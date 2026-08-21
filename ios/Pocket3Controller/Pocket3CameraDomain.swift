import Foundation

/// Coherent camera-facing state published by the Pocket 3 session.
///
/// Transport/session lifecycle and battery telemetry intentionally remain outside this value.
struct Pocket3CameraState: Equatable {
    var recording: Bool?
    var recordingTransitionInProgress = false
    var recordCommandInFlight = false
    var storageTotalMiB: UInt32?
    var storageFreeMiB: UInt32?
    var remainingRecordSeconds: UInt16?
    var elapsedRecordSeconds: UInt16?
    var shootingModeRawValue: UInt8?
    var readback = Pocket3CameraReadbackState()

    var shootingMode: Pocket3CameraShootingMode? {
        shootingModeRawValue.flatMap(Pocket3CameraShootingMode.init(rawValue:))
    }

    var canToggleRecording: Bool {
        recording != nil && !recordingTransitionInProgress && !recordCommandInFlight
    }

    mutating func apply(_ fields: Pocket3CameraStatus.StatusFields) {
        storageTotalMiB = fields.storageTotalMiB
        storageFreeMiB = fields.storageFreeMiB
        remainingRecordSeconds = fields.videoLike ? fields.remainingRecordSeconds : nil
        elapsedRecordSeconds = fields.videoLike ? fields.elapsedRecordSeconds : nil
        shootingModeRawValue = fields.shootingMode
    }

    @discardableResult
    mutating func apply(_ property: Pocket3CameraPropertyRecord) -> Bool {
        readback.apply(property)
    }
}

/// Pure camera status/recording behavior previously embedded in Pocket3GimbalSession.
enum Pocket3CameraStatus {
    struct StatusFields: Equatable {
        let storageTotalMiB: UInt32
        let storageFreeMiB: UInt32
        let remainingRecordSeconds: UInt16
        let elapsedRecordSeconds: UInt16
        let shootingMode: UInt8
        let videoLike: Bool
    }

    struct StorageFields: Equatable {
        let storeCount: UInt8
        let sdTotalMiB: UInt32
        let sdFreeMiB: UInt32
    }

    static func recordingCommand(_ recording: Bool) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02,
            cmd: 0x02,
            payload: Data([recording ? 0x01 : 0x00]),
            label: recording ? "camera record start 02/02 01" : "camera record stop 02/02 00"
        )
    }

    static func statusFields(payload: Data) -> StatusFields? {
        guard payload.count >= 58 else { return nil }
        return StatusFields(
            storageTotalMiB: u32le(payload, 5),
            storageFreeMiB: u32le(payload, 9),
            remainingRecordSeconds: u16le(payload, 17),
            elapsedRecordSeconds: u16le(payload, 29),
            shootingMode: payload[57],
            videoLike: payload[4] == 0x01
        )
    }

    static func storageFields(payload: Data) -> StorageFields? {
        // Pocket 3 is a single-store (microSD) device. Its 02/DC body is 22 bytes.
        guard payload.count >= 22 else { return nil }
        return StorageFields(
            storeCount: payload[2],
            sdTotalMiB: u32le(payload, 6),
            sdFreeMiB: u32le(payload, 10)
        )
    }

    static func recordingActive(statusByte: UInt8) -> Bool {
        (statusByte & 0x80) != 0
    }

    static func recordingTransitioning(statusByte: UInt8) -> Bool {
        (statusByte & 0x40) != 0
    }

    static func recordRequestResolved(targetRecording: Bool, statusByte: UInt8) -> Bool {
        if recordingTransitioning(statusByte: statusByte) {
            return true
        }
        return recordingActive(statusByte: statusByte) == targetRecording
    }

    static func recordingDescription(statusByte: UInt8) -> String {
        switch statusByte {
        case 0x01: return "IDLE"
        case 0x41: return "TRANSITION"
        case 0xC1: return "TRANSITION+REC"
        case 0x81: return "RECORDING"
        default: return "UNKNOWN"
        }
    }

    private static func u16le(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32le(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
    }
}

/// Camera-domain API. It translates user intent into the existing confirmed command encoders,
/// while the injected handlers keep session ownership and command timing in the existing pump.
struct Pocket3CameraControl {
    typealias CommandHandler = (Pocket3CameraCommand) -> Void
    typealias RecordingHandler = (Bool) -> Void

    private let sendCommand: CommandHandler
    private let setRecordingHandler: RecordingHandler

    init(sendCommand: @escaping CommandHandler, setRecording: @escaping RecordingHandler) {
        self.sendCommand = sendCommand
        self.setRecordingHandler = setRecording
    }

    func setShootingMode(_ mode: Pocket3CameraSettings.ShootingMode) {
        sendCommand(Pocket3CameraSettings.shootingMode(mode))
    }

    func setVideoFormat(
        resolution: Pocket3CameraSettings.VideoResolution,
        frameRate: Pocket3CameraSettings.FrameRate,
        slowMotionMultiplier: Pocket3CameraSettings.SlowMotionMultiplier = .none
    ) {
        sendCommand(
            Pocket3CameraSettings.videoFormat(
                resolution: resolution,
                frameRate: frameRate,
                slowMotionMultiplier: slowMotionMultiplier
            )
        )
    }

    func setVideoCompression(_ compression: Pocket3CameraSettings.VideoCompression) {
        sendCommand(Pocket3CameraSettings.videoCompression(compression))
    }

    func setProEnabled(_ enabled: Bool) {
        sendCommand(Pocket3CameraSettings.proEnabled(enabled))
    }

    func setExposureMode(_ mode: Pocket3CameraSettings.ExposureMode) {
        sendCommand(Pocket3CameraSettings.exposureMode(mode))
    }

    func setManualISO(_ iso: Pocket3CameraSettings.ManualISO) {
        sendCommand(Pocket3CameraSettings.manualISO(iso))
    }

    func setISOMax(_ isoMax: Pocket3CameraSettings.ISOMax) {
        sendCommand(Pocket3CameraSettings.isoMax(isoMax))
    }

    func setManualShutter(_ shutter: Pocket3CameraSettings.ManualShutter) {
        sendCommand(Pocket3CameraSettings.manualShutter(shutter))
    }

    @discardableResult
    func setAutoEV(thirdStops: Int) -> Bool {
        guard let command = Pocket3CameraSettings.autoEV(thirdStops: thirdStops) else { return false }
        sendCommand(command)
        return true
    }

    @discardableResult
    func setWhiteBalance(_ whiteBalance: Pocket3CameraSettings.WhiteBalance) -> Bool {
        guard let command = Pocket3CameraSettings.whiteBalance(whiteBalance) else { return false }
        sendCommand(command)
        return true
    }

    func setColorProfile(_ profile: Pocket3CameraSettings.ColorProfile) {
        sendCommand(Pocket3CameraSettings.colorProfile(profile))
    }

    func setFocusMode(_ mode: Pocket3CameraSettings.FocusMode) {
        sendCommand(Pocket3CameraSettings.focusMode(mode))
    }

    func setProductShowcaseEnabled(_ enabled: Bool) {
        sendCommand(Pocket3CameraSettings.productShowcaseEnabled(enabled))
    }

    func shootPhoto() {
        sendCommand(Pocket3CameraSettings.shootPhoto())
    }

    func setPhotoFrame(_ frame: Pocket3CameraSettings.PhotoFrame) {
        sendCommand(Pocket3CameraSettings.photoFrame(frame))
    }

    func setPhotoFormat(_ format: Pocket3CameraSettings.PhotoFormat) {
        sendCommand(Pocket3CameraSettings.photoFormat(format))
    }

    func setPhotoCountdown(_ countdown: Pocket3CameraSettings.PhotoCountdown) {
        sendCommand(Pocket3CameraSettings.photoCountdown(countdown))
    }

    func setTimelapse(_ configuration: Pocket3CameraSettings.TimelapseConfiguration) {
        sendCommand(Pocket3CameraSettings.timelapse(configuration))
    }

    func setMotionlapseDirection(
        _ direction: Pocket3CameraSettings.MotionlapseDirection,
        currentMode: Pocket3CameraShootingMode?
    ) {
        if currentMode != .motionlapse {
            sendCommand(Pocket3CameraSettings.motionlapseMode())
        }
        sendCommand(Pocket3CameraSettings.motionlapseDirection(direction))
    }

    func previewMotionlapse() {
        sendCommand(Pocket3CameraSettings.motionlapsePreview())
    }

    func setMotionlapseWaypoint(
        slot: Pocket3CameraSettings.MotionlapseWaypointSlot,
        intervalTenths: UInt16,
        durationSeconds: UInt32,
        pitchTenths: Int16,
        rollTenths: Int16,
        yawTenths: Int16
    ) {
        sendCommand(
            Pocket3CameraSettings.motionlapseWaypoint(
                slot: slot,
                intervalTenths: intervalTenths,
                durationSeconds: durationSeconds,
                pitchTenths: pitchTenths,
                rollTenths: rollTenths,
                yawTenths: yawTenths
            )
        )
    }

    func deleteMotionlapseWaypoint(
        slot: Pocket3CameraSettings.MotionlapseWaypointSlot,
        intervalTenths: UInt16,
        durationSeconds: UInt32
    ) {
        sendCommand(
            Pocket3CameraSettings.deleteMotionlapseWaypoint(
                slot: slot,
                intervalTenths: intervalTenths,
                durationSeconds: durationSeconds
            )
        )
    }

    func setHyperlapseSpeed(_ speed: Pocket3CameraSettings.HyperlapseSpeed) {
        sendCommand(Pocket3CameraSettings.hyperlapseSpeed(speed))
    }

    func setPanoramaType(_ type: Pocket3CameraSettings.PanoramaType) {
        sendCommand(Pocket3CameraSettings.panoramaType(type))
    }

    func setPanoramaPhotoFormat(_ format: Pocket3CameraSettings.PanoramaPhotoFormat) {
        sendCommand(Pocket3CameraSettings.panoramaPhotoFormat(format))
    }

    func shootPanorama() {
        sendCommand(Pocket3CameraSettings.shootPanorama())
    }

    func setAudioChannel(_ channel: Pocket3CameraSettings.AudioChannel) {
        sendCommand(Pocket3CameraSettings.audioChannel(channel))
    }

    func setRecording(_ recording: Bool) {
        setRecordingHandler(recording)
    }
}

/// Capture-confirmed camera menu policy shared by product UI and future public-safe clients.
enum Pocket3CameraPolicy {
    static func manualShutters(
        shootingMode: Pocket3CameraShootingMode?,
        videoFrameRate: Pocket3CameraSettings.FrameRate?
    ) -> [Pocket3CameraSettings.ManualShutter]? {
        switch shootingMode {
        case .photo:
            return Pocket3CameraSettings.ManualShutter.allCases

        case .video:
            guard let videoFrameRate,
                  let minimum = minimumVideoShutterDenominator(videoFrameRate) else {
                return nil
            }
            return Pocket3CameraSettings.ManualShutter.allCases.filter {
                $0.reciprocalDenominator >= minimum
            }

        default:
            return nil
        }
    }

    static func videoFormatSupported(
        resolution: Pocket3CameraSettings.VideoResolution,
        sensorAspectRatio: Pocket3SensorAspectRatio
    ) -> Bool {
        switch sensorAspectRatio {
        case .landscape:
            return !isPortraitVideoResolution(resolution)
        case .portrait:
            return isPortraitVideoResolution(resolution)
        }
    }

    private static func minimumVideoShutterDenominator(
        _ frameRate: Pocket3CameraSettings.FrameRate
    ) -> Double? {
        switch frameRate {
        case .fps24, .fps25:
            return 25
        case .fps30:
            return 30
        case .fps48, .fps50:
            return 50
        case .fps60:
            return 60
        case .fps120, .fps240:
            return nil
        }
    }

    private static func isPortraitVideoResolution(
        _ resolution: Pocket3CameraSettings.VideoResolution
    ) -> Bool {
        switch resolution {
        case .portrait1080, .portrait2_7K, .portrait3K:
            return true
        default:
            return false
        }
    }
}
