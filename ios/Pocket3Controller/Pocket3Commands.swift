import Foundation

enum Pocket3Commands {
    static let targetAppToWiFi: UInt16 = 0x0702
    static let targetAppToSession: UInt16 = 0xF002
    static let targetAppTo1C: UInt16 = 0x1C02

    static let pairMessageID: UInt16 = 0x8092
    static let defaultIdentifier = "284ae5b8d76b3375a04a6417ad71bea3"

    static let sessionWake = Data([0x04, 0x00])
    static let sessionKeepalive = Data([0x01, 0x01])

    static let appDeviceInfo: Data = {
        var out = Data([0x00, 0x41, 0x50, 0x50])
        out.append(contentsOf: Array(repeating: UInt8(0), count: 37))
        out.append(0x02)
        out.append(contentsOf: Array(repeating: UInt8(0), count: 8))
        out.append(contentsOf: [0x02, 0x08])
        out.append(contentsOf: Array(repeating: UInt8(0), count: 10))
        return out
    }()

    static func packString(_ value: String) -> Data {
        let utf8 = Data(value.utf8)
        precondition(utf8.count <= 255)
        var out = Data([UInt8(utf8.count)])
        out.append(utf8)
        return out
    }

    static func command(
        cmdSet: UInt8,
        cmdId: UInt8,
        payload: Data = Data(),
        target: UInt16,
        id: UInt16
    ) -> Data {
        let type =
            UInt32(0x40) |
            (UInt32(cmdSet) << 8) |
            (UInt32(cmdId) << 16)

        return DumlMessage(
            target: target,
            id: id,
            type: type,
            payload: payload
        ).encode()
    }

    static func sessionPing(_ payload: Data, id: UInt16 = 0x802B) -> Data {
        command(
            cmdSet: 0x00,
            cmdId: 0x2B,
            payload: payload,
            target: targetAppToSession,
            id: id
        )
    }

    static func setPairingPin(
        _ pin: String = "osmo",
        id: UInt16 = pairMessageID,
        identifier: String = defaultIdentifier
    ) -> Data {
        var payload = packString(identifier)
        payload.append(packString(pin))

        let type: UInt32 = 0x450740
        return DumlMessage(
            target: targetAppToWiFi,
            id: id,
            type: type,
            payload: payload
        ).encode()
    }

    static func session5310(id: UInt16 = 0x8053) -> Data {
        command(
            cmdSet: 0x53,
            cmdId: 0x10,
            payload: Data([0x00, 0x00, 0x00, 0x00]),
            target: targetAppTo1C,
            id: id
        )
    }

    static func wifiQuery(
        cmdId: UInt8,
        payload: Data = Data(),
        id: UInt16
    ) -> Data {
        command(
            cmdSet: 0x07,
            cmdId: cmdId,
            payload: payload,
            target: targetAppToWiFi,
            id: id
        )
    }
}
