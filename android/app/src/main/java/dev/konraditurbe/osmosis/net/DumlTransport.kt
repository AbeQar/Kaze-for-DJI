package dev.konraditurbe.osmosis.net

import dev.konraditurbe.osmosis.duml.DjiMessage
import dev.konraditurbe.osmosis.duml.DumlAckWindow
import dev.konraditurbe.osmosis.duml.DumlBytes
import dev.konraditurbe.osmosis.duml.DumlRoutingHeader
import dev.konraditurbe.osmosis.duml.DumlTransportHeader
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import kotlin.random.Random

/**
 * The DUML-over-UDP datalink itself: socket, session, sequencing and framing. Everything a camera and
 * a drone do **identically**, with no idea what a media manifest is.
 *
 * Wire layers per packet: `[8B transport hdr][12B routing hdr][DUML frame]`.
 *
 * The datalink is a **sliding-window transport**, and that is the part worth being careful with — every
 * packet carries `[r0-1 = ack][r2-3 = my own seq]`, and both live in *our own* command-seq space. Two
 * separate outages traced back to getting that wrong (see [routingHeader]), in the same asymmetric way
 * each time: reads and keepalive keep flowing while WRITES are silently dropped by the receive window,
 * so the session looks perfectly healthy and answers nothing.
 *
 * Blocking; call on a background thread. The process must already be bound to the device's network.
 */
class DumlTransport(
    private val log: (String) -> Unit,
    val port: Int,
    /**
     * Bind the local socket to [port] as well. DJI Fly talks to a drone **symmetrically** — every one of
     * the 138k packets in the Mavic capture is 9003→9003. A camera answers an ephemeral source port
     * happily, so this was never needed for one; a drone that routes command replies by port would send
     * ours nowhere, which matches the symptom exactly (session up, beacons streaming, no command answered).
     */
    private val bindLocalPort: Boolean = false,
    /** Byte 10 of the routing header is `0x60` on the commands DJI Fly sends a Mavic, `0x00` for a camera. */
    private val droneRouting: Boolean = false,
) {

    var sessionId = 0
        private set

    private var udpSeq = 0
    private var dumlSeq = 0xA000
    private var cmdCounter = 0
    private var camChannel = 0xB887

    /**
     * The base sequence proposed in the handshake, and the start of our own send-seq space.
     *
     * **Randomised per session, and it matters.** This was a constant (`0x87b8`) baked into the
     * handshake payload, so every session on every device opened with the same base — and an
     * independent reverse-engineering of this transport reports that reusing a fixed base across
     * connects can leave the peer's session state wedged, which looks exactly like a link that
     * handshakes and then answers nothing. The official app draws a fresh one each connect.
     *
     * Kept 8-aligned because the send seq advances in steps of 8.
     *
     * It also explains a red herring: the peer echoes this value back, so the "channel" we appeared
     * to learn from it was only ever our own constant coming home. With a random base, a log showing
     * the same number for both really does mean the echo, not a coincidence.
     */
    var baseSeq = 0xB887
        private set

    /**
     * Pocket 3 / Mimo transport-window state. A pktType-0x04 ACK has three 8-byte groups:
     *
     *   group 1 = latest received pktType-0x02 sequence, duplicated
     *   group 2 = latest received pktType-0x03 sequence, duplicated
     *   group 3 = camera's ACK of our TX sequence, then our latest TX sequence
     *
     * This layout is capture-derived from the clean Pocket 3 Mimo pcaps. v0.11 incorrectly kept
     * groups 2/3 pinned to the session base, which let unsolicited telemetry continue while the
     * command/reply window eventually wedged.
     */
    private var rxType2Seq = 0
    private var rxType3Seq = 0
    private var peerAckedTxSeq = 0
    private var lastTxSeq = 0
    private var seenType2 = false
    private var seenType3 = false

    private var msgId51 = 0
    private var seq51 = 0

    private lateinit var sock: DatagramSocket
    private lateinit var peer: InetAddress

    /** The last packet handed to the socket — kept so a query can be logged verbatim and diffed. */
    var lastSentPacket: ByteArray? = null
        private set

    val peerAddress: InetAddress? get() = if (::peer.isInitialized) peer else null
    val peerIp: String? get() = peerAddress?.hostAddress

    /** The peer's own sequence channel, learned from bytes 8–9 of everything it sends. */
    val cameraChannel: Int get() = camChannel

    /** Our current send sequence — for diagnosing window drift. See [routingHeader]. */
    val seq: Int get() = udpSeq

    /** Capture-derived ACK-window cursors. Diagnostic only. */
    val rxType2Cursor: Int get() = rxType2Seq
    val rxType3Cursor: Int get() = rxType3Seq
    val peerAckedTxCursor: Int get() = peerAckedTxSeq
    val lastTxCursor: Int get() = lastTxSeq

    /** Approximate number of 8-step TX sequence slots still outstanding at the camera. */
    val txAckLagSlots: Int get() = (((lastTxSeq - peerAckedTxSeq) and 0xFFFF) / 8)

    /** Number of DUML commands emitted in this session. Diagnostic only. */
    val commandCount: Int get() = cmdCounter

    val isOpen: Boolean get() = ::sock.isInitialized && !sock.isClosed

    val localPort: Int get() = if (::sock.isInitialized) sock.localPort else -1

    // ---- lifecycle ---------------------------------------------------------------------------------

    /** Create the socket and pick a session id. Does not talk to the peer yet. */
    fun open(ip: String) {
        peer = InetAddress.getByName(ip)
        sock = if (bindLocalPort) {
            runCatching { DatagramSocket(port) }
                .onFailure { log("datalink: local udp/$port unavailable (${it.message}) — falling back") }
                .getOrElse { DatagramSocket() }
        } else DatagramSocket()
        sock.soTimeout = 200
        sessionId = Random.nextInt(0x1000, 0xFFFE)
        // Fresh base per connect, 8-aligned — see [baseSeq]. camChannel starts here because until the
        // peer says otherwise, the only sequence space either side knows about is the one we proposed.
        baseSeq = Random.nextInt(0x1000, 0xF000) and 0xFFF8
        camChannel = baseSeq

        // Every transport/session counter is per connection. v0.11 accidentally carried several of
        // these across reconnects, which made diagnostics confusing and is not how Mimo starts a
        // fresh session.
        // Handshake transport packets start from zero; syncSeqToPeerChannel() switches into the
        // camera's reliable sequence space after the initial drain.
        udpSeq = 0
        dumlSeq = 0xA000
        cmdCounter = 0
        msgId51 = 0
        seq51 = 0

        rxType2Seq = baseSeq
        rxType3Seq = baseSeq
        peerAckedTxSeq = baseSeq
        lastTxSeq = baseSeq
        seenType2 = false
        seenType3 = false
        lastSentPacket = null
    }

    /**
     * Send [payload] as a pktType-`0x00` frame until the peer answers with one, up to [attempts] times.
     * Returns the accepted reply datagram, or null if nothing ever came back — which is how the caller
     * tells "no media" apart from "wrong UDP port for this device" and retries the alternate.
     */
    fun handshake(payload: ByteArray, attempts: Int = 20): ByteArray? {
        repeat(attempts) {
            sendRaw(0x00, payload)
            for (r in recvAll(350)) if (r.size >= 8 && (r[6].toInt() and 0xFF) == 0x00) return r
        }
        return null
    }

    /**
     * Start our send sequence at the peer's channel + 8, once heartbeats have taught us the channel.
     * Called after draining the peer's first packets.
     */
    fun syncSeqToPeerChannel() {
        udpSeq = (camChannel + 8) and 0xFFFF
        lastTxSeq = camChannel
        // Before our first reliable command there cannot be an outstanding local TX window.
        peerAckedTxSeq = camChannel
    }

    fun close() {
        runCatching { if (::sock.isInitialized) sock.close() }
    }

    // ---- send --------------------------------------------------------------------------------------

    /** Send a UDP packet, swallowing a send failure. When the AP drops or the network is unbound
     *  mid-session `sock.send` throws ENETUNREACH — expected on a dying link, and it must NEVER crash
     *  the keep-alive thread (it once did). */
    private fun sendPacket(pkt: ByteArray): Boolean {
        lastSentPacket = pkt
        return runCatching { sock.send(DatagramPacket(pkt, pkt.size, peer, port)) }.isSuccess
    }

    /** Record the transport sequence of a successfully emitted non-ACK frame. */
    private fun noteTx(seqSent: Int) {
        lastTxSeq = seqSent and 0xFFFF
    }

    fun sendRaw(pktType: Int, payload: ByteArray) {
        val seqSent = udpSeq
        val pkt = udpHeader(pktType, payload.size) + payload
        if (sendPacket(pkt)) {
            // pktType-00 is handshake/setup traffic and is not part of the three reliable windows
            // represented by pktType-04. Keep lastTxSeq on the reliable-channel baseline until sync.
            if (pktType != 0x00) noteTx(seqSent)
            advance()
        }
    }

    /**
     * Pocket 3/Mimo pktType-0x04 transport acknowledgement. This controller uses the exact three
     * moving sequence windows observed in the clean Pocket 3 captures; see [DumlAckWindow].
     *
     * Sent with transport seq 0, like Mimo.
     */
    fun sendAck() {
        val payload = DumlAckWindow.encode(
            rxType2Sequence = rxType2Seq,
            rxType3Sequence = rxType3Seq,
            peerAckedTxSequence = peerAckedTxSeq,
            lastTxSequence = lastTxSeq,
        )

        // Mimo sends pktType-0x04 ACKs with transport seq 0 and does not consume our TX sequence.
        val old = udpSeq
        udpSeq = 0
        val hdr = udpHeader(0x04, payload.size)
        udpSeq = old
        sendPacket(hdr + payload)
    }

    fun sendDuml(
        set: Int, cmd: Int, payload: ByteArray,
        receiverType: Int, receiverId: Int, cmdType: Int = 2,
    ) {
        cmdCounter++
        val rt = routingHeader()
        val target = 0x02 or (((receiverId shl 5) or receiverType) shl 8)
        val type = (cmdType shl 5) or (set shl 8) or (cmd shl 16)
        val duml = DjiMessage(target, dumlSeq, type, payload).encode()
        dumlSeq = (dumlSeq + 1) and 0xFFFF
        val seqSent = udpSeq
        val pkt = udpHeader(0x05, rt.size + duml.size) + rt + duml
        if (sendPacket(pkt)) {
            noteTx(seqSent)
            advance()
        }
    }

    /**
     * Send a frame at a raw [target] with a caller-chosen sender byte — the drone uplink uses sender
     * `0x01`, not the `0x02` [sendDuml] hardcodes.
     *
     * For a `0x51` frame both of its sequence fields are stamped fresh. The outer wrapper carries 22
     * trailing bytes after the inner frame and `trailing[5]` is a counter (`…39fdb2ae 02 NN …`). Captured
     * frames are replayed verbatim, so those counters arrive frozen at whatever DJI Fly used — the
     * identity beacon at `0x0a`, the session-open at `0x01`. Sent in our order that counter goes
     * BACKWARDS, exactly the shape a replay check rejects. It sits outside the inner frame, so
     * re-stamping it monotonically leaves the inner CRC untouched.
     */
    fun sendDumlRaw(target: Int, set: Int, cmd: Int, payload: ByteArray, cmdType: Int = 0) {
        cmdCounter++
        var pl = payload
        if (set == 0x51 && pl.size >= 13 && (pl[0].toInt() and 0xFF) == 0x55) {
            val innerLen = (pl[1].toInt() and 0xFF) or ((pl[2].toInt() and 0x03) shl 8)
            if (innerLen in 13..pl.size && pl.size >= innerLen + 6) {
                pl = pl.copyOf()
                pl[innerLen + 5] = (++seq51 and 0xFF).toByte()
            }
        }
        val rt = routingHeader()
        val type = (cmdType shl 5) or (set shl 8) or (cmd shl 16)
        val id = if (set == 0x51) (++msgId51 and 0xFFFF) else 0x000A
        val duml = DjiMessage(target, id, type, pl).encode()
        val seqSent = udpSeq
        val pkt = udpHeader(0x05, rt.size + duml.size) + rt + duml
        if (sendPacket(pkt)) {
            noteTx(seqSent)
            advance()
        }
    }

    // ---- receive -----------------------------------------------------------------------------------

    /** Update the three Mimo-style transport windows from one received datagram. */
    private fun observeTransportState(data: ByteArray) {
        val transportHeader = DumlTransportHeader.decode(data) ?: return
        val pktType = transportHeader.packetType
        val transportSeq = transportHeader.sequence

        // Preserve Osmosis' proven channel learning: the peer channel is carried at bytes 8-9 of
        // incoming frames, not in the transport header's sequence field.
        if (data.size >= 10) {
            val channel = DumlBytes.uint16Le(data, 8)
            if (channel != 0) camChannel = channel
        }

        if (transportSeq != 0) {
            when (pktType) {
                0x02 -> { rxType2Seq = transportSeq; seenType2 = true }
                0x03 -> { rxType3Seq = transportSeq; seenType3 = true }
            }
        }

        // pktType-01 is the peer's 34-byte window-status frame. Its three groups mirror the same
        // transport families. Group 3 is especially important: it tells us which of OUR TX seqs the
        // camera has accepted. Groups 1/2 are used only to seed a cursor before we have directly seen
        // a type-02/03 packet ourselves.
        if (pktType == 0x01 && data.size >= 34) {
            val statusType2 = DumlBytes.uint16Le(data, 10)
            val statusType3 = DumlBytes.uint16Le(data, 18)
            // Group 3 first field is the peer-ACK cursor. In the long Pocket 3/Mimo capture both
            // group-3 fields were equal in every camera status frame, but use the semantic ACK field.
            val statusAckTx = DumlBytes.uint16Le(data, 24)
            if (!seenType2 && statusType2 != 0) rxType2Seq = statusType2
            if (!seenType3 && statusType3 != 0) rxType3Seq = statusType3
            if (statusAckTx != 0) peerAckedTxSeq = statusAckTx
        }
    }

    fun recvAll(durationMs: Long): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        val deadline = System.nanoTime() + durationMs * 1_000_000
        val buf = ByteArray(65536)
        while (System.nanoTime() < deadline) {
            try {
                val p = DatagramPacket(buf, buf.size)
                sock.receive(p)
                val data = p.data.copyOf(p.length)
                out.add(data)
                observeTransportState(data)
            } catch (_: java.net.SocketTimeoutException) {
                // keep polling until the deadline
            } catch (_: Exception) {
                break
            }
        }
        return out
    }

    /**
     * Short receive pump for live-control loops. Unlike [recvAll], this temporarily uses a very
     * small socket timeout so the caller can drain telemetry, update the live window cursors, and emit transport
     * ACKs without stalling a 20 Hz control loop when traffic briefly goes quiet.
     */
    fun recvBurst(durationMs: Long, perReceiveTimeoutMs: Int = 4): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        val deadline = System.nanoTime() + durationMs * 1_000_000
        val buf = ByteArray(65536)
        val oldTimeout = sock.soTimeout
        sock.soTimeout = perReceiveTimeoutMs.coerceAtLeast(1)
        try {
            while (System.nanoTime() < deadline) {
                try {
                    val p = DatagramPacket(buf, buf.size)
                    sock.receive(p)
                    val data = p.data.copyOf(p.length)
                    out.add(data)
                    observeTransportState(data)
                } catch (_: java.net.SocketTimeoutException) {
                    // Normal for this short polling helper.
                }
            }
        } finally {
            sock.soTimeout = oldTimeout
        }
        return out
    }

    // ---- headers -----------------------------------------------------------------------------------

    private fun udpHeader(pktType: Int, payloadLen: Int): ByteArray =
        DumlTransportHeader.encode(pktType, payloadLen, sessionId, udpSeq)

    /**
     * Command routing header (pkt `0x05`):
     *
     *   `[r0-1 = peer ACK of our TX window][r2-3 = this packet's TX seq]`
     *
     * v0.12 still used `r0 = seq - 8`. The long Pocket 3/Mimo reference capture disproves that:
     * under bursts, Mimo deliberately keeps r0 behind while r2 advances, and r0 tracks the camera's
     * pktType-01 group-3 ACK of our transmit sequence. Across the long capture, r0 matched the most
     * recently observed camera ACK for >98% of app pktType-05 packets; the small remainder are races
     * where capture ordering beat the app's receive processing by one or a few packets.
     *
     * This distinction exactly matches the v0.12 failure signature: peerAckTx froze, but v0.12 kept
     * advertising `seq-8` in r0 as if the camera had accepted packets it had not. The receive window
     * then stopped accepting request/control traffic while unsolicited telemetry continued.
     */
    private fun routingHeader(): ByteArray =
        DumlRoutingHeader.encode(
            sequence = udpSeq,
            peerAck = peerAckedTxSeq,
            commandCounter = cmdCounter,
            drone = droneRouting,
        )

    private fun advance() { udpSeq = (udpSeq + 8) and 0xFFFF }

}
