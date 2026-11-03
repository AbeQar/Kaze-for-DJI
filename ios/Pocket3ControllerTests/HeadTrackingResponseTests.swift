import Testing
@testable import Pocket3Controller

@MainActor
struct HeadTrackingResponseTests {
    @Test func smallErrorResponseAndDeadbandRemainUnchanged() {
        for error in [0.0, 0.5, 0.8] {
            #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: error) == 0)
            #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: -error) == 0)
        }
        for (error, expected) in [(1.0, 32), (2.0, 40), (3.0, 48)] {
            #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: error) == expected)
            #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: -error) == -expected)
        }
    }

    @Test func largeErrorsCatchUpFasterWithinProvenCommandRange() {
        #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: 10) == 216)
        #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: 20) == 456)
        #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: 24) == 550)
        #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: 45) == 550)
        #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: -45) == -550)
        #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: 3.001) == 48)
    }

    @Test func responseIsMonotonicSymmetricAndSaturatesSafely() {
        var previous = 0
        for tenth in 0...1800 {
            let error = Double(tenth) / 10
            let output = HeadTrackingManager.controlAxisOffset(errorDegrees: error)
            #expect(output >= previous)
            #expect(output <= JoystickMapper.mimoMaxOffset)
            #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: -error) == -output)
            previous = output
        }
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            #expect(HeadTrackingManager.controlAxisOffset(errorDegrees: invalid) == 0)
        }
    }

    @Test func fullAuthorityUsesExistingCapturedJoystickPayload() {
        let offset = HeadTrackingManager.controlAxisOffset(errorDegrees: 45)
        let payload = Pocket3GimbalSession.gimbalPayload(pitch: 1024 + offset, yaw: 1024 - offset)
        #expect(Array(payload) == [0x26, 0x06, 0x00, 0x00, 0xDA, 0x01, 0x00, 0x80, 0x22, 0x00])
    }
}
