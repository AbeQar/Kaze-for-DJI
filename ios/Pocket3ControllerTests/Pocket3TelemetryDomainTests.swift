import XCTest
@testable import Pocket3Controller

final class Pocket3TelemetryDomainTests: XCTestCase {
    func testGimbalParserDecodesPositiveSignedAxesAndStatus() throws {
        let value = try XCTUnwrap(Pocket3TelemetryParser.gimbal(
            payload: Data([0x7B, 0x00, 0xC8, 0x01, 0x15, 0x03, 0x02, 0, 0, 0, 0x45])
        ))
        XCTAssertEqual(value.pitchDeg, 12.3)
        XCTAssertEqual(value.rollDeg, 45.6)
        XCTAssertEqual(value.yawDeg, 78.9)
        XCTAssertEqual(value.mode, 0x02)
        XCTAssertEqual(value.limitFlags, 0x45)
    }

    func testGimbalParserDecodesNegativeSignedAxes() throws {
        let value = try XCTUnwrap(Pocket3TelemetryParser.gimbal(
            payload: Data([0x85, 0xFF, 0x38, 0xFE, 0xEB, 0xFC])
        ))
        XCTAssertEqual(value.pitchDeg, -12.3)
        XCTAssertEqual(value.rollDeg, -45.6)
        XCTAssertEqual(value.yawDeg, -78.9)
        XCTAssertNil(value.mode)
        XCTAssertNil(value.limitFlags)
    }

    func testGimbalParserRejectsMalformedPayloads() {
        XCTAssertNil(Pocket3TelemetryParser.gimbal(payload: Data()))
        XCTAssertNil(Pocket3TelemetryParser.gimbal(payload: Data(repeating: 0, count: 5)))
    }

    func testYawReducerUnwrapsForwardCrossing() {
        var reducer = Pocket3YawReducer()
        XCTAssertEqual(reducer.reduce(wrapped(yaw: 179), receivedAtNs: 1).yawContinuousDeg, 179)
        XCTAssertEqual(reducer.reduce(wrapped(yaw: -179), receivedAtNs: 2).yawContinuousDeg, 181)
    }

    func testYawReducerUnwrapsReverseCrossing() {
        var reducer = Pocket3YawReducer()
        XCTAssertEqual(reducer.reduce(wrapped(yaw: -179), receivedAtNs: 1).yawContinuousDeg, -179)
        XCTAssertEqual(reducer.reduce(wrapped(yaw: 179), receivedAtNs: 2).yawContinuousDeg, -181)
    }

    func testYawReducerResetStartsFromNextWrappedSample() {
        var reducer = Pocket3YawReducer()
        _ = reducer.reduce(wrapped(yaw: 179), receivedAtNs: 1)
        XCTAssertEqual(reducer.reduce(wrapped(yaw: -179), receivedAtNs: 2).yawContinuousDeg, 181)
        reducer.reset()
        XCTAssertEqual(reducer.reduce(wrapped(yaw: -179), receivedAtNs: 3).yawContinuousDeg, -179)
    }

    func testCameraStatusTelemetryPreservesCurrentStatesAndFields() throws {
        var payload = Data(repeating: 0, count: 58)
        payload[0] = 0x81
        payload[4] = 0x01
        payload[5] = 0x00
        payload[6] = 0x00
        payload[7] = 0x02
        payload[9] = 0x00
        payload[10] = 0x00
        payload[11] = 0x01
        payload[17] = 0x1A
        payload[18] = 0x04
        payload[29] = 0x2A
        payload[57] = 0x01

        let recording = try XCTUnwrap(Pocket3TelemetryParser.cameraStatus(payload: payload))
        XCTAssertTrue(recording.recording)
        XCTAssertFalse(recording.transitioning)
        XCTAssertEqual(recording.fields?.storageTotalMiB, 131_072)
        XCTAssertEqual(recording.fields?.storageFreeMiB, 65_536)
        XCTAssertEqual(recording.fields?.remainingRecordSeconds, 1_050)
        XCTAssertEqual(recording.fields?.elapsedRecordSeconds, 42)

        XCTAssertEqual(Pocket3TelemetryParser.cameraStatus(payload: Data([0x01]))?.recording, false)
        XCTAssertEqual(Pocket3TelemetryParser.cameraStatus(payload: Data([0x41]))?.transitioning, true)
        XCTAssertEqual(Pocket3TelemetryParser.cameraStatus(payload: Data([0xC1]))?.recording, true)
        XCTAssertNil(Pocket3TelemetryParser.cameraStatus(payload: Data()))
    }

    func testBatteryTelemetryPreservesKnownAndUnknownStates() throws {
        var payload = Data(repeating: 0, count: 33)
        payload[20] = 92
        payload[32] = 0x01
        XCTAssertEqual(try XCTUnwrap(Pocket3TelemetryParser.battery(payload: payload)), .init(percent: 92, isCharging: true))
        payload[32] = 0x00
        XCTAssertEqual(try XCTUnwrap(Pocket3TelemetryParser.battery(payload: payload)), .init(percent: 92, isCharging: false))
        payload[32] = 0x7F
        XCTAssertNil(try XCTUnwrap(Pocket3TelemetryParser.battery(payload: payload)).isCharging)
        payload[20] = 101
        XCTAssertNil(Pocket3TelemetryParser.battery(payload: payload))
        XCTAssertNil(Pocket3TelemetryParser.battery(payload: Data(repeating: 0, count: 32)))
    }

    func testStorageTelemetryPreservesCurrentOffsetsAndUnknownBehavior() throws {
        var payload = Data(repeating: 0, count: 22)
        payload[2] = 1
        payload[8] = 2
        payload[12] = 1
        let storage = try XCTUnwrap(Pocket3TelemetryParser.storage(payload: payload))
        XCTAssertEqual(storage.storeCount, 1)
        XCTAssertEqual(storage.sdTotalMiB, 131_072)
        XCTAssertEqual(storage.sdFreeMiB, 65_536)
        XCTAssertNil(Pocket3TelemetryParser.storage(payload: Data(repeating: 0, count: 21)))
    }

    private func wrapped(yaw: Double) -> Pocket3WrappedGimbalTelemetry {
        Pocket3WrappedGimbalTelemetry(
            pitchDeg: 0,
            rollDeg: 0,
            yawDeg: yaw,
            mode: nil,
            limitFlags: nil
        )
    }
}
