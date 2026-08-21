package com.pocket3.gimbaltest.ui.publicsafe

import android.content.Context

enum class KazeJoystickLayout { COMBINED_LEFT, COMBINED_RIGHT, DUAL }

/** Presentation-only camera-screen preferences; never changes DJI protocol or control math. */
internal class KazeCameraUiPreferences(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    fun snapshot(): KazeCameraUiPreferenceSnapshot {
        val savedLayout = preferences.getString(KEY_JOYSTICK_LAYOUT, null)
            ?.let { runCatching { KazeJoystickLayout.valueOf(it) }.getOrNull() }
        val migratedLayout = savedLayout ?: when {
            preferences.contains(KEY_COMBINED_JOYSTICK_RIGHT) -> {
                if (preferences.getBoolean(KEY_COMBINED_JOYSTICK_RIGHT, false)) {
                    KazeJoystickLayout.COMBINED_RIGHT
                } else {
                    KazeJoystickLayout.COMBINED_LEFT
                }
            }
            else -> KazeJoystickLayout.DUAL
        }
        return KazeCameraUiPreferenceSnapshot(
            gridEnabled = preferences.getBoolean(KEY_GRID_ENABLED, DEFAULT_GRID_ENABLED),
            landscapeFull16x9 = preferences.getBoolean(KEY_LANDSCAPE_FULL_16X9, DEFAULT_LANDSCAPE_FULL_16X9),
            joystickLayout = migratedLayout,
            automaticPictureInPictureEnabled = preferences.getBoolean(
                KEY_AUTOMATIC_PICTURE_IN_PICTURE,
                DEFAULT_AUTOMATIC_PICTURE_IN_PICTURE,
            ),
        )
    }

    fun setGridEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_GRID_ENABLED, enabled).apply()
    }

    fun setLandscapeFull16x9(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_LANDSCAPE_FULL_16X9, enabled).apply()
    }

    fun setJoystickLayout(layout: KazeJoystickLayout) {
        preferences.edit().putString(KEY_JOYSTICK_LAYOUT, layout.name).apply()
    }

    fun setAutomaticPictureInPictureEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(KEY_AUTOMATIC_PICTURE_IN_PICTURE, enabled).apply()
    }

    private companion object {
        const val PREFERENCES_NAME = "kaze_camera_ui"
        const val KEY_GRID_ENABLED = "grid_enabled"
        const val KEY_LANDSCAPE_FULL_16X9 = "landscape_full_16x9"
        const val KEY_JOYSTICK_LAYOUT = "joystick_layout"
        const val KEY_COMBINED_JOYSTICK_RIGHT = "combined_joystick_right" // migration only
        const val KEY_AUTOMATIC_PICTURE_IN_PICTURE = "automatic_picture_in_picture"

        const val DEFAULT_GRID_ENABLED = true
        const val DEFAULT_LANDSCAPE_FULL_16X9 = false
        const val DEFAULT_AUTOMATIC_PICTURE_IN_PICTURE = true
    }
}

internal data class KazeCameraUiPreferenceSnapshot(
    val gridEnabled: Boolean,
    val landscapeFull16x9: Boolean,
    val joystickLayout: KazeJoystickLayout,
    val automaticPictureInPictureEnabled: Boolean,
)
