import CoreGraphics
import XCTest
@testable import MonitorFlux

final class DisplayControlSyncTests: XCTestCase {
    private func contrast(
        id: CGDirectDisplayID,
        adjustable: Bool = true
    ) -> DisplayControlSync.ContrastContext {
        DisplayControlSync.ContrastContext(
            id: id,
            canAdjustContrast: adjustable
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
}
