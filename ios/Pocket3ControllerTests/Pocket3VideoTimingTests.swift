import XCTest
@testable import Pocket3Controller

final class Pocket3VideoTimingTests: XCTestCase {
    func testAutomaticPiPRequiresActiveSessionAndRenderedVideo() {
        XCTAssertFalse(Pocket3VideoOutput.shouldAllowAutomaticPiP(
            userEnabled: false,
            sessionActive: true,
            hasRenderedVideo: true,
            sampleAgeMs: 0
        ))
        XCTAssertFalse(Pocket3VideoOutput.shouldAllowAutomaticPiP(
            sessionActive: false,
            hasRenderedVideo: true,
            sampleAgeMs: 0
        ))
        XCTAssertFalse(Pocket3VideoOutput.shouldAllowAutomaticPiP(
            sessionActive: true,
            hasRenderedVideo: false,
            sampleAgeMs: 0
        ))
    }

    func testAutomaticPiPRejectsStaleVideo() {
        XCTAssertTrue(Pocket3VideoOutput.shouldAllowAutomaticPiP(
            sessionActive: true,
            hasRenderedVideo: true,
            sampleAgeMs: Pocket3VideoOutput.automaticPiPMaximumSampleAgeMs
        ))
        XCTAssertFalse(Pocket3VideoOutput.shouldAllowAutomaticPiP(
            sessionActive: true,
            hasRenderedVideo: true,
            sampleAgeMs: Pocket3VideoOutput.automaticPiPMaximumSampleAgeMs + 1
        ))
    }

    func testRegressionCadenceIgnoresOneHundredMillisecondDeliveryBatchesAt24FPS() throws {
        let timestamps = batchedTimestamps(frameRate: 24, seconds: 3)
        let measured = try XCTUnwrap(Pocket3VideoOutput.regressionFrameRate(timestamps))

        XCTAssertEqual(measured, 24, accuracy: 0.1)
    }

    func testRegressionCadenceIgnoresOneHundredMillisecondDeliveryBatchesAt30FPS() throws {
        let timestamps = batchedTimestamps(frameRate: 30, seconds: 3)
        let measured = try XCTUnwrap(Pocket3VideoOutput.regressionFrameRate(timestamps))

        XCTAssertEqual(measured, 30, accuracy: 0.1)
    }

    private func batchedTimestamps(frameRate: Int, seconds: Int) -> [UInt64] {
        let batchNs: UInt64 = 100_000_000
        return (0...(frameRate * seconds)).map { frame in
            let nominalNs = UInt64(frame) * 1_000_000_000 / UInt64(frameRate)
            let batchEndNs = ((nominalNs + batchNs - 1) / batchNs) * batchNs
            // Completed access units in one UDP batch still arrive in order,
            // separated by only a small amount of processing time.
            return batchEndNs + UInt64(frame % 4) * 400_000
        }
    }
}
