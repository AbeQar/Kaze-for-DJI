import Foundation
import Combine

enum GamepadStickLayout: String, CaseIterable, Identifiable {
    case leftCombined
    case rightCombined
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftCombined: return "Left Stick"
        case .rightCombined: return "Right Stick"
        case .split: return "Split Sticks"
        }
    }

    var subtitle: String {
        switch self {
        case .leftCombined:
            return "Left stick controls pitch + yaw"
        case .rightCombined:
            return "Right stick controls pitch + yaw"
        case .split:
            return "Left up/down = pitch, right left/right = yaw"
        }
    }
}

struct GamepadControlSettings: Equatable {
    var stickLayout: GamepadStickLayout
    var invertPitch: Bool
    var invertYaw: Bool
    var responseMode: JoystickResponseMode

    static let `default` = GamepadControlSettings(
        stickLayout: .leftCombined,
        invertPitch: false,
        invertYaw: false,
        responseMode: .linear
    )
}

final class ControllerPreferences: ObservableObject {
    private enum Key {
        static let stickLayout = "controller.stickLayout"
        static let invertPitch = "controller.invertPitch"
        static let invertYaw = "controller.invertYaw"
        static let responseMode = "controller.responseMode"
    }

    private let defaults: UserDefaults

    @Published var stickLayout: GamepadStickLayout {
        didSet { defaults.set(stickLayout.rawValue, forKey: Key.stickLayout) }
    }

    @Published var invertPitch: Bool {
        didSet { defaults.set(invertPitch, forKey: Key.invertPitch) }
    }

    @Published var invertYaw: Bool {
        didSet { defaults.set(invertYaw, forKey: Key.invertYaw) }
    }

    @Published var responseMode: JoystickResponseMode {
        didSet { defaults.set(responseMode.rawValue, forKey: Key.responseMode) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        stickLayout = GamepadStickLayout(
            rawValue: defaults.string(forKey: Key.stickLayout) ?? ""
        ) ?? .leftCombined

        invertPitch = defaults.object(forKey: Key.invertPitch) == nil
            ? false
            : defaults.bool(forKey: Key.invertPitch)

        invertYaw = defaults.object(forKey: Key.invertYaw) == nil
            ? false
            : defaults.bool(forKey: Key.invertYaw)

        responseMode = JoystickResponseMode(
            rawValue: defaults.string(forKey: Key.responseMode) ?? ""
        ) ?? .linear
    }

    var snapshot: GamepadControlSettings {
        GamepadControlSettings(
            stickLayout: stickLayout,
            invertPitch: invertPitch,
            invertYaw: invertYaw,
            responseMode: responseMode
        )
    }
}
