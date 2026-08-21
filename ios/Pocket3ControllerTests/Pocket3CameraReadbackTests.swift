import XCTest
@testable import Pocket3Controller

final class Pocket3CameraReadbackTests: XCTestCase {
    func testCapturedSubscriptionEncoding() throws {
        let command = try XCTUnwrap(
            Pocket3CameraPropertyBus.subscriptionCommand(
                name: "cam_video_param_v2",
                transactionID: 0x0000_C938
            )
        )

        XCTAssertEqual(command.set, 0x00)
        XCTAssertEqual(command.cmd, 0x99)
        XCTAssertEqual(command.receiverType, 0x08)
        XCTAssertEqual(command.receiverId, 1)
        XCTAssertEqual(command.cmdType, 2)
        XCTAssertEqual(
            command.payload,
            Data(hexForTest: "0202000038c900000000001800120063616d5f766964656f5f706172616d5f763200000000")
        )
    }

    func testColdConnectVideoReadback() throws {
        let record = try XCTUnwrap(
            Pocket3CameraPropertyBus.parsePush(
                Data(hexForTest: "020600008d2a00000000002600120063616d5f766964656f5f706172616d5f76320000000000000a0010060000000201000101")
            )
        )

        XCTAssertEqual(record.name, "cam_video_param_v2")
        XCTAssertEqual(record.value, Data(hexForTest: "10060000000201000101"))

        var state = Pocket3CameraReadbackState()
        XCTAssertTrue(state.apply(record))
        XCTAssertEqual(state.videoResolution, .p4K)
        XCTAssertEqual(state.videoFrameRate, .fps60)
        XCTAssertEqual(state.videoCompression, .hevcEfficiency)
    }

    func testCapturedPortraitVideoReadback() {
        var state = Pocket3CameraReadbackState()

        XCTAssertTrue(
            state.apply(
                Pocket3CameraPropertyRecord(
                    transactionID: 0x01,
                    name: "cam_video_param_v2",
                    value: Data(hexForTest: "6c030000000201000101")
                )
            )
        )
        XCTAssertEqual(state.videoResolution, .portrait3K)
        XCTAssertEqual(state.videoFrameRate, .fps30)

        XCTAssertTrue(
            state.apply(
                Pocket3CameraPropertyRecord(
                    transactionID: 0x02,
                    name: "cam_video_param_v2",
                    value: Data(hexForTest: "42060000000201000101")
                )
            )
        )
        XCTAssertEqual(state.videoResolution, .portrait1080)
        XCTAssertEqual(state.videoFrameRate, .fps60)
    }

    func testCapturedSensorAspectRatioReadback() {
        var state = Pocket3CameraReadbackState()

        XCTAssertTrue(
            state.apply(
                Pocket3CameraPropertyRecord(
                    transactionID: 0x01,
                    name: "cam_sensor_aspect_ratio",
                    value: Data([0x00])
                )
            )
        )
        XCTAssertEqual(state.sensorAspectRatio, .landscape)

        XCTAssertTrue(
            state.apply(
                Pocket3CameraPropertyRecord(
                    transactionID: 0x02,
                    name: "cam_sensor_aspect_ratio",
                    value: Data([0x01])
                )
            )
        )
        XCTAssertEqual(state.sensorAspectRatio, .portrait)
        XCTAssertTrue(Pocket3CameraPropertyBus.corePropertyNames.contains("cam_sensor_aspect_ratio"))
    }

    func testColdConnectImageEffectReadback() throws {
        let record = try XCTUnwrap(
            Pocket3CameraPropertyBus.parsePush(
                Data(hexForTest: "020600008e2a00000000002a00100063616d5f696d6167655f656666656374000000000000100000003d0006380005000638000000fefe")
            )
        )

        var state = Pocket3CameraReadbackState()
        XCTAssertTrue(state.apply(record))
        XCTAssertEqual(state.colorProfile, .dLogM)
        XCTAssertEqual(state.whiteBalance, .customKelvin(5600))
    }

    func testColdConnectExposureReadback() throws {
        let record = try XCTUnwrap(
            Pocket3CameraPropertyBus.parsePush(
                Data(hexForTest: "02060000882a000000000044000e0063616d5f6578706f5f706172616d0000000000002c0000003c80000013010000000702c80010400600003c8000000000000064000000016501086400000001010000")
            )
        )

        var state = Pocket3CameraReadbackState()
        XCTAssertTrue(state.apply(record))
        XCTAssertEqual(state.exposureMode, .auto)
        XCTAssertEqual(state.evThirdStops, 3)
        XCTAssertEqual(state.effectiveISO, 1600)
    }

    func testColdConnectFocusReadback() throws {
        let record = try XCTUnwrap(
            Pocket3CameraPropertyBus.parsePush(
                Data(hexForTest: "02060000902a000000000047000e0063616d5f6c656e735f73746174650000000000002f00b200ffff3e00ffff3e00d900b201d9000000061207121c026e067f0401000000000000000000006701000067010000")
            )
        )

        var state = Pocket3CameraReadbackState()
        XCTAssertTrue(state.apply(record))
        XCTAssertEqual(state.focusMode, .continuous)
    }

    func testCapturedPhotoFrameFormatAndCountdownReadback() throws {
        var state = Pocket3CameraReadbackState()

        let oneByOneRaw = try XCTUnwrap(
            Pocket3CameraPropertyBus.parsePush(
                Data(hexForTest: "02060000d61c000000000026000f0063616d5f70686f746f5f706172616d0000000000000d0000030202000001000000000001")
            )
        )
        XCTAssertTrue(state.apply(oneByOneRaw))
        XCTAssertEqual(state.photoFrame, .oneByOne)
        XCTAssertEqual(state.photoFormat, .jpegAndRaw)
        XCTAssertEqual(state.photoCountdown, .off)

        let sixteenByNineJpeg = try XCTUnwrap(
            Pocket3CameraPropertyBus.parsePush(
                Data(hexForTest: "02060000dd29000000000026000f0063616d5f70686f746f5f706172616d0000000000000d0000010201000001000000000001")
            )
        )
        XCTAssertTrue(state.apply(sixteenByNineJpeg))
        XCTAssertEqual(state.photoFrame, .sixteenByNine)
        XCTAssertEqual(state.photoFormat, .jpeg)
        XCTAssertEqual(state.photoCountdown, .off)

        let countdown7 = try XCTUnwrap(
            Pocket3CameraPropertyBus.parsePush(
                Data(hexForTest: "02060000e93b000000000026000f0063616d5f70686f746f5f706172616d0000000000000d0000010201000001070000000001")
            )
        )
        XCTAssertTrue(state.apply(countdown7))
        XCTAssertEqual(state.photoCountdown, .seconds7)
        XCTAssertTrue(Pocket3CameraPropertyBus.corePropertyNames.contains("cam_photo_param"))
    }

    func testCapturedTimelapseReadback() throws {
        let captured = try XCTUnwrap(
            Pocket3CameraPropertyBus.parsePush(
                Data(hexForTest: "020600006e6d00000000002e000f0063616d5f6c617073655f706172616d0000000000001500000500050000000000000000000000000000000000")
            )
        )

        XCTAssertEqual(captured.name, "cam_lapse_param")
        XCTAssertEqual(captured.value, Data(hexForTest: "000500050000000000000000000000000000000000"))

        var state = Pocket3CameraReadbackState()
        XCTAssertTrue(state.apply(captured))
        XCTAssertEqual(state.timelapseOutput, .video)
        XCTAssertEqual(state.timelapseIntervalTenths, 5)
        XCTAssertEqual(state.timelapseDurationSeconds, 0)
        XCTAssertTrue(Pocket3CameraPropertyBus.corePropertyNames.contains("cam_lapse_param"))
    }

    func testCapturedTimelapseIntervalAnchors() {
        let anchors: [(String, UInt16)] = [
            ("000500050000000000000000000000000000000000", 5),
            ("000a00050000000000000000000000000000000000", 10),
            ("006400050000000000000000000000000000000000", 100),
            ("005802050000000000000000000000000000000000", 600),
        ]

        for (hex, expected) in anchors {
            var state = Pocket3CameraReadbackState()
            XCTAssertTrue(
                state.apply(
                    Pocket3CameraPropertyRecord(
                        transactionID: 0,
                        name: "cam_lapse_param",
                        value: Data(hexForTest: hex)
                    )
                )
            )
            XCTAssertEqual(state.timelapseIntervalTenths, expected)
        }
    }

    func testCapturedTimelapseDurationAnchors() {
        let anchors: [(String, UInt32)] = [
            ("000a0005002c010000000000000000000000000000", 300),
            ("000a00050058020000000000000000000000000000", 600),
            ("000a000500100e0000000000000000000000000000", 3_600),
            ("000a00050050460000000000000000000000000000", 18_000),
            ("000a00050000000000000000000000000000000000", 0),
        ]

        for (hex, expected) in anchors {
            var state = Pocket3CameraReadbackState()
            XCTAssertTrue(
                state.apply(
                    Pocket3CameraPropertyRecord(
                        transactionID: 0,
                        name: "cam_lapse_param",
                        value: Data(hexForTest: hex)
                    )
                )
            )
            XCTAssertEqual(state.timelapseDurationSeconds, expected)
        }
    }

    func testCapturedTimelapseOutputAnchors() {
        let anchors: [(String, Pocket3CameraSettings.TimelapseOutput)] = [
            ("001400050000000000000000000000000000000000", .video),
            ("021400050000000000000000000000000000000000", .jpegAndVideo),
            ("031400140000000000000000000000000000000000", .rawAndVideo),
        ]

        for (hex, expected) in anchors {
            var state = Pocket3CameraReadbackState()
            XCTAssertTrue(
                state.apply(
                    Pocket3CameraPropertyRecord(
                        transactionID: 0,
                        name: "cam_lapse_param",
                        value: Data(hexForTest: hex)
                    )
                )
            )
            XCTAssertEqual(state.timelapseOutput, expected)
        }
    }


    func testCapturedHyperlapseSpeedReadback() {
        let anchors: [(String, Pocket3CameraSettings.HyperlapseSpeed)] = [
            ("00140005002c010000000000000000000000000000", .auto),
            ("00140005002c010000020002000000000000000000", .x2),
            ("00140005002c010000050005000000000000000000", .x5),
            ("00140005002c0100000a000a000000000000000000", .x10),
            ("00140005002c0100000f000f000000000000000000", .x15),
            ("00140005002c0100001e001e000000000000000000", .x30),
        ]

        for (hex, expected) in anchors {
            var state = Pocket3CameraReadbackState()
            XCTAssertTrue(
                state.apply(
                    Pocket3CameraPropertyRecord(
                        transactionID: 0,
                        name: "cam_lapse_param",
                        value: Data(hexForTest: hex)
                    )
                )
            )
            XCTAssertEqual(state.hyperlapseSpeed, expected)
        }
    }

    func testHyperlapseSpeedReadbackRejectsMismatchedMirrors() {
        var state = Pocket3CameraReadbackState()
        XCTAssertTrue(
            state.apply(
                Pocket3CameraPropertyRecord(
                    transactionID: 0,
                    name: "cam_lapse_param",
                    value: Data(hexForTest: "00140005002c010000020005000000000000000000")
                )
            )
        )
        XCTAssertNil(state.hyperlapseSpeed)
    }

    func testCapturedPanoramaReadback() {
        var state = Pocket3CameraReadbackState()

        XCTAssertTrue(
            state.apply(
                Pocket3CameraPropertyRecord(
                    transactionID: 1,
                    name: "cam_pano_params",
                    value: Data(hexForTest: "050300")
                )
            )
        )
        XCTAssertEqual(state.panoramaType, .degrees180)
        XCTAssertEqual(state.panoramaPhotoFormat, .jpeg)

        XCTAssertTrue(
            state.apply(
                Pocket3CameraPropertyRecord(
                    transactionID: 2,
                    name: "cam_pano_params",
                    value: Data(hexForTest: "070100")
                )
            )
        )
        XCTAssertEqual(state.panoramaType, .grid3x3)
        XCTAssertEqual(state.panoramaPhotoFormat, .raw)
        XCTAssertTrue(Pocket3CameraPropertyBus.corePropertyNames.contains("cam_pano_params"))
    }

    func testCapturedHyperlapseAndPanoramaWriterPayloads() {
        let speeds: [(Pocket3CameraSettings.HyperlapseSpeed, String)] = [
            (.auto, "0b000000000000000000000000000000"),
            (.x2, "0b000002000000000000000000000000"),
            (.x5, "0b000005000000000000000000000000"),
            (.x10, "0b00000a000000000000000000000000"),
            (.x15, "0b00000f000000000000000000000000"),
            (.x30, "0b00001e000000000000000000000000"),
        ]
        for (speed, expectedHex) in speeds {
            let command = Pocket3CameraSettings.hyperlapseSpeed(speed)
            XCTAssertEqual(command.set, 0x02)
            XCTAssertEqual(command.cmd, 0x6C)
            XCTAssertEqual(command.payload.hexString, expectedHex)
        }

        let pano180 = Pocket3CameraSettings.panoramaType(.degrees180)
        XCTAssertEqual(pano180.set, 0x02)
        XCTAssertEqual(pano180.cmd, 0x6E)
        XCTAssertEqual(pano180.payload, Data([0x05]))

        let pano3x3 = Pocket3CameraSettings.panoramaType(.grid3x3)
        XCTAssertEqual(pano3x3.payload, Data([0x07]))

        let jpeg = Pocket3CameraSettings.panoramaPhotoFormat(.jpeg)
        XCTAssertEqual(jpeg.set, 0x02)
        XCTAssertEqual(jpeg.cmd, 0xE7)
        XCTAssertEqual(jpeg.payload, Data([0x03, 0x00]))

        let raw = Pocket3CameraSettings.panoramaPhotoFormat(.raw)
        XCTAssertEqual(raw.payload, Data([0x01, 0x00]))

        // C2-PAN-090: both 180° and 3×3 shutter presses emitted the same command.
        let start = Pocket3CameraSettings.shootPanorama()
        XCTAssertEqual(start.set, 0x02)
        XCTAssertEqual(start.cmd, 0x01)
        XCTAssertEqual(start.payload, Data([0x07]))
    }

    func testCapturedMotionlapseDirectionAndWaypointReadback() {
        let leftToRight = Data(hexForTest: "010401001c00000290012c01000000000000000090012c010000000000000000")
        let rightToLeft = Data(hexForTest: "010402001c00000290012c01000000000000000090012c010000000000000000")
        let customEmpty = Data(hexForTest: "0104000004000000")
        let customFour = Data(hexForTest: "010400003400000414002c01000036fe0000e80514002c0100009cfe0000220414002c010000c0ff0000810414002c010000d80000009205")

        var state = Pocket3CameraReadbackState()
        XCTAssertTrue(state.apply(Pocket3CameraPropertyRecord(transactionID: 1, name: "cam_motionlapse_params", value: leftToRight)))
        XCTAssertEqual(state.motionlapseDirection, .leftToRight)
        XCTAssertNil(state.motionlapseWaypointCount)

        XCTAssertTrue(state.apply(Pocket3CameraPropertyRecord(transactionID: 2, name: "cam_motionlapse_params", value: rightToLeft)))
        XCTAssertEqual(state.motionlapseDirection, .rightToLeft)
        XCTAssertNil(state.motionlapseWaypointCount)

        XCTAssertTrue(state.apply(Pocket3CameraPropertyRecord(transactionID: 3, name: "cam_motionlapse_params", value: customEmpty)))
        XCTAssertEqual(state.motionlapseDirection, .custom)
        XCTAssertEqual(state.motionlapseWaypointCount, 0)

        XCTAssertTrue(state.apply(Pocket3CameraPropertyRecord(transactionID: 4, name: "cam_motionlapse_params", value: customFour)))
        XCTAssertEqual(state.motionlapseDirection, .custom)
        XCTAssertEqual(state.motionlapseWaypointCount, 4)
        XCTAssertTrue(Pocket3CameraPropertyBus.corePropertyNames.contains("cam_motionlapse_params"))
    }

    func testCapturedMotionlapseWriterPayloads() {
        let enter = Pocket3CameraSettings.motionlapseMode()
        XCTAssertEqual(enter.set, 0x02)
        XCTAssertEqual(enter.cmd, 0xE1)
        XCTAssertEqual(enter.payload, Data([0x18]))

        let returnToTimelapse = Pocket3CameraSettings.shootingMode(.timelapse)
        XCTAssertEqual(returnToTimelapse.payload, Data([0x02]))

        let leftToRight = Pocket3CameraSettings.motionlapseDirection(.leftToRight)
        XCTAssertEqual(leftToRight.set, 0x02)
        XCTAssertEqual(leftToRight.cmd, 0x8E)
        XCTAssertEqual(leftToRight.payload, Data(hexForTest: "010137000101"))

        XCTAssertEqual(
            Pocket3CameraSettings.motionlapseDirection(.rightToLeft).payload,
            Data(hexForTest: "010137000102")
        )
        XCTAssertEqual(
            Pocket3CameraSettings.motionlapseDirection(.custom).payload,
            Data(hexForTest: "010137000100")
        )
    }

    func testCapturedMotionlapseWaypointDeletePayloads() {
        let expected: [(Int, String)] = [
            (4, "0512000a002c01000000000000000000"),
            (3, "050e000a002c01000000000000000000"),
            (2, "050a000a002c01000000000000000000"),
            (1, "0506000a002c01000000000000000000"),
        ]

        for (point, payloadHex) in expected {
            let slot = Pocket3CameraSettings.MotionlapseWaypointSlot(pointNumber: point)!
            let command = Pocket3CameraSettings.deleteMotionlapseWaypoint(
                slot: slot,
                intervalTenths: 10,
                durationSeconds: 300
            )
            XCTAssertEqual(command.set, 0x02)
            XCTAssertEqual(command.cmd, 0x6C)
            XCTAssertEqual(command.payload, Data(hexForTest: payloadHex))
        }
    }


    func testCapturedMotionlapsePreviewCommandAndReadback() {
        let preview = Pocket3CameraSettings.motionlapsePreview()
        XCTAssertEqual(preview.set, 0x02)
        XCTAssertEqual(preview.cmd, 0x8E)
        XCTAssertEqual(preview.payload, Data(hexForTest: "01013600020000"))

        let idle = Data(hexForTest: "01040000340000040a002c010000ffff00000df90a002c010000be0100000df90a002c010000d9ff0000e3fa0a002c01000011020000e3fa")
        let active = Data(hexForTest: "01040080340000040a002c010000ffff00000df90a002c010000be0100000df90a002c010000d9ff0000e3fa0a002c01000011020000e3fa")

        var state = Pocket3CameraReadbackState()
        XCTAssertTrue(state.apply(Pocket3CameraPropertyRecord(transactionID: 1, name: "cam_motionlapse_params", value: idle)))
        XCTAssertEqual(state.motionlapseWaypointCount, 4)
        XCTAssertEqual(state.motionlapsePreviewActive, false)

        XCTAssertTrue(state.apply(Pocket3CameraPropertyRecord(transactionID: 2, name: "cam_motionlapse_params", value: active)))
        XCTAssertEqual(state.motionlapseWaypointCount, 4)
        XCTAssertEqual(state.motionlapsePreviewActive, true)

        XCTAssertTrue(state.apply(Pocket3CameraPropertyRecord(transactionID: 3, name: "cam_motionlapse_params", value: idle)))
        XCTAssertEqual(state.motionlapsePreviewActive, false)
    }

    func testCapturedShootingModeStatusCodes() {
        XCTAssertEqual(Pocket3CameraShootingMode(rawValue: 0x00), .slowMotion)
        XCTAssertEqual(Pocket3CameraShootingMode(rawValue: 0x01), .video)
        XCTAssertEqual(Pocket3CameraShootingMode(rawValue: 0x02), .timelapse)
        XCTAssertEqual(Pocket3CameraShootingMode(rawValue: 0x05), .photo)
        XCTAssertEqual(Pocket3CameraShootingMode(rawValue: 0x0A), .hyperlapse)
        XCTAssertEqual(Pocket3CameraShootingMode(rawValue: 0x0C), .panorama)
        XCTAssertEqual(Pocket3CameraShootingMode(rawValue: 0x18), .motionlapse)
        XCTAssertEqual(Pocket3CameraShootingMode(rawValue: 0x28), .lowLight)
        XCTAssertNil(Pocket3CameraShootingMode(rawValue: 0xFF))
    }

    func testShootingModeDisplayLabels() {
        XCTAssertEqual(Pocket3CameraShootingMode.video.displayName, "Video")
        XCTAssertEqual(Pocket3CameraShootingMode.slowMotion.shortLabel, "SLO-MO")
        XCTAssertEqual(Pocket3CameraShootingMode.timelapse.shortLabel, "T-LAPSE")
        XCTAssertEqual(Pocket3CameraShootingMode.motionlapse.displayName, "Motionlapse")
        XCTAssertEqual(Pocket3CameraShootingMode.motionlapse.shortLabel, "M-LAPSE")
        XCTAssertEqual(Pocket3CameraShootingMode.lowLight.shortLabel, "LOW-LIGHT")
    }

    func testMalformedPropertyPushIsRejected() {
        XCTAssertNil(Pocket3CameraPropertyBus.parsePush(Data([0x02, 0x06, 0x00])))
    }

    func testCapturedMotionlapseWaypointWriter() {
        let point1 = Pocket3CameraSettings.motionlapseWaypoint(
            slot: .point1,
            intervalTenths: 20,
            durationSeconds: 300,
            // Nearest live 04/05 at the Mimo Point 1 write decoded as
            // pitch=151.2°, roll=0°, yaw=-45.8°. The 02/6C waypoint
            // record stores those outer axes in yaw/roll/pitch order.
            pitchTenths: 1512,
            rollTenths: 0,
            yawTenths: -458
        )
        XCTAssertEqual(point1.set, 0x02)
        XCTAssertEqual(point1.cmd, 0x6C)
        XCTAssertEqual(point1.payload.hexString, "05050014002c01000036fe0000e80500")

        let point4 = Pocket3CameraSettings.motionlapseWaypoint(
            slot: .point4,
            intervalTenths: 20,
            durationSeconds: 300,
            // Point 4 nearest 04/05: pitch=142.6°, roll=0°, yaw=21.6°.
            pitchTenths: 1426,
            rollTenths: 0,
            yawTenths: 216
        )
        XCTAssertEqual(point4.payload.hexString, "05110014002c010000d8000000920500")

        XCTAssertEqual(Pocket3CameraSettings.MotionlapseWaypointSlot(pointNumber: 1), .point1)
        XCTAssertEqual(Pocket3CameraSettings.MotionlapseWaypointSlot(pointNumber: 4), .point4)
        XCTAssertNil(Pocket3CameraSettings.MotionlapseWaypointSlot(pointNumber: 5))
    }

}

private extension Data {
    init(hexForTest hex: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
