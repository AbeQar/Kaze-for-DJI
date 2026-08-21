import Foundation

/// A single capture-derived Pocket 3 camera command.
///
/// Camera settings in this file target Camera(receiverType 0x01, receiverId 0)
/// with cmdType 2 / DUML request flags 0x40 unless explicitly noted otherwise.
struct Pocket3CameraCommand: Equatable {
    let set: UInt8
    let cmd: UInt8
    let payload: Data
    let receiverType: Int
    let receiverId: Int
    let cmdType: Int
    let label: String

    init(
        set: UInt8,
        cmd: UInt8,
        payload: Data,
        receiverType: Int = 0x01,
        receiverId: Int = 0,
        cmdType: Int = 2,
        label: String
    ) {
        self.set = set
        self.cmd = cmd
        self.payload = payload
        self.receiverType = receiverType
        self.receiverId = receiverId
        self.cmdType = cmdType
        self.label = label
    }
}

/// Capture-confirmed Pocket 3 setting encoders derived from DJI Mimo 2.11.5 traffic.
///
/// This intentionally contains only controls whose write payloads are isolated well enough to
/// send without replaying unrelated state. Composite/ambiguous captures (beauty block, wind /
/// directional-audio structure, motionlapse waypoint block, gimbal mode selector, and RTMP) stay
/// out of the writable API until their structures are fully decoded.
enum Pocket3CameraSettings {
    enum ShootingMode: UInt8, CaseIterable {
        case slowMotion = 0x00
        case video = 0x01
        case timelapse = 0x02
        case photo = 0x05
        case hyperlapse = 0x0A
        case panorama = 0x0C
        case lowLight = 0x28
    }

    enum VideoResolution: UInt8, CaseIterable {
        case p1080 = 0x0A
        case p4K = 0x10
        case p2_7K = 0x2D
        // Hardware-confirmed Portrait / 9:16 video-format codes.
        case portrait1080 = 0x42
        case portrait2_7K = 0x43
        case square1080 = 0x69
        case square2160 = 0x6A
        case square3K = 0x6B
        case portrait3K = 0x6C
    }

    enum FrameRate: UInt8, CaseIterable {
        case fps24 = 0x01
        case fps25 = 0x02
        case fps30 = 0x03
        case fps48 = 0x04
        case fps50 = 0x05
        case fps60 = 0x06
        case fps120 = 0x07
        case fps240 = 0x08
    }

    enum SlowMotionMultiplier: UInt8 {
        case none = 0x00
        case x4 = 0x04
        case x8 = 0x08
    }

    enum VideoCompression: UInt8 {
        case h264Compatibility = 0x00
        case hevcEfficiency = 0x01
    }

    enum ExposureMode: UInt8 {
        case auto = 0x01
        case manual = 0x04
    }

    /// Complete Pocket 3 ISO menu captured in C3-ISO-full.
    /// Code 0x01 is not exposed by the Pocket 3 Mimo menu and is intentionally unnamed.
    enum ManualISO: UInt8, CaseIterable {
        case auto = 0x00
        case iso50 = 0x02
        case iso100 = 0x03
        case iso200 = 0x04
        case iso400 = 0x05
        case iso800 = 0x06
        case iso1600 = 0x07
        case iso3200 = 0x08
        case iso6400 = 0x09

        var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .iso50: return "50"
            case .iso100: return "100"
            case .iso200: return "200"
            case .iso400: return "400"
            case .iso800: return "800"
            case .iso1600: return "1600"
            case .iso3200: return "3200"
            case .iso6400: return "6400"
            }
        }
    }

    /// Complete Pocket 3 ISO MAX menu captured in C3-ISO-MAX.
    /// 02/8E PID 0x000F carries a one-byte selector:
    /// 1=100, 2=200, 3=400, 4=800, 5=1600, 6=3200, 7=6400.
    enum ISOMax: UInt8, CaseIterable {
        case iso100 = 0x01
        case iso200 = 0x02
        case iso400 = 0x03
        case iso800 = 0x04
        case iso1600 = 0x05
        case iso3200 = 0x06
        case iso6400 = 0x07

        var displayName: String {
            switch self {
            case .iso100: return "100"
            case .iso200: return "200"
            case .iso400: return "400"
            case .iso800: return "800"
            case .iso1600: return "1600"
            case .iso3200: return "3200"
            case .iso6400: return "6400"
            }
        }
    }

    /// Complete Pocket 3 manual-shutter menu captured in C3-SHUTTER-photo-full.
    /// Exact 02/28 payload bytes are retained for the fractional-denominator values.
    enum ManualShutter: CaseIterable, Hashable {
        case oneSecond
        case reciprocal1_25
        case reciprocal1_67
        case reciprocal2
        case reciprocal2_5
        case reciprocal3
        case reciprocal4
        case reciprocal5
        case reciprocal6_25
        case reciprocal8
        case reciprocal10
        case reciprocal12_5
        case reciprocal15
        case reciprocal20
        case reciprocal25
        case reciprocal30
        case reciprocal40
        case reciprocal50
        case reciprocal60
        case reciprocal80
        case reciprocal100
        case reciprocal120
        case reciprocal160
        case reciprocal200
        case reciprocal240
        case reciprocal320
        case reciprocal400
        case reciprocal500
        case reciprocal640
        case reciprocal800
        case reciprocal1000
        case reciprocal1250
        case reciprocal1600
        case reciprocal2000
        case reciprocal2500
        case reciprocal3200
        case reciprocal4000
        case reciprocal5000
        case reciprocal6400
        case reciprocal8000

        var displayName: String {
            switch self {
            case .oneSecond: return "1\""
            case .reciprocal1_25: return "1/1.25"
            case .reciprocal1_67: return "1/1.67"
            case .reciprocal2: return "1/2"
            case .reciprocal2_5: return "1/2.5"
            case .reciprocal3: return "1/3"
            case .reciprocal4: return "1/4"
            case .reciprocal5: return "1/5"
            case .reciprocal6_25: return "1/6.25"
            case .reciprocal8: return "1/8"
            case .reciprocal10: return "1/10"
            case .reciprocal12_5: return "1/12.5"
            case .reciprocal15: return "1/15"
            case .reciprocal20: return "1/20"
            case .reciprocal25: return "1/25"
            case .reciprocal30: return "1/30"
            case .reciprocal40: return "1/40"
            case .reciprocal50: return "1/50"
            case .reciprocal60: return "1/60"
            case .reciprocal80: return "1/80"
            case .reciprocal100: return "1/100"
            case .reciprocal120: return "1/120"
            case .reciprocal160: return "1/160"
            case .reciprocal200: return "1/200"
            case .reciprocal240: return "1/240"
            case .reciprocal320: return "1/320"
            case .reciprocal400: return "1/400"
            case .reciprocal500: return "1/500"
            case .reciprocal640: return "1/640"
            case .reciprocal800: return "1/800"
            case .reciprocal1000: return "1/1000"
            case .reciprocal1250: return "1/1250"
            case .reciprocal1600: return "1/1600"
            case .reciprocal2000: return "1/2000"
            case .reciprocal2500: return "1/2500"
            case .reciprocal3200: return "1/3200"
            case .reciprocal4000: return "1/4000"
            case .reciprocal5000: return "1/5000"
            case .reciprocal6400: return "1/6400"
            case .reciprocal8000: return "1/8000"
            }
        }

        var reciprocalDenominator: Double {
            switch self {
            case .oneSecond: return 1.0
            case .reciprocal1_25: return 1.25
            case .reciprocal1_67: return 1.67
            case .reciprocal2: return 2
            case .reciprocal2_5: return 2.5
            case .reciprocal3: return 3
            case .reciprocal4: return 4
            case .reciprocal5: return 5
            case .reciprocal6_25: return 6.25
            case .reciprocal8: return 8
            case .reciprocal10: return 10
            case .reciprocal12_5: return 12.5
            case .reciprocal15: return 15
            case .reciprocal20: return 20
            case .reciprocal25: return 25
            case .reciprocal30: return 30
            case .reciprocal40: return 40
            case .reciprocal50: return 50
            case .reciprocal60: return 60
            case .reciprocal80: return 80
            case .reciprocal100: return 100
            case .reciprocal120: return 120
            case .reciprocal160: return 160
            case .reciprocal200: return 200
            case .reciprocal240: return 240
            case .reciprocal320: return 320
            case .reciprocal400: return 400
            case .reciprocal500: return 500
            case .reciprocal640: return 640
            case .reciprocal800: return 800
            case .reciprocal1000: return 1000
            case .reciprocal1250: return 1250
            case .reciprocal1600: return 1600
            case .reciprocal2000: return 2000
            case .reciprocal2500: return 2500
            case .reciprocal3200: return 3200
            case .reciprocal4000: return 4000
            case .reciprocal5000: return 5000
            case .reciprocal6400: return 6400
            case .reciprocal8000: return 8000
            }
        }

        fileprivate var payload: Data {
            switch self {
            case .oneSecond:
                return Data([0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x40])
            case .reciprocal1_25:
                return Data([0x01, 0x01, 0x80, 0x19, 0x00, 0x00, 0x40])
            case .reciprocal1_67:
                return Data([0x01, 0x01, 0x80, 0x43, 0x00, 0x00, 0x40])
            case .reciprocal2_5:
                return Data([0x01, 0x02, 0x80, 0x05, 0x00, 0x00, 0x40])
            case .reciprocal6_25:
                return Data([0x01, 0x06, 0x80, 0x19, 0x00, 0x00, 0x40])
            case .reciprocal12_5:
                return Data([0x01, 0x0C, 0x80, 0x05, 0x00, 0x00, 0x40])
            default:
                let denominator = UInt16(reciprocalDenominator)
                let encoded = UInt16(0x8000) | denominator
                return Data([
                    0x01,
                    UInt8(encoded & 0xFF),
                    UInt8((encoded >> 8) & 0xFF),
                    0x00, 0x00, 0x00, 0x40
                ])
            }
        }
    }

    enum WhiteBalance {
        case auto
        case customKelvin(Int)
    }

    enum ColorProfile: UInt8 {
        case normal = 0x00
        case hlg = 0x3C
        case dLogM = 0x3D
    }

    enum FocusMode: UInt8 {
        case single = 0x01
        case continuous = 0x02
    }

    enum PhotoFrame: UInt8 {
        case sixteenByNine = 0x01
        case oneByOne = 0x03
    }

    enum PhotoFormat: UInt8 {
        case jpeg = 0x01
        case jpegAndRaw = 0x02
    }

    enum PhotoCountdown: UInt8 {
        case off = 0
        case seconds3 = 3
        case seconds5 = 5
        case seconds7 = 7
    }

    enum TimelapseOutput: UInt8 {
        case video = 0x00
        case jpegAndVideo = 0x02
        case rawAndVideo = 0x03
    }

    /// Capture-confirmed Motionlapse direction selector carried by 02/8E PID 0x0037.
    enum MotionlapseDirection: UInt8 {
        case custom = 0x00
        case leftToRight = 0x01
        case rightToLeft = 0x02
    }

    /// Capture-confirmed sequential Custom Motionlapse waypoint slots from C2-TML-021.
    /// Mimo emitted 5, 9, 13, 17 for point writes and 6, 10, 14, 18 for deletes.
    enum MotionlapseWaypointSlot: UInt16 {
        case point1 = 0x0005
        case point2 = 0x0009
        case point3 = 0x000D
        case point4 = 0x0011

        init?(pointNumber: Int) {
            switch pointNumber {
            case 1: self = .point1
            case 2: self = .point2
            case 3: self = .point3
            case 4: self = .point4
            default: return nil
            }
        }

        /// In the deletion capture, each point's delete token is the write token + 1.
        var deleteToken: UInt16 { rawValue + 1 }
    }

    enum HyperlapseSpeed: UInt8 {
        case auto = 0x00
        case x2 = 0x02
        case x5 = 0x05
        case x10 = 0x0A
        case x15 = 0x0F
        case x30 = 0x1E
    }

    enum PanoramaType: UInt8 {
        case degrees180 = 0x05
        case grid3x3 = 0x07
    }

    enum PanoramaPhotoFormat: UInt8 {
        // Final settled states from C2-PAN-010. JPEG selection included an intermediate 0x01 write
        // before settling at 0x03; RAW settled at 0x01.
        case raw = 0x01
        case jpeg = 0x03
    }

    enum AudioChannel: UInt8 {
        case mono = 0x01
        case stereo = 0x02
    }

    struct TimelapseConfiguration: Equatable {
        /// Interval in tenths of a second. The complete Mimo menu was captured in C3-TIMELAPSE-interval-full.
        let intervalTenths: UInt16
        /// Duration in seconds. Zero is the captured infinite-duration representation.
        let durationSeconds: UInt32
        let output: TimelapseOutput

        init(intervalTenths: UInt16, durationSeconds: UInt32, output: TimelapseOutput) {
            self.intervalTenths = intervalTenths
            self.durationSeconds = durationSeconds
            self.output = output
        }
    }

    static func shootingMode(_ mode: ShootingMode) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0xE1, payload: Data([mode.rawValue]),
            label: String(format: "shooting mode 02/E1 %02X", mode.rawValue)
        )
    }

    /// Capture-confirmed Mimo transition into moving Motionlapse.
    static func motionlapseMode() -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0xE1, payload: Data([0x18]),
            label: "motionlapse mode 02/E1 18"
        )
    }

    static func videoFormat(
        resolution: VideoResolution,
        frameRate: FrameRate,
        slowMotionMultiplier: SlowMotionMultiplier = .none
    ) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02,
            cmd: 0x18,
            payload: Data([resolution.rawValue, frameRate.rawValue, 0x00, slowMotionMultiplier.rawValue, 0x00]),
            label: String(
                format: "video format 02/18 res=%02X fps=%02X slow=%02X",
                resolution.rawValue, frameRate.rawValue, slowMotionMultiplier.rawValue
            )
        )
    }

    static func videoCompression(_ compression: VideoCompression) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0xAB, payload: Data([compression.rawValue, 0x00]),
            label: String(format: "video compression 02/AB %02X00", compression.rawValue)
        )
    }

    static func proEnabled(_ enabled: Bool) -> Pocket3CameraCommand {
        keyedParameter(pid: 0x0000, value: Data([enabled ? 0x01 : 0x00]), label: "Pro")
    }

    static func exposureMode(_ mode: ExposureMode) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0x1E, payload: Data([mode.rawValue, 0x00]),
            label: String(format: "exposure mode 02/1E %02X00", mode.rawValue)
        )
    }

    static func manualISO(_ iso: ManualISO) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0x2A, payload: Data([iso.rawValue]),
            label: String(format: "manual ISO 02/2A %02X", iso.rawValue)
        )
    }

    /// Capture-confirmed ISO MAX setter from C3-ISO-MAX.
    /// Uses the existing keyed 02/8E parameter writer with PID 0x000F.
    static func isoMax(_ isoMax: ISOMax) -> Pocket3CameraCommand {
        keyedParameter(
            pid: 0x000F,
            value: Data([isoMax.rawValue]),
            label: "ISO MAX"
        )
    }

    static func manualShutter(_ shutter: ManualShutter) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02,
            cmd: 0x28,
            payload: shutter.payload,
            label: "manual shutter 02/28 \(shutter.displayName)"
        )
    }


    /// AUTO EV compensation in one-third-stop units: -9...+9 corresponds to -3.0...+3.0 EV.
    /// Captured encoding is 0x10 at 0 EV, with one code step per 1/3 EV.
    static func autoEV(thirdStops: Int) -> Pocket3CameraCommand? {
        guard (-9...9).contains(thirdStops) else { return nil }
        let code = UInt8(Int(0x10) + thirdStops)
        return Pocket3CameraCommand(
            set: 0x02, cmd: 0x2E, payload: Data([code]),
            label: String(format: "AUTO EV 02/2E %02X (%+.1f EV)", code, Double(thirdStops) / 3.0)
        )
    }

    static func whiteBalance(_ whiteBalance: WhiteBalance) -> Pocket3CameraCommand? {
        switch whiteBalance {
        case .auto:
            return Pocket3CameraCommand(
                set: 0x02, cmd: 0x2C, payload: Data([0, 0, 0, 0, 0]),
                label: "white balance AUTO 02/2C 0000000000"
            )
        case .customKelvin(let kelvin):
            guard kelvin >= 2000, kelvin <= 10_000, kelvin % 100 == 0 else { return nil }
            let encoded = UInt8(kelvin / 100)
            return Pocket3CameraCommand(
                set: 0x02, cmd: 0x2C, payload: Data([0x06, encoded, 0, 0, 0]),
                label: String(format: "white balance %dK 02/2C 06%02X000000", kelvin, encoded)
            )
        }
    }

    static func colorProfile(_ profile: ColorProfile) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0x42, payload: Data([profile.rawValue]),
            label: String(format: "color profile 02/42 %02X", profile.rawValue)
        )
    }

    static func focusMode(_ mode: FocusMode) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0x24, payload: Data([mode.rawValue]),
            label: String(format: "focus mode 02/24 %02X", mode.rawValue)
        )
    }

    static func productShowcaseEnabled(_ enabled: Bool) -> Pocket3CameraCommand {
        keyedParameter(pid: 0x003B, value: Data([0x01, enabled ? 0x01 : 0x00]), label: "Product Showcase")
    }

    /// Generic still-photo shutter trigger. One press captures once in the Pocket's current
    /// Photo sub-mode; countdown/burst behavior is handled by the camera.
    static func shootPhoto() -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0x01, payload: Data([0x01]),
            label: "shoot photo 02/01 01"
        )
    }

    static func photoFrame(_ frame: PhotoFrame) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0x12, payload: Data([0x00, frame.rawValue]),
            label: String(format: "photo frame 02/12 00%02X", frame.rawValue)
        )
    }

    static func photoFormat(_ format: PhotoFormat) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0x16, payload: Data([format.rawValue]),
            label: String(format: "photo format 02/16 %02X", format.rawValue)
        )
    }

    static func photoCountdown(_ countdown: PhotoCountdown) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02,
            cmd: 0x4A,
            payload: Data([0x00, 0x01, countdown.rawValue, 0x00, 0x00, 0x00]),
            label: String(format: "photo countdown 02/4A 0001%02X000000", countdown.rawValue)
        )
    }

    static func timelapse(_ configuration: TimelapseConfiguration) -> Pocket3CameraCommand {
        var payload = Data([0x04, 0x00, configuration.output.rawValue])
        appendLE16(configuration.intervalTenths, to: &payload)
        appendLE32(configuration.durationSeconds, to: &payload)
        payload.append(contentsOf: Array(repeating: UInt8(0), count: 7))
        return Pocket3CameraCommand(
            set: 0x02, cmd: 0x6C, payload: payload,
            label: "timelapse configuration 02/6C"
        )
    }

    static func motionlapseDirection(_ direction: MotionlapseDirection) -> Pocket3CameraCommand {
        keyedParameter(
            pid: 0x0037,
            value: Data([direction.rawValue]),
            label: "Motionlapse Direction"
        )
    }

    /// Capture-confirmed Mimo Custom Motionlapse path preview trigger.
    /// C2 preview-only capture: 02/8E PID 0x0036, two-byte value 00 00.
    /// The Pocket ACKs the command and automatically clears preview-active readback
    /// when traversal completes; no separate stop command was observed.
    static func motionlapsePreview() -> Pocket3CameraCommand {
        keyedParameter(
            pid: 0x0036,
            value: Data([0x00, 0x00]),
            label: "Motionlapse Preview"
        )
    }

    /// Capture-derived Custom Motionlapse point writer from C2-TML-021.
    /// Payload: 05 + slot + interval + duration + yaw/roll/pitch (all LE) + 00.
    /// Important: the waypoint wire order reverses the outer two 04/05 telemetry axes.
    static func motionlapseWaypoint(
        slot: MotionlapseWaypointSlot,
        intervalTenths: UInt16,
        durationSeconds: UInt32,
        pitchTenths: Int16,
        rollTenths: Int16,
        yawTenths: Int16
    ) -> Pocket3CameraCommand {
        var payload = Data([0x05])
        appendLE16(slot.rawValue, to: &payload)
        appendLE16(intervalTenths, to: &payload)
        appendLE32(durationSeconds, to: &payload)
        appendLE16(UInt16(bitPattern: yawTenths), to: &payload)
        appendLE16(UInt16(bitPattern: rollTenths), to: &payload)
        appendLE16(UInt16(bitPattern: pitchTenths), to: &payload)
        payload.append(0x00)

        return Pocket3CameraCommand(
            set: 0x02, cmd: 0x6C, payload: payload,
            label: "Motionlapse Custom Waypoint \(slot)"
        )
    }

    /// Capture-confirmed Custom Motionlapse delete-last-point writer.
    /// Mimo deleted points in reverse order (4→3→2→1→0) with the point's
    /// delete token, current interval/duration, zeroed yaw/roll/pitch, and trailing 00.
    static func deleteMotionlapseWaypoint(
        slot: MotionlapseWaypointSlot,
        intervalTenths: UInt16,
        durationSeconds: UInt32
    ) -> Pocket3CameraCommand {
        var payload = Data([0x05])
        appendLE16(slot.deleteToken, to: &payload)
        appendLE16(intervalTenths, to: &payload)
        appendLE32(durationSeconds, to: &payload)
        payload.append(contentsOf: Array(repeating: UInt8(0), count: 7))

        return Pocket3CameraCommand(
            set: 0x02, cmd: 0x6C, payload: payload,
            label: "Delete Motionlapse Custom Waypoint \(slot)"
        )
    }

    static func hyperlapseSpeed(_ speed: HyperlapseSpeed) -> Pocket3CameraCommand {
        var payload = Data([0x0B, 0x00, 0x00, speed.rawValue])
        payload.append(contentsOf: Array(repeating: UInt8(0), count: 12))
        return Pocket3CameraCommand(
            set: 0x02, cmd: 0x6C, payload: payload,
            label: String(format: "hyperlapse speed 02/6C %02X", speed.rawValue)
        )
    }

    static func panoramaType(_ type: PanoramaType) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0x6E, payload: Data([type.rawValue]),
            label: String(format: "panorama type 02/6E %02X", type.rawValue)
        )
    }

    static func panoramaPhotoFormat(_ format: PanoramaPhotoFormat) -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0xE7, payload: Data([format.rawValue, 0x00]),
            label: String(format: "panorama photo format 02/E7 %02X00", format.rawValue)
        )
    }

    /// Capture-confirmed Panorama shutter/start trigger from C2-PAN-090.
    /// The same 02/01 payload 07 starts both 180° and 3x3 Panorama captures;
    /// the active Panorama type is selected separately with 02/6E.
    static func shootPanorama() -> Pocket3CameraCommand {
        Pocket3CameraCommand(
            set: 0x02, cmd: 0x01, payload: Data([0x07]),
            label: "start panorama 02/01 07"
        )
    }

    static func audioChannel(_ channel: AudioChannel) -> Pocket3CameraCommand {
        keyedParameter(pid: 0x0020, value: Data([channel.rawValue]), label: "Audio Channel")
    }

    static func keyedParameter(pid: UInt16, value: Data, label: String) -> Pocket3CameraCommand {
        precondition(value.count <= 255)
        var payload = Data([
            0x01, 0x01,
            UInt8(pid & 0xFF), UInt8((pid >> 8) & 0xFF),
            UInt8(value.count)
        ])
        payload.append(value)
        return Pocket3CameraCommand(
            set: 0x02, cmd: 0x8E, payload: payload,
            label: String(format: "%@ PID 0x%04X", label, pid)
        )
    }

    private static func appendLE16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private static func appendLE32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
