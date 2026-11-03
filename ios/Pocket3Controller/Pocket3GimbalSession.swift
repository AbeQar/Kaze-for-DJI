import Foundation
import Network
import Combine
import os

final class Pocket3GimbalSession: ObservableObject {
    var onTerminalConnectionFailure: ((String) -> Void)?
    private enum ConnectionState: String {
        case disconnected
        case probingPocket
        case bootstrappingTCP
        case handshakingUDP
        case registering
        case ready
        case backgroundPreserved
        case recovering
        case disconnecting
        case failed
    }

    private enum ReadinessAttemptResult {
        case ready(transport: DumlTransport, heartbeat: Data)
        case noHeartbeat(DumlTransport)
        case ended
    }

    static let cameraIP = "192.168.2.1"
    static let udpPort: UInt16 = 9004
    static let tcpPokePort: UInt16 = 7001
    static let neutral = 1024
    static let recenterPayload = Data([0xFE, 0x08])
    static let gimbalLockPayload = Data([0x00, 0x00])
    static let gimbalFollowPayload = Data([0x01, 0x00])
    static let cameraRecordStartPayload = Pocket3CameraStatus.recordingCommand(true).payload
    static let cameraRecordStopPayload = Pocket3CameraStatus.recordingCommand(false).payload
    static let cameraRecordCommandTimeoutNs: UInt64 = 2_000_000_000

    // Osmosis' proven UDP APP-presence beat and Pocket 3 gimbal readiness heartbeat.
    private static let appPresence = Data(hex: "170046237c415050000000000002")
    private static let gimbalHeartbeat = Data([0x01, 0x04, 0x05])
    private static let gimbalInit = Data(hex: "05ffffffff")

    // Capture-confirmed Mimo live-view states from the proven v4/v11 direct-video path.
    private static let liveStart = Data(hex: "0100000000040000000501")
    private static let liveIdle = Data(hex: "0000000000040000000401")
    private static let liveA8 = Data(hex: "00040200000000000000")

    // Frozen Android v0.14.3 smooth-recenter tuning.
    static let defaultCenterPitchDeg = 180.0
    static let defaultCenterYawDeg = 0.0
    private static let smoothDeadbandDeg = 0.8
    private static let smoothMinOffset = 48
    private static let smoothMaxOffset = 430
    private static let smoothGainPerDeg = 6.0
    private static let smoothTimeoutMs: UInt64 = 35_000
    private static let smoothStaleTelemetryMs: UInt64 = 350
    private static let smoothProgressTimeoutMs: UInt64 = 5_000
    private static let smoothProgressEpsilonDeg = 0.20
    private static let smoothSettleSamples = 3
    private static let smoothMaxTxLagSlots = 64
    private static let smoothDivergenceMinErrorDeg = 8.0
    private static let smoothDivergenceStepDeg = 1.5
    private static let smoothDivergenceSamples = 5

    @Published private(set) var status = "尚未连接 Pocket 3 数据链路"
    @Published private(set) var logText = ""
    @Published private(set) var telemetryText = "等待云台姿态数据"
    @Published private(set) var centerText = "尚未记录中心位置"
    @Published private(set) var isBusy = false
    @Published private(set) var isConnected = false
    @Published private(set) var smoothRecenterRunning = false
    @Published private(set) var canCaptureCenter = false
    @Published private(set) var canSmoothRecenter = false
    @Published private(set) var isGimbalLocked = false
    @Published private(set) var cameraState = Pocket3CameraState()
    @Published private(set) var cameraBatteryPercent: UInt8? = nil
    @Published private(set) var cameraBatteryCharging: Bool? = nil
    @Published private(set) var videoReceiving = false

    // Compatibility accessors keep existing clients source-compatible while new camera-facing
    // code consumes the coherent state boundary above.
    var isCameraRecording: Bool? { cameraState.recording }
    var cameraRecordingTransitionInProgress: Bool { cameraState.recordingTransitionInProgress }
    var cameraRecordCommandInFlight: Bool { cameraState.recordCommandInFlight }
    var cameraStorageTotalMiB: UInt32? { cameraState.storageTotalMiB }
    var cameraStorageFreeMiB: UInt32? { cameraState.storageFreeMiB }
    var cameraRemainingRecordSeconds: UInt16? { cameraState.remainingRecordSeconds }
    var cameraElapsedRecordSeconds: UInt16? { cameraState.elapsedRecordSeconds }
    var cameraShootingMode: UInt8? { cameraState.shootingModeRawValue }
    var cameraReadback: Pocket3CameraReadbackState { cameraState.readback }

    lazy private(set) var camera = Pocket3CameraControl(
        sendCommand: { [weak self] command in self?.sendCameraCommand(command) },
        setRecording: { [weak self] recording in self?.setCameraRecording(recording) }
    )

    private let stateLock = NSLock()
    private let logLock = NSLock()
    private static let connectionLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "Pocket3Controller",
        category: "ConnectionLifecycle"
    )

    private var transport: DumlTransport?
    private var pumpThread: Thread?
    private var pumpStopped: DispatchSemaphore?
    private var connectWorkerStopped: DispatchSemaphore?

    private var pumpRunning = false
    private var sessionReady = false
    private var connectInProgress = false
    private var disconnectInProgress = false
    private var connectionGeneration = 0
    private var connectionState = ConnectionState.disconnected
    private var connectStartedNs: UInt64 = 0
    private var readyAtNs: UInt64 = 0
    private var lastInboundNs: UInt64 = 0
    private var reconnectAttemptCount = 0
    private var firstVideoLoggedGeneration = -1

    // App-lifecycle recovery. We deliberately preserve a healthy direct UDP
    // session across a brief background interval, then require fresh Pocket
    // traffic after foregrounding. If the preserved session is stale, we
    // replace it with a brand-new transport/session instead of trusting it.
    private var backgroundResumeWanted = false
    private var foregroundRecoveryInProgress = false
    private var foregroundPiPVideoRefreshPending = false
    private var lifecycleGeneration = 0

    // Video is fed by the same single-owner UDP receive pump as gimbal control.
    // It never owns a second Pocket socket or mutates transport/window state.
    lazy var videoOutput = Pocket3VideoOutput(
        onReady: { [weak self] in self?.handleFirstVideo() },
        onUnavailable: { [weak self] in self?.publishVideoReceiving(false) },
        onForegroundPiPStopped: { [weak self] in self?.queuePostPiPVideoRefresh() },
        onLog: { [weak self] message in self?.log(message) }
    )

    // Manual/pulse 04/01 state. The single UDP pump is the only network sender.
    private var requestedPitch = Pocket3GimbalSession.neutral
    private var requestedYaw = Pocket3GimbalSession.neutral
    private var joystickActive = false
    private var controlUntilNs: UInt64 = 0
    private var forceNeutralPending = false

    // Native recenter and software lock/follow commands are serialized on the
    // same single-owner UDP pump thread as every other Pocket command.
    private var recenterPending = false
    private var recenterAwaitingReply = false
    private var gimbalLockCommandPending: Bool?
    private var selfieFlipPending = false
    private var cameraRecordCommandPending: Bool?
    private var cameraRecordCommandTarget: Bool?
    private var cameraCommandQueue: [Pocket3CameraCommand] = []
    private var cameraPropertyTransactionID: UInt32 = 0x0000_C900
    private var lastCameraPropertyValues: [String: Data] = [:]
    private var cameraRecordCommandDeadlineNs: UInt64 = 0

    // Closed-loop smooth recenter.
    private var smoothRecenterActive = false
    private var smoothTargetPitchDeg = Pocket3GimbalSession.defaultCenterPitchDeg
    private var smoothTargetYawContinuousDeg = Pocket3GimbalSession.defaultCenterYawDeg
    private var smoothInitialized = false
    private var smoothStartNs: UInt64 = 0
    private var smoothLastProgressNs: UInt64 = 0
    private var smoothBestErrorDeg = Double.infinity
    private var smoothLastSampleNs: UInt64 = 0
    private var smoothSettledSamples = 0
    private var smoothLastYawAbsErrorDeg = Double.nan
    private var smoothYawDivergenceSamples = 0

    // Live telemetry/history.
    private var latestTelemetrySample: GimbalTelemetry?
    private var telemetryHistory: [GimbalTelemetry] = []
    private var lastTelemetryNs: UInt64 = 0
    private var lastTelemetryLogNs: UInt64 = 0
    private var lastTelemetryPublishNs: UInt64 = 0
    private var lastFreshnessPublishNs: UInt64 = 0

    // Camera record state is unsolicited 02/80 telemetry. Keep the raw byte so
    // transition values remain observable; the confirmed recording bit is 0x80.
    private var latestCameraRecording: Bool?
    private var lastCameraRecordStatusByte: UInt8?
    private var lastCameraStatusFields: Pocket3CameraStatus.StatusFields?
    private var lastCameraStoragePushFields: Pocket3CameraStatus.StorageFields?
    private var lastBatteryStatusFields: Pocket3BatteryStatusFields?

    // Wrapped yaw -> physical continuous yaw.
    private var yawReducer = Pocket3YawReducer()

    private var capturedCenter: GimbalTelemetry?
    private var lastHeartbeatReplyNs: UInt64 = 0

    private var logLines: [String] = []
    private let maxLogLines = 1200

    private lazy var timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    // MARK: - Connection

    func connect() {
        stateLock.lock()
        guard !connectInProgress, !disconnectInProgress, !sessionReady else {
            stateLock.unlock()
            return
        }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        connectInProgress = true
        connectStartedNs = nowNs()
        readyAtNs = 0
        lastInboundNs = 0
        reconnectAttemptCount += 1
        let attempt = reconnectAttemptCount
        let workerStopped = DispatchSemaphore(value: 0)
        connectWorkerStopped = workerStopped
        stateLock.unlock()

        publishBusy(true)
        publishVideoReceiving(false)
        videoOutput.reset()
        publishStatus("正在连接相机 192.168.2.1…")
        log("=== DATALINK CONNECT ATTEMPT ===")
        transitionConnectionState(
            to: .probingPocket,
            reason: "connectRequested",
            generation: generation
        )
        os_signpost(
            .event,
            log: Self.connectionLog,
            name: "connect_start",
            "generation=%{public}d attempt=%{public}d",
            generation,
            attempt
        )
        log("Pocket3Controller v0.6 First Live Head Tracking")
        log("Frozen Android v0.14.3 transport/control behavior unchanged; touch, gamepad, and head tracking feed the same proven 04/01 control pump")
        log("iPhone must already be joined to OsmoPocket-3 Wi-Fi")

        let thread = Thread { [weak self] in
            defer { workerStopped.signal() }
            self?.connectWorker(generation: generation)
        }
        thread.name = "Pocket3-Connect"
        thread.start()
    }

    func disconnect(completion: (() -> Void)? = nil) {
        videoOutput.stopSessionImmediately()
        disconnectInternal(
            userInitiated: true,
            reason: "Datalink: disconnected by user",
            completion: completion
        )
    }

    private func disconnectInternal(
        userInitiated: Bool,
        reason: String,
        completion: (() -> Void)? = nil
    ) {
        stateLock.lock()
        guard !disconnectInProgress else {
            stateLock.unlock()
            return
        }
        disconnectInProgress = true
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let wasConnecting = connectInProgress
        let promptUserReadyClose = userInitiated && sessionReady
        connectInProgress = false
        pumpRunning = false
        sessionReady = false
        requestedPitch = Self.neutral
        requestedYaw = Self.neutral
        joystickActive = false
        controlUntilNs = 0
        forceNeutralPending = false
        recenterPending = false
        recenterAwaitingReply = false
        gimbalLockCommandPending = nil
        selfieFlipPending = false
        cameraRecordCommandPending = nil
        cameraRecordCommandTarget = nil
        cameraCommandQueue.removeAll(keepingCapacity: true)
        cameraRecordCommandDeadlineNs = 0
        lastCameraStatusFields = nil
        lastCameraStoragePushFields = nil
        lastBatteryStatusFields = nil
        smoothRecenterActive = false
        smoothInitialized = false
        smoothLastYawAbsErrorDeg = .nan
        smoothYawDivergenceSamples = 0
        foregroundRecoveryInProgress = false
        if userInitiated {
            backgroundResumeWanted = false
            lifecycleGeneration &+= 1
        }
        let tx = transport
        let stopped = pumpStopped
        let connectingStopped = connectWorkerStopped
        transport = nil
        pumpThread = nil
        pumpStopped = nil
        connectWorkerStopped = nil
        stateLock.unlock()

        transitionConnectionState(
            to: .disconnecting,
            reason: userInitiated ? "userDisconnect" : "sessionReplacement",
            generation: generation
        )
        os_signpost(
            .event,
            log: Self.connectionLog,
            name: "disconnect_start",
            "generation=%{public}d user=%{public}d",
            generation,
            userInitiated ? 1 : 0
        )
        log("Disconnect stage: pump stop requested open=\(tx?.isOpen == true)")
        publishBusy(true)
        publishSmoothRunning(false)
        publishFreshness(canCapture: false, canSmooth: false)
        publishStatus("正在断开 Pocket 3 数据连接…")
        publishVideoReceiving(false)
        // User disconnect already revoked PiP synchronously. A stale-session
        // replacement can originate off-main, so use the asynchronous reset.
        if !userInitiated {
            videoOutput.reset()
        }

        let thread = Thread { [weak self] in
            guard let self else {
                tx?.close()
                return
            }
            if let stopped {
                stopped.wait()
                self.log("Disconnect stage: UDP pump stopped")
            } else if wasConnecting, let connectingStopped {
                // Bring-up has no pump owner yet. Closing the pipe cancels its
                // bounded receive waits; wait for that worker before finalizing.
                tx?.close()
                connectingStopped.wait()
                self.log("Disconnect stage: connection worker stopped")
            }
            self.finishDisconnect(
                tx: tx,
                generation: generation,
                reason: reason,
                promptUserReadyClose: promptUserReadyClose,
                completion: completion
            )
        }
        thread.name = "Pocket3-Disconnect"
        thread.start()
    }

    private func finishDisconnect(
        tx: DumlTransport?,
        generation: Int,
        reason: String,
        promptUserReadyClose: Bool,
        completion: (() -> Void)?
    ) {
        if promptUserReadyClose {
            log("Disconnect stage: prompt transport close; no post-pump DUML")
        } else if let tx, tx.isOpen {
            // This runs only after the sole UDP pump owner has exited.
            sendGimbal(tx, pitch: Self.neutral, yaw: Self.neutral)
            log("Disconnect stage: final neutral submitted")

            // Retain the prior tail for non-user session replacement. The
            // experiment changes only a user disconnect from a ready session.
            for _ in 0..<8 {
                tx.sendDuml(
                    set: 0x01,
                    cmd: 0x01,
                    payload: Self.liveIdle,
                    receiverType: 0x01,
                    receiverId: 0,
                    cmdType: 0
                )
                Thread.sleep(forTimeInterval: 0.003)
            }
            log("Disconnect stage: LIVE_IDLE x8 submitted")

            let drainDeadline = nowNs() + 750_000_000
            var drainedDatagrams = 0
            while nowNs() < drainDeadline, tx.isOpen {
                drainedDatagrams += tx.recvBurst(durationMs: 12).count
                tx.sendAck()
            }
            log("Disconnect stage: RX/ACK drain complete datagrams=\(drainedDatagrams)")
        }

        tx?.close()
        log("Disconnect stage: transport closed")

        stateLock.lock()
        let stillCurrent = generation == connectionGeneration
        if stillCurrent {
            disconnectInProgress = false
        }
        stateLock.unlock()

        guard stillCurrent else { return }

        publishVideoReceiving(false)
        resetTelemetryState()
        publishConnected(false)
        publishBusy(false)
        publishStatus("数据连接已断开")
        log(reason)
        transitionConnectionState(to: .disconnected, reason: reason, generation: generation)
        os_signpost(
            .event,
            log: Self.connectionLog,
            name: "disconnect_complete",
            "generation=%{public}d",
            generation
        )
        completion?()
    }

    private func queuePostPiPVideoRefresh() {
        stateLock.lock()
        let ready = sessionReady
        if ready {
            foregroundPiPVideoRefreshPending = true
        }
        stateLock.unlock()

        if ready {
            log("Video: post-PiP 09/A8 refresh queued")
        }
    }

    /// Called when the scene enters the background. Do not tear down a healthy
    /// Pocket session immediately: a short app switch can often return before
    /// the camera discards the datalink. The pump will simply be suspended with
    /// the process and resume when iOS runs us again. Motion has already been
    /// neutralized by the scene's `.inactive` transition.
    func prepareForBackground() {
        videoOutput.prepareForBackground()

        stateLock.lock()
        lifecycleGeneration &+= 1
        backgroundResumeWanted = sessionReady || connectInProgress
        foregroundRecoveryInProgress = false
        foregroundPiPVideoRefreshPending = false
        requestedPitch = Self.neutral
        requestedYaw = Self.neutral
        joystickActive = false
        controlUntilNs = 0
        forceNeutralPending = true
        let shouldPreserve = backgroundResumeWanted
        stateLock.unlock()

        if shouldPreserve {
            transitionConnectionState(
                to: .backgroundPreserved,
                reason: "sceneBackground",
                generation: connectionGenerationSnapshot()
            )
            log("Lifecycle: app backgrounded; preserving Pocket datalink for media/PiP resume")
            publishStatus("应用在后台，相机媒体连接保持中")
        }
    }

    /// Called on foreground entry. A preserved session is accepted only if new
    /// Pocket traffic arrives after resume. ACK-window lag is diagnostic here:
    /// iOS can suspend the receive pump while PiP is off, leaving the last
    /// camera-reported ACK behind even though fresh telemetry and video resume.
    /// Otherwise the session is discarded and replaced with a fresh one.
    func resumeFromBackground() {
        stateLock.lock()
        guard backgroundResumeWanted else {
            stateLock.unlock()
            return
        }
        backgroundResumeWanted = false
        lifecycleGeneration &+= 1
        let lifecycleToken = lifecycleGeneration
        let ready = sessionReady
        let busy = connectInProgress
        let baselineTelemetryNs = lastTelemetryNs
        let baselineHeartbeatNs = lastHeartbeatReplyNs
        foregroundRecoveryInProgress = ready
        stateLock.unlock()

        if busy {
            log("Lifecycle: foreground return; existing connection attempt will continue")
            return
        }

        guard ready else {
            log("Lifecycle: foreground return found no ready datalink; opening fresh session")
            connect()
            return
        }

        log("Lifecycle: foreground return; probing preserved Pocket datalink")
        transitionConnectionState(
            to: .recovering,
            reason: "foregroundResume",
            generation: connectionGenerationSnapshot()
        )
        publishStatus("正在恢复 Pocket 3 控制…")

        let thread = Thread { [weak self] in
            self?.foregroundRecoveryWorker(
                lifecycleToken: lifecycleToken,
                baselineTelemetryNs: baselineTelemetryNs,
                baselineHeartbeatNs: baselineHeartbeatNs
            )
        }
        thread.name = "Pocket3-Foreground-Recovery"
        thread.start()
    }

    private func foregroundRecoveryWorker(
        lifecycleToken: Int,
        baselineTelemetryNs: UInt64,
        baselineHeartbeatNs: UInt64
    ) {
        let deadline = nowNs() + 1_750_000_000

        while nowNs() < deadline {
            stateLock.lock()
            let valid = lifecycleToken == lifecycleGeneration
                && foregroundRecoveryInProgress
                && sessionReady
            let telemetryAdvanced = lastTelemetryNs > baselineTelemetryNs
            let heartbeatAdvanced = lastHeartbeatReplyNs > baselineHeartbeatNs
            let tx = transport
            stateLock.unlock()

            guard valid else { return }

            let lag = tx?.txAckLagSlots ?? Int.max
            if Self.shouldAcceptPreservedSession(
                telemetryAdvanced: telemetryAdvanced,
                heartbeatAdvanced: heartbeatAdvanced
            ) {
                stateLock.lock()
                if lifecycleToken == lifecycleGeneration {
                    foregroundRecoveryInProgress = false
                }
                stateLock.unlock()

                let signal = telemetryAdvanced ? "fresh 04/05" : "fresh 04/50"
                log("Lifecycle: preserved datalink resumed (\(signal), txLag=\(lag))")

                // Experiment 2: Mimo capture evidence strongly associates 09/A8
                // with a fresh H.264 IDR tens of milliseconds later. Send one
                // lightweight refresh after a preserved background session is
                // proven alive, without rebuilding TCP/UDP or replaying the
                // full live-view START sequence.
                tx?.sendDuml(
                    set: 0x09, cmd: 0xA8, payload: Self.liveA8,
                    receiverType: 0x01, receiverId: 2, cmdType: 2
                )
                log("Video: foreground 09/A8 refresh sent after preserved-session proof")

                transitionConnectionState(
                    to: .ready,
                    reason: "foregroundFreshProof=\(signal)",
                    generation: connectionGenerationSnapshot()
                )
                publishStatus("已连接，摇杆已就绪")
                return
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        stateLock.lock()
        let stillCurrent = lifecycleToken == lifecycleGeneration
            && foregroundRecoveryInProgress
            && sessionReady
        if stillCurrent {
            foregroundRecoveryInProgress = false
        }
        stateLock.unlock()

        guard stillCurrent else { return }

        log("Lifecycle: preserved datalink did not recover promptly; opening fresh session")
        disconnectInternal(
            userInitiated: false,
            reason: "Datalink: stale after foreground resume; replacing session",
            completion: { [weak self] in self?.connect() }
        )
    }

    /// Fresh camera-originated DUML is the foreground liveness proof. The TX
    /// ACK lag must not veto it because pktType-01 ACK state can remain stale
    /// across ordinary iOS suspension while pktType-02 video and 04/05
    /// telemetry are already flowing again.
    static func shouldAcceptPreservedSession(
        telemetryAdvanced: Bool,
        heartbeatAdvanced: Bool
    ) -> Bool {
        telemetryAdvanced || heartbeatAdvanced
    }

    private func connectWorker(generation: Int) {
        // Close any prior transport without producing a second user-facing disconnect message.
        stateLock.lock()
        guard generation == connectionGeneration else {
            stateLock.unlock()
            return
        }
        pumpRunning = false
        sessionReady = false
        let old = transport
        transport = nil
        stateLock.unlock()
        old?.close()
        resetTelemetryState()

        for readinessAttempt in 1...2 {
            guard connectionAttemptIsCurrent(generation) else { return }

            if readinessAttempt == 2 {
                log("readiness attempt 2 starting fresh transport")
            }

            switch runReadinessAttempt(generation: generation, attempt: readinessAttempt) {
            case .ended:
                return

            case .noHeartbeat(let tx):
                log("readiness attempt \(readinessAttempt) failed")
                logReadinessFailureDiagnostics(tx, attempt: readinessAttempt)
                log("closing failed session")
                clearTransportIfCurrent(tx)
                tx.close()

                if readinessAttempt == 1 {
                    resetTelemetryState()
                    continue
                }

                fail("04/50 gimbal heartbeat got NO reply after one fresh retry; controller NOT marked ready", generation: generation)
                return

            case .ready(let tx, let heartbeat):
                finishReadyConnection(tx: tx, heartbeat: heartbeat, generation: generation)
                return
            }
        }
    }

    private func runReadinessAttempt(generation: Int, attempt: Int) -> ReadinessAttemptResult {
        transitionConnectionState(to: .bootstrappingTCP, reason: "directPocketProbe", generation: generation)
        os_signpost(
            .event,
            log: Self.connectionLog,
            name: "tcp_bootstrap_start",
            "generation=%{public}d",
            generation
        )
        tcpPoke()
        os_signpost(
            .event,
            log: Self.connectionLog,
            name: "tcp_bootstrap_end",
            "generation=%{public}d",
            generation
        )
        guard connectionAttemptIsCurrent(generation) else { return .ended }

        let tx = DumlTransport(log: { [weak self] message in
            self?.log(message)
        }, port: Self.udpPort)

        do {
            try tx.open(ip: Self.cameraIP)
        } catch {
            fail("UDP/9004 open failed: \(error)", generation: generation)
            return .ended
        }

        logReadinessTransportParameters(tx, attempt: attempt, stage: "opened")

        guard connectionAttemptIsCurrent(generation) else {
            tx.close()
            return .ended
        }

        stateLock.lock()
        guard generation == connectionGeneration else {
            stateLock.unlock()
            tx.close()
            return .ended
        }
        transport = tx
        stateLock.unlock()

        transitionConnectionState(to: .handshakingUDP, reason: "udpOpen", generation: generation)
        os_signpost(
            .event,
            log: Self.connectionLog,
            name: "udp_handshake_start",
            "generation=%{public}d",
            generation
        )
        let handshake = handshakeFrame(baseSeq: tx.baseSeq)
        guard tx.handshake(payload: handshake) != nil else {
            log("Datalink: UDP/9004 handshake exhausted attempts=\(tx.lastHandshakeAttemptCount)")
            tx.close()
            fail("UDP/9004 handshake FAILED", generation: generation)
            return .ended
        }
        guard connectionAttemptIsCurrent(generation) else {
            tx.close()
            return .ended
        }
        log("Datalink: UDP/9004 handshake OK attempts=\(tx.lastHandshakeAttemptCount)")
        os_signpost(
            .event,
            log: Self.connectionLog,
            name: "udp_handshake_succeeded",
            "generation=%{public}d attempts=%{public}d",
            generation,
            tx.lastHandshakeAttemptCount
        )
        transitionConnectionState(to: .registering, reason: "udpHandshakeSucceeded", generation: generation)

        // Exact Osmosis openDatalink pattern retained from frozen Android v0.14.3.
        for _ in 0..<5 {
            _ = tx.recvAll(durationMs: 400)
            tx.sendAck()
        }

        tx.syncSeqToPeerChannel()
        log(
            String(
                format: "Datalink: readiness attempt %d session=0x%04X base=0x%04X channel=0x%04X nextTx=0x%04X",
                attempt, tx.sessionId, tx.baseSeq, tx.cameraChannel, tx.udpSeq
            )
        )

        tx.sendDuml(
            set: 0x00,
            cmd: 0x81,
            payload: Pocket3Commands.appDeviceInfo,
            receiverType: 0x08,
            receiverId: 2,
            cmdType: 4
        )
        _ = tx.recvAll(durationMs: 400)
        tx.sendAck()
        log("Datalink: 00/81 APP device-info registration sent")
        os_signpost(.event, log: Self.connectionLog, name: "registration_00_81")

        tx.sendDuml(
            set: 0x00,
            cmd: 0x88,
            payload: Self.appPresence,
            receiverType: 0x08,
            receiverId: 1
        )
        _ = tx.recvAll(durationMs: 400)
        tx.sendAck()
        log("Datalink: 00/88 APP presence sent")

        tx.sendDuml(
            set: 0x03,
            cmd: 0xDA,
            payload: Self.gimbalInit,
            receiverType: 0x03,
            receiverId: 0
        )
        _ = tx.recvAll(durationMs: 400)
        tx.sendAck()
        log("Datalink: 03/DA gimbal init sent")

        tx.sendDuml(
            set: 0x04,
            cmd: 0x50,
            payload: Self.gimbalHeartbeat,
            receiverType: 0x04,
            receiverId: 0
        )
        let heartbeatReplies = tx.recvAll(durationMs: 600)
        tx.sendAck()

        guard let heartbeat = DumlFrameScanner.firstReply(in: heartbeatReplies, set: 0x04, cmd: 0x50) else {
            return .noHeartbeat(tx)
        }

        return .ready(transport: tx, heartbeat: heartbeat)
    }

    private func finishReadyConnection(tx: DumlTransport, heartbeat: Data, generation: Int) {
        // Start the capture-confirmed direct H.264 path only after the same
        // heartbeat health gate that marks the gimbal session usable.
        sendLiveStartSequence(tx)
        log("Video: capture-confirmed Mimo live-view START/IDLE sequence sent")

        stateLock.lock()
        guard generation == connectionGeneration else {
            stateLock.unlock()
            tx.close()
            return
        }
        lastHeartbeatReplyNs = nowNs()
        readyAtNs = lastHeartbeatReplyNs
        sessionReady = true
        connectInProgress = false
        pumpRunning = true
        requestedPitch = Self.neutral
        requestedYaw = Self.neutral
        joystickActive = false
        controlUntilNs = 0
        forceNeutralPending = false

        var readbackSubscriptionsQueued = 0
        for propertyName in Pocket3CameraPropertyBus.corePropertyNames {
            if let command = Pocket3CameraPropertyBus.subscriptionCommand(
                name: propertyName,
                transactionID: cameraPropertyTransactionID
            ) {
                cameraCommandQueue.append(command)
                readbackSubscriptionsQueued += 1
                cameraPropertyTransactionID &+= 1
            }
        }
        stateLock.unlock()

        log("Datalink: 04/50 gimbal heartbeat reply: \(heartbeat.hexString)")
        log("Camera readback: queued \(readbackSubscriptionsQueued) capture-derived 00/99 subscriptions")
        let readyDurationMs = connectionElapsedMs(at: readyAtNs)
        transitionConnectionState(
            to: .ready,
            reason: "fresh04/50 timeToReadyMs=\(readyDurationMs)",
            generation: generation
        )
        os_signpost(
            .event,
            log: Self.connectionLog,
            name: "connection_ready",
            "generation=%{public}d durationMs=%{public}llu",
            generation,
            readyDurationMs
        )
        publishConnected(true)
        publishBusy(false)
        publishStatus("已连接，摇杆已就绪")
        log("Pocket 3 gimbal ready. Osmosis-style UDP registration + control pump started.")

        videoOutput.startSession()
        startPump(tx, generation: generation)
    }

    private func clearTransportIfCurrent(_ tx: DumlTransport) {
        stateLock.lock()
        if transport === tx {
            transport = nil
        }
        stateLock.unlock()
    }

    private func logReadinessTransportParameters(_ tx: DumlTransport, attempt: Int, stage: String) {
        let localPort = tx.localSourcePort.map(String.init) ?? "unknown"
        log(
            String(
                format: "Datalink: readiness attempt %d %@ localUDP=%@ session=0x%04X base=0x%04X channel=0x%04X nextTx=0x%04X",
                attempt, stage, localPort, tx.sessionId, tx.baseSeq, tx.cameraChannel, tx.udpSeq
            )
        )
    }

    private func logReadinessFailureDiagnostics(_ tx: DumlTransport, attempt: Int) {
        let localPort = tx.localSourcePort.map(String.init) ?? "unknown"
        let lastInboundAge: String
        if tx.lastInboundNs == 0 {
            lastInboundAge = "never"
        } else {
            let now = nowNs()
            let ageMs = now >= tx.lastInboundNs ? (now - tx.lastInboundNs) / 1_000_000 : 0
            lastInboundAge = "\(ageMs)ms"
        }

        log(
            String(
                format: "Datalink: readiness attempt %d diagnostics localUDP=%@ session=0x%04X base=0x%04X channel=0x%04X nextTx=0x%04X inboundDatagrams=%d rejectedSessionDatagrams=%d lastInboundAge=%@ peerAckTx=0x%04X txLag=%d saw04/05=%@ sawPktType02Video=%@ saw00/81=%@ saw00/88=%@ sawOtherValidCameraDUML=%@",
                attempt,
                localPort,
                tx.sessionId,
                tx.baseSeq,
                tx.cameraChannel,
                tx.udpSeq,
                tx.inboundDatagramCount,
                tx.rejectedSessionDatagramCount,
                lastInboundAge,
                tx.peerAckedTxSeq,
                tx.txAckLagSlots,
                String(tx.sawBringUp0405),
                String(tx.sawBringUpType02Video),
                String(tx.sawBringUp0081),
                String(tx.sawBringUp0088),
                String(tx.sawBringUpOtherValidCameraDuml)
            )
        )
    }

    private func tcpPoke() {
        log("Datalink: TCP/7001 poke starting")

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi

        let connection = NWConnection(
            host: NWEndpoint.Host(Self.cameraIP),
            port: NWEndpoint.Port(rawValue: Self.tcpPokePort)!,
            using: parameters
        )

        let readySemaphore = DispatchSemaphore(value: 0)
        let callbackQueue = DispatchQueue(label: "Pocket3.TCPPoke")
        let resultLock = NSLock()
        var becameReady = false
        var failedText: String?

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                resultLock.lock()
                becameReady = true
                resultLock.unlock()
                readySemaphore.signal()

            case .failed(let error):
                resultLock.lock()
                failedText = error.localizedDescription
                resultLock.unlock()
                readySemaphore.signal()

            case .cancelled:
                readySemaphore.signal()

            default:
                break
            }
        }

        connection.start(queue: callbackQueue)

        let readyResult = readySemaphore.wait(timeout: .now() + 1.2)
        resultLock.lock()
        let ready = becameReady
        let failure = failedText
        resultLock.unlock()

        guard readyResult == .success, ready else {
            connection.cancel()
            log("Datalink: TCP/7001 poke failed: \(failure ?? "connect timeout") — continuing to UDP as Android does")
            return
        }

        let frame = Pocket3Commands.setPairingPin("osmo")
        let sendSemaphore = DispatchSemaphore(value: 0)
        let sendLock = NSLock()
        var sendError: NWError?

        connection.send(content: frame, completion: .contentProcessed { error in
            sendLock.lock()
            sendError = error
            sendLock.unlock()
            sendSemaphore.signal()
        })

        _ = sendSemaphore.wait(timeout: .now() + 1.0)
        sendLock.lock()
        let finalSendError = sendError
        sendLock.unlock()

        if let finalSendError {
            log("Datalink: TCP/7001 poke send failed: \(finalSendError.localizedDescription)")
        } else {
            log("Datalink: TCP/7001 pairing frame sent")
        }

        Thread.sleep(forTimeInterval: 0.400)
        connection.cancel()
    }

    private func sendLiveStartSequence(_ tx: DumlTransport) {
        func stateStart() {
            tx.sendDuml(
                set: 0x01, cmd: 0x01, payload: Self.liveStart,
                receiverType: 0x01, receiverId: 0, cmdType: 0
            )
        }

        func a8() {
            tx.sendDuml(
                set: 0x09, cmd: 0xA8, payload: Self.liveA8,
                receiverType: 0x01, receiverId: 2, cmdType: 2
            )
        }

        stateStart()
        Thread.sleep(forTimeInterval: 0.001)
        a8()
        Thread.sleep(forTimeInterval: 0.001)

        stateStart()
        Thread.sleep(forTimeInterval: 0.001)
        a8()
        Thread.sleep(forTimeInterval: 0.001)

        for _ in 0..<5 {
            stateStart()
            Thread.sleep(forTimeInterval: 0.002)
        }

        // Capture-confirmed: Mimo returns 01/01 to this normal/idle state
        // while pktType-0x02 video continues. Never use the old 03...07 01
        // playback transition as a live-view stop command.
        for _ in 0..<4 {
            tx.sendDuml(
                set: 0x01, cmd: 0x01, payload: Self.liveIdle,
                receiverType: 0x01, receiverId: 0, cmdType: 0
            )
            Thread.sleep(forTimeInterval: 0.002)
        }
    }

    // MARK: - Manual controls

    func setJoystick(pitch: Int, yaw: Int) {
        guard pitch >= 0, pitch <= 0xFFFF, yaw >= 0, yaw <= 0xFFFF else { return }

        var canceledSmooth = false
        var engaged = false

        stateLock.lock()
        guard sessionReady else {
            stateLock.unlock()
            return
        }

        if smoothRecenterActive {
            smoothRecenterActive = false
            smoothInitialized = false
            canceledSmooth = true
        }

        engaged = !joystickActive
        requestedPitch = pitch
        requestedYaw = yaw
        controlUntilNs = 0
        joystickActive = true
        stateLock.unlock()

        if canceledSmooth {
            publishSmoothRunning(false)
            log("Smooth recenter canceled: manual joystick took control")
        }
        if engaged {
            log("Virtual joystick engaged")
            publishStatus("摇杆控制中")
        }
    }

    func releaseJoystick() {
        var wasActive = false

        stateLock.lock()
        guard sessionReady else {
            stateLock.unlock()
            return
        }
        wasActive = joystickActive
        requestedPitch = Self.neutral
        requestedYaw = Self.neutral
        controlUntilNs = 0
        joystickActive = false
        stateLock.unlock()

        if wasActive {
            log("Virtual joystick released -> neutral")
            publishStatus("摇杆已松开，控制已归零")
        }
    }

    func neutral() {
        var canceledSmooth = false

        stateLock.lock()
        guard sessionReady else {
            stateLock.unlock()
            return
        }

        requestedPitch = Self.neutral
        requestedYaw = Self.neutral
        controlUntilNs = 0
        joystickActive = false
        forceNeutralPending = true

        if smoothRecenterActive {
            smoothRecenterActive = false
            smoothInitialized = false
            canceledSmooth = true
        }
        stateLock.unlock()

        if canceledSmooth {
            publishSmoothRunning(false)
            log("Smooth recenter canceled: STOP / NEUTRAL")
        }
        log("Neutral requested")
        publishStatus("已发送停止指令")
    }

    func noteJoystickProfile(_ mode: JoystickResponseMode) {
        releaseJoystick()
        log(mode.logText)
        publishStatus(mode.statusText)
    }

    /// Thread-safe read-only snapshot for v0.6 head tracking.
    /// This does not alter the proven transport/control pump. A caller can
    /// require a maximum telemetry age so stale feedback never drives motion.
    func latestTelemetrySnapshot(maxAgeMs: UInt64 = 350) -> GimbalTelemetry? {
        let now = nowNs()
        stateLock.lock()
        defer { stateLock.unlock() }

        guard sessionReady, let sample = latestTelemetrySample else { return nil }
        guard now >= sample.receivedAtNs else { return nil }
        let ageMs = (now - sample.receivedAtNs) / 1_000_000
        guard ageMs <= maxAgeMs else { return nil }
        return sample
    }

    // MARK: - Gimbal lock / follow

    /// Physically confirmed Pocket 3 software lock/follow control:
    /// - 04/4C 00 00 = lock
    /// - 04/4C 01 00 = return to follow
    ///
    /// The UI state is not changed optimistically here. It follows fresh 04/05
    /// telemetry, where mode 0x00 is the physically confirmed locked state.
    func setGimbalLocked(_ locked: Bool) {
        var canceledSmooth = false

        stateLock.lock()
        guard sessionReady else {
            stateLock.unlock()
            log("GIMBAL LOCK ERROR: not connected")
            return
        }

        requestedPitch = Self.neutral
        requestedYaw = Self.neutral
        controlUntilNs = 0
        joystickActive = false

        if smoothRecenterActive {
            smoothRecenterActive = false
            smoothInitialized = false
            canceledSmooth = true
        }

        // Latest explicit 04/4C UI action wins if native recenter was queued but
        // has not yet reached the transport pump.
        recenterPending = false
        gimbalLockCommandPending = locked
        stateLock.unlock()

        if canceledSmooth {
            publishSmoothRunning(false)
            log("Smooth recenter canceled: gimbal lock/follow requested")
        }

        log(locked ? "Gimbal LOCK requested (04/4C 00 00)" : "Gimbal FOLLOW requested (04/4C 01 00)")
        publishStatus(locked ? "已请求锁定云台…" : "已请求云台跟随…")
    }

    /// Queue the capture-confirmed DJI Mimo internal-record command on the
    /// existing single-owner UDP pump. UI state remains telemetry-driven; this
    /// method does not optimistically flip `isCameraRecording`.
    private func setCameraRecording(_ recording: Bool) {
        stateLock.lock()
        guard sessionReady else {
            stateLock.unlock()
            log("CAMERA RECORD ERROR: not connected")
            return
        }

        guard let current = latestCameraRecording,
              let statusByte = lastCameraRecordStatusByte else {
            stateLock.unlock()
            log("CAMERA RECORD ERROR: waiting for 02/80 recording state")
            return
        }

        guard cameraRecordCommandTarget == nil else {
            stateLock.unlock()
            log("CAMERA RECORD ignored: previous record command still in flight")
            return
        }

        guard !Pocket3CameraStatus.recordingTransitioning(statusByte: statusByte) else {
            stateLock.unlock()
            log(String(format: "CAMERA RECORD ignored: 02/80 transition active (0x%02X)", statusByte))
            return
        }

        guard current != recording else {
            stateLock.unlock()
            log(recording ? "CAMERA RECORD ignored: Pocket already recording" : "CAMERA RECORD ignored: Pocket already idle")
            return
        }

        cameraRecordCommandPending = recording
        cameraRecordCommandTarget = recording
        cameraRecordCommandDeadlineNs = nowNs() &+ Self.cameraRecordCommandTimeoutNs
        stateLock.unlock()

        publishCameraRecordCommandInFlight(true)
        log(recording ? "Camera RECORD START requested (02/02 01)" : "Camera RECORD STOP requested (02/02 00)")
        publishStatus(recording ? "正在开始录像…" : "正在停止录像…")
    }

    /// Queue one capture-confirmed camera-setting command on the existing single-owner UDP pump.
    /// Network state and DUML sequencing remain owned by the pump thread.
    private func sendCameraCommand(_ command: Pocket3CameraCommand) {
        stateLock.lock()
        guard sessionReady else {
            stateLock.unlock()
            log("CAMERA SETTING ERROR: not connected (\(command.label))")
            return
        }
        cameraCommandQueue.append(command)
        stateLock.unlock()

        log("Camera command queued: \(command.label) payload=\(command.payload.map { String(format: "%02X", $0) }.joined())")
    }

    /// Capture-confirmed DJI Mimo camera-facing toggle: 04/4C FE09.
    /// The same command toggles forward <-> selfie orientation.
    func toggleSelfieFacing() {
        stateLock.lock()
        guard sessionReady else {
            stateLock.unlock()
            log("SELFIE FLIP ERROR: not connected")
            return
        }
        selfieFlipPending = true
        stateLock.unlock()
        log("Selfie/forward flip requested (04/4C FE09)")
    }

    // MARK: - Native/smooth recenter

    func recenter() {
        var canceledSmooth = false

        stateLock.lock()
        guard sessionReady else {
            stateLock.unlock()
            log("NATIVE RECENTER ERROR: not connected")
            return
        }

        if smoothRecenterActive {
            smoothRecenterActive = false
            smoothInitialized = false
            canceledSmooth = true
        }

        requestedPitch = Self.neutral
        requestedYaw = Self.neutral
        controlUntilNs = 0
        joystickActive = false
        gimbalLockCommandPending = nil
        recenterPending = true
        stateLock.unlock()

        if canceledSmooth {
            publishSmoothRunning(false)
            log("Smooth recenter canceled: native recenter requested")
        }

        log("Native recenter requested (Mimo 04/4C FE08)")
        publishStatus("已请求云台回中…")
    }

    @discardableResult
    func captureCenter(windowMs: UInt64 = 800) -> Bool {
        guard let center = averageRecentTelemetry(windowMs: windowMs) else {
            log("CENTER CAPTURE FAILED: no fresh 04/05 samples in the last 0.8 sec")
            publishStatus("尚未收到最新云台姿态，无法记录中心")
            return false
        }

        stateLock.lock()
        capturedCenter = center
        stateLock.unlock()

        log(
            String(
                format: "CENTER CAPTURED from recent 04/05: pitch=%+.1f° roll=%+.1f° yaw=%+.1f° Ycont=%+.1f°",
                center.pitchDeg, center.rollDeg, center.yawDeg, center.yawContinuousDeg
            )
        )
        publishStatus("中心位置已记录")
        publishTelemetryAndCenter(now: nowNs(), force: true)
        return true
    }

    func smoothRecenterToCapturedCenter() {
        stateLock.lock()
        guard sessionReady else {
            stateLock.unlock()
            log("SMOOTH RECENTER ERROR: not connected")
            return
        }

        guard let target = capturedCenter else {
            stateLock.unlock()
            log("SMOOTH RECENTER ERROR: capture the native-recenter center first")
            publishStatus("请先记录中心位置，再平滑回中")
            return
        }

        guard let current = latestTelemetrySample else {
            stateLock.unlock()
            log("SMOOTH RECENTER ERROR: no 04/05 telemetry yet")
            publishStatus("缺少云台姿态，无法平滑回中")
            return
        }

        let age = telemetryAgeMsLocked(nowNs: nowNs())
        guard age <= Self.smoothStaleTelemetryMs else {
            stateLock.unlock()
            log("SMOOTH RECENTER ERROR: 04/05 telemetry is stale (\(age)ms)")
            publishStatus("云台姿态已过期，未启动平滑回中")
            return
        }

        requestedPitch = Self.neutral
        requestedYaw = Self.neutral
        controlUntilNs = 0
        joystickActive = false

        smoothTargetPitchDeg = target.pitchDeg
        smoothTargetYawContinuousDeg = target.yawContinuousDeg
        smoothInitialized = false
        smoothRecenterActive = true
        stateLock.unlock()

        log(
            String(
                format: "Smooth recenter requested: current P=%+.1f Y=%+.1f Ycont=%+.1f -> target P=%+.1f Ycont=%+.1f (04/01 + 04/05 closed loop; 04/14 NOT used)",
                current.pitchDeg, current.yawDeg, current.yawContinuousDeg,
                target.pitchDeg, target.yawContinuousDeg
            )
        )
        publishSmoothRunning(true)
        publishStatus("正在平滑返回已记录的中心…")
    }

    // MARK: - Single-owner UDP pump

    private func startPump(_ tx: DumlTransport, generation: Int) {
        let stopped = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            defer { stopped.signal() }
            self?.pumpLoop(tx)
        }
        thread.name = "Pocket3-UDP-Pump"
        stateLock.lock()
        guard generation == connectionGeneration,
              sessionReady,
              pumpRunning,
              !disconnectInProgress else {
            stateLock.unlock()
            return
        }
        pumpThread = thread
        pumpStopped = stopped
        stateLock.unlock()
        thread.start()
    }

    private func pumpLoop(_ tx: DumlTransport) {
        var nextAckFallback = nowNs() + 250_000_000
        var nextHeartbeat = nowNs() + 700_000_000
        var nextAppPresence = nowNs() + 900_000_000
        var nextControl = nowNs()
        var wasControlling = false
        var lastHealthLog: UInt64 = 0
        var heartbeatLostLogged = false
        var txWindowLagLogged = false

        var inboundDatagrams5s = 0
        var inboundPktTypeCounts: [Int: Int] = [:]
        var inboundDumlCounts: [Int: Int] = [:]

        while true {
            stateLock.lock()
            let shouldRun = pumpRunning && sessionReady
            stateLock.unlock()
            guard shouldRun, tx.isOpen else { break }

            let replies = tx.recvBurst(durationMs: 12)
            let now = nowNs()

            // Disconnect can occur while recvBurst() is in progress. Re-check the
            // session immediately so teardown cannot continue into ACK/heartbeat/
            // health calculations after telemetry state has already been cleared.
            stateLock.lock()
            let stillRunning = pumpRunning && sessionReady
            stateLock.unlock()
            guard stillRunning, tx.isOpen else { break }

            let inboundStats = recordInbound(replies, nowNs: now)
            inboundDatagrams5s += inboundStats.datagrams
            for (key, value) in inboundStats.packetTypes {
                inboundPktTypeCounts[key, default: 0] += value
            }
            for (key, value) in inboundStats.duml {
                inboundDumlCounts[key, default: 0] += value
            }

            if !replies.isEmpty {
                tx.sendAck()
                nextAckFallback = now + 250_000_000
            } else if now >= nextAckFallback {
                tx.sendAck()
                nextAckFallback = now + 250_000_000
            }

            if DumlFrameScanner.firstReply(in: replies, set: 0x04, cmd: 0x50) != nil {
                stateLock.lock()
                lastHeartbeatReplyNs = now
                stateLock.unlock()
                heartbeatLostLogged = false
            }

            stateLock.lock()
            let awaitingRecenter = recenterAwaitingReply
            stateLock.unlock()

            if awaitingRecenter,
               let nativeStatus = DumlFrameScanner.firstResponseStatus(in: replies, set: 0x04, cmd: 0x4C) {
                stateLock.lock()
                recenterAwaitingReply = false
                stateLock.unlock()
                log(String(format: "04/4C native recenter response status=0x%04X", nativeStatus))
            }

            if now >= nextHeartbeat {
                tx.sendDuml(
                    set: 0x04,
                    cmd: 0x50,
                    payload: Self.gimbalHeartbeat,
                    receiverType: 0x04,
                    receiverId: 0
                )
                nextHeartbeat = now + 1_000_000_000
            }

            if now >= nextAppPresence {
                tx.sendDuml(
                    set: 0x00,
                    cmd: 0x88,
                    payload: Self.appPresence,
                    receiverType: 0x08,
                    receiverId: 1
                )
                nextAppPresence = now + 1_000_000_000
            }

            stateLock.lock()
            let doPostPiPVideoRefresh = foregroundPiPVideoRefreshPending
            if foregroundPiPVideoRefreshPending {
                foregroundPiPVideoRefreshPending = false
            }
            stateLock.unlock()

            if doPostPiPVideoRefresh {
                tx.sendDuml(
                    set: 0x09, cmd: 0xA8, payload: Self.liveA8,
                    receiverType: 0x01, receiverId: 2, cmdType: 2
                )
                log("Video: post-PiP 09/A8 refresh sent")
            }

            stateLock.lock()
            let doRecenter = recenterPending
            if recenterPending {
                recenterPending = false
            }
            stateLock.unlock()

            if doRecenter {
                sendGimbal(tx, pitch: Self.neutral, yaw: Self.neutral)
                tx.sendDuml(
                    set: 0x04,
                    cmd: 0x4C,
                    payload: Self.recenterPayload,
                    receiverType: 0x04,
                    receiverId: 0,
                    cmdType: 2
                )
                stateLock.lock()
                recenterAwaitingReply = true
                stateLock.unlock()
                log("04/4C native recenter packet sent: fe08")
            }

            stateLock.lock()
            let requestedGimbalLock = gimbalLockCommandPending
            gimbalLockCommandPending = nil
            stateLock.unlock()

            if let locked = requestedGimbalLock {
                // Neutral first, on the same pump iteration, so a stale manual
                // command cannot race the mode transition.
                sendGimbal(tx, pitch: Self.neutral, yaw: Self.neutral)
                let payload = locked ? Self.gimbalLockPayload : Self.gimbalFollowPayload
                tx.sendDuml(
                    set: 0x04,
                    cmd: 0x4C,
                    payload: payload,
                    receiverType: 0x04,
                    receiverId: 0,
                    cmdType: 2
                )
                log(locked ? "04/4C gimbal LOCK packet sent: 0000" : "04/4C gimbal FOLLOW packet sent: 0100")
            }

            stateLock.lock()
            let doSelfieFlip = selfieFlipPending
            if selfieFlipPending {
                selfieFlipPending = false
            }
            stateLock.unlock()

            if doSelfieFlip {
                sendGimbal(tx, pitch: Self.neutral, yaw: Self.neutral)
                tx.sendDuml(
                    set: 0x04,
                    cmd: 0x4C,
                    payload: Data([0xFE, 0x09]),
                    receiverType: 0x04,
                    receiverId: 0,
                    cmdType: 2
                )
                log("04/4C selfie/forward toggle packet sent: fe09")
            }

            stateLock.lock()
            let requestedCameraRecording = cameraRecordCommandPending
            cameraRecordCommandPending = nil
            stateLock.unlock()

            if let recording = requestedCameraRecording {
                let command = Pocket3CameraStatus.recordingCommand(recording)
                tx.sendDuml(
                    set: command.set,
                    cmd: command.cmd,
                    payload: command.payload,
                    receiverType: command.receiverType,
                    receiverId: command.receiverId,
                    cmdType: command.cmdType
                )
                log(recording ? "02/02 camera RECORD START packet sent: 01" : "02/02 camera RECORD STOP packet sent: 00")
            }

            stateLock.lock()
            let cameraSettingCommand = cameraCommandQueue.isEmpty ? nil : cameraCommandQueue.removeFirst()
            stateLock.unlock()

            if let command = cameraSettingCommand {
                tx.sendDuml(
                    set: command.set,
                    cmd: command.cmd,
                    payload: command.payload,
                    receiverType: command.receiverType,
                    receiverId: command.receiverId,
                    cmdType: command.cmdType
                )
                log("Camera command sent: \(command.label)")
            }

            stateLock.lock()
            let doForceNeutral = forceNeutralPending
            if forceNeutralPending {
                forceNeutralPending = false
            }
            stateLock.unlock()

            if doForceNeutral {
                sendGimbal(tx, pitch: Self.neutral, yaw: Self.neutral)
                wasControlling = false
                log("04/01 forced neutral sent")
            }

            stateLock.lock()
            let smoothOwnsControl = smoothRecenterActive
            stateLock.unlock()

            if smoothOwnsControl {
                if now >= nextControl {
                    _ = driveSmoothRecenter(tx, now: now)
                    nextControl = now + 50_000_000
                }
                wasControlling = false
            } else {
                stateLock.lock()
                let until = controlUntilNs
                let active = joystickActive
                let pitch = requestedPitch
                let yaw = requestedYaw
                stateLock.unlock()

                let controlling = active || until > now
                if controlling, now >= nextControl {
                    sendGimbal(tx, pitch: pitch, yaw: yaw)
                    if !wasControlling {
                        log("04/01 stream started: pitch=\(pitch) yaw=\(yaw)")
                    }
                    wasControlling = true
                    nextControl = now + 50_000_000
                } else if !controlling, wasControlling {
                    sendGimbal(tx, pitch: Self.neutral, yaw: Self.neutral)

                    stateLock.lock()
                    requestedPitch = Self.neutral
                    requestedYaw = Self.neutral
                    controlUntilNs = 0
                    stateLock.unlock()

                    wasControlling = false
                    log("04/01 neutral sent after joystick/pulse")
                }
            }

            let txLag = tx.txAckLagSlots
            if txLag > 24, !txWindowLagLogged {
                txWindowLagLogged = true
                log("WARNING: reliable TX window lag grew to \(txLag) slots; \(transportSnapshot(tx))")
            } else if txLag <= 4 {
                txWindowLagLogged = false
            }

            let hbAge = heartbeatAgeMs(nowNs: now)
            if hbAge > 3000, !heartbeatLostLogged {
                heartbeatLostLogged = true
                log("WARNING: no 04/50 heartbeat reply for \(hbAge)ms; 04/05 age=\(displayAge(telemetryAgeMs(nowNs: now))); \(transportSnapshot(tx))")
            }

            publishTelemetryAndCenter(now: now, force: false)
            publishFreshnessIfNeeded(now: now)

            if now - lastHealthLog >= 5_000_000_000 {
                lastHealthLog = now

                let packetSummary = inboundPktTypeCounts
                    .sorted { $0.key < $1.key }
                    .map { String(format: "%02X=%d", $0.key, $0.value) }
                    .joined(separator: " ")

                let dumlSummary = inboundDumlCounts
                    .sorted { lhs, rhs in
                        if lhs.value == rhs.value { return lhs.key < rhs.key }
                        return lhs.value > rhs.value
                    }
                    .prefix(10)
                    .map { entry in
                        let set = (entry.key >> 8) & 0xFF
                        let cmd = entry.key & 0xFF
                        return String(format: "%02X/%02X=%d", set, cmd, entry.value)
                    }
                    .joined(separator: " ")

                let lifecycle = connectionDiagnosticSnapshot(nowNs: now)
                let videoAge = videoOutput.lastSampleAgeMs(nowNs: now)
                log(
                    "Session diag/5s: state=\(lifecycle.state) generation=\(lifecycle.generation) " +
                    "freshInboundAge=\(displayAge(lifecycle.inboundAgeMs)) videoAge=\(displayAge(videoAge)) " +
                    "pumpAlive=\(Thread.current.isExecuting) hbAge=\(displayAge(hbAge)) 04/05Age=\(displayAge(telemetryAgeMs(nowNs: now))) " +
                    "datagrams=\(inboundDatagrams5s) pktTypes[\(packetSummary.isEmpty ? "none" : packetSummary)] " +
                    "DUML[\(dumlSummary.isEmpty ? "none" : dumlSummary)] \(transportSnapshot(tx))"
                )

                inboundDatagrams5s = 0
                inboundPktTypeCounts.removeAll(keepingCapacity: true)
                inboundDumlCounts.removeAll(keepingCapacity: true)
            }
        }

        log("Transport pump stopped")
    }

    // MARK: - Smooth recenter controller

    private func smoothAxisOffset(errorDeg: Double) -> Int {
        let magnitude = abs(errorDeg)
        if magnitude <= Self.smoothDeadbandDeg { return 0 }

        let raw = Double(Self.smoothMinOffset) +
            (magnitude - Self.smoothDeadbandDeg) * Self.smoothGainPerDeg
        let clamped = Int(raw.rounded()).clamped(to: Self.smoothMinOffset...Self.smoothMaxOffset)
        return errorDeg > 0 ? clamped : -clamped
    }

    @discardableResult
    private func driveSmoothRecenter(_ tx: DumlTransport, now: UInt64) -> Bool {
        stateLock.lock()
        guard smoothRecenterActive else {
            stateLock.unlock()
            return false
        }

        guard let sample = latestTelemetrySample else {
            stateLock.unlock()
            finishSmoothRecenterInPump(tx, success: false, reason: "telemetry stale (none)")
            return false
        }

        let ageMs = telemetryAgeMsLocked(nowNs: now)
        guard ageMs <= Self.smoothStaleTelemetryMs else {
            stateLock.unlock()
            finishSmoothRecenterInPump(tx, success: false, reason: "telemetry stale (\(ageMs)ms)")
            return false
        }

        if !smoothInitialized {
            smoothInitialized = true
            smoothStartNs = now
            smoothLastProgressNs = now
            smoothBestErrorDeg = .infinity
            smoothLastSampleNs = 0
            smoothSettledSamples = 0
            smoothLastYawAbsErrorDeg = .nan
            smoothYawDivergenceSamples = 0
        }

        let elapsedMs = (now - smoothStartNs) / 1_000_000
        if elapsedMs > Self.smoothTimeoutMs {
            stateLock.unlock()
            finishSmoothRecenterInPump(tx, success: false, reason: "timeout after \(elapsedMs)ms")
            return false
        }

        if tx.txAckLagSlots > Self.smoothMaxTxLagSlots {
            let lag = tx.txAckLagSlots
            stateLock.unlock()
            finishSmoothRecenterInPump(tx, success: false, reason: "transport TX lag=\(lag) slots")
            return false
        }

        let pitchError = Self.wrappedAngleError(targetDeg: smoothTargetPitchDeg, currentDeg: sample.pitchDeg)
        // Continuous yaw is intentionally NOT reduced to shortest circular error.
        let yawError = smoothTargetYawContinuousDeg - sample.yawContinuousDeg
        let totalError = hypot(pitchError, yawError)

        if sample.receivedAtNs != smoothLastSampleNs {
            smoothLastSampleNs = sample.receivedAtNs

            if abs(pitchError) <= Self.smoothDeadbandDeg,
               abs(yawError) <= Self.smoothDeadbandDeg {
                smoothSettledSamples += 1
            } else {
                smoothSettledSamples = 0
            }

            if smoothSettledSamples >= Self.smoothSettleSamples {
                stateLock.unlock()
                finishSmoothRecenterInPump(
                    tx,
                    success: true,
                    reason: String(
                        format: "settled P=%+.1f Y=%+.1f errors P=%+.1f Y=%+.1f",
                        sample.pitchDeg, sample.yawDeg, pitchError, yawError
                    )
                )
                return false
            }

            if totalError + Self.smoothProgressEpsilonDeg < smoothBestErrorDeg {
                smoothBestErrorDeg = totalError
                smoothLastProgressNs = now
            } else if totalError > 2.0,
                      (now - smoothLastProgressNs) / 1_000_000 > Self.smoothProgressTimeoutMs {
                stateLock.unlock()
                finishSmoothRecenterInPump(
                    tx,
                    success: false,
                    reason: String(
                        format: "no progress for %dms; errors P=%+.1f Y=%+.1f",
                        Self.smoothProgressTimeoutMs, pitchError, yawError
                    )
                )
                return false
            }

            let yawAbs = abs(yawError)
            if !smoothLastYawAbsErrorDeg.isNaN,
               yawAbs > Self.smoothDivergenceMinErrorDeg {
                if yawAbs > smoothLastYawAbsErrorDeg + Self.smoothDivergenceStepDeg {
                    smoothYawDivergenceSamples += 1
                } else if yawAbs <= smoothLastYawAbsErrorDeg + 0.2 {
                    smoothYawDivergenceSamples = 0
                }

                if smoothYawDivergenceSamples >= Self.smoothDivergenceSamples {
                    let target = smoothTargetYawContinuousDeg
                    stateLock.unlock()
                    finishSmoothRecenterInPump(
                        tx,
                        success: false,
                        reason: String(
                            format: "yaw error diverging; Ycont=%+.1f target=%+.1f error=%+.1f",
                            sample.yawContinuousDeg, target, yawError
                        )
                    )
                    return false
                }
            } else {
                smoothYawDivergenceSamples = 0
            }
            smoothLastYawAbsErrorDeg = yawAbs
        }

        let pitchOffset = smoothAxisOffset(errorDeg: pitchError)
        let yawOffset = smoothAxisOffset(errorDeg: yawError)
        let pitchCommand = (Self.neutral - pitchOffset)
            .clamped(to: (Self.neutral - Self.smoothMaxOffset)...(Self.neutral + Self.smoothMaxOffset))
        let yawCommand = (Self.neutral + yawOffset)
            .clamped(to: (Self.neutral - Self.smoothMaxOffset)...(Self.neutral + Self.smoothMaxOffset))
        stateLock.unlock()

        // Re-check ownership after releasing the lock so a manual joystick/STOP cannot be ignored.
        stateLock.lock()
        let stillActive = smoothRecenterActive
        stateLock.unlock()
        guard stillActive else { return false }

        sendGimbal(tx, pitch: pitchCommand, yaw: yawCommand)
        return true
    }

    private func finishSmoothRecenterInPump(_ tx: DumlTransport, success: Bool, reason: String) {
        stateLock.lock()
        smoothRecenterActive = false
        smoothInitialized = false
        requestedPitch = Self.neutral
        requestedYaw = Self.neutral
        controlUntilNs = 0
        joystickActive = false
        stateLock.unlock()

        sendGimbal(tx, pitch: Self.neutral, yaw: Self.neutral)
        publishSmoothRunning(false)
        publishStatus(success ? "平滑回中完成" : "平滑回中已中止")
        log("Smooth recenter \(success ? "COMPLETE" : "ABORTED"): \(reason); neutral sent")
    }

    // MARK: - Telemetry

    private struct InboundStats {
        var datagrams = 0
        var packetTypes: [Int: Int] = [:]
        var duml: [Int: Int] = [:]
    }

    private func recordInbound(_ datagrams: [Data], nowNs: UInt64) -> InboundStats {
        var stats = InboundStats()

        if !datagrams.isEmpty {
            stateLock.lock()
            lastInboundNs = nowNs
            stateLock.unlock()
        }

        for datagram in datagrams {
            stats.datagrams += 1
            if datagram.count >= 7 {
                let packetType = Int(datagram[6])
                stats.packetTypes[packetType, default: 0] += 1
                if packetType == 0x02 {
                    videoOutput.feed(datagram: datagram)
                }
            }

            for frame in DumlFrameScanner.scan(datagram) {
                let key = (Int(frame.set) << 8) | Int(frame.cmd)
                stats.duml[key, default: 0] += 1

                if frame.set == 0x00, frame.cmd == 0x99,
                   let property = Pocket3CameraPropertyBus.parsePush(frame.payload),
                   Pocket3CameraPropertyBus.corePropertyNames.contains(property.name) {
                    stateLock.lock()
                    let previousValue = lastCameraPropertyValues[property.name]
                    let changed = previousValue != property.value
                    if changed {
                        lastCameraPropertyValues[property.name] = property.value
                    }
                    stateLock.unlock()

                    if changed {
                        publishCameraReadback(property)
                        let valueHex = property.value.map { String(format: "%02X", $0) }.joined()
                        log("Camera readback 00/99 \(property.name): \(valueHex)")
                    }
                    continue
                }

                if frame.set == 0x02, frame.cmd == 0x80,
                   let telemetry = Pocket3TelemetryParser.cameraStatus(payload: frame.payload) {
                    let statusByte = telemetry.statusByte
                    let recording = telemetry.recording
                    let transitioning = telemetry.transitioning
                    let recordStateNowNs = nowNs
                    let statusFields = telemetry.fields

                    stateLock.lock()
                    let previousRecording = latestCameraRecording
                    let previousStatusByte = lastCameraRecordStatusByte
                    latestCameraRecording = recording
                    lastCameraRecordStatusByte = statusByte
                    let previousStatusFields = lastCameraStatusFields
                    if let statusFields {
                        lastCameraStatusFields = statusFields
                    }

                    var clearRecordCommandInFlight = false
                    var recordCommandTimedOut = false
                    if let target = cameraRecordCommandTarget {
                        if Pocket3CameraStatus.recordRequestResolved(
                            targetRecording: target,
                            statusByte: statusByte
                        ) {
                            cameraRecordCommandPending = nil
                            cameraRecordCommandTarget = nil
                            cameraRecordCommandDeadlineNs = 0
                            clearRecordCommandInFlight = true
                        } else if cameraRecordCommandDeadlineNs != 0,
                                  recordStateNowNs >= cameraRecordCommandDeadlineNs {
                            cameraRecordCommandPending = nil
                            cameraRecordCommandTarget = nil
                            cameraRecordCommandDeadlineNs = 0
                            clearRecordCommandInFlight = true
                            recordCommandTimedOut = true
                        }
                    }
                    stateLock.unlock()

                    if clearRecordCommandInFlight {
                        publishCameraRecordCommandInFlight(false)
                        if recordCommandTimedOut {
                            log("CAMERA RECORD WARNING: command-in-flight guard timed out waiting for 02/80 change")
                        }
                    }

                    if previousRecording == nil || previousRecording != recording {
                        publishCameraRecording(recording)
                    }

                    publishCameraRecordingTransition(transitioning)

                    if previousStatusByte == nil || previousStatusByte != statusByte {
                        log(
                            "Camera 02/80 state: " +
                            "\(Pocket3CameraStatus.recordingDescription(statusByte: statusByte)) " +
                            String(format: "(0x%02X, REC bit=%@)", statusByte, recording ? "set" : "clear")
                        )
                    }

                    if let statusFields {
                        publishCameraStatusFields(statusFields)
                        if previousStatusFields == nil || previousStatusFields != statusFields {
                            log(
                                "Camera 02/80 status: " +
                                "storage=\(statusFields.storageFreeMiB)/\(statusFields.storageTotalMiB) MiB free/total " +
                                "remaining=\(statusFields.remainingRecordSeconds)s " +
                                "elapsed=\(statusFields.elapsedRecordSeconds)s " +
                                String(format: "mode=0x%02X videoLike=%@", statusFields.shootingMode, statusFields.videoLike ? "yes" : "no")
                            )
                        }
                    }
                    continue
                }

                if frame.set == 0x02, frame.cmd == 0xDC,
                   let storageFields = Pocket3TelemetryParser.storage(payload: frame.payload) {
                    stateLock.lock()
                    let previousStorageFields = lastCameraStoragePushFields
                    lastCameraStoragePushFields = storageFields
                    stateLock.unlock()

                    if previousStorageFields == nil || previousStorageFields != storageFields {
                        log(
                            "Camera 02/DC storage: " +
                            "stores=\(storageFields.storeCount) " +
                            "SD=\(storageFields.sdFreeMiB)/\(storageFields.sdTotalMiB) MiB free/total"
                        )
                    }
                    continue
                }

                if frame.set == 0x0D, frame.cmd == 0x02 {
                    if let fields = Pocket3TelemetryParser.battery(payload: frame.payload) {
                        stateLock.lock()
                        let previousFields = lastBatteryStatusFields
                        lastBatteryStatusFields = fields
                        stateLock.unlock()

                        if previousFields != fields {
                            publishBatteryStatus(fields)
                            let chargingText = fields.isCharging.map { $0 ? "yes" : "no" } ?? "unknown"
                            log("Battery 0D/02: \(fields.percent)% charging=\(chargingText)")
                        }
                    }
                    continue
                }

                guard frame.set == 0x04, frame.cmd == 0x05,
                      let telemetry = Pocket3TelemetryParser.gimbal(payload: frame.payload) else {
                    continue
                }

                stateLock.lock()
                let sample = yawReducer.reduce(telemetry, receivedAtNs: nowNs)

                let previousLocked = latestTelemetrySample?.mode == 0x00
                let currentLocked = sample.mode == 0x00
                let lockStateChanged = latestTelemetrySample == nil || previousLocked != currentLocked

                latestTelemetrySample = sample
                lastTelemetryNs = nowNs
                telemetryHistory.append(sample)
                let cutoff = nowNs > 2_000_000_000 ? nowNs - 2_000_000_000 : 0
                telemetryHistory.removeAll { $0.receivedAtNs < cutoff }

                let shouldLog = nowNs - lastTelemetryLogNs >= 1_000_000_000
                if shouldLog {
                    lastTelemetryLogNs = nowNs
                }
                stateLock.unlock()

                if lockStateChanged {
                    publishGimbalLocked(currentLocked)
                    if currentLocked {
                        log("Gimbal state confirmed LOCKED by 04/05 mode 0x00")
                    } else if previousLocked {
                        log("Gimbal state left locked mode; 04/05 mode=\(sample.mode.map { String(format: "0x%02X", $0) } ?? "--")")
                    }
                }

                if shouldLog {
                    log(
                        String(
                            format: "GIMBAL 04/05: pitch=%+.1f° roll=%+.1f° yaw=%+.1f° Ycont=%+.1f° mode=%@ limits=%@",
                            sample.pitchDeg,
                            sample.rollDeg,
                            sample.yawDeg,
                            sample.yawContinuousDeg,
                            sample.mode.map { String(format: "0x%02X", $0) } ?? "--",
                            limitSummary(sample)
                        )
                    )
                }
            }
        }

        return stats
    }

    private func averageRecentTelemetry(windowMs: UInt64) -> GimbalTelemetry? {
        let now = nowNs()
        let minNs = now > windowMs * 1_000_000 ? now - windowMs * 1_000_000 : 0

        stateLock.lock()
        let samples = telemetryHistory.filter { $0.receivedAtNs >= minNs }
        stateLock.unlock()

        guard !samples.isEmpty else { return nil }

        return GimbalTelemetry(
            pitchDeg: Self.circularMeanDeg(samples.map(\.pitchDeg)),
            rollDeg: samples.map(\.rollDeg).reduce(0, +) / Double(samples.count),
            yawDeg: Self.circularMeanDeg(samples.map(\.yawDeg)),
            yawContinuousDeg: samples.map(\.yawContinuousDeg).reduce(0, +) / Double(samples.count),
            mode: samples.last?.mode,
            limitFlags: samples.last?.limitFlags,
            receivedAtNs: now
        )
    }

    private func publishTelemetryAndCenter(now: UInt64, force: Bool) {
        stateLock.lock()

        // `now` is captured by the caller before taking stateLock. A forced
        // publish from Set Center can race the UDP pump: the pump may acquire
        // the lock first with a newer timestamp. Never subtract a newer stored
        // UInt64 timestamp from an older caller timestamp (Swift traps on
        // unsigned underflow), and never move the publish clock backwards.
        if now < lastTelemetryPublishNs {
            stateLock.unlock()
            return
        }

        if !force, now - lastTelemetryPublishNs < 250_000_000 {
            stateLock.unlock()
            return
        }
        lastTelemetryPublishNs = now

        let sample = latestTelemetrySample
        let center = capturedCenter
        let age = telemetryAgeMsLocked(nowNs: now)
        stateLock.unlock()

        guard let sample else {
            DispatchQueue.main.async { [weak self] in
                self?.telemetryText = "等待云台姿态数据"
            }
            return
        }

        let telemetry =
            String(
                format: "俯仰=%+.1f° 横滚=%+.1f° 水平=%+.1f° 连续水平=%+.1f°\n数据时效=%@ 模式=%@ 限位：%@",
                sample.pitchDeg,
                sample.rollDeg,
                sample.yawDeg,
                sample.yawContinuousDeg,
                displayAge(age),
                sample.mode.map { String(format: "0x%02X", $0) } ?? "--",
                limitSummary(sample)
            )

        let centerDisplay: String
        if let center {
            let pitchError = Self.wrappedAngleError(targetDeg: center.pitchDeg, currentDeg: sample.pitchDeg)
            let yawError = center.yawContinuousDeg - sample.yawContinuousDeg
            centerDisplay = String(
                format: "已记录中心：俯仰=%+.1f° 水平=%+.1f° 连续水平=%+.1f° 当前偏差：俯仰=%+.1f° 水平=%+.1f°",
                center.pitchDeg,
                center.yawDeg,
                center.yawContinuousDeg,
                pitchError,
                yawError
            )
        } else {
            centerDisplay = "尚未记录中心位置"
        }

        DispatchQueue.main.async { [weak self] in
            self?.telemetryText = telemetry
            self?.centerText = centerDisplay
        }
    }

    private func publishFreshnessIfNeeded(now: UInt64) {
        stateLock.lock()
        if now - lastFreshnessPublishNs < 250_000_000 {
            stateLock.unlock()
            return
        }
        lastFreshnessPublishNs = now
        let age = telemetryAgeMsLocked(nowNs: now)
        let hasCenter = capturedCenter != nil
        let ready = sessionReady
        stateLock.unlock()

        publishFreshness(
            canCapture: ready && age < 500,
            canSmooth: ready && age < Self.smoothStaleTelemetryMs && hasCenter
        )
    }

    func telemetryAgeMs(nowNs: UInt64? = nil) -> UInt64 {
        let now = nowNs ?? self.nowNs()
        stateLock.lock()
        let age = telemetryAgeMsLocked(nowNs: now)
        stateLock.unlock()
        return age
    }

    private func telemetryAgeMsLocked(nowNs: UInt64) -> UInt64 {
        guard lastTelemetryNs != 0 else { return UInt64.max }
        return nowNs >= lastTelemetryNs ? (nowNs - lastTelemetryNs) / 1_000_000 : 0
    }

    private func heartbeatAgeMs(nowNs: UInt64) -> UInt64 {
        stateLock.lock()
        let last = lastHeartbeatReplyNs
        stateLock.unlock()
        guard last != 0 else { return UInt64.max }
        return nowNs >= last ? (nowNs - last) / 1_000_000 : 0
    }

    // MARK: - Command helpers

    private func sendGimbal(_ tx: DumlTransport, pitch: Int, yaw: Int) {
        tx.sendDuml(
            set: 0x04,
            cmd: 0x01,
            payload: Self.gimbalPayload(pitch: pitch, yaw: yaw),
            receiverType: 0x04,
            receiverId: 0,
            cmdType: 0
        )
    }

    static func gimbalPayload(pitch: Int, yaw: Int) -> Data {
        Data([
            UInt8(pitch & 0xFF),
            UInt8((pitch >> 8) & 0xFF),
            0x00, 0x00,
            UInt8(yaw & 0xFF),
            UInt8((yaw >> 8) & 0xFF),
            0x00, 0x80, 0x22, 0x00
        ])
    }

    private func handshakeFrame(baseSeq: Int) -> Data {
        var data = Data(hex:
            "000064006400c005140000640000019001c005140000640014006400c00514000064000101040102"
        )
        data[0] = UInt8(baseSeq & 0xFF)
        data[1] = UInt8((baseSeq >> 8) & 0xFF)
        return data
    }

    private func transportSnapshot(_ tx: DumlTransport) -> String {
        String(
            format: "nextTx=0x%04X lastTx=0x%04X peerAckTx=0x%04X lag=%d rx02=0x%04X rx03=0x%04X camCh=0x%04X base=0x%04X cmdCount=%d",
            tx.udpSeq,
            tx.lastTxSeq,
            tx.peerAckedTxSeq,
            tx.txAckLagSlots,
            tx.rxType2Seq,
            tx.rxType3Seq,
            tx.cameraChannel,
            tx.baseSeq,
            tx.cmdCounter
        )
    }

    // MARK: - Pure math/decode helpers

    static func wrappedAngleError(targetDeg: Double, currentDeg: Double) -> Double {
        Pocket3YawReducer.wrappedAngleError(targetDeg: targetDeg, currentDeg: currentDeg)
    }

    private static func circularMeanDeg(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        var x = 0.0
        var y = 0.0
        for value in values {
            let radians = value * .pi / 180.0
            x += cos(radians)
            y += sin(radians)
        }
        return atan2(y, x) * 180.0 / .pi
    }

    private static func u16le(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32le(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private func limitSummary(_ telemetry: GimbalTelemetry) -> String {
        guard let flags = telemetry.limitFlags else { return "unknown" }
        return String(
            format: "0x%02X[P=%@ R=%@ Y=%@ stuck=%@]",
            flags,
            telemetry.pitchAtLimit ? "LIMIT" : "ok",
            telemetry.rollAtLimit ? "LIMIT" : "ok",
            telemetry.yawAtLimit ? "LIMIT" : "ok",
            telemetry.stuck ? "YES" : "no"
        )
    }

    private func displayAge(_ ms: UInt64) -> String {
        ms == UInt64.max ? "none" : "\(ms)ms"
    }

    // MARK: - UI/logging helpers

    private func resetTelemetryState() {
        stateLock.lock()
        latestTelemetrySample = nil
        telemetryHistory.removeAll(keepingCapacity: true)
        lastTelemetryNs = 0
        lastTelemetryLogNs = 0
        lastTelemetryPublishNs = 0
        lastFreshnessPublishNs = 0
        latestCameraRecording = nil
        lastCameraRecordStatusByte = nil
        lastCameraPropertyValues.removeAll(keepingCapacity: true)
        lastBatteryStatusFields = nil
        yawReducer.reset()
        capturedCenter = nil
        lastHeartbeatReplyNs = 0
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.telemetryText = "等待云台姿态数据"
            self?.centerText = "尚未记录中心位置"
            self?.isGimbalLocked = false
            self?.cameraState = Pocket3CameraState()
            self?.cameraBatteryPercent = nil
            self?.cameraBatteryCharging = nil
        }
    }

    private func connectionAttemptIsCurrent(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == connectionGeneration && connectInProgress
    }

    private func connectionGenerationSnapshot() -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connectionGeneration
    }

    private func connectionElapsedMs(at timestampNs: UInt64) -> UInt64 {
        stateLock.lock()
        let start = connectStartedNs
        stateLock.unlock()
        guard start != 0, timestampNs >= start else { return 0 }
        return (timestampNs - start) / 1_000_000
    }

    private func connectionDiagnosticSnapshot(
        nowNs: UInt64
    ) -> (state: String, generation: Int, inboundAgeMs: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let inboundAge: UInt64
        if lastInboundNs == 0 {
            inboundAge = UInt64.max
        } else {
            inboundAge = nowNs >= lastInboundNs ? (nowNs - lastInboundNs) / 1_000_000 : 0
        }
        return (connectionState.rawValue, connectionGeneration, inboundAge)
    }

    private func transitionConnectionState(
        to newState: ConnectionState,
        reason: String,
        generation: Int
    ) {
        stateLock.lock()
        let oldState = connectionState
        connectionState = newState
        stateLock.unlock()

        log(
            "Conn state: \(oldState.rawValue) -> \(newState.rawValue) " +
            "reason=\(reason) generation=\(generation)"
        )
        os_signpost(
            .event,
            log: Self.connectionLog,
            name: "connection_state",
            "generation=%{public}d",
            generation
        )
    }

    private func handleFirstVideo() {
        publishVideoReceiving(true)

        stateLock.lock()
        let generation = connectionGeneration
        let shouldLog = firstVideoLoggedGeneration != generation
        if shouldLog {
            firstVideoLoggedGeneration = generation
        }
        let start = connectStartedNs
        stateLock.unlock()

        guard shouldLog else { return }
        let now = nowNs()
        let elapsedMs = start != 0 && now >= start ? (now - start) / 1_000_000 : 0
        log("Connection milestone: firstVideo generation=\(generation) timeToFirstVideoMs=\(elapsedMs)")
        os_signpost(
            .event,
            log: Self.connectionLog,
            name: "first_video",
            "generation=%{public}d durationMs=%{public}llu",
            generation,
            elapsedMs
        )
    }

    private func fail(_ message: String, generation: Int? = nil) {
        stateLock.lock()
        if let generation, generation != connectionGeneration {
            stateLock.unlock()
            return
        }
        connectInProgress = false
        pumpRunning = false
        sessionReady = false
        let tx = transport
        transport = nil
        stateLock.unlock()

        tx?.close()
        log("CONNECTION ERROR: \(message)")
        transitionConnectionState(
            to: .failed,
            reason: message,
            generation: generation ?? connectionGenerationSnapshot()
        )
        publishConnected(false)
        publishBusy(false)
        publishSmoothRunning(false)
        publishFreshness(canCapture: false, canSmooth: false)
        publishStatus("连接失败，请查看数据连接日志")
        DispatchQueue.main.async { [weak self] in
            self?.onTerminalConnectionFailure?(message)
        }
    }

    private func nowNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func clearLog() {
        logLock.lock()
        logLines.removeAll(keepingCapacity: true)
        logLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.logText = ""
        }
    }

    func beginDiagnosticTest() {
        clearLog()
        log("=== NEW DIAGNOSTIC TEST ===")
    }

    private func log(_ message: String) {
        logLock.lock()
        let line = "\(timestampFormatter.string(from: Date()))  \(message)"
        logLines.append(line)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
        let rendered = logLines.joined(separator: "\n")
        logLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.logText = rendered
        }
        print(line)
    }

    private func publishStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.status = text }
    }

    private func publishBusy(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in self?.isBusy = value }
    }

    private func publishVideoReceiving(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.videoReceiving = value
        }
    }

    private func publishConnected(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in self?.isConnected = value }
    }

    private func publishSmoothRunning(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in self?.smoothRecenterRunning = value }
    }

    private func publishGimbalLocked(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in self?.isGimbalLocked = value }
    }

    private func publishCameraRecording(_ value: Bool?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = self.cameraState
            next.recording = value
            self.cameraState = next
        }
    }

    private func publishCameraRecordingTransition(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = self.cameraState
            next.recordingTransitionInProgress = value
            self.cameraState = next
        }
    }

    private func publishCameraRecordCommandInFlight(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = self.cameraState
            next.recordCommandInFlight = value
            self.cameraState = next
        }
    }

    private func publishCameraStatusFields(_ fields: Pocket3CameraStatus.StatusFields) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = self.cameraState
            next.apply(fields)
            self.cameraState = next
        }
    }

    private func publishBatteryStatus(_ fields: Pocket3BatteryStatusFields) {
        DispatchQueue.main.async { [weak self] in
            self?.cameraBatteryPercent = fields.percent
            self?.cameraBatteryCharging = fields.isCharging
        }
    }

    private func publishCameraReadback(_ property: Pocket3CameraPropertyRecord) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = self.cameraState
            if next.apply(property) {
                self.cameraState = next
            }
        }
    }

    private func publishFreshness(canCapture: Bool, canSmooth: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.canCaptureCenter = canCapture
            self?.canSmoothRecenter = canSmooth
        }
    }
}

private extension Data {
    init(hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        precondition(clean.count % 2 == 0)

        var bytes: [UInt8] = []
        bytes.reserveCapacity(clean.count / 2)

        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            bytes.append(UInt8(clean[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
