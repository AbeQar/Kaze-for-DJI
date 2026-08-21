package com.pocket3.gimbaltest

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import dev.konraditurbe.osmosis.duml.DjiCrc
import dev.konraditurbe.osmosis.duml.DjiMessage
import dev.konraditurbe.osmosis.duml.DumlAckWindow
import dev.konraditurbe.osmosis.duml.DumlFrameScanner
import dev.konraditurbe.osmosis.duml.DumlRoutingHeader
import dev.konraditurbe.osmosis.duml.DumlTransportHeader
import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class SharedProtocolVectorTest {
    @Test
    fun sharedCrcVectors() {
        for (vector in ProtocolVectorLoader.load("crc", "crc.json")) {
            when (vector.operation) {
                "crc8.compute" -> assertEquals(
                    vector.id,
                    vector.expectedHexInt("crcHex"),
                    DjiCrc.computeCrc8(vector.inputBytes("dataHex")),
                )

                "crc16.compute" -> assertEquals(
                    vector.id,
                    vector.expectedHexInt("crcHex"),
                    DjiCrc.computeCrc16(vector.inputBytes("dataHex")),
                )

                "duml.rejectCorruptedFrame" -> {
                    assertFalse(vector.id, vector.expectedBoolean("valid"))
                    assertEquals("crc16-mismatch", vector.expectedString("errorCategory"))
                    try {
                        DjiMessage.fromBytes(vector.inputBytes("frameHex"))
                        fail("${vector.id}: corrupted frame was accepted")
                    } catch (error: IllegalArgumentException) {
                        assertEquals(vector.id, "Bad CRC", error.message)
                    }
                }

                else -> fail("${vector.id}: unsupported CRC operation ${vector.operation}")
            }
        }
    }

    @Test
    fun sharedTransportVectors() {
        for (vector in ProtocolVectorLoader.load("transport", "transport.json")) {
            when (vector.operation) {
                "duml.encode" -> {
                    val type = vector.inputHexInt("flagsHex") or
                        (vector.inputHexInt("commandSetHex") shl 8) or
                        (vector.inputHexInt("commandIdHex") shl 16)
                    val message = DjiMessage(
                        target = vector.inputHexInt("targetHex"),
                        id = vector.inputHexInt("idHex"),
                        type = type,
                        payload = vector.inputBytes("payloadHex"),
                    )
                    assertEquals(vector.id, vector.expectedString("frameHex"), message.encode().hexString())
                }

                "duml.decode" -> {
                    val message = DjiMessage.fromBytes(vector.inputBytes("frameHex"))
                    assertEquals(vector.id, vector.expectedHexInt("targetHex"), message.target)
                    assertEquals(vector.id, vector.expectedHexInt("idHex"), message.id)
                    assertEquals(vector.id, vector.expectedHexInt("flagsHex"), message.flags)
                    assertEquals(vector.id, vector.expectedHexInt("commandSetHex"), message.cmdSet)
                    assertEquals(vector.id, vector.expectedHexInt("commandIdHex"), message.cmdId)
                    assertEquals(vector.id, vector.expectedString("payloadHex"), message.payload.hexString())
                }

                "transport.udpHeader" -> {
                    val header = DumlTransportHeader.encode(
                        packetType = vector.inputHexInt("packetTypeHex"),
                        payloadLength = vector.inputInt("payloadLength"),
                        sessionId = vector.inputHexInt("sessionIdHex"),
                        sequence = vector.inputHexInt("sequenceHex"),
                    )
                    assertEquals(vector.id, vector.expectedString("headerHex"), header.hexString())
                    val fields = DumlTransportHeader.decode(header)
                        ?: error("${vector.id}: header did not parse")
                    assertEquals(vector.id, header.size + vector.inputInt("payloadLength"), fields.totalLength)
                    assertEquals(vector.id, vector.inputHexInt("sessionIdHex"), fields.sessionId)
                    assertEquals(vector.id, vector.inputHexInt("sequenceHex"), fields.sequence)
                    assertEquals(vector.id, vector.inputHexInt("packetTypeHex"), fields.packetType)
                }

                "transport.ackPayload" -> {
                    val payload = DumlAckWindow.encode(
                        rxType2Sequence = vector.inputHexInt("rxType2SequenceHex"),
                        rxType3Sequence = vector.inputHexInt("rxType3SequenceHex"),
                        peerAckedTxSequence = vector.inputHexInt("peerAckedTxSequenceHex"),
                        lastTxSequence = vector.inputHexInt("lastTxSequenceHex"),
                    )
                    assertEquals(vector.id, vector.expectedString("payloadHex"), payload.hexString())
                }

                "transport.routingHeader" -> {
                    val header = DumlRoutingHeader.encode(
                        sequence = vector.inputHexInt("sequenceHex"),
                        peerAck = vector.inputHexInt("peerAckHex"),
                        commandCounter = vector.inputHexInt("commandCounterHex"),
                        drone = vector.inputBoolean("drone"),
                    )
                    assertEquals(vector.id, vector.expectedString("headerHex"), header.hexString())
                    val fields = DumlRoutingHeader.decode(header)
                        ?: error("${vector.id}: routing header did not parse")
                    assertEquals(vector.id, vector.inputHexInt("sequenceHex"), fields.sequence)
                    assertEquals(vector.id, vector.inputHexInt("peerAckHex"), fields.peerAck)
                    assertEquals(vector.id, vector.inputHexInt("commandCounterHex"), fields.commandCounter)
                    assertEquals(vector.id, 0x00, fields.routingClass)
                }

                else -> fail("${vector.id}: unsupported transport operation ${vector.operation}")
            }
        }
    }

    @Test
    fun sharedFrameScannerValidation() {
        val decodeVector = ProtocolVectorLoader.load("transport", "transport.json")
            .firstOrNull { it.operation == "duml.decode" }
            ?: error("Canonical DUML decode vector is required")
        val validFrame = decodeVector.inputBytes("frameHex")

        val scanned = DumlFrameScanner.scan(validFrame)
        assertEquals(decodeVector.id, 1, scanned.size)
        assertEquals(decodeVector.id, decodeVector.expectedHexInt("commandSetHex"), scanned.first().commandSet)
        assertEquals(decodeVector.id, decodeVector.expectedHexInt("commandIdHex"), scanned.first().commandId)
        assertArrayEquals(decodeVector.id, decodeVector.expectedBytes("payloadHex"), scanned.first().payload)

        val truncated = validFrame.copyOf(validFrame.size - 1)
        assertTrue("Truncated frame must be rejected", DumlFrameScanner.scan(truncated).isEmpty())

        val corruptedVector = ProtocolVectorLoader.load("crc", "crc.json")
            .firstOrNull { it.operation == "duml.rejectCorruptedFrame" }
            ?: error("Canonical corrupted DUML vector is required")
        assertTrue(corruptedVector.id, DumlFrameScanner.scan(corruptedVector.inputBytes("frameHex")).isEmpty())

        val outerType = 0x40 or (0x51 shl 8) or (0x01 shl 16)
        val outer = DjiMessage(0x0702, 0x1234, outerType, validFrame).encode()
        val nested = DumlFrameScanner.scan(outer)
        assertEquals("Scanner must preserve byte-wise nested DUML discovery", 2, nested.size)
        assertTrue(
            nested.any {
                it.commandSet == scanned.first().commandSet &&
                    it.commandId == scanned.first().commandId &&
                    it.payload.contentEquals(scanned.first().payload)
            },
        )
    }

    @Test
    fun sharedGimbalVectors() {
        for (vector in ProtocolVectorLoader.load("gimbal", "gimbal.json")) {
            assertEquals(vector.id, 0x04, vector.expectedHexInt("commandSetHex"))

            when (vector.operation) {
                "gimbal.velocity" -> {
                    assertEquals(vector.id, 0x01, vector.expectedHexInt("commandIdHex"))
                    val payload = Pocket3GimbalCommands.velocityPayload(
                        vector.inputInt("pitchCommand"),
                        vector.inputInt("yawCommand"),
                    )
                    assertArrayEquals(vector.id, vector.expectedBytes("payloadHex"), payload)
                }

                "gimbal.recenter" -> {
                    assertEquals(vector.id, 0x4C, vector.expectedHexInt("commandIdHex"))

                    assertArrayEquals(
                        vector.id,
                        vector.expectedBytes("payloadHex"),
                        Pocket3GimbalCommands.recenterPayload(),
                    )
                }

                else -> fail("${vector.id}: unsupported gimbal operation ${vector.operation}")
            }
        }
    }

    @Test
    fun cameraVectorsRemainIosOnlyAtThisCheckpoint() {
        val vectors = ProtocolVectorLoader.load("camera", "camera.json")
        assertTrue("Expected canonical camera vectors", vectors.isNotEmpty())
        assertTrue(
            "Android must not claim camera-vector implementation in Stage 1",
            vectors.all { it.operation.startsWith("camera.") },
        )
    }
}

private data class ProtocolVector(
    val id: String,
    val operation: String,
    private val input: JsonObject,
    private val expected: JsonObject,
) {
    fun inputString(key: String): String = input.required(key).asString
    fun inputInt(key: String): Int = input.required(key).asInt
    fun inputBoolean(key: String): Boolean = input.required(key).asBoolean
    fun inputHexInt(key: String): Int = inputString(key).toInt(16)
    fun inputBytes(key: String): ByteArray = inputString(key).hexBytes()

    fun expectedString(key: String): String = expected.required(key).asString
    fun expectedBoolean(key: String): Boolean = expected.required(key).asBoolean
    fun expectedHexInt(key: String): Int = expectedString(key).toInt(16)
    fun expectedBytes(key: String): ByteArray = expectedString(key).hexBytes()
}

private object ProtocolVectorLoader {
    private val confirmedEvidence = setOf(
        "hardware-confirmed",
        "packet-capture-confirmed",
        "source-confirmed",
    )

    fun load(category: String, fileName: String): List<ProtocolVector> {
        val vectorFile = File(protocolRoot(), "test-vectors/$category/$fileName")
        check(vectorFile.isFile && vectorFile.canRead()) {
            "Canonical vector file not found at ${vectorFile.path}. " +
                "Set POCKET3_PROTOCOL_ROOT to the local Pocket3/Protocol repository."
        }

        val array = vectorFile.reader().use { JsonParser.parseReader(it).asJsonArray }
        check(array.size() > 0) { "${vectorFile.path}: expected a non-empty JSON array" }

        return array.map { element ->
            val objectValue = element.asJsonObject
            check(objectValue.required("schemaVersion").asInt == 1) {
                "${vectorFile.path}: unsupported schemaVersion"
            }
            check(objectValue.required("device").asString == "pocket3") {
                "${vectorFile.path}: unsupported device"
            }

            val evidence = objectValue.required("evidence").asJsonObject
            check(evidence.required("level").asString in confirmedEvidence) {
                "${vectorFile.path}: unconfirmed evidence cannot be an authoritative vector"
            }
            check(evidence.required("source").asString.isNotBlank()) {
                "${vectorFile.path}: evidence source is required"
            }

            ProtocolVector(
                id = objectValue.required("id").asString,
                operation = objectValue.required("operation").asString,
                input = objectValue.required("input").asJsonObject,
                expected = objectValue.required("expected").asJsonObject,
            )
        }
    }

    private fun protocolRoot(): File {
        val configured = System.getenv("POCKET3_PROTOCOL_ROOT")
        val candidate = if (!configured.isNullOrBlank()) {
            File(configured)
        } else {
            val workingDirectory = System.getProperty("user.dir")
                ?: error("JVM user.dir is unavailable; set POCKET3_PROTOCOL_ROOT explicitly.")
            val start = File(workingDirectory).canonicalFile
            val androidProjectRoot = generateSequence(start) { it.parentFile }
                .firstOrNull { File(it, "settings.gradle").isFile && File(it, "app").isDirectory }
                ?: error(
                    "Could not derive the Android project root from $start. " +
                        "Set POCKET3_PROTOCOL_ROOT to the local Pocket3/Protocol repository.",
                )
            File(androidProjectRoot, "../protocol")
        }.canonicalFile

        check(File(candidate, "test-vectors").isDirectory) {
            "Canonical Protocol repository not found at ${candidate.path}. " +
                "Set POCKET3_PROTOCOL_ROOT to the local Pocket3/Protocol repository."
        }
        return candidate
    }
}

private fun JsonObject.required(key: String) = get(key)
    ?: error("Missing required vector field: $key")

private fun String.hexBytes(): ByteArray {
    check(length % 2 == 0) { "Odd-length hex string: $this" }
    return ByteArray(length / 2) { index ->
        substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
}

private fun ByteArray.hexString(): String = joinToString("") { "%02X".format(it.toInt() and 0xFF) }
