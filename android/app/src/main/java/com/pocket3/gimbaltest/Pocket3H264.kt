package com.pocket3.gimbaltest

data class Pocket3H264NalUnit(val type: Int, val bytes: ByteArray)

data class Pocket3H264DecoderConfiguration(val sps: ByteArray, val pps: ByteArray)

data class Pocket3H264AccessUnit(val annexB: ByteArray, val isIdr: Boolean)

data class Pocket3H264Result(
    val configuration: Pocket3H264DecoderConfiguration?,
    val accessUnit: Pocket3H264AccessUnit?,
    val nalTypes: Set<Int>,
)

data class Pocket3H264Stats(
    val spsCount: Long,
    val ppsCount: Long,
    val idrCount: Long,
    val accessUnitCount: Long,
    val invalidMessageCount: Long,
)

data class Pocket3VideoDimensions(val width: Int, val height: Int)

/** Minimal SPS geometry decoder used only to configure Android's hardware AVC decoder. */
object Pocket3H264Sps {
    private val extendedProfiles = setOf(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)

    fun dimensions(spsNal: ByteArray): Pocket3VideoDimensions? = runCatching {
        if (spsNal.isEmpty() || spsNal[0].toInt() and 0x1F != 7) return null
        val rbsp = removeEmulationPrevention(spsNal.copyOfRange(1, spsNal.size))
        val bits = BitReader(rbsp)
        val profileIdc = bits.readBits(8)
        bits.readBits(8) // constraint flags
        bits.readBits(8) // level_idc
        bits.readUnsignedExpGolomb() // seq_parameter_set_id

        var chromaFormatIdc = 1
        var separateColourPlane = false
        if (profileIdc in extendedProfiles) {
            chromaFormatIdc = bits.readUnsignedExpGolomb()
            if (chromaFormatIdc == 3) separateColourPlane = bits.readBit() == 1
            bits.readUnsignedExpGolomb() // bit_depth_luma_minus8
            bits.readUnsignedExpGolomb() // bit_depth_chroma_minus8
            bits.readBit() // qpprime_y_zero_transform_bypass_flag
            if (bits.readBit() == 1) {
                val count = if (chromaFormatIdc == 3) 12 else 8
                repeat(count) { index ->
                    if (bits.readBit() == 1) skipScalingList(bits, if (index < 6) 16 else 64)
                }
            }
        }

        bits.readUnsignedExpGolomb() // log2_max_frame_num_minus4
        when (bits.readUnsignedExpGolomb()) { // pic_order_cnt_type
            0 -> bits.readUnsignedExpGolomb()
            1 -> {
                bits.readBit()
                bits.readSignedExpGolomb()
                bits.readSignedExpGolomb()
                repeat(bits.readUnsignedExpGolomb()) { bits.readSignedExpGolomb() }
            }
        }
        bits.readUnsignedExpGolomb() // max_num_ref_frames
        bits.readBit() // gaps_in_frame_num_value_allowed_flag
        val widthInMbs = bits.readUnsignedExpGolomb() + 1
        val heightInMapUnits = bits.readUnsignedExpGolomb() + 1
        val frameMbsOnly = bits.readBit()
        if (frameMbsOnly == 0) bits.readBit()
        bits.readBit() // direct_8x8_inference_flag

        var cropLeft = 0
        var cropRight = 0
        var cropTop = 0
        var cropBottom = 0
        if (bits.readBit() == 1) {
            cropLeft = bits.readUnsignedExpGolomb()
            cropRight = bits.readUnsignedExpGolomb()
            cropTop = bits.readUnsignedExpGolomb()
            cropBottom = bits.readUnsignedExpGolomb()
        }

        val chromaArrayType = if (separateColourPlane) 0 else chromaFormatIdc
        val subWidthC = if (chromaArrayType == 1 || chromaArrayType == 2) 2 else 1
        val subHeightC = if (chromaArrayType == 1) 2 else 1
        val cropUnitX = if (chromaArrayType == 0) 1 else subWidthC
        val cropUnitY = if (chromaArrayType == 0) 2 - frameMbsOnly else subHeightC * (2 - frameMbsOnly)
        val width = widthInMbs * 16 - (cropLeft + cropRight) * cropUnitX
        val height = heightInMapUnits * 16 * (2 - frameMbsOnly) - (cropTop + cropBottom) * cropUnitY
        if (width <= 0 || height <= 0 || width > 8192 || height > 8192) null
        else Pocket3VideoDimensions(width, height)
    }.getOrNull()

    private fun removeEmulationPrevention(source: ByteArray): ByteArray {
        val output = ByteArray(source.size)
        var outputSize = 0
        var zeros = 0
        for (value in source) {
            val unsigned = value.toInt() and 0xFF
            if (zeros >= 2 && unsigned == 0x03) {
                zeros = 0
                continue
            }
            output[outputSize++] = value
            zeros = if (unsigned == 0) zeros + 1 else 0
        }
        return output.copyOf(outputSize)
    }

    private fun skipScalingList(bits: BitReader, size: Int) {
        var lastScale = 8
        var nextScale = 8
        repeat(size) {
            if (nextScale != 0) {
                nextScale = (lastScale + bits.readSignedExpGolomb() + 256) % 256
            }
            if (nextScale != 0) lastScale = nextScale
        }
    }

    private class BitReader(private val bytes: ByteArray) {
        private var bitOffset = 0

        fun readBit(): Int {
            require(bitOffset < bytes.size * 8)
            val value = (bytes[bitOffset / 8].toInt() ushr (7 - bitOffset % 8)) and 1
            bitOffset++
            return value
        }

        fun readBits(count: Int): Int {
            var value = 0
            repeat(count) { value = (value shl 1) or readBit() }
            return value
        }

        fun readUnsignedExpGolomb(): Int {
            var leadingZeros = 0
            while (readBit() == 0) {
                leadingZeros++
                require(leadingZeros <= 31)
            }
            return if (leadingZeros == 0) 0 else (1 shl leadingZeros) - 1 + readBits(leadingZeros)
        }

        fun readSignedExpGolomb(): Int {
            val code = readUnsignedExpGolomb()
            return if (code and 1 == 0) -(code / 2) else (code + 1) / 2
        }
    }
}

object Pocket3AnnexB {
    fun parse(data: ByteArray): List<Pocket3H264NalUnit> {
        if (data.size < 4) return emptyList()
        val starts = ArrayList<Pair<Int, Int>>()
        var index = 0
        while (index + 3 < data.size) {
            if (index + 4 <= data.size && data[index] == 0.toByte() && data[index + 1] == 0.toByte() &&
                data[index + 2] == 0.toByte() && data[index + 3] == 1.toByte()
            ) {
                starts += index to 4
                index += 4
            } else if (data[index] == 0.toByte() && data[index + 1] == 0.toByte() && data[index + 2] == 1.toByte()) {
                starts += index to 3
                index += 3
            } else {
                index++
            }
        }
        return starts.mapIndexedNotNull { position, (startCodeOffset, startCodeSize) ->
            val start = startCodeOffset + startCodeSize
            val end = starts.getOrNull(position + 1)?.first ?: data.size
            if (start >= end) null else {
                val nal = data.copyOfRange(start, end)
                Pocket3H264NalUnit(nal[0].toInt() and 0x1F, nal)
            }
        }
    }

    fun encode(nals: List<Pocket3H264NalUnit>): ByteArray {
        val size = nals.sumOf { 4 + it.bytes.size }
        val output = ByteArray(size)
        var offset = 0
        for (nal in nals) {
            output[offset + 3] = 1
            offset += 4
            nal.bytes.copyInto(output, offset)
            offset += nal.bytes.size
        }
        return output
    }
}

/** Retains SPS/PPS and emits only configured, IDR-synchronized access units. */
class Pocket3H264Stream {
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null
    private var waitingForIdr = true
    private var spsCount = 0L
    private var ppsCount = 0L
    private var idrCount = 0L
    private var accessUnitCount = 0L
    private var invalidMessageCount = 0L

    fun consume(message: ByteArray): Pocket3H264Result {
        val nals = Pocket3AnnexB.parse(message)
        if (nals.isEmpty()) {
            invalidMessageCount++
            return Pocket3H264Result(null, null, emptySet())
        }

        var parameterSetChanged = false
        for (nal in nals) {
            when (nal.type) {
                7 -> {
                    spsCount++
                    if (sps?.contentEquals(nal.bytes) != true) {
                        sps = nal.bytes.copyOf()
                        parameterSetChanged = true
                    }
                }
                8 -> {
                    ppsCount++
                    if (pps?.contentEquals(nal.bytes) != true) {
                        pps = nal.bytes.copyOf()
                        parameterSetChanged = true
                    }
                }
            }
        }

        val configuration = if (parameterSetChanged && sps != null && pps != null) {
            waitingForIdr = true
            Pocket3H264DecoderConfiguration(sps!!.copyOf(), pps!!.copyOf())
        } else null

        val sampleNals = nals.filter { it.type != 7 && it.type != 8 && it.type != 9 }
        val hasVcl = sampleNals.any { it.type in 1..5 }
        if (!hasVcl || sps == null || pps == null) {
            return Pocket3H264Result(configuration, null, nals.mapTo(linkedSetOf()) { it.type })
        }

        val isIdr = sampleNals.any { it.type == 5 }
        accessUnitCount++
        if (isIdr) idrCount++
        if (waitingForIdr && !isIdr) {
            return Pocket3H264Result(configuration, null, nals.mapTo(linkedSetOf()) { it.type })
        }
        waitingForIdr = false
        return Pocket3H264Result(
            configuration,
            Pocket3H264AccessUnit(Pocket3AnnexB.encode(sampleNals), isIdr),
            nals.mapTo(linkedSetOf()) { it.type },
        )
    }

    fun requireIdr() {
        waitingForIdr = true
    }

    fun currentConfiguration(): Pocket3H264DecoderConfiguration? =
        if (sps != null && pps != null) Pocket3H264DecoderConfiguration(sps!!.copyOf(), pps!!.copyOf()) else null

    fun reset() {
        sps = null
        pps = null
        waitingForIdr = true
        spsCount = 0
        ppsCount = 0
        idrCount = 0
        accessUnitCount = 0
        invalidMessageCount = 0
    }

    fun stats() = Pocket3H264Stats(spsCount, ppsCount, idrCount, accessUnitCount, invalidMessageCount)
}
