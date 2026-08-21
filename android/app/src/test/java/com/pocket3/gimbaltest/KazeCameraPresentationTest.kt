package com.pocket3.gimbaltest

import com.pocket3.gimbaltest.ui.publicsafe.KazeCameraPresentation
import com.pocket3.gimbaltest.ui.publicsafe.KazeCameraUiState
import com.pocket3.gimbaltest.ui.publicsafe.KazeConnectionPhase
import com.pocket3.gimbaltest.ui.publicsafe.KAZE_BOTTOM_CONTROL_ORDER
import com.pocket3.gimbaltest.ui.publicsafe.KAZE_DESTINATION_FOR_CONTROL
import com.pocket3.gimbaltest.ui.publicsafe.KazeCameraDestination
import com.pocket3.gimbaltest.ui.publicsafe.KazeVideoOverlayKind
import com.pocket3.gimbaltest.ui.publicsafe.kazeVideoOverlay
import com.pocket3.gimbaltest.ui.publicsafe.kazeConnectionPresentation
import com.pocket3.gimbaltest.ui.publicsafe.kazePreviewAspectFill
import com.pocket3.gimbaltest.ui.publicsafe.kazePreviewCaptureAspect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KazeCameraPresentationTest {
    @Test
    fun confirmedCameraReadbackBecomesCameraUiState() {
        val camera = Pocket3CameraState(
            recording = true,
            storageTotalMiB = 64_000,
            storageFreeMiB = 32_000,
            remainingRecordSeconds = 600,
            elapsedRecordSeconds = 65,
            shootingModeCode = Pocket3CameraShootingMode.VIDEO.code,
            readback = Pocket3CameraReadbackState(
                videoResolution = Pocket3VideoResolution.P4K,
                videoFrameRate = Pocket3FrameRate.FPS_30,
                sensorAspectRatio = Pocket3SensorAspectRatio.LANDSCAPE,
                videoCompression = Pocket3VideoCompression.HEVC,
                colorProfile = Pocket3ColorProfile.D_LOG_M,
                whiteBalance = Pocket3WhiteBalanceReadback.CustomKelvin(5600),
                exposureMode = Pocket3ExposureMode.MANUAL,
                evThirdStops = -2,
                effectiveIso = 400,
                focusMode = Pocket3FocusMode.AF_C,
            ),
        )

        val ui = KazeCameraPresentation.create(
            KazeConnectionPhase.CONNECTED,
            "Connected",
            camera,
            Pocket3VideoState(status = Pocket3VideoStatus.DECODING),
            JoystickResponseMode.PROGRESSIVE,
        )

        assertTrue(ui.connected)
        assertEquals("4K 30 fps • LANDSCAPE", ui.formatSummary)
        assertEquals("ISO 400", ui.isoSummary)
        assertEquals("-0.7 EV", ui.evSummary)
        assertEquals("5600K", ui.whiteBalanceSummary)
        assertEquals("REC 1:05", ui.timeSummary)
        assertEquals(Pocket3VideoStatus.DECODING, ui.videoStatus)
        assertEquals("C-AF", ui.focusSummary)
        assertEquals(Pocket3VideoCompression.HEVC, ui.selectedCompression)
        assertEquals(Pocket3ColorProfile.D_LOG_M, ui.selectedColor)
        assertEquals(Pocket3FocusMode.AF_C, ui.selectedFocus)
        assertEquals(JoystickResponseMode.PROGRESSIVE, ui.joystickMode)
    }

    @Test
    fun presentationOptionsComeFromExistingCameraPolicy() {
        val ui = KazeCameraPresentation.create(
            KazeConnectionPhase.CONNECTED,
            "Connected",
            Pocket3CameraState(
                shootingModeCode = Pocket3CameraShootingMode.VIDEO.code,
                readback = Pocket3CameraReadbackState(
                    sensorAspectRatio = Pocket3SensorAspectRatio.PORTRAIT,
                    videoFrameRate = Pocket3FrameRate.FPS_60,
                ),
            ),
            Pocket3VideoState(),
            JoystickResponseMode.LINEAR,
        )

        assertEquals(
            Pocket3CameraPolicy.normalVideoResolutions(Pocket3SensorAspectRatio.PORTRAIT),
            ui.resolutionOptions,
        )
        assertEquals(Pocket3CameraPolicy.normalVideoFrameRates(), ui.frameRateOptions)
        assertEquals(
            Pocket3CameraPolicy.manualShutters(Pocket3CameraShootingMode.VIDEO, Pocket3FrameRate.FPS_60),
            ui.shutterOptions,
        )
        assertEquals(Pocket3CameraPolicy.evThirdStops().toList(), ui.evOptions)
    }

    @Test
    fun disconnectedPresentationDoesNotClaimCameraControlReadiness() {
        val ui = KazeCameraPresentation.create(
            KazeConnectionPhase.DISCONNECTED,
            "Disconnected",
            Pocket3CameraState(recording = false),
            Pocket3VideoState(status = Pocket3VideoStatus.STOPPED),
            JoystickResponseMode.LINEAR,
        )

        assertFalse(ui.connected)
        assertFalse(ui.canToggleRecording)
        assertEquals(Pocket3VideoStatus.STOPPED, ui.videoStatus)
        assertEquals("—", ui.storageSummary)
    }

    @Test
    fun productionVideoOverlayUsesStructuredState() {
        assertEquals(
            KazeVideoOverlayKind.NONE,
            kazeVideoOverlay(true, Pocket3VideoStatus.DECODING).kind,
        )
        assertEquals(
            KazeVideoOverlayKind.STARTING,
            kazeVideoOverlay(true, Pocket3VideoStatus.WAITING_FOR_VIDEO).kind,
        )
        assertEquals(
            KazeVideoOverlayKind.ERROR,
            kazeVideoOverlay(true, Pocket3VideoStatus.ERROR).kind,
        )
        assertEquals(
            KazeVideoOverlayKind.DISCONNECTED,
            kazeVideoOverlay(false, Pocket3VideoStatus.STOPPED).kind,
        )
    }

    @Test
    fun bottomStripOrderAndDestinationsMatchCanonicalProductLayout() {
        assertEquals(listOf("MODE", "WB", "EV", "FOCUS", "CAMERA", "TOOLS"), KAZE_BOTTOM_CONTROL_ORDER)
        assertEquals(KazeCameraDestination.MODE, KAZE_DESTINATION_FOR_CONTROL["MODE"])
        assertEquals(KazeCameraDestination.WHITE_BALANCE, KAZE_DESTINATION_FOR_CONTROL["WB"])
        assertEquals(KazeCameraDestination.EXPOSURE, KAZE_DESTINATION_FOR_CONTROL["EV"])
        assertEquals(KazeCameraDestination.FOCUS, KAZE_DESTINATION_FOR_CONTROL["FOCUS"])
        assertEquals(KazeCameraDestination.CAMERA, KAZE_DESTINATION_FOR_CONTROL["CAMERA"])
        assertFalse(KAZE_DESTINATION_FOR_CONTROL.containsKey("TOOLS"))
    }

    @Test
    fun disconnectedCameraHubPresentationUsesProductCopy() {
        val presentation = kazeConnectionPresentation(KazeCameraUiState())

        assertEquals("Cameras", presentation.topLabel)
        assertEquals("Cameras", presentation.title)
        assertEquals(null, presentation.device)
        assertEquals("No camera connected", presentation.status)
        assertEquals("Connect Camera", presentation.action)
    }


    @Test
    fun decoderDimensionsAreExposedForPreviewGeometry() {
        val ui = KazeCameraPresentation.create(
            KazeConnectionPhase.CONNECTED,
            "Connected",
            Pocket3CameraState(),
            Pocket3VideoState(status = Pocket3VideoStatus.DECODING, width = 1280, height = 720),
            JoystickResponseMode.LINEAR,
        )

        assertEquals(1280, ui.videoWidth)
        assertEquals(720, ui.videoHeight)
    }

    @Test
    fun connectedCameraDisplayNameIsUsedVerbatim() {
        val ui = KazeCameraPresentation.create(
            KazeConnectionPhase.CONNECTED,
            "Connected",
            Pocket3CameraState(),
            Pocket3VideoState(),
            JoystickResponseMode.LINEAR,
            connectedCameraDisplayName = "Pocket 4P",
        )
        val presentation = kazeConnectionPresentation(ui)

        assertEquals("Pocket 4P", presentation.topLabel)
        assertEquals("Pocket 4P", presentation.device)
        assertEquals("Connected", presentation.status)
        assertEquals("Disconnect", presentation.action)
    }

    @Test
    fun full16x9PreferenceKeepsApprovedFitFillSemantics() {
        assertFalse(kazePreviewAspectFill(landscape = false, showFull16x9 = false))
        assertTrue(kazePreviewAspectFill(landscape = true, showFull16x9 = false))
        assertFalse(kazePreviewAspectFill(landscape = true, showFull16x9 = true))
        assertFalse(
            kazePreviewAspectFill(
                landscape = true,
                showFull16x9 = false,
                captureAspect = 9f / 16f,
            ),
        )
    }

    @Test
    fun previewCaptureAspectFollowsConfirmedRecordingFrame() {
        assertEquals(
            9f / 16f,
            kazePreviewCaptureAspect(Pocket3SensorAspectRatio.PORTRAIT, Pocket3VideoResolution.PORTRAIT_3K),
        )
        assertEquals(
            1f,
            kazePreviewCaptureAspect(Pocket3SensorAspectRatio.LANDSCAPE, Pocket3VideoResolution.SQUARE_3K),
        )
        assertEquals(
            16f / 9f,
            kazePreviewCaptureAspect(Pocket3SensorAspectRatio.LANDSCAPE, Pocket3VideoResolution.P4K),
        )
        assertEquals(
            9f / 16f,
            kazePreviewCaptureAspect(Pocket3SensorAspectRatio.PORTRAIT, null),
        )
    }
}
