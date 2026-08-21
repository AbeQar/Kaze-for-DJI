import Foundation
import CoreMotion
import Combine

enum HeadTrackingManualSource: String, Hashable {
    case touch = "touch"
    case gamepad = "gamepad"
}

/// v0.6.3 full-authority head tracking with a symmetric yaw travel limit.
///
/// Safety model:
/// - Head Tracking always starts OFF for a fresh app launch.
/// - Enabling motion alone cannot move the gimbal; Set Head Center is required.
/// - Set Head Center captures BOTH the current AirPods pose and the current
///   Pocket 3 telemetry pose.
/// - Touch/gamepad temporarily override head tracking. When the last manual
///   override ends, the current head + gimbal pose is rebased before tracking
///   resumes, preventing a jump back toward the old target.
/// - AirPods disconnect, Head Tracking OFF, explicit invalidation, or stale
///   gimbal telemetry forces neutral.
final class HeadTrackingManager: NSObject, ObservableObject, CMHeadphoneMotionManagerDelegate {
    @Published private(set) var isEnabled = false
    @Published private(set) var isConnected = false
    @Published private(set) var hasMotion = false
    @Published private(set) var isCentered = false
    @Published private(set) var isControlEngaged = false
    @Published private(set) var isManualOverrideActive = false

    // Raw AirPods attitude as reported by Core Motion.
    @Published private(set) var pitchDegrees = 0.0
    @Published private(set) var yawDegrees = 0.0
    @Published private(set) var rollDegrees = 0.0

    // Relative attitude after Set Head Center / automatic rebase.
    @Published private(set) var relativePitchDegrees = 0.0
    @Published private(set) var relativeYawDegrees = 0.0
    @Published private(set) var relativeRollDegrees = 0.0

    @Published private(set) var continuousYawDegrees = 0.0
    @Published private(set) var sampleCount: UInt64 = 0

    @Published private(set) var statusText = "Off"
    @Published private(set) var authorizationText = "Not determined"
    @Published private(set) var controlText = "Head control not armed"
    @Published private(set) var commandText = "P=1024 Y=1024"

    /// Supplied by ContentView. Must return only fresh gimbal telemetry.
    var telemetryProvider: (() -> GimbalTelemetry?)?

    /// Updates the existing proven 04/01 joystick request path.
    var onControlCommand: ((_ pitch: Int, _ yaw: Int) -> Void)?

    /// Releases an active head-control request when the target settles.
    var onControlRelease: (() -> Void)?

    /// Forces an explicit neutral for safety events.
    var onSafetyNeutral: (() -> Void)?

    private let motionManager = CMHeadphoneMotionManager()
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Pocket3.HeadphoneMotion"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        return queue
    }()

    private var lastRawYawDegrees: Double?

    private var centerPitchDegrees = 0.0
    private var centerContinuousYawDegrees = 0.0
    private var centerRollDegrees = 0.0

    private var gimbalBaselinePitchDegrees = 0.0
    private var gimbalBaselineYawContinuousDegrees = 0.0

    private var manualOverrides: Set<HeadTrackingManualSource> = []
    private var pendingRebase = false
    private var headCommandWasActive = false

    // Native recenter can temporarily pause live head control and then
    // automatically rebase once fresh 04/05 telemetry has visibly settled.
    // This keeps the Head Tracking switch ON and avoids a snap after FE08.
    private var autoResumeAfterRecenter = false
    private var recenterRequestedUptime: TimeInterval = 0.0
    private var recenterLastTelemetryNs: UInt64 = 0
    private var recenterLastPitchDegrees: Double?
    private var recenterLastYawContinuousDegrees: Double?
    private var recenterStableSamples = 0

    private var lastConsoleLogUptime: TimeInterval = 0.0
    private let consoleLogInterval: TimeInterval = 0.20

    // v0.6.3 keeps full +/-550 04/01 command authority, but head tracking alone
    // is intentionally symmetric in yaw. The Pocket 3 can physically rotate much
    // farther to one side than the other, so cap the head-driven yaw target to
    // +/-45 degrees around the current head-control baseline. This is slightly
    // inside the roughly 48-degree short-side physical travel observed on hardware.
    // Touch/gamepad are not affected by this head-only position limit.
    private static let headYawLimitDegrees = 45.0
    private static let controlDeadbandDegrees = 0.8
    private static let controlNearZoneDegrees = 3.0
    private static let controlMinOffset = 30
    private static let controlNearGainPerDegree = 8.0
    private static let controlFarBaseOffset = 48.0
    private static let controlFarGainPerDegree = 10.0
    private static let controlMaxOffset = JoystickMapper.mimoMaxOffset
    private static let neutral = 1024

    // Native FE08 recenter auto-resume settling detector. We only count unique
    // 04/05 telemetry frames, never repeated Core Motion callbacks that happen
    // to observe the same gimbal sample.
    private static let recenterResumeNotBeforeSeconds = 0.60
    private static let recenterStablePitchDeltaDegrees = 0.35
    private static let recenterStableYawDeltaDegrees = 0.35
    private static let recenterStableSampleCount = 10

    override init() {
        super.init()
        motionManager.delegate = self
        refreshAuthorizationText()
    }

    deinit {
        motionManager.stopDeviceMotionUpdates()
        motionManager.stopConnectionStatusUpdates()
    }

    func enable() {
        guard !isEnabled else { return }

        isEnabled = true
        isConnected = false
        hasMotion = false
        sampleCount = 0
        resetYawTracking()
        clearCenterInternal()
        manualOverrides.removeAll()
        isManualOverrideActive = false
        pendingRebase = false
        headCommandWasActive = false
        resetRecenterAutoResumeState()
        isControlEngaged = false
        statusText = "Starting…"
        controlText = "Waiting for AirPods motion — then Set Head Center"
        commandText = "P=1024 Y=1024"
        lastConsoleLogUptime = 0.0
        print("AIRPODS HEAD CONTROL: ON — control remains DISARMED until Set Head Center")
        refreshAuthorizationText()

        motionManager.startConnectionStatusUpdates()
        startMotionIfAvailable()
    }

    func disable() {
        guard isEnabled else { return }

        motionManager.stopDeviceMotionUpdates()
        motionManager.stopConnectionStatusUpdates()

        forceSafetyNeutral(reason: "Head Tracking switched OFF")

        isEnabled = false
        isConnected = false
        hasMotion = false
        manualOverrides.removeAll()
        isManualOverrideActive = false
        pendingRebase = false
        resetRecenterAutoResumeState()
        resetYawTracking()
        clearCenterInternal()
        statusText = "Off"
        controlText = "Head control not armed"
        print("AIRPODS HEAD CONTROL: OFF — neutral forced")
        refreshAuthorizationText()
    }

    /// Captures the current AirPods orientation AND current Pocket 3 pose.
    /// Head motion begins controlling the gimbal only after this succeeds.
    @discardableResult
    func captureCenter() -> Bool {
        guard isEnabled, hasMotion else {
            statusText = "Cannot center until AirPods motion is active"
            return false
        }

        guard manualOverrides.isEmpty else {
            statusText = "Release touch/gamepad before setting head center"
            return false
        }

        guard let gimbal = telemetryProvider?() else {
            statusText = "Cannot center — waiting for fresh Pocket 3 telemetry"
            controlText = "Connect the control link and wait for 04/05 telemetry"
            return false
        }

        captureCurrentPose(using: gimbal)
        pendingRebase = false
        statusText = "Head centered — LIVE gimbal control armed"
        controlText = "LIVE — AirPods head tracking controls Pocket 3"
        print(
            String(
                format: "HEAD CONTROL CENTER CAPTURED: head raw P=%+.1f Y=%+.1f R=%+.1f Ycont=%+.1f | gimbal baseline P=%+.1f Ycont=%+.1f",
                pitchDegrees,
                yawDegrees,
                rollDegrees,
                continuousYawDegrees,
                gimbal.pitchDeg,
                gimbal.yawContinuousDeg
            )
        )
        return true
    }

    /// Use before commands that intentionally reposition/stop the gimbal
    /// outside head tracking and should remain disarmed afterward (STOP, smooth
    /// recenter, disconnect). The Head Tracking switch stays ON, but Set Head
    /// Center is required again.
    func invalidateControlCenter(reason: String) {
        guard isEnabled else { return }

        forceSafetyNeutral(reason: reason)
        clearCenterInternal()
        pendingRebase = false
        resetRecenterAutoResumeState()
        controlText = "Paused — Set Head Center to arm control again"
        statusText = "Head control paused — Set Head Center"
        print("HEAD CONTROL CENTER INVALIDATED: \(reason)")
    }

    /// Call immediately before sending the Pocket 3 native FE08 recenter. If
    /// head control is currently armed, live control pauses, the switch remains
    /// ON, and fresh 04/05 telemetry is watched until the gimbal has settled.
    /// The then-current head + gimbal pose becomes the new zero automatically.
    func prepareForRecenterAutoResume(reason: String) {
        guard isEnabled else { return }

        let shouldAutoResume = isCentered && hasMotion
        forceSafetyNeutral(reason: reason)
        clearCenterInternal()
        pendingRebase = false
        resetRecenterAutoResumeState()

        guard shouldAutoResume else {
            controlText = "Paused — Set Head Center to arm control again"
            statusText = "Native recenter requested — head control remains disarmed"
            print("HEAD CONTROL NATIVE RECENTER: no auto-resume because head control was not armed")
            return
        }

        autoResumeAfterRecenter = true
        recenterRequestedUptime = ProcessInfo.processInfo.systemUptime
        controlText = "Paused — waiting for native recenter to settle…"
        statusText = "Recenter running — head tracking will resume automatically"
        print("HEAD CONTROL NATIVE RECENTER PAUSE: \(reason) — auto-resume armed")
    }

    /// Manual touch/gamepad ownership. Multiple simultaneous manual sources are
    /// tracked independently, so releasing one cannot resume head control while
    /// the other still owns the gimbal.
    func setManualOverride(_ source: HeadTrackingManualSource, active: Bool) {
        guard isEnabled else { return }

        if active {
            let wasEmpty = manualOverrides.isEmpty
            manualOverrides.insert(source)
            isManualOverrideActive = !manualOverrides.isEmpty

            if wasEmpty {
                if autoResumeAfterRecenter {
                    resetRecenterAutoResumeState()
                    print("HEAD CONTROL NATIVE RECENTER AUTO-RESUME CANCELED: manual \(source.rawValue) took control")
                }
                isControlEngaged = false
                controlText = "Manual override — \(source.rawValue)"
                print("HEAD CONTROL OVERRIDE BEGIN: \(source.rawValue)")
            }
            return
        }

        let hadSource = manualOverrides.remove(source) != nil
        guard hadSource else { return }

        isManualOverrideActive = !manualOverrides.isEmpty
        guard manualOverrides.isEmpty else { return }

        // The caller releases its manual joystick command before invoking this.
        // Rebase current head + current gimbal pose so there is no jump when
        // head tracking resumes.
        pendingRebase = true
        isControlEngaged = false
        headCommandWasActive = false
        commandText = "P=1024 Y=1024"
        controlText = "Manual override ended — rebasing…"
        print("HEAD CONTROL OVERRIDE END: \(source.rawValue) — rebasing current pose")
        attemptPendingRebase()
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = true
            print("AIRPODS CONNECTED")
            if self.isEnabled {
                self.statusText = "AirPods connected — starting motion…"
                self.startMotionIfAvailable()
            }
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.forceSafetyNeutral(reason: "AirPods disconnected")
            self.isConnected = false
            self.hasMotion = false
            print("AIRPODS DISCONNECTED — neutral forced")
            self.motionManager.stopDeviceMotionUpdates()
            self.resetYawTracking()
            self.clearCenterInternal()
            self.manualOverrides.removeAll()
            self.isManualOverrideActive = false
            self.pendingRebase = false
            self.resetRecenterAutoResumeState()
            if self.isEnabled {
                self.statusText = "AirPods disconnected — waiting"
                self.controlText = "Paused — reconnect AirPods and Set Head Center"
            }
        }
    }

    private func startMotionIfAvailable() {
        guard isEnabled else { return }

        refreshAuthorizationText()

        guard motionManager.isDeviceMotionAvailable else {
            statusText = "Waiting for motion-capable AirPods"
            return
        }

        guard !motionManager.isDeviceMotionActive else { return }

        statusText = "Starting motion…"

        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self else { return }

            if let error {
                DispatchQueue.main.async {
                    self.forceSafetyNeutral(reason: "AirPods motion error")
                    self.hasMotion = false
                    self.statusText = "Motion error: \(error.localizedDescription)"
                    self.refreshAuthorizationText()
                }
                return
            }

            guard let motion else { return }

            let radiansToDegrees = 180.0 / Double.pi
            let pitch = motion.attitude.pitch * radiansToDegrees
            let yaw = motion.attitude.yaw * radiansToDegrees
            let roll = motion.attitude.roll * radiansToDegrees

            DispatchQueue.main.async {
                guard self.isEnabled else { return }

                self.isConnected = true
                self.hasMotion = true
                self.pitchDegrees = pitch
                self.yawDegrees = yaw
                self.rollDegrees = roll
                self.updateContinuousYaw(withRawYaw: yaw)

                if self.isCentered {
                    self.relativePitchDegrees = Self.wrappedDeltaDegrees(pitch - self.centerPitchDegrees)
                    self.relativeYawDegrees = self.continuousYawDegrees - self.centerContinuousYawDegrees
                    self.relativeRollDegrees = Self.wrappedDeltaDegrees(roll - self.centerRollDegrees)
                }

                self.sampleCount &+= 1

                if self.autoResumeAfterRecenter, self.manualOverrides.isEmpty {
                    self.attemptRecenterAutoResume()
                }

                if self.pendingRebase, self.manualOverrides.isEmpty {
                    self.attemptPendingRebase()
                }

                self.updateLiveControl()
                self.logMotionAndControlIfNeeded()
                self.refreshAuthorizationText()
            }
        }
    }

    private func updateLiveControl() {
        guard isEnabled, hasMotion else { return }

        guard manualOverrides.isEmpty else {
            isControlEngaged = false
            return
        }

        guard !autoResumeAfterRecenter else {
            isControlEngaged = false
            return
        }

        guard isCentered, !pendingRebase else {
            isControlEngaged = false
            if !pendingRebase {
                statusText = "Receiving AirPods motion — Set Head Center"
                controlText = "DISARMED — Set Head Center"
            }
            return
        }

        guard let gimbal = telemetryProvider?() else {
            // Do not keep driving from an old target if gimbal feedback goes
            // stale. Force neutral, then rebase automatically when telemetry
            // becomes fresh again.
            forceSafetyNeutral(reason: "Pocket 3 telemetry stale")
            pendingRebase = true
            isControlEngaged = false
            statusText = "Head control paused — waiting for fresh gimbal telemetry"
            controlText = "Paused — telemetry stale; automatic rebase pending"
            return
        }

        // Pitch remains unrestricted by our software. Yaw is symmetric for
        // head tracking only: +/-45 degrees around the current control baseline.
        // Relative Yaw still reports the user's full measured head motion; only
        // the gimbal target is clamped.
        let headPitch = relativePitchDegrees
        let requestedHeadYaw = relativeYawDegrees
        let headYaw = requestedHeadYaw.clamped(
            to: (-Self.headYawLimitDegrees)...Self.headYawLimitDegrees
        )
        let yawWasLimited = abs(requestedHeadYaw) > Self.headYawLimitDegrees

        // Physical sign mapping proven in v0.5b:
        // AirPods: +yaw=LEFT, -yaw=RIGHT, +pitch=UP, -pitch=DOWN.
        // Pocket 3 telemetry increases opposite to the desired head delta for
        // both target axes, so desired pose = baseline - head delta.
        let targetPitch = Self.wrappedDegrees(gimbalBaselinePitchDegrees - headPitch)
        let targetYawContinuous = gimbalBaselineYawContinuousDegrees - headYaw

        let pitchError = Self.wrappedDeltaDegrees(targetPitch - gimbal.pitchDeg)
        let yawError = targetYawContinuous - gimbal.yawContinuousDeg

        let pitchOffset = Self.controlAxisOffset(errorDegrees: pitchError)
        let yawOffset = Self.controlAxisOffset(errorDegrees: yawError)

        // Same sign conventions already physically proven by smooth recenter:
        // pitch command is opposite telemetry error; yaw command follows error.
        let pitchCommand = (Self.neutral - pitchOffset)
            .clamped(to: (Self.neutral - Self.controlMaxOffset)...(Self.neutral + Self.controlMaxOffset))
        let yawCommand = (Self.neutral + yawOffset)
            .clamped(to: (Self.neutral - Self.controlMaxOffset)...(Self.neutral + Self.controlMaxOffset))

        commandText = "P=\(pitchCommand) Y=\(yawCommand)"
        statusText = "Head centered — LIVE gimbal control"
        if yawWasLimited {
            controlText = String(
                format: "LIVE  target ΔP=%+.1f° ΔY=%+.1f°  (head yaw capped ±%.0f°)",
                -headPitch,
                -headYaw,
                Self.headYawLimitDegrees
            )
        } else {
            controlText = String(
                format: "LIVE  target ΔP=%+.1f° ΔY=%+.1f°",
                -headPitch,
                -headYaw
            )
        }

        if pitchOffset == 0, yawOffset == 0 {
            isControlEngaged = false
            if headCommandWasActive {
                headCommandWasActive = false
                onControlRelease?()
            }
            return
        }

        isControlEngaged = true
        headCommandWasActive = true
        onControlCommand?(pitchCommand, yawCommand)
    }

    private func attemptRecenterAutoResume() {
        guard autoResumeAfterRecenter, isEnabled, hasMotion, manualOverrides.isEmpty else { return }
        guard let gimbal = telemetryProvider?() else {
            controlText = "Paused — waiting for fresh recenter telemetry…"
            return
        }

        // CMHeadphoneMotionManager updates much faster than 04/05 telemetry.
        // Only evaluate a new Pocket 3 sample once.
        guard gimbal.receivedAtNs != recenterLastTelemetryNs else { return }
        recenterLastTelemetryNs = gimbal.receivedAtNs

        let elapsed = ProcessInfo.processInfo.systemUptime - recenterRequestedUptime

        if let lastPitch = recenterLastPitchDegrees,
           let lastYaw = recenterLastYawContinuousDegrees {
            let pitchStep = abs(Self.wrappedDeltaDegrees(gimbal.pitchDeg - lastPitch))
            let yawStep = abs(gimbal.yawContinuousDeg - lastYaw)

            if elapsed >= Self.recenterResumeNotBeforeSeconds,
               pitchStep <= Self.recenterStablePitchDeltaDegrees,
               yawStep <= Self.recenterStableYawDeltaDegrees {
                recenterStableSamples += 1
            } else {
                recenterStableSamples = 0
            }
        }

        recenterLastPitchDegrees = gimbal.pitchDeg
        recenterLastYawContinuousDegrees = gimbal.yawContinuousDeg

        guard recenterStableSamples >= Self.recenterStableSampleCount else {
            controlText = String(
                format: "Paused — native recenter settling… %d/%d",
                recenterStableSamples,
                Self.recenterStableSampleCount
            )
            return
        }

        captureCurrentPose(using: gimbal)
        resetRecenterAutoResumeState()
        statusText = "Head tracking resumed automatically after recenter"
        controlText = "LIVE — recenter complete; current head pose rebased"
        commandText = "P=1024 Y=1024"
        print(
            String(
                format: "HEAD CONTROL AUTO-RESUMED AFTER RECENTER: head P=%+.1f Ycont=%+.1f | gimbal P=%+.1f Ycont=%+.1f",
                pitchDegrees,
                continuousYawDegrees,
                gimbal.pitchDeg,
                gimbal.yawContinuousDeg
            )
        )
    }

    private func attemptPendingRebase() {
        guard pendingRebase, isEnabled, hasMotion, manualOverrides.isEmpty else { return }
        guard let gimbal = telemetryProvider?() else {
            controlText = "Waiting for fresh telemetry to rebase…"
            return
        }

        captureCurrentPose(using: gimbal)
        pendingRebase = false
        headCommandWasActive = false
        isControlEngaged = false
        commandText = "P=1024 Y=1024"
        statusText = "Head tracking resumed after manual override"
        controlText = "LIVE — rebased to current head + gimbal pose"
        print(
            String(
                format: "HEAD CONTROL REBASED: head P=%+.1f Ycont=%+.1f | gimbal P=%+.1f Ycont=%+.1f",
                pitchDegrees,
                continuousYawDegrees,
                gimbal.pitchDeg,
                gimbal.yawContinuousDeg
            )
        )
    }

    private func captureCurrentPose(using gimbal: GimbalTelemetry) {
        centerPitchDegrees = pitchDegrees
        centerContinuousYawDegrees = continuousYawDegrees
        centerRollDegrees = rollDegrees

        gimbalBaselinePitchDegrees = gimbal.pitchDeg
        gimbalBaselineYawContinuousDegrees = gimbal.yawContinuousDeg

        relativePitchDegrees = 0.0
        relativeYawDegrees = 0.0
        relativeRollDegrees = 0.0
        isCentered = true
        isControlEngaged = false
        headCommandWasActive = false
        commandText = "P=1024 Y=1024"
    }

    private func forceSafetyNeutral(reason: String) {
        // Force the existing gimbal pump to emit an explicit neutral packet.
        // This is intentionally used for safety state changes, not ordinary
        // deadband settling.
        onSafetyNeutral?()
        headCommandWasActive = false
        isControlEngaged = false
        commandText = "P=1024 Y=1024"
        print("HEAD CONTROL NEUTRAL: \(reason)")
    }

    private func resetRecenterAutoResumeState() {
        autoResumeAfterRecenter = false
        recenterRequestedUptime = 0.0
        recenterLastTelemetryNs = 0
        recenterLastPitchDegrees = nil
        recenterLastYawContinuousDegrees = nil
        recenterStableSamples = 0
    }

    private func clearCenterInternal() {
        isCentered = false
        isControlEngaged = false
        centerPitchDegrees = 0.0
        centerContinuousYawDegrees = 0.0
        centerRollDegrees = 0.0
        gimbalBaselinePitchDegrees = 0.0
        gimbalBaselineYawContinuousDegrees = 0.0
        relativePitchDegrees = 0.0
        relativeYawDegrees = 0.0
        relativeRollDegrees = 0.0
        headCommandWasActive = false
        commandText = "P=1024 Y=1024"
    }

    private func updateContinuousYaw(withRawYaw rawYaw: Double) {
        if let lastRawYawDegrees {
            continuousYawDegrees += Self.wrappedDeltaDegrees(rawYaw - lastRawYawDegrees)
        } else {
            continuousYawDegrees = rawYaw
        }
        lastRawYawDegrees = rawYaw
    }

    private func resetYawTracking() {
        lastRawYawDegrees = nil
        continuousYawDegrees = 0.0
    }

    private func logMotionAndControlIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastConsoleLogUptime >= consoleLogInterval else { return }
        lastConsoleLogUptime = now

        if isCentered, let gimbal = telemetryProvider?() {
            let headPitch = relativePitchDegrees
            let requestedHeadYaw = relativeYawDegrees
            let headYaw = requestedHeadYaw.clamped(
                to: (-Self.headYawLimitDegrees)...Self.headYawLimitDegrees
            )
            let targetPitch = Self.wrappedDegrees(gimbalBaselinePitchDegrees - headPitch)
            let targetYaw = gimbalBaselineYawContinuousDegrees - headYaw
            let pitchError = Self.wrappedDeltaDegrees(targetPitch - gimbal.pitchDeg)
            let yawError = targetYaw - gimbal.yawContinuousDeg

            print(
                String(
                    format: "HEAD CONTROL #%llu rel[P=%+.1f Y=%+.1f R=%+.1f] gimbal[P=%+.1f Yc=%+.1f] target[P=%+.1f Yc=%+.1f] err[P=%+.1f Y=%+.1f] cmd[%@] override=%@",
                    sampleCount,
                    relativePitchDegrees,
                    relativeYawDegrees,
                    relativeRollDegrees,
                    gimbal.pitchDeg,
                    gimbal.yawContinuousDeg,
                    targetPitch,
                    targetYaw,
                    pitchError,
                    yawError,
                    commandText,
                    manualOverrides.isEmpty ? "none" : manualOverrides.map(\.rawValue).sorted().joined(separator: "+")
                )
            )
        } else if isCentered {
            print(
                String(
                    format: "HEAD CONTROL #%llu rel[P=%+.1f Y=%+.1f R=%+.1f] gimbal[STALE] cmd[%@] override=%@",
                    sampleCount,
                    relativePitchDegrees,
                    relativeYawDegrees,
                    relativeRollDegrees,
                    commandText,
                    manualOverrides.isEmpty ? "none" : manualOverrides.map(\.rawValue).sorted().joined(separator: "+")
                )
            )
        } else {
            print(
                String(
                    format: "AIRPODS MOTION #%llu raw[P=%+.1f Y=%+.1f R=%+.1f] Ycont=%+.1f control[DISARMED]",
                    sampleCount,
                    pitchDegrees,
                    yawDegrees,
                    rollDegrees,
                    continuousYawDegrees
                )
            )
        }
    }

    private static func controlAxisOffset(errorDegrees: Double) -> Int {
        let magnitude = abs(errorDegrees)
        if magnitude <= controlDeadbandDegrees { return 0 }

        let activeMagnitude = magnitude - controlDeadbandDegrees
        let raw: Double

        if magnitude <= controlNearZoneDegrees {
            // Softer close to target to reduce hunting while still reacting
            // sooner than v0.6's 1.5° deadband.
            raw = Double(controlMinOffset) + activeMagnitude * controlNearGainPerDegree
        } else {
            // More authority once the target is clearly moving away.
            raw = controlFarBaseOffset +
                (magnitude - controlNearZoneDegrees) * controlFarGainPerDegree
        }

        let clamped = Int(raw.rounded()).clamped(to: controlMinOffset...controlMaxOffset)
        return errorDegrees > 0 ? clamped : -clamped
    }

    /// Returns the shortest signed angular delta in [-180, +180).
    static func wrappedDeltaDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360.0)
        if value >= 180.0 { value -= 360.0 }
        if value < -180.0 { value += 360.0 }
        return value
    }

    private static func wrappedDegrees(_ degrees: Double) -> Double {
        wrappedDeltaDegrees(degrees)
    }

    private func refreshAuthorizationText() {
        switch CMHeadphoneMotionManager.authorizationStatus() {
        case .notDetermined:
            authorizationText = "Not determined"
        case .restricted:
            authorizationText = "Restricted"
        case .denied:
            authorizationText = "Denied"
        case .authorized:
            authorizationText = "Authorized"
        @unknown default:
            authorizationText = "Unknown"
        }
    }

    var pitchText: String { Self.formatDegrees(pitchDegrees) }
    var yawText: String { Self.formatDegrees(yawDegrees) }
    var rollText: String { Self.formatDegrees(rollDegrees) }
    var continuousYawText: String { Self.formatDegrees(continuousYawDegrees) }

    var relativePitchText: String { Self.formatDegrees(relativePitchDegrees) }
    var relativeYawText: String { Self.formatDegrees(relativeYawDegrees) }
    var relativeRollText: String { Self.formatDegrees(relativeRollDegrees) }

    private static func formatDegrees(_ value: Double) -> String {
        String(format: "%+.1f°", value)
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
