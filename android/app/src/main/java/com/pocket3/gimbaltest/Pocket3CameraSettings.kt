package com.pocket3.gimbaltest

data class Pocket3CameraCommand(
    val set: Int,
    val command: Int,
    val payload: ByteArray,
    val receiverType: Int = 0x01,
    val receiverId: Int = 0,
    val commandType: Int = 2,
    val label: String,
) {
    override fun equals(other: Any?): Boolean =
        other is Pocket3CameraCommand &&
            set == other.set && command == other.command && payload.contentEquals(other.payload) &&
            receiverType == other.receiverType && receiverId == other.receiverId &&
            commandType == other.commandType && label == other.label

    override fun hashCode(): Int {
        var result = set
        result = 31 * result + command
        result = 31 * result + payload.contentHashCode()
        result = 31 * result + receiverType
        result = 31 * result + receiverId
        result = 31 * result + commandType
        return 31 * result + label.hashCode()
    }
}

enum class Pocket3ExposureMode(val code: Int, val displayName: String) {
    AUTO(0x01, "Auto"),
    MANUAL(0x04, "Manual"),
}

enum class Pocket3VideoResolution(val code: Int, val displayName: String) {
    P1080(0x0A, "1080p"),
    P4K(0x10, "4K"),
    P2_7K(0x2D, "2.7K"),
    PORTRAIT_1080(0x42, "9:16 1080"),
    PORTRAIT_2_7K(0x43, "9:16 2.7K"),
    SQUARE_1080(0x69, "1:1 1080"),
    SQUARE_2160(0x6A, "1:1 2160"),
    SQUARE_3K(0x6B, "1:1 3K"),
    PORTRAIT_3K(0x6C, "9:16 3K"),
}

enum class Pocket3FrameRate(val code: Int, val displayName: String) {
    FPS_24(0x01, "24 fps"),
    FPS_25(0x02, "25 fps"),
    FPS_30(0x03, "30 fps"),
    FPS_48(0x04, "48 fps"),
    FPS_50(0x05, "50 fps"),
    FPS_60(0x06, "60 fps"),
    FPS_120(0x07, "120 fps"),
    FPS_240(0x08, "240 fps"),
}

enum class Pocket3VideoCompression(val code: Int, val displayName: String) {
    H264(0x00, "H.264"),
    HEVC(0x01, "HEVC"),
}

enum class Pocket3ColorProfile(val code: Int, val displayName: String) {
    NORMAL(0x00, "Normal"),
    HLG(0x3C, "HLG"),
    D_LOG_M(0x3D, "D-Log M"),
}

enum class Pocket3FocusMode(val code: Int, val displayName: String) {
    AF_S(0x01, "AF-S"),
    AF_C(0x02, "AF-C"),
}

enum class Pocket3ManualIso(val code: Int, val displayName: String) {
    AUTO(0x00, "Auto"),
    ISO_50(0x02, "50"),
    ISO_100(0x03, "100"),
    ISO_200(0x04, "200"),
    ISO_400(0x05, "400"),
    ISO_800(0x06, "800"),
    ISO_1600(0x07, "1600"),
    ISO_3200(0x08, "3200"),
    ISO_6400(0x09, "6400"),
}

enum class Pocket3IsoMax(val code: Int, val displayName: String) {
    ISO_100(0x01, "100"),
    ISO_200(0x02, "200"),
    ISO_400(0x03, "400"),
    ISO_800(0x04, "800"),
    ISO_1600(0x05, "1600"),
    ISO_3200(0x06, "3200"),
    ISO_6400(0x07, "6400"),
}

enum class Pocket3ManualShutter(
    val displayName: String,
    val reciprocalDenominator: Double,
) {
    ONE_SECOND("1\"", 1.0),
    RECIPROCAL_1_25("1/1.25", 1.25),
    RECIPROCAL_1_67("1/1.67", 1.67),
    RECIPROCAL_2("1/2", 2.0),
    RECIPROCAL_2_5("1/2.5", 2.5),
    RECIPROCAL_3("1/3", 3.0),
    RECIPROCAL_4("1/4", 4.0),
    RECIPROCAL_5("1/5", 5.0),
    RECIPROCAL_6_25("1/6.25", 6.25),
    RECIPROCAL_8("1/8", 8.0),
    RECIPROCAL_10("1/10", 10.0),
    RECIPROCAL_12_5("1/12.5", 12.5),
    RECIPROCAL_15("1/15", 15.0),
    RECIPROCAL_20("1/20", 20.0),
    RECIPROCAL_25("1/25", 25.0),
    RECIPROCAL_30("1/30", 30.0),
    RECIPROCAL_40("1/40", 40.0),
    RECIPROCAL_50("1/50", 50.0),
    RECIPROCAL_60("1/60", 60.0),
    RECIPROCAL_80("1/80", 80.0),
    RECIPROCAL_100("1/100", 100.0),
    RECIPROCAL_120("1/120", 120.0),
    RECIPROCAL_160("1/160", 160.0),
    RECIPROCAL_200("1/200", 200.0),
    RECIPROCAL_240("1/240", 240.0),
    RECIPROCAL_320("1/320", 320.0),
    RECIPROCAL_400("1/400", 400.0),
    RECIPROCAL_500("1/500", 500.0),
    RECIPROCAL_640("1/640", 640.0),
    RECIPROCAL_800("1/800", 800.0),
    RECIPROCAL_1000("1/1000", 1000.0),
    RECIPROCAL_1250("1/1250", 1250.0),
    RECIPROCAL_1600("1/1600", 1600.0),
    RECIPROCAL_2000("1/2000", 2000.0),
    RECIPROCAL_2500("1/2500", 2500.0),
    RECIPROCAL_3200("1/3200", 3200.0),
    RECIPROCAL_4000("1/4000", 4000.0),
    RECIPROCAL_5000("1/5000", 5000.0),
    RECIPROCAL_6400("1/6400", 6400.0),
    RECIPROCAL_8000("1/8000", 8000.0),
}


enum class Pocket3SlowMotionMultiplier(val code: Int, val displayName: String) {
    NONE(0x00, "Normal"),
    X4(0x04, "4×"),
    X8(0x08, "8×"),
}

enum class Pocket3PhotoFrame(val code: Int, val displayName: String) {
    SIXTEEN_BY_NINE(0x01, "16:9"),
    ONE_BY_ONE(0x03, "1:1"),
}

enum class Pocket3PhotoFormat(val code: Int, val displayName: String) {
    JPEG(0x01, "JPEG"),
    JPEG_AND_RAW(0x02, "JPEG+RAW"),
}

enum class Pocket3PhotoCountdown(val code: Int, val displayName: String) {
    OFF(0, "Off"),
    SECONDS_3(3, "3 s"),
    SECONDS_5(5, "5 s"),
    SECONDS_7(7, "7 s"),
}

enum class Pocket3TimelapseOutput(val code: Int, val displayName: String) {
    VIDEO(0x00, "Video"),
    JPEG_AND_VIDEO(0x02, "JPEG+Video"),
    RAW_AND_VIDEO(0x03, "RAW+Video"),
}

data class Pocket3TimelapseConfiguration(
    val intervalTenths: Int,
    val durationSeconds: Long,
    val output: Pocket3TimelapseOutput,
)

enum class Pocket3HyperlapseSpeed(val code: Int, val displayName: String) {
    AUTO(0x00, "Auto"),
    X2(0x02, "2×"),
    X5(0x05, "5×"),
    X10(0x0A, "10×"),
    X15(0x0F, "15×"),
    X30(0x1E, "30×"),
}

enum class Pocket3PanoramaType(val code: Int, val displayName: String) {
    DEGREES_180(0x05, "180°"),
    GRID_3X3(0x07, "3×3"),
}

enum class Pocket3PanoramaPhotoFormat(val code: Int, val displayName: String) {
    RAW(0x01, "RAW"),
    JPEG(0x03, "JPEG"),
}

enum class Pocket3AudioChannel(val code: Int, val displayName: String) {
    MONO(0x01, "Mono"),
    STEREO(0x02, "Stereo"),
}

enum class Pocket3MotionlapseDirection(val code: Int, val displayName: String) {
    CUSTOM(0x00, "Custom"),
    LEFT_TO_RIGHT(0x01, "L→R"),
    RIGHT_TO_LEFT(0x02, "R→L"),
}

sealed interface Pocket3WhiteBalance {
    data object Auto : Pocket3WhiteBalance
    data class CustomKelvin(val kelvin: Int) : Pocket3WhiteBalance
}

/** Capture-confirmed Pocket 3 camera encoders ported from the approved iOS boundary. */
object Pocket3CameraSettings {
    fun videoFormat(
        resolution: Pocket3VideoResolution,
        frameRate: Pocket3FrameRate,
        slowMotionMultiplier: Pocket3SlowMotionMultiplier = Pocket3SlowMotionMultiplier.NONE,
    ) = Pocket3CameraCommand(
        set = 0x02,
        command = 0x18,
        payload = byteArrayOf(
            resolution.code.toByte(), frameRate.code.toByte(), 0x00, slowMotionMultiplier.code.toByte(), 0x00,
        ),
        label = "video format ${resolution.displayName}/${frameRate.displayName} slow=${slowMotionMultiplier.displayName}",
    )

    /** Only the capture-confirmed Timelapse <-> Motionlapse transition is exposed. */
    fun timelapseMotionMode(mode: Pocket3CameraShootingMode): Pocket3CameraCommand {
        require(mode == Pocket3CameraShootingMode.TIMELAPSE || mode == Pocket3CameraShootingMode.MOTIONLAPSE)
        return Pocket3CameraCommand(
            set = 0x02, command = 0xE1, payload = byteArrayOf(mode.code.toByte()),
            label = "shooting mode ${mode.displayName} 02/E1 %02X".format(mode.code),
        )
    }

    fun videoCompression(compression: Pocket3VideoCompression) = Pocket3CameraCommand(
        set = 0x02,
        command = 0xAB,
        payload = byteArrayOf(compression.code.toByte(), 0x00),
        label = "video compression ${compression.displayName}",
    )

    fun proEnabled(enabled: Boolean) = keyedParameter(0x0000, byteArrayOf(if (enabled) 0x01 else 0x00), "Pro")

    fun exposureMode(mode: Pocket3ExposureMode) = Pocket3CameraCommand(
        set = 0x02, command = 0x1E,
        payload = byteArrayOf(mode.code.toByte(), 0x00),
        label = "exposure mode ${mode.displayName}",
    )

    fun manualIso(iso: Pocket3ManualIso) = Pocket3CameraCommand(
        set = 0x02, command = 0x2A, payload = byteArrayOf(iso.code.toByte()),
        label = "manual ISO ${iso.displayName}",
    )

    fun isoMax(isoMax: Pocket3IsoMax) = Pocket3CameraCommand(
        set = 0x02, command = 0x8E,
        payload = byteArrayOf(0x01, 0x01, 0x0F, 0x00, 0x01, isoMax.code.toByte()),
        label = "ISO MAX ${isoMax.displayName}",
    )

    fun manualShutter(shutter: Pocket3ManualShutter) = Pocket3CameraCommand(
        set = 0x02, command = 0x28, payload = shutterPayload(shutter),
        label = "manual shutter ${shutter.displayName}",
    )

    fun autoEv(thirdStops: Int): Pocket3CameraCommand? {
        if (thirdStops !in -9..9) return null
        val code = 0x10 + thirdStops
        return Pocket3CameraCommand(
            set = 0x02, command = 0x2E, payload = byteArrayOf(code.toByte()),
            label = "AUTO EV %+.1f".format(thirdStops / 3.0),
        )
    }

    fun whiteBalance(whiteBalance: Pocket3WhiteBalance): Pocket3CameraCommand? {
        return when (whiteBalance) {
            Pocket3WhiteBalance.Auto -> Pocket3CameraCommand(
                set = 0x02, command = 0x2C, payload = byteArrayOf(0, 0, 0, 0, 0),
                label = "white balance AUTO",
            )
            is Pocket3WhiteBalance.CustomKelvin -> {
                val kelvin = whiteBalance.kelvin
                if (kelvin !in 2000..10_000 || kelvin % 100 != 0) return null
                Pocket3CameraCommand(
                    set = 0x02, command = 0x2C,
                    payload = byteArrayOf(0x06, (kelvin / 100).toByte(), 0, 0, 0),
                    label = "white balance ${kelvin}K",
                )
            }
        }
    }

    fun productShowcaseEnabled(enabled: Boolean) = keyedParameter(
        0x003B, byteArrayOf(0x01, if (enabled) 0x01 else 0x00), "Product Showcase",
    )

    fun shootPhoto() = Pocket3CameraCommand(
        set = 0x02, command = 0x01, payload = byteArrayOf(0x01), label = "shoot photo 02/01 01",
    )

    fun photoFrame(frame: Pocket3PhotoFrame) = Pocket3CameraCommand(
        set = 0x02, command = 0x12, payload = byteArrayOf(0x00, frame.code.toByte()),
        label = "photo frame ${frame.displayName}",
    )

    fun photoFormat(format: Pocket3PhotoFormat) = Pocket3CameraCommand(
        set = 0x02, command = 0x16, payload = byteArrayOf(format.code.toByte()),
        label = "photo format ${format.displayName}",
    )

    fun photoCountdown(countdown: Pocket3PhotoCountdown) = Pocket3CameraCommand(
        set = 0x02, command = 0x4A,
        payload = byteArrayOf(0x00, 0x01, countdown.code.toByte(), 0x00, 0x00, 0x00),
        label = "photo countdown ${countdown.displayName}",
    )

    fun timelapse(configuration: Pocket3TimelapseConfiguration): Pocket3CameraCommand {
        require(configuration.intervalTenths in 0..0xFFFF)
        require(configuration.durationSeconds in 0..0xFFFF_FFFFL)
        val payload = ArrayList<Byte>(16)
        payload.add(0x04.toByte()); payload.add(0x00.toByte()); payload.add(configuration.output.code.toByte())
        payload.addLe16(configuration.intervalTenths)
        payload.addLe32(configuration.durationSeconds)
        repeat(7) { payload.add(0x00.toByte()) }
        return Pocket3CameraCommand(0x02, 0x6C, payload.toByteArray(), label = "timelapse configuration 02/6C")
    }

    fun hyperlapseSpeed(speed: Pocket3HyperlapseSpeed): Pocket3CameraCommand {
        val payload = ByteArray(16)
        payload[0] = 0x0B
        payload[3] = speed.code.toByte()
        return Pocket3CameraCommand(0x02, 0x6C, payload, label = "hyperlapse speed ${speed.displayName}")
    }

    fun panoramaType(type: Pocket3PanoramaType) = Pocket3CameraCommand(
        set = 0x02, command = 0x6E, payload = byteArrayOf(type.code.toByte()), label = "panorama type ${type.displayName}",
    )

    fun panoramaPhotoFormat(format: Pocket3PanoramaPhotoFormat) = Pocket3CameraCommand(
        set = 0x02, command = 0xE7, payload = byteArrayOf(format.code.toByte(), 0x00), label = "panorama format ${format.displayName}",
    )

    fun shootPanorama() = Pocket3CameraCommand(
        set = 0x02, command = 0x01, payload = byteArrayOf(0x07), label = "start panorama 02/01 07",
    )

    fun audioChannel(channel: Pocket3AudioChannel) = keyedParameter(
        0x0020, byteArrayOf(channel.code.toByte()), "Audio Channel",
    )

    fun motionlapseDirection(direction: Pocket3MotionlapseDirection) = keyedParameter(
        0x0037, byteArrayOf(direction.code.toByte()), "Motionlapse Direction",
    )

    fun motionlapsePreview() = keyedParameter(0x0036, byteArrayOf(0x00, 0x00), "Motionlapse Preview")

    fun motionlapseWaypoint(
        slot: Int,
        intervalTenths: Int,
        durationSeconds: Long,
        pitchTenths: Int,
        rollTenths: Int,
        yawTenths: Int,
    ): Pocket3CameraCommand {
        require(slot in 1..4)
        require(intervalTenths in 0..0xFFFF)
        require(durationSeconds in 0..0xFFFF_FFFFL)
        require(pitchTenths in Short.MIN_VALUE..Short.MAX_VALUE)
        require(rollTenths in Short.MIN_VALUE..Short.MAX_VALUE)
        require(yawTenths in Short.MIN_VALUE..Short.MAX_VALUE)
        val token = 0x0005 + (slot - 1) * 4
        val payload = ArrayList<Byte>(16)
        payload.add(0x05.toByte())
        payload.addLe16(token)
        payload.addLe16(intervalTenths)
        payload.addLe32(durationSeconds)
        // Hardware-confirmed axis order: yaw, roll, pitch.
        payload.addLe16(yawTenths and 0xFFFF)
        payload.addLe16(rollTenths and 0xFFFF)
        payload.addLe16(pitchTenths and 0xFFFF)
        payload.add(0x00.toByte())
        return Pocket3CameraCommand(0x02, 0x6C, payload.toByteArray(), label = "Motionlapse waypoint $slot")
    }

    fun deleteMotionlapseWaypoint(slot: Int, intervalTenths: Int, durationSeconds: Long): Pocket3CameraCommand {
        require(slot in 1..4)
        require(intervalTenths in 0..0xFFFF)
        require(durationSeconds in 0..0xFFFF_FFFFL)
        val deleteToken = 0x0006 + (slot - 1) * 4
        val payload = ArrayList<Byte>(16)
        payload.add(0x05.toByte())
        payload.addLe16(deleteToken)
        payload.addLe16(intervalTenths)
        payload.addLe32(durationSeconds)
        repeat(7) { payload.add(0x00.toByte()) }
        return Pocket3CameraCommand(0x02, 0x6C, payload.toByteArray(), label = "Delete Motionlapse waypoint $slot")
    }

    fun colorProfile(profile: Pocket3ColorProfile) = Pocket3CameraCommand(
        set = 0x02,
        command = 0x42,
        payload = byteArrayOf(profile.code.toByte()),
        label = "color profile ${profile.displayName}",
    )

    fun focusMode(mode: Pocket3FocusMode) = Pocket3CameraCommand(
        set = 0x02,
        command = 0x24,
        payload = byteArrayOf(mode.code.toByte()),
        label = "focus mode ${mode.displayName}",
    )

    fun keyedParameter(pid: Int, value: ByteArray, label: String): Pocket3CameraCommand {
        require(pid in 0..0xFFFF && value.size <= 0xFF)
        val payload = ByteArray(5 + value.size)
        payload[0] = 0x01
        payload[1] = 0x01
        payload[2] = (pid and 0xFF).toByte()
        payload[3] = ((pid ushr 8) and 0xFF).toByte()
        payload[4] = value.size.toByte()
        value.copyInto(payload, 5)
        return Pocket3CameraCommand(0x02, 0x8E, payload, label = "$label PID 0x%04X".format(pid))
    }

    private fun ArrayList<Byte>.addLe16(value: Int) {
        add((value and 0xFF).toByte()); add(((value ushr 8) and 0xFF).toByte())
    }

    private fun ArrayList<Byte>.addLe32(value: Long) {
        add((value and 0xFF).toByte()); add(((value ushr 8) and 0xFF).toByte())
        add(((value ushr 16) and 0xFF).toByte()); add(((value ushr 24) and 0xFF).toByte())
    }

    internal fun shutterPayload(shutter: Pocket3ManualShutter): ByteArray = when (shutter) {
        Pocket3ManualShutter.ONE_SECOND -> bytes(0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x40)
        Pocket3ManualShutter.RECIPROCAL_1_25 -> bytes(0x01, 0x01, 0x80, 0x19, 0x00, 0x00, 0x40)
        Pocket3ManualShutter.RECIPROCAL_1_67 -> bytes(0x01, 0x01, 0x80, 0x43, 0x00, 0x00, 0x40)
        Pocket3ManualShutter.RECIPROCAL_2_5 -> bytes(0x01, 0x02, 0x80, 0x05, 0x00, 0x00, 0x40)
        Pocket3ManualShutter.RECIPROCAL_6_25 -> bytes(0x01, 0x06, 0x80, 0x19, 0x00, 0x00, 0x40)
        Pocket3ManualShutter.RECIPROCAL_12_5 -> bytes(0x01, 0x0C, 0x80, 0x05, 0x00, 0x00, 0x40)
        else -> {
            val encoded = 0x8000 or shutter.reciprocalDenominator.toInt()
            bytes(0x01, encoded and 0xFF, (encoded ushr 8) and 0xFF, 0, 0, 0, 0x40)
        }
    }

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }
}
