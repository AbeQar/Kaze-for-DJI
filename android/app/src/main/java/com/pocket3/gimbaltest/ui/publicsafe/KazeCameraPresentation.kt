package com.pocket3.gimbaltest.ui.publicsafe

import com.pocket3.gimbaltest.JoystickResponseMode
import com.pocket3.gimbaltest.Pocket3TimelapseOutput
import com.pocket3.gimbaltest.Pocket3PhotoFrame
import com.pocket3.gimbaltest.Pocket3PhotoFormat
import com.pocket3.gimbaltest.Pocket3PhotoCountdown
import com.pocket3.gimbaltest.Pocket3PanoramaType
import com.pocket3.gimbaltest.Pocket3PanoramaPhotoFormat
import com.pocket3.gimbaltest.Pocket3MotionlapseDirection
import com.pocket3.gimbaltest.Pocket3HyperlapseSpeed
import com.pocket3.gimbaltest.Pocket3CameraShootingMode
import com.pocket3.gimbaltest.Pocket3AudioChannel
import com.pocket3.gimbaltest.Pocket3CameraPolicy
import com.pocket3.gimbaltest.Pocket3CameraState
import com.pocket3.gimbaltest.Pocket3ColorProfile
import com.pocket3.gimbaltest.Pocket3ExposureMode
import com.pocket3.gimbaltest.Pocket3FocusMode
import com.pocket3.gimbaltest.Pocket3FrameRate
import com.pocket3.gimbaltest.Pocket3IsoMax
import com.pocket3.gimbaltest.Pocket3ManualIso
import com.pocket3.gimbaltest.Pocket3ManualShutter
import com.pocket3.gimbaltest.Pocket3SensorAspectRatio
import com.pocket3.gimbaltest.Pocket3VideoCompression
import com.pocket3.gimbaltest.Pocket3VideoResolution
import com.pocket3.gimbaltest.Pocket3VideoState
import com.pocket3.gimbaltest.Pocket3VideoStatus
import com.pocket3.gimbaltest.Pocket3WhiteBalance
import com.pocket3.gimbaltest.Pocket3WhiteBalanceReadback

enum class KazeConnectionPhase(val label: String) {
    DISCONNECTED("DISCONNECTED"),
    CONNECTING("CONNECTING"),
    CONNECTED("CONNECTED"),
    DISCONNECTING("DISCONNECTING"),
}

data class KazeCameraUiState(
    val connectionPhase: KazeConnectionPhase = KazeConnectionPhase.DISCONNECTED,
    val connectionDetail: String = "Disconnected",
    val connected: Boolean = false,
    val connectedCameraDisplayName: String? = null,
    val videoStatus: Pocket3VideoStatus = Pocket3VideoStatus.STOPPED,
    val videoWidth: Int? = null,
    val videoHeight: Int? = null,
    val recording: Boolean? = null,
    val recordTransitioning: Boolean = false,
    val canToggleRecording: Boolean = false,
    val shootingMode: String = "—",
    val shootingModeValue: Pocket3CameraShootingMode? = null,
    val formatSummary: String = "—",
    val batterySummary: String = "—",
    val storageSummary: String = "—",
    val timeSummary: String = "—",
    val isoSummary: String = "—",
    val shutterSummary: String = "—",
    val evSummary: String = "—",
    val whiteBalanceSummary: String = "—",
    val focusSummary: String = "—",
    val exposureMode: Pocket3ExposureMode? = null,
    val evThirdStops: Int? = null,
    val sensorAspectRatio: Pocket3SensorAspectRatio? = null,
    val selectedResolution: Pocket3VideoResolution? = null,
    val selectedFrameRate: Pocket3FrameRate? = null,
    val selectedCompression: Pocket3VideoCompression? = null,
    val selectedColor: Pocket3ColorProfile? = null,
    val selectedFocus: Pocket3FocusMode? = null,
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
    val gimbalLocked: Boolean = false,
    val joystickMode: JoystickResponseMode = JoystickResponseMode.LINEAR,
    val isoOptions: List<Pocket3ManualIso> = emptyList(),
    val isoMaxOptions: List<Pocket3IsoMax> = emptyList(),
    val shutterOptions: List<Pocket3ManualShutter> = emptyList(),
    val evOptions: List<Int> = emptyList(),
    val whiteBalanceOptions: List<Pocket3WhiteBalance> = emptyList(),
    val resolutionOptions: List<Pocket3VideoResolution> = emptyList(),
    val frameRateOptions: List<Pocket3FrameRate> = emptyList(),
)

/** Pure adapter from existing domain truth to public-safe presentation values. */
object KazeCameraPresentation {
    fun create(
        connectionPhase: KazeConnectionPhase,
        connectionDetail: String,
        camera: Pocket3CameraState,
        video: Pocket3VideoState,
        joystickMode: JoystickResponseMode,
        connectedCameraDisplayName: String? = null,
        gimbalLocked: Boolean = false,
    ): KazeCameraUiState {
        val readback = camera.readback
        val connected = connectionPhase == KazeConnectionPhase.CONNECTED
        val whiteBalance = when (val wb = readback.whiteBalance) {
            Pocket3WhiteBalanceReadback.Auto -> "AUTO"
            is Pocket3WhiteBalanceReadback.CustomKelvin -> "${wb.kelvin}K"
            null -> "—"
        }
        val orientation = readback.sensorAspectRatio?.displayName?.uppercase() ?: "—"
        val format = if (readback.videoResolution != null && readback.videoFrameRate != null) {
            "${readback.videoResolution.displayName} ${readback.videoFrameRate.displayName} • $orientation"
        } else camera.shootingMode?.let { "${it.displayName.uppercase()} • $orientation" } ?: orientation
        val storage = camera.storageFreeMiB?.let {
            "%.1f GB".format(it * 1_048_576.0 / 1_000_000_000.0)
        } ?: "—"
        val time = when {
            camera.recording == true && camera.elapsedRecordSeconds != null ->
                "REC ${duration(camera.elapsedRecordSeconds)}"
            camera.remainingRecordSeconds != null -> "${duration(camera.remainingRecordSeconds)} remaining"
            else -> "—"
        }
        return KazeCameraUiState(
            connectionPhase = connectionPhase,
            connectionDetail = connectionDetail,
            connected = connected,
            connectedCameraDisplayName = connectedCameraDisplayName.takeIf { connected },
            videoStatus = video.status,
            videoWidth = video.width,
            videoHeight = video.height,
            recording = camera.recording,
            recordTransitioning = camera.recordingTransitionInProgress || camera.recordCommandInFlight,
            canToggleRecording = connected && camera.canToggleRecording,
            shootingMode = camera.shootingMode?.displayName?.uppercase() ?: "—",
            shootingModeValue = camera.shootingMode,
            formatSummary = format,
            batterySummary = camera.batteryPercent?.let { percent ->
                if (camera.batteryCharging == true) "⚡$percent%" else "$percent%"
            } ?: "—",
            storageSummary = storage,
            timeSummary = time,
            isoSummary = readback.effectiveIso?.let { "ISO $it" } ?: "ISO —",
            shutterSummary = "SHUTTER —",
            evSummary = readback.evThirdStops?.let { evLabel(it) } ?: "EV —",
            whiteBalanceSummary = whiteBalance,
            focusSummary = when (readback.focusMode) {
                Pocket3FocusMode.AF_S -> "S-AF"
                Pocket3FocusMode.AF_C -> "C-AF"
                null -> "—"
            },
            exposureMode = readback.exposureMode,
            evThirdStops = readback.evThirdStops,
            sensorAspectRatio = readback.sensorAspectRatio,
            selectedResolution = readback.videoResolution,
            selectedFrameRate = readback.videoFrameRate,
            selectedCompression = readback.videoCompression,
            selectedColor = readback.colorProfile,
            selectedFocus = readback.focusMode,
            photoFrame = readback.photoFrame,
            photoFormat = readback.photoFormat,
            photoCountdown = readback.photoCountdown,
            timelapseIntervalTenths = readback.timelapseIntervalTenths,
            timelapseDurationSeconds = readback.timelapseDurationSeconds,
            timelapseOutput = readback.timelapseOutput,
            hyperlapseSpeed = readback.hyperlapseSpeed,
            panoramaType = readback.panoramaType,
            panoramaPhotoFormat = readback.panoramaPhotoFormat,
            motionlapseDirection = readback.motionlapseDirection,
            motionlapseWaypointCount = readback.motionlapseWaypointCount,
            motionlapsePreviewActive = readback.motionlapsePreviewActive,
            gimbalLocked = gimbalLocked,
            joystickMode = joystickMode,
            isoOptions = Pocket3ManualIso.entries,
            isoMaxOptions = Pocket3IsoMax.entries,
            shutterOptions = Pocket3CameraPolicy.manualShutters(camera.shootingMode, readback.videoFrameRate).orEmpty(),
            evOptions = Pocket3CameraPolicy.evThirdStops().toList(),
            whiteBalanceOptions = listOf(Pocket3WhiteBalance.Auto) +
                Pocket3CameraPolicy.whiteBalanceKelvinValues().map(Pocket3WhiteBalance::CustomKelvin),
            resolutionOptions = Pocket3CameraPolicy.normalVideoResolutions(readback.sensorAspectRatio),
            frameRateOptions = Pocket3CameraPolicy.normalVideoFrameRates(),
        )
    }


    fun photoFrameLabel(value: Pocket3PhotoFrame) = value.displayName
    fun photoFormatLabel(value: Pocket3PhotoFormat) = value.displayName
    fun photoCountdownLabel(value: Pocket3PhotoCountdown) = value.displayName

    fun evLabel(thirdStops: Int): String = "%+.1f EV".format(thirdStops / 3.0)

    fun whiteBalanceLabel(value: Pocket3WhiteBalance): String = when (value) {
        Pocket3WhiteBalance.Auto -> "AUTO"
        is Pocket3WhiteBalance.CustomKelvin -> "${value.kelvin}K"
    }

    private fun duration(totalSeconds: Int): String =
        "%d:%02d".format(totalSeconds / 60, totalSeconds % 60)
}

data class KazeConnectionPresentation(
    val topLabel: String,
    val title: String,
    val device: String?,
    val status: String,
    val action: String,
)

fun kazeConnectionPresentation(state: KazeCameraUiState): KazeConnectionPresentation {
    val cameraName = state.connectedCameraDisplayName.takeIf { state.connected }
    return if (cameraName == null) {
        KazeConnectionPresentation("Cameras", "Cameras", null, "No camera connected", "Connect Camera")
    } else {
        KazeConnectionPresentation(cameraName, "Cameras", cameraName, "Connected", "Disconnect")
    }
}

fun kazePreviewCaptureAspect(
    sensorAspectRatio: Pocket3SensorAspectRatio?,
    resolution: Pocket3VideoResolution?,
): Float = when (resolution) {
    Pocket3VideoResolution.PORTRAIT_1080,
    Pocket3VideoResolution.PORTRAIT_2_7K,
    Pocket3VideoResolution.PORTRAIT_3K -> 9f / 16f

    Pocket3VideoResolution.SQUARE_1080,
    Pocket3VideoResolution.SQUARE_2160,
    Pocket3VideoResolution.SQUARE_3K -> 1f

    Pocket3VideoResolution.P1080,
    Pocket3VideoResolution.P2_7K,
    Pocket3VideoResolution.P4K -> 16f / 9f

    null -> if (sensorAspectRatio == Pocket3SensorAspectRatio.PORTRAIT) 9f / 16f else 16f / 9f
}

fun kazePreviewAspectFill(
    landscape: Boolean,
    showFull16x9: Boolean,
    captureAspect: Float = 16f / 9f,
): Boolean = landscape && !showFull16x9 && captureAspect > 1f
