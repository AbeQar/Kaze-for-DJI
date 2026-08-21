package dev.konraditurbe.osmosis.duml

data class DumlTransportFields(
    val totalLength: Int,
    val sessionId: Int,
    val sequence: Int,
    val packetType: Int,
    val checksum: Int,
)

object DumlTransportHeader {
    fun encode(packetType: Int, payloadLength: Int, sessionId: Int, sequence: Int): ByteArray {
        val total = 8 + payloadLength
        val word0 = (1 shl 15) or (total and 0x3FFF)
        val bytes = byteArrayOf(
            (word0 and 0xFF).toByte(), ((word0 ushr 8) and 0xFF).toByte(),
            (sessionId and 0xFF).toByte(), ((sessionId ushr 8) and 0xFF).toByte(),
            (sequence and 0xFF).toByte(), ((sequence ushr 8) and 0xFF).toByte(),
            packetType.toByte(), 0,
        )
        var checksum = 0
        for (index in 0 until 7) checksum = checksum xor (bytes[index].toInt() and 0xFF)
        bytes[7] = checksum.toByte()
        return bytes
    }

    /** Parses fields without introducing checksum/length validation absent from the old transport. */
    fun decode(datagram: ByteArray): DumlTransportFields? {
        if (datagram.size < 8) return null
        return DumlTransportFields(
            totalLength = DumlBytes.uint16Le(datagram, 0) and 0x3FFF,
            sessionId = DumlBytes.uint16Le(datagram, 2),
            sequence = DumlBytes.uint16Le(datagram, 4),
            packetType = datagram[6].toInt() and 0xFF,
            checksum = datagram[7].toInt() and 0xFF,
        )
    }
}

object DumlAckWindow {
    fun encode(
        rxType2Sequence: Int,
        rxType3Sequence: Int,
        peerAckedTxSequence: Int,
        lastTxSequence: Int,
    ): ByteArray {
        val bytes = ByteArray(26)
        putDuplicated(bytes, 0, rxType2Sequence)
        putDuplicated(bytes, 8, rxType3Sequence)
        DumlBytes.putUInt16Le(bytes, 16, peerAckedTxSequence)
        DumlBytes.putUInt16Le(bytes, 18, lastTxSequence)
        return bytes
    }

    private fun putDuplicated(bytes: ByteArray, offset: Int, value: Int) {
        DumlBytes.putUInt16Le(bytes, offset, value)
        DumlBytes.putUInt16Le(bytes, offset + 2, value)
    }
}

data class DumlRoutingFields(
    val peerAck: Int,
    val sequence: Int,
    val commandCounter: Int,
    val routingClass: Int,
)

object DumlRoutingHeader {
    fun encode(sequence: Int, peerAck: Int, commandCounter: Int, drone: Boolean): ByteArray =
        byteArrayOf(
            (peerAck and 0xFF).toByte(), ((peerAck ushr 8) and 0xFF).toByte(),
            (sequence and 0xFF).toByte(), ((sequence ushr 8) and 0xFF).toByte(),
            0, 0, 0, 0,
            (commandCounter and 0xFF).toByte(), 0x01,
            (if (drone) 0x60 else 0x00).toByte(), 0x00,
        )

    fun decode(data: ByteArray): DumlRoutingFields? {
        if (data.size < 12) return null
        return DumlRoutingFields(
            peerAck = DumlBytes.uint16Le(data, 0),
            sequence = DumlBytes.uint16Le(data, 2),
            commandCounter = data[8].toInt() and 0xFF,
            routingClass = data[10].toInt() and 0xFF,
        )
    }
}

object DumlBytes {
    fun uint16Le(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8)

    fun putUInt16Le(bytes: ByteArray, offset: Int, value: Int) {
        bytes[offset] = (value and 0xFF).toByte()
        bytes[offset + 1] = ((value ushr 8) and 0xFF).toByte()
    }
}
