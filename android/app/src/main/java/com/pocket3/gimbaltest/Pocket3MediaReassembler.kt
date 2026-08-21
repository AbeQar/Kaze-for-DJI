package com.pocket3.gimbaltest

data class Pocket3MediaReassemblyStats(
    val packetsReceived: Long,
    val completedMessages: Long,
    val malformedPackets: Long,
    val droppedPartialMessages: Long,
    val joinedMidMessagePackets: Long,
)

/**
 * Reassembles DJI pktType-0x02 media messages from the full accepted UDP datagrams returned by the
 * existing transport. This class is thread-confined by Pocket3VideoOutput.
 */
class Pocket3MediaReassembler(
    private val maximumMessageSize: Int = 8 * 1024 * 1024,
    private val maximumPartialAgeNs: Long = 1_500_000_000L,
) {
    companion object {
        private const val PACKET_TYPE_OFFSET = 6
        private const val MEDIA_FRAGMENT_OFFSET = 20
        private const val FIRST_FRAGMENT_HEADER_SIZE = 16
    }

    private var expectedLength: Int? = null
    private var partial = ByteArray(0)
    private var partialSize = 0
    private var partialStartedNs = 0L
    private var packetsReceived = 0L
    private var completedMessages = 0L
    private var malformedPackets = 0L
    private var droppedPartialMessages = 0L
    private var joinedMidMessagePackets = 0L

    fun consume(datagram: ByteArray, nowNs: Long = System.nanoTime()): ByteArray? {
        packetsReceived++
        if (datagram.size < MEDIA_FRAGMENT_OFFSET || datagram.u8(PACKET_TYPE_OFFSET) != 0x02) {
            malformedPackets++
            return null
        }

        if (expectedLength != null && nowNs - partialStartedNs > maximumPartialAgeNs) {
            discardPartial()
        }

        val fragmentSize = datagram.size - MEDIA_FRAGMENT_OFFSET
        val firstMarker = fragmentSize >= 4 &&
            datagram.u8(MEDIA_FRAGMENT_OFFSET) == 0x00 &&
            datagram.u8(MEDIA_FRAGMENT_OFFSET + 1) == 0x00 &&
            datagram.u8(MEDIA_FRAGMENT_OFFSET + 2) == 0x01 &&
            datagram.u8(MEDIA_FRAGMENT_OFFSET + 3) == 0xFF

        if (firstMarker) {
            if (expectedLength != null) discardPartial()
            if (fragmentSize < FIRST_FRAGMENT_HEADER_SIZE) {
                malformedPackets++
                clearPartial()
                return null
            }
            val announced = datagram.u32le(MEDIA_FRAGMENT_OFFSET + 4)
            if (announced <= 0L || announced > maximumMessageSize.toLong()) {
                malformedPackets++
                clearPartial()
                return null
            }
            expectedLength = announced.toInt()
            partial = ByteArray(announced.toInt())
            partialSize = 0
            partialStartedNs = nowNs
            append(datagram, MEDIA_FRAGMENT_OFFSET + FIRST_FRAGMENT_HEADER_SIZE)
        } else {
            if (expectedLength == null) {
                joinedMidMessagePackets++
                return null
            }
            if (fragmentSize == 0) {
                malformedPackets++
                return null
            }
            append(datagram, MEDIA_FRAGMENT_OFFSET)
        }

        val expected = expectedLength ?: return null
        if (partialSize < expected) return null
        val complete = partial.copyOf(expected)
        completedMessages++
        clearPartial()
        return complete
    }

    fun reset() {
        clearPartial()
    }

    fun resetAll() {
        clearPartial()
        packetsReceived = 0
        completedMessages = 0
        malformedPackets = 0
        droppedPartialMessages = 0
        joinedMidMessagePackets = 0
    }

    fun hasPartialMessage(): Boolean = expectedLength != null

    fun stats() = Pocket3MediaReassemblyStats(
        packetsReceived,
        completedMessages,
        malformedPackets,
        droppedPartialMessages,
        joinedMidMessagePackets,
    )

    private fun append(source: ByteArray, offset: Int) {
        val expected = expectedLength ?: return
        val available = source.size - offset
        if (available <= 0) return
        val remaining = expected - partialSize
        val copyCount = minOf(available, remaining)
        source.copyInto(partial, destinationOffset = partialSize, startIndex = offset, endIndex = offset + copyCount)
        partialSize += copyCount
        if (available > remaining) malformedPackets++
    }

    private fun discardPartial() {
        droppedPartialMessages++
        clearPartial()
    }

    private fun clearPartial() {
        expectedLength = null
        partial = ByteArray(0)
        partialSize = 0
        partialStartedNs = 0L
    }
}
