import AVFoundation
import AVKit
import Combine
import CoreMedia
import os
import SwiftUI
import UIKit

/// Direct Pocket 3 pktType-0x02 H.264 receiver + low-latency display path.
///
/// The wire framing is copied from the physically proven Mac v4/v11 receiver:
/// - 8-byte DJI transport header
/// - 12-byte routing header
/// - media fragment begins at byte 20
/// - first fragment marker 00 00 01 FF
/// - little-endian assembled H.264 length at +4
/// - 8 bytes media metadata at +8
/// - Annex-B H.264 begins at +16
///
/// A captured raw fixture shows each completed DJI media message is either an
/// SPS/PPS configuration message or one video access unit. We still parse every
/// Annex-B NAL rather than assuming a fixed NAL layout.
final class Pocket3VideoOutput: NSObject, ObservableObject {
    @Published private(set) var isPictureInPictureActive = false
    @Published private(set) var isPictureInPicturePossible = false

    private let queue = DispatchQueue(label: "Pocket3.VideoOutput", qos: .userInteractive)
    private static let performanceLog = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "Pocket3Controller",
        category: "VideoPipeline"
    )
    private let onReady: () -> Void
    private let onUnavailable: () -> Void
    private let onForegroundPiPStopped: () -> Void
    private let onLog: (String) -> Void

    // Connection eligibility is intentionally independent of the media queue.
    // A disconnect must be able to revoke a queued frame immediately, before
    // that frame reaches the main queue and re-arms automatic PiP.
    private let sessionLock = NSLock()
    private var sessionGeneration = 0
    private var sessionActive = false
    static let automaticPiPMaximumSampleAgeMs: UInt64 = 1_500
    private static let freshnessCheckIntervalNs: UInt64 = 750_000_000

    private var current = Data()
    private var expectedLength: Int?
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForIDR = true
    private var readySignaled = false
    private var completedMessages = 0
    private var decodedSamples = 0
    private var droppedPartialMessages = 0

    // Rate-limited pipeline diagnostics. All fields except the layer lifecycle
    // entry points are owned by `queue`; main-thread observations are reported
    // back to that queue. Signposts are effectively free until enabled in
    // Instruments and make individual access units correlatable by sequence.
    private var diagnosticWindowStartNs: UInt64?
    private var diagnosticDatagrams = 0
    private var diagnosticMediaMessages = 0
    private var diagnosticAccessUnits = 0
    private var diagnosticEnqueues = 0
    private var diagnosticSampleBufferFailures = 0
    private var diagnosticPartialDrops = 0
    private var diagnosticInvalidMessages = 0
    private var diagnosticJoinedMidMessage = 0
    private var diagnosticSequenceDiscontinuities = 0
    private var diagnosticBackpressureEvents = 0
    private var diagnosticLayerFailures = 0
    private var diagnosticFlushes = 0
    private var diagnosticAttaches = 0
    private var diagnosticDetaches = 0
    private var diagnosticPendingEnqueues = 0
    private var diagnosticMaxPendingEnqueues = 0
    private var diagnosticLastTransportSequence: Int?
    private var diagnosticLastCompletionNs: UInt64?
    private var diagnosticLastAccessUnitNs: UInt64?
    private var diagnosticLastPTS: CMTime?
    private var diagnosticCompletionIntervalsMs: [Double] = []
    private var diagnosticAccessUnitIntervalsMs: [Double] = []
    private var diagnosticPTSIntervalsMs: [Double] = []
    private var diagnosticMainQueueDelaysMs: [Double] = []
    private var diagnosticMaxCompletionGapMs = 0.0
    private var diagnosticNALTypeMask: UInt32 = 0
    private var diagnosticIDRCount = 0
    private var diagnosticSPSCount = 0
    private var diagnosticPPSCount = 0
    private var diagnosticNonMonotonicPTS = 0
    private var diagnosticPresentationClockRebases = 0
    private var diagnosticPresentationLeadMs: [Double] = []

    // Recording mode can change the live-view cadence. Infer it from completed
    // access units and lock to a standard Pocket rate instead of coupling pacing
    // to a particular resolution or hard-coded fps. Until a stable observation
    // window locks, samples retain the proven immediate-display behavior.
    private static let supportedFrameRates = [24, 25, 30, 48, 50, 60]
    private var cadenceTimestampsNs: [UInt64] = []
    private var detectedFrameRate: Int?
    private var cadenceCandidate: Int?
    private var cadenceCandidateVotes = 0
    private var cadenceLastEvaluationNs: UInt64?
    private static let cadenceWindowNs: UInt64 = 3_000_000_000
    private static let cadenceMinimumSpanNs: UInt64 = 2_000_000_000
    private static let cadenceEvaluationIntervalNs: UInt64 = 500_000_000
    private static let cadenceResetGapNs: UInt64 = 180_000_000
    private let presentationLeadFrames: Int32 = 1
    private let maximumPresentationLeadFrames: Int32 = 4
    private var nextPresentationTime: CMTime?

    private var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(detectedFrameRate ?? 30))
    }

    // Keep the inline layer strongly referenced. AVKit needs the same live layer
    // to remain alive across the foreground -> PiP transition even if SwiftUI
    // dismantles the representable while the app leaves the screen.
    private var displayLayer: AVSampleBufferDisplayLayer?
    // Keep the exact layer used by AVKit's current PiP content source separate
    // from SwiftUI's current inline layer. During the short foreground-return
    // transition those can briefly be different, and both must keep receiving
    // samples until PiP has stopped.
    private var pictureInPictureSourceLayer: AVSampleBufferDisplayLayer?
    private var pictureInPictureController: AVPictureInPictureController?
    private var pictureInPicturePossibleObservation: NSKeyValueObservation?
    private var foregroundReturnPiPStopRequested = false
    private var mediaSessionConfigured = false
    private var mediaSessionActiveForPiP = false
    private var automaticPictureInPictureEnabled = true

    init(
        onReady: @escaping () -> Void,
        onUnavailable: @escaping () -> Void,
        onForegroundPiPStopped: @escaping () -> Void,
        onLog: @escaping (String) -> Void
    ) {
        self.onReady = onReady
        self.onUnavailable = onUnavailable
        self.onForegroundPiPStopped = onForegroundPiPStopped
        self.onLog = onLog
        super.init()
    }

    @MainActor
    func attach(
        displayLayer: AVSampleBufferDisplayLayer,
        videoGravity: AVLayerVideoGravity = .resizeAspect
    ) {
        precondition(Thread.isMainThread)
        let layerChanged = self.displayLayer !== displayLayer
        self.displayLayer = displayLayer
        displayLayer.videoGravity = videoGravity
        displayLayer.backgroundColor = UIColor.black.cgColor
        configureSystemMediaSessionIfNeeded()

        // UIViewRepresentable.updateUIView can run for every unrelated SwiftUI
        // state change. Replacing AVPictureInPictureController.contentSource on
        // every update was churning AVKit's internal observation objects and
        // repeatedly toggling isPictureInPicturePossible. Configure PiP only
        // when SwiftUI actually gives us a different display layer.
        if layerChanged {
            displayLayer.flush()
            queue.async { [weak self] in
                guard let self else { return }
                self.waitingForIDR = true
                self.nextPresentationTime = nil
                self.diagnosticLastPTS = nil
                self.diagnosticAttaches += 1
                self.diagnosticFlushes += 1
            }
            onLog("Video: inline display layer attached; waiting for next IDR")
        }
    }

    @MainActor
    func detach(displayLayer: AVSampleBufferDisplayLayer) {
        precondition(Thread.isMainThread)
        queue.async { [weak self] in
            self?.diagnosticDetaches += 1
        }
        // Intentionally do not clear displayLayer here. The PiP content source
        // retains this exact layer while the inline SwiftUI view leaves the
        // hierarchy, and the video pump must keep enqueueing into it. A future
        // inline attach replaces it naturally.
    }

    private func configureSystemMediaSessionIfNeeded() {
        guard !mediaSessionConfigured else { return }
        mediaSessionConfigured = true

        let session = AVAudioSession.sharedInstance()
        do {
            // Configure the media category when the preview opens, but do not
            // activate the session here. Activation is deferred until AVKit is
            // actually starting PiP so opening the camera UI does not create an
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            onLog("Media: playback category configured for automatic PiP")
        } catch {
            onLog("Media: AVAudioSession setup failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func activateMediaSessionForPiP() {
        guard !mediaSessionActiveForPiP else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            mediaSessionActiveForPiP = true
            onLog("PiP: media session activated for background playback")
        } catch {
            onLog("PiP: media session activation failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func deactivateMediaSessionAfterPiP() {
        guard mediaSessionActiveForPiP else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            onLog("PiP: media session deactivation failed: \(error.localizedDescription)")
        }
        mediaSessionActiveForPiP = false
    }

    @MainActor
    private func configurePictureInPicture(for displayLayer: AVSampleBufferDisplayLayer) {
        guard automaticPictureInPictureEnabled,
              activeSessionGeneration() != nil else {
            isPictureInPicturePossible = false
            return
        }

        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            isPictureInPicturePossible = false
            return
        }

        if pictureInPictureSourceLayer === displayLayer {
            return
        }

        // Never replace an active PiP content source. If SwiftUI rebuilds the
        // inline host while we're returning to the app, keep feeding the old
        // PiP layer until AVKit reports that PiP has stopped.
        if let controller = pictureInPictureController,
           controller.isPictureInPictureActive {
            onLog("PiP: inline display layer changed during active PiP; deferring content-source swap")
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )

        if let controller = pictureInPictureController {
            controller.contentSource = source
            pictureInPictureSourceLayer = displayLayer
            onLog("PiP: content source moved to new inline display layer")
            return
        }

        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // Do not let iOS auto-start PiP while the Pocket preview is still empty.
        // The user may leave the app during BLE/Wi-Fi setup; attempting PiP with
        // no renderable sample produced PGPegasusErrorDomain -1003 in the device
        // log. Automatic PiP is armed only after the first live H.264 sample.
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        pictureInPictureController = controller
        pictureInPictureSourceLayer = displayLayer

        pictureInPicturePossibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            DispatchQueue.main.async {
                self?.isPictureInPicturePossible = controller.isPictureInPicturePossible
                self?.onLog("PiP: possible=\(controller.isPictureInPicturePossible)")
            }
        }

        onLog("PiP: sample-buffer content source configured; automatic PiP will arm after live video starts")
    }


    /// Starts a new, connection-proven media generation. Frames from an older
    /// UDP session can no longer render or arm PiP after this point.
    func startSession() {
        sessionLock.lock()
        sessionGeneration &+= 1
        let generation = sessionGeneration
        sessionActive = true
        sessionLock.unlock()

        queue.async { [weak self] in
            guard let self, self.isSessionCurrent(generation) else { return }
            self.resetDecoderState()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isSessionCurrent(generation) else { return }
                self.tearDownPictureInPicture()
                self.flushAllDisplayLayers()
            }
        }
    }

    /// Revokes PiP eligibility synchronously, then clears queued decoder work.
    /// This is safe to call repeatedly while connection teardown is in flight.
    func reset() {
        revokeSession()

        // Do not put AVKit disarming behind decoder cleanup. A user can leave
        // the app while the media queue is still draining old UDP datagrams.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tearDownPictureInPicture()
            self.flushAllDisplayLayers()
            self.queue.async { [weak self] in
                self?.diagnosticFlushes += 1
            }
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.resetDecoderState()
        }
    }

    /// User disconnect originates on the main thread. Revoke AVKit before
    /// starting asynchronous transport teardown so Home/app switching cannot
    /// race a stale automatic-PiP flag.
    @MainActor
    func stopSessionImmediately() {
        revokeSession()
        tearDownPictureInPicture()
        flushAllDisplayLayers()

        queue.async { [weak self] in
            self?.resetDecoderState()
        }
    }

    private func revokeSession() {
        sessionLock.lock()
        sessionGeneration &+= 1
        sessionActive = false
        sessionLock.unlock()
    }

    private func resetDecoderState() {
        current.removeAll(keepingCapacity: true)
        expectedLength = nil
        sps = nil
        pps = nil
        formatDescription = nil
        waitingForIDR = true
        readySignaled = false
        completedMessages = 0
        decodedSamples = 0
        droppedPartialMessages = 0
        diagnosticLastTransportSequence = nil
        diagnosticLastCompletionNs = nil
        diagnosticLastAccessUnitNs = nil
        diagnosticLastPTS = nil
        nextPresentationTime = nil
        resetCadenceDetection()
        resetDiagnosticWindow(nowNs: DispatchTime.now().uptimeNanoseconds)
    }

    private func activeSessionGeneration() -> Int? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionActive ? sessionGeneration : nil
    }

    private func isSessionCurrent(_ generation: Int) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return sessionActive && sessionGeneration == generation
    }

    static func shouldAllowAutomaticPiP(
        userEnabled: Bool = true,
        sessionActive: Bool,
        hasRenderedVideo: Bool,
        sampleAgeMs: UInt64
    ) -> Bool {
        userEnabled
            && sessionActive
            && hasRenderedVideo
            && sampleAgeMs <= automaticPiPMaximumSampleAgeMs
    }

    private func isAutomaticPiPEligible(
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        let snapshot = queue.sync { () -> (hasRenderedVideo: Bool, sampleAgeMs: UInt64) in
            let age = diagnosticLastAccessUnitNs.map {
                nowNs >= $0 ? (nowNs - $0) / 1_000_000 : 0
            } ?? UInt64.max
            return (readySignaled, age)
        }
        return Self.shouldAllowAutomaticPiP(
            userEnabled: automaticPictureInPictureEnabled,
            sessionActive: activeSessionGeneration() != nil,
            hasRenderedVideo: snapshot.hasRenderedVideo,
            sampleAgeMs: snapshot.sampleAgeMs
        )
    }

    private func scheduleFreshnessCheck(for generation: Int) {
        queue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(Self.freshnessCheckIntervalNs))
        ) { [weak self] in
            guard let self, self.isSessionCurrent(generation), self.readySignaled else { return }

            let now = DispatchTime.now().uptimeNanoseconds
            let sampleAgeMs = self.diagnosticLastAccessUnitNs.map {
                now >= $0 ? (now - $0) / 1_000_000 : 0
            } ?? UInt64.max

            guard !Self.shouldAllowAutomaticPiP(
                sessionActive: true,
                hasRenderedVideo: true,
                sampleAgeMs: sampleAgeMs
            ) else {
                self.scheduleFreshnessCheck(for: generation)
                return
            }

            self.readySignaled = false
            self.current.removeAll(keepingCapacity: true)
            self.expectedLength = nil
            self.nextPresentationTime = nil
            self.diagnosticLastPTS = nil
            self.onUnavailable()

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isSessionCurrent(generation) else { return }
                self.tearDownPictureInPicture()
                self.onLog("PiP: disarmed because live video became stale (\(sampleAgeMs)ms)")
            }
        }
    }

    @MainActor
    private func tearDownPictureInPicture() {
        pictureInPicturePossibleObservation?.invalidate()
        pictureInPicturePossibleObservation = nil

        if let controller = pictureInPictureController {
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            if controller.isPictureInPictureActive {
                controller.stopPictureInPicture()
            }
            controller.delegate = nil
            controller.contentSource = nil
        }

        pictureInPictureController = nil
        pictureInPictureSourceLayer = nil
        foregroundReturnPiPStopRequested = false
        isPictureInPictureActive = false
        isPictureInPicturePossible = false
        deactivateMediaSessionAfterPiP()
        onLog("PiP: controller torn down")
    }

    @MainActor
    func stopPictureInPictureForForegroundReturn() {
        guard let controller = pictureInPictureController,
              controller.isPictureInPictureActive else { return }

        foregroundReturnPiPStopRequested = true
        onLog("PiP: foreground return requested; stopping active Picture in Picture")
        controller.stopPictureInPicture()
    }

    @MainActor
    func setAutomaticPictureInPictureEnabled(_ enabled: Bool) {
        guard automaticPictureInPictureEnabled != enabled else { return }
        automaticPictureInPictureEnabled = enabled

        guard enabled else {
            tearDownPictureInPicture()
            onLog("PiP: automatic Picture in Picture disabled in Tools")
            return
        }

        if isAutomaticPiPEligible(), let displayLayer {
            configurePictureInPicture(for: displayLayer)
            pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
        onLog("PiP: automatic Picture in Picture enabled in Tools")
    }

    @MainActor
    private func flushAllDisplayLayers() {
        let layers = [displayLayer, pictureInPictureSourceLayer].compactMap { $0 }
        var uniqueLayers: [AVSampleBufferDisplayLayer] = []
        for layer in layers where !uniqueLayers.contains(where: { $0 === layer }) {
            uniqueLayers.append(layer)
        }
        for layer in uniqueLayers {
            layer.flushAndRemoveImage()
        }
    }

    private func finishPendingEnqueue() {
        queue.async { [weak self] in
            guard let self else { return }
            self.diagnosticPendingEnqueues = max(0, self.diagnosticPendingEnqueues - 1)
        }
    }

    func feed(datagram: Data) {
        guard datagram.count >= 20, datagram[6] == 0x02 else { return }
        guard let generation = activeSessionGeneration() else { return }
        let receiveNs = DispatchTime.now().uptimeNanoseconds
        queue.async { [weak self] in
            guard let self, self.isSessionCurrent(generation) else { return }
            self.consume(datagram, receiveNs: receiveNs, sessionGeneration: generation)
        }
    }

    /// Rate-limited connection diagnostics call this from the UDP pump thread.
    /// The media queue owns the timestamp, so take a synchronous snapshot.
    func lastSampleAgeMs(nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds) -> UInt64 {
        queue.sync {
            guard let last = diagnosticLastAccessUnitNs else { return UInt64.max }
            return nowNs >= last ? (nowNs - last) / 1_000_000 : 0
        }
    }

    /// Re-check freshness at the exact Home/app-switch transition. The periodic
    /// watchdog normally handles this, but it must not leave a stale automatic
    /// PiP flag armed between watchdog ticks.
    @MainActor
    func prepareForBackground() {
        guard !isAutomaticPiPEligible() else { return }

        tearDownPictureInPicture()
        onLog("PiP: Home-screen start rejected because live video is not fresh")
    }

    private func consume(_ datagram: Data, receiveNs: UInt64, sessionGeneration: Int) {
        diagnosticDatagrams += 1
        if Self.performanceLog.signpostsEnabled {
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "udp_receive",
                "bytes=%{public}d",
                datagram.count
            )
        }

        let transportSequence = Int(datagram[4]) | (Int(datagram[5]) << 8)
        if let previous = diagnosticLastTransportSequence {
            let delta = (transportSequence - previous) & 0xFFFF
            // pktType 0x02 normally advances in eight-count transport slots.
            // Count this as a discontinuity candidate, not proof of packet loss.
            if delta != 8 {
                diagnosticSequenceDiscontinuities += 1
            }
        }
        diagnosticLastTransportSequence = transportSequence

        let fragmentStart = 20
        let fragmentCount = datagram.count - fragmentStart

        if fragmentCount >= 16,
           datagram[fragmentStart] == 0x00,
           datagram[fragmentStart + 1] == 0x00,
           datagram[fragmentStart + 2] == 0x01,
           datagram[fragmentStart + 3] == 0xFF {
            if expectedLength != nil, !current.isEmpty {
                droppedPartialMessages += 1
                diagnosticPartialDrops += 1
            }

            let length = Self.u32le(datagram, fragmentStart + 4)
            // Guard against corrupt framing without guessing a camera maximum.
            guard length > 0, length <= 8 * 1024 * 1024 else {
                diagnosticInvalidMessages += 1
                expectedLength = nil
                current.removeAll(keepingCapacity: true)
                return
            }

            expectedLength = length
            current = Data()
            current.reserveCapacity(length)
            current.append(datagram[(fragmentStart + 16)..<datagram.count])
        } else if expectedLength != nil {
            current.append(datagram[fragmentStart..<datagram.count])
        } else {
            // Joined mid-message. Wait for the next capture-confirmed first-fragment marker.
            diagnosticJoinedMidMessage += 1
            return
        }

        guard let expectedLength, current.count >= expectedLength else { return }

        self.expectedLength = nil
        let message: Data
        if current.count == expectedLength {
            // Moving the completed value preserves its storage for parsing and
            // avoids copying the full access unit before the next reassembly.
            message = current
            current = Data()
        } else {
            message = Data(current.prefix(expectedLength))
            current.removeAll(keepingCapacity: true)
        }
        completedMessages += 1
        diagnosticMediaMessages += 1
        if let previous = diagnosticLastCompletionNs {
            let interval = Self.milliseconds(from: previous, to: receiveNs)
            diagnosticCompletionIntervalsMs.append(interval)
            diagnosticMaxCompletionGapMs = max(diagnosticMaxCompletionGapMs, interval)
        }
        diagnosticLastCompletionNs = receiveNs
        if Self.performanceLog.signpostsEnabled {
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "media_message_complete",
                "sequence=%{public}d bytes=%{public}d",
                completedMessages,
                expectedLength
            )
        }
        processAnnexB(message, completionNs: receiveNs, sessionGeneration: sessionGeneration)
        emitDiagnosticSummaryIfNeeded(nowNs: receiveNs)
    }

    private func processAnnexB(
        _ message: Data,
        completionNs: UInt64,
        sessionGeneration: Int
    ) {
        let nalRanges = Self.annexBNALRanges(message)
        guard !nalRanges.isEmpty else { return }

        var sawParameterSetChange = false
        var nalTypeMask: UInt32 = 0
        for range in nalRanges where !range.isEmpty {
            let type = message[range.lowerBound] & 0x1F
            nalTypeMask |= UInt32(1) << UInt32(type)
            switch type {
            case 7:
                diagnosticSPSCount += 1
                let nal = Data(message[range])
                if sps != nal {
                    sps = nal
                    sawParameterSetChange = true
                }
            case 8:
                diagnosticPPSCount += 1
                let nal = Data(message[range])
                if pps != nal {
                    pps = nal
                    sawParameterSetChange = true
                }
            default:
                break
            }
        }

        if sawParameterSetChange,
           let sps,
           let pps,
           let newFormat = Self.makeFormatDescription(sps: sps, pps: pps) {
            formatDescription = newFormat
            waitingForIDR = true
            nextPresentationTime = nil
            diagnosticLastPTS = nil
            resetCadenceDetection()
            onLog("Video: H.264 SPS/PPS received; native display format ready")
            DispatchQueue.main.async { [weak self] in
                self?.displayLayer?.flush()
                self?.queue.async { [weak self] in
                    self?.diagnosticFlushes += 1
                }
            }
        }

        guard let formatDescription else { return }

        let sampleNALRanges = nalRanges.filter { range in
            guard !range.isEmpty else { return false }
            let type = message[range.lowerBound] & 0x1F
            // SPS/PPS configure the format description and AUD is not needed in AVCC samples.
            return type != 7 && type != 8 && type != 9
        }

        let hasVCL = sampleNALRanges.contains { range in
            guard !range.isEmpty else { return false }
            let type = message[range.lowerBound] & 0x1F
            return type >= 1 && type <= 5
        }
        guard hasVCL else { return }

        let isIDR = sampleNALRanges.contains { range in
            !range.isEmpty && (message[range.lowerBound] & 0x1F) == 5
        }

        diagnosticNALTypeMask |= nalTypeMask
        diagnosticAccessUnits += 1
        if isIDR { diagnosticIDRCount += 1 }
        if let previous = diagnosticLastAccessUnitNs {
            diagnosticAccessUnitIntervalsMs.append(Self.milliseconds(from: previous, to: completionNs))
        }
        diagnosticLastAccessUnitNs = completionNs
        observeCadence(at: completionNs)

        if waitingForIDR {
            guard isIDR else { return }
            waitingForIDR = false
            onLog("Video: first H.264 IDR accepted")
        }

        let duration = frameDuration
        let cadenceLocked = detectedFrameRate != nil
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        let presentationTime: CMTime
        if !cadenceLocked {
            presentationTime = hostTime
        } else if let nextPresentationTime,
           CMTimeCompare(nextPresentationTime, hostTime) >= 0 {
            let maximumLead = CMTimeMultiply(
                duration,
                multiplier: maximumPresentationLeadFrames
            )
            let maximumPresentationTime = CMTimeAdd(hostTime, maximumLead)
            if CMTimeCompare(nextPresentationTime, maximumPresentationTime) <= 0 {
                presentationTime = nextPresentationTime
            } else {
                // Preserve every compressed frame, but compress an exceptional
                // burst at the four-frame boundary rather than letting renderer
                // latency grow without limit.
                let monotonicFloor = diagnosticLastPTS.map {
                    CMTimeAdd($0, CMTime(value: 1, timescale: 60_000))
                } ?? maximumPresentationTime
                presentationTime = CMTimeCompare(monotonicFloor, maximumPresentationTime) > 0
                    ? monotonicFloor
                    : maximumPresentationTime
                diagnosticPresentationClockRebases += 1
            }
        } else {
            if nextPresentationTime != nil {
                diagnosticPresentationClockRebases += 1
            }
            let targetLead = CMTimeMultiply(duration, multiplier: presentationLeadFrames)
            presentationTime = CMTimeAdd(hostTime, targetLead)
        }
        nextPresentationTime = cadenceLocked
            ? CMTimeAdd(presentationTime, duration)
            : nil
        diagnosticPresentationLeadMs.append(
            max(0, CMTimeGetSeconds(CMTimeSubtract(presentationTime, hostTime)) * 1_000)
        )
        if let previousPTS = diagnosticLastPTS {
            let delta = CMTimeSubtract(presentationTime, previousPTS)
            if delta <= .zero {
                diagnosticNonMonotonicPTS += 1
            } else {
                diagnosticPTSIntervalsMs.append(CMTimeGetSeconds(delta) * 1_000)
            }
        }
        diagnosticLastPTS = presentationTime

        guard let sampleBuffer = Self.makeSampleBuffer(
            annexB: message,
            nalRanges: sampleNALRanges,
            formatDescription: formatDescription,
            isIDR: isIDR,
            presentationTimeStamp: presentationTime,
            duration: duration,
            displayImmediately: !cadenceLocked
        ) else {
            diagnosticSampleBufferFailures += 1
            return
        }

        decodedSamples += 1
        let sampleSequence = decodedSamples
        if Self.performanceLog.signpostsEnabled {
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "h264_access_unit_ready",
                "sequence=%{public}d bytes=%{public}d nalMask=%{public}x idr=%{public}d",
                sampleSequence,
                message.count,
                nalTypeMask,
                isIDR ? 1 : 0
            )
            os_signpost(
                .event,
                log: Self.performanceLog,
                name: "sample_buffer_created",
                "sequence=%{public}d",
                sampleSequence
            )
        }
        if !readySignaled {
            readySignaled = true
            onLog("Video: direct Pocket 3 H.264 is rendering")
            DispatchQueue.main.async { [weak self, onReady] in
                guard let self, self.isSessionCurrent(sessionGeneration) else { return }
                if self.automaticPictureInPictureEnabled,
                   let displayLayer = self.displayLayer {
                    self.configurePictureInPicture(for: displayLayer)
                    self.pictureInPictureController?
                        .canStartPictureInPictureAutomaticallyFromInline = true
                    self.onLog("PiP: automatic Home-screen start armed for fresh live video")
                }
                onReady()
            }
            scheduleFreshnessCheck(for: sessionGeneration)
        }

        diagnosticPendingEnqueues += 1
        diagnosticMaxPendingEnqueues = max(diagnosticMaxPendingEnqueues, diagnosticPendingEnqueues)
        let enqueueDispatchNs = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isSessionCurrent(sessionGeneration) else {
                self?.finishPendingEnqueue()
                return
            }

            var layers = [self.displayLayer].compactMap { $0 }
            if self.isPictureInPictureActive,
               let pipLayer = self.pictureInPictureSourceLayer,
               !layers.contains(where: { $0 === pipLayer }) {
                layers.append(pipLayer)
            }

            var backpressureCount = 0
            var failureCount = 0
            for layer in layers {
                let backpressured = !layer.isReadyForMoreMediaData
                if backpressured { backpressureCount += 1 }
                if layer.status == .failed {
                    failureCount += 1
                    self.onLog("Video: display layer failed; flushing before resume")
                    layer.flush()
                }
                layer.enqueue(sampleBuffer)
                if Self.performanceLog.signpostsEnabled {
                    os_signpost(
                        .event,
                        log: Self.performanceLog,
                        name: "sample_buffer_enqueue",
                        "sequence=%{public}d ready=%{public}d",
                        sampleSequence,
                        backpressured ? 0 : 1
                    )
                }
            }

            if self.isPictureInPictureActive && self.decodedSamples % 60 == 0 {
                let status = self.pictureInPictureSourceLayer?.status.rawValue ?? -1
                let errorText = self.pictureInPictureSourceLayer?.error?.localizedDescription ?? "none"
                self.onLog(
                    "PiP: live video samples still arriving " +
                    "(sample \(self.decodedSamples), layerStatus=\(status), error=\(errorText))"
                )
            }

            let mainQueueDelayMs = Self.milliseconds(
                from: enqueueDispatchNs,
                to: DispatchTime.now().uptimeNanoseconds
            )
            let enqueueCount = layers.count
            self.queue.async { [weak self] in
                guard let self else { return }
                self.diagnosticPendingEnqueues = max(0, self.diagnosticPendingEnqueues - 1)
                self.diagnosticMainQueueDelaysMs.append(mainQueueDelayMs)
                self.diagnosticEnqueues += enqueueCount
                self.diagnosticBackpressureEvents += backpressureCount
                self.diagnosticLayerFailures += failureCount
            }
        }
    }

    private func emitDiagnosticSummaryIfNeeded(nowNs: UInt64) {
        guard let start = diagnosticWindowStartNs else {
            diagnosticWindowStartNs = nowNs
            return
        }
        guard nowNs - start >= 5_000_000_000 else { return }

        let seconds = Double(nowNs - start) / 1_000_000_000
        let completion = Self.intervalSummary(diagnosticCompletionIntervalsMs)
        let accessUnit = Self.intervalSummary(diagnosticAccessUnitIntervalsMs)
        let pts = Self.intervalSummary(diagnosticPTSIntervalsMs)
        let main = Self.intervalSummary(diagnosticMainQueueDelaysMs)
        let lead = Self.intervalSummary(diagnosticPresentationLeadMs)
        onLog(
            String(
                format: "Video diag/%.1fs: cadence=%dfps udp=%d (%.1f/s) media=%d AU=%d (%.1f/s) enqueue=%d " +
                    "sampleFail=%d partialDrop=%d invalid=%d midJoin=%d seqGapCandidate=%d " +
                    "mediaDelta[avg=%.2f p50=%.2f p95=%.2f max=%.2fms] " +
                    "auDelta[avg=%.2f p50=%.2f p95=%.2f max=%.2fms] " +
                    "ptsDelta[avg=%.2f p50=%.2f p95=%.2f max=%.2fms nonMono=%d] " +
                    "presentationLead[avg=%.2f p50=%.2f p95=%.2f max=%.2fms rebases=%d] " +
                    "mainDelay[avg=%.2f p95=%.2f max=%.2fms pendingMax=%d] " +
                    "layer[backpressure=%d failed=%d flush=%d attach=%d detach=%d] " +
                    "NALmask=0x%08X IDR=%d SPS=%d PPS=%d",
                seconds,
                detectedFrameRate ?? 0,
                diagnosticDatagrams,
                Double(diagnosticDatagrams) / seconds,
                diagnosticMediaMessages,
                diagnosticAccessUnits,
                Double(diagnosticAccessUnits) / seconds,
                diagnosticEnqueues,
                diagnosticSampleBufferFailures,
                diagnosticPartialDrops,
                diagnosticInvalidMessages,
                diagnosticJoinedMidMessage,
                diagnosticSequenceDiscontinuities,
                completion.average,
                completion.p50,
                completion.p95,
                max(completion.maximum, diagnosticMaxCompletionGapMs),
                accessUnit.average,
                accessUnit.p50,
                accessUnit.p95,
                accessUnit.maximum,
                pts.average,
                pts.p50,
                pts.p95,
                pts.maximum,
                diagnosticNonMonotonicPTS,
                lead.average,
                lead.p50,
                lead.p95,
                lead.maximum,
                diagnosticPresentationClockRebases,
                main.average,
                main.p95,
                main.maximum,
                diagnosticMaxPendingEnqueues,
                diagnosticBackpressureEvents,
                diagnosticLayerFailures,
                diagnosticFlushes,
                diagnosticAttaches,
                diagnosticDetaches,
                diagnosticNALTypeMask,
                diagnosticIDRCount,
                diagnosticSPSCount,
                diagnosticPPSCount
            )
        )
        resetDiagnosticWindow(nowNs: nowNs)
    }

    private func resetDiagnosticWindow(nowNs: UInt64) {
        diagnosticWindowStartNs = nowNs
        diagnosticDatagrams = 0
        diagnosticMediaMessages = 0
        diagnosticAccessUnits = 0
        diagnosticEnqueues = 0
        diagnosticSampleBufferFailures = 0
        diagnosticPartialDrops = 0
        diagnosticInvalidMessages = 0
        diagnosticJoinedMidMessage = 0
        diagnosticSequenceDiscontinuities = 0
        diagnosticBackpressureEvents = 0
        diagnosticLayerFailures = 0
        diagnosticFlushes = 0
        diagnosticAttaches = 0
        diagnosticDetaches = 0
        diagnosticMaxPendingEnqueues = diagnosticPendingEnqueues
        diagnosticCompletionIntervalsMs.removeAll(keepingCapacity: true)
        diagnosticAccessUnitIntervalsMs.removeAll(keepingCapacity: true)
        diagnosticPTSIntervalsMs.removeAll(keepingCapacity: true)
        diagnosticMainQueueDelaysMs.removeAll(keepingCapacity: true)
        diagnosticMaxCompletionGapMs = 0
        diagnosticNALTypeMask = 0
        diagnosticIDRCount = 0
        diagnosticSPSCount = 0
        diagnosticPPSCount = 0
        diagnosticNonMonotonicPTS = 0
        diagnosticPresentationClockRebases = 0
        diagnosticPresentationLeadMs.removeAll(keepingCapacity: true)
    }

    private func resetCadenceDetection() {
        cadenceTimestampsNs.removeAll(keepingCapacity: true)
        detectedFrameRate = nil
        cadenceCandidate = nil
        cadenceCandidateVotes = 0
        cadenceLastEvaluationNs = nil
    }

    private func observeCadence(at completionNs: UInt64) {
        if let previous = cadenceTimestampsNs.last,
           completionNs > previous,
           completionNs - previous >= Self.cadenceResetGapNs {
            let gapMs = Self.milliseconds(from: previous, to: completionNs)
            resetCadenceDetection()
            nextPresentationTime = nil
            onLog(String(format: "Video: cadence observation restarted after %.1f ms stream gap", gapMs))
        }

        cadenceTimestampsNs.append(completionNs)
        let cutoff = completionNs > Self.cadenceWindowNs
            ? completionNs - Self.cadenceWindowNs
            : 0
        while cadenceTimestampsNs.count > 1,
              let first = cadenceTimestampsNs.first,
              first < cutoff {
            cadenceTimestampsNs.removeFirst()
        }

        guard cadenceTimestampsNs.count >= 12,
              let first = cadenceTimestampsNs.first,
              completionNs > first,
              completionNs - first >= Self.cadenceMinimumSpanNs else {
            return
        }
        if let lastEvaluation = cadenceLastEvaluationNs,
           completionNs - lastEvaluation < Self.cadenceEvaluationIntervalNs {
            return
        }
        cadenceLastEvaluationNs = completionNs

        guard let observed = Self.regressionFrameRate(cadenceTimestampsNs) else { return }
        guard let nearest = Self.supportedFrameRates.min(by: {
            abs(Double($0) - observed) < abs(Double($1) - observed)
        }),
        abs(Double(nearest) - observed) / Double(nearest) <= 0.08 else {
            cadenceCandidate = nil
            cadenceCandidateVotes = 0
            return
        }

        if let detectedFrameRate {
            let departure = abs(observed - Double(detectedFrameRate)) / Double(detectedFrameRate)
            // Adjacent rates such as 24 and 25 are too close to distinguish
            // reliably from bursty network arrival alone. Keep the established
            // lock unless a stream gap resets observation or the sustained
            // measured cadence moves far enough to represent a real mode change.
            guard nearest != detectedFrameRate, departure >= 0.10 else {
                cadenceCandidate = nil
                cadenceCandidateVotes = 0
                return
            }
        }

        if cadenceCandidate == nearest {
            cadenceCandidateVotes += 1
        } else {
            cadenceCandidate = nearest
            cadenceCandidateVotes = 1
        }
        guard cadenceCandidateVotes >= 2 else { return }

        let previousRate = detectedFrameRate
        detectedFrameRate = nearest
        cadenceCandidate = nil
        cadenceCandidateVotes = 0
        if previousRate == nil {
            nextPresentationTime = nil
            onLog(String(format: "Video: measured cadence locked to %d fps (observed %.2f)", nearest, observed))
        } else {
            // Retain the existing future timestamp when changing rate without a
            // transport gap so the new clock cannot move backward.
            onLog(
                String(
                    format: "Video: measured cadence changed from %d to %d fps (observed %.2f)",
                    previousRate ?? 0,
                    nearest,
                    observed
                )
            )
        }
    }

    nonisolated static func regressionFrameRate(_ timestampsNs: [UInt64]) -> Double? {
        guard timestampsNs.count >= 2, let origin = timestampsNs.first else { return nil }

        let count = Double(timestampsNs.count)
        let meanFrame = Double(timestampsNs.count - 1) / 2
        let meanTime = timestampsNs.reduce(0.0) { partial, timestamp in
            partial + Double(timestamp - origin) / 1_000_000_000
        } / count

        var covariance = 0.0
        var timeVariance = 0.0
        for (index, timestamp) in timestampsNs.enumerated() {
            let time = Double(timestamp - origin) / 1_000_000_000
            let centeredTime = time - meanTime
            covariance += centeredTime * (Double(index) - meanFrame)
            timeVariance += centeredTime * centeredTime
        }
        guard timeVariance > 0 else { return nil }
        return covariance / timeVariance
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }

    private static func intervalSummary(
        _ values: [Double]
    ) -> (average: Double, p50: Double, p95: Double, maximum: Double) {
        guard !values.isEmpty else { return (0, 0, 0, 0) }
        let sorted = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
        }
        return (
            values.reduce(0, +) / Double(values.count),
            percentile(0.50),
            percentile(0.95),
            sorted.last ?? 0
        )
    }

    private static func makeFormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        guard !spsBytes.isEmpty, !ppsBytes.isEmpty else { return nil }

        var format: CMFormatDescription?
        var status: OSStatus = -1

        spsBytes.withUnsafeBufferPointer { spsBuffer in
            ppsBytes.withUnsafeBufferPointer { ppsBuffer in
                guard let spsBase = spsBuffer.baseAddress,
                      let ppsBase = ppsBuffer.baseAddress else { return }

                var pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                var sizes = [spsBytes.count, ppsBytes.count]

                status = pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        guard let pointerBase = pointerBuffer.baseAddress,
                              let sizeBase = sizeBuffer.baseAddress else {
                            return -1
                        }

                        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBase,
                            parameterSetSizes: sizeBase,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format
                        )
                    }
                }
            }
        }

        guard status == noErr else { return nil }
        return format
    }

    private static func makeSampleBuffer(
        annexB: Data,
        nalRanges: [Range<Data.Index>],
        formatDescription: CMVideoFormatDescription,
        isIDR: Bool,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        displayImmediately: Bool
    ) -> CMSampleBuffer? {
        let sampleLength = nalRanges.reduce(0) { $0 + 4 + $1.count }
        guard sampleLength > 0 else { return nil }

        // Keep one contiguous AVCC staging value before handing the bytes to
        // Core Media. An attempted direct write through
        // CMBlockBufferGetDataPointer compiled successfully but returned no
        // renderable sample buffers on a physical iPhone. The replace-data API
        // below is the physically proven baseline behavior.
        var avcc = Data()
        avcc.reserveCapacity(sampleLength)
        for range in nalRanges where !range.isEmpty {
            let length = range.count
            avcc.append(UInt8((length >> 24) & 0xFF))
            avcc.append(UInt8((length >> 16) & 0xFF))
            avcc.append(UInt8((length >> 8) & 0xFF))
            avcc.append(UInt8(length & 0xFF))
            avcc.append(annexB[range])
        }

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus: OSStatus = avcc.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleLength
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ), CFArrayGetCount(attachments) > 0,
           let rawDictionary = CFArrayGetValueAtIndex(attachments, 0) {
            let dictionary = unsafeBitCast(rawDictionary, to: CFMutableDictionary.self)
            if displayImmediately {
                CFDictionarySetValue(
                    dictionary,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(isIDR ? kCFBooleanFalse : kCFBooleanTrue).toOpaque()
            )
        }

        return sampleBuffer
    }

    private static func annexBNALRanges(_ data: Data) -> [Range<Data.Index>] {
        guard data.count >= 4 else { return [] }

        var starts: [(index: Int, length: Int)] = []
        var index = 0
        while index + 3 < data.count {
            if index + 4 <= data.count,
               data[index] == 0,
               data[index + 1] == 0,
               data[index + 2] == 0,
               data[index + 3] == 1 {
                starts.append((index, 4))
                index += 4
            } else if data[index] == 0,
                      data[index + 1] == 0,
                      data[index + 2] == 1 {
                starts.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }

        guard !starts.isEmpty else { return [] }

        var result: [Range<Data.Index>] = []
        result.reserveCapacity(starts.count)
        for position in starts.indices {
            let start = starts[position].index + starts[position].length
            let end = position + 1 < starts.count ? starts[position + 1].index : data.count
            if start < end {
                result.append(start..<end)
            }
        }
        return result
    }

    private static func u32le(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) |
            (Int(data[offset + 1]) << 8) |
            (Int(data[offset + 2]) << 16) |
            (Int(data[offset + 3]) << 24)
    }
}

// MARK: - Picture in Picture

extension Pocket3VideoOutput: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(
        _: AVPictureInPictureController,
        setPlaying _: Bool
    ) {
        // This is a live monitor. There is no meaningful pause/resume state to
        // apply to the Pocket transport from PiP playback controls.
    }

    func pictureInPictureControllerTimeRangeForPlayback(
        _: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _: AVPictureInPictureController
    ) -> Bool {
        false
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        didTransitionToRenderSize _: CMVideoDimensions
    ) {}

    func pictureInPictureController(
        _: AVPictureInPictureController,
        skipByInterval _: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

extension Pocket3VideoOutput: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard isAutomaticPiPEligible() else {
            tearDownPictureInPicture()
            onLog("PiP: rejected start because the Pocket live video is inactive or stale")
            return
        }
        activateMediaSessionForPiP()
        onLog("PiP: will start; keeping live Pocket media pipeline active")
    }

    func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        guard isAutomaticPiPEligible() else {
            tearDownPictureInPicture()
            return
        }
        isPictureInPictureActive = true
        onLog("PiP: started")
    }

    func pictureInPictureControllerDidStopPictureInPicture(
        _: AVPictureInPictureController
    ) {
        isPictureInPictureActive = false
        deactivateMediaSessionAfterPiP()
        onLog("PiP: stopped")

        if foregroundReturnPiPStopRequested {
            foregroundReturnPiPStopRequested = false
            onLog("PiP: foreground handoff complete; requesting post-PiP IDR")
            onForegroundPiPStopped()
        }

        // SwiftUI may have rebuilt the inline preview while PiP owned the old
        // source layer. Rebind AVKit only after PiP is fully stopped.
        if let displayLayer, pictureInPictureSourceLayer !== displayLayer {
            configurePictureInPicture(for: displayLayer)
        }
    }

    func pictureInPictureController(
        _: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        isPictureInPictureActive = false
        foregroundReturnPiPStopRequested = false
        deactivateMediaSessionAfterPiP()
        onLog("PiP: failed to start: \(error.localizedDescription)")
    }
}

final class Pocket3VideoHostView: UIView {
    override class var layerClass: AnyClass {
        AVSampleBufferDisplayLayer.self
    }

    var sampleBufferLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }
}

struct Pocket3VideoPreviewView: UIViewRepresentable {
    let output: Pocket3VideoOutput
    var aspectFill = false

    func makeCoordinator() -> Pocket3VideoOutput {
        output
    }

    func makeUIView(context: Context) -> Pocket3VideoHostView {
        let view = Pocket3VideoHostView()
        view.backgroundColor = .black
        output.attach(
            displayLayer: view.sampleBufferLayer,
            videoGravity: aspectFill ? .resizeAspectFill : .resizeAspect
        )
        return view
    }

    func updateUIView(_ uiView: Pocket3VideoHostView, context: Context) {
        // Do not re-run output.attach() here. SwiftUI calls updateUIView for
        // unrelated state changes; doing so used to rebuild PiP's content
        // source dozens of times per second. Only the visual gravity changes.
        uiView.sampleBufferLayer.videoGravity = aspectFill ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleUIView(_ uiView: Pocket3VideoHostView, coordinator: Pocket3VideoOutput) {
        coordinator.detach(displayLayer: uiView.sampleBufferLayer)
    }
}
