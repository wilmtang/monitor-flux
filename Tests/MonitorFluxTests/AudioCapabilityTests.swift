import XCTest
@testable import MonitorFlux

/// The volume slider is shown only for displays that actually output sound. These pin down
/// the name-matching that maps a CoreAudio display-audio device to a display.
final class AudioCapabilityTests: XCTestCase {
    private let service = AudioCapabilityService()

    func testNoDisplayAudioDevicesMeansNoAudio() {
        // Only built-in speakers present -> an external monitor reports no audio.
        XCTAssertFalse(service.displayHasAudio(named: "AW3225QF", deviceNames: []))
        XCTAssertFalse(service.displayHasAudio(named: "AW3225QF", deviceNames: ["MacBook Pro Speakers"]))
    }

    func testExactNameMatchIsAudio() {
        XCTAssertTrue(service.displayHasAudio(named: "DELL U2720Q", deviceNames: ["DELL U2720Q"]))
    }

    func testMatchIgnoresPunctuationSpacingAndCase() {
        XCTAssertTrue(service.displayHasAudio(named: "LG HDR 4K", deviceNames: ["lg-hdr_4k"]))
    }

    func testMatchAllowsAudioDeviceNameSuffix() {
        // macOS sometimes appends a qualifier to the audio device name.
        XCTAssertTrue(service.displayHasAudio(named: "DELL U2720Q", deviceNames: ["DELL U2720Q (1)"]))
    }

    func testSimilarSiblingNameIsNotAFalsePositive() {
        // A speakerless "DELL U2720" must NOT be flagged just because a sibling model's
        // audio device "DELL U2720Q" contains its name as a substring.
        XCTAssertFalse(service.displayHasAudio(named: "DELL U2720", deviceNames: ["DELL U2720Q"]))
        // And the reverse: a short/generic display name isn't matched by a longer device.
        XCTAssertFalse(service.displayHasAudio(named: "LG", deviceNames: ["LG TV"]))
    }

    func testUnrelatedDeviceIsNotAudio() {
        XCTAssertFalse(
            service.displayHasAudio(named: "AW3225QF", deviceNames: ["DELL U2720Q", "Studio Display"])
        )
    }

    func testSpeakerMonitorAmongOthersMatchesOnlyItsOwn() {
        let devices = ["DELL U2720Q"]
        XCTAssertTrue(service.displayHasAudio(named: "DELL U2720Q", deviceNames: devices))
        XCTAssertFalse(service.displayHasAudio(named: "AW3225QF", deviceNames: devices))
    }

    func testEmptyDisplayNameIsNotAudio() {
        XCTAssertFalse(service.displayHasAudio(named: "", deviceNames: ["DELL U2720Q"]))
    }
}
