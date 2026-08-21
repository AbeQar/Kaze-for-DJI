package com.pocket3.gimbaltest

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class Pocket3CameraSettingsTest {
    @Test
    fun videoFormatMappingsMatchApprovedIosVectors() {
        val command = Pocket3CameraSettings.videoFormat(Pocket3VideoResolution.P4K, Pocket3FrameRate.FPS_60)
        assertEquals(0x02, command.set)
        assertEquals(0x18, command.command)
        assertArrayEquals(bytes(0x10, 0x06, 0, 0, 0), command.payload)
        assertArrayEquals(
            bytes(0x42, 0x06, 0, 0, 0),
            Pocket3CameraSettings.videoFormat(Pocket3VideoResolution.PORTRAIT_1080, Pocket3FrameRate.FPS_60).payload,
        )
        assertArrayEquals(
            bytes(0x6C, 0x03, 0, 0, 0),
            Pocket3CameraSettings.videoFormat(Pocket3VideoResolution.PORTRAIT_3K, Pocket3FrameRate.FPS_30).payload,
        )
        assertEquals(
            listOf(0x0A, 0x10, 0x2D, 0x42, 0x43, 0x69, 0x6A, 0x6B, 0x6C),
            Pocket3VideoResolution.entries.map { it.code },
        )
        assertEquals((1..8).toList(), Pocket3FrameRate.entries.map { it.code })
    }

    @Test
    fun colorCompressionAndFocusMappingsMatchApprovedIosVectors() {
        Pocket3ColorProfile.entries.forEach { profile ->
            val command = Pocket3CameraSettings.colorProfile(profile)
            assertEquals(0x42, command.command)
            assertArrayEquals(byteArrayOf(profile.code.toByte()), command.payload)
        }
        Pocket3VideoCompression.entries.forEach { compression ->
            val command = Pocket3CameraSettings.videoCompression(compression)
            assertEquals(0xAB, command.command)
            assertArrayEquals(bytes(compression.code, 0), command.payload)
        }
        Pocket3FocusMode.entries.forEach { focus ->
            val command = Pocket3CameraSettings.focusMode(focus)
            assertEquals(0x24, command.command)
            assertArrayEquals(byteArrayOf(focus.code.toByte()), command.payload)
        }
    }

    @Test
    fun exposureModeUsesConfirmedCommandAndCodes() {
        val auto = Pocket3CameraSettings.exposureMode(Pocket3ExposureMode.AUTO)
        val manual = Pocket3CameraSettings.exposureMode(Pocket3ExposureMode.MANUAL)
        assertEquals(0x02, auto.set)
        assertEquals(0x1E, auto.command)
        assertArrayEquals(bytes(0x01, 0x00), auto.payload)
        assertArrayEquals(bytes(0x04, 0x00), manual.payload)
    }

    @Test
    fun completeIsoMappingsMatchConfirmedTable() {
        assertEquals(listOf(0x00, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09), Pocket3ManualIso.entries.map { it.code })
        Pocket3ManualIso.entries.forEach { iso ->
            val command = Pocket3CameraSettings.manualIso(iso)
            assertEquals(0x02, command.set)
            assertEquals(0x2A, command.command)
            assertArrayEquals(byteArrayOf(iso.code.toByte()), command.payload)
        }
    }

    @Test
    fun completeIsoMaxMappingsUseConfirmedKeyedParameter() {
        assertEquals((1..7).toList(), Pocket3IsoMax.entries.map { it.code })
        Pocket3IsoMax.entries.forEach { isoMax ->
            val command = Pocket3CameraSettings.isoMax(isoMax)
            assertEquals(0x02, command.set)
            assertEquals(0x8E, command.command)
            assertArrayEquals(bytes(0x01, 0x01, 0x0F, 0x00, 0x01, isoMax.code), command.payload)
        }
    }

    @Test
    fun shutterSpecialFractionalPayloadsMatchApprovedIosEncoder() {
        val vectors = mapOf(
            Pocket3ManualShutter.ONE_SECOND to bytes(0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x40),
            Pocket3ManualShutter.RECIPROCAL_1_25 to bytes(0x01, 0x01, 0x80, 0x19, 0x00, 0x00, 0x40),
            Pocket3ManualShutter.RECIPROCAL_1_67 to bytes(0x01, 0x01, 0x80, 0x43, 0x00, 0x00, 0x40),
            Pocket3ManualShutter.RECIPROCAL_2_5 to bytes(0x01, 0x02, 0x80, 0x05, 0x00, 0x00, 0x40),
            Pocket3ManualShutter.RECIPROCAL_6_25 to bytes(0x01, 0x06, 0x80, 0x19, 0x00, 0x00, 0x40),
            Pocket3ManualShutter.RECIPROCAL_12_5 to bytes(0x01, 0x0C, 0x80, 0x05, 0x00, 0x00, 0x40),
        )
        vectors.forEach { (shutter, payload) ->
            assertArrayEquals(shutter.displayName, payload, Pocket3CameraSettings.manualShutter(shutter).payload)
        }
    }

    @Test
    fun completeShutterMenuAndIntegerExamplesMatchConfirmedEncoding() {
        assertEquals(40, Pocket3ManualShutter.entries.size)
        assertEquals("1\"", Pocket3ManualShutter.entries.first().displayName)
        assertEquals("1/8000", Pocket3ManualShutter.entries.last().displayName)
        assertArrayEquals(bytes(0x01, 0x1E, 0x80, 0, 0, 0, 0x40), Pocket3CameraSettings.manualShutter(Pocket3ManualShutter.RECIPROCAL_30).payload)
        assertArrayEquals(bytes(0x01, 0x3C, 0x80, 0, 0, 0, 0x40), Pocket3CameraSettings.manualShutter(Pocket3ManualShutter.RECIPROCAL_60).payload)
        assertArrayEquals(bytes(0x01, 0xE8, 0x83, 0, 0, 0, 0x40), Pocket3CameraSettings.manualShutter(Pocket3ManualShutter.RECIPROCAL_1000).payload)
        assertArrayEquals(bytes(0x01, 0x40, 0x9F, 0, 0, 0, 0x40), Pocket3CameraSettings.manualShutter(Pocket3ManualShutter.RECIPROCAL_8000).payload)
    }

    @Test
    fun evAndWhiteBalanceMappingsRejectUnconfirmedValues() {
        assertArrayEquals(bytes(0x07), Pocket3CameraSettings.autoEv(-9)?.payload)
        assertArrayEquals(bytes(0x10), Pocket3CameraSettings.autoEv(0)?.payload)
        assertArrayEquals(bytes(0x19), Pocket3CameraSettings.autoEv(9)?.payload)
        assertNull(Pocket3CameraSettings.autoEv(10))
        assertArrayEquals(bytes(0, 0, 0, 0, 0), Pocket3CameraSettings.whiteBalance(Pocket3WhiteBalance.Auto)?.payload)
        assertArrayEquals(bytes(0x06, 0x38, 0, 0, 0), Pocket3CameraSettings.whiteBalance(Pocket3WhiteBalance.CustomKelvin(5600))?.payload)
        assertNull(Pocket3CameraSettings.whiteBalance(Pocket3WhiteBalance.CustomKelvin(5650)))
    }


    @Test
    fun modeSpecificCameraCommandsMatchCurrentIosVectors() {
        assertEquals((1..8).toList(), Pocket3FrameRate.entries.map { it.code })
        assertArrayEquals(
            bytes(0x10, 0x07, 0x00, 0x04, 0x00),
            Pocket3CameraSettings.videoFormat(
                Pocket3VideoResolution.P4K,
                Pocket3FrameRate.FPS_120,
                Pocket3SlowMotionMultiplier.X4,
            ).payload,
        )
        assertArrayEquals(bytes(0x18), Pocket3CameraSettings.timelapseMotionMode(Pocket3CameraShootingMode.MOTIONLAPSE).payload)
        assertArrayEquals(bytes(0x02), Pocket3CameraSettings.timelapseMotionMode(Pocket3CameraShootingMode.TIMELAPSE).payload)
        assertArrayEquals(bytes(0x01, 0x01, 0x00, 0x00, 0x01, 0x01), Pocket3CameraSettings.proEnabled(true).payload)
        assertArrayEquals(bytes(0x01, 0x01, 0x3B, 0x00, 0x02, 0x01, 0x01), Pocket3CameraSettings.productShowcaseEnabled(true).payload)
        assertArrayEquals(bytes(0x01), Pocket3CameraSettings.shootPhoto().payload)
        assertArrayEquals(bytes(0x00, 0x03), Pocket3CameraSettings.photoFrame(Pocket3PhotoFrame.ONE_BY_ONE).payload)
        assertArrayEquals(bytes(0x02), Pocket3CameraSettings.photoFormat(Pocket3PhotoFormat.JPEG_AND_RAW).payload)
        assertArrayEquals(bytes(0x00, 0x01, 0x05, 0, 0, 0), Pocket3CameraSettings.photoCountdown(Pocket3PhotoCountdown.SECONDS_5).payload)
        assertArrayEquals(bytes(0x07), Pocket3CameraSettings.shootPanorama().payload)
        assertArrayEquals(bytes(0x03, 0x00), Pocket3CameraSettings.panoramaPhotoFormat(Pocket3PanoramaPhotoFormat.JPEG).payload)
        assertArrayEquals(bytes(0x01, 0x01, 0x20, 0x00, 0x01, 0x02), Pocket3CameraSettings.audioChannel(Pocket3AudioChannel.STEREO).payload)
    }

    @Test
    fun timelapseHyperlapseAndMotionlapseVectorsMatchCurrentIos() {
        assertArrayEquals(
            bytes(0x04, 0x00, 0x02, 0x0A, 0x00, 0x2C, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0),
            Pocket3CameraSettings.timelapse(
                Pocket3TimelapseConfiguration(10, 300, Pocket3TimelapseOutput.JPEG_AND_VIDEO)
            ).payload,
        )
        assertArrayEquals(
            bytes(0x0B, 0, 0, 0x0F, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
            Pocket3CameraSettings.hyperlapseSpeed(Pocket3HyperlapseSpeed.X15).payload,
        )
        assertArrayEquals(
            bytes(0x01, 0x01, 0x37, 0x00, 0x01, 0x01),
            Pocket3CameraSettings.motionlapseDirection(Pocket3MotionlapseDirection.LEFT_TO_RIGHT).payload,
        )
        assertArrayEquals(
            bytes(0x01, 0x01, 0x36, 0x00, 0x02, 0x00, 0x00),
            Pocket3CameraSettings.motionlapsePreview().payload,
        )
        assertArrayEquals(
            hex("05050014002c01000036fe0000e80500"),
            Pocket3CameraSettings.motionlapseWaypoint(
                slot = 1, intervalTenths = 20, durationSeconds = 300,
                pitchTenths = 1512, rollTenths = 0, yawTenths = -458,
            ).payload,
        )
        assertArrayEquals(
            hex("0512000a002c01000000000000000000"),
            Pocket3CameraSettings.deleteMotionlapseWaypoint(4, 10, 300).payload,
        )
    }

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    private fun hex(value: String): ByteArray = ByteArray(value.length / 2) { index ->
        value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}
