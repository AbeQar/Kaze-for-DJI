import XCTest
import Foundation
import NetworkExtension
@testable import Pocket3Controller

final class Pocket3ControllerV04Tests: XCTestCase {
    func testForegroundRecoveryAcceptsFreshTelemetryWithoutHeartbeat() {
        XCTAssertTrue(Pocket3GimbalSession.shouldAcceptPreservedSession(
            telemetryAdvanced: true,
            heartbeatAdvanced: false
        ))
    }

    func testForegroundRecoveryRequiresFreshCameraDuml() {
        XCTAssertFalse(Pocket3GimbalSession.shouldAcceptPreservedSession(
            telemetryAdvanced: false,
            heartbeatAdvanced: false
        ))
    }

    func testLinearGamepadLeftStickFullRight() {
        let settings = GamepadControlSettings(
            stickLayout: .leftCombined,
            invertPitch: false,
            invertYaw: false,
            responseMode: .linear
        )
        let value = GamepadInputMapper.map(
            leftX: 1, leftY: 0,
            rightX: 0, rightY: 0,
            settings: settings
        )
        XCTAssertTrue(value.active)
        XCTAssertEqual(value.pitch, 1024)
        XCTAssertEqual(value.yaw, 1354)
    }

    func testLinearGamepadLeftStickFullUp() {
        let settings = GamepadControlSettings(
            stickLayout: .leftCombined,
            invertPitch: false,
            invertYaw: false,
            responseMode: .linear
        )
        let value = GamepadInputMapper.map(
            leftX: 0, leftY: 1,
            rightX: 0, rightY: 0,
            settings: settings
        )
        XCTAssertEqual(value.pitch, 1354)
        XCTAssertEqual(value.yaw, 1024)
    }

    func testRightStickCombinedIgnoresLeftStick() {
        let settings = GamepadControlSettings(
            stickLayout: .rightCombined,
            invertPitch: false,
            invertYaw: false,
            responseMode: .linear
        )
        let value = GamepadInputMapper.map(
            leftX: 1, leftY: 1,
            rightX: -1, rightY: -1,
            settings: settings
        )
        XCTAssertEqual(value.pitch, 694)
        XCTAssertEqual(value.yaw, 694)
    }

    func testSplitUsesLeftPitchAndRightYaw() {
        let settings = GamepadControlSettings(
            stickLayout: .split,
            invertPitch: false,
            invertYaw: false,
            responseMode: .linear
        )
        let value = GamepadInputMapper.map(
            leftX: -1, leftY: 1,
            rightX: 1, rightY: -1,
            settings: settings
        )
        XCTAssertEqual(value.pitch, 1354)
        XCTAssertEqual(value.yaw, 1354)
    }

    func testInvertPitchOnly() {
        let settings = GamepadControlSettings(
            stickLayout: .leftCombined,
            invertPitch: true,
            invertYaw: false,
            responseMode: .linear
        )
        let value = GamepadInputMapper.map(
            leftX: 0, leftY: 1,
            rightX: 0, rightY: 0,
            settings: settings
        )
        XCTAssertEqual(value.pitch, 694)
        XCTAssertEqual(value.yaw, 1024)
    }

    func testInvertYawOnly() {
        let settings = GamepadControlSettings(
            stickLayout: .leftCombined,
            invertPitch: false,
            invertYaw: true,
            responseMode: .linear
        )
        let value = GamepadInputMapper.map(
            leftX: 1, leftY: 0,
            rightX: 0, rightY: 0,
            settings: settings
        )
        XCTAssertEqual(value.pitch, 1024)
        XCTAssertEqual(value.yaw, 694)
    }

    func testGamepadDeadzoneReturnsNeutralAndInactive() {
        let settings = GamepadControlSettings.default
        let value = GamepadInputMapper.map(
            leftX: 0.03, leftY: 0.02,
            rightX: 0, rightY: 0,
            settings: settings
        )
        XCTAssertFalse(value.active)
        XCTAssertEqual(value.pitch, 1024)
        XCTAssertEqual(value.yaw, 1024)
    }

    func testGamepadMimoUsesSameQuarterScaleAsTouch() {
        let settings = GamepadControlSettings(
            stickLayout: .leftCombined,
            invertPitch: false,
            invertYaw: false,
            responseMode: .progressive
        )
        let value = GamepadInputMapper.map(
            leftX: 0.25, leftY: 0,
            rightX: 0, rightY: 0,
            settings: settings
        )
        XCTAssertEqual(value.yaw, 1134)
    }

    // Regression vectors preserved from v0.3.1.
    func testTransportHeaderRegression() {
        XCTAssertEqual(
            DumlTransportHeader.encode(packetType: 0x05, payloadLength: 34, sessionId: 0x1234, sequence: 0x5678).hexString,
            "2a803412785605a7"
        )
    }

    func testTransportSessionIdIsDecodedFromHeader() {
        let datagram = DumlTransportHeader.encode(
            packetType: 0x00,
            payloadLength: 0,
            sessionId: 0xB8D0,
            sequence: 0
        )

        XCTAssertEqual(DumlTransportHeader.sessionId(in: datagram), 0xB8D0)
        XCTAssertTrue(DumlTransportHeader.belongsToSession(datagram, sessionId: 0xB8D0))
        XCTAssertFalse(DumlTransportHeader.belongsToSession(datagram, sessionId: 0xBE8A))
        XCTAssertNil(DumlTransportHeader.sessionId(in: Data([0x08, 0x80, 0xD0])))
    }

    func testHotspotAlreadyAssociatedErrorClassification() {
        let alreadyAssociated = NSError(
            domain: NEHotspotConfigurationErrorDomain,
            code: NEHotspotConfigurationError.alreadyAssociated.rawValue
        )
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: 1)

        XCTAssertTrue(Pocket3WiFiManager.isAlreadyAssociated(alreadyAssociated))
        XCTAssertFalse(Pocket3WiFiManager.isAlreadyAssociated(unrelated))
    }

    func testAckRegression() {
        XCTAssertEqual(
            DumlAckWindow.encode(
                rxType2Sequence: 0x1111,
                rxType3Sequence: 0x2222,
                peerAckedTxSequence: 0x3333,
                lastTxSequence: 0x4444
            ).hexString,
            "1111111100000000222222220000000033334444000000000000"
        )
    }

    func testNeutralGimbalRegression() {
        XCTAssertEqual(
            Pocket3GimbalSession.gimbalPayload(pitch: 1024, yaw: 1024).hexString,
            "00040000000400802200"
        )
    }

    func testRecenterRegression() {
        XCTAssertEqual(Pocket3GimbalSession.recenterPayload.hexString, "fe08")
    }

    func testGimbalLockAndFollowPayloadRegression() {
        XCTAssertEqual(Pocket3GimbalSession.gimbalLockPayload.hexString, "0000")
        XCTAssertEqual(Pocket3GimbalSession.gimbalFollowPayload.hexString, "0100")
    }

    func testCameraRecordingStateBitRegression() {
        XCTAssertFalse(Pocket3CameraStatus.recordingActive(statusByte: 0x01))
        XCTAssertFalse(Pocket3CameraStatus.recordingActive(statusByte: 0x41))
        XCTAssertTrue(Pocket3CameraStatus.recordingActive(statusByte: 0xC1))
        XCTAssertTrue(Pocket3CameraStatus.recordingActive(statusByte: 0x81))
    }

    func testCameraRecordCommandPayloadRegression() {
        XCTAssertEqual(Pocket3GimbalSession.cameraRecordStartPayload.hexString, "01")
        XCTAssertEqual(Pocket3GimbalSession.cameraRecordStopPayload.hexString, "00")
    }

    func testCameraRecordingTransitionBitRegression() {
        XCTAssertFalse(Pocket3CameraStatus.recordingTransitioning(statusByte: 0x01))
        XCTAssertTrue(Pocket3CameraStatus.recordingTransitioning(statusByte: 0x41))
        XCTAssertTrue(Pocket3CameraStatus.recordingTransitioning(statusByte: 0xC1))
        XCTAssertFalse(Pocket3CameraStatus.recordingTransitioning(statusByte: 0x81))
    }

    func testCameraRecordRequestResolutionRegression() {
        XCTAssertFalse(Pocket3CameraStatus.recordRequestResolved(targetRecording: true, statusByte: 0x01))
        XCTAssertTrue(Pocket3CameraStatus.recordRequestResolved(targetRecording: true, statusByte: 0x41))
        XCTAssertTrue(Pocket3CameraStatus.recordRequestResolved(targetRecording: true, statusByte: 0x81))

        XCTAssertFalse(Pocket3CameraStatus.recordRequestResolved(targetRecording: false, statusByte: 0x81))
        XCTAssertTrue(Pocket3CameraStatus.recordRequestResolved(targetRecording: false, statusByte: 0xC1))
        XCTAssertTrue(Pocket3CameraStatus.recordRequestResolved(targetRecording: false, statusByte: 0x01))
    }

    func testCameraStatusFieldDecodeRegression() {
        var payload = Data(repeating: 0, count: 60)
        payload[4] = 0x01
        payload[5] = 0x78
        payload[6] = 0x56
        payload[7] = 0x34
        payload[8] = 0x12
        payload[9] = 0xEF
        payload[10] = 0xCD
        payload[11] = 0xAB
        payload[12] = 0x00
        payload[17] = 0x1A
        payload[18] = 0x04
        payload[29] = 0x2A
        payload[30] = 0x00
        payload[57] = 0x01

        let fields = Pocket3CameraStatus.statusFields(payload: payload)
        XCTAssertEqual(fields?.storageTotalMiB, 0x12345678)
        XCTAssertEqual(fields?.storageFreeMiB, 0x00ABCDEF)
        XCTAssertEqual(fields?.remainingRecordSeconds, 1050)
        XCTAssertEqual(fields?.elapsedRecordSeconds, 42)
        XCTAssertEqual(fields?.shootingMode, 0x01)
        XCTAssertEqual(fields?.videoLike, true)
    }

    func testCameraStorageFieldDecodeRegression() {
        var payload = Data(repeating: 0, count: 22)
        payload[2] = 0x01
        payload[6] = 0x00
        payload[7] = 0x00
        payload[8] = 0x02
        payload[9] = 0x00
        payload[10] = 0x00
        payload[11] = 0x00
        payload[12] = 0x01
        payload[13] = 0x00

        let fields = Pocket3TelemetryParser.storage(payload: payload)
        XCTAssertEqual(fields?.storeCount, 1)
        XCTAssertEqual(fields?.sdTotalMiB, 131_072)
        XCTAssertEqual(fields?.sdFreeMiB, 65_536)
    }

    func testScanFramesExposesRoutingMetadata() {
        let message = DumlMessage(
            target: 0x0702,
            id: 0x1234,
            type: UInt32(0x40) | (UInt32(0x0D) << 8) | (UInt32(0x02) << 16),
            payload: Data([0x61, 0x62])
        ).encode()

        let frames = DumlFrameScanner.scan(message)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.route, 0x0702)
        XCTAssertEqual(frames.first?.id, 0x1234)
        XCTAssertEqual(frames.first?.flags, 0x40)
        XCTAssertEqual(frames.first?.set, 0x0D)
        XCTAssertEqual(frames.first?.cmd, 0x02)
        XCTAssertEqual(frames.first?.payload, Data([0x61, 0x62]))
    }

    func testBatteryStatusDecodeNotCharging92Percent() throws {
        // Physical Pocket 3 showed 92% and no charging indicator.
        let payload = Data(hexForBatteryTest: "006C1000000AFEFFFF00000000000000009001005C00000000000020040000000001")
        let fields = try XCTUnwrap(Pocket3TelemetryParser.battery(payload: payload))

        XCTAssertEqual(fields.percent, 92)
        XCTAssertEqual(fields.isCharging, false)
    }

    func testBatteryStatusDecodeCharging92Percent() throws {
        // Physical Pocket 3 showed 92% with its charging indicator active.
        let payload = Data(hexForBatteryTest: "00811000007500000000000000000000009001005C00000000000020040000000101")
        let fields = try XCTUnwrap(Pocket3TelemetryParser.battery(payload: payload))

        XCTAssertEqual(fields.percent, 92)
        XCTAssertEqual(fields.isCharging, true)
    }

    func testBatteryStatusDecodePreservesPercentForUnknownChargeFlag() throws {
        var payload = Data(hexForBatteryTest: "006C1000000AFEFFFF00000000000000009001005C00000000000020040000000001")
        payload[32] = 0x7F
        let fields = try XCTUnwrap(Pocket3TelemetryParser.battery(payload: payload))

        XCTAssertEqual(fields.percent, 92)
        XCTAssertNil(fields.isCharging)
    }

    func testBatteryStatusDecodeRejectsInvalidPayloads() {
        XCTAssertNil(Pocket3TelemetryParser.battery(payload: Data(repeating: 0, count: 32)))

        var impossiblePercent = Data(repeating: 0, count: 34)
        impossiblePercent[20] = 101
        XCTAssertNil(Pocket3TelemetryParser.battery(payload: impossiblePercent))
    }

    func testCameraRecordingStatusDescriptions() {
        XCTAssertEqual(Pocket3CameraStatus.recordingDescription(statusByte: 0x01), "IDLE")
        XCTAssertEqual(Pocket3CameraStatus.recordingDescription(statusByte: 0x41), "TRANSITION")
        XCTAssertEqual(Pocket3CameraStatus.recordingDescription(statusByte: 0xC1), "TRANSITION+REC")
        XCTAssertEqual(Pocket3CameraStatus.recordingDescription(statusByte: 0x81), "RECORDING")
        XCTAssertEqual(Pocket3CameraStatus.recordingDescription(statusByte: 0x55), "UNKNOWN")
    }
}

private extension Data {
    init(hexForBatteryTest hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        precondition(clean.count % 2 == 0)

        var bytes: [UInt8] = []
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            bytes.append(UInt8(clean[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
