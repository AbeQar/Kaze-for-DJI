import Foundation
import CoreMotion
import Combine

enum HeadTrackingManualSource: String, Hashable {
    case touch = "touch"
    case gamepad = "gamepad"
}

/// v0.6.4 faster catch-up head tracking with a symmetric yaw travel limit.
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

    @Published private(set) var statusText = "关闭"
    @Published private(set) var authorizationText = "尚未授权"
    @Published private(set) var controlText = "头追尚未启动"
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

    private var lastMotionAgeMs = 0.0
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
    // Keep the proven close-to-target curve and deadband unchanged. Increase
    // catch-up authority only outside 3 degrees, with a continuous transition.
    // The captured/physically verified 04/01 ceiling remains +/-550; those units
    // are not calibrated degrees/second. Full authority now starts near 24 deg
    // rather than 53 deg, which the head-only +/-45 deg target rarely reached.
    private static let controlFarBaseOffset = Double(controlMinOffset) +
        (controlNearZoneDegrees - controlDeadbandDegrees) * controlNearGainPerDegree
    private static let controlFarGainPerDegree = 24.0
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
        statusText = "正在启动…"
        controlText = "等待 AirPods 运动数据，收到后请设置头部中心"
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
        statusText = "关闭"
        controlText = "头追尚未启动"
        print("AIRPODS HEAD CONTROL: OFF — neutral forced")
        refreshAuthorizationText()
    }

    /// Captures the current AirPods orientation AND current Pocket 3 pose.
    /// Head motion begins controlling the gimbal only after this succeeds.
    @discardableResult
    func captureCenter() -> Bool {
        guard isEnabled, hasMotion else {
            statusText = "尚未收到 AirPods 运动数据，无法设置中心"
            return false
        }

        guard manualOverrides.isEmpty else {
            statusText = "请先松开触屏摇杆或手柄，再设置头部中心"
            return false
        }

        guard let gimbal = telemetryProvider?() else {
            statusText = "无法设置中心：等待 Pocket 3 最新姿态数据"
            controlText = "请连接相机并等待云台姿态数据"
            return false
        }

        captureCurrentPose(using: gimbal)
        pendingRebase = false
        statusText = "中心已设置，头追控制已启动"
        controlText = "跟随中：AirPods 正在控制 Pocket 3"
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
        controlText = "已暂停，请重新设置头部中心以启动"
        statusText = "头追已暂停，请设置头部中心"
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
            controlText = "已暂停，请重新设置头部中心以启动"
            statusText = "正在回中，头追尚未启动"
            print("HEAD CONTROL NATIVE RECENTER: no auto-resume because head control was not armed")
            return
        }

        autoResumeAfterRecenter = true
        recenterRequestedUptime = ProcessInfo.processInfo.systemUptime
        controlText = "已暂停，等待云台完成回中…"
        statusText = "正在回中，完成后将自动恢复头追"
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
                controlText = "手动接管：\(source.rawValue)"
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
        controlText = "手动接管已结束，正在重新校准…"
        print("HEAD CONTROL OVERRIDE END: \(source.rawValue) — rebasing current pose")
        attemptPendingRebase()
    }

    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = true
            print("AIRPODS CONNECTED")
            if self.isEnabled {
                self.statusText = "AirPods 已连接，正在启动运动采集…"
                self.startMotionIfAvailable()
            }
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.forceSafetyNeutral(reason: "AirPods 已断开")
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
                self.statusText = "AirPods 已断开，等待重新连接"
                self.controlText = "已暂停，请重新连接 AirPods 并设置头部中心"
            }
        }
    }

    private func startMotionIfAvailable() {
        guard isEnabled else { return }

        refreshAuthorizationText()

        guard motionManager.isDeviceMotionAvailable else {
            statusText = "等待连接支持运动数据的 AirPods"
            return
        }

        guard !motionManager.isDeviceMotionActive else { return }

        statusText = "正在启动运动采集…"

        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self else { return }

            if let error {
                DispatchQueue.main.async {
                    self.forceSafetyNeutral(reason: "AirPods 运动数据异常")
                    self.hasMotion = false
                    self.statusText = "运动数据异常：\(error.localizedDescription)"
                    self.refreshAuthorizationText()
                }
                return
            }

            guard let motion else { return }

            let radiansToDegrees = 180.0 / Double.pi
            let pitch = motion.attitude.pitch * radiansToDegrees
            let yaw = motion.attitude.yaw * radiansToDegrees
            let roll = motion.attitude.roll * radiansToDegrees
            let motionTimestamp = motion.timestamp

            DispatchQueue.main.async {
                guard self.isEnabled else { return }

                // Diagnostic only: distinguish sample/main-queue delay from
                // mechanical catch-up. Acquisition and control cadence are unchanged.
                self.lastMotionAgeMs = max(0, (ProcessInfo.processInfo.systemUptime - motionTimestamp) * 1000)
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
                statusText = "已收到 AirPods 运动数据，请设置头部中心"
                controlText = "尚未启动，请设置头部中心"
            }
            return
        }

        guard let gimbal = telemetryProvider?() else {
            // Do not keep driving from an old target if gimbal feedback goes
            // stale. Force neutral, then rebase automatically when telemetry
            // becomes fresh again.
            forceSafetyNeutral(reason: "Pocket 3 姿态数据已过期")
            pendingRebase = true
            isControlEngaged = false
            statusText = "头追已暂停，等待最新云台姿态数据"
            controlText = "已暂停：姿态数据已过期，等待自动重新校准"
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
        statusText = "头追跟随中"
        if yawWasLimited {
            controlText = String(
                format: "跟随中 俯仰Δ=%+.1f° 水平Δ=%+.1f°（水平限制 ±%.0f°）",
                -headPitch,
                -headYaw,
                Self.headYawLimitDegrees
            )
        } else {
            controlText = String(
                format: "跟随中 俯仰Δ=%+.1f° 水平Δ=%+.1f°",
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
            controlText = "已暂停，等待回中后的最新姿态数据…"
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
                format: "已暂停，云台正在回中… %d/%d",
                recenterStableSamples,
                Self.recenterStableSampleCount
            )
            return
        }

        captureCurrentPose(using: gimbal)
        resetRecenterAutoResumeState()
        statusText = "回中完成，头追已自动恢复"
        controlText = "跟随中：已回中并以当前头部姿态重新校准"
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
            controlText = "等待最新姿态数据以重新校准…"
            return
        }

        captureCurrentPose(using: gimbal)
        pendingRebase = false
        headCommandWasActive = false
        isControlEngaged = false
        commandText = "P=1024 Y=1024"
        statusText = "手动接管已结束，头追已恢复"
        controlText = "跟随中：已按当前头部和云台姿态重新校准"
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
                    format: "HEAD CONTROL #%llu rel[P=%+.1f Y=%+.1f R=%+.1f] gimbal[P=%+.1f Yc=%+.1f] target[P=%+.1f Yc=%+.1f] err[P=%+.1f Y=%+.1f] cmd[%@] override=%@ sampleAgeMs=%.0f",
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
                    manualOverrides.isEmpty ? "none" : manualOverrides.map(\.rawValue).sorted().joined(separator: "+"),
                    lastMotionAgeMs
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

    static func controlAxisOffset(errorDegrees: Double) -> Int {
        guard errorDegrees.isFinite else { return 0 }
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
            authorizationText = "尚未授权"
        case .restricted:
            authorizationText = "受系统限制"
        case .denied:
            authorizationText = "未允许"
        case .authorized:
            authorizationText = "已允许"
        @unknown default:
            authorizationText = "未知"
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
