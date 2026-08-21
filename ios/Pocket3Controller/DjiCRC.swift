import Foundation

// Adapted from the frozen Pocket3GimbalTest v0.14.3 / Osmosis-derived DUML implementation.
// See LICENSE_OSMOSIS.txt and NOTICE.md.

enum DjiCRC {
    static func crc8(
        _ data: Data,
        initial: UInt8 = 0x77,
        polynomial: UInt8 = 0x8C
    ) -> UInt8 {
        var crc = initial
        for byte in data {
            crc ^= byte
            for _ in 0..<8 {
                if (crc & 0x01) != 0 {
                    crc = (crc >> 1) ^ polynomial
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }

    static func crc16(
        _ data: Data,
        initial: UInt16 = 0x3692,
        polynomial: UInt16 = 0x8408
    ) -> UInt16 {
        var crc = initial
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                if (crc & 0x0001) != 0 {
                    crc = (crc >> 1) ^ polynomial
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }
}
