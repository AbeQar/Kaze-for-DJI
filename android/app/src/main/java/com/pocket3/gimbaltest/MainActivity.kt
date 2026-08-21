package com.pocket3.gimbaltest

import android.Manifest
import android.app.AlertDialog
import android.app.PictureInPictureParams
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.LinkProperties
import android.net.Network
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.graphics.Color
import android.text.method.ScrollingMovementMethod
import android.util.Log
import android.util.Rational
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.ArrayAdapter
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.ViewModelProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.pocket3.gimbaltest.ui.publicsafe.KazeCameraActions
import com.pocket3.gimbaltest.ui.publicsafe.KazeCameraPresentation
import com.pocket3.gimbaltest.ui.publicsafe.KazeCameraScreen
import com.pocket3.gimbaltest.ui.publicsafe.KazeCameraUiPreferences
import com.pocket3.gimbaltest.ui.publicsafe.KazeCameraUiState
import com.pocket3.gimbaltest.ui.publicsafe.KazeConnectionPhase
import com.pocket3.gimbaltest.ui.publicsafe.kazePreviewCaptureAspect
import com.pocket3.gimbaltest.input.release.AndroidGameControllerManager
import com.pocket3.gimbaltest.input.release.AndroidGameControllerState
import com.pocket3.gimbaltest.ui.release.KazeReleaseControlState
import com.pocket3.gimbaltest.ui.release.KazeReleaseControls
import com.pocket3.gimbaltest.ui.release.KazeReleaseControllerTools

class MainActivity : ComponentActivity(), Pocket3ConnectionManager.Listener {
    companion object {
        const val LOG_TAG = "Pocket3GimbalTest"
        private const val REQ_CONNECTION_PERMS = 2001
    }

    private val main = Handler(Looper.getMainLooper())

    private lateinit var pocketOwner: PocketSessionViewModel
    private val worker get() = pocketOwner.worker
    private val connection get() = pocketOwner.connection
    private val session get() = pocketOwner.session
    private lateinit var legacyDebugView: View
    private lateinit var status: TextView
    private lateinit var joystickValues: TextView
    private lateinit var telemetryView: TextView
    private lateinit var centerView: TextView
    private lateinit var logView: TextView
    private lateinit var connectButton: Button
    private lateinit var disconnectButton: Button
    private lateinit var videoStatusView: TextView
    private lateinit var joystick: JoystickView
    private lateinit var joystickModeButton: Button
    private lateinit var recenterButton: Button
    private lateinit var smoothRecenterButton: Button
    private lateinit var captureCenterButton: Button
    private lateinit var neutralButton: Button
    private lateinit var copyLogButton: Button
    private lateinit var cameraStateView: TextView
    private lateinit var recordButton: Button
    private lateinit var videoFormatPolicyView: TextView
    private lateinit var videoResolutionSpinner: Spinner
    private lateinit var videoResolutionAdapter: ArrayAdapter<String>
    private var videoResolutionOptions: List<Pocket3VideoResolution> = emptyList()
    private var lastVideoAspectRatio: Pocket3SensorAspectRatio? = null
    private lateinit var videoFrameRateSpinner: Spinner
    private val videoFrameRateOptions = Pocket3CameraPolicy.normalVideoFrameRates()
    private var videoFrameRateDraftInitialized = false
    private lateinit var videoFormatButton: Button
    private lateinit var shutterSpinner: Spinner
    private lateinit var shutterAdapter: ArrayAdapter<String>
    private var shutterOptions: List<Pocket3ManualShutter> = emptyList()
    private lateinit var shutterButton: Button
    private val cameraSettingButtons = ArrayList<Button>()
    private var cameraControlsEnabled = false
    private var kazeUiState by mutableStateOf(KazeCameraUiState())
    private var connectionPhase: KazeConnectionPhase
        get() = pocketOwner.connectionPhase
        set(value) { pocketOwner.connectionPhase = value }
    private var connectionDetail: String
        get() = pocketOwner.connectionDetail
        set(value) { pocketOwner.connectionDetail = value }
    private var joystickWasActive = false
    private lateinit var gameController: AndroidGameControllerManager
    private var gameControllerState by mutableStateOf(AndroidGameControllerState())
    private var manualInputOwner: ManualInputOwner? = null
    private var capturedCenter: GimbalTelemetry?
        get() = pocketOwner.capturedCenter
        set(value) { pocketOwner.capturedCenter = value }
    private var pairingDialog: AlertDialog? = null
    private var showingKazeUi = true
    private lateinit var cameraUiPreferences: KazeCameraUiPreferences
    private val pictureInPictureSupported by lazy {
        packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
    }
    private var automaticPictureInPictureEnabled by mutableStateOf(true)
    private var pictureInPictureActive by mutableStateOf(false)
    private var lastPictureInPictureConfig: PictureInPictureConfig? = null

    private enum class ManualInputOwner { TOUCH, GAMEPAD }

    private data class PictureInPictureConfig(
        val automaticEnabled: Boolean,
        val eligible: Boolean,
        val aspectNumerator: Int,
        val aspectDenominator: Int,
    )

    private val telemetryUiTicker = object : Runnable {
        override fun run() {
            renderTelemetry()
            renderCamera()
            renderVideo()
            renderKazePresentation()
            main.postDelayed(this, 250)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pocketOwner = ViewModelProvider(this)[PocketSessionViewModel::class.java]
        pocketOwner.attach(this)
        cameraUiPreferences = KazeCameraUiPreferences(applicationContext)
        automaticPictureInPictureEnabled = cameraUiPreferences.snapshot().automaticPictureInPictureEnabled
        pictureInPictureActive = isInPictureInPictureMode
        legacyDebugView = buildUi()
        gameController = AndroidGameControllerManager(
            context = this,
            responseModeProvider = { joystick.responseMode },
            onJoystick = ::onGamepadJoystickChanged,
            onRecenter = ::recenter,
            onNeutral = ::neutral,
            onCaptureCenter = ::captureCenter,
            onSmoothReturn = ::smoothRecenter,
            onLog = ::appendLog,
        ).also { manager ->
            manager.onStateChanged = { state -> gameControllerState = state }
            manager.start()
        }
        showKazeUi()
        setControlsEnabled(session.connected)
        setStatus(connectionDetail)
        appendLog(
            if (savedInstanceState == null) "Activity created; Pocket session owner attached"
            else "Activity recreated/configuration changed; Pocket session retained"
        )
        appendLog("Pocket 3 Gimbal Test v0.14.3 started")
        appendLog("v0.14.3: LINEAR unchanged; faster PROGRESSIVE midrange + ~20% faster smooth recenter")
        main.post(telemetryUiTicker)
    }

    private fun showKazeUi() {
        showingKazeUi = true
        if (!pictureInPictureActive) configureKazeWindow()
        setContent {
            KazeCameraScreen(
                state = kazeUiState,
                videoOutput = session.videoOutput,
                actions = KazeCameraActions(
                    onConnect = ::ensurePermissionsAndConnect,
                    onDisconnect = ::disconnectFromPocket,
                    onRecordToggle = {
                        session.cameraState().recording?.let { session.camera.setRecording(!it) }
                    },
                    onShootPhoto = {
                        session.camera.shootPhoto()
                        setStatus("Photo shutter command queued")
                    },
                    onRecenter = ::recenter,
                    onSetGimbalLocked = { locked ->
                        runCatching { session.setGimbalLocked(locked) }
                            .onSuccess { setStatus(if (locked) "Gimbal lock requested" else "Gimbal follow requested") }
                            .onFailure { setStatus("Gimbal lock/follow failed: ${it.message}") }
                    },
                    onSelfieForward = {
                        runCatching { session.toggleSelfieForward() }
                            .onSuccess { setStatus("Selfie / forward toggle requested") }
                            .onFailure { setStatus("Selfie toggle failed: ${it.message}") }
                    },
                    onNeutral = ::neutral,
                    onJoystick = ::onJoystickChanged,
                    onToggleJoystickMode = ::toggleJoystickMode,
                    onSetExposureMode = {
                        session.camera.setExposureMode(it)
                        setStatus("Exposure mode command queued: ${it.displayName}")
                    },
                    onSetIso = {
                        session.camera.setManualIso(it)
                        setStatus("ISO command queued: ${it.displayName}; effective ISO remains readback-driven")
                    },
                    onSetIsoMax = {
                        session.camera.setIsoMax(it)
                        setStatus("ISO MAX command queued: ${it.displayName} (no confirmed readback)")
                    },
                    onSetShutter = {
                        session.camera.setManualShutter(it)
                        setStatus("Shutter command queued: ${it.displayName} (no confirmed readback)")
                    },
                    onSetEv = {
                        if (session.camera.setAutoEv(it)) setStatus("EV command queued: ${evLabel(it)}")
                    },
                    onSetWhiteBalance = {
                        if (session.camera.setWhiteBalance(it)) setStatus("White balance command queued: ${whiteBalanceLabel(it)}")
                    },
                    onSetVideoFormat = { resolution, frameRate ->
                        val aspect = session.cameraState().readback.sensorAspectRatio
                        if (aspect != null && Pocket3CameraPolicy.videoFormatSupported(resolution, aspect)) {
                            session.camera.setVideoFormat(resolution, frameRate)
                            setStatus("Video format command queued: ${resolution.displayName}/${frameRate.displayName}")
                        }
                    },
                    onSetModeVideoFormat = { resolution, frameRate, slowMultiplier ->
                        session.camera.setVideoFormat(resolution, frameRate, slowMultiplier)
                        setStatus("Mode format queued: ${resolution.displayName}/${frameRate.displayName}/${slowMultiplier.displayName}")
                    },
                    onSetColor = {
                        session.camera.setColorProfile(it)
                        setStatus("Color profile command queued: ${it.displayName}")
                    },
                    onSetCompression = {
                        session.camera.setVideoCompression(it)
                        setStatus("Compression command queued: ${it.displayName}")
                    },
                    onSetFocus = {
                        session.camera.setFocusMode(it)
                        setStatus("Focus mode command queued: ${it.displayName}")
                    },
                    onSetProEnabled = { enabled ->
                        session.camera.setProEnabled(enabled)
                        setStatus("Pro ${if (enabled) "On" else "Off"} command queued")
                    },
                    onSetProductShowcaseEnabled = { enabled ->
                        session.camera.setProductShowcaseEnabled(enabled)
                        setStatus("Product Showcase ${if (enabled) "On" else "Off"} command queued")
                    },
                    onSetPhotoFrame = { session.camera.setPhotoFrame(it) },
                    onSetPhotoFormat = { session.camera.setPhotoFormat(it) },
                    onSetPhotoCountdown = { session.camera.setPhotoCountdown(it) },
                    onSetTimelapse = { session.camera.setTimelapse(it) },
                    onSetTimelapseMotionMode = { session.camera.setTimelapseMotionMode(it) },
                    onSetHyperlapseSpeed = { session.camera.setHyperlapseSpeed(it) },
                    onSetPanoramaType = { session.camera.setPanoramaType(it) },
                    onSetPanoramaPhotoFormat = { session.camera.setPanoramaPhotoFormat(it) },
                    onShootPanorama = { session.camera.shootPanorama() },
                    onSetAudioChannel = { session.camera.setAudioChannel(it) },
                    onSetMotionlapseDirection = { direction ->
                        if (session.cameraState().shootingMode != Pocket3CameraShootingMode.MOTIONLAPSE) {
                            session.camera.setTimelapseMotionMode(Pocket3CameraShootingMode.MOTIONLAPSE)
                        }
                        session.camera.setMotionlapseDirection(direction)
                    },
                    onAddMotionlapseWaypoint = { slot, interval, duration ->
                        if (!session.addMotionlapseWaypoint(slot, interval, duration)) {
                            setStatus("Motionlapse point needs fresh 04/05 telemetry")
                        } else {
                            setStatus("Motionlapse point $slot queued")
                        }
                    },
                    onDeleteMotionlapseWaypoint = { slot, interval, duration ->
                        session.camera.deleteMotionlapseWaypoint(slot, interval, duration)
                        setStatus("Delete Motionlapse point $slot queued")
                    },
                    onPreviewMotionlapse = {
                        session.camera.previewMotionlapse()
                        setStatus("Motionlapse Preview requested")
                    },
                ),
                privateTopRightActions = {
                    val telemetryAge = session.telemetryAgeMs()
                    KazeReleaseControls(
                        state = KazeReleaseControlState(
                            canCaptureCenter = session.connected && telemetryAge < 500,
                            hasCapturedCenter = capturedCenter != null,
                            canSmoothRecenter = session.connected && telemetryAge < 350 && capturedCenter != null,
                            smoothRecenterRunning = session.isSmoothRecenterActive(),
                        ),
                        onCaptureCenter = ::captureCenter,
                        onSmoothRecenter = ::smoothRecenter,
                    )
                },
                privateToolsContent = {
                    KazeReleaseControllerTools(
                        state = gameControllerState,
                        onLayout = gameController::setStickLayout,
                        onInvertPitch = gameController::setInvertPitch,
                        onInvertYaw = gameController::setInvertYaw,
                    )
                },
                automaticPictureInPictureEnabled = automaticPictureInPictureEnabled,
                onAutomaticPictureInPictureChange = ::updateAutomaticPictureInPicturePreference,
                isPictureInPictureMode = pictureInPictureActive,
                onOpenDebugControls = if (isDebugBuild()) ::showLegacyDebugUi else null,
            )
        }
        updatePictureInPictureParams(force = true)
    }

    private fun updateAutomaticPictureInPicturePreference(enabled: Boolean) {
        automaticPictureInPictureEnabled = enabled
        cameraUiPreferences.setAutomaticPictureInPictureEnabled(enabled)
        appendLog("PiP: automatic entry ${if (enabled) "enabled" else "disabled"}")
        updatePictureInPictureParams(force = true)
    }

    private fun pictureInPictureConfig(): PictureInPictureConfig {
        val aspect = kazePreviewCaptureAspect(kazeUiState.sensorAspectRatio, kazeUiState.selectedResolution)
        val (numerator, denominator) = when {
            aspect < 0.8f -> 9 to 16
            aspect < 1.2f -> 1 to 1
            else -> 16 to 9
        }
        val video = session.videoOutput.state()
        val eligible = pictureInPictureSupported &&
            showingKazeUi &&
            session.connected &&
            video.status == Pocket3VideoStatus.DECODING &&
            video.renderedFrames > 0
        return PictureInPictureConfig(
            automaticEnabled = automaticPictureInPictureEnabled,
            eligible = eligible,
            aspectNumerator = numerator,
            aspectDenominator = denominator,
        )
    }

    private fun buildPictureInPictureParams(config: PictureInPictureConfig): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(config.aspectNumerator, config.aspectDenominator))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(config.automaticEnabled && config.eligible)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    private fun updatePictureInPictureParams(force: Boolean = false) {
        if (!pictureInPictureSupported) return
        val config = pictureInPictureConfig()
        if (!force && config == lastPictureInPictureConfig) return
        setPictureInPictureParams(buildPictureInPictureParams(config))
        if (config != lastPictureInPictureConfig) {
            appendLog(
                "PiP: params automatic=${config.automaticEnabled} eligible=${config.eligible} " +
                    "aspect=${config.aspectNumerator}:${config.aspectDenominator}"
            )
        }
        lastPictureInPictureConfig = config
    }

    private fun shouldEnterPictureInPicture(): Boolean {
        val config = pictureInPictureConfig()
        return config.automaticEnabled && config.eligible
    }

    private fun configureKazeWindow() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.BLACK
        window.isStatusBarContrastEnforced = false
        window.isNavigationBarContrastEnforced = false
        WindowCompat.getInsetsController(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
            systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            hide(WindowInsetsCompat.Type.statusBars())
        }
    }

    private fun showLegacyDebugUi() {
        showingKazeUi = false
        updatePictureInPictureParams(force = true)
        session.releaseJoystick()
        joystickWasActive = false
        WindowCompat.getInsetsController(window, window.decorView).show(WindowInsetsCompat.Type.statusBars())
        WindowCompat.setDecorFitsSystemWindows(window, true)
        setContentView(legacyDebugView)
    }

    private fun buildUi(): View {
        val density = resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        // v0.14.2 layout fix:
        // - The control area scrolls independently so no button can be pushed below the screen.
        // - The app log stays in a small fixed panel at the bottom.
        // - The joystick remains a normal-sized touch target inside the scrolling control area.
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }

        val controls = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(16), dp(20), dp(18))
        }

        controls.addView(TextView(this).apply {
            text = "Pocket 3 Gimbal Test v0.14.3"
            textSize = 24f
        })

        status = TextView(this).apply {
            textSize = 16f
            setPadding(0, dp(8), 0, dp(4))
        }
        controls.addView(status)

        controls.addView(Pocket3PreviewView(this, session.videoOutput))
        videoStatusView = TextView(this).apply {
            text = "Live preview: stopped"
            textSize = 13f
            setPadding(0, dp(4), 0, dp(6))
        }
        controls.addView(videoStatusView)

        joystickValues = TextView(this).apply {
            text = "Joystick: pitch=1024  yaw=1024"
            textSize = 14f
        }
        controls.addView(joystickValues)

        telemetryView = TextView(this).apply {
            text = "04/05 telemetry: waiting"
            textSize = 14f
            setPadding(0, dp(5), 0, 0)
        }
        controls.addView(telemetryView)

        centerView = TextView(this).apply {
            text = "Measured center: not captured"
            textSize = 14f
            setPadding(0, dp(3), 0, dp(8))
        }
        controls.addView(centerView)

        controls.addView(TextView(this).apply {
            text = "v0.14.3 keeps LINEAR and the proven transport unchanged. PROGRESSIVE reaches high speed sooner while retaining the same +/-550 ceiling, and smooth recenter is about 20% faster. Scroll this control area to reach every button."
            textSize = 13f
            setPadding(0, 0, 0, dp(8))
        })

        connectButton = Button(this).apply {
            text = "CONNECT VIA BLUETOOTH"
            setOnClickListener { ensurePermissionsAndConnect() }
        }
        controls.addView(connectButton)

        disconnectButton = Button(this).apply {
            text = "DISCONNECT"
            isEnabled = false
            setOnClickListener { disconnectFromPocket() }
        }
        controls.addView(disconnectButton)

        joystickModeButton = Button(this).apply {
            text = "JOYSTICK: LINEAR"
            setOnClickListener { toggleJoystickMode() }
        }
        controls.addView(joystickModeButton)

        joystick = JoystickView(this).apply {
            isEnabled = false
            onJoystick = { pitch, yaw, active -> onJoystickChanged(pitch, yaw, active) }
        }
        controls.addView(
            joystick,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(240)),
        )

        val controlRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        neutralButton = Button(this).apply {
            text = "STOP / NEUTRAL"
            isEnabled = false
            setOnClickListener { neutral() }
        }
        recenterButton = Button(this).apply {
            text = "RECENTER"
            isEnabled = false
            setOnClickListener { recenter() }
        }
        controlRow.addView(
            neutralButton,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        controlRow.addView(
            recenterButton,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        controls.addView(controlRow)

        smoothRecenterButton = Button(this).apply {
            text = "SMOOTH RECENTER"
            isEnabled = false
            setOnClickListener { smoothRecenter() }
        }
        controls.addView(smoothRecenterButton)

        captureCenterButton = Button(this).apply {
            text = "CAPTURE CENTER FROM LAST 0.8 SEC"
            isEnabled = false
            setOnClickListener { captureCenter() }
        }
        controls.addView(captureCenterButton)

        controls.addView(TextView(this).apply {
            text = "Camera controls"
            textSize = 20f
            setPadding(0, dp(14), 0, dp(4))
        })
        cameraStateView = TextView(this).apply {
            text = "Camera state: waiting for 02/80 and property readback"
            textSize = 14f
            setPadding(0, 0, 0, dp(6))
        }
        controls.addView(cameraStateView)

        videoFormatPolicyView = TextView(this).apply {
            text = "Video format: waiting for effective orientation readback"
            textSize = 13f
        }
        controls.addView(videoFormatPolicyView)

        val videoFormatRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        videoResolutionAdapter = ArrayAdapter(
            this,
            android.R.layout.simple_spinner_dropdown_item,
            ArrayList<String>(),
        )
        videoResolutionSpinner = Spinner(this).apply { adapter = videoResolutionAdapter }
        videoFrameRateSpinner = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@MainActivity,
                android.R.layout.simple_spinner_dropdown_item,
                videoFrameRateOptions.map { it.displayName },
            )
        }
        videoFormatRow.addView(
            videoResolutionSpinner,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        videoFormatRow.addView(
            videoFrameRateSpinner,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        controls.addView(videoFormatRow)
        videoFormatButton = Button(this).apply {
            text = "SET VIDEO FORMAT"
            isEnabled = false
            setOnClickListener {
                val resolution = videoResolutionOptions.getOrNull(videoResolutionSpinner.selectedItemPosition)
                    ?: return@setOnClickListener
                val frameRate = videoFrameRateOptions.getOrNull(videoFrameRateSpinner.selectedItemPosition)
                    ?: return@setOnClickListener
                val aspect = session.cameraState().readback.sensorAspectRatio
                    ?: return@setOnClickListener
                if (!Pocket3CameraPolicy.videoFormatSupported(resolution, aspect)) return@setOnClickListener
                session.camera.setVideoFormat(resolution, frameRate)
                setStatus("Video format command queued: ${resolution.displayName}/${frameRate.displayName}")
            }
        }
        controls.addView(videoFormatButton)

        fun <T> addCameraPicker(
            label: String,
            options: List<T>,
            display: (T) -> String,
            onApply: (T) -> Unit,
        ) {
            val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
            val spinner = Spinner(this).apply {
                adapter = ArrayAdapter(
                    this@MainActivity,
                    android.R.layout.simple_spinner_dropdown_item,
                    options.map(display),
                )
            }
            val apply = Button(this).apply {
                text = "SET $label"
                isEnabled = false
                setOnClickListener {
                    @Suppress("UNCHECKED_CAST")
                    onApply(options[spinner.selectedItemPosition])
                }
            }
            cameraSettingButtons += apply
            row.addView(spinner, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
            row.addView(apply)
            controls.addView(row)
        }

        addCameraPicker("EXPOSURE", Pocket3ExposureMode.entries, { it.displayName }) {
            session.camera.setExposureMode(it)
            setStatus("Exposure mode command queued: ${it.displayName}")
        }
        addCameraPicker("ISO", Pocket3ManualIso.entries, { it.displayName }) {
            session.camera.setManualIso(it)
            setStatus("ISO command queued: ${it.displayName}; effective ISO remains readback-driven")
        }
        addCameraPicker("ISO MAX", Pocket3IsoMax.entries, { it.displayName }) {
            session.camera.setIsoMax(it)
            setStatus("ISO MAX command queued: ${it.displayName} (no confirmed readback)")
        }

        val shutterRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        shutterAdapter = ArrayAdapter(
            this,
            android.R.layout.simple_spinner_dropdown_item,
            ArrayList<String>(),
        )
        shutterSpinner = Spinner(this).apply { adapter = shutterAdapter }
        shutterButton = Button(this).apply {
            text = "SET SHUTTER"
            isEnabled = false
            setOnClickListener {
                val shutter = shutterOptions.getOrNull(shutterSpinner.selectedItemPosition)
                    ?: return@setOnClickListener
                session.camera.setManualShutter(shutter)
                setStatus("Shutter command queued: ${shutter.displayName} (no confirmed readback)")
            }
        }
        shutterRow.addView(shutterSpinner, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        shutterRow.addView(shutterButton)
        controls.addView(shutterRow)

        addCameraPicker("EV", Pocket3CameraPolicy.evThirdStops().toList(), { evLabel(it) }) {
            check(session.camera.setAutoEv(it))
            setStatus("EV command queued: ${evLabel(it)}")
        }

        val whiteBalanceOptions: List<Pocket3WhiteBalance> =
            listOf(Pocket3WhiteBalance.Auto) +
                Pocket3CameraPolicy.whiteBalanceKelvinValues().map(Pocket3WhiteBalance::CustomKelvin)
        addCameraPicker("WB", whiteBalanceOptions, { whiteBalanceLabel(it) }) {
            check(session.camera.setWhiteBalance(it))
            setStatus("White balance command queued: ${whiteBalanceLabel(it)}")
        }
        addCameraPicker("COLOR", Pocket3ColorProfile.entries, { it.displayName }) {
            session.camera.setColorProfile(it)
            setStatus("Color profile command queued: ${it.displayName}")
        }
        addCameraPicker("CODEC", Pocket3VideoCompression.entries, { it.displayName }) {
            session.camera.setVideoCompression(it)
            setStatus("Compression command queued: ${it.displayName}")
        }
        addCameraPicker("FOCUS", Pocket3FocusMode.entries, { it.displayName }) {
            session.camera.setFocusMode(it)
            setStatus("Focus mode command queued: ${it.displayName}")
        }

        recordButton = Button(this).apply {
            text = "RECORD — WAITING FOR CAMERA STATE"
            isEnabled = false
            setOnClickListener {
                val current = session.cameraState().recording ?: return@setOnClickListener
                session.camera.setRecording(!current)
            }
        }
        controls.addView(recordButton)

        copyLogButton = Button(this).apply {
            text = "COPY APP LOG"
            setOnClickListener { copyLog() }
        }
        controls.addView(copyLogButton)

        if (isDebugBuild()) {
            controls.addView(Button(this).apply {
                text = "RETURN TO KAZE UI"
                setOnClickListener { showKazeUi() }
            })
        }

        // Extra bottom room makes the last button easy to bring fully above the log panel/nav bar.
        controls.addView(View(this), LinearLayout.LayoutParams(1, dp(18)))

        val controlScroll = JoystickScrollView(this).apply {
            isFillViewport = false
            addView(
                controls,
                android.widget.FrameLayout.LayoutParams(
                    android.widget.FrameLayout.LayoutParams.MATCH_PARENT,
                    android.widget.FrameLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        joystick.onGestureOwnershipChanged = controlScroll::setJoystickGestureActive
        outer.addView(
            controlScroll,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f),
        )

        outer.addView(TextView(this).apply {
            text = "App log (scrollable)"
            textSize = 15f
            setPadding(dp(20), dp(5), dp(20), dp(2))
        })

        logView = TextView(this).apply {
            textSize = 10f
            movementMethod = ScrollingMovementMethod()
            setTextIsSelectable(true)
            setPadding(dp(12), dp(4), dp(12), dp(4))
        }
        val logScroll = ScrollView(this).apply { addView(logView) }
        outer.addView(
            logScroll,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(115)),
        )

        return outer
    }

    // ---- Connection ---------------------------------------------------------------------------

    private fun requiredPermissions(): Array<String> {
        val out = ArrayList<String>()
        if (Build.VERSION.SDK_INT >= 31) {
            out += Manifest.permission.BLUETOOTH_SCAN
            out += Manifest.permission.BLUETOOTH_CONNECT
        } else {
            out += Manifest.permission.ACCESS_FINE_LOCATION
        }
        if (Build.VERSION.SDK_INT >= 33) {
            out += Manifest.permission.NEARBY_WIFI_DEVICES
        }
        return out.toTypedArray()
    }

    private fun ensurePermissionsAndConnect() {
        val missing = requiredPermissions().filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            appendLog("Requesting Android Bluetooth/Wi-Fi permissions")
            requestPermissions(missing.toTypedArray(), REQ_CONNECTION_PERMS)
            return
        }
        startConnection()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_CONNECTION_PERMS) return
        if (grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }) {
            startConnection()
        } else {
            appendLog("Connection permission denied")
            setStatus("Bluetooth/Wi-Fi permission required")
        }
    }

    private fun startConnection() {
        connectionPhase = KazeConnectionPhase.CONNECTING
        setControlsEnabled(false)
        videoFrameRateDraftInitialized = false
        connectButton.isEnabled = false
        disconnectButton.isEnabled = false
        connectButton.text = "CONNECTING …"
        capturedCenter = null
        centerView.text = "Measured center: not captured"
        pairingDialog?.dismiss()
        pairingDialog = null
        setStatus("Resetting previous session …")

        // Close the old UDP socket before releasing/rebinding Android's process network.
        worker.execute {
            session.disconnect()
            main.post { connection.start() }
        }
    }

    override fun onConnectionLog(message: String) = appendLog(message)

    override fun onConnectionState(message: String) = setStatus(message)

    override fun onPairingApprovalRequired() {
        if (isFinishing || isDestroyed) return
        pairingDialog?.dismiss()
        pairingDialog = AlertDialog.Builder(this)
            .setTitle("Approve Pocket 3 pairing")
            .setMessage("Look at the Pocket 3 screen and approve the connection request. The app will continue automatically.")
            .setPositiveButton("OK", null)
            .show()
        setStatus("Approve pairing on the Pocket 3 screen")
    }

    override fun onPocket3Network(network: Network, link: LinkProperties?) {
        appendLog("Connection manager handed the bound Pocket 3 Wi-Fi network to gimbal session")
        worker.execute {
            val ok = runCatching { session.connect() }
                .onFailure { appendLog("DATALINK ERROR: ${it.message}") }
                .getOrDefault(false)
            main.post {
                connectionPhase = if (ok) KazeConnectionPhase.CONNECTED else KazeConnectionPhase.DISCONNECTED
                connectButton.isEnabled = true
                connectButton.text = if (ok) "RECONNECT VIA BLUETOOTH" else "CONNECT VIA BLUETOOTH"
                disconnectButton.isEnabled = ok
                setControlsEnabled(ok)
                setStatus(if (ok) "Connected — live preview + controls ready" else "Wi-Fi joined, but gimbal datalink failed")
            }
        }
    }

    private fun disconnectFromPocket() {
        appendLog("Explicit disconnect requested")
        connectionPhase = KazeConnectionPhase.DISCONNECTING
        renderKazePresentation()
        setControlsEnabled(false)
        connectButton.isEnabled = false
        disconnectButton.isEnabled = false
        setStatus("Disconnecting safely …")
        worker.execute {
            session.disconnect()
            main.post {
                connection.teardown()
                connectionPhase = KazeConnectionPhase.DISCONNECTED
                renderKazePresentation()
                connectButton.isEnabled = true
                connectButton.text = "CONNECT VIA BLUETOOTH"
                setStatus("Disconnected")
            }
        }
    }

    override fun onPocket3NetworkLost() {
        connectionPhase = KazeConnectionPhase.DISCONNECTED
        appendLog("WiFi: network-loss callback reached app; stopping gimbal session")
        setControlsEnabled(false)
        disconnectButton.isEnabled = false
        setStatus("Pocket 3 Wi-Fi lost")
        worker.execute {
            session.disconnect()
            main.post {
                connectButton.isEnabled = true
                connectButton.text = "RECONNECT VIA BLUETOOTH"
            }
        }
    }

    override fun onConnectionFailed(message: String) {
        main.post {
            connectionPhase = KazeConnectionPhase.DISCONNECTED
            setControlsEnabled(false)
            disconnectButton.isEnabled = false
            connectButton.isEnabled = true
            connectButton.text = "CONNECT VIA BLUETOOTH"
        }
    }

    // ---- Controls -----------------------------------------------------------------------------

    private fun onJoystickChanged(pitch: Int, yaw: Int, active: Boolean) {
        joystickValues.text = "Joystick: pitch=$pitch  yaw=$yaw"
        if (!session.connected) return

        if (active) {
            manualInputOwner = ManualInputOwner.TOUCH
            session.setJoystick(pitch, yaw)
            if (!joystickWasActive) {
                joystickWasActive = true
                appendLog("Virtual joystick engaged")
            }
            setStatus("Joystick active")
        } else {
            val ownedControl = manualInputOwner == ManualInputOwner.TOUCH
            if (ownedControl) {
                session.releaseJoystick()
                manualInputOwner = null
            }
            if (joystickWasActive) {
                appendLog(if (ownedControl) "Virtual joystick released -> neutral" else "Virtual joystick released; newer manual source retains control")
            }
            joystickWasActive = false
            setStatus(if (ownedControl) "Joystick released — neutral" else "Touch released — other manual input remains active")
        }
    }

    private fun onGamepadJoystickChanged(pitch: Int, yaw: Int, active: Boolean) {
        if (!session.connected) return
        if (active) {
            manualInputOwner = ManualInputOwner.GAMEPAD
            session.setJoystick(pitch, yaw)
            setStatus("Gamepad active")
        } else if (manualInputOwner == ManualInputOwner.GAMEPAD) {
            session.releaseJoystick()
            manualInputOwner = null
            setStatus("Gamepad released — neutral")
        }
    }

    private fun toggleJoystickMode() {
        // Make the profile change at neutral so there is never a discontinuous command while moving.
        if (::gameController.isInitialized) gameController.releaseActiveControl("response profile changed")
        if (session.connected) session.releaseJoystick()
        manualInputOwner = null
        joystickWasActive = false
        val next = when (joystick.responseMode) {
            JoystickResponseMode.LINEAR -> JoystickResponseMode.PROGRESSIVE
            JoystickResponseMode.PROGRESSIVE -> JoystickResponseMode.LINEAR
        }
        joystick.setResponseMode(next)
        joystickModeButton.text = when (next) {
            JoystickResponseMode.LINEAR -> "JOYSTICK: LINEAR"
            JoystickResponseMode.PROGRESSIVE -> "JOYSTICK: PROGRESSIVE"
        }
        joystickValues.text = "Joystick: pitch=1024  yaw=1024"
        appendLog(
            when (next) {
                JoystickResponseMode.LINEAR ->
                    "Joystick response -> LINEAR (v0.13 behavior, +/-330)"
                JoystickResponseMode.PROGRESSIVE ->
                    "Joystick response -> PROGRESSIVE (more aggressive midrange, soft center, same full +/-550)"
            }
        )
        setStatus(if (next == JoystickResponseMode.LINEAR) "Linear joystick profile" else "Progressive joystick profile")
    }

    private fun recenter() {
        session.releaseJoystick()
        joystickWasActive = false
        setStatus("RECENTER requested …")
        runCatching { session.recenter() }
            .onFailure {
                appendLog("RECENTER ERROR: ${it.message}")
                setStatus("RECENTER failed")
            }
    }

    private fun smoothRecenter() {
        session.releaseJoystick()
        joystickWasActive = false
        val c = capturedCenter
        if (c == null) {
            appendLog("SMOOTH RECENTER ERROR: capture the RECENTER position first")
            setStatus("Capture center before smooth recenter")
            return
        }
        setStatus("Smooth recenter running using captured center …")
        runCatching { session.smoothRecenter(c.pitchDeg, c.yawContinuousDeg) }
            .onFailure {
                appendLog("SMOOTH RECENTER ERROR: ${it.message}")
                setStatus("Smooth recenter could not start")
            }
    }

    private fun captureCenter() {
        val center = session.averageRecentTelemetry(800L)
        if (center == null) {
            appendLog("CENTER CAPTURE FAILED: no fresh 04/05 samples in the last 0.8 sec")
            setStatus("No fresh 04/05 telemetry to capture")
            return
        }
        capturedCenter = center
        appendLog(
            "CENTER CAPTURED from recent 04/05: pitch=${fmt(center.pitchDeg)}° " +
                "roll=${fmt(center.rollDeg)}° yaw=${fmt(center.yawDeg)}° " +
                "Ycont=${fmt(center.yawContinuousDeg)}°"
        )
        setStatus("Measured center captured")
        renderTelemetry()
    }

    private fun neutral() {
        if (::gameController.isInitialized) gameController.releaseActiveControl("neutral requested")
        manualInputOwner = null
        runCatching { session.neutral() }
            .onFailure { appendLog("NEUTRAL ERROR: ${it.message}") }
        joystickWasActive = false
        setStatus("Neutral / stop requested")
    }

    private fun renderTelemetry() {
        if (!::telemetryView.isInitialized) return
        val t = session.latestTelemetry()
        if (t == null) {
            telemetryView.text = "04/05 telemetry: waiting"
            captureCenterButton.isEnabled = false
            smoothRecenterButton.isEnabled = false
            return
        }

        val age = session.telemetryAgeMs()
        val limits = if (t.limitFlags == null) {
            "unknown"
        } else {
            "P=${if (t.pitchAtLimit) "LIMIT" else "ok"} " +
                "R=${if (t.rollAtLimit) "LIMIT" else "ok"} " +
                "Y=${if (t.yawAtLimit) "LIMIT" else "ok"} " +
                "stuck=${if (t.stuck) "YES" else "no"}"
        }

        telemetryView.text =
            "04/05: pitch=${fmt(t.pitchDeg)}°  roll=${fmt(t.rollDeg)}°  yaw=${fmt(t.yawDeg)}°  " +
                "Ycont=${fmt(t.yawContinuousDeg)}°\n" +
                "age=${if (age == Long.MAX_VALUE) "none" else "${age} ms"}  " +
                "mode=${t.mode?.let { "0x%02X".format(it) } ?: "--"}  limits: $limits"

        captureCenterButton.isEnabled = session.connected && age < 500
        smoothRecenterButton.isEnabled = session.connected && age < 350 && capturedCenter != null
        smoothRecenterButton.text = if (session.isSmoothRecenterActive()) {
            "SMOOTH RECENTER — RUNNING"
        } else {
            "SMOOTH RECENTER"
        }

        val c = capturedCenter
        centerView.text = if (c == null) {
            "Measured center: not captured"
        } else {
            val pErr = session.wrappedAngleError(c.pitchDeg, t.pitchDeg)
            val yErr = c.yawContinuousDeg - t.yawContinuousDeg
            "Measured center: P=${fmt(c.pitchDeg)}° Y=${fmt(c.yawDeg)}° " +
                "Ycont=${fmt(c.yawContinuousDeg)}°   current error: P=${fmt(pErr)}° Y=${fmt(yErr)}°"
        }
    }

    private fun renderCamera() {
        if (!::cameraStateView.isInitialized) return
        val state = session.cameraState()
        val recording = when (state.recording) {
            true -> "RECORDING"
            false -> "IDLE"
            null -> "waiting"
        }
        val transition = if (state.recordingTransitionInProgress) " (transition)" else ""
        val mode = state.shootingMode?.displayName ?: state.shootingModeCode?.let { "0x%02X".format(it) } ?: "--"
        val rb = state.readback
        val exposure = rb.exposureMode?.displayName ?: "--"
        val iso = rb.effectiveIso?.toString() ?: "--"
        val ev = rb.evThirdStops?.let(::evLabel) ?: "--"
        val wb = rb.whiteBalance?.let(::whiteBalanceReadbackLabel) ?: "--"
        val orientation = rb.sensorAspectRatio?.displayName ?: "--"
        val videoFormat = if (rb.videoResolution != null && rb.videoFrameRate != null) {
            "${rb.videoResolution.displayName}/${rb.videoFrameRate.displayName}"
        } else "--"
        val compression = rb.videoCompression?.displayName ?: "--"
        val color = rb.colorProfile?.displayName ?: "--"
        val focus = rb.focusMode?.displayName ?: "--"
        val storage = if (state.storageFreeMiB != null && state.storageTotalMiB != null) {
            "${state.storageFreeMiB}/${state.storageTotalMiB} MiB free/total"
        } else "--"
        val timing = if (state.elapsedRecordSeconds != null && state.remainingRecordSeconds != null) {
            " elapsed=${state.elapsedRecordSeconds}s remaining=${state.remainingRecordSeconds}s"
        } else ""

        cameraStateView.text =
            "Camera: $recording$transition  mode=$mode  storage=$storage$timing\n" +
                "Confirmed video: orientation=$orientation  format=$videoFormat  codec=$compression\n" +
                "Confirmed image: color=$color  focus=$focus  exposure=$exposure  ISO=$iso  EV=$ev  WB=$wb"
        refreshCameraPolicy(state)
        recordButton.text = when (state.recording) {
            true -> "STOP RECORDING"
            false -> "START RECORDING"
            null -> "RECORD — WAITING FOR CAMERA STATE"
        }
        recordButton.isEnabled = cameraControlsEnabled && session.connected && state.canToggleRecording
    }

    private fun renderVideo() {
        if (!::videoStatusView.isInitialized) return
        val state = session.videoOutput.state()
        val label = when (state.status) {
            Pocket3VideoStatus.STOPPED -> "stopped"
            Pocket3VideoStatus.WAITING_FOR_VIDEO -> "WAITING FOR VIDEO"
            Pocket3VideoStatus.VIDEO_RECEIVING -> "VIDEO RECEIVING"
            Pocket3VideoStatus.DECODING -> "DECODING"
            Pocket3VideoStatus.ERROR -> "ERROR"
        }
        val dimensions = if (state.width != null && state.height != null) {
            " ${state.width}x${state.height}"
        } else ""
        videoStatusView.text =
            "Live preview: $label$dimensions\n" +
                "pkt=${state.packetsReceived} msg=${state.completedMediaMessages} " +
                "SPS/PPS/IDR=${state.spsCount}/${state.ppsCount}/${state.idrCount} " +
                "AU=${state.accessUnitCount} output=${state.decoderOutputFrames} rendered=${state.renderedFrames}\n" +
                "malformed=${state.malformedPackets} partialDrop=${state.droppedPartialMessages} " +
                "queueDrop=${state.droppedDatagrams} decoderReset/error=${state.decoderResets}/${state.decoderErrors}"
    }

    private fun renderKazePresentation() {
        kazeUiState = KazeCameraPresentation.create(
            connectionPhase = connectionPhase,
            connectionDetail = connectionDetail,
            camera = session.cameraState(),
            video = session.videoOutput.state(),
            joystickMode = joystick.responseMode,
            connectedCameraDisplayName = "Pocket 3",
            gimbalLocked = session.isGimbalLocked(),
        )
        updatePictureInPictureParams()
    }

    private fun setControlsEnabled(enabled: Boolean) {
        cameraControlsEnabled = enabled
        joystick.isEnabled = enabled
        recenterButton.isEnabled = enabled
        neutralButton.isEnabled = enabled
        smoothRecenterButton.isEnabled = enabled && session.telemetryAgeMs() < 350 && capturedCenter != null
        captureCenterButton.isEnabled = enabled && session.telemetryAgeMs() < 500
        cameraSettingButtons.forEach { it.isEnabled = enabled }
        refreshCameraPolicy(session.cameraState())
        recordButton.isEnabled = enabled && session.cameraState().canToggleRecording
    }

    private fun refreshCameraPolicy(state: Pocket3CameraState) {
        if (!::videoFormatPolicyView.isInitialized) return
        val readback = state.readback
        val aspect = readback.sensorAspectRatio
        val allowedResolutions = Pocket3CameraPolicy.normalVideoResolutions(aspect)
        if (allowedResolutions != videoResolutionOptions || aspect != lastVideoAspectRatio) {
            videoResolutionOptions = allowedResolutions
            lastVideoAspectRatio = aspect
            videoResolutionAdapter.clear()
            videoResolutionAdapter.addAll(allowedResolutions.map { it.displayName })
            videoResolutionAdapter.notifyDataSetChanged()
            val confirmedIndex = allowedResolutions.indexOf(readback.videoResolution)
            if (confirmedIndex >= 0) videoResolutionSpinner.setSelection(confirmedIndex)
        }
        if (!videoFrameRateDraftInitialized) {
            val confirmedIndex = videoFrameRateOptions.indexOf(readback.videoFrameRate)
            if (confirmedIndex >= 0) {
                videoFrameRateSpinner.setSelection(confirmedIndex)
                videoFrameRateDraftInitialized = true
            }
        }

        videoFormatPolicyView.text = if (aspect == null) {
            "Video format: waiting for effective orientation readback"
        } else {
            "Video format follows confirmed ${aspect.displayName.lowercase()} orientation; normal video exposes 24–60 fps only."
        }
        videoFormatButton.isEnabled =
            cameraControlsEnabled && session.connected &&
                state.shootingMode == Pocket3CameraShootingMode.VIDEO &&
                aspect != null && allowedResolutions.isNotEmpty()

        val allowedShutters = Pocket3CameraPolicy.manualShutters(state.shootingMode, readback.videoFrameRate)
            ?: emptyList()
        if (allowedShutters != shutterOptions) {
            val selected = shutterOptions.getOrNull(shutterSpinner.selectedItemPosition)
            shutterOptions = allowedShutters
            shutterAdapter.clear()
            shutterAdapter.addAll(allowedShutters.map { it.displayName })
            shutterAdapter.notifyDataSetChanged()
            val preservedIndex = allowedShutters.indexOf(selected)
            if (preservedIndex >= 0) shutterSpinner.setSelection(preservedIndex)
        }
        shutterButton.isEnabled = cameraControlsEnabled && session.connected && allowedShutters.isNotEmpty()
    }

    private fun evLabel(thirdStops: Int): String = "%+.1f EV".format(thirdStops / 3.0)

    private fun whiteBalanceLabel(value: Pocket3WhiteBalance): String = when (value) {
        Pocket3WhiteBalance.Auto -> "Auto"
        is Pocket3WhiteBalance.CustomKelvin -> "${value.kelvin}K"
    }

    private fun whiteBalanceReadbackLabel(value: Pocket3WhiteBalanceReadback): String = when (value) {
        Pocket3WhiteBalanceReadback.Auto -> "Auto"
        is Pocket3WhiteBalanceReadback.CustomKelvin -> "${value.kelvin}K"
    }

    private fun copyLog() {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Pocket3 Gimbal Test v0.14.3 log", logView.text))
        setStatus("App log copied to clipboard")
        appendLog("UI log copied to clipboard")
    }

    private fun setStatus(s: String) {
        main.post {
            connectionDetail = s
            status.text = "Status: $s"
            renderKazePresentation()
        }
    }

    private fun appendLog(message: String) {
        Log.i(LOG_TAG, message)
        main.post {
            if (!::logView.isInitialized) return@post
            logView.append(message + "\n")
            logView.post {
                val layout = logView.layout ?: return@post
                val scrollAmount = layout.getLineTop(logView.lineCount) - logView.height
                if (scrollAmount > 0) logView.scrollTo(0, scrollAmount)
            }
        }
    }

    private fun fmt(v: Double): String = "%+.1f".format(v)

    private fun isDebugBuild(): Boolean =
        applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0

    override fun dispatchGenericMotionEvent(event: MotionEvent): Boolean {
        if (::gameController.isInitialized && gameController.handleMotionEvent(event)) return true
        return super.dispatchGenericMotionEvent(event)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (::gameController.isInitialized && gameController.handleKeyEvent(event)) return true
        return super.dispatchKeyEvent(event)
    }

    override fun onResume() {
        super.onResume()
        pictureInPictureActive = isInPictureInPictureMode
        if (showingKazeUi && !pictureInPictureActive) configureKazeWindow()
        updatePictureInPictureParams(force = true)
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        // Android 12+ uses the system's smoother auto-enter transition. Older supported
        // releases still need the explicit user-leave fallback.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            !isInPictureInPictureMode &&
            shouldEnterPictureInPicture()
        ) {
            val config = pictureInPictureConfig()
            val entered = enterPictureInPictureMode(buildPictureInPictureParams(config))
            appendLog("PiP: explicit auto-enter requested; entered=$entered")
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pictureInPictureActive = isInPictureInPictureMode
        appendLog("PiP: ${if (isInPictureInPictureMode) "entered" else "exited"}")
        if (!isInPictureInPictureMode && showingKazeUi) configureKazeWindow()
        updatePictureInPictureParams(force = true)
    }

    override fun onPause() {
        if (::gameController.isInitialized) gameController.releaseActiveControl("activity paused")
        if (manualInputOwner == ManualInputOwner.GAMEPAD) manualInputOwner = null
        appendLog("Activity onPause; Pocket session retained")
        super.onPause()
    }

    override fun onStop() {
        appendLog("Activity onStop; Pocket session retained")
        super.onStop()
    }

    override fun onDestroy() {
        appendLog("Activity onDestroy; changingConfiguration=$isChangingConfigurations finishing=$isFinishing")
        main.removeCallbacks(telemetryUiTicker)
        pairingDialog?.dismiss()
        pairingDialog = null
        if (::gameController.isInitialized) gameController.stop()
        pocketOwner.detach(this)
        super.onDestroy()
    }
}
