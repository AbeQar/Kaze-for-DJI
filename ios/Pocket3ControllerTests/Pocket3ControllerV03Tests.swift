import XCTest
import Foundation
@testable import Pocket3Controller

final class Pocket3ControllerV03Tests: XCTestCase {
    func testCRCMatchesFrozenAndroidWakeFrame() {
        XCTAssertEqual(DjiCRC.crc8(Data([0x55, 0x0F, 0x04])), 0xA2)

        let withoutCRC = Data([
            0x55, 0x0F, 0x04, 0xA2,
            0x02, 0xF0,
            0x2B, 0x80,
            0x40, 0x00, 0x2B,
            0x04, 0x00
        ])
        XCTAssertEqual(DjiCRC.crc16(withoutCRC), 0x4024)
    }

    func testSessionWakeMatchesFrozenAndroidBytes() throws {
        let frame = Pocket3Commands.sessionPing(Pocket3Commands.sessionWake)
        XCTAssertEqual(frame.hexString, "550f04a202f02b8040002b04002440")

        let decoded = try DumlMessage(data: frame)
        XCTAssertEqual(decoded.target, 0xF002)
        XCTAssertEqual(decoded.id, 0x802B)
        XCTAssertEqual(decoded.flags, 0x40)
        XCTAssertEqual(decoded.cmdSet, 0x00)
        XCTAssertEqual(decoded.cmdId, 0x2B)
        XCTAssertEqual(decoded.payload, Data([0x04, 0x00]))
    }

    func testPairingFrameMatchesFrozenAndroidBytes() {
        XCTAssertEqual(
            Pocket3Commands.setPairingPin("osmo").hexString,
            "553304c202079280400745203238346165356238643736623333373561303461363431376164373162656133046f736d6fa0b4"
        )
    }

    func testUDPHeaderLayoutAndXor() {
        let header = DumlTransportHeader.encode(
            packetType: 0x05,
            payloadLength: 34,
            sessionId: 0x1234,
            sequence: 0x5678
        )
        XCTAssertEqual(header.hexString, "2a803412785605a7")
    }

    func testAckPayloadHasExactThreeWindows() {
        let ack = DumlAckWindow.encode(
            rxType2Sequence: 0x1111,
            rxType3Sequence: 0x2222,
            peerAckedTxSequence: 0x3333,
            lastTxSequence: 0x4444
        )
        XCTAssertEqual(ack.count, 26)
        XCTAssertEqual(
            ack.hexString,
            "1111111100000000222222220000000033334444000000000000"
        )
    }

    func testRoutingHeaderUsesActualPeerAck() {
        let header = DumlRoutingHeader.encode(
            sequence: 0x5678,
            peerAck: 0x1234,
            commandCounter: 0x9A
        )
        XCTAssertEqual(header.hexString, "34127856000000009a010000")
    }

    func testNeutralGimbalPayloadMatchesCapture() {
        XCTAssertEqual(
            Pocket3GimbalSession.gimbalPayload(pitch: 1024, yaw: 1024).hexString,
            "00040000000400802200"
        )
    }

    func testRecenterPayloadMatchesMimoCapture() {
        XCTAssertEqual(Pocket3GimbalSession.recenterPayload.hexString, "fe08")
    }

    func testLinearJoystickFullRightMatchesAndroidV0143() {
        let value = JoystickMapper.map(normalizedX: 1.0, normalizedY: 0.0, mode: .linear)
        XCTAssertEqual(value.pitch, 1024)
        XCTAssertEqual(value.yaw, 1354)
    }

    func testLinearJoystickFullUpMatchesAndroidV0143() {
        let value = JoystickMapper.map(normalizedX: 0.0, normalizedY: -1.0, mode: .linear)
        XCTAssertEqual(value.pitch, 1354)
        XCTAssertEqual(value.yaw, 1024)
    }

    func testProgressiveDeadZoneReturnsNeutral() {
        let value = JoystickMapper.map(normalizedX: 0.05, normalizedY: 0.0, mode: .progressive)
        XCTAssertEqual(value.pitch, 1024)
        XCTAssertEqual(value.yaw, 1024)
    }

    func testProgressiveQuarterHalfThreeQuarterAndFull() {
        XCTAssertEqual(
            JoystickMapper.map(normalizedX: 0.25, normalizedY: 0.0, mode: .progressive).yaw,
            1134
        )
        XCTAssertEqual(
            JoystickMapper.map(normalizedX: 0.50, normalizedY: 0.0, mode: .progressive).yaw,
            1304
        )
        XCTAssertEqual(
            JoystickMapper.map(normalizedX: 0.75, normalizedY: 0.0, mode: .progressive).yaw,
            1464
        )
        XCTAssertEqual(
            JoystickMapper.map(normalizedX: 1.00, normalizedY: 0.0, mode: .progressive).yaw,
            1574
        )
    }

    func testWrappedYawCrossingPreservesContinuousDirection() {
        XCTAssertEqual(
            Pocket3GimbalSession.wrappedAngleError(targetDeg: -179.0, currentDeg: 179.0),
            2.0,
            accuracy: 0.0001
        )
    }
}
