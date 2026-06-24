import XCTest
@testable import MonitorFlux

final class OSDControllerTests: XCTestCase {
    func testVolumeOSDUsesNativeSpeakerGlyphLevels() {
        XCTAssertEqual(OSDController.Kind.volume.systemImage(fraction: 0), "speaker.slash.fill")
        XCTAssertEqual(OSDController.Kind.volume.systemImage(fraction: 0.2), "speaker.wave.1.fill")
        XCTAssertEqual(OSDController.Kind.volume.systemImage(fraction: 0.5), "speaker.wave.2.fill")
        XCTAssertEqual(OSDController.Kind.volume.systemImage(fraction: 0.9), "speaker.wave.3.fill")
    }

    func testSegmentFillPartiallyFillsTheBoundarySegment() {
        // 70% across 16 segments → 11 full, the 12th ~20% filled, the rest empty.
        XCTAssertEqual(OSDController.segmentFill(fraction: 0.7, index: 10, segments: 16), 1, accuracy: 0.0001)
        XCTAssertEqual(OSDController.segmentFill(fraction: 0.7, index: 11, segments: 16), 0.2, accuracy: 0.0001)
        XCTAssertEqual(OSDController.segmentFill(fraction: 0.7, index: 12, segments: 16), 0, accuracy: 0.0001)
    }

    func testSubSegmentStepsAlwaysMoveTheBar() {
        // A warmth keypress is 200 K of a 5300 K range ≈ 0.6 of a 16-segment bar — smaller
        // than one segment. With whole-segment (rounded) fills the bar stalled between ticks;
        // the partial fill must make two adjacent steps render differently.
        let step = 200.0 / 5300.0
        for start in stride(from: 0.0, through: 1.0 - step, by: step) {
            let before = (0..<16).map { OSDController.segmentFill(fraction: start, index: $0, segments: 16) }
            let after = (0..<16).map { OSDController.segmentFill(fraction: start + step, index: $0, segments: 16) }
            XCTAssertNotEqual(before, after, "bar did not move for a step starting at \(start)")
        }
    }
}
