package com.pocket3.gimbaltest

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Pocket3CameraDomainTest {
    @Test
    fun recordingCommandAndStatusBitsMatchConfirmedBehavior() {
        val start = Pocket3CameraStatus.recordingCommand(true)
        val stop = Pocket3CameraStatus.recordingCommand(false)
        assertEquals(0x02, start.set)
        assertEquals(0x02, start.command)
        assertEquals(0x01, start.receiverType)
        assertEquals(0, start.receiverId)
        assertEquals(2, start.commandType)
        assertArrayEquals(byteArrayOf(0x01), start.payload)
        assertArrayEquals(byteArrayOf(0x00), stop.payload)
        assertTrue(Pocket3CameraStatus.recordingActive(0x81))
        assertFalse(Pocket3CameraStatus.recordingActive(0x01))
        assertTrue(Pocket3CameraStatus.recordingTransitioning(0x41))
        assertTrue(Pocket3CameraStatus.recordRequestResolved(true, 0x41))
        assertTrue(Pocket3CameraStatus.recordRequestResolved(true, 0x81))
        assertFalse(Pocket3CameraStatus.recordRequestResolved(true, 0x01))
    }

    @Test
    fun statusAndStateExposeOnlyConfirmedCameraValues() {
        val payload = ByteArray(60)
        payload[4] = 0x01
        payload[7] = 0x02
        payload[11] = 0x01
        payload[17] = 0x1A
        payload[18] = 0x04
        payload[29] = 0x2A
        payload[57] = 0x01
        val fields = Pocket3CameraStatus.statusFields(payload)!!
        val state = Pocket3CameraState(recording = false).apply(fields)
        assertEquals(131_072L, state.storageTotalMiB)
        assertEquals(65_536L, state.storageFreeMiB)
        assertEquals(1_050, state.remainingRecordSeconds)
        assertEquals(42, state.elapsedRecordSeconds)
        assertEquals(Pocket3CameraShootingMode.VIDEO, state.shootingMode)
        assertTrue(state.canToggleRecording)
        assertFalse(state.copy(recordCommandInFlight = true).canToggleRecording)
        assertNull(Pocket3CameraStatus.statusFields(ByteArray(57)))
    }

    @Test
    fun nonVideoStatusClearsRecordTiming() {
        val payload = ByteArray(58)
        payload[17] = 10
        payload[29] = 5
        payload[57] = 0x05
        val state = Pocket3CameraState(remainingRecordSeconds = 99, elapsedRecordSeconds = 88)
            .apply(Pocket3CameraStatus.statusFields(payload)!!)
        assertEquals(Pocket3CameraShootingMode.PHOTO, state.shootingMode)
        assertNull(state.remainingRecordSeconds)
        assertNull(state.elapsedRecordSeconds)
    }

    @Test
    fun controlDelegatesIntentAndRejectsInvalidValues() {
        val commands = ArrayList<Pocket3CameraCommand>()
        val recording = ArrayList<Boolean>()
        val control = Pocket3CameraControl(commands::add, recording::add)
        control.setVideoFormat(Pocket3VideoResolution.P4K, Pocket3FrameRate.FPS_60)
        control.setVideoCompression(Pocket3VideoCompression.HEVC)
        control.setExposureMode(Pocket3ExposureMode.MANUAL)
        control.setManualIso(Pocket3ManualIso.ISO_400)
        control.setIsoMax(Pocket3IsoMax.ISO_1600)
        control.setManualShutter(Pocket3ManualShutter.RECIPROCAL_60)
        assertTrue(control.setAutoEv(3))
        assertTrue(control.setWhiteBalance(Pocket3WhiteBalance.CustomKelvin(5600)))
        control.setColorProfile(Pocket3ColorProfile.D_LOG_M)
        control.setFocusMode(Pocket3FocusMode.AF_C)
        assertFalse(control.setAutoEv(10))
        assertFalse(control.setWhiteBalance(Pocket3WhiteBalance.CustomKelvin(5650)))
        control.setRecording(true)
        assertEquals(10, commands.size)
        assertEquals(listOf(true), recording)
    }

    @Test
    fun policyPublishesOnlyConfirmedRanges() {
        assertEquals((-9..9).toList(), Pocket3CameraPolicy.evThirdStops().toList())
        val kelvin = Pocket3CameraPolicy.whiteBalanceKelvinValues().toList()
        assertEquals(2000, kelvin.first())
        assertEquals(10_000, kelvin.last())
        assertEquals(100, kelvin[1] - kelvin[0])
    }

    @Test
    fun normalVideoPolicyFollowsConfirmedOrientationAndExcludesSlowMotionRates() {
        assertEquals(
            listOf(
                Pocket3VideoResolution.P1080,
                Pocket3VideoResolution.P2_7K,
                Pocket3VideoResolution.P4K,
                Pocket3VideoResolution.SQUARE_1080,
                Pocket3VideoResolution.SQUARE_2160,
                Pocket3VideoResolution.SQUARE_3K,
            ),
            Pocket3CameraPolicy.normalVideoResolutions(Pocket3SensorAspectRatio.LANDSCAPE),
        )
        assertEquals(
            listOf(
                Pocket3VideoResolution.PORTRAIT_1080,
                Pocket3VideoResolution.PORTRAIT_2_7K,
                Pocket3VideoResolution.PORTRAIT_3K,
            ),
            Pocket3CameraPolicy.normalVideoResolutions(Pocket3SensorAspectRatio.PORTRAIT),
        )
        assertTrue(Pocket3CameraPolicy.videoFormatSupported(Pocket3VideoResolution.PORTRAIT_3K, Pocket3SensorAspectRatio.PORTRAIT))
        assertFalse(Pocket3CameraPolicy.videoFormatSupported(Pocket3VideoResolution.P4K, Pocket3SensorAspectRatio.PORTRAIT))
        assertTrue(Pocket3CameraPolicy.normalVideoResolutions(null).isEmpty())
        assertEquals(
            listOf(24, 25, 30, 48, 50, 60),
            Pocket3CameraPolicy.normalVideoFrameRates().map { it.displayName.substringBefore(' ').toInt() },
        )
        assertEquals((1..8).toList(), Pocket3FrameRate.entries.map { it.code })
    }

    @Test
    fun normalVideoShutterPolicyMatchesApprovedFpsThresholds() {
        val minimums = mapOf(
            Pocket3FrameRate.FPS_24 to Pocket3ManualShutter.RECIPROCAL_25,
            Pocket3FrameRate.FPS_25 to Pocket3ManualShutter.RECIPROCAL_25,
            Pocket3FrameRate.FPS_30 to Pocket3ManualShutter.RECIPROCAL_30,
            Pocket3FrameRate.FPS_48 to Pocket3ManualShutter.RECIPROCAL_50,
            Pocket3FrameRate.FPS_50 to Pocket3ManualShutter.RECIPROCAL_50,
            Pocket3FrameRate.FPS_60 to Pocket3ManualShutter.RECIPROCAL_60,
        )
        minimums.forEach { (fps, minimum) ->
            val shutters = Pocket3CameraPolicy.manualShutters(Pocket3CameraShootingMode.VIDEO, fps)!!
            assertEquals(minimum, shutters.first())
            val prior = Pocket3ManualShutter.entries.getOrNull(Pocket3ManualShutter.entries.indexOf(minimum) - 1)
            if (prior != null) assertFalse(prior in shutters)
        }
        assertNull(Pocket3CameraPolicy.manualShutters(Pocket3CameraShootingMode.SLOW_MOTION, Pocket3FrameRate.FPS_60))
        assertEquals(Pocket3ManualShutter.entries, Pocket3CameraPolicy.manualShutters(Pocket3CameraShootingMode.PHOTO, null))
    }

    @Test
    fun hardwareConfirmedBatteryParserRejectsImpossibleValuesAndPreservesUnknownCharging() {
        val payload = ByteArray(33)
        payload[20] = 87
        payload[32] = 1
        assertEquals(Pocket3BatteryStatusFields(87, true), Pocket3TelemetryParser.battery(payload))
        payload[32] = 0
        assertEquals(Pocket3BatteryStatusFields(87, false), Pocket3TelemetryParser.battery(payload))
        payload[32] = 2
        assertEquals(Pocket3BatteryStatusFields(87, null), Pocket3TelemetryParser.battery(payload))
        payload[20] = 101
        assertNull(Pocket3TelemetryParser.battery(payload))
        assertNull(Pocket3TelemetryParser.battery(ByteArray(32)))
    }

    @Test
    fun currentIosModeSpecificPolicyIsExplicitAndFinite() {
        assertEquals(4, Pocket3CameraPolicy.slowMotionPresets().size)
        assertEquals(6, Pocket3CameraPolicy.lowLightPresets().size)
        assertEquals(3, Pocket3CameraPolicy.hyperlapsePresets().size)
        assertEquals(listOf(5,10,20,30,40,50,60,80,100,150,200,250,300,400,600), Pocket3CameraPolicy.timelapseIntervalsTenths)
        assertEquals(listOf(0L,300L,600L,1200L,1800L,3600L,7200L,10800L,18000L), Pocket3CameraPolicy.timelapseDurationsSeconds)
    }

}
