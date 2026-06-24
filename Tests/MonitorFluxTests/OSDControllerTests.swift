import XCTest
@testable import MonitorFlux

final class OSDControllerTests: XCTestCase {
    func testVolumeOSDUsesNativeSpeakerGlyphLevels() {
        XCTAssertEqual(OSDController.Kind.volume.systemImage(fraction: 0), "speaker.slash.fill")
        XCTAssertEqual(OSDController.Kind.volume.systemImage(fraction: 0.2), "speaker.wave.1.fill")
        XCTAssertEqual(OSDController.Kind.volume.systemImage(fraction: 0.5), "speaker.wave.2.fill")
        XCTAssertEqual(OSDController.Kind.volume.systemImage(fraction: 0.9), "speaker.wave.3.fill")
    }
}
