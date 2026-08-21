package dev.konraditurbe.osmosis.duml

data class DumlFrame(
    val route: Int,
    val id: Int,
    val flags: Int,
    val commandSet: Int,
    val commandId: Int,
    val payload: ByteArray,
)

object DumlFrameScanner {
    /**
     * Returns every CRC-valid DUML frame. Advancing one byte at a time is intentional: DJI tunnel
     * frames can contain another complete DUML frame that must also be discovered.
     */
    fun scan(raw: ByteArray): List<DumlFrame> {
        val frames = ArrayList<DumlFrame>()
        var index = 0

        while (index + 13 <= raw.size) {
            if ((raw[index].toInt() and 0xFF) != 0x55) {
                index++
                continue
            }

            val packed = (raw[index + 1].toInt() and 0xFF) or
                ((raw[index + 2].toInt() and 0xFF) shl 8)
            val length = packed and 0x03FF
            val version = (raw[index + 2].toInt() and 0xFF) ushr 2
            if (version != 1 || length < 13 || index + length > raw.size) {
                index++
                continue
            }

            if (DjiCrc.computeCrc8(raw.copyOfRange(index, index + 3)) !=
                (raw[index + 3].toInt() and 0xFF)
            ) {
                index++
                continue
            }

            val bodyEnd = index + length - 2
            val body = raw.copyOfRange(index, bodyEnd)
            val expectedCrc = (raw[bodyEnd].toInt() and 0xFF) or
                ((raw[bodyEnd + 1].toInt() and 0xFF) shl 8)
            if (DjiCrc.computeCrc16(body) != expectedCrc) {
                index++
                continue
            }

            frames.add(
                DumlFrame(
                    route = DumlBytes.uint16Le(raw, index + 4),
                    id = DumlBytes.uint16Le(raw, index + 6),
                    flags = raw[index + 8].toInt() and 0xFF,
                    commandSet = raw[index + 9].toInt() and 0xFF,
                    commandId = raw[index + 10].toInt() and 0xFF,
                    payload = raw.copyOfRange(index + 11, bodyEnd),
                ),
            )

            index++
        }

        return frames
    }

    /**
     * Preserves the existing Android reply lookup exactly: header CRC is checked, but CRC-16 and
     * packed-version validation are not. Tightening this requires separate evidence and is not part
     * of the behavior-preserving extraction.
     */
    fun findReply(datagrams: List<ByteArray>, set: Int, command: Int): ByteArray? {
        for (datagram in datagrams) {
            var index = 0
            while (index + 11 <= datagram.size) {
                if ((datagram[index].toInt() and 0xFF) != 0x55) {
                    index++
                    continue
                }
                val length = ((datagram[index + 1].toInt() and 0xFF) or
                    ((datagram[index + 2].toInt() and 0xFF) shl 8)) and 0x03FF
                if (length < 13 || index + length > datagram.size) {
                    index++
                    continue
                }
                if (DjiCrc.computeCrc8(datagram.copyOfRange(index, index + 3)) !=
                    (datagram[index + 3].toInt() and 0xFF)
                ) {
                    index++
                    continue
                }
                if ((datagram[index + 9].toInt() and 0xFF) == set &&
                    (datagram[index + 10].toInt() and 0xFF) == command
                ) {
                    val payload = datagram.copyOfRange(index + 11, index + length - 2)
                    if (payload.isNotEmpty()) return payload
                }
                index += length
            }
        }
        return null
    }

    /** Preserves the existing response-status lookup, including its intentionally unchanged checks. */
    fun findResponseStatus(datagram: ByteArray, set: Int, command: Int): Int? {
        var index = 0
        while (index + 13 <= datagram.size) {
            if ((datagram[index].toInt() and 0xFF) != 0x55) {
                index++
                continue
            }
            val length = ((datagram[index + 1].toInt() and 0xFF) or
                ((datagram[index + 2].toInt() and 0xFF) shl 8)) and 0x03FF
            if (length < 13 || index + length > datagram.size) {
                index++
                continue
            }
            if ((datagram[index + 9].toInt() and 0xFF) == set &&
                (datagram[index + 10].toInt() and 0xFF) == command
            ) {
                val payloadStart = index + 11
                val payloadEnd = index + length - 2
                return when {
                    payloadEnd - payloadStart >= 2 -> DumlBytes.uint16Le(datagram, payloadStart)
                    payloadEnd - payloadStart >= 1 -> datagram[payloadStart].toInt() and 0xFF
                    else -> 0
                }
            }
            index += length
        }
        return null
    }
}
