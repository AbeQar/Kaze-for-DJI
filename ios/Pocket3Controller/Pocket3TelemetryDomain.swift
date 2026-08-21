import Foundation

struct GimbalTelemetry: Equatable {
    let pitchDeg: Double
    let rollDeg: Double
    let yawDeg: Double
    let yawContinuousDeg: Double
    let mode: Int?
    let limitFlags: Int?
    let receivedAtNs: UInt64

    var pitchAtLimit: Bool { limitFlags.map { ($0 & 0x01) != 0 } ?? false }
    var rollAtLimit: Bool { limitFlags.map { ($0 & 0x02) != 0 } ?? false }
    var yawAtLimit: Bool { limitFlags.map { ($0 & 0x04) != 0 } ?? false }
    var stuck: Bool { limitFlags.map { ($0 & 0x40) != 0 } ?? false }
}

struct Pocket3WrappedGimbalTelemetry: Equatable {
    let pitchDeg: Double
    let rollDeg: Double
    let yawDeg: Double
    let mode: Int?
    let limitFlags: Int?
}

struct Pocket3CameraStatusTelemetry: Equatable {
    let statusByte: UInt8
    let recording: Bool
    let transitioning: Bool
    let fields: Pocket3CameraStatus.StatusFields?
}

struct Pocket3BatteryStatusFields: Equatable {
    let percent: UInt8
    let isCharging: Bool?
}

enum Pocket3TelemetryParser {
    /// Decode unsolicited 04/05 telemetry without manufacturing values for short payloads.
    static func gimbal(payload: Data) -> Pocket3WrappedGimbalTelemetry? {
        guard payload.count >= 6 else { return nil }
        return Pocket3WrappedGimbalTelemetry(
            pitchDeg: Double(s16le(payload, 0)) / 10.0,
            rollDeg: Double(s16le(payload, 2)) / 10.0,
            yawDeg: Double(s16le(payload, 4)) / 10.0,
            mode: payload.count > 6 ? Int(payload[6]) : nil,
            limitFlags: payload.count > 10 ? Int(payload[10]) : nil
        )
    }

    /// Preserve the Stage-3 camera-status interpretation while presenting a typed inbound event.
    static func cameraStatus(payload: Data) -> Pocket3CameraStatusTelemetry? {
        guard let statusByte = payload.first else { return nil }
        return Pocket3CameraStatusTelemetry(
            statusByte: statusByte,
            recording: Pocket3CameraStatus.recordingActive(statusByte: statusByte),
            transitioning: Pocket3CameraStatus.recordingTransitioning(statusByte: statusByte),
            fields: Pocket3CameraStatus.statusFields(payload: payload)
        )
    }

    static func storage(payload: Data) -> Pocket3CameraStatus.StorageFields? {
        Pocket3CameraStatus.storageFields(payload: payload)
    }

    /// Hardware-confirmed unsolicited 0D/02 fields: byte 20 percent, byte 32 charging state.
    static func battery(payload: Data) -> Pocket3BatteryStatusFields? {
        guard payload.count >= 33 else { return nil }

        let percent = payload[20]
        guard percent <= 100 else { return nil }

        let isCharging: Bool?
        switch payload[32] {
        case 0x00:
            isCharging = false
        case 0x01:
            isCharging = true
        default:
            isCharging = nil
        }

        return Pocket3BatteryStatusFields(percent: percent, isCharging: isCharging)
    }

    private static func s16le(_ data: Data, _ offset: Int) -> Int16 {
        let value = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        return Int16(bitPattern: value)
    }
}

struct Pocket3YawReducer {
    private var lastWrappedYawDeg: Double?
    private var continuousYawDeg = 0.0

    mutating func reduce(
        _ telemetry: Pocket3WrappedGimbalTelemetry,
        receivedAtNs: UInt64
    ) -> GimbalTelemetry {
        if let lastWrappedYawDeg {
            continuousYawDeg += Self.wrappedAngleError(
                targetDeg: telemetry.yawDeg,
                currentDeg: lastWrappedYawDeg
            )
        } else {
            continuousYawDeg = telemetry.yawDeg
        }
        lastWrappedYawDeg = telemetry.yawDeg

        return GimbalTelemetry(
            pitchDeg: telemetry.pitchDeg,
            rollDeg: telemetry.rollDeg,
            yawDeg: telemetry.yawDeg,
            yawContinuousDeg: continuousYawDeg,
            mode: telemetry.mode,
            limitFlags: telemetry.limitFlags,
            receivedAtNs: receivedAtNs
        )
    }

    mutating func reset() {
        lastWrappedYawDeg = nil
        continuousYawDeg = 0
    }

    static func wrappedAngleError(targetDeg: Double, currentDeg: Double) -> Double {
        var delta = (targetDeg - currentDeg).truncatingRemainder(dividingBy: 360.0)
        if delta <= -180.0 { delta += 360.0 }
        if delta > 180.0 { delta -= 360.0 }
        return delta
    }
}
