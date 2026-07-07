import CoreGraphics
import XCTest
@testable import MonitorFlux

final class DisplayControlSyncTests: XCTestCase {
    private func brightness(
        id: CGDirectDisplayID,
        adjustable: Bool = true
    ) -> DisplayControlSync.BrightnessContext {
        DisplayControlSync.BrightnessContext(
            id: id,
            canAdjustBrightness: adjustable
        )
    }

    private func contrast(
        id: CGDirectDisplayID,
        adjustable: Bool = true
    ) -> DisplayControlSync.ContrastContext {
        DisplayControlSync.ContrastContext(
            id: id,
            canAdjustContrast: adjustable
        )
    }

    func testBrightnessSyncDisabledEmitsNoPeerAdjustments() {
        let adjustments = DisplayControlSync.brightnessAdjustments(
            sourceID: 1,
            targetBrightness: 0.64,
            enabled: false,
            displays: [
                brightness(id: 1),
                brightness(id: 2),
            ]
        )

        XCTAssertTrue(adjustments.isEmpty)
    }

    func testBrightnessSyncSkipsSourceAndUnavailableDisplays() {
        let adjustments = DisplayControlSync.brightnessAdjustments(
            sourceID: 1,
            targetBrightness: 1.2,
            enabled: true,
            displays: [
                brightness(id: 1),
                brightness(id: 2),
                brightness(id: 3, adjustable: false),
            ]
        )

        XCTAssertEqual(
            adjustments,
            [DisplayControlSync.BrightnessAdjustment(displayID: 2, targetBrightness: 1.0)]
        )
    }

    func testContrastSyncDisabledEmitsNoPeerAdjustments() {
        let adjustments = DisplayControlSync.contrastAdjustments(
            sourceID: 1,
            targetContrast: 62,
            enabled: false,
            displays: [
                contrast(id: 1),
                contrast(id: 2),
            ]
        )

        XCTAssertTrue(adjustments.isEmpty)
    }

    func testContrastSyncSkipsSourceAndUnavailableDisplays() {
        let adjustments = DisplayControlSync.contrastAdjustments(
            sourceID: 1,
            targetContrast: -10,
            enabled: true,
            displays: [
                contrast(id: 1),
                contrast(id: 2),
                contrast(id: 3, adjustable: false),
            ]
        )

        XCTAssertEqual(
            adjustments,
            [DisplayControlSync.ContrastAdjustment(displayID: 2, targetContrast: 0)]
        )
    }

    func testBrightnessRestorePutsBackManualAndScheduledFields() {
        var original = DisplayPreferences()
        original.hardwareBrightness = 22
        original.gammaBrightness = 88
        original.scheduleBrightness = true
        original.dayBrightness = 91
        original.sunsetBrightness = 62
        original.nightBrightness = 33

        let restore = DisplayBrightnessSyncRestore(original)
        var synced = DisplayPreferences()
        synced.hardwareBrightness = 70
        synced.gammaBrightness = 100
        synced.scheduleBrightness = false
        restore.apply(to: &synced)

        XCTAssertEqual(synced.hardwareBrightness, 22)
        XCTAssertEqual(synced.gammaBrightness, 88)
        XCTAssertTrue(synced.scheduleBrightness)
        XCTAssertEqual(synced.dayBrightness, 91)
        XCTAssertEqual(synced.sunsetBrightness, 62)
        XCTAssertEqual(synced.nightBrightness, 33)
    }

    func testContrastRestorePutsBackManualAndScheduledFields() {
        var original = DisplayPreferences()
        original.hardwareContrast = 44
        original.scheduleContrast = true
        original.dayContrast = 77
        original.sunsetContrast = 66
        original.nightContrast = 55

        let restore = DisplayContrastSyncRestore(original)
        var synced = DisplayPreferences()
        synced.hardwareContrast = 80
        synced.scheduleContrast = false
        restore.apply(to: &synced)

        XCTAssertEqual(synced.hardwareContrast, 44)
        XCTAssertTrue(synced.scheduleContrast)
        XCTAssertEqual(synced.dayContrast, 77)
        XCTAssertEqual(synced.sunsetContrast, 66)
        XCTAssertEqual(synced.nightContrast, 55)
    }
}
