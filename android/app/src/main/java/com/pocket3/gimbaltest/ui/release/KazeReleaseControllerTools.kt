package com.pocket3.gimbaltest.ui.release

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.pocket3.gimbaltest.input.release.AndroidGameControllerState
import com.pocket3.gimbaltest.input.release.GamepadStickLayout

/** Minimal private controller settings inside the shared Tools panel. Final visual polish is deferred. */
@Composable
internal fun ColumnScope.KazeReleaseControllerTools(
    state: AndroidGameControllerState,
    onLayout: (GamepadStickLayout) -> Unit,
    onInvertPitch: (Boolean) -> Unit,
    onInvertYaw: (Boolean) -> Unit,
) {
    Spacer(Modifier.height(1.dp))
    Text("Game Controller", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
    Text(state.statusText, fontSize = 10.sp, color = Color.White.copy(alpha = 0.68f))

    ReleaseChoice("Left Stick", state.settings.stickLayout == GamepadStickLayout.LEFT_COMBINED) {
        onLayout(GamepadStickLayout.LEFT_COMBINED)
    }
    ReleaseChoice("Right Stick", state.settings.stickLayout == GamepadStickLayout.RIGHT_COMBINED) {
        onLayout(GamepadStickLayout.RIGHT_COMBINED)
    }
    ReleaseChoice("Split Sticks", state.settings.stickLayout == GamepadStickLayout.SPLIT) {
        onLayout(GamepadStickLayout.SPLIT)
    }
    ReleaseChoice("Invert Pitch", state.settings.invertPitch) { onInvertPitch(!state.settings.invertPitch) }
    ReleaseChoice("Invert Yaw", state.settings.invertYaw) { onInvertYaw(!state.settings.invertYaw) }

    Text(
        "A/Cross: Recenter   B/Circle: Stop   X/Square: Mark   Y/Triangle: Return. " +
            "The physical controller uses the same LINEAR / PROGRESSIVE response selected at the top of the camera screen.",
        fontSize = 9.sp,
        color = Color.White.copy(alpha = 0.55f),
    )
}

@Composable
private fun ReleaseChoice(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 3.dp),
    ) {
        Text(label, fontSize = 11.sp, color = Color.White)
        Spacer(Modifier.weight(1f))
        Text(if (selected) "●" else "○", fontSize = 12.sp, color = Color.White.copy(alpha = 0.8f))
    }
}
