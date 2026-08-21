package com.pocket3.gimbaltest

import dev.konraditurbe.osmosis.duml.DumlFrameScanner
import dev.konraditurbe.osmosis.duml.OsmoCommands
import dev.konraditurbe.osmosis.net.DumlTransport
import java.net.InetSocketAddress
import java.net.Socket
import java.time.ZonedDateTime
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Minimal Pocket 3 control session derived from Osmosis' proven camera datalink path.
 *
 * v0.14.3 keeps the proven v0.13 BLE/Wi-Fi/transport path frozen. LINEAR remains unchanged;
 * PROGRESSIVE is more aggressive through the middle while retaining the captured +/-550 ceiling.
 * SAFE smooth recenter keeps continuous/unwrapped yaw and receives a modest ~20% speed increase.
 * The unsafe experimental 04/14 command remains removed and is never used.
 */
class GimbalSession(private val log: (String) -> Unit) {
    companion object {
        const val CAMERA_IP = "192.168.2.1"
        const val UDP_PORT = 9004
        private const val TCP_POKE_PORT = 7001
        private const val NEUTRAL = 1024

        // Osmosis' proven UDP app-presence beat. This is NOT the BLE 00/2B keepalive.
        private val APP_PRESENCE = hex("170046237c415050000000000002")
        private val GIMBAL_HEARTBEAT = hex("010405")

        // Closed-loop smooth recenter. v0.14 proved the continuous-yaw controller and accurate
        // settling. v0.14.3 raises command authority by about 20% while retaining the same safety,
        // deadband, telemetry freshness, progress, divergence, and transport checks.
        const val DEFAULT_CENTER_PITCH_DEG = 180.0
        const val DEFAULT_CENTER_YAW_DEG = 0.0
        private const val SMOOTH_DEADBAND_DEG = 0.8
        private const val SMOOTH_MIN_OFFSET = 48
        private const val SMOOTH_MAX_OFFSET = 430
        private const val SMOOTH_GAIN_PER_DEG = 6.0
        private const val SMOOTH_TIMEOUT_MS = 35_000L
        private const val SMOOTH_STALE_TELEMETRY_MS = 350L
        private const val SMOOTH_PROGRESS_TIMEOUT_MS = 5_000L
        private const val SMOOTH_PROGRESS_EPSILON_DEG = 0.20
        private const val SMOOTH_SETTLE_SAMPLES = 3
        private const val SMOOTH_MAX_TX_LAG_SLOTS = 64
        private const val SMOOTH_DIVERGENCE_MIN_ERROR_DEG = 8.0
        private const val SMOOTH_DIVERGENCE_STEP_DEG = 1.5
        private const val SMOOTH_DIVERGENCE_SAMPLES = 5
        private const val CAMERA_RECORD_COMMAND_TIMEOUT_NS = 5_000_000_000L

        private fun hex(s: String): ByteArray {
            val clean = s.filter { !it.isWhitespace() }
            require(clean.length % 2 == 0)
            return ByteArray(clean.length / 2) { i ->
                ((clean[i * 2].digitToInt(16) shl 4) or clean[i * 2 + 1].digitToInt(16)).toByte()
            }
        }
    }

    private val tx = DumlTransport(log, UDP_PORT, bindLocalPort = false, droneRouting = false)

    /** Live video consumes copies of pktType 0x02 datagrams already received by [tx]. */
    val videoOutput = Pocket3VideoOutput(log)

    @Volatile
    var connected: Boolean = false
        private set

    @Volatile private var pumpRunning = false
    @Volatile private var requestedPitch = NEUTRAL
    @Volatile private var requestedYaw = NEUTRAL
    private val controlUntilNs = AtomicLong(0L)
    private val recenterPending = AtomicBoolean(false)
    private val recenterAwaitingReply = AtomicBoolean(false)
    private val gimbalLockPending = AtomicReference<Boolean?>(null)
    private val selfieTogglePending = AtomicBoolean(false)
    private val joystickActive = AtomicBoolean(false)
    private val smoothRecenterActive = AtomicBoolean(false)
    private val forceNeutralPending = AtomicBoolean(false)
    @Volatile private var smoothTargetPitchDeg = DEFAULT_CENTER_PITCH_DEG
    @Volatile private var smoothTargetYawContinuousDeg = DEFAULT_CENTER_YAW_DEG
    @Volatile private var smoothInitialized = false
    private var smoothStartNs = 0L
    private var smoothLastProgressNs = 0L
    private var smoothBestErrorDeg = Double.POSITIVE_INFINITY
    private var smoothLastSampleNs = 0L
    private var smoothSettledSamples = 0
    private var smoothLastYawAbsErrorDeg = Double.NaN
    private var smoothYawDivergenceSamples = 0
    private val lastHeartbeatReplyNs = AtomicLong(0L)
    private var pumpThread: Thread? = null

    // Camera commands share the existing single-owner UDP pump and transport sequencing.
    private val cameraCommandQueue = ConcurrentLinkedQueue<Pocket3CameraCommand>()
    private val cameraStateLock = Any()
    private var cameraPropertyTransactionId = 0x0000_C900L
    private val lastCameraPropertyValues = HashMap<String, ByteArray>()
    private var cameraRecordCommandPending: Boolean? = null
    private var cameraRecordCommandTarget: Boolean? = null
    private var cameraRecordCommandDeadlineNs = 0L
    private var latestCameraRecordStatusByte: Int? = null
    @Volatile private var latestCameraState = Pocket3CameraState()

    val camera = Pocket3CameraControl(
        sendCommand = ::queueCameraCommand,
        setRecordingHandler = ::setCameraRecording,
    )

    // Live 04/05 telemetry. Immutable samples are safe to publish through a volatile reference.
    @Volatile private var latestTelemetrySample: GimbalTelemetry? = null
    @Volatile private var latestGimbalLocked = false
    private val telemetryHistory = ArrayDeque<GimbalTelemetry>()
    private val telemetryLock = Any()
    private val lastTelemetryNs = AtomicLong(0L)
    private var lastTelemetryLogNs = 0L

    // Telemetry yaw is wrapped to roughly [-180,+180]. Track a continuous branch so the long
    // selfie-side travel can be represented as e.g. +225 degrees rather than suddenly -135.
    private val yawReducer = Pocket3YawReducer()

    // Five-second diagnostics, owned by the pump thread only.
    private val inboundDumlCounts = HashMap<Int, Int>()
    private val inboundPktTypeCounts = IntArray(256)
    private var inboundDatagrams5s = 0

    fun latestTelemetry(): GimbalTelemetry? = latestTelemetrySample

    fun cameraState(): Pocket3CameraState = latestCameraState

    fun isGimbalLocked(): Boolean = latestGimbalLocked

    fun telemetryAgeMs(nowNs: Long = System.nanoTime()): Long {
        val last = lastTelemetryNs.get()
        if (last == 0L) return Long.MAX_VALUE
        return ((nowNs - last) / 1_000_000L).coerceAtLeast(0L)
    }

    /**
     * Average the most recent stable-looking telemetry window. This does NOT move the gimbal.
     * Intended to be pressed only after the proven native 04/4C recenter has finished settling.
     */
    fun averageRecentTelemetry(windowMs: Long = 800L): GimbalTelemetry? {
        val now = System.nanoTime()
        val minNs = now - windowMs * 1_000_000L
        val samples = synchronized(telemetryLock) {
            telemetryHistory.filter { it.receivedAtNs >= minNs }
        }
        if (samples.isEmpty()) return null
        return GimbalTelemetry(
            // Pitch/yaw wrapped display angles can cross +/-180, so use circular means there.
            // Continuous yaw is a physical-travel coordinate and therefore uses an arithmetic mean.
            pitchDeg = circularMeanDeg(samples.map { it.pitchDeg }),
            rollDeg = samples.map { it.rollDeg }.average(),
            yawDeg = circularMeanDeg(samples.map { it.yawDeg }),
            yawContinuousDeg = samples.map { it.yawContinuousDeg }.average(),
            mode = samples.last().mode,
            limitFlags = samples.last().limitFlags,
            receivedAtNs = now,
        )
    }

    fun isSmoothRecenterActive(): Boolean = smoothRecenterActive.get()

    /** Shortest signed angular error in degrees, always in (-180, +180]. */
    fun wrappedAngleError(targetDeg: Double, currentDeg: Double): Double {
        return Pocket3YawReducer.wrappedAngleError(targetDeg, currentDeg)
    }

    private fun circularMeanDeg(values: List<Double>): Double {
        if (values.isEmpty()) return Double.NaN
        var x = 0.0
        var y = 0.0
        for (v in values) {
            val r = Math.toRadians(v)
            x += cos(r)
            y += sin(r)
        }
        return Math.toDegrees(atan2(y, x))
    }

    /** Connect + register, deliberately never entering camera playback mode. */
    fun connect(ip: String = CAMERA_IP): Boolean {
        disconnect()
        log("Datalink: opening Pocket 3 at $ip using Osmosis registration path")

        // Same TCP-7001 poke Osmosis uses for genuine DJI cameras before udp/9004.
        try {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(ip, TCP_POKE_PORT), 1200)
                socket.getOutputStream().write(OsmoCommands.setPairingPin("osmo"))
                socket.getOutputStream().flush()
                Thread.sleep(400)
            }
            log("Datalink: TCP/7001 poke sent")
        } catch (t: Throwable) {
            log("Datalink: TCP/7001 poke failed: ${t.message}")
        }

        tx.open(ip)
        val reply = tx.handshake(handshakeFrame())
        if (reply == null) {
            log("Datalink: UDP/9004 handshake FAILED")
            tx.close()
            return false
        }
        log("Datalink: UDP/9004 handshake OK")

        // Exact Osmosis openDatalink pattern: drain initial peer traffic, ACK it, then sync our
        // command sequence to the learned peer channel.
        repeat(5) {
            tx.recvAll(400)
            tx.sendAck()
        }
        tx.syncSeqToPeerChannel()
        log(
            "Datalink: session=0x%04x base=0x%04x channel=0x%04x localPort=%d"
                .format(tx.sessionId, tx.baseSeq, tx.cameraChannel, tx.localPort)
        )

        // Minimal camera registration copied from Osmosis CameraSession.openAndRegister().
        // Deliberately NO UDP 00/2B session-open spam here: that command belongs to the BLE wake path.
        tx.sendDuml(
            set = 0x00, cmd = 0x81, payload = OsmoCommands.APP_DEVICE_INFO,
            receiverType = 0x08, receiverId = 2, cmdType = 4,
        )
        tx.recvAll(400); tx.sendAck()
        log("Datalink: 00/81 APP device-info registration sent")

        tx.sendDuml(
            set = 0x00, cmd = 0x88, payload = APP_PRESENCE,
            receiverType = 0x08, receiverId = 1,
        )
        tx.recvAll(400); tx.sendAck()
        log("Datalink: 00/88 APP presence sent")

        tx.sendDuml(
            set = 0x03, cmd = 0xDA, payload = hex("05ffffffff"),
            receiverType = 0x03, receiverId = 0,
        )
        tx.recvAll(400); tx.sendAck()
        log("Datalink: 03/DA gimbal init sent")

        // Keep the already-proven Pocket 3 gimbal heartbeat as a readiness probe.
        val hb = sendHeartbeatAndGetReply()
        if (hb == null) {
            log("Datalink: 04/50 gimbal heartbeat got NO reply; not marking controller ready")
            tx.close()
            return false
        }
        lastHeartbeatReplyNs.set(System.nanoTime())
        log("Datalink: 04/50 gimbal heartbeat reply: ${bytesHex(hb)}")

        // The capture-approved direct-live sequence must follow the readiness proof exactly. It is
        // sent here while this thread still exclusively owns the transport, before the UDP pump.
        videoOutput.startSession()
        try {
            for (step in Pocket3LiveViewCommands.startupSequence()) {
                sendLiveViewCommand(step.command)
                if (step.delayAfterMs > 0) Thread.sleep(step.delayAfterMs)
            }
            log("Live preview: capture-approved startup sequence sent")
        } catch (t: Throwable) {
            videoOutput.stopSession()
            tx.close()
            log("Live preview: startup failed: ${t.message}")
            return false
        }

        connected = true
        var subscriptionCount = 0
        for (propertyName in Pocket3CameraPropertyBus.CORE_PROPERTY_NAMES) {
            val command = Pocket3CameraPropertyBus.subscriptionCommand(
                propertyName,
                cameraPropertyTransactionId++,
            ) ?: continue
            cameraCommandQueue.add(command)
            subscriptionCount++
        }
        startPump()
        log("Camera readback: queued $subscriptionCount capture-derived 00/99 subscriptions")
        log("Pocket 3 gimbal ready. Osmosis-style UDP registration + control pump started.")
        return true
    }

    private fun queueCameraCommand(command: Pocket3CameraCommand) {
        if (!connected) {
            log("CAMERA SETTING ERROR: not connected (${command.label})")
            return
        }
        cameraCommandQueue.add(command)
        log("Camera command queued: ${command.label} payload=${bytesHex(command.payload)}")
    }

    private fun setCameraRecording(recording: Boolean) {
        synchronized(cameraStateLock) {
            if (!connected) {
                log("CAMERA RECORD ERROR: not connected")
                return
            }
            val current = latestCameraState.recording
            val statusByte = latestCameraRecordStatusByte
            if (current == null || statusByte == null) {
                log("CAMERA RECORD ERROR: waiting for 02/80 recording state")
                return
            }
            if (cameraRecordCommandTarget != null) {
                log("CAMERA RECORD ignored: previous record command still in flight")
                return
            }
            if (Pocket3CameraStatus.recordingTransitioning(statusByte)) {
                log("CAMERA RECORD ignored: 02/80 transition active (0x%02X)".format(statusByte))
                return
            }
            if (current == recording) {
                log(if (recording) "CAMERA RECORD ignored: Pocket already recording" else "CAMERA RECORD ignored: Pocket already idle")
                return
            }
            cameraRecordCommandPending = recording
            cameraRecordCommandTarget = recording
            cameraRecordCommandDeadlineNs = System.nanoTime() + CAMERA_RECORD_COMMAND_TIMEOUT_NS
            latestCameraState = latestCameraState.copy(recordCommandInFlight = true)
        }
        log(if (recording) "Camera RECORD START requested (02/02 01)" else "Camera RECORD STOP requested (02/02 00)")
    }

    fun pulse(pitch: Int = NEUTRAL, yaw: Int = NEUTRAL, durationMs: Long = 1500L) {
        check(connected) { "Not connected" }
        require(pitch in 0..0xFFFF && yaw in 0..0xFFFF)

        val hbAge = heartbeatAgeMs()
        log("Pulse request: pitch=$pitch yaw=$yaw for ${durationMs}ms (heartbeat age=${hbAge}ms)")

        requestedPitch = pitch
        requestedYaw = yaw
        controlUntilNs.set(System.nanoTime() + durationMs * 1_000_000L)
        Thread.sleep(durationMs + 120L)
        log("Pulse window finished; background pump returned to neutral")
    }

    /** Live virtual-joystick input. Values are consumed by the single UDP pump at ~20 Hz. */
    fun setJoystick(pitch: Int, yaw: Int) {
        if (!connected) return
        require(pitch in 0..0xFFFF && yaw in 0..0xFFFF)
        if (smoothRecenterActive.compareAndSet(true, false)) {
            smoothInitialized = false
            log("Smooth recenter canceled: manual joystick took control")
        }
        requestedPitch = pitch
        requestedYaw = yaw
        controlUntilNs.set(0L)
        joystickActive.set(true)
    }

    /** Release the virtual joystick. The pump emits one explicit neutral 04/01 frame. */
    fun releaseJoystick() {
        if (!connected) return
        requestedPitch = NEUTRAL
        requestedYaw = NEUTRAL
        controlUntilNs.set(0L)
        joystickActive.set(false)
    }

    fun neutral() {
        if (!connected) return
        requestedPitch = NEUTRAL
        requestedYaw = NEUTRAL
        controlUntilNs.set(0L)
        joystickActive.set(false)
        if (smoothRecenterActive.compareAndSet(true, false)) {
            smoothInitialized = false
            log("Smooth recenter canceled: STOP / NEUTRAL")
        }
        forceNeutralPending.set(true)
        log("Neutral requested")
    }

    /**
     * Safe closed-loop recenter. Uses only the already-proven 04/01 virtual joystick and live 04/05
     * telemetry; it never sends the unsafe experimental 04/14 command.
     */
    fun smoothRecenter(
        targetPitchDeg: Double = DEFAULT_CENTER_PITCH_DEG,
        targetYawContinuousDeg: Double = DEFAULT_CENTER_YAW_DEG,
    ) {
        check(connected) { "Not connected" }
        val t = latestTelemetrySample ?: error("No 04/05 telemetry yet")
        val age = telemetryAgeMs()
        require(age <= SMOOTH_STALE_TELEMETRY_MS) { "04/05 telemetry is stale (${age}ms)" }

        releaseJoystick()
        smoothTargetPitchDeg = targetPitchDeg
        smoothTargetYawContinuousDeg = targetYawContinuousDeg
        smoothInitialized = false
        smoothRecenterActive.set(true)
        log(
            "Smooth recenter requested: current P=${fmt(t.pitchDeg)} Y=${fmt(t.yawDeg)} " +
                "Ycont=${fmt(t.yawContinuousDeg)} -> target P=${fmt(targetPitchDeg)} " +
                "Ycont=${fmt(targetYawContinuousDeg)} (04/01 + 04/05 closed loop; 04/14 NOT used)"
        )
    }

    /** Pocket 3 RECENTER captured directly from DJI Mimo: 04/4C FE08. */
    fun recenter() {
        check(connected) { "Not connected" }
        if (smoothRecenterActive.compareAndSet(true, false)) {
            smoothInitialized = false
            log("Smooth recenter canceled: RECENTER requested")
        }
        releaseJoystick()
        recenterPending.set(true)
        log("RECENTER requested (DJI Mimo 04/4C FE08)")
    }

    /** Hardware-confirmed software gimbal lock/follow command: 04/4C 0000 / 0100. */
    fun setGimbalLocked(locked: Boolean) {
        check(connected) { "Not connected" }
        neutral()
        gimbalLockPending.set(locked)
        log(if (locked) "Gimbal LOCK requested (04/4C 0000)" else "Gimbal FOLLOW requested (04/4C 0100)")
    }

    /** Capture-confirmed Pocket selfie/forward toggle: 04/4C FE09. */
    fun toggleSelfieForward() {
        check(connected) { "Not connected" }
        neutral()
        selfieTogglePending.set(true)
        log("Selfie/forward toggle requested (04/4C FE09)")
    }

    /** Add a Custom Motionlapse waypoint from fresh hardware 04/05 telemetry. */
    fun addMotionlapseWaypoint(slot: Int, intervalTenths: Int, durationSeconds: Long): Boolean {
        if (!connected) return false
        val sample = latestTelemetrySample ?: return false
        if (telemetryAgeMs() > SMOOTH_STALE_TELEMETRY_MS) return false
        camera.addMotionlapseWaypoint(
            slot = slot,
            intervalTenths = intervalTenths,
            durationSeconds = durationSeconds,
            pitchTenths = (sample.pitchDeg * 10.0).roundToInt(),
            rollTenths = (sample.rollDeg * 10.0).roundToInt(),
            yawTenths = (sample.yawDeg * 10.0).roundToInt(),
        )
        return true
    }

    /** Convert signed angle error to a useful joystick offset around 1024. */
    private fun smoothAxisOffset(errorDeg: Double): Int {
        val a = abs(errorDeg)
        if (a <= SMOOTH_DEADBAND_DEG) return 0
        val mag = (SMOOTH_MIN_OFFSET + (a - SMOOTH_DEADBAND_DEG) * SMOOTH_GAIN_PER_DEG)
            .roundToInt()
            .coerceIn(SMOOTH_MIN_OFFSET, SMOOTH_MAX_OFFSET)
        return if (errorDeg > 0.0) mag else -mag
    }

    /** Called only by the UDP pump thread. Returns true while it owns the gimbal command stream. */
    private fun driveSmoothRecenter(now: Long): Boolean {
        if (!smoothRecenterActive.get()) return false

        val sample = latestTelemetrySample
        val ageMs = telemetryAgeMs(now)
        if (sample == null || ageMs > SMOOTH_STALE_TELEMETRY_MS) {
            finishSmoothRecenterInPump(
                success = false,
                reason = "telemetry stale (${if (ageMs == Long.MAX_VALUE) "none" else "${ageMs}ms"})",
            )
            return false
        }

        if (!smoothInitialized) {
            smoothInitialized = true
            smoothStartNs = now
            smoothLastProgressNs = now
            smoothBestErrorDeg = Double.POSITIVE_INFINITY
            smoothLastSampleNs = 0L
            smoothSettledSamples = 0
            smoothLastYawAbsErrorDeg = Double.NaN
            smoothYawDivergenceSamples = 0
        }

        val elapsedMs = (now - smoothStartNs) / 1_000_000L
        if (elapsedMs > SMOOTH_TIMEOUT_MS) {
            finishSmoothRecenterInPump(false, "timeout after ${elapsedMs}ms")
            return false
        }

        // If the reliable TX window is catastrophically backing up, don't keep applying movement.
        // Mimo can transiently have a few outstanding slots; 64 is intentionally generous.
        if (tx.txAckLagSlots > SMOOTH_MAX_TX_LAG_SLOTS) {
            finishSmoothRecenterInPump(false, "transport TX lag=${tx.txAckLagSlots} slots")
            return false
        }

        val pErr = wrappedAngleError(smoothTargetPitchDeg, sample.pitchDeg)
        // Yaw is NOT treated as a circular shortest-path angle. The Pocket 3 has a strongly
        // asymmetric physical yaw range: one side stops around -48 degrees while the selfie side
        // can travel through +180 and continue to roughly +225 physical degrees. Continuous yaw
        // preserves the path we actually took and therefore commands the correct route back home.
        val yErr = smoothTargetYawContinuousDeg - sample.yawContinuousDeg
        val totalErr = hypot(pErr, yErr)

        // Evaluate settling/progress only once per NEW 04/05 sample (~10 Hz), not every 20 Hz pump tick.
        if (sample.receivedAtNs != smoothLastSampleNs) {
            smoothLastSampleNs = sample.receivedAtNs

            if (abs(pErr) <= SMOOTH_DEADBAND_DEG && abs(yErr) <= SMOOTH_DEADBAND_DEG) {
                smoothSettledSamples++
            } else {
                smoothSettledSamples = 0
            }

            if (smoothSettledSamples >= SMOOTH_SETTLE_SAMPLES) {
                finishSmoothRecenterInPump(
                    true,
                    "settled P=${fmt(sample.pitchDeg)} Y=${fmt(sample.yawDeg)} " +
                        "errors P=${fmt(pErr)} Y=${fmt(yErr)}",
                )
                return false
            }

            if (totalErr + SMOOTH_PROGRESS_EPSILON_DEG < smoothBestErrorDeg) {
                smoothBestErrorDeg = totalErr
                smoothLastProgressNs = now
            } else if (
                totalErr > 2.0 &&
                (now - smoothLastProgressNs) / 1_000_000L > SMOOTH_PROGRESS_TIMEOUT_MS
            ) {
                finishSmoothRecenterInPump(
                    false,
                    "no progress for ${SMOOTH_PROGRESS_TIMEOUT_MS}ms; " +
                        "errors P=${fmt(pErr)} Y=${fmt(yErr)}",
                )
                return false
            }

            // Safety: if a meaningful yaw error repeatedly grows in the direction we're commanding,
            // stop instead of trusting a bad branch/sign assumption. Allow several samples for normal
            // inertia/coupling and ignore this check close to center.
            val yawAbs = abs(yErr)
            if (!smoothLastYawAbsErrorDeg.isNaN() && yawAbs > SMOOTH_DIVERGENCE_MIN_ERROR_DEG) {
                if (yawAbs > smoothLastYawAbsErrorDeg + SMOOTH_DIVERGENCE_STEP_DEG) {
                    smoothYawDivergenceSamples++
                } else if (yawAbs <= smoothLastYawAbsErrorDeg + 0.2) {
                    smoothYawDivergenceSamples = 0
                }
                if (smoothYawDivergenceSamples >= SMOOTH_DIVERGENCE_SAMPLES) {
                    finishSmoothRecenterInPump(
                        false,
                        "yaw error diverging; Ycont=${fmt(sample.yawContinuousDeg)} " +
                            "target=${fmt(smoothTargetYawContinuousDeg)} error=${fmt(yErr)}",
                    )
                    return false
                }
            } else {
                smoothYawDivergenceSamples = 0
            }
            smoothLastYawAbsErrorDeg = yawAbs
        }

        // Empirically from our working 04/01 + 04/05 logs:
        //   yaw > 1024 increases telemetry yaw, so yaw follows the signed target-current error;
        //   pitch < 1024 increases wrapped telemetry pitch, so pitch uses the opposite command sign.
        val pOffset = smoothAxisOffset(pErr)
        val yOffset = smoothAxisOffset(yErr)
        val pitchCmd = (NEUTRAL - pOffset).coerceIn(NEUTRAL - SMOOTH_MAX_OFFSET, NEUTRAL + SMOOTH_MAX_OFFSET)
        val yawCmd = (NEUTRAL + yOffset).coerceIn(NEUTRAL - SMOOTH_MAX_OFFSET, NEUTRAL + SMOOTH_MAX_OFFSET)
        sendGimbal(pitchCmd, yawCmd)
        return true
    }

    /** Called only by the pump thread, so the final neutral command cannot race normal 04/01 traffic. */
    private fun finishSmoothRecenterInPump(success: Boolean, reason: String) {
        smoothRecenterActive.set(false)
        smoothInitialized = false
        requestedPitch = NEUTRAL
        requestedYaw = NEUTRAL
        controlUntilNs.set(0L)
        joystickActive.set(false)
        sendGimbal(NEUTRAL, NEUTRAL)
        log("Smooth recenter ${if (success) "COMPLETE" else "ABORTED"}: $reason; neutral sent")
    }

    private fun startPump() {
        if (pumpRunning) return
        pumpRunning = true
        pumpThread = Thread({
            var nextAckFallback = System.nanoTime() + 250_000_000L
            var nextHeartbeat = System.nanoTime() + 700_000_000L
            var nextAppPresence = System.nanoTime() + 900_000_000L
            var nextControl = System.nanoTime()
            var wasControlling = false
            var lastHealthLog = 0L
            var heartbeatLostLogged = false
            var txWindowLagLogged = false

            try {
                while (pumpRunning && tx.isOpen) {
                    // One thread owns all UDP receive/send/sequence state. Drain briefly so 20 Hz
                    // control remains responsive, but ACK actual incoming traffic immediately.
                    val replies = tx.recvBurst(12, 4)
                    val now = System.nanoTime()
                    recordInbound(replies, now)

                    if (replies.isNotEmpty()) {
                        tx.sendAck()
                        nextAckFallback = now + 250_000_000L
                    } else if (now >= nextAckFallback) {
                        // Osmosis ACKs on every receive cycle. This low-rate fallback keeps the peer's
                        // downlink window serviced without the old blind 50 Hz ACK spam.
                        tx.sendAck()
                        nextAckFallback = now + 250_000_000L
                    }

                    if (DumlFrameScanner.findReply(replies, 0x04, 0x50) != null) {
                        lastHeartbeatReplyNs.set(now)
                        heartbeatLostLogged = false
                    }

                    if (recenterAwaitingReply.get()) {
                        val status = replies.asSequence()
                            .mapNotNull { DumlFrameScanner.findResponseStatus(it, 0x04, 0x4C) }
                            .firstOrNull()
                        if (status != null) {
                            recenterAwaitingReply.set(false)
                            log("04/4C RECENTER response status=0x%04x".format(status))
                        }
                    }

                    // Gimbal-specific readiness beat, retained from the working controller captures.
                    if (now >= nextHeartbeat) {
                        tx.sendDuml(0x04, 0x50, GIMBAL_HEARTBEAT, receiverType = 0x04, receiverId = 0)
                        nextHeartbeat = now + 1_000_000_000L
                    }

                    // Proven Osmosis camera-session beat. Crucially, this replaces the old repeated
                    // UDP 00/2B[04 00], which Osmosis uses on BLE only as the wake/open command.
                    if (now >= nextAppPresence) {
                        tx.sendDuml(
                            0x00, 0x88, APP_PRESENCE,
                            receiverType = 0x08, receiverId = 1,
                        )
                        nextAppPresence = now + 1_000_000_000L
                    }

                    val requestedCameraRecording = synchronized(cameraStateLock) {
                        cameraRecordCommandPending.also { cameraRecordCommandPending = null }
                    }
                    if (requestedCameraRecording != null) {
                        val command = Pocket3CameraStatus.recordingCommand(requestedCameraRecording)
                        sendCameraCommandInPump(command)
                        log(
                            if (requestedCameraRecording) "02/02 camera RECORD START packet sent: 01"
                            else "02/02 camera RECORD STOP packet sent: 00"
                        )
                    }

                    cameraCommandQueue.poll()?.let { command ->
                        sendCameraCommandInPump(command)
                        log("Camera command sent: ${command.label}")
                    }

                    gimbalLockPending.getAndSet(null)?.let { locked ->
                        sendGimbal(NEUTRAL, NEUTRAL)
                        tx.sendDuml(
                            set = 0x04, cmd = 0x4C,
                            payload = Pocket3GimbalCommands.lockPayload(locked),
                            receiverType = 0x04, receiverId = 0, cmdType = 2,
                        )
                        latestGimbalLocked = locked
                        log(if (locked) "04/4C gimbal LOCK packet sent: 0000" else "04/4C gimbal FOLLOW packet sent: 0100")
                    }

                    if (selfieTogglePending.compareAndSet(true, false)) {
                        sendGimbal(NEUTRAL, NEUTRAL)
                        tx.sendDuml(
                            set = 0x04, cmd = 0x4C, payload = Pocket3GimbalCommands.selfieForwardPayload(),
                            receiverType = 0x04, receiverId = 0, cmdType = 2,
                        )
                        log("04/4C selfie/forward packet sent: fe09")
                    }

                    if (recenterPending.compareAndSet(true, false)) {
                        sendGimbal(NEUTRAL, NEUTRAL)
                        tx.sendDuml(
                            set = 0x04,
                            cmd = 0x4C,
                            payload = Pocket3GimbalCommands.recenterPayload(),
                            receiverType = 0x04,
                            receiverId = 0,
                            cmdType = 2,
                        )
                        recenterAwaitingReply.set(true)
                        log("04/4C RECENTER packet sent: fe08")
                    }

                    if (forceNeutralPending.compareAndSet(true, false)) {
                        sendGimbal(NEUTRAL, NEUTRAL)
                        wasControlling = false
                        log("04/01 forced neutral sent")
                    }

                    // Smooth recenter owns the same proven 04/01 command stream as the manual stick.
                    // It is intentionally serialized on this one pump thread so it cannot race ACK/seq state.
                    val smoothOwnsControl = smoothRecenterActive.get()
                    if (smoothOwnsControl) {
                        if (now >= nextControl) {
                            driveSmoothRecenter(now)
                            nextControl = now + 50_000_000L
                        }
                        wasControlling = false
                    } else {
                        val until = controlUntilNs.get()
                        val controlling = joystickActive.get() || until > now
                        if (controlling && now >= nextControl) {
                            sendGimbal(requestedPitch, requestedYaw)
                            if (!wasControlling) {
                                log("04/01 stream started: pitch=$requestedPitch yaw=$requestedYaw")
                            }
                            wasControlling = true
                            nextControl = now + 50_000_000L // ~20 Hz
                        } else if (!controlling && wasControlling) {
                            sendGimbal(NEUTRAL, NEUTRAL)
                            requestedPitch = NEUTRAL
                            requestedYaw = NEUTRAL
                            controlUntilNs.set(0L)
                            wasControlling = false
                            log("04/01 neutral sent after joystick/pulse")
                        }
                    }

                    val txLag = tx.txAckLagSlots
                    if (txLag > 24 && !txWindowLagLogged) {
                        txWindowLagLogged = true
                        log("WARNING: reliable TX window lag grew to $txLag slots; ${transportSnapshot()}")
                    } else if (txLag <= 4) {
                        txWindowLagLogged = false
                    }

                    val hbAgeMs = heartbeatAgeMs(now)
                    if (hbAgeMs > 3000 && !heartbeatLostLogged) {
                        heartbeatLostLogged = true
                        log(
                            "WARNING: no 04/50 heartbeat reply for ${hbAgeMs}ms; " +
                                "04/05 age=${displayAge(telemetryAgeMs(now))}; " +
                                transportSnapshot()
                        )
                    }

                    if (now - lastHealthLog >= 5_000_000_000L) {
                        lastHealthLog = now
                        logFiveSecondDiagnostics(now, hbAgeMs)
                    }
                }
            } catch (t: Throwable) {
                if (pumpRunning) log("Transport pump error: ${t.message}")
            } finally {
                if (tx.isOpen) runCatching { sendGimbal(NEUTRAL, NEUTRAL) }
                log("Transport pump stopped")
            }
        }, "Pocket3-UDP-Pump").apply {
            isDaemon = true
            start()
        }
    }

    /** Decode and classify every CRC-valid DUML frame in the packets drained by the pump. */
    private fun recordInbound(datagrams: List<ByteArray>, nowNs: Long) {
        for (d in datagrams) {
            inboundDatagrams5s++
            if (d.size >= 7) {
                val pktType = d[6].toInt() and 0xFF
                inboundPktTypeCounts[pktType]++
                if (pktType == 0x02) videoOutput.feed(d)
            }

            for (frame in DumlFrameScanner.scan(d)) {
                val key = (frame.commandSet shl 8) or frame.commandId
                inboundDumlCounts[key] = (inboundDumlCounts[key] ?: 0) + 1

                val payload = frame.payload
                if (frame.commandSet == 0x00 && frame.commandId == 0x99) {
                    val property = Pocket3CameraPropertyBus.parsePush(payload)
                    if (property != null && property.name in Pocket3CameraPropertyBus.CORE_PROPERTY_NAMES) {
                        val changed = lastCameraPropertyValues[property.name]
                            ?.contentEquals(property.value) != true
                        if (changed) {
                            lastCameraPropertyValues[property.name] = property.value.copyOf()
                            synchronized(cameraStateLock) {
                                latestCameraState.apply(property)?.let { latestCameraState = it }
                            }
                            log("Camera readback 00/99 ${property.name}: ${bytesHex(property.value)}")
                        }
                        continue
                    }
                }

                if (frame.commandSet == 0x02 && frame.commandId == 0x80) {
                    val telemetry = Pocket3TelemetryParser.cameraStatus(payload) ?: continue
                    val statusByte = telemetry.statusByte
                    var timedOut = false
                    synchronized(cameraStateLock) {
                        latestCameraRecordStatusByte = statusByte
                        var state = latestCameraState.copy(
                            recording = telemetry.recording,
                            recordingTransitionInProgress = telemetry.transitioning,
                        )
                        if (telemetry.fields != null) state = state.apply(telemetry.fields)
                        val target = cameraRecordCommandTarget
                        if (target != null && Pocket3CameraStatus.recordRequestResolved(target, statusByte)) {
                            cameraRecordCommandTarget = null
                            cameraRecordCommandPending = null
                            cameraRecordCommandDeadlineNs = 0L
                            state = state.copy(recordCommandInFlight = false)
                        } else if (target != null && cameraRecordCommandDeadlineNs != 0L && nowNs >= cameraRecordCommandDeadlineNs) {
                            cameraRecordCommandTarget = null
                            cameraRecordCommandPending = null
                            cameraRecordCommandDeadlineNs = 0L
                            state = state.copy(recordCommandInFlight = false)
                            timedOut = true
                        }
                        latestCameraState = state
                    }
                    if (timedOut) log("CAMERA RECORD WARNING: command-in-flight guard timed out waiting for 02/80 change")
                }

                if (frame.commandSet == 0x0D && frame.commandId == 0x02) {
                    val battery = Pocket3TelemetryParser.battery(payload)
                    if (battery != null) {
                        synchronized(cameraStateLock) {
                            latestCameraState = latestCameraState.copy(
                                batteryPercent = battery.percent,
                                batteryCharging = battery.charging,
                            )
                        }
                    }
                }

                if (frame.commandSet == 0x04 && frame.commandId == 0x05) {
                    val telemetry = Pocket3TelemetryParser.gimbal(payload) ?: continue
                    val sample = yawReducer.reduce(telemetry, nowNs)
                    latestTelemetrySample = sample
                    // 04/05 mode is not a confirmed Pocket 3 lock-state readback. Keep the
                    // UI state tied to the capture-confirmed 04/4C command we actually sent.
                    lastTelemetryNs.set(nowNs)
                    synchronized(telemetryLock) {
                        telemetryHistory.addLast(sample)
                        val cutoff = nowNs - 2_000_000_000L
                        while (telemetryHistory.isNotEmpty() && telemetryHistory.first().receivedAtNs < cutoff) {
                            telemetryHistory.removeFirst()
                        }
                    }

                    // Human-readable Logcat is rate-limited; the UI reads the latest sample directly.
                    if (nowNs - lastTelemetryLogNs >= 1_000_000_000L) {
                        lastTelemetryLogNs = nowNs
                        log(
                            "GIMBAL 04/05: pitch=${fmt(sample.pitchDeg)}° roll=${fmt(sample.rollDeg)}° " +
                                "yaw=${fmt(sample.yawDeg)}° Ycont=${fmt(sample.yawContinuousDeg)}° " +
                                "mode=${hexOrDash(sample.mode)} " +
                                "limits=${limitSummary(sample)}"
                        )
                    }
                }
            }
        }
    }

    private fun logFiveSecondDiagnostics(nowNs: Long, hbAgeMs: Long) {
        val duml = inboundDumlCounts.entries
            .sortedByDescending { it.value }
            .take(10)
            .joinToString(" ") { (k, v) -> "%02X/%02X=%d".format((k ushr 8) and 0xFF, k and 0xFF, v) }
            .ifEmpty { "none" }

        val pkt = inboundPktTypeCounts.indices
            .filter { inboundPktTypeCounts[it] > 0 }
            .joinToString(" ") { "%02X=%d".format(it, inboundPktTypeCounts[it]) }
            .ifEmpty { "none" }

        log(
            "Session diag/5s: hbAge=${hbAgeMs}ms 04/05Age=${displayAge(telemetryAgeMs(nowNs))} " +
                "datagrams=$inboundDatagrams5s pktTypes[$pkt] DUML[$duml] ${transportSnapshot()}"
        )

        inboundDumlCounts.clear()
        inboundPktTypeCounts.fill(0)
        inboundDatagrams5s = 0
    }

    private fun transportSnapshot(): String =
        "nextTx=0x%04x lastTx=0x%04x peerAckTx=0x%04x lag=%d rx02=0x%04x rx03=0x%04x camCh=0x%04x base=0x%04x cmdCount=%d"
            .format(
                tx.seq, tx.lastTxCursor, tx.peerAckedTxCursor, tx.txAckLagSlots,
                tx.rxType2Cursor, tx.rxType3Cursor, tx.cameraChannel, tx.baseSeq, tx.commandCount,
            )

    private fun heartbeatAgeMs(nowNs: Long = System.nanoTime()): Long {
        val last = lastHeartbeatReplyNs.get()
        if (last == 0L) return Long.MAX_VALUE
        return ((nowNs - last) / 1_000_000L).coerceAtLeast(0L)
    }

    private fun sendHeartbeatAndGetReply(): ByteArray? {
        tx.sendDuml(0x04, 0x50, GIMBAL_HEARTBEAT, receiverType = 0x04, receiverId = 0)
        val replies = tx.recvAll(600)
        tx.sendAck()
        return DumlFrameScanner.findReply(replies, 0x04, 0x50)
    }

    private fun sendGimbal(pitch: Int, yaw: Int) {
        tx.sendDuml(
            set = 0x04,
            cmd = 0x01,
            payload = Pocket3GimbalCommands.velocityPayload(pitch, yaw),
            receiverType = 0x04,
            receiverId = 0,
            cmdType = 0,
        )
    }

    private fun sendCameraCommandInPump(command: Pocket3CameraCommand) {
        tx.sendDuml(
            set = command.set,
            cmd = command.command,
            payload = command.payload,
            receiverType = command.receiverType,
            receiverId = command.receiverId,
            cmdType = command.commandType,
        )
    }

    private fun sendLiveViewCommand(command: Pocket3LiveViewCommand) {
        tx.sendDuml(
            set = command.set,
            cmd = command.command,
            payload = command.payload,
            receiverType = command.receiverType,
            receiverId = command.receiverId,
            cmdType = command.commandType,
        )
    }

    fun disconnect() {
        requestedPitch = NEUTRAL
        requestedYaw = NEUTRAL
        controlUntilNs.set(0L)
        joystickActive.set(false)
        recenterPending.set(false)
        recenterAwaitingReply.set(false)
        gimbalLockPending.set(null)
        selfieTogglePending.set(false)
        smoothRecenterActive.set(false)
        smoothInitialized = false
        smoothLastYawAbsErrorDeg = Double.NaN
        smoothYawDivergenceSamples = 0
        forceNeutralPending.set(false)
        cameraCommandQueue.clear()
        synchronized(cameraStateLock) {
            cameraRecordCommandPending = null
            cameraRecordCommandTarget = null
            cameraRecordCommandDeadlineNs = 0L
            latestCameraRecordStatusByte = null
            latestCameraState = Pocket3CameraState()
            lastCameraPropertyValues.clear()
        }
        pumpRunning = false
        runCatching { pumpThread?.join(1_500) }
        if (pumpThread?.isAlive == true) {
            log("WARNING: transport pump did not stop before live-preview shutdown")
        }
        pumpThread = null

        if (tx.isOpen) {
            // Preserve the validated shutdown ordering: the sole pump has exited, then one final
            // neutral, eight LIVE_IDLE commands, and a 0.75 s receive/ACK drain before close.
            runCatching {
                sendGimbal(NEUTRAL, NEUTRAL)
                for (step in Pocket3LiveViewCommands.shutdownSequence()) {
                    sendLiveViewCommand(step.command)
                    if (step.delayAfterMs > 0) Thread.sleep(step.delayAfterMs)
                }
                val drainDeadlineNs = System.nanoTime() + 750_000_000L
                var drained = 0
                while (tx.isOpen && System.nanoTime() < drainDeadlineNs) {
                    drained += tx.recvBurst(12, 4).size
                    tx.sendAck()
                }
                log("Live preview: safe idle + ACK drain complete ($drained datagrams)")
            }.onFailure { log("Live preview: shutdown drain error: ${it.message}") }
            videoOutput.stopSession()
            tx.close()
        } else {
            videoOutput.stopSession()
        }
        connected = false
        lastHeartbeatReplyNs.set(0L)
        lastTelemetryNs.set(0L)
        latestTelemetrySample = null
        latestGimbalLocked = false
        yawReducer.reset()
        synchronized(telemetryLock) { telemetryHistory.clear() }
        inboundDumlCounts.clear()
        inboundPktTypeCounts.fill(0)
        inboundDatagrams5s = 0
    }

    private fun handshakeFrame(): ByteArray = hex(
        "000064006400c005140000640000019001c005140000640014006400c00514000064000101040102"
    ).also {
        it[0] = (tx.baseSeq and 0xFF).toByte()
        it[1] = ((tx.baseSeq ushr 8) and 0xFF).toByte()
    }

    private fun appDeviceInfo(): ByteArray {
        val b = ByteArray(62)
        b[1] = 'A'.code.toByte()
        b[2] = 'P'.code.toByte()
        b[3] = 'P'.code.toByte()
        b[41] = 0x02
        b[50] = 0x02
        b[51] = 0x08
        return b
    }

    private fun timeSyncPayload(): ByteArray {
        val now = ZonedDateTime.now()
        val year = now.year
        val offsetMinutes = now.offset.totalSeconds / 60
        val off = offsetMinutes and 0xFFFF
        return byteArrayOf(
            (year and 0xFF).toByte(), ((year ushr 8) and 0xFF).toByte(),
            now.monthValue.toByte(), now.dayOfMonth.toByte(), now.hour.toByte(),
            now.minute.toByte(), now.second.toByte(),
            (off and 0xFF).toByte(), ((off ushr 8) and 0xFF).toByte(),
        )
    }

    private fun fmt(v: Double): String = "%+.1f".format(v)
    private fun hexOrDash(v: Int?): String = v?.let { "0x%02x".format(it) } ?: "--"
    private fun limitSummary(t: GimbalTelemetry): String {
        if (t.limitFlags == null) return "--"
        return "0x%02x[P=%s R=%s Y=%s stuck=%s]".format(
            t.limitFlags,
            if (t.pitchAtLimit) "LIMIT" else "ok",
            if (t.rollAtLimit) "LIMIT" else "ok",
            if (t.yawAtLimit) "LIMIT" else "ok",
            if (t.stuck) "YES" else "no",
        )
    }

    private fun displayAge(ms: Long): String = if (ms == Long.MAX_VALUE) "none" else "${ms}ms"
    private fun bytesHex(b: ByteArray): String = b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
}
