package com.pocket3.gimbaltest.input.release

import com.pocket3.gimbaltest.JoystickCommand
import com.pocket3.gimbaltest.JoystickResponse
import com.pocket3.gimbaltest.JoystickResponseMode

enum class GamepadStickLayout {
    LEFT_COMBINED,
    RIGHT_COMBINED,
    SPLIT,
}

data class GamepadControlSettings(
    val stickLayout: GamepadStickLayout = GamepadStickLayout.LEFT_COMBINED,
    val invertPitch: Boolean = false,
    val invertYaw: Boolean = false,
)

data class GamepadMappedInput(
    val command: JoystickCommand,
    val active: Boolean,
)

/**
 * Private/release game-controller mapper.
 *
 * It deliberately reuses the same [JoystickResponse] mapping as touch control so the physical
 * controller cannot create a second DJI command curve or bypass the single GimbalSession pump.
 */
object GamepadInputMapper {
    fun map(
        leftX: Float,
        leftY: Float,
        rightX: Float,
        rightY: Float,
        settings: GamepadControlSettings,
        responseMode: JoystickResponseMode,
    ): GamepadMappedInput {
        var x: Float
        var y: Float
        when (settings.stickLayout) {
            GamepadStickLayout.LEFT_COMBINED -> {
                x = leftX
                y = leftY
            }
            GamepadStickLayout.RIGHT_COMBINED -> {
                x = rightX
                y = rightY
            }
            GamepadStickLayout.SPLIT -> {
                // iOS parity: left up/down controls pitch; right left/right controls yaw.
                x = rightX
                y = leftY
            }
        }

        if (settings.invertYaw) x = -x
        if (settings.invertPitch) y = -y

        x = x.coerceIn(-1f, 1f)
        y = y.coerceIn(-1f, 1f)
        val command = JoystickResponse.mapNormalized(x, y, responseMode)
        val active = command.pitch != JoystickResponse.NEUTRAL || command.yaw != JoystickResponse.NEUTRAL
        return GamepadMappedInput(command, active)
    }
}
