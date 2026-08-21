import Foundation

struct DumlFrame {
    let route: UInt16
    let id: UInt16
    let flags: UInt8
    let set: UInt8
    let cmd: UInt8
    let payload: Data
}

enum DumlFrameScanner {
    /// Returns every CRC-valid DUML frame, including valid frames nested inside another payload.
    /// Advancing one byte at a time is intentional and preserves the current DJI tunnel behavior.
    static func scan(_ raw: Data) -> [DumlFrame] {
        let bytes = [UInt8](raw)
        var frames: [DumlFrame] = []
        var index = 0

        while index + 13 <= bytes.count {
            guard bytes[index] == 0x55 else {
                index += 1
                continue
            }

            let packed = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8)
            let length = packed & 0x03FF
            let version = Int(bytes[index + 2]) >> 2

            guard version == 1, length >= 13, index + length <= bytes.count else {
                index += 1
                continue
            }

            let header = Data(bytes[index..<(index + 3)])
            guard DjiCRC.crc8(header) == bytes[index + 3] else {
                index += 1
                continue
            }

            let bodyEnd = index + length - 2
            let body = Data(bytes[index..<bodyEnd])
            let expectedCRC =
                UInt16(bytes[bodyEnd]) |
                (UInt16(bytes[bodyEnd + 1]) << 8)

            guard DjiCRC.crc16(body) == expectedCRC else {
                index += 1
                continue
            }

            frames.append(DumlFrame(
                route: UInt16(bytes[index + 4]) | (UInt16(bytes[index + 5]) << 8),
                id: UInt16(bytes[index + 6]) | (UInt16(bytes[index + 7]) << 8),
                flags: bytes[index + 8],
                set: bytes[index + 9],
                cmd: bytes[index + 10],
                payload: Data(bytes[(index + 11)..<bodyEnd])
            ))

            index += 1
        }

        return frames
    }

    static func firstReply(in datagrams: [Data], set: UInt8, cmd: UInt8) -> Data? {
        for datagram in datagrams {
            for frame in scan(datagram) where frame.set == set && frame.cmd == cmd && !frame.payload.isEmpty {
                return frame.payload
            }
        }
        return nil
    }

    static func firstResponseStatus(in datagrams: [Data], set: UInt8, cmd: UInt8) -> Int? {
        for datagram in datagrams {
            for frame in scan(datagram) where frame.set == set && frame.cmd == cmd {
                if frame.payload.count >= 2 {
                    return Int(frame.payload[0]) | (Int(frame.payload[1]) << 8)
                }
                if frame.payload.count == 1 {
                    return Int(frame.payload[0])
                }
                return 0
            }
        }
        return nil
    }
}

enum DumlTransportHeader {
    struct Fields {
        let totalLength: Int
        let sessionId: Int
        let sequence: Int
        let packetType: UInt8
        let checksum: UInt8
    }

    static func encode(
        packetType: UInt8,
        payloadLength: Int,
        sessionId: Int,
        sequence: Int
    ) -> Data {
        let total = 8 + payloadLength
        let word0 = 0x8000 | (total & 0x3FFF)

        var bytes: [UInt8] = [
            UInt8(word0 & 0xFF),
            UInt8((word0 >> 8) & 0xFF),
            UInt8(sessionId & 0xFF),
            UInt8((sessionId >> 8) & 0xFF),
            UInt8(sequence & 0xFF),
            UInt8((sequence >> 8) & 0xFF),
            packetType
        ]

        bytes.append(bytes.reduce(UInt8(0)) { $0 ^ $1 })
        return Data(bytes)
    }

    /// Parses the eight fixed header fields without adding validation that the legacy transport
    /// did not perform. Session filtering therefore retains its existing behavior.
    static func decode(_ datagram: Data) -> Fields? {
        guard datagram.count >= 8 else { return nil }
        let word0 = DumlBytes.uint16LE(datagram, at: 0)
        return Fields(
            totalLength: word0 & 0x3FFF,
            sessionId: DumlBytes.uint16LE(datagram, at: 2),
            sequence: DumlBytes.uint16LE(datagram, at: 4),
            packetType: datagram[6],
            checksum: datagram[7]
        )
    }

    static func sessionId(in datagram: Data) -> Int? {
        decode(datagram)?.sessionId
    }

    static func sequence(in datagram: Data) -> Int? {
        decode(datagram)?.sequence
    }

    static func packetType(in datagram: Data) -> UInt8? {
        decode(datagram)?.packetType
    }

    static func belongsToSession(_ datagram: Data, sessionId: Int) -> Bool {
        self.sessionId(in: datagram) == sessionId
    }
}

enum DumlAckWindow {
    static func encode(
        rxType2Sequence: Int,
        rxType3Sequence: Int,
        peerAckedTxSequence: Int,
        lastTxSequence: Int
    ) -> Data {
        var result = Data()
        appendDuplicated(rxType2Sequence, to: &result)
        appendDuplicated(rxType3Sequence, to: &result)
        DumlBytes.appendUInt16LE(peerAckedTxSequence, to: &result)
        DumlBytes.appendUInt16LE(lastTxSequence, to: &result)
        result.append(contentsOf: [0, 0, 0, 0, 0, 0])
        return result
    }

    private static func appendDuplicated(_ value: Int, to data: inout Data) {
        DumlBytes.appendUInt16LE(value, to: &data)
        DumlBytes.appendUInt16LE(value, to: &data)
        data.append(contentsOf: [0, 0, 0, 0])
    }
}

enum DumlRoutingHeader {
    struct Fields {
        let peerAck: Int
        let sequence: Int
        let commandCounter: Int
        let routingClass: UInt8
    }

    static func encode(sequence: Int, peerAck: Int, commandCounter: Int) -> Data {
        Data([
            UInt8(peerAck & 0xFF),
            UInt8((peerAck >> 8) & 0xFF),
            UInt8(sequence & 0xFF),
            UInt8((sequence >> 8) & 0xFF),
            0, 0, 0, 0,
            UInt8(commandCounter & 0xFF),
            0x01,
            0x00,
            0x00
        ])
    }

    static func decode(_ data: Data) -> Fields? {
        guard data.count >= 12 else { return nil }
        return Fields(
            peerAck: DumlBytes.uint16LE(data, at: 0),
            sequence: DumlBytes.uint16LE(data, at: 2),
            commandCounter: Int(data[8]),
            routingClass: data[10]
        )
    }
}

enum DumlBytes {
    static func uint16LE(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    static func appendUInt16LE(_ value: Int, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
}
