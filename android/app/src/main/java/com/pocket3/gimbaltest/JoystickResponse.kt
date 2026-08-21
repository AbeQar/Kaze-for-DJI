package com.pocket3.gimbaltest

import kotlin.math.roundToInt
import kotlin.math.sqrt

enum class JoystickResponseMode {
    LINEAR,
    PROGRESSIVE,
}

data class JoystickCommand(
    val pitch: Int,
    val yaw: Int,
)

/** Pure mapping used by the Android virtual joystick. */
object JoystickResponse {
    const val NEUTRAL = 1024
    private const val LINEAR_MAX_OFFSET = 330
    private const val PROGRESSIVE_MAX_OFFSET = 550
    private const val DEAD_ZONE = 0.06f

    fun mapNormalized(
        normalizedX: Float,
        normalizedY: Float,
        mode: JoystickResponseMode,
    ): JoystickCommand {
        var nx = normalizedX
        var ny = normalizedY
        val radius = sqrt(nx * nx + ny * ny).coerceAtMost(1f)
        if (radius < DEAD_ZONE) {
            nx = 0f
            ny = 0f
        }

        val (outX, outY) = when (mode) {
            JoystickResponseMode.LINEAR -> {
                Pair(nx * LINEAR_MAX_OFFSET, ny * LINEAR_MAX_OFFSET)
            }

            JoystickResponseMode.PROGRESSIVE -> {
                if (radius < DEAD_ZONE || radius <= 0f) {
                    Pair(0f, 0f)
                } else {
                    // Exact v0.14.3 radial polynomial; terminology changed, mathematics did not.
                    // Approximate magnitudes: 25%=110, 50%=280, 75%=440, 100%=550.
                    val shaped =
                        0.35757576f * radius +
                            2.2909091f * radius * radius -
                            2.2303030f * radius * radius * radius +
                            0.58181816f * radius * radius * radius * radius
                    val curvedMagnitude = PROGRESSIVE_MAX_OFFSET * shaped.coerceIn(0f, 1f)
                    val ux = nx / radius
                    val uy = ny / radius
                    Pair(ux * curvedMagnitude, uy * curvedMagnitude)
                }
            }
        }

        val yaw = (NEUTRAL + outX).roundToInt()
            .coerceIn(NEUTRAL - PROGRESSIVE_MAX_OFFSET, NEUTRAL + PROGRESSIVE_MAX_OFFSET)
        // Android Y grows downward; DJI pitch >1024 is UP.
        val pitch = (NEUTRAL - outY).roundToInt()
            .coerceIn(NEUTRAL - PROGRESSIVE_MAX_OFFSET, NEUTRAL + PROGRESSIVE_MAX_OFFSET)
        return JoystickCommand(pitch = pitch, yaw = yaw)
    }
}
