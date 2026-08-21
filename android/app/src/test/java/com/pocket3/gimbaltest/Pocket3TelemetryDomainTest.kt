package com.pocket3.gimbaltest

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Pocket3TelemetryDomainTest {
    @Test
    fun gimbalParserDecodesPositiveAndNegativeSignedAxes() {
        val positive = Pocket3TelemetryParser.gimbal(bytes(0x7B, 0, 0xC8, 1, 0x15, 3, 2, 0, 0, 0, 0x45))!!
        assertEquals(12.3, positive.pitchDeg, 0.0)
        assertEquals(45.6, positive.rollDeg, 0.0)
        assertEquals(78.9, positive.yawDeg, 0.0)
        assertEquals(2, positive.mode)
        assertEquals(0x45, positive.limitFlags)

        val negative = Pocket3TelemetryParser.gimbal(bytes(0x85, 0xFF, 0x38, 0xFE, 0xEB, 0xFC))!!
        assertEquals(-12.3, negative.pitchDeg, 0.0)
        assertEquals(-45.6, negative.rollDeg, 0.0)
        assertEquals(-78.9, negative.yawDeg, 0.0)
        assertNull(negative.mode)
        assertNull(negative.limitFlags)
    }

    @Test
    fun gimbalParserRejectsMalformedPayloads() {
        assertNull(Pocket3TelemetryParser.gimbal(ByteArray(0)))
        assertNull(Pocket3TelemetryParser.gimbal(ByteArray(5)))
    }

    @Test
    fun yawReducerUnwrapsForwardAndReverseCrossings() {
        val forward = Pocket3YawReducer()
        assertEquals(179.0, forward.reduce(wrapped(179.0), 1).yawContinuousDeg, 0.0)
        assertEquals(181.0, forward.reduce(wrapped(-179.0), 2).yawContinuousDeg, 0.0)

        val reverse = Pocket3YawReducer()
        assertEquals(-179.0, reverse.reduce(wrapped(-179.0), 1).yawContinuousDeg, 0.0)
        assertEquals(-181.0, reverse.reduce(wrapped(179.0), 2).yawContinuousDeg, 0.0)
    }

    @Test
    fun yawReducerResetStartsFromNextWrappedSample() {
        val reducer = Pocket3YawReducer()
        reducer.reduce(wrapped(179.0), 1)
        assertEquals(181.0, reducer.reduce(wrapped(-179.0), 2).yawContinuousDeg, 0.0)
        reducer.reset()
        assertEquals(-179.0, reducer.reduce(wrapped(-179.0), 3).yawContinuousDeg, 0.0)
    }

    @Test
    fun cameraStatusPreservesRecordingTransitionsIdleAndStorageFields() {
        val payload = ByteArray(58)
        payload[0] = 0x81.toByte()
        payload[4] = 1
        payload[7] = 2
        payload[11] = 1
        payload[17] = 0x1A
        payload[18] = 0x04
        payload[29] = 0x2A
        payload[57] = 1
        val recording = Pocket3TelemetryParser.cameraStatus(payload)!!
        assertTrue(recording.recording)
        assertFalse(recording.transitioning)
        assertEquals(131_072L, recording.fields?.storageTotalMiB)
        assertEquals(65_536L, recording.fields?.storageFreeMiB)
        assertEquals(1_050, recording.fields?.remainingRecordSeconds)
        assertEquals(42, recording.fields?.elapsedRecordSeconds)

        assertFalse(Pocket3TelemetryParser.cameraStatus(bytes(0x01))!!.recording)
        assertTrue(Pocket3TelemetryParser.cameraStatus(bytes(0x41))!!.transitioning)
        assertTrue(Pocket3TelemetryParser.cameraStatus(bytes(0xC1))!!.recording)
        assertNull(Pocket3TelemetryParser.cameraStatus(ByteArray(0)))
    }

    @Test
    fun batteryPreservesKnownChargingAndUnknownStates() {
        val payload = ByteArray(33)
        payload[20] = 92
        payload[32] = 1
        assertEquals(Pocket3BatteryStatusFields(92, true), Pocket3TelemetryParser.battery(payload))
        payload[32] = 0
        assertEquals(Pocket3BatteryStatusFields(92, false), Pocket3TelemetryParser.battery(payload))
        payload[32] = 0x7F
        assertEquals(Pocket3BatteryStatusFields(92, null), Pocket3TelemetryParser.battery(payload))
        payload[20] = 101
        assertNull(Pocket3TelemetryParser.battery(payload))
        assertNull(Pocket3TelemetryParser.battery(ByteArray(32)))
    }

    private fun wrapped(yaw: Double) = Pocket3WrappedGimbalTelemetry(
        pitchDeg = 0.0,
        rollDeg = 0.0,
        yawDeg = yaw,
        mode = null,
        limitFlags = null,
    )

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }
}
