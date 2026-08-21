//
//  Pocket3ControllerTests.swift
//  Pocket3ControllerTests
//
//  Created by Brian Merchant on 8/8/26.
//

import Testing
@testable import Pocket3Controller

struct Pocket3ControllerTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

    @Test func disconnectedCameraConnectionPresentationUsesCameraHubCopy() {
        let presentation = CameraConnectionPresentation.make(
            isConnected: false,
            connectedCameraDisplayName: nil
        )

        #expect(presentation.topLabel == "Cameras")
        #expect(presentation.title == "Cameras")
        #expect(presentation.deviceName == nil)
        #expect(presentation.status == "No camera connected")
        #expect(presentation.actionTitle == "Connect Camera")
    }

    @Test func connectedCameraNameIsUsedVerbatim() {
        let presentation = CameraConnectionPresentation.make(
            isConnected: true,
            connectedCameraDisplayName: "Pocket 4P"
        )

        #expect(presentation.topLabel == "Pocket 4P")
        #expect(presentation.deviceName == "Pocket 4P")
        #expect(presentation.status == "Connected")
        #expect(presentation.actionTitle == "Disconnect")
    }

}
