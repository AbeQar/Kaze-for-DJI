import Foundation
import Network

/// iOS port of the frozen Pocket3GimbalTest v0.14.3 DUML-over-UDP transport.
/// The sequence/ACK/window behavior intentionally mirrors the working Android implementation.
final class DumlTransport {
    static let defaultPort: UInt16 = 9004

    private let log: (String) -> Void
    private let port: UInt16

    private(set) var sessionId = 0
    private(set) var baseSeq = 0
    private(set) var cameraChannel = 0
    private(set) var udpSeq = 0
    private(set) var dumlSeq = 0xA000
    private(set) var cmdCounter = 0
    private(set) var lastHandshakeAttemptCount = 0

    private(set) var rxType2Seq = 0
    private(set) var rxType3Seq = 0
    private(set) var peerAckedTxSeq = 0
    private(set) var lastTxSeq = 0

    private(set) var inboundDatagramCount = 0
    private(set) var rejectedSessionDatagramCount = 0
    private(set) var lastInboundNs: UInt64 = 0
    private(set) var sawBringUp0405 = false
    private(set) var sawBringUpType02Video = false
    private(set) var sawBringUp0081 = false
    private(set) var sawBringUp0088 = false
    private(set) var sawBringUpOtherValidCameraDuml = false

    private var seenType2 = false
    private var seenType3 = false

    private var pipe: NWDatagramPipe?

    var isOpen: Bool { pipe?.isUsable ?? false }

    var localSourcePort: UInt16? { pipe?.localSourcePort }

    var txAckLagSlots: Int {
        (((lastTxSeq - peerAckedTxSeq) & 0xFFFF) / 8)
    }

    init(log: @escaping (String) -> Void, port: UInt16 = DumlTransport.defaultPort) {
        self.log = log
        self.port = port
    }

    func open(ip: String) throws {
        close()

        sessionId = Int.random(in: 0x1000..<0xFFFE)
        baseSeq = Int.random(in: 0x1000..<0xF000) & 0xFFF8
        cameraChannel = baseSeq

        udpSeq = 0
        dumlSeq = 0xA000
        cmdCounter = 0
        lastHandshakeAttemptCount = 0

        rxType2Seq = baseSeq
        rxType3Seq = baseSeq
        peerAckedTxSeq = baseSeq
        lastTxSeq = baseSeq
        seenType2 = false
        seenType3 = false
        inboundDatagramCount = 0
        rejectedSessionDatagramCount = 0
        lastInboundNs = 0
        sawBringUp0405 = false
        sawBringUpType02Video = false
        sawBringUp0081 = false
        sawBringUp0088 = false
        sawBringUpOtherValidCameraDuml = false

        let newPipe = NWDatagramPipe(host: ip, port: port, log: log)
        pipe = newPipe

        // iOS-specific wait so the Local Network permission sheet has time to appear.
        // DJI's on-wire handshake timing below is unchanged.
        try newPipe.start(timeout: 10.0)
    }

    func close() {
        pipe?.stop()
        pipe = nil
    }

    func handshake(payload: Data, attempts: Int = 20) -> Data? {
        lastHandshakeAttemptCount = 0
        for attemptIndex in 0..<attempts {
            guard isOpen else { return nil }
            lastHandshakeAttemptCount = attemptIndex + 1
            sendRaw(pktType: 0x00, payload: payload)
            let replies = recvAll(durationMs: 350)
            guard isOpen else { return nil }
            if let reply = replies.first(where: { $0.count >= 8 && $0[6] == 0x00 }) {
                return reply
            }
        }
        return nil
    }

    func syncSeqToPeerChannel() {
        udpSeq = (cameraChannel + 8) & 0xFFFF
        lastTxSeq = cameraChannel
        peerAckedTxSeq = cameraChannel
    }

    func sendRaw(pktType: UInt8, payload: Data) {
        let seqSent = udpSeq
        let packet = DumlTransportHeader.encode(
            packetType: pktType,
            payloadLength: payload.count,
            sessionId: sessionId,
            sequence: udpSeq
        ) + payload

        if sendPacket(packet) {
            if pktType != 0x00 {
                lastTxSeq = seqSent & 0xFFFF
            }
            advance()
        }
    }

    func sendAck() {
        let payload = DumlAckWindow.encode(
            rxType2Sequence: rxType2Seq,
            rxType3Sequence: rxType3Seq,
            peerAckedTxSequence: peerAckedTxSeq,
            lastTxSequence: lastTxSeq
        )

        let header = DumlTransportHeader.encode(
            packetType: 0x04,
            payloadLength: payload.count,
            sessionId: sessionId,
            sequence: 0
        )

        _ = sendPacket(header + payload)
    }

    func sendDuml(
        set: UInt8,
        cmd: UInt8,
        payload: Data,
        receiverType: Int,
        receiverId: Int,
        cmdType: Int = 2
    ) {
        cmdCounter += 1

        let routing = DumlRoutingHeader.encode(
            sequence: udpSeq,
            peerAck: peerAckedTxSeq,
            commandCounter: cmdCounter
        )

        let target = UInt16(
            0x02 |
            (((receiverId << 5) | receiverType) << 8)
        )

        let type =
            UInt32(cmdType << 5) |
            (UInt32(set) << 8) |
            (UInt32(cmd) << 16)

        let duml = DumlMessage(
            target: target,
            id: UInt16(dumlSeq),
            type: type,
            payload: payload
        ).encode()

        dumlSeq = (dumlSeq + 1) & 0xFFFF

        let seqSent = udpSeq
        let body = routing + duml
        let packet = DumlTransportHeader.encode(
            packetType: 0x05,
            payloadLength: body.count,
            sessionId: sessionId,
            sequence: udpSeq
        ) + body

        if sendPacket(packet) {
            lastTxSeq = seqSent & 0xFFFF
            advance()
        }
    }

    func recvAll(durationMs: Int) -> [Data] {
        guard let pipe else { return [] }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(durationMs) * 1_000_000
        var out: [Data] = []

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let batch = pipe.drainIncoming()
            if !batch.isEmpty {
                for data in batch {
                    guard acceptInboundDatagram(data) else { continue }
                    observeTransportState(data)
                    out.append(data)
                }
            } else {
                Thread.sleep(forTimeInterval: 0.004)
            }
        }

        return out
    }

    func recvBurst(durationMs: Int = 12) -> [Data] {
        guard let pipe else { return [] }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(durationMs) * 1_000_000
        var out: [Data] = []

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let batch = pipe.drainIncoming()
            if !batch.isEmpty {
                for data in batch {
                    guard acceptInboundDatagram(data) else { continue }
                    observeTransportState(data)
                    out.append(data)
                }
            } else {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        return out
    }

    private func acceptInboundDatagram(_ data: Data) -> Bool {
        guard DumlTransportHeader.belongsToSession(data, sessionId: sessionId) else {
            rejectedSessionDatagramCount += 1
            return false
        }
        return true
    }

    private func observeTransportState(_ data: Data) {
        inboundDatagramCount += 1
        lastInboundNs = DispatchTime.now().uptimeNanoseconds

        guard let transportHeader = DumlTransportHeader.decode(data) else { return }

        let pktType = transportHeader.packetType
        let transportSeq = transportHeader.sequence

        if pktType == 0x02 {
            sawBringUpType02Video = true
        }

        for frame in DumlFrameScanner.scan(data) {
            switch (frame.set, frame.cmd) {
            case (0x04, 0x05):
                sawBringUp0405 = true
            case (0x00, 0x81):
                sawBringUp0081 = true
            case (0x00, 0x88):
                sawBringUp0088 = true
            default:
                sawBringUpOtherValidCameraDuml = true
            }
        }

        if data.count >= 10 {
            let channel = DumlBytes.uint16LE(data, at: 8)
            if channel != 0 {
                cameraChannel = channel
            }
        }

        if transportSeq != 0 {
            switch pktType {
            case 0x02:
                rxType2Seq = transportSeq
                seenType2 = true
            case 0x03:
                rxType3Seq = transportSeq
                seenType3 = true
            default:
                break
            }
        }

        if pktType == 0x01, data.count >= 34 {
            let statusType2 = DumlBytes.uint16LE(data, at: 10)
            let statusType3 = DumlBytes.uint16LE(data, at: 18)
            let statusAckTx = DumlBytes.uint16LE(data, at: 24)

            if !seenType2, statusType2 != 0 {
                rxType2Seq = statusType2
            }
            if !seenType3, statusType3 != 0 {
                rxType3Seq = statusType3
            }
            if statusAckTx != 0 {
                peerAckedTxSeq = statusAckTx
            }
        }
    }

    private func sendPacket(_ data: Data) -> Bool {
        guard let pipe else { return false }
        return pipe.send(data)
    }

    private func advance() {
        udpSeq = (udpSeq + 8) & 0xFFFF
    }

}

private final class NWDatagramPipe {
    private let connection: NWConnection
    private let callbackQueue = DispatchQueue(label: "Pocket3.NWDatagramPipe")
    private let lock = NSLock()
    private let log: (String) -> Void

    private var incoming: [Data] = []
    private var stopped = false
    private var ready = false
    private var failureText: String?
    private var boundLocalPort: UInt16?

    var isUsable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready && !stopped
    }

    var localSourcePort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return boundLocalPort
    }

    init(host: String, port: UInt16, log: @escaping (String) -> Void) {
        self.log = log

        let parameters = NWParameters.udp
        parameters.requiredInterfaceType = .wifi

        self.connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters
        )
    }

    func start(timeout: TimeInterval) throws {
        let semaphore = DispatchSemaphore(value: 0)

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .ready:
                self.lock.lock()
                self.ready = true
                if case .hostPort(_, let port)? = self.connection.currentPath?.localEndpoint {
                    self.boundLocalPort = port.rawValue
                }
                self.lock.unlock()
                semaphore.signal()

            case .failed(let error):
                self.lock.lock()
                self.failureText = error.localizedDescription
                self.stopped = true
                self.lock.unlock()
                semaphore.signal()

            case .cancelled:
                self.lock.lock()
                self.stopped = true
                self.lock.unlock()
                semaphore.signal()

            default:
                break
            }
        }

        connection.start(queue: callbackQueue)

        let result = semaphore.wait(timeout: .now() + timeout)
        guard result == .success else {
            connection.cancel()
            throw DatalinkError.network("UDP connection did not become ready within \(String(format: "%.1f", timeout)) s")
        }

        lock.lock()
        let ok = ready && !stopped
        let failure = failureText
        lock.unlock()

        guard ok else {
            throw DatalinkError.network(failure ?? "UDP connection failed")
        }

        scheduleReceive()
    }

    func send(_ data: Data) -> Bool {
        lock.lock()
        let canSend = ready && !stopped
        lock.unlock()

        guard canSend else { return false }

        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, let error else { return }

            self.lock.lock()
            let intentionalTeardown = self.stopped
            self.lock.unlock()

            // NWConnection reports Operation canceled for sends completed while
            // an intentional disconnect is closing the socket. That is teardown,
            // not a transport failure, so keep it out of the user-facing log.
            if !intentionalTeardown {
                self.log("UDP send error: \(error.localizedDescription)")
            }
        })
        return true
    }

    func drainIncoming() -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        guard !incoming.isEmpty else { return [] }
        let batch = incoming
        incoming.removeAll(keepingCapacity: true)
        return batch
    }

    func stop() {
        lock.lock()
        stopped = true
        ready = false
        incoming.removeAll()
        lock.unlock()

        connection.cancel()
    }

    private func scheduleReceive() {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard let self else { return }

            if let content, !content.isEmpty {
                self.lock.lock()
                if !self.stopped {
                    self.incoming.append(content)
                }
                self.lock.unlock()
            }

            self.lock.lock()
            let shouldContinue = !self.stopped && error == nil
            self.lock.unlock()

            if let error {
                self.log("UDP receive error: \(error.localizedDescription)")
            }

            if shouldContinue {
                self.scheduleReceive()
            }
        }
    }
}

enum DatalinkError: Error, CustomStringConvertible {
    case network(String)

    var description: String {
        switch self {
        case .network(let text):
            return text
        }
    }
}

private extension Data {
    static func + (lhs: Data, rhs: Data) -> Data {
        var out = lhs
        out.append(rhs)
        return out
    }
}
