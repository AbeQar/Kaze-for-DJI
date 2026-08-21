package com.pocket3.gimbaltest

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class JoystickResponseTest {
    @Test
    fun linearMappingRemainsUnchanged() {
        assertEquals(
            JoystickCommand(pitch = 1024, yaw = 1024),
            JoystickResponse.mapNormalized(0f, 0f, JoystickResponseMode.LINEAR),
        )
        assertEquals(
            JoystickCommand(pitch = 1024, yaw = 1354),
            JoystickResponse.mapNormalized(1f, 0f, JoystickResponseMode.LINEAR),
        )
        assertEquals(
            JoystickCommand(pitch = 1354, yaw = 1024),
            JoystickResponse.mapNormalized(0f, -1f, JoystickResponseMode.LINEAR),
        )
    }

    @Test
    fun progressiveMappingRetainsExactV0143Curve() {
        val anchors = listOf(
            0.25f to 1134,
            0.50f to 1304,
            0.75f to 1464,
            1.00f to 1574,
        )

        for ((magnitude, expectedYaw) in anchors) {
            assertEquals(
                "magnitude=$magnitude",
                JoystickCommand(pitch = 1024, yaw = expectedYaw),
                JoystickResponse.mapNormalized(magnitude, 0f, JoystickResponseMode.PROGRESSIVE),
            )
        }
    }

    @Test
    fun deadZoneAndNeutralRemainUnchanged() {
        for (mode in JoystickResponseMode.entries) {
            assertEquals(
                JoystickCommand(pitch = 1024, yaw = 1024),
                JoystickResponse.mapNormalized(0.05f, 0f, mode),
            )
        }
    }

    @Test
    fun commandRangeRemainsBounded() {
        val samples = listOf(-1f, -0.75f, -0.5f, -0.25f, 0f, 0.25f, 0.5f, 0.75f, 1f)
        for (mode in JoystickResponseMode.entries) {
            for (x in samples) {
                for (y in samples) {
                    if (x * x + y * y > 1.0001f) continue
                    val command = JoystickResponse.mapNormalized(x, y, mode)
                    assertTrue(command.pitch in 474..1574)
                    assertTrue(command.yaw in 474..1574)
                }
            }
        }
    }

    @Test
    fun recenterPayloadRemainsCaptureConfirmedFE08() {
        assertArrayEquals(
            byteArrayOf(0xFE.toByte(), 0x08),
            Pocket3GimbalCommands.recenterPayload(),
        )
    }

    @Test
    fun lockFollowAndSelfiePayloadsMatchCurrentIos() {
        assertArrayEquals(byteArrayOf(0x00, 0x00), Pocket3GimbalCommands.lockPayload(true))
        assertArrayEquals(byteArrayOf(0x01, 0x00), Pocket3GimbalCommands.lockPayload(false))
        assertArrayEquals(byteArrayOf(0xFE.toByte(), 0x09), Pocket3GimbalCommands.selfieForwardPayload())
    }
}
