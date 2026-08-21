import XCTest
@testable import Pocket3Controller

final class Pocket3CameraDomainTests: XCTestCase {
    func testControlDelegatesToExistingCommandEncoders() {
        var commands: [Pocket3CameraCommand] = []
        var recordingRequests: [Bool] = []
        let control = Pocket3CameraControl(
            sendCommand: { commands.append($0) },
            setRecording: { recordingRequests.append($0) }
        )
        let timelapse = Pocket3CameraSettings.TimelapseConfiguration(
            intervalTenths: 10,
            durationSeconds: 300,
            output: .jpegAndVideo
        )

        control.setShootingMode(.video)
        control.setVideoFormat(resolution: .p4K, frameRate: .fps60)
        control.setVideoCompression(.hevcEfficiency)
        control.setProEnabled(true)
        control.setExposureMode(.manual)
        control.setManualISO(.iso400)
        control.setISOMax(.iso1600)
        control.setManualShutter(.reciprocal60)
        XCTAssertTrue(control.setAutoEV(thirdStops: 3))
        XCTAssertTrue(control.setWhiteBalance(.customKelvin(5600)))
        control.setColorProfile(.dLogM)
        control.setFocusMode(.continuous)
        control.setProductShowcaseEnabled(true)
        control.shootPhoto()
        control.setPhotoFrame(.oneByOne)
        control.setPhotoFormat(.jpegAndRaw)
        control.setPhotoCountdown(.seconds5)
        control.setTimelapse(timelapse)
        control.previewMotionlapse()
        control.setMotionlapseWaypoint(
            slot: .point1,
            intervalTenths: 10,
            durationSeconds: 300,
            pitchTenths: 123,
            rollTenths: -45,
            yawTenths: 678
        )
        control.deleteMotionlapseWaypoint(slot: .point1, intervalTenths: 10, durationSeconds: 300)
        control.setHyperlapseSpeed(.x15)
        control.setPanoramaType(.grid3x3)
        control.setPanoramaPhotoFormat(.raw)
        control.shootPanorama()
        control.setAudioChannel(.stereo)
        control.setRecording(true)
        control.setRecording(false)

        XCTAssertEqual(
            commands,
            [
                Pocket3CameraSettings.shootingMode(.video),
                Pocket3CameraSettings.videoFormat(resolution: .p4K, frameRate: .fps60),
                Pocket3CameraSettings.videoCompression(.hevcEfficiency),
                Pocket3CameraSettings.proEnabled(true),
                Pocket3CameraSettings.exposureMode(.manual),
                Pocket3CameraSettings.manualISO(.iso400),
                Pocket3CameraSettings.isoMax(.iso1600),
                Pocket3CameraSettings.manualShutter(.reciprocal60),
                Pocket3CameraSettings.autoEV(thirdStops: 3)!,
                Pocket3CameraSettings.whiteBalance(.customKelvin(5600))!,
                Pocket3CameraSettings.colorProfile(.dLogM),
                Pocket3CameraSettings.focusMode(.continuous),
                Pocket3CameraSettings.productShowcaseEnabled(true),
                Pocket3CameraSettings.shootPhoto(),
                Pocket3CameraSettings.photoFrame(.oneByOne),
                Pocket3CameraSettings.photoFormat(.jpegAndRaw),
                Pocket3CameraSettings.photoCountdown(.seconds5),
                Pocket3CameraSettings.timelapse(timelapse),
                Pocket3CameraSettings.motionlapsePreview(),
                Pocket3CameraSettings.motionlapseWaypoint(
                    slot: .point1,
                    intervalTenths: 10,
                    durationSeconds: 300,
                    pitchTenths: 123,
                    rollTenths: -45,
                    yawTenths: 678
                ),
                Pocket3CameraSettings.deleteMotionlapseWaypoint(
                    slot: .point1,
                    intervalTenths: 10,
                    durationSeconds: 300
                ),
                Pocket3CameraSettings.hyperlapseSpeed(.x15),
                Pocket3CameraSettings.panoramaType(.grid3x3),
                Pocket3CameraSettings.panoramaPhotoFormat(.raw),
                Pocket3CameraSettings.shootPanorama(),
                Pocket3CameraSettings.audioChannel(.stereo),
            ]
        )
        XCTAssertEqual(recordingRequests, [true, false])
    }

    func testControlRejectsInvalidValueWithoutEnqueueing() {
        var commands: [Pocket3CameraCommand] = []
        let control = Pocket3CameraControl(
            sendCommand: { commands.append($0) },
            setRecording: { _ in }
        )

        XCTAssertFalse(control.setAutoEV(thirdStops: 10))
        XCTAssertFalse(control.setWhiteBalance(.customKelvin(5650)))
        XCTAssertTrue(commands.isEmpty)
    }

    func testMotionlapseDirectionPreservesModeTransitionOrdering() {
        var commands: [Pocket3CameraCommand] = []
        let control = Pocket3CameraControl(
            sendCommand: { commands.append($0) },
            setRecording: { _ in }
        )

        control.setMotionlapseDirection(.custom, currentMode: .timelapse)
        XCTAssertEqual(
            commands,
            [
                Pocket3CameraSettings.motionlapseMode(),
                Pocket3CameraSettings.motionlapseDirection(.custom),
            ]
        )

        commands.removeAll()
        control.setMotionlapseDirection(.rightToLeft, currentMode: .motionlapse)
        XCTAssertEqual(commands, [Pocket3CameraSettings.motionlapseDirection(.rightToLeft)])
    }

    func testCameraStateAggregatesStatusAndReadback() throws {
        var payload = Data(repeating: 0, count: 60)
        payload[4] = 0x01
        payload[5] = 0x00
        payload[6] = 0x00
        payload[7] = 0x02
        payload[9] = 0x00
        payload[10] = 0x00
        payload[11] = 0x01
        payload[17] = 0x1A
        payload[18] = 0x04
        payload[29] = 0x2A
        payload[57] = Pocket3CameraShootingMode.video.rawValue

        var state = Pocket3CameraState()
        state.apply(try XCTUnwrap(Pocket3CameraStatus.statusFields(payload: payload)))
        state.recording = false

        XCTAssertEqual(state.shootingMode, .video)
        XCTAssertEqual(state.storageTotalMiB, 131_072)
        XCTAssertEqual(state.storageFreeMiB, 65_536)
        XCTAssertEqual(state.remainingRecordSeconds, 1_050)
        XCTAssertEqual(state.elapsedRecordSeconds, 42)
        XCTAssertTrue(state.canToggleRecording)

        XCTAssertTrue(
            state.apply(
                Pocket3CameraPropertyRecord(
                    transactionID: 1,
                    name: "cam_video_param_v2",
                    value: Data([0x10, 0x06, 0, 0, 0, 0, 0, 0, 0x01])
                )
            )
        )
        XCTAssertEqual(state.readback.videoResolution, .p4K)
        XCTAssertEqual(state.readback.videoFrameRate, .fps60)
        XCTAssertEqual(state.readback.videoCompression, .hevcEfficiency)

        state.recordCommandInFlight = true
        XCTAssertFalse(state.canToggleRecording)
    }

    func testRecordingAndMenuPolicyPreserveConfirmedBehavior() {
        XCTAssertEqual(Pocket3CameraStatus.recordingCommand(true).payload, Data([0x01]))
        XCTAssertEqual(Pocket3CameraStatus.recordingCommand(false).payload, Data([0x00]))
        XCTAssertTrue(Pocket3CameraStatus.recordingActive(statusByte: 0x81))
        XCTAssertTrue(Pocket3CameraStatus.recordingTransitioning(statusByte: 0x41))

        let photoShutters = Pocket3CameraPolicy.manualShutters(
            shootingMode: .photo,
            videoFrameRate: nil
        )
        XCTAssertEqual(photoShutters, Pocket3CameraSettings.ManualShutter.allCases)

        let video60Shutters = Pocket3CameraPolicy.manualShutters(
            shootingMode: .video,
            videoFrameRate: .fps60
        )
        XCTAssertTrue(video60Shutters?.contains(.reciprocal60) == true)
        XCTAssertFalse(video60Shutters?.contains(.reciprocal50) == true)
        XCTAssertNil(
            Pocket3CameraPolicy.manualShutters(
                shootingMode: .slowMotion,
                videoFrameRate: .fps120
            )
        )

        XCTAssertTrue(
            Pocket3CameraPolicy.videoFormatSupported(
                resolution: .portrait3K,
                sensorAspectRatio: .portrait
            )
        )
        XCTAssertFalse(
            Pocket3CameraPolicy.videoFormatSupported(
                resolution: .p4K,
                sensorAspectRatio: .portrait
            )
        )
    }
}
