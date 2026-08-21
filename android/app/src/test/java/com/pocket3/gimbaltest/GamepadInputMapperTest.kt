package com.pocket3.gimbaltest

import com.pocket3.gimbaltest.input.release.GamepadControlSettings
import com.pocket3.gimbaltest.input.release.GamepadInputMapper
import com.pocket3.gimbaltest.input.release.GamepadStickLayout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GamepadInputMapperTest {
    @Test
    fun leftCombinedFullRightUsesSharedLinearResponse() {
        val value = GamepadInputMapper.map(
            leftX = 1f,
            leftY = 0f,
            rightX = 0f,
            rightY = 0f,
            settings = GamepadControlSettings(stickLayout = GamepadStickLayout.LEFT_COMBINED),
            responseMode = JoystickResponseMode.LINEAR,
        )
        assertTrue(value.active)
        assertEquals(1024, value.command.pitch)
        assertEquals(1354, value.command.yaw)
    }

    @Test
    fun androidStickUpMapsToPositiveDjiPitch() {
        val value = GamepadInputMapper.map(
            leftX = 0f,
            leftY = -1f,
            rightX = 0f,
            rightY = 0f,
            settings = GamepadControlSettings(stickLayout = GamepadStickLayout.LEFT_COMBINED),
            responseMode = JoystickResponseMode.LINEAR,
        )
        assertEquals(1354, value.command.pitch)
        assertEquals(1024, value.command.yaw)
    }

    @Test
    fun rightCombinedIgnoresLeftStick() {
        val value = GamepadInputMapper.map(
            leftX = 1f,
            leftY = -1f,
            rightX = -1f,
            rightY = 1f,
            settings = GamepadControlSettings(stickLayout = GamepadStickLayout.RIGHT_COMBINED),
            responseMode = JoystickResponseMode.LINEAR,
        )
        assertEquals(694, value.command.pitch)
        assertEquals(694, value.command.yaw)
    }

    @Test
    fun splitUsesLeftPitchAndRightYaw() {
        val value = GamepadInputMapper.map(
            leftX = -1f,
            leftY = -1f,
            rightX = 1f,
            rightY = 1f,
            settings = GamepadControlSettings(stickLayout = GamepadStickLayout.SPLIT),
            responseMode = JoystickResponseMode.LINEAR,
        )
        assertEquals(1354, value.command.pitch)
        assertEquals(1354, value.command.yaw)
    }

    @Test
    fun inversionIsAppliedBeforeSharedResponse() {
        val value = GamepadInputMapper.map(
            leftX = 1f,
            leftY = -1f,
            rightX = 0f,
            rightY = 0f,
            settings = GamepadControlSettings(
                stickLayout = GamepadStickLayout.LEFT_COMBINED,
                invertPitch = true,
                invertYaw = true,
            ),
            responseMode = JoystickResponseMode.LINEAR,
        )
        assertEquals(694, value.command.pitch)
        assertEquals(694, value.command.yaw)
    }

    @Test
    fun sharedDeadzoneReturnsNeutralAndInactive() {
        val value = GamepadInputMapper.map(
            leftX = 0.03f,
            leftY = -0.02f,
            rightX = 0f,
            rightY = 0f,
            settings = GamepadControlSettings(),
            responseMode = JoystickResponseMode.LINEAR,
        )
        assertFalse(value.active)
        assertEquals(1024, value.command.pitch)
        assertEquals(1024, value.command.yaw)
    }
}
