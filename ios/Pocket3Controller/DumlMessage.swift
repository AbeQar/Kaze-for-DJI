import Foundation

enum DumlError: Error, CustomStringConvertible {
    case tooShort
    case badSOF
    case badLength(expected: Int, actual: Int)
    case badVersion
    case badHeaderCRC
    case badCRC

    var description: String {
        switch self {
        case .tooShort: return "DUML frame too short"
        case .badSOF: return "Bad DUML SOF"
        case .badLength(let expected, let actual):
            return "Bad DUML length: expected \(expected), actual \(actual)"
        case .badVersion: return "Bad DUML version"
        case .badHeaderCRC: return "Bad DUML header CRC"
        case .badCRC: return "Bad DUML CRC16"
        }
    }
}

struct DumlMessage {
    var target: UInt16
    var id: UInt16
    var type: UInt32
    var payload: Data

    var flags: UInt8 { UInt8(type & 0xFF) }
    var cmdSet: UInt8 { UInt8((type >> 8) & 0xFF) }
    var cmdId: UInt8 { UInt8((type >> 16) & 0xFF) }

    init(target: UInt16, id: UInt16, type: UInt32, payload: Data = Data()) {
        self.target = target
        self.id = id
        self.type = type & 0x00FF_FFFF
        self.payload = payload
    }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 13 else { throw DumlError.tooShort }
        guard bytes[0] == 0x55 else { throw DumlError.badSOF }

        let declaredLength = Int(bytes[1])
        guard declaredLength == bytes.count else {
            throw DumlError.badLength(expected: declaredLength, actual: bytes.count)
        }
        guard bytes[2] == 0x04 else { throw DumlError.badVersion }

        let header = Data(bytes[0..<3])
        guard bytes[3] == DjiCRC.crc8(header) else { throw DumlError.badHeaderCRC }

        let target = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
        let id = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
        let type = UInt32(bytes[8]) | (UInt32(bytes[9]) << 8) | (UInt32(bytes[10]) << 16)

        let payloadEnd = bytes.count - 2
        let payload = payloadEnd > 11 ? Data(bytes[11..<payloadEnd]) : Data()

        let receivedCRC = UInt16(bytes[payloadEnd]) | (UInt16(bytes[payloadEnd + 1]) << 8)
        let calculatedCRC = DjiCRC.crc16(Data(bytes[0..<payloadEnd]))
        guard receivedCRC == calculatedCRC else { throw DumlError.badCRC }

        self.target = target
        self.id = id
        self.type = type
        self.payload = payload
    }

    func encode() -> Data {
        precondition(payload.count <= 242, "BLE DUML payload is too large for one-byte length field")

        var bytes = [UInt8]()
        bytes.reserveCapacity(13 + payload.count)

        bytes.append(0x55)
        bytes.append(UInt8(13 + payload.count))
        bytes.append(0x04)
        bytes.append(DjiCRC.crc8(Data(bytes)))

        bytes.append(UInt8(truncatingIfNeeded: target))
        bytes.append(UInt8(truncatingIfNeeded: target >> 8))

        bytes.append(UInt8(truncatingIfNeeded: id))
        bytes.append(UInt8(truncatingIfNeeded: id >> 8))

        bytes.append(UInt8(truncatingIfNeeded: type))
        bytes.append(UInt8(truncatingIfNeeded: type >> 8))
        bytes.append(UInt8(truncatingIfNeeded: type >> 16))

        bytes.append(contentsOf: payload)

        let crc = DjiCRC.crc16(Data(bytes))
        bytes.append(UInt8(truncatingIfNeeded: crc))
        bytes.append(UInt8(truncatingIfNeeded: crc >> 8))

        return Data(bytes)
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
