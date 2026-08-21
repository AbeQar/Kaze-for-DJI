package com.pocket3.gimbaltest.input.release

import android.content.Context
import android.hardware.input.InputManager
import android.os.Handler
import android.os.Looper
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import com.pocket3.gimbaltest.JoystickResponse
import com.pocket3.gimbaltest.JoystickResponseMode

internal data class AndroidGameControllerState(
    val connected: Boolean = false,
    val controllerName: String = "",
    val settings: GamepadControlSettings = GamepadControlSettings(),
    val inputActive: Boolean = false,
) {
    val statusText: String
        get() = if (connected) {
            if (inputActive) "Gamepad active — $controllerName" else "Gamepad connected — $controllerName"
        } else {
            "No game controller detected"
        }
}

/** Private/release physical-controller input. No DJI transport lives here. */
internal class AndroidGameControllerManager(
    context: Context,
    private val responseModeProvider: () -> JoystickResponseMode,
    private val onJoystick: (pitch: Int, yaw: Int, active: Boolean) -> Unit,
    private val onRecenter: () -> Unit,
    private val onNeutral: () -> Unit,
    private val onCaptureCenter: () -> Unit,
    private val onSmoothReturn: () -> Unit,
    private val onLog: (String) -> Unit,
) : InputManager.InputDeviceListener {
    private val appContext = context.applicationContext
    private val inputManager = appContext.getSystemService(Context.INPUT_SERVICE) as InputManager
    private val main = Handler(Looper.getMainLooper())
    private val preferences = appContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private var started = false
    private var activeDeviceId: Int? = null
    private var inputActive = false
    private var settings = loadSettings()

    var onStateChanged: ((AndroidGameControllerState) -> Unit)? = null

    fun start() {
        if (started) return
        started = true
        inputManager.registerInputDeviceListener(this, main)
        refreshController("startup")
    }

    fun stop() {
        if (!started) return
        releaseActiveControl("manager stopped")
        inputManager.unregisterInputDeviceListener(this)
        started = false
    }

    fun releaseActiveControl(reason: String) {
        if (!inputActive) return
        inputActive = false
        onJoystick(JoystickResponse.NEUTRAL, JoystickResponse.NEUTRAL, false)
        onLog("Game controller released -> neutral ($reason)")
        publishState()
    }

    fun setStickLayout(layout: GamepadStickLayout) {
        if (settings.stickLayout == layout) return
        releaseActiveControl("layout changed")
        settings = settings.copy(stickLayout = layout)
        preferences.edit().putString(KEY_STICK_LAYOUT, layout.name).apply()
        onLog("Game controller layout -> ${layout.name}")
        publishState()
    }

    fun setInvertPitch(enabled: Boolean) {
        if (settings.invertPitch == enabled) return
        releaseActiveControl("pitch inversion changed")
        settings = settings.copy(invertPitch = enabled)
        preferences.edit().putBoolean(KEY_INVERT_PITCH, enabled).apply()
        onLog("Game controller invert pitch -> $enabled")
        publishState()
    }

    fun setInvertYaw(enabled: Boolean) {
        if (settings.invertYaw == enabled) return
        releaseActiveControl("yaw inversion changed")
        settings = settings.copy(invertYaw = enabled)
        preferences.edit().putBoolean(KEY_INVERT_YAW, enabled).apply()
        onLog("Game controller invert yaw -> $enabled")
        publishState()
    }

    fun handleMotionEvent(event: MotionEvent): Boolean {
        val device = event.device ?: return false
        if (!isGameController(device) || event.action != MotionEvent.ACTION_MOVE) return false
        adoptDevice(device)

        val leftX = event.getAxisValue(MotionEvent.AXIS_X)
        val leftY = event.getAxisValue(MotionEvent.AXIS_Y)
        val rightX = axisWithFallback(event, device, MotionEvent.AXIS_Z, MotionEvent.AXIS_RX)
        val rightY = axisWithFallback(event, device, MotionEvent.AXIS_RZ, MotionEvent.AXIS_RY)
        val mapped = GamepadInputMapper.map(
            leftX = leftX,
            leftY = leftY,
            rightX = rightX,
            rightY = rightY,
            settings = settings,
            responseMode = responseModeProvider(),
        )

        if (mapped.active) {
            onJoystick(mapped.command.pitch, mapped.command.yaw, true)
            if (!inputActive) {
                inputActive = true
                onLog("Game controller stick engaged")
                publishState()
            }
        } else if (inputActive) {
            inputActive = false
            onJoystick(JoystickResponse.NEUTRAL, JoystickResponse.NEUTRAL, false)
            onLog("Game controller stick released -> neutral")
            publishState()
        }
        return true
    }

    fun handleKeyEvent(event: KeyEvent): Boolean {
        val device = event.device ?: return false
        if (!isGameController(device) || !isControllerButton(event.keyCode)) return false
        adoptDevice(device)

        // One action per physical press. ACTION_UP is consumed but does not fire again.
        if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_BUTTON_A -> {
                    onLog("Game controller A/Cross -> RECENTER")
                    releaseActiveControl("A/Cross pressed")
                    onRecenter()
                }
                KeyEvent.KEYCODE_BUTTON_B -> {
                    onLog("Game controller B/Circle -> STOP / neutral")
                    releaseActiveControl("B/Circle pressed")
                    onNeutral()
                }
                KeyEvent.KEYCODE_BUTTON_X -> {
                    onLog("Game controller X/Square -> Mark center")
                    releaseActiveControl("X/Square pressed")
                    onCaptureCenter()
                }
                KeyEvent.KEYCODE_BUTTON_Y -> {
                    onLog("Game controller Y/Triangle -> Return to center")
                    releaseActiveControl("Y/Triangle pressed")
                    onSmoothReturn()
                }
            }
        }
        return true
    }

    override fun onInputDeviceAdded(deviceId: Int) = refreshController("device added")
    override fun onInputDeviceRemoved(deviceId: Int) {
        if (activeDeviceId == deviceId) releaseActiveControl("controller removed")
        refreshController("device removed")
    }
    override fun onInputDeviceChanged(deviceId: Int) = refreshController("device changed")

    private fun refreshController(reason: String) {
        val current = activeDeviceId?.let(InputDevice::getDevice)?.takeIf(::isGameController)
            ?: InputDevice.getDeviceIds()
                .asSequence()
                .mapNotNull(InputDevice::getDevice)
                .firstOrNull(::isGameController)
        val previousId = activeDeviceId
        activeDeviceId = current?.id
        if (previousId != activeDeviceId) {
            val message = if (current != null) {
                "Game controller detected: ${current.name} ($reason)"
            } else {
                "Game controller not detected ($reason)"
            }
            onLog(message)
        }
        publishState(current)
    }

    private fun adoptDevice(device: InputDevice) {
        if (activeDeviceId == device.id) return
        if (inputActive) releaseActiveControl("controller changed")
        activeDeviceId = device.id
        onLog("Game controller active: ${device.name}")
        publishState(device)
    }

    private fun publishState(device: InputDevice? = activeDeviceId?.let(InputDevice::getDevice)) {
        onStateChanged?.invoke(
            AndroidGameControllerState(
                connected = device?.let(::isGameController) == true,
                controllerName = device?.name.orEmpty(),
                settings = settings,
                inputActive = inputActive,
            )
        )
    }

    private fun axisWithFallback(event: MotionEvent, device: InputDevice, primary: Int, fallback: Int): Float {
        val primaryRange = device.getMotionRange(primary, event.source)
            ?: device.getMotionRange(primary)
        return if (primaryRange != null) event.getAxisValue(primary) else event.getAxisValue(fallback)
    }

    private fun isGameController(device: InputDevice): Boolean {
        if (device.isVirtual) return false
        val sources = device.sources
        return (sources and InputDevice.SOURCE_GAMEPAD) == InputDevice.SOURCE_GAMEPAD ||
            (sources and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK
    }

    private fun isControllerButton(keyCode: Int): Boolean = when (keyCode) {
        KeyEvent.KEYCODE_BUTTON_A,
        KeyEvent.KEYCODE_BUTTON_B,
        KeyEvent.KEYCODE_BUTTON_X,
        KeyEvent.KEYCODE_BUTTON_Y -> true
        else -> false
    }

    private fun loadSettings(): GamepadControlSettings {
        val layout = preferences.getString(KEY_STICK_LAYOUT, null)
            ?.let { runCatching { GamepadStickLayout.valueOf(it) }.getOrNull() }
            ?: GamepadStickLayout.LEFT_COMBINED
        return GamepadControlSettings(
            stickLayout = layout,
            invertPitch = preferences.getBoolean(KEY_INVERT_PITCH, false),
            invertYaw = preferences.getBoolean(KEY_INVERT_YAW, false),
        )
    }

    private companion object {
        const val PREFERENCES_NAME = "kaze_game_controller"
        const val KEY_STICK_LAYOUT = "stick_layout"
        const val KEY_INVERT_PITCH = "invert_pitch"
        const val KEY_INVERT_YAW = "invert_yaw"
    }
}
