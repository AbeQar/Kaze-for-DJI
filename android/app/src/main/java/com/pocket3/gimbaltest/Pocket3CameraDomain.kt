package com.pocket3.gimbaltest

enum class Pocket3CameraShootingMode(val code: Int, val displayName: String) {
    SLOW_MOTION(0x00, "Slow Motion"),
    VIDEO(0x01, "Video"),
    TIMELAPSE(0x02, "Timelapse"),
    PHOTO(0x05, "Photo"),
    HYPERLAPSE(0x0A, "Hyperlapse"),
    PANORAMA(0x0C, "Panorama"),
    MOTIONLAPSE(0x18, "Motionlapse"),
    LOW_LIGHT(0x28, "Low-Light"),
}

enum class Pocket3SensorAspectRatio(val code: Int, val displayName: String) {
    LANDSCAPE(0x00, "Landscape"),
    PORTRAIT(0x01, "Portrait"),
}

data class Pocket3CameraStatusFields(
    val storageTotalMiB: Long,
    val storageFreeMiB: Long,
    val remainingRecordSeconds: Int,
    val elapsedRecordSeconds: Int,
    val shootingModeCode: Int,
    val videoLike: Boolean,
)

data class Pocket3CameraState(
    val recording: Boolean? = null,
    val batteryPercent: Int? = null,
    val batteryCharging: Boolean? = null,
    val recordingTransitionInProgress: Boolean = false,
    val recordCommandInFlight: Boolean = false,
    val storageTotalMiB: Long? = null,
    val storageFreeMiB: Long? = null,
    val remainingRecordSeconds: Int? = null,
    val elapsedRecordSeconds: Int? = null,
    val shootingModeCode: Int? = null,
    val readback: Pocket3CameraReadbackState = Pocket3CameraReadbackState(),
) {
    val shootingMode: Pocket3CameraShootingMode?
        get() = Pocket3CameraShootingMode.entries.firstOrNull { it.code == shootingModeCode }

    val canToggleRecording: Boolean
        get() = recording != null && !recordingTransitionInProgress && !recordCommandInFlight

    fun apply(fields: Pocket3CameraStatusFields) = copy(
        storageTotalMiB = fields.storageTotalMiB,
        storageFreeMiB = fields.storageFreeMiB,
        remainingRecordSeconds = fields.remainingRecordSeconds.takeIf { fields.videoLike },
        elapsedRecordSeconds = fields.elapsedRecordSeconds.takeIf { fields.videoLike },
        shootingModeCode = fields.shootingModeCode,
    )

    fun apply(property: Pocket3CameraPropertyRecord): Pocket3CameraState? =
        readback.apply(property)?.let { copy(readback = it) }
}

object Pocket3CameraStatus {
    fun recordingCommand(recording: Boolean) = Pocket3CameraCommand(
        set = 0x02,
        command = 0x02,
        payload = byteArrayOf(if (recording) 0x01 else 0x00),
        label = if (recording) "camera record start" else "camera record stop",
    )

    fun statusFields(payload: ByteArray): Pocket3CameraStatusFields? {
        if (payload.size < 58) return null
        return Pocket3CameraStatusFields(
            storageTotalMiB = payload.u32le(5),
            storageFreeMiB = payload.u32le(9),
            remainingRecordSeconds = payload.u16le(17),
            elapsedRecordSeconds = payload.u16le(29),
            shootingModeCode = payload.u8(57),
            videoLike = payload.u8(4) == 0x01,
        )
    }

    fun recordingActive(statusByte: Int) = statusByte and 0x80 != 0

    fun recordingTransitioning(statusByte: Int) = statusByte and 0x40 != 0

    fun recordRequestResolved(targetRecording: Boolean, statusByte: Int): Boolean =
        recordingTransitioning(statusByte) || recordingActive(statusByte) == targetRecording
}

class Pocket3CameraControl(
    private val sendCommand: (Pocket3CameraCommand) -> Unit,
    private val setRecordingHandler: (Boolean) -> Unit,
) {
    fun setVideoFormat(resolution: Pocket3VideoResolution, frameRate: Pocket3FrameRate) =
        sendCommand(Pocket3CameraSettings.videoFormat(resolution, frameRate))

    fun setVideoCompression(compression: Pocket3VideoCompression) =
        sendCommand(Pocket3CameraSettings.videoCompression(compression))

    fun setExposureMode(mode: Pocket3ExposureMode) = sendCommand(Pocket3CameraSettings.exposureMode(mode))
    fun setManualIso(iso: Pocket3ManualIso) = sendCommand(Pocket3CameraSettings.manualIso(iso))
    fun setIsoMax(isoMax: Pocket3IsoMax) = sendCommand(Pocket3CameraSettings.isoMax(isoMax))
    fun setManualShutter(shutter: Pocket3ManualShutter) = sendCommand(Pocket3CameraSettings.manualShutter(shutter))

    fun setAutoEv(thirdStops: Int): Boolean {
        val command = Pocket3CameraSettings.autoEv(thirdStops) ?: return false
        sendCommand(command)
        return true
    }

    fun setWhiteBalance(whiteBalance: Pocket3WhiteBalance): Boolean {
        val command = Pocket3CameraSettings.whiteBalance(whiteBalance) ?: return false
        sendCommand(command)
        return true
    }

    fun setColorProfile(profile: Pocket3ColorProfile) =
        sendCommand(Pocket3CameraSettings.colorProfile(profile))

    fun setFocusMode(mode: Pocket3FocusMode) = sendCommand(Pocket3CameraSettings.focusMode(mode))

    fun setVideoFormat(
        resolution: Pocket3VideoResolution,
        frameRate: Pocket3FrameRate,
        slowMotionMultiplier: Pocket3SlowMotionMultiplier,
    ) = sendCommand(Pocket3CameraSettings.videoFormat(resolution, frameRate, slowMotionMultiplier))

    fun setTimelapseMotionMode(mode: Pocket3CameraShootingMode) = sendCommand(Pocket3CameraSettings.timelapseMotionMode(mode))
    fun setProEnabled(enabled: Boolean) = sendCommand(Pocket3CameraSettings.proEnabled(enabled))
    fun setProductShowcaseEnabled(enabled: Boolean) = sendCommand(Pocket3CameraSettings.productShowcaseEnabled(enabled))
    fun shootPhoto() = sendCommand(Pocket3CameraSettings.shootPhoto())
    fun setPhotoFrame(frame: Pocket3PhotoFrame) = sendCommand(Pocket3CameraSettings.photoFrame(frame))
    fun setPhotoFormat(format: Pocket3PhotoFormat) = sendCommand(Pocket3CameraSettings.photoFormat(format))
    fun setPhotoCountdown(countdown: Pocket3PhotoCountdown) = sendCommand(Pocket3CameraSettings.photoCountdown(countdown))
    fun setTimelapse(configuration: Pocket3TimelapseConfiguration) = sendCommand(Pocket3CameraSettings.timelapse(configuration))
    fun setHyperlapseSpeed(speed: Pocket3HyperlapseSpeed) = sendCommand(Pocket3CameraSettings.hyperlapseSpeed(speed))
    fun setPanoramaType(type: Pocket3PanoramaType) = sendCommand(Pocket3CameraSettings.panoramaType(type))
    fun setPanoramaPhotoFormat(format: Pocket3PanoramaPhotoFormat) = sendCommand(Pocket3CameraSettings.panoramaPhotoFormat(format))
    fun shootPanorama() = sendCommand(Pocket3CameraSettings.shootPanorama())
    fun setAudioChannel(channel: Pocket3AudioChannel) = sendCommand(Pocket3CameraSettings.audioChannel(channel))
    fun setMotionlapseDirection(direction: Pocket3MotionlapseDirection) = sendCommand(Pocket3CameraSettings.motionlapseDirection(direction))
    fun previewMotionlapse() = sendCommand(Pocket3CameraSettings.motionlapsePreview())
    fun addMotionlapseWaypoint(
        slot: Int, intervalTenths: Int, durationSeconds: Long, pitchTenths: Int, rollTenths: Int, yawTenths: Int,
    ) = sendCommand(Pocket3CameraSettings.motionlapseWaypoint(slot, intervalTenths, durationSeconds, pitchTenths, rollTenths, yawTenths))
    fun deleteMotionlapseWaypoint(slot: Int, intervalTenths: Int, durationSeconds: Long) =
        sendCommand(Pocket3CameraSettings.deleteMotionlapseWaypoint(slot, intervalTenths, durationSeconds))

    fun setRecording(recording: Boolean) = setRecordingHandler(recording)
}

/** Rules used by the development UI without depending on Activity or private controller features. */
object Pocket3CameraPolicy {
    private val normalFrameRates = listOf(
        Pocket3FrameRate.FPS_24,
        Pocket3FrameRate.FPS_25,
        Pocket3FrameRate.FPS_30,
        Pocket3FrameRate.FPS_48,
        Pocket3FrameRate.FPS_50,
        Pocket3FrameRate.FPS_60,
    )

    private val landscapeResolutions = listOf(
        Pocket3VideoResolution.P1080,
        Pocket3VideoResolution.P2_7K,
        Pocket3VideoResolution.P4K,
        Pocket3VideoResolution.SQUARE_1080,
        Pocket3VideoResolution.SQUARE_2160,
        Pocket3VideoResolution.SQUARE_3K,
    )

    private val portraitResolutions = listOf(
        Pocket3VideoResolution.PORTRAIT_1080,
        Pocket3VideoResolution.PORTRAIT_2_7K,
        Pocket3VideoResolution.PORTRAIT_3K,
    )

    fun evThirdStops() = -9..9

    fun whiteBalanceKelvinValues() = (2000..10_000 step 100)

    fun normalVideoFrameRates(): List<Pocket3FrameRate> = normalFrameRates

    fun normalVideoResolutions(aspectRatio: Pocket3SensorAspectRatio?): List<Pocket3VideoResolution> =
        when (aspectRatio) {
            Pocket3SensorAspectRatio.LANDSCAPE -> landscapeResolutions
            Pocket3SensorAspectRatio.PORTRAIT -> portraitResolutions
            null -> emptyList()
        }

    fun videoFormatSupported(
        resolution: Pocket3VideoResolution,
        aspectRatio: Pocket3SensorAspectRatio,
    ): Boolean = resolution in normalVideoResolutions(aspectRatio)

    data class VideoPreset(
        val resolution: Pocket3VideoResolution,
        val frameRate: Pocket3FrameRate,
        val slowMotionMultiplier: Pocket3SlowMotionMultiplier = Pocket3SlowMotionMultiplier.NONE,
        val label: String,
    )

    fun slowMotionPresets() = listOf(
        VideoPreset(Pocket3VideoResolution.P4K, Pocket3FrameRate.FPS_120, Pocket3SlowMotionMultiplier.X4, "4K / 120 / 4×"),
        VideoPreset(Pocket3VideoResolution.P2_7K, Pocket3FrameRate.FPS_120, Pocket3SlowMotionMultiplier.X4, "2.7K / 120 / 4×"),
        VideoPreset(Pocket3VideoResolution.P1080, Pocket3FrameRate.FPS_120, Pocket3SlowMotionMultiplier.X4, "1080 / 120 / 4×"),
        VideoPreset(Pocket3VideoResolution.P1080, Pocket3FrameRate.FPS_240, Pocket3SlowMotionMultiplier.X8, "1080 / 240 / 8×"),
    )

    fun lowLightPresets() = listOf(
        Pocket3VideoResolution.P1080, Pocket3VideoResolution.P4K,
    ).flatMap { resolution ->
        listOf(Pocket3FrameRate.FPS_24, Pocket3FrameRate.FPS_25, Pocket3FrameRate.FPS_30).map { fps ->
            VideoPreset(resolution, fps, label = "${resolution.displayName} / ${fps.displayName}")
        }
    }

    fun hyperlapsePresets() = listOf(
        VideoPreset(Pocket3VideoResolution.P1080, Pocket3FrameRate.FPS_25, label = "1080p / 25"),
        VideoPreset(Pocket3VideoResolution.P2_7K, Pocket3FrameRate.FPS_30, label = "2.7K / 30"),
        VideoPreset(Pocket3VideoResolution.P4K, Pocket3FrameRate.FPS_30, label = "4K / 30"),
    )

    val timelapseIntervalsTenths = listOf(5, 10, 20, 30, 40, 50, 60, 80, 100, 150, 200, 250, 300, 400, 600)
    val timelapseDurationsSeconds = listOf(0L, 300L, 600L, 1200L, 1800L, 3600L, 7200L, 10800L, 18000L)

    fun timelapseIntervalLabel(tenths: Int): String = when {
        tenths == 600 -> "1 m"
        tenths % 10 == 0 -> "${tenths / 10} s"
        else -> "${tenths / 10.0} s"
    }

    fun timelapseDurationLabel(seconds: Long): String = when (seconds) {
        0L -> "∞"
        300L -> "5 m"
        600L -> "10 m"
        1200L -> "20 m"
        1800L -> "30 m"
        3600L -> "1 h"
        7200L -> "2 h"
        10800L -> "3 h"
        18000L -> "5 h"
        else -> "${seconds}s"
    }

    fun manualShutters(
        shootingMode: Pocket3CameraShootingMode?,
        frameRate: Pocket3FrameRate?,
    ): List<Pocket3ManualShutter>? {
        return when (shootingMode) {
            Pocket3CameraShootingMode.PHOTO -> Pocket3ManualShutter.entries
            Pocket3CameraShootingMode.VIDEO -> {
                val minimum = minimumVideoShutterDenominator(frameRate) ?: return null
                Pocket3ManualShutter.entries.filter { it.reciprocalDenominator >= minimum }
            }
            else -> null
        }
    }

    private fun minimumVideoShutterDenominator(frameRate: Pocket3FrameRate?): Double? =
        when (frameRate) {
            Pocket3FrameRate.FPS_24, Pocket3FrameRate.FPS_25 -> 25.0
            Pocket3FrameRate.FPS_30 -> 30.0
            Pocket3FrameRate.FPS_48, Pocket3FrameRate.FPS_50 -> 50.0
            Pocket3FrameRate.FPS_60 -> 60.0
            Pocket3FrameRate.FPS_120 -> 120.0
            Pocket3FrameRate.FPS_240 -> 240.0
            null -> null
        }
}
