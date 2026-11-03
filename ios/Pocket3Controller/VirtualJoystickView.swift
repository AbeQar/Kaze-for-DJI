import SwiftUI
import UIKit

// Exact response profiles from frozen Android Pocket3GimbalTest v0.14.3.
enum JoystickResponseMode: String, CaseIterable {
    case linear
    case progressive

    var buttonTitle: String {
        switch self {
        case .linear: return "摇杆：线性"
        case .progressive: return "摇杆：渐进"
        }
    }

    var statusText: String {
        switch self {
        case .linear: return "线性摇杆响应"
        case .progressive: return "渐进摇杆响应"
        }
    }

    var logText: String {
        switch self {
        case .linear:
            return "Joystick response -> LINEAR (v0.13 behavior, +/-330)"
        case .progressive:
            return "Joystick response -> PROGRESSIVE (more aggressive midrange, soft center, same full +/-550)"
        }
    }
}

enum JoystickMapper {
    static let neutral = 1024
    static let linearMaxOffset = 330
    static let mimoMaxOffset = 550
    static let deadZone: CGFloat = 0.06

    static func map(normalizedX rawX: CGFloat, normalizedY rawY: CGFloat, mode: JoystickResponseMode) -> (pitch: Int, yaw: Int) {
        var nx = rawX
        var ny = rawY
        let rawRadius = sqrt(nx * nx + ny * ny)
        let r = min(rawRadius, 1.0)

        if r < deadZone {
            nx = 0
            ny = 0
        }

        let outX: CGFloat
        let outY: CGFloat

        switch mode {
        case .linear:
            outX = nx * CGFloat(linearMaxOffset)
            outY = ny * CGFloat(linearMaxOffset)

        case .progressive:
            guard r >= deadZone, r > 0 else {
                return (neutral, neutral)
            }

            let r2 = r * r
            let r3 = r2 * r
            let r4 = r3 * r
            let shaped =
                0.35757576 * r +
                2.2909091 * r2 -
                2.2303030 * r3 +
                0.58181816 * r4

            let curvedMagnitude = CGFloat(mimoMaxOffset) * min(max(shaped, 0), 1)
            let ux = nx / r
            let uy = ny / r
            outX = ux * curvedMagnitude
            outY = uy * curvedMagnitude
        }

        let yaw = Int((CGFloat(neutral) + outX).rounded())
            .clamped(to: (neutral - mimoMaxOffset)...(neutral + mimoMaxOffset))

        // iOS/UIKit Y grows downward; DJI pitch >1024 is UP.
        let pitch = Int((CGFloat(neutral) - outY).rounded())
            .clamped(to: (neutral - mimoMaxOffset)...(neutral + mimoMaxOffset))

        return (pitch, yaw)
    }
}

struct VirtualJoystickView: UIViewRepresentable {
    var isEnabled: Bool
    var responseMode: JoystickResponseMode
    var onJoystick: (_ pitch: Int, _ yaw: Int, _ active: Bool) -> Void

    func makeUIView(context: Context) -> JoystickUIView {
        let view = JoystickUIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        view.onJoystick = onJoystick
        view.responseMode = responseMode
        view.setEnabled(isEnabled)
        return view
    }

    func updateUIView(_ uiView: JoystickUIView, context: Context) {
        uiView.onJoystick = onJoystick

        // Never call back into SwiftUI synchronously from updateUIView().
        // v0.3 did that while toggling response mode / disconnecting and iOS
        // correctly warned: "Modifying state during view update".
        uiView.setEnabled(isEnabled)
        uiView.setResponseMode(responseMode)
    }
}

final class JoystickUIView: UIView {
    var onJoystick: ((_ pitch: Int, _ yaw: Int, _ active: Bool) -> Void)?

    private(set) var joystickEnabled = false
    var responseMode: JoystickResponseMode = .linear

    private let ringLayer = CAShapeLayer()
    private let crossLayer = CAShapeLayer()
    private let knobLayer = CAShapeLayer()

    private var knobCenter = CGPoint.zero
    private var touchActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    private func setupLayers() {
        isOpaque = false
        isUserInteractionEnabled = false
        alpha = 0.38

        ringLayer.fillColor = UIColor.clear.cgColor
        ringLayer.strokeColor = UIColor.label.withAlphaComponent(0.70).cgColor
        ringLayer.lineWidth = 5

        crossLayer.fillColor = UIColor.clear.cgColor
        crossLayer.strokeColor = UIColor.label.withAlphaComponent(0.35).cgColor
        crossLayer.lineWidth = 2

        knobLayer.fillColor = UIColor.label.withAlphaComponent(0.70).cgColor
        knobLayer.strokeColor = UIColor.clear.cgColor

        layer.addSublayer(ringLayer)
        layer.addSublayer(crossLayer)
        layer.addSublayer(knobLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let cx = bounds.midX
        let cy = bounds.midY
        let radius = min(bounds.width, bounds.height) * 0.39
        let knobRadius = radius * 0.25

        let ringRect = CGRect(
            x: cx - radius,
            y: cy - radius,
            width: radius * 2,
            height: radius * 2
        )
        ringLayer.path = UIBezierPath(ovalIn: ringRect).cgPath

        let crossPath = UIBezierPath()
        crossPath.move(to: CGPoint(x: cx - radius, y: cy))
        crossPath.addLine(to: CGPoint(x: cx + radius, y: cy))
        crossPath.move(to: CGPoint(x: cx, y: cy - radius))
        crossPath.addLine(to: CGPoint(x: cx, y: cy + radius))
        crossLayer.path = crossPath.cgPath

        if knobCenter == .zero || !touchActive {
            knobCenter = CGPoint(x: cx, y: cy)
        }

        knobLayer.path = UIBezierPath(
            ovalIn: CGRect(
                x: knobCenter.x - knobRadius,
                y: knobCenter.y - knobRadius,
                width: knobRadius * 2,
                height: knobRadius * 2
            )
        ).cgPath
    }

    func setEnabled(_ enabled: Bool) {
        guard joystickEnabled != enabled else { return }
        joystickEnabled = enabled
        isUserInteractionEnabled = enabled
        alpha = enabled ? 1.0 : 0.38

        if !enabled {
            touchActive = false
            centerAndRelease(notify: false)
        }
    }

    func setResponseMode(_ mode: JoystickResponseMode) {
        guard responseMode != mode else { return }
        responseMode = mode

        if !touchActive {
            centerAndRelease(notify: false)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard joystickEnabled, let touch = touches.first else { return }
        touchActive = true
        updateFromTouch(touch.location(in: self))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard joystickEnabled, let touch = touches.first else { return }
        touchActive = true
        updateFromTouch(touch.location(in: self))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouch()
    }

    private func finishTouch() {
        guard touchActive else { return }
        touchActive = false
        centerAndRelease(notify: true)
    }

    private func updateFromTouch(_ point: CGPoint) {
        let cx = bounds.midX
        let cy = bounds.midY
        let radius = min(bounds.width, bounds.height) * 0.39
        guard radius > 0 else { return }

        var dx = point.x - cx
        var dy = point.y - cy
        let distance = sqrt(dx * dx + dy * dy)

        if distance > radius, distance > 0 {
            let scale = radius / distance
            dx *= scale
            dy *= scale
        }

        knobCenter = CGPoint(x: cx + dx, y: cy + dy)
        setNeedsLayout()

        let nx = dx / radius
        let ny = dy / radius
        let mapped = JoystickMapper.map(normalizedX: nx, normalizedY: ny, mode: responseMode)
        onJoystick?(mapped.pitch, mapped.yaw, true)
    }

    private func centerAndRelease(notify: Bool) {
        knobCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        setNeedsLayout()
        if notify {
            onJoystick?(JoystickMapper.neutral, JoystickMapper.neutral, false)
        }
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
