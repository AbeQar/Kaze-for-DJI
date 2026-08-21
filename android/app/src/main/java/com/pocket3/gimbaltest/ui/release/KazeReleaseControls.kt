package com.pocket3.gimbaltest.ui.release

import androidx.compose.foundation.layout.RowScope
import androidx.compose.runtime.Composable
import com.pocket3.gimbaltest.ui.publicsafe.KazeCameraActionButton

data class KazeReleaseControlState(
    val canCaptureCenter: Boolean,
    val hasCapturedCenter: Boolean,
    val canSmoothRecenter: Boolean,
    val smoothRecenterRunning: Boolean,
)

/** Release-only actions supplied to the public-safe screen's canonical top-right slot. */
@Composable
fun RowScope.KazeReleaseControls(
    state: KazeReleaseControlState,
    onCaptureCenter: () -> Unit,
    onSmoothRecenter: () -> Unit,
) {
    KazeCameraActionButton(
        label = "Mark",
        symbol = if (state.hasCapturedCenter) "◆" else "◇",
        enabled = state.canCaptureCenter,
        onClick = onCaptureCenter,
    )
    KazeCameraActionButton(
        label = if (state.smoothRecenterRunning) "Returning" else "Return",
        symbol = "↶",
        enabled = state.canSmoothRecenter && !state.smoothRecenterRunning,
        onClick = onSmoothRecenter,
    )
}
