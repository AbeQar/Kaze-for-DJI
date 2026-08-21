package com.pocket3.gimbaltest

import android.graphics.ImageFormat
import android.media.ImageReader
import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

enum class Pocket3VideoStatus {
    STOPPED,
    WAITING_FOR_VIDEO,
    VIDEO_RECEIVING,
    DECODING,
    ERROR,
}

/** Ordinary media traffic may establish reception, but never erase decode/error state. */
internal fun Pocket3VideoStatus.onOrdinaryMediaDatagram(): Pocket3VideoStatus =
    if (this == Pocket3VideoStatus.WAITING_FOR_VIDEO) Pocket3VideoStatus.VIDEO_RECEIVING else this

internal fun Pocket3VideoStatus.onDecoderInputAccepted(): Pocket3VideoStatus = Pocket3VideoStatus.DECODING

data class Pocket3VideoState(
    val liveViewRequested: Boolean = false,
    val status: Pocket3VideoStatus = Pocket3VideoStatus.STOPPED,
    val packetsReceived: Long = 0,
    val completedMediaMessages: Long = 0,
    val spsCount: Long = 0,
    val ppsCount: Long = 0,
    val idrCount: Long = 0,
    val accessUnitCount: Long = 0,
    val decoderOutputFrames: Long = 0,
    val renderedFrames: Long = 0,
    val malformedPackets: Long = 0,
    val droppedPartialMessages: Long = 0,
    val droppedDatagrams: Long = 0,
    val decoderResets: Long = 0,
    val decoderErrors: Long = 0,
    val width: Int? = null,
    val height: Int? = null,
)

/** Bounded media worker and Android MediaCodec coordinator. It never owns a socket. */
class Pocket3VideoOutput(private val log: (String) -> Unit) {
    companion object {
        private const val QUEUE_CAPACITY = 128
    }

    private val active = AtomicBoolean(false)
    private val queue = ArrayBlockingQueue<ByteArray>(QUEUE_CAPACITY)
    private val packetsReceived = AtomicLong(0)
    private val droppedDatagrams = AtomicLong(0)
    private val discontinuityPending = AtomicBoolean(false)
    private val surfaceVersion = AtomicLong(0)
    private val appliedSurfaceVersion = AtomicLong(-1)
    private val surfaceLock = Any()
    @Volatile private var pendingSurfaceDetach: java.util.concurrent.CountDownLatch? = null
    @Volatile private var pendingSurfaceDetachVersion = -1L
    @Volatile private var desiredSurface: Surface? = null
    @Volatile private var state = Pocket3VideoState()
    private var worker: Thread? = null

    fun state(): Pocket3VideoState = state

    fun attachSurface(surface: Surface) {
        // SurfaceHolder calls surfaceCreated() and surfaceChanged() for the same Surface.
        // Treat that as one attachment: restarting a decoder on surfaceChanged() loses the
        // current GOP and Pocket 3 may not send another IDR for a long time.
        if (desiredSurface === surface) return
        desiredSurface = surface
        surfaceVersion.incrementAndGet()
        log("Preview Surface restored")
    }

    fun detachSurface(surface: Surface) {
        if (desiredSurface !== surface) return
        log("Preview Surface lost; parking decoder while Pocket session remains active")
        val latch = java.util.concurrent.CountDownLatch(1)
        synchronized(surfaceLock) {
            desiredSurface = null
            pendingSurfaceDetach = latch
            pendingSurfaceDetachVersion = surfaceVersion.incrementAndGet()
        }
        // surfaceDestroyed() is the last safe point to move MediaCodec away from this
        // Surface. Give the decode worker a short bounded opportunity to switch to its
        // retained parking Surface before Android abandons the BufferQueue.
        if (active.get()) runCatching { latch.await(200, java.util.concurrent.TimeUnit.MILLISECONDS) }
        synchronized(surfaceLock) {
            if (pendingSurfaceDetach === latch) {
                pendingSurfaceDetach = null
                pendingSurfaceDetachVersion = -1L
            }
        }
    }

    @Synchronized
    fun startSession() {
        stopSession()
        queue.clear()
        packetsReceived.set(0)
        droppedDatagrams.set(0)
        discontinuityPending.set(false)
        state = Pocket3VideoState(liveViewRequested = true, status = Pocket3VideoStatus.WAITING_FOR_VIDEO)
        active.set(true)
        worker = Thread(::runWorker, "Pocket3-Video-Decode").apply {
            isDaemon = true
            start()
        }
        log("Video: media pipeline started; waiting for pktType 0x02")
    }

    fun feed(datagram: ByteArray) {
        if (!active.get()) return
        packetsReceived.incrementAndGet()
        if (!queue.offer(datagram)) {
            queue.poll()
            droppedDatagrams.incrementAndGet()
            discontinuityPending.set(true)
            queue.offer(datagram)
        }
    }

    @Synchronized
    fun stopSession() {
        active.set(false)
        pendingSurfaceDetach?.countDown()
        queue.clear()
        worker?.interrupt()
        runCatching { worker?.join(750) }
        worker = null
        state = Pocket3VideoState(status = Pocket3VideoStatus.STOPPED)
    }

    private fun runWorker() {
        val reassembler = Pocket3MediaReassembler()
        val h264 = Pocket3H264Stream()
        val decoder = HardwareAvcDecoder(log)
        var lastDiagnosticNs = System.nanoTime()
        var decoderResets = 0L
        var decoderErrors = 0L
        var decoderOutputFrames = 0L
        var renderedFrames = 0L
        var status = Pocket3VideoStatus.WAITING_FOR_VIDEO
        var pendingAccessUnit: Pocket3H264AccessUnit? = null
        var pendingRetryCount = 0

        try {
            while (active.get()) {
                val currentSurfaceVersion = surfaceVersion.get()
                if (currentSurfaceVersion != appliedSurfaceVersion.get()) {
                    val surface = desiredSurface?.takeIf { it.isValid }
                    if (decoder.isConfigured) {
                        if (!decoder.setPresentationSurface(surface)) {
                            decoderErrors++
                            status = Pocket3VideoStatus.ERROR
                        } else if (surface != null) {
                            log("Decoder output resumed on preview Surface without codec restart")
                        } else {
                            log("Decoder output parked; compressed stream and codec state retained")
                        }
                    }
                    synchronized(surfaceLock) {
                        appliedSurfaceVersion.set(currentSurfaceVersion)
                        if (pendingSurfaceDetachVersion in 0..currentSurfaceVersion) {
                            pendingSurfaceDetach?.countDown()
                        }
                    }
                }

                if (pendingAccessUnit != null) {
                    // MediaCodec can briefly have no input buffer immediately after start/restart.
                    // That is decoder backpressure, not a lost H.264 picture. Dropping the first
                    // IDR here makes the parser wait for another IDR, which Pocket 3 may not send
                    // for a long time. Retain the access unit and retry it before consuming more
                    // media so the dependency chain remains intact.
                    if (discontinuityPending.compareAndSet(true, false)) {
                        pendingAccessUnit = null
                        pendingRetryCount = 0
                        reassembler.reset()
                        h264.requireIdr()
                        decoder.flush()
                        decoderResets++
                    } else {
                        val result = decoder.feed(requireNotNull(pendingAccessUnit))
                        decoderOutputFrames += result.outputFrames
                        renderedFrames += result.renderedFrames
                        if (result.outputFrames > 0) status = status.onDecoderInputAccepted()
                        if (result.error) {
                            decoderErrors++
                            decoder.release()
                            h264.requireIdr()
                            decoderResets++
                            pendingAccessUnit = null
                            pendingRetryCount = 0
                            status = Pocket3VideoStatus.ERROR
                        } else if (result.accepted) {
                            if (pendingRetryCount > 0) {
                                log("Video decoder accepted retained access unit after $pendingRetryCount retries")
                            }
                            pendingAccessUnit = null
                            pendingRetryCount = 0
                        } else {
                            pendingRetryCount++
                            if (pendingRetryCount == 1) {
                                log("Video decoder input busy; retaining access unit instead of dropping GOP state")
                            }
                            try {
                                Thread.sleep(1)
                            } catch (_: InterruptedException) {
                                break
                            }
                            continue
                        }
                    }
                }

                val datagram = try {
                    queue.poll(20, java.util.concurrent.TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    break
                }
                if (datagram != null) {
                    if (discontinuityPending.compareAndSet(true, false)) {
                        pendingAccessUnit = null
                        pendingRetryCount = 0
                        reassembler.reset()
                        h264.requireIdr()
                        decoder.flush()
                        decoderResets++
                    }
                    status = status.onOrdinaryMediaDatagram()
                    val message = runCatching { reassembler.consume(datagram) }.getOrElse {
                        reassembler.reset()
                        decoderErrors++
                        null
                    }
                    if (message != null) {
                        val parsed = runCatching { h264.consume(message) }.getOrElse {
                            h264.requireIdr()
                            decoderErrors++
                            null
                        }
                        if (parsed != null) {
                            if (parsed.configuration != null) {
                                decoder.release()
                                decoderResets++
                                val surface = desiredSurface?.takeIf { it.isValid }
                                if (!decoder.configure(parsed.configuration, surface)) {
                                    decoderErrors++
                                    status = Pocket3VideoStatus.ERROR
                                } else if (surface == null) {
                                    log("Video decoder configured on retained parking Surface")
                                }
                            }
                            parsed.accessUnit?.let { accessUnit ->
                                if (decoder.isConfigured) {
                                    val result = decoder.feed(accessUnit)
                                    decoderOutputFrames += result.outputFrames
                                    renderedFrames += result.renderedFrames
                                    if (result.outputFrames > 0) status = status.onDecoderInputAccepted()
                                    if (result.error) {
                                        decoderErrors++
                                        decoder.release()
                                        h264.requireIdr()
                                        decoderResets++
                                        status = Pocket3VideoStatus.ERROR
                                    } else if (!result.accepted) {
                                        // Temporary MediaCodec input backpressure is not a stream
                                        // discontinuity. Retain this exact access unit and retry it
                                        // before parsing later pictures. In particular, never throw
                                        // away the first IDR merely because the codec input queue is
                                        // still coming online after a reconnect.
                                        pendingAccessUnit = accessUnit
                                        pendingRetryCount = 1
                                        log("Video decoder input busy; retaining access unit instead of dropping GOP state")
                                    }
                                }
                            }
                        }
                    }
                }

                val reassemblyStats = reassembler.stats()
                val h264Stats = h264.stats()
                val dimensions = decoder.dimensions
                state = Pocket3VideoState(
                    liveViewRequested = true,
                    status = status,
                    packetsReceived = packetsReceived.get(),
                    completedMediaMessages = reassemblyStats.completedMessages,
                    spsCount = h264Stats.spsCount,
                    ppsCount = h264Stats.ppsCount,
                    idrCount = h264Stats.idrCount,
                    accessUnitCount = h264Stats.accessUnitCount,
                    decoderOutputFrames = decoderOutputFrames,
                    renderedFrames = renderedFrames,
                    malformedPackets = reassemblyStats.malformedPackets + h264Stats.invalidMessageCount,
                    droppedPartialMessages = reassemblyStats.droppedPartialMessages,
                    droppedDatagrams = droppedDatagrams.get(),
                    decoderResets = decoderResets,
                    decoderErrors = decoderErrors,
                    width = dimensions?.width,
                    height = dimensions?.height,
                )

                val now = System.nanoTime()
                if (now - lastDiagnosticNs >= 5_000_000_000L) {
                    lastDiagnosticNs = now
                    log(
                        "Video diag/5s: status=$status pkt=${packetsReceived.get()} " +
                            "messages=${reassemblyStats.completedMessages} AU=${h264Stats.accessUnitCount} " +
                            "SPS=${h264Stats.spsCount} PPS=${h264Stats.ppsCount} IDR=${h264Stats.idrCount} " +
                            "output=$decoderOutputFrames rendered=$renderedFrames surface=${if (decoder.isPresenting) "preview" else "parking"} " +
                            "malformed=${state.malformedPackets} " +
                            "partialDrops=${reassemblyStats.droppedPartialMessages} queueDrops=${droppedDatagrams.get()} " +
                            "decoderErrors=$decoderErrors"
                    )
                }
            }
        } finally {
            reassembler.reset()
            h264.reset()
            decoder.release()
        }
    }
}

private data class DecoderFeedResult(val accepted: Boolean, val outputFrames: Int, val renderedFrames: Int, val error: Boolean)

private class HardwareAvcDecoder(private val log: (String) -> Unit) {
    private var codec: MediaCodec? = null
    private var parkingReader: ImageReader? = null
    private var parkingThread: HandlerThread? = null
    private var currentOutputSurface: Surface? = null
    private var presentationSurface: Surface? = null
    var dimensions: Pocket3VideoDimensions? = null
        private set
    val isConfigured: Boolean get() = codec != null
    val isPresenting: Boolean get() = presentationSurface != null && currentOutputSurface === presentationSurface

    fun configure(configuration: Pocket3H264DecoderConfiguration, surface: Surface?): Boolean {
        release()
        val parsedDimensions = Pocket3H264Sps.dimensions(configuration.sps)
        if (parsedDimensions == null) {
            log("Video decoder: rejected SPS with undecodable dimensions")
            return false
        }
        return runCatching {
            createParkingSurface(parsedDimensions)
            val initialPresentation = surface?.takeIf { it.isValid }
            val outputSurface = initialPresentation ?: requireNotNull(parkingReader?.surface)
            val format = MediaFormat.createVideoFormat(
                MediaFormat.MIMETYPE_VIDEO_AVC,
                parsedDimensions.width,
                parsedDimensions.height,
            ).apply {
                setByteBuffer("csd-0", ByteBuffer.wrap(withStartCode(configuration.sps)))
                setByteBuffer("csd-1", ByteBuffer.wrap(withStartCode(configuration.pps)))
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 2 * 1024 * 1024)
                if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).also {
                it.configure(format, outputSurface, null, 0)
                it.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
                it.start()
            }
            dimensions = parsedDimensions
            presentationSurface = initialPresentation
            currentOutputSurface = outputSurface
            log(
                "Video decoder: hardware AVC configured ${parsedDimensions.width}x${parsedDimensions.height} " +
                    "output=${if (initialPresentation != null) "preview" else "parking"}"
            )
            true
        }.getOrElse {
            log("Video decoder ERROR: ${it.message}")
            release()
            false
        }
    }

    /**
     * Move a running codec between the visible SurfaceView and a retained drain Surface.
     * This deliberately does not flush/reconfigure MediaCodec, preserving H.264 reference
     * frames across Activity recreation, rotation and Recents.
     */
    fun setPresentationSurface(surface: Surface?): Boolean {
        val activeCodec = codec ?: return true
        val validPresentation = surface?.takeIf { it.isValid }
        val target = validPresentation ?: parkingReader?.surface ?: return false
        if (currentOutputSurface === target) {
            presentationSurface = validPresentation
            return true
        }
        return runCatching {
            activeCodec.setOutputSurface(target)
            activeCodec.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT)
            presentationSurface = validPresentation
            currentOutputSurface = target
            true
        }.getOrElse {
            log("Video decoder surface switch ERROR: ${it.message}")
            false
        }
    }

    fun feed(accessUnit: Pocket3H264AccessUnit): DecoderFeedResult {
        val activeCodec = codec ?: return DecoderFeedResult(false, 0, 0, false)
        return runCatching {
            val outputBeforeInput = drain(activeCodec)
            val visibleBeforeInput = if (isPresenting) outputBeforeInput else 0
            val inputIndex = activeCodec.dequeueInputBuffer(2_000)
            if (inputIndex < 0) return DecoderFeedResult(false, outputBeforeInput, visibleBeforeInput, false)
            val buffer = activeCodec.getInputBuffer(inputIndex)
                ?: return DecoderFeedResult(false, outputBeforeInput, visibleBeforeInput, true)
            if (buffer.capacity() < accessUnit.annexB.size) {
                return DecoderFeedResult(false, outputBeforeInput, visibleBeforeInput, true)
            }
            buffer.clear()
            buffer.put(accessUnit.annexB)
            activeCodec.queueInputBuffer(
                inputIndex,
                0,
                accessUnit.annexB.size,
                System.nanoTime() / 1_000,
                if (accessUnit.isIdr) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0,
            )
            val outputAfterInput = drain(activeCodec)
            val visibleAfterInput = if (isPresenting) outputAfterInput else 0
            DecoderFeedResult(
                accepted = true,
                outputFrames = outputBeforeInput + outputAfterInput,
                renderedFrames = visibleBeforeInput + visibleAfterInput,
                error = false,
            )
        }.getOrElse {
            log("Video decoder ERROR: ${it.message}")
            DecoderFeedResult(false, 0, 0, true)
        }
    }

    fun flush() {
        runCatching { codec?.flush() }
    }

    fun release() {
        val oldCodec = codec
        codec = null
        dimensions = null
        presentationSurface = null
        currentOutputSurface = null
        runCatching { oldCodec?.stop() }
        runCatching { oldCodec?.release() }

        val oldReader = parkingReader
        parkingReader = null
        runCatching { oldReader?.setOnImageAvailableListener(null, null) }
        runCatching { oldReader?.close() }

        val oldThread = parkingThread
        parkingThread = null
        runCatching { oldThread?.quitSafely() }
        runCatching { oldThread?.join(250) }
    }

    private fun createParkingSurface(dimensions: Pocket3VideoDimensions) {
        val thread = HandlerThread("Pocket3-Video-Parking").apply { start() }
        val reader = ImageReader.newInstance(
            dimensions.width,
            dimensions.height,
            ImageFormat.PRIVATE,
            3,
        )
        reader.setOnImageAvailableListener({ source ->
            // PRIVATE images have no CPU-readable planes, but acquiring/closing them keeps
            // the BufferQueue flowing while the UI SurfaceView is absent.
            while (true) {
                val image = runCatching { source.acquireNextImage() }.getOrNull() ?: break
                image.close()
            }
        }, Handler(thread.looper))
        parkingThread = thread
        parkingReader = reader
    }

    private fun drain(codec: MediaCodec): Int {
        val info = MediaCodec.BufferInfo()
        var output = 0
        while (true) {
            val outputIndex = codec.dequeueOutputBuffer(info, 0)
            if (outputIndex >= 0) {
                codec.releaseOutputBuffer(outputIndex, true)
                output++
            } else if (outputIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ||
                outputIndex == MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED
            ) {
                continue
            } else {
                break
            }
        }
        return output
    }

    private fun withStartCode(nal: ByteArray): ByteArray = byteArrayOf(0, 0, 0, 1) + nal
}
