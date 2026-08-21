package com.pocket3.gimbaltest

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class Pocket3VideoMediaTest {
    @Test
    fun ordinaryMediaStatusProgressionIsMonotonic() {
        val receiving = Pocket3VideoStatus.WAITING_FOR_VIDEO.onOrdinaryMediaDatagram()
        assertEquals(Pocket3VideoStatus.VIDEO_RECEIVING, receiving)

        val decoding = receiving.onDecoderInputAccepted()
        assertEquals(Pocket3VideoStatus.DECODING, decoding)

        assertEquals(Pocket3VideoStatus.DECODING, decoding.onOrdinaryMediaDatagram())
        assertEquals(Pocket3VideoStatus.ERROR, Pocket3VideoStatus.ERROR.onOrdinaryMediaDatagram())
    }

    @Test
    fun validFirstFragmentCompletesAtExactAnnouncedLength() {
        val reassembler = Pocket3MediaReassembler()
        val message = bytes(0, 0, 0, 1, 0x65, 0x11, 0x22)
        assertArrayEquals(message, reassembler.consume(firstFragment(message.size, message)))
        assertEquals(1, reassembler.stats().completedMessages)
        assertFalse(reassembler.hasPartialMessage())
    }

    @Test
    fun multiFragmentMediaMessageReassemblesInOrder() {
        val reassembler = Pocket3MediaReassembler()
        assertNull(reassembler.consume(firstFragment(7, bytes(1, 2)), nowNs = 10))
        assertNull(reassembler.consume(continuation(bytes(3, 4)), nowNs = 20))
        assertArrayEquals(bytes(1, 2, 3, 4, 5, 6, 7), reassembler.consume(continuation(bytes(5, 6, 7)), nowNs = 30))
    }

    @Test
    fun truncatedFirstFragmentIsRejected() {
        val reassembler = Pocket3MediaReassembler()
        val packet = ByteArray(28).apply {
            this[6] = 0x02
            this[20] = 0
            this[21] = 0
            this[22] = 1
            this[23] = 0xFF.toByte()
        }
        assertNull(reassembler.consume(packet))
        assertEquals(1, reassembler.stats().malformedPackets)
    }

    @Test
    fun absurdAnnouncedLengthIsRejectedWithoutAllocation() {
        val reassembler = Pocket3MediaReassembler()
        assertNull(reassembler.consume(firstFragment(8 * 1024 * 1024 + 1, byteArrayOf())))
        assertFalse(reassembler.hasPartialMessage())
        assertEquals(1, reassembler.stats().malformedPackets)
    }

    @Test
    fun newFirstFragmentDiscardsStalePartial() {
        val reassembler = Pocket3MediaReassembler()
        assertNull(reassembler.consume(firstFragment(5, bytes(1, 2))))
        val replacement = bytes(9, 8, 7)
        assertArrayEquals(replacement, reassembler.consume(firstFragment(replacement.size, replacement)))
        assertEquals(1, reassembler.stats().droppedPartialMessages)
    }

    @Test
    fun partialExpiresAndResetClearsState() {
        val reassembler = Pocket3MediaReassembler(maximumPartialAgeNs = 100)
        assertNull(reassembler.consume(firstFragment(4, bytes(1)), nowNs = 1))
        assertNull(reassembler.consume(continuation(bytes(2)), nowNs = 102))
        assertEquals(1, reassembler.stats().droppedPartialMessages)
        assertEquals(1, reassembler.stats().joinedMidMessagePackets)

        assertNull(reassembler.consume(firstFragment(4, bytes(1)), nowNs = 200))
        assertTrue(reassembler.hasPartialMessage())
        reassembler.reset()
        assertFalse(reassembler.hasPartialMessage())
    }

    @Test
    fun malformedPacketNeverThrows() {
        val reassembler = Pocket3MediaReassembler()
        listOf(ByteArray(0), ByteArray(7), ByteArray(19), ByteArray(20)).forEach {
            assertNull(reassembler.consume(it))
        }
        assertTrue(reassembler.stats().malformedPackets >= 3)
    }

    @Test
    fun annexBParserHandlesThreeAndFourByteStartCodes() {
        val parsed = Pocket3AnnexB.parse(
            bytes(0, 0, 0, 1, 0x67, 0x64, 0, 0, 1, 0x68, 0x01, 0, 0, 0, 1, 0x65, 0x55)
        )
        assertEquals(listOf(7, 8, 5), parsed.map { it.type })
        assertArrayEquals(bytes(0x67, 0x64), parsed[0].bytes)
        assertArrayEquals(bytes(0x68, 0x01), parsed[1].bytes)
        assertArrayEquals(bytes(0x65, 0x55), parsed[2].bytes)
    }

    @Test
    fun h264StreamRetainsSpsPpsAndWaitsForIdr() {
        val stream = Pocket3H264Stream()
        val configuration = stream.consume(annexB(bytes(0x67, 0x64, 0x00), bytes(0x68, 0x01)))
        assertTrue(configuration.configuration != null)
        assertNull(configuration.accessUnit)
        assertEquals(setOf(7, 8), configuration.nalTypes)

        assertNull(stream.consume(annexB(bytes(0x41, 0x10))).accessUnit)
        val idr = stream.consume(annexB(bytes(0x65, 0x20)))
        assertTrue(idr.accessUnit?.isIdr == true)
        assertEquals(1, stream.stats().spsCount)
        assertEquals(1, stream.stats().ppsCount)
        assertEquals(1, stream.stats().idrCount)
    }

    @Test
    fun startupSequenceMatchesCaptureConfirmedOrderAndTiming() {
        val steps = Pocket3LiveViewCommands.startupSequence()
        assertEquals(13, steps.size)
        assertEquals(listOf(0x01, 0x09, 0x01, 0x09), steps.take(4).map { it.command.set })
        assertTrue(steps.subList(4, 9).all { it.command.set == 0x01 && it.command.payload.contentEquals(LIVE_START) && it.delayAfterMs == 2L })
        assertTrue(steps.takeLast(4).all { it.command.payload.contentEquals(LIVE_IDLE) && it.delayAfterMs == 2L })
        assertArrayEquals(LIVE_A8, steps[1].command.payload)
        assertEquals(2, steps[1].command.receiverId)
        assertEquals(2, steps[1].command.commandType)
    }

    @Test
    fun safeShutdownUsesOnlyLiveIdleEightTimes() {
        val steps = Pocket3LiveViewCommands.shutdownSequence()
        assertEquals(8, steps.size)
        assertTrue(steps.all { it.command.set == 0x01 && it.command.command == 0x01 })
        assertTrue(steps.all { it.command.payload.contentEquals(LIVE_IDLE) && it.delayAfterMs == 3L })
        assertTrue(steps.none { it.command.payload.contentEquals(FORBIDDEN_PLAYBACK_STATE_TEST_FIXTURE) })
    }

    private fun firstFragment(announcedLength: Int, payload: ByteArray): ByteArray =
        ByteArray(36 + payload.size).apply {
            this[6] = 0x02
            this[20] = 0
            this[21] = 0
            this[22] = 1
            this[23] = 0xFF.toByte()
            this[24] = (announcedLength and 0xFF).toByte()
            this[25] = ((announcedLength ushr 8) and 0xFF).toByte()
            this[26] = ((announcedLength ushr 16) and 0xFF).toByte()
            this[27] = ((announcedLength ushr 24) and 0xFF).toByte()
            payload.copyInto(this, 36)
        }

    private fun continuation(payload: ByteArray): ByteArray = ByteArray(20 + payload.size).apply {
        this[6] = 0x02
        payload.copyInto(this, 20)
    }

    private fun annexB(vararg nals: ByteArray): ByteArray = Pocket3AnnexB.encode(
        nals.map { Pocket3H264NalUnit(it[0].toInt() and 0x1F, it) },
    )

    companion object {
        private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

        private val LIVE_START = bytes(0x01, 0, 0, 0, 0, 0x04, 0, 0, 0, 0x05, 0x01)
        private val LIVE_IDLE = bytes(0x00, 0, 0, 0, 0, 0x04, 0, 0, 0, 0x04, 0x01)
        private val LIVE_A8 = bytes(0x00, 0x04, 0x02, 0, 0, 0, 0, 0, 0, 0)

        // Test-only regression fixture. Production code must never emit this playback transition.
        private val FORBIDDEN_PLAYBACK_STATE_TEST_FIXTURE =
            bytes(0x03, 0, 0, 0, 0, 0x04, 0, 0, 0, 0x07, 0x01)
    }
}
