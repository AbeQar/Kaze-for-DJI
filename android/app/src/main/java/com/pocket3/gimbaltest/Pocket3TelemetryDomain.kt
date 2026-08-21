package com.pocket3.gimbaltest

/** Decoded Pocket 3 gimbal telemetry from unsolicited DUML 04/05 frames. */
data class GimbalTelemetry(
    val pitchDeg: Double,
    val rollDeg: Double,
    val yawDeg: Double,
    val yawContinuousDeg: Double,
    val mode: Int?,
    val limitFlags: Int?,
    val receivedAtNs: Long,
) {
    val pitchAtLimit: Boolean get() = limitFlags?.let { (it and 0x01) != 0 } ?: false
    val rollAtLimit: Boolean get() = limitFlags?.let { (it and 0x02) != 0 } ?: false
    val yawAtLimit: Boolean get() = limitFlags?.let { (it and 0x04) != 0 } ?: false
    val stuck: Boolean get() = limitFlags?.let { (it and 0x40) != 0 } ?: false
}

data class Pocket3WrappedGimbalTelemetry(
    val pitchDeg: Double,
    val rollDeg: Double,
    val yawDeg: Double,
    val mode: Int?,
    val limitFlags: Int?,
)

data class Pocket3CameraStatusTelemetry(
    val statusByte: Int,
    val recording: Boolean,
    val transitioning: Boolean,
    val fields: Pocket3CameraStatusFields?,
)

data class Pocket3BatteryStatusFields(
    val percent: Int,
    val charging: Boolean?,
)

object Pocket3TelemetryParser {
    /** Decode 04/05 without manufacturing values for short payloads. */
    fun gimbal(payload: ByteArray): Pocket3WrappedGimbalTelemetry? {
        if (payload.size < 6) return null
        return Pocket3WrappedGimbalTelemetry(
            pitchDeg = payload.s16le(0) / 10.0,
            rollDeg = payload.s16le(2) / 10.0,
            yawDeg = payload.s16le(4) / 10.0,
            mode = payload.getOrNull(6)?.toInt()?.and(0xFF),
            limitFlags = payload.getOrNull(10)?.toInt()?.and(0xFF),
        )
    }

    /** Preserve the Stage-3 camera-status interpretation as one typed inbound event. */
    fun cameraStatus(payload: ByteArray): Pocket3CameraStatusTelemetry? {
        if (payload.isEmpty()) return null
        val statusByte = payload.u8(0)
        return Pocket3CameraStatusTelemetry(
            statusByte = statusByte,
            recording = Pocket3CameraStatus.recordingActive(statusByte),
            transitioning = Pocket3CameraStatus.recordingTransitioning(statusByte),
            fields = Pocket3CameraStatus.statusFields(payload),
        )
    }

    /** Hardware-confirmed unsolicited 0D/02 fields: byte 20 percent, byte 32 charging state. */
    fun battery(payload: ByteArray): Pocket3BatteryStatusFields? {
        if (payload.size < 33) return null
        val percent = payload.u8(20)
        if (percent !in 0..100) return null
        val charging = when (payload.u8(32)) {
            0x00 -> false
            0x01 -> true
            else -> null
        }
        return Pocket3BatteryStatusFields(percent, charging)
    }

    private fun ByteArray.s16le(offset: Int): Int {
        val unsigned = u8(offset) or (u8(offset + 1) shl 8)
        return if (unsigned >= 0x8000) unsigned - 0x10000 else unsigned
    }
}

class Pocket3YawReducer {
    private var lastWrappedYawDeg: Double? = null
    private var continuousYawDeg = 0.0

    fun reduce(telemetry: Pocket3WrappedGimbalTelemetry, receivedAtNs: Long): GimbalTelemetry {
        continuousYawDeg = lastWrappedYawDeg?.let { previous ->
            continuousYawDeg + wrappedAngleError(telemetry.yawDeg, previous)
        } ?: telemetry.yawDeg
        lastWrappedYawDeg = telemetry.yawDeg

        return GimbalTelemetry(
            pitchDeg = telemetry.pitchDeg,
            rollDeg = telemetry.rollDeg,
            yawDeg = telemetry.yawDeg,
            yawContinuousDeg = continuousYawDeg,
            mode = telemetry.mode,
            limitFlags = telemetry.limitFlags,
            receivedAtNs = receivedAtNs,
        )
    }

    fun reset() {
        lastWrappedYawDeg = null
        continuousYawDeg = 0.0
    }

    companion object {
        /** Shortest signed angular error in degrees, always in (-180, +180]. */
        fun wrappedAngleError(targetDeg: Double, currentDeg: Double): Double {
            var delta = (targetDeg - currentDeg) % 360.0
            if (delta <= -180.0) delta += 360.0
            if (delta > 180.0) delta -= 360.0
            return delta
        }
    }
}
