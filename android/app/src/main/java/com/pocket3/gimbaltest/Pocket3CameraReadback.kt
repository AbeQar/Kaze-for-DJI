package com.pocket3.gimbaltest

data class Pocket3CameraPropertyRecord(
    val transactionId: Long,
    val name: String,
    val value: ByteArray,
) {
    override fun equals(other: Any?): Boolean =
        other is Pocket3CameraPropertyRecord && transactionId == other.transactionId &&
            name == other.name && value.contentEquals(other.value)

    override fun hashCode(): Int = 31 * (31 * transactionId.hashCode() + name.hashCode()) + value.contentHashCode()
}

sealed interface Pocket3WhiteBalanceReadback {
    data object Auto : Pocket3WhiteBalanceReadback
    data class CustomKelvin(val kelvin: Int) : Pocket3WhiteBalanceReadback
}

data class Pocket3CameraReadbackState(
    val videoResolution: Pocket3VideoResolution? = null,
    val videoFrameRate: Pocket3FrameRate? = null,
    val sensorAspectRatio: Pocket3SensorAspectRatio? = null,
    val videoCompression: Pocket3VideoCompression? = null,
    val colorProfile: Pocket3ColorProfile? = null,
    val whiteBalance: Pocket3WhiteBalanceReadback? = null,
    val exposureMode: Pocket3ExposureMode? = null,
    val evThirdStops: Int? = null,
    val effectiveIso: Long? = null,
    val focusMode: Pocket3FocusMode? = null,
    val photoFrame: Pocket3PhotoFrame? = null,
    val photoFormat: Pocket3PhotoFormat? = null,
    val photoCountdown: Pocket3PhotoCountdown? = null,
    val timelapseIntervalTenths: Int? = null,
    val timelapseDurationSeconds: Long? = null,
    val timelapseOutput: Pocket3TimelapseOutput? = null,
    val hyperlapseSpeed: Pocket3HyperlapseSpeed? = null,
    val panoramaType: Pocket3PanoramaType? = null,
    val panoramaPhotoFormat: Pocket3PanoramaPhotoFormat? = null,
    val motionlapseDirection: Pocket3MotionlapseDirection? = null,
    val motionlapseWaypointCount: Int? = null,
    val motionlapsePreviewActive: Boolean? = null,
    val receivedProperties: Set<String> = emptySet(),
) {
    fun apply(record: Pocket3CameraPropertyRecord): Pocket3CameraReadbackState? {
        return when (record.name) {
            "cam_video_param_v2" -> {
                if (record.value.size < 9) return null
                copy(
                    videoResolution = Pocket3VideoResolution.entries.firstOrNull { it.code == record.value.u8(0) },
                    videoFrameRate = Pocket3FrameRate.entries.firstOrNull { it.code == record.value.u8(1) },
                    videoCompression = Pocket3VideoCompression.entries.firstOrNull { it.code == record.value.u8(8) },
                    receivedProperties = receivedProperties + record.name,
                )
            }
            "cam_sensor_aspect_ratio" -> {
                if (record.value.isEmpty()) return null
                copy(
                    sensorAspectRatio = Pocket3SensorAspectRatio.entries.firstOrNull { it.code == record.value.u8(0) },
                    receivedProperties = receivedProperties + record.name,
                )
            }
            "cam_image_effect" -> {
                if (record.value.size < 6) return null
                val wb = when (record.value.u8(4)) {
                    0x00 -> Pocket3WhiteBalanceReadback.Auto
                    0x06 -> Pocket3WhiteBalanceReadback.CustomKelvin(record.value.u8(5) * 100)
                    else -> null
                }
                copy(
                    colorProfile = Pocket3ColorProfile.entries.firstOrNull { it.code == record.value.u8(2) },
                    whiteBalance = wb,
                    receivedProperties = receivedProperties + record.name,
                )
            }
            "cam_expo_param" -> {
                if (record.value.size < 20) return null
                val evCode = record.value.u8(6)
                copy(
                    exposureMode = Pocket3ExposureMode.entries.firstOrNull { it.code == record.value.u8(7) },
                    evThirdStops = if (evCode in 0x07..0x19) evCode - 0x10 else null,
                    effectiveIso = record.value.u32le(16),
                    receivedProperties = receivedProperties + record.name,
                )
            }
            "cam_lens_state" -> {
                if (record.value.isEmpty()) return null
                val focus = when (record.value.u8(0)) {
                    0xB1 -> Pocket3FocusMode.AF_S
                    0xB2 -> Pocket3FocusMode.AF_C
                    else -> null
                }
                copy(focusMode = focus, receivedProperties = receivedProperties + record.name)
            }
            "cam_photo_param" -> {
                if (record.value.size < 13) return null
                copy(
                    photoFrame = Pocket3PhotoFrame.entries.firstOrNull { it.code == record.value.u8(1) },
                    photoFormat = Pocket3PhotoFormat.entries.firstOrNull { it.code == record.value.u8(3) },
                    photoCountdown = Pocket3PhotoCountdown.entries.firstOrNull { it.code == record.value.u8(7) },
                    receivedProperties = receivedProperties + record.name,
                )
            }
            "cam_lapse_param" -> {
                if (record.value.size < 21) return null
                val speedA = record.value.u16le(9)
                val speedB = record.value.u16le(11)
                copy(
                    timelapseOutput = Pocket3TimelapseOutput.entries.firstOrNull { it.code == record.value.u8(0) },
                    timelapseIntervalTenths = record.value.u16le(1),
                    timelapseDurationSeconds = record.value.u32le(5),
                    hyperlapseSpeed = if (speedA == speedB && speedA <= 0xFF) {
                        Pocket3HyperlapseSpeed.entries.firstOrNull { it.code == speedA }
                    } else null,
                    receivedProperties = receivedProperties + record.name,
                )
            }
            "cam_pano_params" -> {
                if (record.value.size < 3) return null
                copy(
                    panoramaType = Pocket3PanoramaType.entries.firstOrNull { it.code == record.value.u8(0) },
                    panoramaPhotoFormat = Pocket3PanoramaPhotoFormat.entries.firstOrNull { it.code == record.value.u8(1) },
                    receivedProperties = receivedProperties + record.name,
                )
            }
            "cam_motionlapse_params" -> {
                if (record.value.size < 8) return null
                val direction = Pocket3MotionlapseDirection.entries.firstOrNull { it.code == record.value.u8(2) }
                copy(
                    motionlapseDirection = direction,
                    motionlapsePreviewActive = record.value.u8(3) == 0x80,
                    motionlapseWaypointCount = if (direction == Pocket3MotionlapseDirection.CUSTOM && record.value.u8(7) <= 4) record.value.u8(7) else null,
                    receivedProperties = receivedProperties + record.name,
                )
            }
            else -> null
        }
    }
}

/** Capture-derived 00/99 property subscription and push decoder. */
object Pocket3CameraPropertyBus {
    val CORE_PROPERTY_NAMES = listOf(
        "cam_video_param_v2",
        "cam_sensor_aspect_ratio",
        "cam_image_effect",
        "cam_expo_param",
        "cam_lens_state",
        "cam_photo_param",
        "cam_lapse_param",
        "cam_pano_params",
        "cam_motionlapse_params",
    )

    fun subscriptionCommand(name: String, transactionId: Long): Pocket3CameraCommand? {
        if (name.any { it.code !in 0..0x7F } || transactionId !in 0..0xFFFF_FFFFL) return null
        val nameBytes = name.toByteArray(Charsets.US_ASCII)
        if (nameBytes.isEmpty() || nameBytes.size > 0xFFFF - 6) return null
        val payload = ArrayList<Byte>(19 + nameBytes.size)
        payload.addAll(listOf(0x02, 0x02, 0x00, 0x00).map(Int::toByte))
        payload.addLe32(transactionId)
        payload.addAll(listOf(0x00, 0x00, 0x00).map(Int::toByte))
        payload.addLe16(nameBytes.size + 6)
        payload.addLe16(nameBytes.size)
        payload.addAll(nameBytes.toList())
        payload.addAll(listOf(0x00, 0x00, 0x00, 0x00).map(Int::toByte))
        return Pocket3CameraCommand(
            set = 0x00,
            command = 0x99,
            payload = payload.toByteArray(),
            receiverType = 0x08,
            receiverId = 1,
            commandType = 2,
            label = "Readback subscribe $name",
        )
    }

    fun parsePush(payload: ByteArray): Pocket3CameraPropertyRecord? {
        if (payload.size < 23 || payload.u8(0) != 0x02 || payload.u8(1) != 0x06 ||
            payload.u8(2) != 0 || payload.u8(3) != 0
        ) return null

        val transactionId = payload.u32le(4)
        val nameLength = payload.u16le(13)
        val nameStart = 15
        val nameEnd = nameStart + nameLength
        if (nameLength <= 0 || nameEnd + 8 > payload.size) return null
        val nameBytes = payload.copyOfRange(nameStart, nameEnd)
        if (nameBytes.any { it.toInt() and 0x80 != 0 }) return null
        val name = nameBytes.toString(Charsets.US_ASCII)
        val valueLengthOffset = nameEnd + 6
        val valueLength = payload.u16le(valueLengthOffset)
        val valueStart = valueLengthOffset + 2
        val valueEnd = valueStart + valueLength
        if (valueEnd > payload.size) return null
        return Pocket3CameraPropertyRecord(transactionId, name, payload.copyOfRange(valueStart, valueEnd))
    }

    private fun ArrayList<Byte>.addLe16(value: Int) {
        add((value and 0xFF).toByte())
        add(((value ushr 8) and 0xFF).toByte())
    }

    private fun ArrayList<Byte>.addLe32(value: Long) {
        add((value and 0xFF).toByte())
        add(((value ushr 8) and 0xFF).toByte())
        add(((value ushr 16) and 0xFF).toByte())
        add(((value ushr 24) and 0xFF).toByte())
    }
}

internal fun ByteArray.u8(offset: Int): Int = this[offset].toInt() and 0xFF

internal fun ByteArray.u16le(offset: Int): Int = u8(offset) or (u8(offset + 1) shl 8)

internal fun ByteArray.u32le(offset: Int): Long =
    u8(offset).toLong() or
        (u8(offset + 1).toLong() shl 8) or
        (u8(offset + 2).toLong() shl 16) or
        (u8(offset + 3).toLong() shl 24)
