import Foundation
import GameController
import CoreGraphics
import Combine

enum ControlInputSource: String {
    case touch = "触屏"
    case gamepad = "手柄"
}

struct GamepadMappedInput: Equatable {
    let normalizedX: CGFloat
    let normalizedY: CGFloat
    let pitch: Int
    let yaw: Int
    let active: Bool
}

enum GamepadInputMapper {
    // GCExtendedGamepad thumbstick Y is positive UP.
    // JoystickMapper expects UIKit-style normalizedY, where positive is DOWN.
    static func map(
        leftX: Float,
        leftY: Float,
        rightX: Float,
        rightY: Float,
        settings: GamepadControlSettings
    ) -> GamepadMappedInput {
        var yawAxis: CGFloat
        var pitchAxisUp: CGFloat

        switch settings.stickLayout {
        case .leftCombined:
            yawAxis = CGFloat(leftX)
            pitchAxisUp = CGFloat(leftY)

        case .rightCombined:
            yawAxis = CGFloat(rightX)
            pitchAxisUp = CGFloat(rightY)

        case .split:
            pitchAxisUp = CGFloat(leftY)
            yawAxis = CGFloat(rightX)
        }

        if settings.invertYaw {
            yawAxis *= -1
        }
        if settings.invertPitch {
            pitchAxisUp *= -1
        }

        yawAxis = min(max(yawAxis, -1), 1)
        pitchAxisUp = min(max(pitchAxisUp, -1), 1)

        let normalizedYForJoystickMapper = -pitchAxisUp
        let radius = sqrt(yawAxis * yawAxis + normalizedYForJoystickMapper * normalizedYForJoystickMapper)
        let active = radius >= JoystickMapper.deadZone

        let mapped = JoystickMapper.map(
            normalizedX: yawAxis,
            normalizedY: normalizedYForJoystickMapper,
            mode: settings.responseMode
        )

        return GamepadMappedInput(
            normalizedX: yawAxis,
            normalizedY: normalizedYForJoystickMapper,
            pitch: mapped.pitch,
            yaw: mapped.yaw,
            active: active
        )
    }
}

final class GameControllerManager: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var controllerName = "未连接手柄"
    @Published private(set) var controllerCategory = ""
    @Published private(set) var statusText = "未连接游戏手柄"
    @Published private(set) var lastInputSource: ControlInputSource = .touch
    @Published private(set) var isDiscovering = false

    var settingsProvider: (() -> GamepadControlSettings)?
    var onMappedInput: ((GamepadMappedInput) -> Void)?
    var onRecenter: (() -> Void)?
    var onStopNeutral: (() -> Void)?
    var onCaptureCenter: (() -> Void)?
    var onSmoothRecenter: (() -> Void)?
    /// Fires on physical-stick activity transitions even when another source
    /// owns the gimbal. v0.6 uses this only to suspend/resume head tracking.
    var onManualActivityChanged: ((Bool) -> Void)?

    private var activeController: GCController?
    private var started = false
    private var gamepadWasActive = false
    private var discoveryGeneration = 0

    deinit {
        stop()
    }

    func start() {
        guard !started else {
            refreshConnectedControllers()
            return
        }
        started = true

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: NSNotification.Name.GCControllerDidConnect,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: NSNotification.Name.GCControllerDidDisconnect,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(controllerDidBecomeCurrent(_:)),
            name: NSNotification.Name.GCControllerDidBecomeCurrent,
            object: nil
        )

        refreshConnectedControllers()
    }

    func stop() {
        guard started else { return }
        started = false

        GCController.stopWirelessControllerDiscovery()
        isDiscovering = false
        discoveryGeneration &+= 1

        NotificationCenter.default.removeObserver(self)

        detachController(sendNeutralIfOwned: true)
    }


    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        consider(controller)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        controllerDisconnected(controller)
    }

    @objc private func controllerDidBecomeCurrent(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        consider(controller, prefer: true)
    }

    func discoverControllers() {
        discoveryGeneration &+= 1
        let generation = discoveryGeneration
        isDiscovering = true
        statusText = "正在查找手柄…"

        GCController.startWirelessControllerDiscovery { [weak self] in
            DispatchQueue.main.async {
                guard let self, generation == self.discoveryGeneration else { return }
                self.refreshConnectedControllers()
            }
        }

        // Discovery is intentionally bounded. Already paired controllers also
        // arrive through GCControllerDidConnect notifications.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, generation == self.discoveryGeneration else { return }
            GCController.stopWirelessControllerDiscovery()
            self.isDiscovering = false
            self.refreshConnectedControllers()
            if !self.isConnected {
                self.statusText = "未找到手柄，请先在 iPhone 蓝牙设置中配对后重试"
            }
        }
    }

    func refreshConnectedControllers() {
        if let current = GCController.current, current.extendedGamepad != nil {
            consider(current, prefer: true)
            return
        }

        if let controller = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            consider(controller)
            return
        }

        if activeController == nil {
            isConnected = false
            controllerName = "未连接手柄"
            controllerCategory = ""
            if !isDiscovering {
                statusText = "未连接游戏手柄"
            }
        }
    }

    func settingsDidChange() {
        // Never remap a physically deflected stick in-place. Neutralize first;
        // the new layout/inversion takes effect on the next controller change.
        if gamepadWasActive, lastInputSource == .gamepad {
            onMappedInput?(
                GamepadMappedInput(
                    normalizedX: 0,
                    normalizedY: 0,
                    pitch: JoystickMapper.neutral,
                    yaw: JoystickMapper.neutral,
                    active: false
                )
            )
        }
        if gamepadWasActive {
            onManualActivityChanged?(false)
        }
        gamepadWasActive = false
    }

    func noteTouchInput(active: Bool) {
        if active, lastInputSource != .touch {
            lastInputSource = .touch
        }
    }

    private func consider(_ controller: GCController, prefer: Bool = false) {
        guard controller.extendedGamepad != nil else { return }

        if let activeController, activeController !== controller, !prefer {
            return
        }

        attach(controller)
    }

    private func attach(_ controller: GCController) {
        if activeController === controller {
            publishControllerIdentity(controller)
            return
        }

        detachController(sendNeutralIfOwned: true)
        guard let gamepad = controller.extendedGamepad else { return }

        activeController = controller
        controller.handlerQueue = .main
        isConnected = true
        isDiscovering = false
        GCController.stopWirelessControllerDiscovery()
        discoveryGeneration &+= 1
        publishControllerIdentity(controller)
        statusText = "手柄已就绪"

        gamepad.valueChangedHandler = { [weak self] profile, _ in
            self?.handleStickState(profile)
        }

        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.lastInputSource = .gamepad
            self?.onRecenter?()
        }

        gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            guard let self else { return }
            self.lastInputSource = .gamepad
            if self.gamepadWasActive {
                self.onManualActivityChanged?(false)
            }
            self.gamepadWasActive = false
            self.onStopNeutral?()
        }

        gamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            self?.lastInputSource = .gamepad
            self?.onCaptureCenter?()
        }

        gamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            guard let self else { return }
            self.lastInputSource = .gamepad
            if self.gamepadWasActive {
                self.onManualActivityChanged?(false)
            }
            self.gamepadWasActive = false
            self.onSmoothRecenter?()
        }

        // Seed the state once, but a centered controller won't claim ownership.
        handleStickState(gamepad)
    }

    private func handleStickState(_ gamepad: GCExtendedGamepad) {
        let settings = settingsProvider?() ?? .default
        let mapped = GamepadInputMapper.map(
            leftX: gamepad.leftThumbstick.xAxis.value,
            leftY: gamepad.leftThumbstick.yAxis.value,
            rightX: gamepad.rightThumbstick.xAxis.value,
            rightY: gamepad.rightThumbstick.yAxis.value,
            settings: settings
        )

        if mapped.active {
            if lastInputSource != .gamepad {
                lastInputSource = .gamepad
            }
            if !gamepadWasActive {
                onManualActivityChanged?(true)
            }
            gamepadWasActive = true
            onMappedInput?(mapped)
            return
        }

        if gamepadWasActive {
            // Only release the gimbal if gamepad still owns input. If the user
            // grabbed the touchscreen joystick, a later gamepad return-to-center
            // event must not cancel that touch gesture. Head-tracking activity
            // is nevertheless told that the physical stick returned to center.
            if lastInputSource == .gamepad {
                onMappedInput?(mapped)
            }
            gamepadWasActive = false
            onManualActivityChanged?(false)
        }
    }

    private func controllerDisconnected(_ controller: GCController) {
        guard activeController === controller else {
            refreshConnectedControllers()
            return
        }

        detachController(sendNeutralIfOwned: true)
        statusText = "手柄已断开"
        refreshConnectedControllers()
    }

    private func detachController(sendNeutralIfOwned: Bool) {
        if sendNeutralIfOwned, gamepadWasActive, lastInputSource == .gamepad {
            onMappedInput?(
                GamepadMappedInput(
                    normalizedX: 0,
                    normalizedY: 0,
                    pitch: JoystickMapper.neutral,
                    yaw: JoystickMapper.neutral,
                    active: false
                )
            )
        }
        if gamepadWasActive {
            onManualActivityChanged?(false)
        }
        gamepadWasActive = false

        if let gamepad = activeController?.extendedGamepad {
            gamepad.valueChangedHandler = nil
            gamepad.buttonA.pressedChangedHandler = nil
            gamepad.buttonB.pressedChangedHandler = nil
            gamepad.buttonX.pressedChangedHandler = nil
            gamepad.buttonY.pressedChangedHandler = nil
        }

        activeController = nil
        isConnected = false
        controllerName = "未连接手柄"
        controllerCategory = ""
    }

    private func publishControllerIdentity(_ controller: GCController) {
        controllerName = controller.vendorName ?? controller.productCategory
        controllerCategory = controller.productCategory
    }
}
