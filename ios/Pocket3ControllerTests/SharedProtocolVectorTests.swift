import Foundation
import XCTest
@testable import Pocket3Controller

final class SharedProtocolVectorTests: XCTestCase {
    func testSharedCRCVectors() throws {
        let vectors = try SharedProtocolVectorLoader.load(category: "crc", file: "crc.json")

        for vector in vectors {
            switch vector.operation {
            case "crc8.compute":
                let data = try data(fromHex: try vector.inputString("dataHex"))
                let expected = try UInt8(hexValue(try vector.expectedString("crcHex")))
                XCTAssertEqual(DjiCRC.crc8(data), expected, vector.id)

            case "crc16.compute":
                let data = try data(fromHex: try vector.inputString("dataHex"))
                let expected = try UInt16(hexValue(try vector.expectedString("crcHex")))
                XCTAssertEqual(DjiCRC.crc16(data), expected, vector.id)

            case "duml.rejectCorruptedFrame":
                let frame = try data(fromHex: try vector.inputString("frameHex"))
                XCTAssertFalse(try vector.expectedBool("valid"), vector.id)
                XCTAssertEqual(try vector.expectedString("errorCategory"), "crc16-mismatch", vector.id)
                XCTAssertThrowsError(try DumlMessage(data: frame), vector.id) { error in
                    guard let dumlError = error as? DumlError else {
                        return XCTFail("\(vector.id): unexpected error type \(error)")
                    }
                    guard case .badCRC = dumlError else {
                        return XCTFail("\(vector.id): expected CRC-16 rejection, got \(dumlError)")
                    }
                }

            default:
                XCTFail("\(vector.id): unsupported CRC operation \(vector.operation)")
            }
        }
    }

    func testSharedTransportVectors() throws {
        let vectors = try SharedProtocolVectorLoader.load(category: "transport", file: "transport.json")

        for vector in vectors {
            switch vector.operation {
            case "duml.encode":
                let flags = try hexValue(vector.inputString("flagsHex"))
                let commandSet = try hexValue(vector.inputString("commandSetHex"))
                let commandId = try hexValue(vector.inputString("commandIdHex"))
                let type = UInt32(flags) | (UInt32(commandSet) << 8) | (UInt32(commandId) << 16)
                let message = DumlMessage(
                    target: UInt16(try hexValue(vector.inputString("targetHex"))),
                    id: UInt16(try hexValue(vector.inputString("idHex"))),
                    type: type,
                    payload: try data(fromHex: vector.inputString("payloadHex"))
                )
                XCTAssertEqual(
                    hexString(message.encode()),
                    try vector.expectedString("frameHex"),
                    vector.id
                )

            case "duml.decode":
                let message = try DumlMessage(data: data(fromHex: vector.inputString("frameHex")))
                XCTAssertEqual(message.target, UInt16(try hexValue(vector.expectedString("targetHex"))), vector.id)
                XCTAssertEqual(message.id, UInt16(try hexValue(vector.expectedString("idHex"))), vector.id)
                XCTAssertEqual(message.flags, UInt8(try hexValue(vector.expectedString("flagsHex"))), vector.id)
                XCTAssertEqual(message.cmdSet, UInt8(try hexValue(vector.expectedString("commandSetHex"))), vector.id)
                XCTAssertEqual(message.cmdId, UInt8(try hexValue(vector.expectedString("commandIdHex"))), vector.id)
                XCTAssertEqual(hexString(message.payload), try vector.expectedString("payloadHex"), vector.id)

            case "transport.udpHeader":
                let header = DumlTransportHeader.encode(
                    packetType: UInt8(try hexValue(vector.inputString("packetTypeHex"))),
                    payloadLength: try vector.inputInt("payloadLength"),
                    sessionId: try hexValue(vector.inputString("sessionIdHex")),
                    sequence: try hexValue(vector.inputString("sequenceHex"))
                )
                XCTAssertEqual(hexString(header), try vector.expectedString("headerHex"), vector.id)
                let fields = try XCTUnwrap(DumlTransportHeader.decode(header), vector.id)
                XCTAssertEqual(fields.totalLength, header.count + (try vector.inputInt("payloadLength")), vector.id)
                XCTAssertEqual(fields.sessionId, try hexValue(vector.inputString("sessionIdHex")), vector.id)
                XCTAssertEqual(fields.sequence, try hexValue(vector.inputString("sequenceHex")), vector.id)
                XCTAssertEqual(fields.packetType, UInt8(try hexValue(vector.inputString("packetTypeHex"))), vector.id)

            case "transport.ackPayload":
                let payload = DumlAckWindow.encode(
                    rxType2Sequence: try hexValue(vector.inputString("rxType2SequenceHex")),
                    rxType3Sequence: try hexValue(vector.inputString("rxType3SequenceHex")),
                    peerAckedTxSequence: try hexValue(vector.inputString("peerAckedTxSequenceHex")),
                    lastTxSequence: try hexValue(vector.inputString("lastTxSequenceHex"))
                )
                XCTAssertEqual(hexString(payload), try vector.expectedString("payloadHex"), vector.id)

            case "transport.routingHeader":
                XCTAssertFalse(try vector.inputBool("drone"), "\(vector.id): iOS vector is the camera routing variant")
                let header = DumlRoutingHeader.encode(
                    sequence: try hexValue(vector.inputString("sequenceHex")),
                    peerAck: try hexValue(vector.inputString("peerAckHex")),
                    commandCounter: try hexValue(vector.inputString("commandCounterHex"))
                )
                XCTAssertEqual(hexString(header), try vector.expectedString("headerHex"), vector.id)
                let fields = try XCTUnwrap(DumlRoutingHeader.decode(header), vector.id)
                XCTAssertEqual(fields.sequence, try hexValue(vector.inputString("sequenceHex")), vector.id)
                XCTAssertEqual(fields.peerAck, try hexValue(vector.inputString("peerAckHex")), vector.id)
                XCTAssertEqual(fields.commandCounter, try hexValue(vector.inputString("commandCounterHex")), vector.id)
                XCTAssertEqual(fields.routingClass, 0x00, vector.id)

            default:
                XCTFail("\(vector.id): unsupported transport operation \(vector.operation)")
            }
        }
    }

    func testSharedFrameScannerValidation() throws {
        let transportVectors = try SharedProtocolVectorLoader.load(category: "transport", file: "transport.json")
        let decodeVector = try XCTUnwrap(
            transportVectors.first { $0.operation == "duml.decode" },
            "Canonical DUML decode vector is required"
        )
        let validFrame = try data(fromHex: decodeVector.inputString("frameHex"))

        let scanned = DumlFrameScanner.scan(validFrame)
        XCTAssertEqual(scanned.count, 1, decodeVector.id)
        XCTAssertEqual(scanned.first?.set, UInt8(try hexValue(decodeVector.expectedString("commandSetHex"))), decodeVector.id)
        XCTAssertEqual(scanned.first?.cmd, UInt8(try hexValue(decodeVector.expectedString("commandIdHex"))), decodeVector.id)
        XCTAssertEqual(scanned.first?.payload, try data(fromHex: decodeVector.expectedString("payloadHex")), decodeVector.id)

        let truncated = Data(validFrame.dropLast())
        XCTAssertTrue(DumlFrameScanner.scan(truncated).isEmpty, "Truncated frame must be rejected")

        let crcVectors = try SharedProtocolVectorLoader.load(category: "crc", file: "crc.json")
        let corruptedVector = try XCTUnwrap(
            crcVectors.first { $0.operation == "duml.rejectCorruptedFrame" },
            "Canonical corrupted DUML vector is required"
        )
        let corrupted = try data(fromHex: corruptedVector.inputString("frameHex"))
        XCTAssertTrue(DumlFrameScanner.scan(corrupted).isEmpty, corruptedVector.id)

        let outer = DumlMessage(
            target: 0x0702,
            id: 0x1234,
            type: UInt32(0x40) | (UInt32(0x51) << 8) | (UInt32(0x01) << 16),
            payload: validFrame
        ).encode()
        let nested = DumlFrameScanner.scan(outer)
        XCTAssertEqual(nested.count, 2, "Scanner must preserve byte-wise nested DUML discovery")
        XCTAssertTrue(nested.contains { $0.set == scanned[0].set && $0.cmd == scanned[0].cmd && $0.payload == scanned[0].payload })
    }

    func testSharedGimbalVectors() throws {
        let vectors = try SharedProtocolVectorLoader.load(category: "gimbal", file: "gimbal.json")

        for vector in vectors {
            XCTAssertEqual(try vector.expectedString("commandSetHex"), "04", vector.id)

            switch vector.operation {
            case "gimbal.velocity":
                XCTAssertEqual(try vector.expectedString("commandIdHex"), "01", vector.id)
                let payload = Pocket3GimbalSession.gimbalPayload(
                    pitch: try vector.inputInt("pitchCommand"),
                    yaw: try vector.inputInt("yawCommand")
                )
                XCTAssertEqual(hexString(payload), try vector.expectedString("payloadHex"), vector.id)

            case "gimbal.recenter":
                XCTAssertEqual(try vector.expectedString("commandIdHex"), "4C", vector.id)
                XCTAssertEqual(
                    hexString(Pocket3GimbalSession.recenterPayload),
                    try vector.expectedString("payloadHex"),
                    vector.id
                )

            default:
                XCTFail("\(vector.id): unsupported gimbal operation \(vector.operation)")
            }
        }
    }

    func testSharedCameraVectors() throws {
        let vectors = try SharedProtocolVectorLoader.load(category: "camera", file: "camera.json")

        for vector in vectors {
            let command: Pocket3CameraCommand
            switch vector.operation {
            case "camera.setManualIso":
                let iso: Pocket3CameraSettings.ManualISO
                switch try vector.inputString("iso") {
                case "AUTO": iso = .auto
                case "100": iso = .iso100
                case "6400": iso = .iso6400
                case let value:
                    return XCTFail("\(vector.id): unsupported manual ISO vector \(value)")
                }
                command = Pocket3CameraSettings.manualISO(iso)

            case "camera.setIsoMax":
                let iso: Pocket3CameraSettings.ISOMax
                switch try vector.inputInt("iso") {
                case 100: iso = .iso100
                case 6400: iso = .iso6400
                case let value:
                    return XCTFail("\(vector.id): unsupported ISO MAX vector \(value)")
                }
                command = Pocket3CameraSettings.isoMax(iso)

            default:
                return XCTFail("\(vector.id): unsupported camera operation \(vector.operation)")
            }

            XCTAssertEqual(command.set, UInt8(try hexValue(vector.expectedString("commandSetHex"))), vector.id)
            XCTAssertEqual(command.cmd, UInt8(try hexValue(vector.expectedString("commandIdHex"))), vector.id)
            XCTAssertEqual(hexString(command.payload), try vector.expectedString("payloadHex"), vector.id)
        }
    }
}

private struct SharedProtocolVector {
    let id: String
    let operation: String
    let input: [String: Any]
    let expected: [String: Any]

    func inputString(_ key: String) throws -> String { try required(key, in: input, as: String.self) }
    func inputInt(_ key: String) throws -> Int { try required(key, in: input, as: Int.self) }
    func inputBool(_ key: String) throws -> Bool { try required(key, in: input, as: Bool.self) }
    func expectedString(_ key: String) throws -> String { try required(key, in: expected, as: String.self) }
    func expectedBool(_ key: String) throws -> Bool { try required(key, in: expected, as: Bool.self) }

    private func required<T>(_ key: String, in dictionary: [String: Any], as type: T.Type) throws -> T {
        guard let value = dictionary[key] as? T else {
            throw SharedProtocolVectorError.invalidVector("\(id): missing or invalid \(key)")
        }
        return value
    }
}

private enum SharedProtocolVectorLoader {
    static func load(category: String, file: String) throws -> [SharedProtocolVector] {
        let root = try protocolRoot()
        let url = root
            .appendingPathComponent("test-vectors", isDirectory: true)
            .appendingPathComponent(category, isDirectory: true)
            .appendingPathComponent(file, isDirectory: false)

        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw SharedProtocolVectorError.missingCanonicalVectors(
                "Canonical vector file not found at \(url.path). " +
                "Set POCKET3_PROTOCOL_ROOT to the local Pocket3/Protocol repository."
            )
        }

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionaries = object as? [[String: Any]], !dictionaries.isEmpty else {
            throw SharedProtocolVectorError.invalidVector("\(url.path): expected a non-empty JSON array")
        }

        return try dictionaries.map { dictionary in
            guard dictionary["schemaVersion"] as? Int == 1,
                  dictionary["device"] as? String == "pocket3",
                  let id = dictionary["id"] as? String,
                  let operation = dictionary["operation"] as? String,
                  let evidence = dictionary["evidence"] as? [String: Any],
                  let evidenceLevel = evidence["level"] as? String,
                  ["hardware-confirmed", "packet-capture-confirmed", "source-confirmed"].contains(evidenceLevel),
                  evidence["source"] as? String != nil,
                  let input = dictionary["input"] as? [String: Any],
                  let expected = dictionary["expected"] as? [String: Any] else {
                throw SharedProtocolVectorError.invalidVector("\(url.path): invalid vector metadata or evidence")
            }
            return SharedProtocolVector(id: id, operation: operation, input: input, expected: expected)
        }
    }

    private static func protocolRoot() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidate: URL
        if let configured = environment["POCKET3_PROTOCOL_ROOT"], !configured.isEmpty {
            candidate = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            let projectRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            candidate = projectRoot
                .appendingPathComponent("..", isDirectory: true)
                .appendingPathComponent("protocol", isDirectory: true)
        }

        let root = candidate.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SharedProtocolVectorError.missingCanonicalVectors(
                "Canonical Protocol repository not found at \(root.path). " +
                "Set POCKET3_PROTOCOL_ROOT to the local Pocket3/Protocol repository."
            )
        }
        return root
    }
}

private enum SharedProtocolVectorError: Error, CustomStringConvertible {
    case missingCanonicalVectors(String)
    case invalidVector(String)

    var description: String {
        switch self {
        case .missingCanonicalVectors(let message), .invalidVector(let message): return message
        }
    }
}

private func data(fromHex hex: String) throws -> Data {
    guard hex.count.isMultiple(of: 2) else {
        throw SharedProtocolVectorError.invalidVector("Odd-length hex string: \(hex)")
    }

    var bytes: [UInt8] = []
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else {
            throw SharedProtocolVectorError.invalidVector("Invalid hex string: \(hex)")
        }
        bytes.append(byte)
        index = next
    }
    return Data(bytes)
}

private func hexValue(_ hex: String) throws -> Int {
    guard let value = Int(hex, radix: 16) else {
        throw SharedProtocolVectorError.invalidVector("Invalid integer hex string: \(hex)")
    }
    return value
}

private func hexString(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined()
}
