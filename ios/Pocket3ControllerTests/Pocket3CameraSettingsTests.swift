import XCTest
@testable import Pocket3Controller

final class Pocket3CameraSettingsTests: XCTestCase {
    func testVideoFormatEncoding() {
        XCTAssertEqual(
            Pocket3CameraSettings.videoFormat(resolution: .p4K, frameRate: .fps60).payload,
            Data([0x10, 0x06, 0x00, 0x00, 0x00])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.videoFormat(
                resolution: .p1080,
                frameRate: .fps240,
                slowMotionMultiplier: .x8
            ).payload,
            Data([0x0A, 0x08, 0x00, 0x08, 0x00])
        )
    }

    func testSquareVideoResolutionCodes() {
        XCTAssertEqual(Pocket3CameraSettings.VideoResolution.square1080.rawValue, 0x69)
        XCTAssertEqual(Pocket3CameraSettings.VideoResolution.square2160.rawValue, 0x6A)
        XCTAssertEqual(Pocket3CameraSettings.VideoResolution.square3K.rawValue, 0x6B)
    }

    func testPortraitVideoResolutionCodes() {
        XCTAssertEqual(Pocket3CameraSettings.VideoResolution.portrait1080.rawValue, 0x42)
        XCTAssertEqual(Pocket3CameraSettings.VideoResolution.portrait2_7K.rawValue, 0x43)
        XCTAssertEqual(Pocket3CameraSettings.VideoResolution.portrait3K.rawValue, 0x6C)

        XCTAssertEqual(
            Pocket3CameraSettings.videoFormat(resolution: .portrait1080, frameRate: .fps60).payload,
            Data([0x42, 0x06, 0x00, 0x00, 0x00])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.videoFormat(resolution: .portrait3K, frameRate: .fps30).payload,
            Data([0x6C, 0x03, 0x00, 0x00, 0x00])
        )
    }

    func testEVEncoding() {
        XCTAssertEqual(Pocket3CameraSettings.autoEV(thirdStops: -9)?.payload, Data([0x07]))
        XCTAssertEqual(Pocket3CameraSettings.autoEV(thirdStops: 0)?.payload, Data([0x10]))
        XCTAssertEqual(Pocket3CameraSettings.autoEV(thirdStops: 9)?.payload, Data([0x19]))
        XCTAssertNil(Pocket3CameraSettings.autoEV(thirdStops: 10))
    }

    func testWhiteBalanceEncoding() {
        XCTAssertEqual(Pocket3CameraSettings.whiteBalance(.auto)?.payload, Data([0, 0, 0, 0, 0]))
        XCTAssertEqual(
            Pocket3CameraSettings.whiteBalance(.customKelvin(5600))?.payload,
            Data([0x06, 0x38, 0x00, 0x00, 0x00])
        )
        XCTAssertNil(Pocket3CameraSettings.whiteBalance(.customKelvin(5650)))
    }

    func testKeyedParameterEncoding() {
        XCTAssertEqual(
            Pocket3CameraSettings.proEnabled(true).payload,
            Data([0x01, 0x01, 0x00, 0x00, 0x01, 0x01])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.productShowcaseEnabled(true).payload,
            Data([0x01, 0x01, 0x3B, 0x00, 0x02, 0x01, 0x01])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.audioChannel(.stereo).payload,
            Data([0x01, 0x01, 0x20, 0x00, 0x01, 0x02])
        )
    }

    func testPhotoShutterEncoding() {
        let command = Pocket3CameraSettings.shootPhoto()
        XCTAssertEqual(command.set, 0x02)
        XCTAssertEqual(command.cmd, 0x01)
        XCTAssertEqual(command.payload, Data([0x01]))
        XCTAssertEqual(command.receiverType, 0x01)
        XCTAssertEqual(command.cmdType, 2)
    }

    func testPhotoControls() {
        XCTAssertEqual(Pocket3CameraSettings.photoFrame(.oneByOne).payload, Data([0x00, 0x03]))
        XCTAssertEqual(Pocket3CameraSettings.photoFormat(.jpegAndRaw).payload, Data([0x02]))
        XCTAssertEqual(
            Pocket3CameraSettings.photoCountdown(.seconds5).payload,
            Data([0x00, 0x01, 0x05, 0x00, 0x00, 0x00])
        )
    }

    func testTimelapseEncoding() {
        let command = Pocket3CameraSettings.timelapse(
            .init(intervalTenths: 10, durationSeconds: 300, output: .jpegAndVideo)
        )
        XCTAssertEqual(
            command.payload,
            Data([0x04, 0x00, 0x02, 0x0A, 0x00, 0x2C, 0x01, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0])
        )
    }

    func testHyperlapseSpeedEncoding() {
        XCTAssertEqual(
            Pocket3CameraSettings.hyperlapseSpeed(.x15).payload,
            Data([0x0B, 0x00, 0x00, 0x0F] + Array(repeating: UInt8(0), count: 12))
        )
    }

    func testCompleteISOOptionTable() {
        XCTAssertEqual(
            Pocket3CameraSettings.ManualISO.allCases.map(\.rawValue),
            [0x00, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09]
        )
        XCTAssertEqual(
            Pocket3CameraSettings.ManualISO.allCases.map(\.displayName),
            ["Auto", "50", "100", "200", "400", "800", "1600", "3200", "6400"]
        )
    }

    func testCompleteISOMaxOptionTable() {
        XCTAssertEqual(
            Pocket3CameraSettings.ISOMax.allCases.map(\.rawValue),
            [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]
        )
        XCTAssertEqual(
            Pocket3CameraSettings.ISOMax.allCases.map(\.displayName),
            ["100", "200", "400", "800", "1600", "3200", "6400"]
        )

        for isoMax in Pocket3CameraSettings.ISOMax.allCases {
            let command = Pocket3CameraSettings.isoMax(isoMax)
            XCTAssertEqual(command.set, 0x02)
            XCTAssertEqual(command.cmd, 0x8E)
            XCTAssertEqual(
                command.payload,
                Data([0x01, 0x01, 0x0F, 0x00, 0x01, isoMax.rawValue])
            )
        }
    }

    func testManualShutterEncoding() {
        let oneSecond = Pocket3CameraSettings.manualShutter(.oneSecond)
        XCTAssertEqual(oneSecond.set, 0x02)
        XCTAssertEqual(oneSecond.cmd, 0x28)
        XCTAssertEqual(oneSecond.payload, Data([0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x40]))

        XCTAssertEqual(
            Pocket3CameraSettings.manualShutter(.reciprocal1_25).payload,
            Data([0x01, 0x01, 0x80, 0x19, 0x00, 0x00, 0x40])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.manualShutter(.reciprocal1_67).payload,
            Data([0x01, 0x01, 0x80, 0x43, 0x00, 0x00, 0x40])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.manualShutter(.reciprocal2_5).payload,
            Data([0x01, 0x02, 0x80, 0x05, 0x00, 0x00, 0x40])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.manualShutter(.reciprocal6_25).payload,
            Data([0x01, 0x06, 0x80, 0x19, 0x00, 0x00, 0x40])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.manualShutter(.reciprocal12_5).payload,
            Data([0x01, 0x0C, 0x80, 0x05, 0x00, 0x00, 0x40])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.manualShutter(.reciprocal30).payload,
            Data([0x01, 0x1E, 0x80, 0x00, 0x00, 0x00, 0x40])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.manualShutter(.reciprocal60).payload,
            Data([0x01, 0x3C, 0x80, 0x00, 0x00, 0x00, 0x40])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.manualShutter(.reciprocal1000).payload,
            Data([0x01, 0xE8, 0x83, 0x00, 0x00, 0x00, 0x40])
        )
        XCTAssertEqual(
            Pocket3CameraSettings.manualShutter(.reciprocal8000).payload,
            Data([0x01, 0x40, 0x9F, 0x00, 0x00, 0x00, 0x40])
        )

        XCTAssertEqual(Pocket3CameraSettings.ManualShutter.allCases.count, 40)
        XCTAssertEqual(Pocket3CameraSettings.ManualShutter.allCases.first?.displayName, "1\"")
        XCTAssertEqual(Pocket3CameraSettings.ManualShutter.allCases.last?.displayName, "1/8000")
    }

    func testCompleteTimelapseMenus() {
        let intervals: [UInt16] = [5, 10, 20, 30, 40, 50, 60, 80, 100, 150, 200, 250, 300, 400, 600]
        let durations: [UInt32] = [0, 300, 600, 1_200, 1_800, 3_600, 7_200, 10_800, 18_000]

        for interval in intervals {
            let command = Pocket3CameraSettings.timelapse(
                .init(intervalTenths: interval, durationSeconds: 300, output: .video)
            )
            XCTAssertEqual(command.cmd, 0x6C)
            XCTAssertEqual(command.payload[3], UInt8(interval & 0xFF))
            XCTAssertEqual(command.payload[4], UInt8((interval >> 8) & 0xFF))
        }

        for duration in durations {
            let command = Pocket3CameraSettings.timelapse(
                .init(intervalTenths: 50, durationSeconds: duration, output: .video)
            )
            XCTAssertEqual(command.payload[5], UInt8(duration & 0xFF))
            XCTAssertEqual(command.payload[6], UInt8((duration >> 8) & 0xFF))
            XCTAssertEqual(command.payload[7], UInt8((duration >> 16) & 0xFF))
            XCTAssertEqual(command.payload[8], UInt8((duration >> 24) & 0xFF))
        }
    }

}
