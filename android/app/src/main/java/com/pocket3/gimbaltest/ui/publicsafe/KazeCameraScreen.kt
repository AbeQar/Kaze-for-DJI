package com.pocket3.gimbaltest.ui.publicsafe

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.pocket3.gimbaltest.JoystickView
import com.pocket3.gimbaltest.Pocket3TimelapseOutput
import com.pocket3.gimbaltest.Pocket3TimelapseConfiguration
import com.pocket3.gimbaltest.Pocket3SlowMotionMultiplier
import com.pocket3.gimbaltest.Pocket3PhotoFrame
import com.pocket3.gimbaltest.Pocket3PhotoFormat
import com.pocket3.gimbaltest.Pocket3PhotoCountdown
import com.pocket3.gimbaltest.Pocket3PanoramaType
import com.pocket3.gimbaltest.Pocket3PanoramaPhotoFormat
import com.pocket3.gimbaltest.Pocket3MotionlapseDirection
import com.pocket3.gimbaltest.Pocket3HyperlapseSpeed
import com.pocket3.gimbaltest.Pocket3CameraShootingMode
import com.pocket3.gimbaltest.Pocket3CameraPolicy
import com.pocket3.gimbaltest.Pocket3AudioChannel
import com.pocket3.gimbaltest.AxisJoystickView
import com.pocket3.gimbaltest.Pocket3ColorProfile
import com.pocket3.gimbaltest.Pocket3ExposureMode
import com.pocket3.gimbaltest.Pocket3FocusMode
import com.pocket3.gimbaltest.Pocket3FrameRate
import com.pocket3.gimbaltest.Pocket3IsoMax
import com.pocket3.gimbaltest.Pocket3ManualIso
import com.pocket3.gimbaltest.Pocket3ManualShutter
import com.pocket3.gimbaltest.Pocket3PreviewView
import com.pocket3.gimbaltest.Pocket3VideoCompression
import com.pocket3.gimbaltest.Pocket3VideoOutput
import com.pocket3.gimbaltest.Pocket3VideoResolution
import com.pocket3.gimbaltest.Pocket3VideoStatus
import com.pocket3.gimbaltest.Pocket3WhiteBalance

data class KazeCameraActions(
    val onConnect: () -> Unit,
    val onDisconnect: () -> Unit,
    val onRecordToggle: () -> Unit,
    val onShootPhoto: () -> Unit,
    val onRecenter: () -> Unit,
    val onSetGimbalLocked: (Boolean) -> Unit,
    val onSelfieForward: () -> Unit,
    val onNeutral: () -> Unit,
    val onJoystick: (pitch: Int, yaw: Int, active: Boolean) -> Unit,
    val onToggleJoystickMode: () -> Unit,
    val onSetExposureMode: (Pocket3ExposureMode) -> Unit,
    val onSetIso: (Pocket3ManualIso) -> Unit,
    val onSetIsoMax: (Pocket3IsoMax) -> Unit,
    val onSetShutter: (Pocket3ManualShutter) -> Unit,
    val onSetEv: (Int) -> Unit,
    val onSetWhiteBalance: (Pocket3WhiteBalance) -> Unit,
    val onSetVideoFormat: (Pocket3VideoResolution, Pocket3FrameRate) -> Unit,
    val onSetModeVideoFormat: (Pocket3VideoResolution, Pocket3FrameRate, Pocket3SlowMotionMultiplier) -> Unit,
    val onSetColor: (Pocket3ColorProfile) -> Unit,
    val onSetCompression: (Pocket3VideoCompression) -> Unit,
    val onSetFocus: (Pocket3FocusMode) -> Unit,
    val onSetProEnabled: (Boolean) -> Unit,
    val onSetProductShowcaseEnabled: (Boolean) -> Unit,
    val onSetPhotoFrame: (Pocket3PhotoFrame) -> Unit,
    val onSetPhotoFormat: (Pocket3PhotoFormat) -> Unit,
    val onSetPhotoCountdown: (Pocket3PhotoCountdown) -> Unit,
    val onSetTimelapse: (Pocket3TimelapseConfiguration) -> Unit,
    val onSetTimelapseMotionMode: (Pocket3CameraShootingMode) -> Unit,
    val onSetHyperlapseSpeed: (Pocket3HyperlapseSpeed) -> Unit,
    val onSetPanoramaType: (Pocket3PanoramaType) -> Unit,
    val onSetPanoramaPhotoFormat: (Pocket3PanoramaPhotoFormat) -> Unit,
    val onShootPanorama: () -> Unit,
    val onSetAudioChannel: (Pocket3AudioChannel) -> Unit,
    val onSetMotionlapseDirection: (Pocket3MotionlapseDirection) -> Unit,
    val onAddMotionlapseWaypoint: (Int, Int, Long) -> Unit,
    val onDeleteMotionlapseWaypoint: (Int, Int, Long) -> Unit,
    val onPreviewMotionlapse: () -> Unit,
)
enum class KazeCameraDestination(val title: String) {
    MODE("Current Mode"), WHITE_BALANCE("White Balance"), EXPOSURE("Exposure"),
    FOCUS("Focus"), CAMERA("Camera Settings"),
}

internal val KAZE_BOTTOM_CONTROL_ORDER = listOf("MODE", "WB", "EV", "FOCUS", "CAMERA", "TOOLS")
internal val KAZE_DESTINATION_FOR_CONTROL = mapOf(
    "MODE" to KazeCameraDestination.MODE,
    "WB" to KazeCameraDestination.WHITE_BALANCE,
    "EV" to KazeCameraDestination.EXPOSURE,
    "FOCUS" to KazeCameraDestination.FOCUS,
    "CAMERA" to KazeCameraDestination.CAMERA,
)

enum class KazeVideoOverlayKind { NONE, DISCONNECTED, STARTING, ERROR }
data class KazeVideoOverlay(val kind: KazeVideoOverlayKind, val title: String, val detail: String)

internal fun kazeVideoOverlay(connected: Boolean, status: Pocket3VideoStatus): KazeVideoOverlay = when {
    !connected -> KazeVideoOverlay(KazeVideoOverlayKind.DISCONNECTED, "NO CAMERA CONNECTED", "Connect a camera to start direct preview")
    status == Pocket3VideoStatus.ERROR -> KazeVideoOverlay(KazeVideoOverlayKind.ERROR, "DIRECT VIDEO ERROR", "Open debug controls for diagnostics")
    status == Pocket3VideoStatus.DECODING -> KazeVideoOverlay(KazeVideoOverlayKind.NONE, "", "")
    else -> KazeVideoOverlay(KazeVideoOverlayKind.STARTING, "STARTING DIRECT VIDEO", "Waiting for capture-confirmed H.264 SPS / IDR")
}

private object KazeChrome {
    val Primary = Color(0xFFF4F6F8)
    val Secondary = Primary.copy(alpha = 0.68f)
    val Disabled = Primary.copy(alpha = 0.42f)
    val Surface = Color(0xD522252A)
    val Panel = Color(0xEC22252A)
    val Control = Color(0xC42B2E33)
    val Divider = Primary.copy(alpha = 0.16f)
    val Border = Primary.copy(alpha = 0.15f)
    val Connected = Color(0xFF56D787)
}

/** Public-safe screen. Private behavior enters only through location-specific UI slots. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun KazeCameraScreen(
    state: KazeCameraUiState,
    videoOutput: Pocket3VideoOutput,
    actions: KazeCameraActions,
    modifier: Modifier = Modifier,
    supplementalTopStatus: @Composable RowScope.() -> Unit = {},
    privateTopRightActions: @Composable RowScope.() -> Unit = {},
    privateOverlayContent: @Composable BoxScope.() -> Unit = {},
    privateToolsContent: @Composable ColumnScope.() -> Unit = {},
    automaticPictureInPictureEnabled: Boolean = true,
    onAutomaticPictureInPictureChange: (Boolean) -> Unit = {},
    isPictureInPictureMode: Boolean = false,
    onOpenDebugControls: (() -> Unit)? = null,
) {
    var destination by remember { mutableStateOf<KazeCameraDestination?>(null) }
    var showTools by remember { mutableStateOf(false) }
    var showConnection by remember { mutableStateOf(false) }
    var showLayoutPicker by remember { mutableStateOf(false) }

    val appContext = LocalContext.current.applicationContext
    val cameraUiPreferences = remember(appContext) { KazeCameraUiPreferences(appContext) }
    val savedCameraUiPreferences = remember(cameraUiPreferences) { cameraUiPreferences.snapshot() }
    var gridEnabled by remember { mutableStateOf(savedCameraUiPreferences.gridEnabled) }
    var landscapeFull16x9 by remember { mutableStateOf(savedCameraUiPreferences.landscapeFull16x9) }
    var joystickLayout by remember { mutableStateOf(savedCameraUiPreferences.joystickLayout) }

    MaterialTheme(colorScheme = kazeDarkColorScheme) {
      CompositionLocalProvider(LocalContentColor provides KazeChrome.Primary) {
        BoxWithConstraints(modifier.fillMaxSize().background(Color.Black)) {
            val landscape = maxWidth > maxHeight
            val availableWidth = maxWidth
            val availableHeight = maxHeight
            val captureAspect = kazePreviewCaptureAspect(state.sensorAspectRatio, state.selectedResolution)
            val previewFill = kazePreviewAspectFill(landscape, landscapeFull16x9, captureAspect)

            // A SurfaceView retains its last submitted buffer even after the decoder stops.
            // Remove the preview Surface entirely once disconnect begins so configuration
            // changes cannot briefly expose a stale frame from the previous camera session.
            // Keep it during CONNECTING so the existing first-connect presentation path is
            // unchanged, and keep the retained decoder/parking-Surface lifecycle untouched.
            if (
                state.connectionPhase != KazeConnectionPhase.DISCONNECTED &&
                state.connectionPhase != KazeConnectionPhase.DISCONNECTING
            ) {
                AndroidView(
                    factory = { Pocket3PreviewView(it, videoOutput) },
                    update = {
                        it.setPresentation(
                            sourceWidth = state.videoWidth,
                            sourceHeight = state.videoHeight,
                            captureAspect = captureAspect,
                            fillDisplay = previewFill,
                        )
                    },
                    modifier = Modifier.fillMaxSize(),
                )
            }
            if (!isPictureInPictureMode) {
                if (gridEnabled) ThirdsGrid(
                    fittedVideoModifier(maxWidth, maxHeight, captureAspect, previewFill).align(Alignment.Center),
                )
                VideoStatusOverlay(kazeVideoOverlay(state.connected, state.videoStatus))

                Box(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
                CameraTopStatusBar(
                    state, !landscape,
                    onToggleResponse = actions.onToggleJoystickMode,
                    onConnectionClick = {
                        showConnection = !showConnection
                        if (showConnection) { destination = null; showTools = false; showLayoutPicker = false }
                    },
                    supplementalTopStatus = supplementalTopStatus,
                    modifier = Modifier.align(Alignment.TopCenter)
                        .padding(horizontal = if (landscape) 28.dp else 14.dp)
                        .padding(top = if (landscape) 8.dp else 2.dp),
                )

                Row(
                    Modifier.align(Alignment.TopEnd)
                        .padding(end = if (landscape) 8.dp else 10.dp)
                        .padding(top = if (landscape) 56.dp else 84.dp),
                    horizontalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    KazeCameraActionButton(
                        if (state.gimbalLocked) "Unlock" else "Lock",
                        if (state.gimbalLocked) "▣" else "□",
                        state.connected,
                    ) { actions.onSetGimbalLocked(!state.gimbalLocked) }
                    KazeCameraActionButton("Recenter", "◎", state.connected, actions.onRecenter)
                    privateTopRightActions()
                }

                when (joystickLayout) {
                    KazeJoystickLayout.COMBINED_LEFT -> CombinedJoystick(
                        state, actions, Modifier.align(Alignment.BottomStart)
                            .padding(start = if (landscape) 24.dp else 10.dp, bottom = if (landscape) 66.dp else 142.dp),
                    )
                    KazeJoystickLayout.COMBINED_RIGHT -> CombinedJoystick(
                        state, actions, Modifier.align(Alignment.BottomEnd)
                            .padding(end = if (landscape) 92.dp else 10.dp, bottom = if (landscape) 66.dp else 142.dp),
                    )
                    KazeJoystickLayout.DUAL -> DualJoysticks(
                        state, actions, landscape, Modifier.fillMaxSize(),
                    )
                }
                SmallCapsuleButton(
                    "▣  Layout",
                    {
                        showLayoutPicker = !showLayoutPicker
                        if (showLayoutPicker) { destination = null; showTools = false; showConnection = false }
                    },
                    Modifier.align(Alignment.BottomEnd).padding(end = 9.dp, bottom = 66.dp),
                )
                CameraCaptureButton(
                    enabled = if (state.shootingModeValue == Pocket3CameraShootingMode.PHOTO) state.connected else state.canToggleRecording,
                    recording = state.recording == true,
                    transitioning = state.recordTransitioning,
                    photoShutter = state.shootingModeValue == Pocket3CameraShootingMode.PHOTO,
                    onClick = if (state.shootingModeValue == Pocket3CameraShootingMode.PHOTO) actions.onShootPhoto else actions.onRecordToggle,
                    modifier = if (landscape) Modifier.align(Alignment.CenterEnd)
                    else Modifier.align(Alignment.BottomCenter).padding(bottom = 66.dp),
                )
                CameraBottomControlBar(
                    state,
                    onDestination = { requested ->
                        destination = if (destination == requested) null else requested
                        showTools = false; showConnection = false; showLayoutPicker = false
                    },
                    onTools = {
                        showTools = !showTools
                        destination = null; showConnection = false; showLayoutPicker = false
                    },
                    modifier = Modifier.align(Alignment.BottomCenter)
                        .padding(horizontal = if (landscape) 110.dp else 18.dp)
                        .padding(bottom = if (landscape) 2.dp else 6.dp),
                )

                destination?.let {
                    CameraSettingsPanel(
                        it, state, actions, landscape, availableWidth, { destination = null },
                        Modifier.align(Alignment.BottomCenter).padding(bottom = if (landscape) 66.dp else 82.dp),
                    )
                }
                if (showTools) ToolsPanel(
                    gridEnabled, landscapeFull16x9,
                    { enabled ->
                        gridEnabled = enabled
                        cameraUiPreferences.setGridEnabled(enabled)
                    },
                    { enabled ->
                        landscapeFull16x9 = enabled
                        cameraUiPreferences.setLandscapeFull16x9(enabled)
                    },
                    automaticPictureInPictureEnabled,
                    onAutomaticPictureInPictureChange,
                    onOpenDebugControls, { showTools = false }, privateToolsContent,
                    maxHeight = (availableHeight - if (landscape) 148.dp else 180.dp).coerceAtLeast(180.dp),
                    modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = if (landscape) 74.dp else 90.dp),
                )
                if (showConnection) ConnectionPanel(
                    state, actions, { showConnection = false },
                    Modifier.align(Alignment.TopCenter).padding(top = if (landscape) 66.dp else 96.dp),
                )
                if (showLayoutPicker) LayoutPicker(
                    joystickLayout,
                    { selected ->
                        joystickLayout = selected
                        cameraUiPreferences.setJoystickLayout(selected)
                        showLayoutPicker = false
                    },
                    { showLayoutPicker = false },
                    Modifier.align(Alignment.BottomCenter).padding(bottom = if (landscape) 90.dp else 140.dp),
                )
                    privateOverlayContent()
                }
            }
        }
      }
    }
}

private fun fittedVideoModifier(width: Dp, height: Dp, aspect: Float, fill: Boolean): Modifier {
    if (fill) return Modifier.fillMaxSize()
    return if (width.value / height.value > aspect) Modifier.fillMaxHeight().width(height * aspect)
    else Modifier.fillMaxWidth().height(width / aspect)
}

@Composable private fun ThirdsGrid(modifier: Modifier) = Canvas(modifier) {
    val color = Color.White.copy(alpha = 0.18f)
    val stroke = 0.7.dp.toPx()
    listOf(1f / 3f, 2f / 3f).forEach {
        drawLine(color, Offset(size.width * it, 0f), Offset(size.width * it, size.height), stroke)
        drawLine(color, Offset(0f, size.height * it), Offset(size.width, size.height * it), stroke)
    }
}

@Composable private fun VideoStatusOverlay(overlay: KazeVideoOverlay) {
    if (overlay.kind == KazeVideoOverlayKind.NONE) return
    val backdrop = if (overlay.kind == KazeVideoOverlayKind.DISCONNECTED) Color.Black else Color.Transparent
    Box(Modifier.fillMaxSize().background(backdrop), contentAlignment = Alignment.Center) {
        Column(
            Modifier.background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(22.dp)).padding(horizontal = 18.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Text(if (overlay.kind == KazeVideoOverlayKind.ERROR) "!" else "●", fontSize = 18.sp)
            Text(overlay.title, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
            Text(overlay.detail, fontSize = 10.sp, color = KazeChrome.Secondary)
        }
    }
}

@Composable private fun CameraTopStatusBar(
    state: KazeCameraUiState,
    portrait: Boolean,
    onToggleResponse: () -> Unit,
    onConnectionClick: () -> Unit,
    supplementalTopStatus: @Composable RowScope.() -> Unit,
    modifier: Modifier,
) {
    Surface(modifier.fillMaxWidth(), color = KazeChrome.Surface, contentColor = KazeChrome.Primary, shape = RoundedCornerShape(18.dp)) {
        if (portrait) Column(Modifier.padding(horizontal = 16.dp, vertical = 11.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                ConnectionStatus(state, onConnectionClick); Spacer(Modifier.weight(1f)); FormatCapsule(state.formatSummary, true)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                supplementalTopStatus(); Text("TOUCH", fontSize = 10.sp)
                ResponseStatus(state, onToggleResponse)
                Spacer(Modifier.weight(1f)); MediaStatus(state)
            }
        } else Row(
            Modifier.padding(horizontal = 16.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            ConnectionStatus(state, onConnectionClick); FormatCapsule(state.formatSummary, false); Spacer(Modifier.weight(1f))
            supplementalTopStatus(); Text("TOUCH", fontSize = 10.sp); Spacer(Modifier.weight(1f))
            ResponseStatus(state, onToggleResponse); MediaStatus(state)
        }
    }
}

@Composable private fun ResponseStatus(state: KazeCameraUiState, onToggle: () -> Unit) = Text(
    state.joystickMode.name,
    Modifier.clickable(enabled = state.connected, onClick = onToggle).padding(vertical = 4.dp),
    fontSize = 12.sp,
    fontWeight = FontWeight.SemiBold,
    color = KazeChrome.Secondary,
)

@Composable private fun ConnectionStatus(state: KazeCameraUiState, onClick: () -> Unit) {
    val presentation = kazeConnectionPresentation(state)
    Row(Modifier.clickable(onClick = onClick).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.size(9.dp).background(if (state.connected) KazeChrome.Connected else KazeChrome.Secondary, CircleShape))
        Text(presentation.topLabel, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = KazeChrome.Primary)
        Text("⌄", fontSize = 12.sp, color = KazeChrome.Secondary)
    }
}

@Composable private fun FormatCapsule(value: String, portrait: Boolean) = Text(
    value, fontSize = if (portrait) 10.sp else 11.sp, fontWeight = FontWeight.SemiBold,
    fontFamily = FontFamily.Monospace, maxLines = 1,
    modifier = Modifier.background(Color.White.copy(alpha = 0.08f), RoundedCornerShape(20.dp)).padding(horizontal = 8.dp, vertical = 4.dp),
)

@Composable private fun MediaStatus(state: KazeCameraUiState) {
    val value = listOf(
        state.batterySummary.takeUnless { it == "—" }?.let { "BAT $it" },
        state.storageSummary.takeUnless { it == "—" }?.let { "SD $it" },
        state.timeSummary.takeUnless { it == "—" },
    ).filterNotNull().joinToString("  ").ifEmpty { "—" }
    Text(value, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.Monospace, maxLines = 1,
        color = if (state.recording == true) Color(0xFFFF5252) else KazeChrome.Primary)
}

@Composable fun KazeCameraActionButton(label: String, symbol: String, enabled: Boolean, onClick: () -> Unit) {
    Column(
        Modifier.size(width = 48.dp, height = 44.dp).clickable(enabled = enabled, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        Box(Modifier.size(34.dp).background(KazeChrome.Control, CircleShape).border(0.75.dp, KazeChrome.Border, CircleShape), contentAlignment = Alignment.Center) {
            Text(symbol, fontSize = 14.sp, color = if (enabled) KazeChrome.Primary else KazeChrome.Disabled)
        }
        Text(label, fontSize = 8.5.sp, maxLines = 1, color = if (enabled) KazeChrome.Primary else KazeChrome.Disabled)
    }
}

@Composable private fun CameraCaptureButton(
    enabled: Boolean, recording: Boolean, transitioning: Boolean, photoShutter: Boolean,
    onClick: () -> Unit, modifier: Modifier,
) {
    Box(modifier.size(68.dp).clip(CircleShape).clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(58.dp)) { drawCircle(Color.White.copy(alpha = 0.95f), style = Stroke(width = 3.2.dp.toPx())) }
        Box(Modifier.size(if (recording) 31.dp else 45.dp).background(
            (if (photoShutter) Color.White else Color(0xFFFF2837)).copy(alpha = if (enabled) 1f else if (transitioning) 0.75f else 0.55f),
            if (recording && !photoShutter) RoundedCornerShape(7.dp) else CircleShape,
        ))
    }
}

@Composable private fun CombinedJoystick(state: KazeCameraUiState, actions: KazeCameraActions, modifier: Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text("PAN / TILT", fontSize = 9.sp, fontWeight = FontWeight.SemiBold, color = KazeChrome.Primary)
        Box(Modifier.size(98.dp), contentAlignment = Alignment.Center) {
            Box(Modifier.size(88.dp).background(KazeChrome.Control, CircleShape).border(0.75.dp, KazeChrome.Border, CircleShape))
            AndroidView(
                factory = { JoystickView(it).apply { onJoystick = actions.onJoystick } },
                update = { it.isEnabled = state.connected; if (it.responseMode != state.joystickMode) it.setResponseMode(state.joystickMode) },
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable private fun DualJoysticks(
    state: KazeCameraUiState, actions: KazeCameraActions, landscape: Boolean, modifier: Modifier,
) {
    var yaw by remember { mutableIntStateOf(1024) }
    var pitch by remember { mutableIntStateOf(1024) }
    var yawActive by remember { mutableStateOf(false) }
    var pitchActive by remember { mutableStateOf(false) }

    fun publish() { actions.onJoystick(pitch, yaw, yawActive || pitchActive) }

    Box(modifier) {
        Column(
            Modifier.align(Alignment.BottomStart).padding(start = if (landscape) 24.dp else 10.dp, bottom = if (landscape) 66.dp else 142.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("YAW", fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
            AndroidView(
                factory = { context -> AxisJoystickView(context, AxisJoystickView.Axis.YAW).apply {
                    onAxis = { value, active -> yaw = value; yawActive = active; publish() }
                } },
                update = { view ->
                    view.isEnabled = state.connected
                    if (view.responseMode != state.joystickMode) view.setResponseMode(state.joystickMode)
                },
                modifier = Modifier.size(width = 138.dp, height = 50.dp),
            )
        }
        Column(
            Modifier.align(Alignment.BottomEnd).padding(end = if (landscape) 92.dp else 10.dp, bottom = if (landscape) 66.dp else 142.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("PITCH", fontSize = 9.sp, fontWeight = FontWeight.SemiBold)
            AndroidView(
                factory = { context -> AxisJoystickView(context, AxisJoystickView.Axis.PITCH).apply {
                    onAxis = { value, active -> pitch = value; pitchActive = active; publish() }
                } },
                update = { view ->
                    view.isEnabled = state.connected
                    if (view.responseMode != state.joystickMode) view.setResponseMode(state.joystickMode)
                },
                modifier = Modifier.size(width = 50.dp, height = 132.dp),
            )
        }
    }
}

@Composable private fun SmallCapsuleButton(label: String, onClick: () -> Unit, modifier: Modifier) = Text(
    label, modifier.background(KazeChrome.Control, RoundedCornerShape(20.dp)).clickable(onClick = onClick).padding(horizontal = 9.dp, vertical = 6.dp),
    fontSize = 9.sp, fontWeight = FontWeight.SemiBold, color = KazeChrome.Primary,
)

@Composable private fun CameraBottomControlBar(state: KazeCameraUiState, onDestination: (KazeCameraDestination) -> Unit, onTools: () -> Unit, modifier: Modifier) {
    Surface(modifier.fillMaxWidth(), color = KazeChrome.Surface, contentColor = KazeChrome.Primary, shape = RoundedCornerShape(18.dp)) {
        Row(Modifier.padding(horizontal = 7.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            BottomControlItem("MODE", state.shootingMode) { onDestination(KazeCameraDestination.MODE) }; BottomDivider()
            BottomControlItem("WB", state.whiteBalanceSummary) { onDestination(KazeCameraDestination.WHITE_BALANCE) }; BottomDivider()
            BottomControlItem("EV", state.evSummary.removeSuffix(" EV")) { onDestination(KazeCameraDestination.EXPOSURE) }; BottomDivider()
            BottomControlItem("FOCUS", state.focusSummary) { onDestination(KazeCameraDestination.FOCUS) }; BottomDivider()
            BottomControlItem("CAMERA", "●") { onDestination(KazeCameraDestination.CAMERA) }; BottomDivider()
            BottomControlItem("TOOLS", "≡", onTools)
        }
    }
}

@Composable private fun RowScope.BottomControlItem(title: String, value: String, onClick: () -> Unit) {
    Column(Modifier.weight(1f).clickable(onClick = onClick).padding(vertical = 2.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, fontSize = 9.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, color = KazeChrome.Secondary)
        if (value.isNotEmpty()) Text(value, fontSize = 11.sp, fontWeight = FontWeight.Medium, maxLines = 1, textAlign = TextAlign.Center, color = KazeChrome.Primary)
    }
}
@Composable private fun BottomDivider() = Box(Modifier.width(0.75.dp).height(26.dp).background(KazeChrome.Divider))

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun CameraSettingsPanel(
    destination: KazeCameraDestination, state: KazeCameraUiState, actions: KazeCameraActions,
    landscape: Boolean, availableWidth: Dp, onClose: () -> Unit, modifier: Modifier,
) {
    val targetWidth = if (landscape) 470.dp else 350.dp
    val panelWidth = if (availableWidth < targetWidth) availableWidth else targetWidth
    val maxHeight = when (destination) {
        KazeCameraDestination.CAMERA, KazeCameraDestination.MODE -> if (landscape) 330.dp else 520.dp
        KazeCameraDestination.WHITE_BALANCE -> if (landscape) 230.dp else 250.dp
        KazeCameraDestination.EXPOSURE -> if (landscape) 300.dp else 370.dp
        KazeCameraDestination.FOCUS -> if (landscape) 220.dp else 250.dp
    }
    Surface(modifier.width(panelWidth).height(maxHeight), color = KazeChrome.Panel, contentColor = KazeChrome.Primary, shape = RoundedCornerShape(17.dp), border = BorderStroke(1.dp, KazeChrome.Border)) {
        Column(Modifier.padding(13.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            PanelHeader(destination.title, state.connected, state.connectedCameraDisplayName, onClose)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("MODE", fontSize = 8.5.sp, fontWeight = FontWeight.Bold, color = KazeChrome.Secondary); Spacer(Modifier.width(6.dp))
                Text(state.shootingMode, fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold)
            }
            Box(Modifier.fillMaxWidth().height(0.75.dp).background(KazeChrome.Divider))
            LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                when (destination) {
                    KazeCameraDestination.MODE -> {
                        item { PanelNote("Shooting mode follows live camera readback. Unsupported remote mode switching remains intentionally read-only.") }
                        item { ModeSpecificCameraSettings(state, actions) }
                    }
                    KazeCameraDestination.WHITE_BALANCE -> item { WhiteBalanceSettings(state, actions) }
                    KazeCameraDestination.EXPOSURE -> item { ExposureSettings(state, actions) }
                    KazeCameraDestination.FOCUS -> item { FocusSettings(state, actions) }
                    KazeCameraDestination.CAMERA -> {
                        item { ModeSpecificCameraSettings(state, actions) }
                        item { CommonCameraSettings(state, actions) }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun ModeSpecificCameraSettings(state: KazeCameraUiState, actions: KazeCameraActions) {
    var interval by remember(state.timelapseIntervalTenths) { mutableIntStateOf(state.timelapseIntervalTenths ?: 10) }
    var duration by remember(state.timelapseDurationSeconds) { mutableStateOf(state.timelapseDurationSeconds ?: 300L) }
    var output by remember(state.timelapseOutput) { mutableStateOf(state.timelapseOutput ?: Pocket3TimelapseOutput.JPEG_AND_VIDEO) }

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        when {
            !state.connected -> PanelNote("Connect to the Pocket 3 to load mode-specific controls.")
            state.shootingModeValue == null -> PanelNote("Waiting for the Pocket 3 shooting-mode status push…")
            else -> when (state.shootingModeValue) {
                Pocket3CameraShootingMode.VIDEO -> {
                    NormalVideoSettings(state, actions)
                    VideoCompressionAndColorSettings(state, actions)
                }
                Pocket3CameraShootingMode.SLOW_MOTION -> {
                    SettingsSection("SLOW MOTION FORMAT") {
                        ChoiceFlow(Pocket3CameraPolicy.slowMotionPresets(), { it.label }, state.connected, state.formatSummary) { preset ->
                            actions.onSetModeVideoFormat(preset.resolution, preset.frameRate, preset.slowMotionMultiplier)
                        }
                    }
                    VideoCompressionAndColorSettings(state, actions)
                }
                Pocket3CameraShootingMode.LOW_LIGHT -> {
                    SettingsSection("LOW-LIGHT FORMAT") {
                        ChoiceFlow(Pocket3CameraPolicy.lowLightPresets(), { it.label }, state.connected, null) { preset ->
                            actions.onSetModeVideoFormat(preset.resolution, preset.frameRate, preset.slowMotionMultiplier)
                        }
                    }
                    VideoCompressionAndColorSettings(state, actions)
                }
                Pocket3CameraShootingMode.PHOTO -> {
                    SettingsSection("PHOTO FRAME") { ChoiceFlow(Pocket3PhotoFrame.entries, { it.displayName }, state.connected, state.photoFrame?.displayName, actions.onSetPhotoFrame) }
                    SettingsSection("PHOTO FORMAT") { ChoiceFlow(Pocket3PhotoFormat.entries, { it.displayName }, state.connected, state.photoFormat?.displayName, actions.onSetPhotoFormat) }
                    SettingsSection("COUNTDOWN") { ChoiceFlow(Pocket3PhotoCountdown.entries, { it.displayName }, state.connected, state.photoCountdown?.displayName, actions.onSetPhotoCountdown) }
                    PanelNote("The main capture button becomes the white still-photo shutter in Photo mode.")
                }
                Pocket3CameraShootingMode.TIMELAPSE, Pocket3CameraShootingMode.MOTIONLAPSE -> {
                    SettingsSection("INTERVAL") {
                        ChoiceFlow(Pocket3CameraPolicy.timelapseIntervalsTenths, Pocket3CameraPolicy::timelapseIntervalLabel, state.connected, Pocket3CameraPolicy.timelapseIntervalLabel(interval)) { interval = it }
                    }
                    SettingsSection("DURATION") {
                        ChoiceFlow(Pocket3CameraPolicy.timelapseDurationsSeconds, Pocket3CameraPolicy::timelapseDurationLabel, state.connected, Pocket3CameraPolicy.timelapseDurationLabel(duration)) { duration = it }
                    }
                    SettingsSection("OUTPUT") { ChoiceFlow(Pocket3TimelapseOutput.entries, { it.displayName }, state.connected, output.displayName) { output = it } }
                    ChoiceButton("Apply Timelapse", false, state.connected) { actions.onSetTimelapse(Pocket3TimelapseConfiguration(interval, duration, output)) }
                    if (state.shootingModeValue == Pocket3CameraShootingMode.TIMELAPSE) {
                        ChoiceButton("Motionlapse…", false, state.connected) { actions.onSetTimelapseMotionMode(Pocket3CameraShootingMode.MOTIONLAPSE) }
                    } else {
                        SettingsSection("MOTIONLAPSE DIRECTION") {
                            ChoiceFlow(Pocket3MotionlapseDirection.entries, { it.displayName }, state.connected, state.motionlapseDirection?.displayName, actions.onSetMotionlapseDirection)
                        }
                        val saved = state.motionlapseWaypointCount ?: 0
                        if (state.motionlapseDirection == Pocket3MotionlapseDirection.CUSTOM) {
                            Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                                ChoiceButton("Add Point ${saved + 1}", false, state.connected && saved < 4 && state.motionlapsePreviewActive != true) {
                                    actions.onAddMotionlapseWaypoint(saved + 1, interval, duration)
                                }
                                ChoiceButton("Delete Point $saved", false, state.connected && saved > 0 && state.motionlapsePreviewActive != true) {
                                    actions.onDeleteMotionlapseWaypoint(saved, interval, duration)
                                }
                            }
                            ChoiceButton(if (state.motionlapsePreviewActive == true) "Previewing…" else "Preview Path", false,
                                state.connected && saved > 0 && state.motionlapsePreviewActive != true, actions.onPreviewMotionlapse)
                        }
                        ChoiceButton("Return to Timelapse", false, state.connected) { actions.onSetTimelapseMotionMode(Pocket3CameraShootingMode.TIMELAPSE) }
                    }
                }
                Pocket3CameraShootingMode.HYPERLAPSE -> {
                    SettingsSection("HYPERLAPSE FORMAT") {
                        ChoiceFlow(Pocket3CameraPolicy.hyperlapsePresets(), { it.label }, state.connected, null) { preset ->
                            actions.onSetModeVideoFormat(preset.resolution, preset.frameRate, preset.slowMotionMultiplier)
                        }
                    }
                    SettingsSection("HYPERLAPSE SPEED") {
                        ChoiceFlow(Pocket3HyperlapseSpeed.entries, { it.displayName }, state.connected, state.hyperlapseSpeed?.displayName, actions.onSetHyperlapseSpeed)
                    }
                }
                Pocket3CameraShootingMode.PANORAMA -> {
                    SettingsSection("PANORAMA TYPE") { ChoiceFlow(Pocket3PanoramaType.entries, { it.displayName }, state.connected, state.panoramaType?.displayName, actions.onSetPanoramaType) }
                    SettingsSection("PANORAMA FORMAT") { ChoiceFlow(Pocket3PanoramaPhotoFormat.entries, { it.displayName }, state.connected, state.panoramaPhotoFormat?.displayName, actions.onSetPanoramaPhotoFormat) }
                    ChoiceButton("Start Panorama", false, state.connected, actions.onShootPanorama)
                }
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun NormalVideoSettings(state: KazeCameraUiState, actions: KazeCameraActions) {
    var draftResolution by remember(state.selectedResolution) { mutableStateOf(state.selectedResolution) }
    var draftFrameRate by remember(state.selectedFrameRate) { mutableStateOf(state.selectedFrameRate) }
    SettingsSection("NORMAL VIDEO FORMAT") {
        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
            if (state.resolutionOptions.isEmpty()) {
                PanelNote("Waiting for camera orientation readback before enabling resolution changes.")
            } else {
                ChoiceFlow(state.resolutionOptions, { it.displayName }, state.connected, draftResolution?.displayName) { draftResolution = it }
            }
            SettingsSection("FRAME RATE") {
                ChoiceFlow(state.frameRateOptions, { it.displayName }, state.connected, draftFrameRate?.displayName) { draftFrameRate = it }
            }
            ChoiceButton(
                "Apply ${draftResolution?.displayName ?: "—"} / ${draftFrameRate?.displayName ?: "—"}",
                false,
                state.connected && draftResolution != null && draftFrameRate != null,
            ) { actions.onSetVideoFormat(draftResolution!!, draftFrameRate!!) }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun VideoCompressionAndColorSettings(state: KazeCameraUiState, actions: KazeCameraActions) {
    SettingsSection("COMPRESSION") {
        ChoiceFlow(Pocket3VideoCompression.entries, { it.displayName }, state.connected, state.selectedCompression?.displayName, actions.onSetCompression)
    }
    SettingsSection("COLOR PROFILE") {
        ChoiceFlow(Pocket3ColorProfile.entries, { it.displayName }, state.connected, state.selectedColor?.displayName, actions.onSetColor)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun WhiteBalanceSettings(state: KazeCameraUiState, actions: KazeCameraActions) {
    SettingsSection("WHITE BALANCE") {
        ChoiceFlow(state.whiteBalanceOptions, KazeCameraPresentation::whiteBalanceLabel, state.connected, state.whiteBalanceSummary, actions.onSetWhiteBalance)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun ExposureSettings(state: KazeCameraUiState, actions: KazeCameraActions) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SettingsSection("EXPOSURE MODE") { ChoiceFlow(Pocket3ExposureMode.entries, { it.displayName }, state.connected, state.exposureMode?.displayName, actions.onSetExposureMode) }
        SettingsSection("MANUAL ISO") { ChoiceFlow(state.isoOptions, { it.displayName }, state.connected, state.isoSummary.removePrefix("ISO "), actions.onSetIso) }
        SettingsSection("MANUAL SHUTTER") {
            if (state.shutterOptions.isEmpty()) PanelNote("Unavailable in the current confirmed camera mode.")
            else ChoiceFlow(state.shutterOptions, { it.displayName }, state.connected, null, actions.onSetShutter)
        }
        SettingsSection("AUTO EV COMPENSATION") { ChoiceFlow(state.evOptions, KazeCameraPresentation::evLabel, state.connected, state.evThirdStops?.let(KazeCameraPresentation::evLabel), actions.onSetEv) }
        SettingsSection("ISO MAX") { ChoiceFlow(state.isoMaxOptions, { it.displayName }, state.connected, null, actions.onSetIsoMax) }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable private fun FocusSettings(state: KazeCameraUiState, actions: KazeCameraActions) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SettingsSection("FOCUS") { ChoiceFlow(Pocket3FocusMode.entries, { it.displayName }, state.connected, state.selectedFocus?.displayName, actions.onSetFocus) }
        SettingsSection("PRODUCT SHOWCASE") {
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                ChoiceButton("Off", false, state.connected) { actions.onSetProductShowcaseEnabled(false) }
                ChoiceButton("On", false, state.connected) { actions.onSetProductShowcaseEnabled(true) }
            }
        }
    }
}

@Composable private fun CommonCameraSettings(state: KazeCameraUiState, actions: KazeCameraActions) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SettingsSection("COMMON CAMERA CONTROLS") {
            PanelNote("Capture-derived common controls remain available alongside the active shooting-mode controls.")
        }
        WhiteBalanceSettings(state, actions)
        ExposureSettings(state, actions)
        FocusSettings(state, actions)
        SettingsSection("PRO") {
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                ChoiceButton("Off", false, state.connected) { actions.onSetProEnabled(false) }
                ChoiceButton("On", false, state.connected) { actions.onSetProEnabled(true) }
            }
        }
        SettingsSection("AUDIO CHANNEL") {
            ChoiceFlow(Pocket3AudioChannel.entries, { it.displayName }, state.connected, null, actions.onSetAudioChannel)
        }
        SettingsSection("CAMERA FACING / GIMBAL") {
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                ChoiceButton("Recenter", false, state.connected, actions.onRecenter)
                ChoiceButton("Selfie / Forward", false, state.connected, actions.onSelfieForward)
            }
        }
    }
}

@Composable private fun PanelHeader(title: String, connected: Boolean, cameraName: String?, onClose: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = KazeChrome.Primary)
            Text(if (connected) "${cameraName ?: "Camera"} connected" else "No camera connected", fontSize = 9.sp, color = if (connected) KazeChrome.Connected else KazeChrome.Secondary)
        }
        Spacer(Modifier.weight(1f)); Text("●", Modifier.clickable(onClick = onClose).padding(4.dp), color = KazeChrome.Secondary, fontSize = 14.sp)
    }
}
@Composable private fun SettingsSection(title: String, content: @Composable () -> Unit) = Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
    Text(title, fontSize = 9.sp, fontWeight = FontWeight.Bold, color = KazeChrome.Secondary); content()
}
@OptIn(ExperimentalLayoutApi::class)
@Composable private fun <T> ChoiceFlow(options: List<T>, label: (T) -> String, enabled: Boolean, selected: String?, onSelect: (T) -> Unit) {
    FlowRow(horizontalArrangement = Arrangement.spacedBy(7.dp), verticalArrangement = Arrangement.spacedBy(7.dp)) {
        options.forEach { option -> val text = label(option); ChoiceButton(text, text == selected, enabled) { onSelect(option) } }
    }
}
@Composable private fun ChoiceButton(title: String, selected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.widthIn(min = 58.dp).background(Color.White.copy(alpha = if (selected) 0.18f else 0.06f), RoundedCornerShape(10.dp))
            .border(0.75.dp, Color.White.copy(alpha = if (selected) 0.28f else 0.10f), RoundedCornerShape(10.dp))
            .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 9.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        if (selected) Text("✓ ", fontSize = 9.sp, fontWeight = FontWeight.Bold)
        Text(title, fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, color = if (enabled) KazeChrome.Primary else KazeChrome.Disabled)
    }
}
@Composable private fun PanelNote(text: String) = Text(text, fontSize = 9.25.sp, color = KazeChrome.Secondary)

@Composable private fun ToolsPanel(
    gridEnabled: Boolean, landscapeFull16x9: Boolean, onGridChange: (Boolean) -> Unit, onLandscapeFitChange: (Boolean) -> Unit,
    automaticPictureInPictureEnabled: Boolean, onAutomaticPictureInPictureChange: (Boolean) -> Unit,
    onDebug: (() -> Unit)?, onClose: () -> Unit, privateToolsContent: @Composable ColumnScope.() -> Unit,
    maxHeight: Dp, modifier: Modifier,
) = ScrollableFloatingPanel(modifier.width(280.dp), maxHeight) {
    PanelTitle("Monitoring Tools", onClose)
    ToggleChoice("Grid", gridEnabled) { onGridChange(!gridEnabled) }
    ToggleChoice("Show Full 16:9", landscapeFull16x9) { onLandscapeFitChange(!landscapeFull16x9) }
    ToggleChoice("Automatic Picture in Picture", automaticPictureInPictureEnabled) {
        onAutomaticPictureInPictureChange(!automaticPictureInPictureEnabled)
    }
    privateToolsContent()
    if (onDebug != null) { Box(Modifier.fillMaxWidth().height(0.75.dp).background(KazeChrome.Divider)); ToggleChoice("Legacy / Debug", false, onDebug) }
    PanelNote("Histogram, waveform, zebras, false color and focus peaking remain unavailable until their real pipelines exist.")
}

@Composable private fun ConnectionPanel(state: KazeCameraUiState, actions: KazeCameraActions, onClose: () -> Unit, modifier: Modifier) = FloatingPanel(modifier.width(280.dp)) {
    val presentation = kazeConnectionPresentation(state)
    PanelTitle(presentation.title, onClose)
    if (presentation.device != null) Text(presentation.device, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = KazeChrome.Primary)
    Text(presentation.status, fontSize = 10.sp, color = if (state.connected) KazeChrome.Connected else KazeChrome.Secondary)
    ChoiceButton(presentation.action, false,
        state.connectionPhase != KazeConnectionPhase.CONNECTING && state.connectionPhase != KazeConnectionPhase.DISCONNECTING) {
        if (state.connected) actions.onDisconnect() else actions.onConnect(); onClose()
    }
}

@Composable private fun LayoutPicker(selected: KazeJoystickLayout, onSelected: (KazeJoystickLayout) -> Unit, onClose: () -> Unit, modifier: Modifier) = FloatingPanel(modifier.width(236.dp)) {
    PanelTitle("Joystick Layout", onClose)
    ChoiceButton("Dual YAW / PITCH", selected == KazeJoystickLayout.DUAL, true) { onSelected(KazeJoystickLayout.DUAL) }
    ChoiceButton("Combined left", selected == KazeJoystickLayout.COMBINED_LEFT, true) { onSelected(KazeJoystickLayout.COMBINED_LEFT) }
    ChoiceButton("Combined right", selected == KazeJoystickLayout.COMBINED_RIGHT, true) { onSelected(KazeJoystickLayout.COMBINED_RIGHT) }
}

@Composable private fun FloatingPanel(modifier: Modifier, content: @Composable ColumnScope.() -> Unit) {
    Surface(modifier, color = KazeChrome.Panel, contentColor = KazeChrome.Primary, shape = RoundedCornerShape(17.dp), border = BorderStroke(1.dp, KazeChrome.Border)) {
        Column(Modifier.padding(13.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
    }
}
@Composable private fun ScrollableFloatingPanel(
    modifier: Modifier,
    maxHeight: Dp,
    content: @Composable ColumnScope.() -> Unit,
) {
    val scrollState = rememberScrollState()
    Surface(
        modifier.heightIn(max = maxHeight),
        color = KazeChrome.Panel,
        contentColor = KazeChrome.Primary,
        shape = RoundedCornerShape(17.dp),
        border = BorderStroke(1.dp, KazeChrome.Border),
    ) {
        Column(
            Modifier.padding(13.dp).verticalScroll(scrollState),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            content = content,
        )
    }
}
@Composable private fun PanelTitle(title: String, onClose: () -> Unit) = Row(verticalAlignment = Alignment.CenterVertically) {
    Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = KazeChrome.Primary); Spacer(Modifier.weight(1f)); Text("●", Modifier.clickable(onClick = onClose).padding(4.dp), color = KazeChrome.Secondary, fontSize = 14.sp)
}
@Composable private fun ToggleChoice(label: String, checked: Boolean, onClick: () -> Unit) = Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
    Text(label, fontSize = 12.sp); Spacer(Modifier.weight(1f)); Text(if (checked) "●" else "○", fontSize = 14.sp)
}

private val kazeDarkColorScheme @Composable get() = androidx.compose.material3.darkColorScheme(
    primary = KazeChrome.Primary, onPrimary = Color(0xFF101318), secondary = KazeChrome.Secondary,
    onSecondary = KazeChrome.Primary, surface = Color(0xFF101318), onSurface = KazeChrome.Primary,
    background = Color.Black, onBackground = KazeChrome.Primary, error = Color(0xFFFF5A5F), onError = KazeChrome.Primary,
)
