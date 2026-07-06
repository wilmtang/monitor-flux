import XCTest
@testable import MonitorFlux

final class AmbientBrightnessSyncTests: XCTestCase {
    private func context(
        id: CGDirectDisplayID,
        isBuiltIn: Bool = false,
        scheduled: Bool = false,
        adjustable: Bool = true,
        current: Double
    ) -> AmbientBrightnessSync.DisplayContext {
        AmbientBrightnessSync.DisplayContext(
            id: id,
            isBuiltIn: isBuiltIn,
            isBrightnessScheduled: scheduled,
            canAdjustBrightness: adjustable,
            currentBrightness: current
        )
    }

    func testFirstObservationOnlySetsBaseline() {
        let plan = AmbientBrightnessSync.plan(
            previousBuiltInBrightness: nil,
            currentBuiltInBrightness: 0.42,
            displays: [context(id: 2, current: 0.7)]
        )
        XCTAssertEqual(plan.baseline, 0.42)
        XCTAssertNil(plan.percentDelta)
        XCTAssertTrue(plan.adjustments.isEmpty)
    }

    func testDeltaMovesOnlyEligibleExternals() {
        let plan = AmbientBrightnessSync.plan(
            previousBuiltInBrightness: 0.40,
            currentBuiltInBrightness: 0.52,
            displays: [
                context(id: 1, isBuiltIn: true, current: 0.52),
                context(id: 2, current: 0.50),
                context(id: 3, scheduled: true, current: 0.50),
                context(id: 4, adjustable: false, current: 0.50),
                context(id: 5, current: 0.95),
            ]
        )
        XCTAssertEqual(plan.baseline, 0.52)
        XCTAssertEqual(plan.percentDelta, 12)
        XCTAssertEqual(
            plan.adjustments,
            [
                AmbientBrightnessSync.Adjustment(displayID: 2, targetBrightness: 0.62),
                AmbientBrightnessSync.Adjustment(displayID: 5, targetBrightness: 1.0),
            ]
        )
    }

    func testSubPercentChangesAccumulateAgainstOldBaseline() {
        let tiny = AmbientBrightnessSync.plan(
            previousBuiltInBrightness: 0.40,
            currentBuiltInBrightness: 0.409,
            displays: [context(id: 2, current: 0.5)]
        )
        XCTAssertEqual(tiny.baseline, 0.40)
        XCTAssertNil(tiny.percentDelta)
        XCTAssertTrue(tiny.adjustments.isEmpty)

        let accumulated = AmbientBrightnessSync.plan(
            previousBuiltInBrightness: tiny.baseline,
            currentBuiltInBrightness: 0.411,
            displays: [context(id: 2, current: 0.5)]
        )
        XCTAssertEqual(accumulated.baseline, 0.411)
        XCTAssertEqual(accumulated.percentDelta, 1)
        XCTAssertEqual(
            accumulated.adjustments,
            [AmbientBrightnessSync.Adjustment(displayID: 2, targetBrightness: 0.51)]
        )
    }
}
