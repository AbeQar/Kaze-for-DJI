package com.pocket3.gimbaltest

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Pocket3CameraReadbackTest {
    @Test
    fun capturedSubscriptionEncodingMatchesApprovedVector() {
        val command = Pocket3CameraPropertyBus.subscriptionCommand("cam_video_param_v2", 0x0000_C938)!!
        assertEquals(0x00, command.set)
        assertEquals(0x99, command.command)
        assertEquals(0x08, command.receiverType)
        assertEquals(1, command.receiverId)
        assertEquals(2, command.commandType)
        assertArrayEquals(hex("0202000038c900000000001800120063616d5f766964656f5f706172616d5f763200000000"), command.payload)
    }

    @Test
    fun capturedExposureReadbackParsesConfirmedFields() {
        val record = Pocket3CameraPropertyBus.parsePush(
            hex("02060000882a000000000044000e0063616d5f6578706f5f706172616d0000000000002c0000003c80000013010000000702c80010400600003c8000000000000064000000016501086400000001010000")
        )!!
        val state = Pocket3CameraReadbackState().apply(record)!!
        assertEquals("cam_expo_param", record.name)
        assertEquals(Pocket3ExposureMode.AUTO, state.exposureMode)
        assertEquals(3, state.evThirdStops)
        assertEquals(1600L, state.effectiveIso)
        assertTrue("cam_expo_param" in state.receivedProperties)
    }

    @Test
    fun capturedVideoFormatReadbackParsesConfirmedFields() {
        val record = Pocket3CameraPropertyBus.parsePush(
            hex("020600008d2a00000000002600120063616d5f766964656f5f706172616d5f76320000000000000a0010060000000201000101")
        )!!
        val state = Pocket3CameraReadbackState().apply(record)!!
        assertEquals(Pocket3VideoResolution.P4K, state.videoResolution)
        assertEquals(Pocket3FrameRate.FPS_60, state.videoFrameRate)
        assertEquals(Pocket3VideoCompression.HEVC, state.videoCompression)
    }

    @Test
    fun portraitOrientationAndFocusReadbackUseConfirmedMappings() {
        var state = Pocket3CameraReadbackState()
        state = state.apply(Pocket3CameraPropertyRecord(1, "cam_video_param_v2", hex("6c030000000201000101")))!!
        assertEquals(Pocket3VideoResolution.PORTRAIT_3K, state.videoResolution)
        assertEquals(Pocket3FrameRate.FPS_30, state.videoFrameRate)
        state = state.apply(Pocket3CameraPropertyRecord(2, "cam_sensor_aspect_ratio", byteArrayOf(0x01)))!!
        assertEquals(Pocket3SensorAspectRatio.PORTRAIT, state.sensorAspectRatio)
        state = state.apply(Pocket3CameraPropertyRecord(3, "cam_sensor_aspect_ratio", byteArrayOf(0x00)))!!
        assertEquals(Pocket3SensorAspectRatio.LANDSCAPE, state.sensorAspectRatio)
        state = state.apply(Pocket3CameraPropertyRecord(4, "cam_lens_state", byteArrayOf(0xB2.toByte())))!!
        assertEquals(Pocket3FocusMode.AF_C, state.focusMode)
        state = state.apply(Pocket3CameraPropertyRecord(5, "cam_lens_state", byteArrayOf(0xB1.toByte())))!!
        assertEquals(Pocket3FocusMode.AF_S, state.focusMode)

        state = state.apply(Pocket3CameraPropertyRecord(6, "cam_video_param_v2", hex("10ff00000002010001")))!!
        assertNull(state.videoFrameRate)
    }

    @Test
    fun capturedWhiteBalanceReadbackParsesConfirmedFields() {
        val record = Pocket3CameraPropertyBus.parsePush(
            hex("020600008e2a00000000002a00100063616d5f696d6167655f656666656374000000000000100000003d0006380005000638000000fefe")
        )!!
        val state = Pocket3CameraReadbackState().apply(record)!!
        assertEquals(Pocket3ColorProfile.D_LOG_M, state.colorProfile)
        assertEquals(Pocket3WhiteBalanceReadback.CustomKelvin(5600), state.whiteBalance)
    }

    @Test
    fun malformedOrUnrelatedPropertyDataIsRejected() {
        assertNull(Pocket3CameraPropertyBus.parsePush(ByteArray(22)))
        assertNull(Pocket3CameraReadbackState().apply(Pocket3CameraPropertyRecord(1, "cam_expo_param", ByteArray(19))))
        assertNull(Pocket3CameraReadbackState().apply(Pocket3CameraPropertyRecord(1, "unrelated", byteArrayOf(1))))
        assertNull(Pocket3CameraReadbackState().apply(Pocket3CameraPropertyRecord(1, "cam_video_param_v2", ByteArray(8))))
        assertNull(Pocket3CameraReadbackState().apply(Pocket3CameraPropertyRecord(1, "cam_sensor_aspect_ratio", ByteArray(0))))
        assertNull(Pocket3CameraReadbackState().apply(Pocket3CameraPropertyRecord(1, "cam_lens_state", ByteArray(0))))
        assertEquals(
            listOf(
                "cam_video_param_v2",
                "cam_sensor_aspect_ratio",
                "cam_image_effect",
                "cam_expo_param",
                "cam_lens_state",
                "cam_photo_param",
                "cam_lapse_param",
                "cam_pano_params",
                "cam_motionlapse_params",
            ),
            Pocket3CameraPropertyBus.CORE_PROPERTY_NAMES,
        )
        assertFalse(Pocket3CameraPropertyBus.CORE_PROPERTY_NAMES.any { it.contains("gimbal") })
    }


    @Test
    fun currentIosPhotoLapsePanoramaAndMotionlapseReadbacksMatch() {
        var state = Pocket3CameraReadbackState()
        val photo = ByteArray(13).apply { this[1] = 0x03; this[3] = 0x02; this[7] = 0x05 }
        state = state.apply(Pocket3CameraPropertyRecord(1, "cam_photo_param", photo))!!
        assertEquals(Pocket3PhotoFrame.ONE_BY_ONE, state.photoFrame)
        assertEquals(Pocket3PhotoFormat.JPEG_AND_RAW, state.photoFormat)
        assertEquals(Pocket3PhotoCountdown.SECONDS_5, state.photoCountdown)

        val lapse = ByteArray(21).apply {
            this[0] = 0x02
            this[1] = 0x0A
            this[5] = 0x2C; this[6] = 0x01
            this[9] = 0x0F; this[11] = 0x0F
        }
        state = state.apply(Pocket3CameraPropertyRecord(2, "cam_lapse_param", lapse))!!
        assertEquals(Pocket3TimelapseOutput.JPEG_AND_VIDEO, state.timelapseOutput)
        assertEquals(10, state.timelapseIntervalTenths)
        assertEquals(300L, state.timelapseDurationSeconds)
        assertEquals(Pocket3HyperlapseSpeed.X15, state.hyperlapseSpeed)

        state = state.apply(Pocket3CameraPropertyRecord(3, "cam_pano_params", bytes(0x07, 0x03, 0x00)))!!
        assertEquals(Pocket3PanoramaType.GRID_3X3, state.panoramaType)
        assertEquals(Pocket3PanoramaPhotoFormat.JPEG, state.panoramaPhotoFormat)

        state = state.apply(Pocket3CameraPropertyRecord(4, "cam_motionlapse_params", bytes(0, 0, 0, 0x80, 0, 0, 0, 4)))!!
        assertEquals(Pocket3MotionlapseDirection.CUSTOM, state.motionlapseDirection)
        assertTrue(state.motionlapsePreviewActive == true)
        assertEquals(4, state.motionlapseWaypointCount)
    }

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    private fun hex(value: String): ByteArray = ByteArray(value.length / 2) { index ->
        value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}
