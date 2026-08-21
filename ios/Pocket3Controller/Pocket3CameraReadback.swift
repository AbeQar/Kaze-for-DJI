import Foundation

/// Capture-derived decoder for DJI Mimo's 00/99 named-property subscription bus.
///
/// Cold-connect capture (Pocket already configured before Mimo connected) showed that Mimo
/// subscribes to named properties and the Pocket then pushes current values continuously.
/// This is readback only: it does not change camera settings.
struct Pocket3CameraPropertyRecord: Equatable {
    let transactionID: UInt32
    let name: String
    let value: Data
}

/// Shooting-mode readback decoded from the capture-confirmed 02/80 status byte.
///
/// These raw IDs are confirmed for readback. Mimo captures also confirm 02/E1 0x02 / 0x18
/// as the Timelapse / moving-Motionlapse transition; other shooting-mode writers remain
/// independently validated features.
enum Pocket3CameraShootingMode: UInt8, CaseIterable, Equatable {
    case slowMotion = 0x00
    case video = 0x01
    case timelapse = 0x02
    case photo = 0x05
    case hyperlapse = 0x0A
    case panorama = 0x0C
    // Hardware-confirmed: switching the Pocket itself to Motionlapse produces 02/80 = 0x18.
    case motionlapse = 0x18
    case lowLight = 0x28

    var displayName: String {
        switch self {
        case .slowMotion: return "Slow Motion"
        case .video: return "Video"
        case .timelapse: return "Timelapse"
        case .photo: return "Photo"
        case .hyperlapse: return "Hyperlapse"
        case .panorama: return "Panorama"
        case .motionlapse: return "Motionlapse"
        case .lowLight: return "Low-Light"
        }
    }

    var shortLabel: String {
        switch self {
        case .slowMotion: return "SLO-MO"
        case .video: return "VIDEO"
        case .timelapse: return "T-LAPSE"
        case .photo: return "PHOTO"
        case .hyperlapse: return "HYPER"
        case .panorama: return "PANO"
        case .motionlapse: return "M-LAPSE"
        case .lowLight: return "LOW-LIGHT"
        }
    }
}

enum Pocket3WhiteBalanceReadback: Equatable {
    case auto
    case customKelvin(Int)
}

/// Effective sensor/output aspect readback from `cam_sensor_aspect_ratio`.
///
/// Capture-confirmed values:
/// - 0x00 = Landscape
/// - 0x01 = Portrait / vertical
///
/// Pocket "Auto" is a policy, not a third value here: while Auto was selected with the
/// Pocket physically vertical, this property continued to report 0x01.
enum Pocket3SensorAspectRatio: UInt8, Equatable {
    case landscape = 0x00
    case portrait = 0x01

    var displayName: String {
        switch self {
        case .landscape: return "Landscape"
        case .portrait: return "Portrait"
        }
    }
}

struct Pocket3CameraReadbackState: Equatable {
    var videoResolution: Pocket3CameraSettings.VideoResolution?
    var videoFrameRate: Pocket3CameraSettings.FrameRate?
    var sensorAspectRatio: Pocket3SensorAspectRatio?
    var videoCompression: Pocket3CameraSettings.VideoCompression?
    var colorProfile: Pocket3CameraSettings.ColorProfile?
    var whiteBalance: Pocket3WhiteBalanceReadback?
    var exposureMode: Pocket3CameraSettings.ExposureMode?
    var evThirdStops: Int?
    var effectiveISO: UInt32?
    var focusMode: Pocket3CameraSettings.FocusMode?
    var photoFrame: Pocket3CameraSettings.PhotoFrame?
    var photoFormat: Pocket3CameraSettings.PhotoFormat?
    var photoCountdown: Pocket3CameraSettings.PhotoCountdown?
    var timelapseIntervalTenths: UInt16?
    var timelapseDurationSeconds: UInt32?
    var timelapseOutput: Pocket3CameraSettings.TimelapseOutput?
    var hyperlapseSpeed: Pocket3CameraSettings.HyperlapseSpeed?
    var panoramaType: Pocket3CameraSettings.PanoramaType?
    var panoramaPhotoFormat: Pocket3CameraSettings.PanoramaPhotoFormat?
    var motionlapseDirection: Pocket3CameraSettings.MotionlapseDirection?
    var motionlapseWaypointCount: UInt8?
    var motionlapsePreviewActive: Bool?
    var receivedProperties: Set<String> = []

    var hasCoreReadback: Bool { !receivedProperties.isEmpty }

    @discardableResult
    mutating func apply(_ record: Pocket3CameraPropertyRecord) -> Bool {
        var recognized = true

        switch record.name {
        case "cam_video_param_v2":
            guard record.value.count >= 9 else { return false }
            videoResolution = Pocket3CameraSettings.VideoResolution(rawValue: record.value[0])
            videoFrameRate = Pocket3CameraSettings.FrameRate(rawValue: record.value[1])
            videoCompression = Pocket3CameraSettings.VideoCompression(rawValue: record.value[8])

        case "cam_sensor_aspect_ratio":
            guard let raw = record.value.first else { return false }
            sensorAspectRatio = Pocket3SensorAspectRatio(rawValue: raw)

        case "cam_image_effect":
            guard record.value.count >= 6 else { return false }
            colorProfile = Pocket3CameraSettings.ColorProfile(rawValue: record.value[2])
            switch record.value[4] {
            case 0x00:
                whiteBalance = .auto
            case 0x06:
                whiteBalance = .customKelvin(Int(record.value[5]) * 100)
            default:
                whiteBalance = nil
            }

        case "cam_expo_param":
            guard record.value.count >= 20 else { return false }
            let evCode = Int(record.value[6])
            evThirdStops = (0x07...0x19).contains(evCode) ? evCode - 0x10 : nil
            exposureMode = Pocket3CameraSettings.ExposureMode(rawValue: record.value[7])
            effectiveISO = Self.u32le(record.value, 16)

        case "cam_lens_state":
            guard let focusByte = record.value.first else { return false }
            switch focusByte {
            case 0xB1:
                focusMode = .single
            case 0xB2:
                focusMode = .continuous
            default:
                focusMode = nil
            }

        case "cam_photo_param":
            // Capture-confirmed 13-byte photo state:
            //   byte 1 = frame (0x01 16:9, 0x03 1:1)
            //   byte 3 = format (0x01 JPEG, 0x02 JPEG+RAW)
            //   byte 7 = countdown seconds (0, 3, 5, 7)
            guard record.value.count >= 13 else { return false }
            photoFrame = Pocket3CameraSettings.PhotoFrame(rawValue: record.value[1])
            photoFormat = Pocket3CameraSettings.PhotoFormat(rawValue: record.value[3])
            photoCountdown = Pocket3CameraSettings.PhotoCountdown(rawValue: record.value[7])

        case "cam_lapse_param":
            // Capture-confirmed 21-byte Timelapse / Hyperlapse state.
            // Timelapse fields:
            //   byte 0     = output (0x00 Video, 0x02 JPEG+Video, 0x03 RAW+Video)
            //   bytes 1-2  = interval in tenths of a second, UInt16 LE
            //   bytes 5-8  = duration in seconds, UInt32 LE (0 = infinity)
            // Hyperlapse speed (C2-HYP-012 full coverage):
            //   bytes 9-10  = selected speed, UInt16 LE
            //   bytes 11-12 = mirrored selected speed, UInt16 LE
            // Both copies settled to 0, 2, 5, 10, 15, or 30 after the matching 02/6C write.
            // Bytes 3...4 and 13...20 remain intentionally undecoded.
            guard record.value.count >= 21 else { return false }
            timelapseOutput = Pocket3CameraSettings.TimelapseOutput(rawValue: record.value[0])
            timelapseIntervalTenths = Self.u16le(record.value, 1)
            timelapseDurationSeconds = Self.u32le(record.value, 5)

            let speedA = Self.u16le(record.value, 9)
            let speedB = Self.u16le(record.value, 11)
            if speedA == speedB, speedA <= UInt16(UInt8.max) {
                hyperlapseSpeed = Pocket3CameraSettings.HyperlapseSpeed(rawValue: UInt8(speedA))
            } else {
                hyperlapseSpeed = nil
            }

        case "cam_pano_params":
            // Capture-confirmed 3-byte Panorama selector state (C2-PAN-010):
            //   byte 0 = panorama type: 0x05 180°, 0x07 3x3
            //   byte 1 = photo format: 0x03 JPEG, 0x01 RAW
            //   byte 2 remains intentionally undecoded.
            guard record.value.count >= 3 else { return false }
            panoramaType = Pocket3CameraSettings.PanoramaType(rawValue: record.value[0])
            panoramaPhotoFormat = Pocket3CameraSettings.PanoramaPhotoFormat(rawValue: record.value[1])

        case "cam_motionlapse_params":
            // Capture-confirmed structural readback from C2-TML-020 / C2-TML-021
            // plus the isolated Preview capture.
            //   byte 2 = direction selector matching PID 0x0037:
            //            0 Custom, 1 L->R, 2 R->L
            //   byte 3 = 0x80 while Custom path Preview is traversing, 0x00 when idle
            // For Custom only, byte 7 is the saved-waypoint count (0...4).
            // The remaining waypoint-record bytes are intentionally not decoded.
            guard record.value.count >= 8 else { return false }
            motionlapseDirection = Pocket3CameraSettings.MotionlapseDirection(rawValue: record.value[2])
            motionlapsePreviewActive = record.value[3] == 0x80
            if motionlapseDirection == .custom, record.value[7] <= 4 {
                motionlapseWaypointCount = record.value[7]
            } else {
                motionlapseWaypointCount = nil
            }

        default:
            recognized = false
        }

        if recognized {
            receivedProperties.insert(record.name)
        }
        return recognized
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

enum Pocket3CameraPropertyBus {
    static let corePropertyNames = [
        "cam_video_param_v2",
        "cam_sensor_aspect_ratio",
        "cam_image_effect",
        "cam_expo_param",
        "cam_lens_state",
        "cam_photo_param",
        "cam_lapse_param",
        "cam_pano_params",
        "cam_motionlapse_params",
    ]

    /// Build the capture-derived 00/99 subscription request used by Mimo at startup.
    /// Target is DJI receiverType 0x08 / receiverId 1 (DUML target 0x2802).
    static func subscriptionCommand(name: String, transactionID: UInt32) -> Pocket3CameraCommand? {
        guard let nameData = name.data(using: .ascii), nameData.count <= Int(UInt16.max) - 6 else {
            return nil
        }

        var payload = Data([0x02, 0x02, 0x00, 0x00])
        appendLE32(transactionID, to: &payload)
        payload.append(contentsOf: [0x00, 0x00, 0x00])
        appendLE16(UInt16(nameData.count + 6), to: &payload)
        appendLE16(UInt16(nameData.count), to: &payload)
        payload.append(nameData)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])

        return Pocket3CameraCommand(
            set: 0x00,
            cmd: 0x99,
            payload: payload,
            receiverType: 0x08,
            receiverId: 1,
            cmdType: 2,
            label: "Readback subscribe \(name)"
        )
    }

    /// Decode a Pocket -> app 00/99 named-property push (operation 0x06).
    /// Captured layout after the property name is six reserved bytes, a LE16 value length,
    /// then the property value bytes.
    static func parsePush(_ payload: Data) -> Pocket3CameraPropertyRecord? {
        guard payload.count >= 23,
              payload[0] == 0x02,
              payload[1] == 0x06,
              payload[2] == 0x00,
              payload[3] == 0x00 else {
            return nil
        }

        let transactionID = u32le(payload, 4)
        let nameLength = Int(u16le(payload, 13))
        let nameStart = 15
        let nameEnd = nameStart + nameLength
        guard nameLength > 0, nameEnd + 8 <= payload.count else { return nil }

        let nameData = payload[nameStart..<nameEnd]
        guard let name = String(data: nameData, encoding: .ascii) else { return nil }

        let valueLengthOffset = nameEnd + 6
        let valueLength = Int(u16le(payload, valueLengthOffset))
        let valueStart = valueLengthOffset + 2
        let valueEnd = valueStart + valueLength
        guard valueEnd <= payload.count else { return nil }

        return Pocket3CameraPropertyRecord(
            transactionID: transactionID,
            name: name,
            value: Data(payload[valueStart..<valueEnd])
        )
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
