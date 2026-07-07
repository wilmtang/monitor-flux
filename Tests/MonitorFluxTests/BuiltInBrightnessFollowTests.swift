import XCTest
@testable import MonitorFlux

final class BuiltInBrightnessFollowTests: XCTestCase {
    private func context(
        id: CGDirectDisplayID,
        isBuiltIn: Bool = false,
        scheduled: Bool = false,
        adjustable: Bool = true,
        current: Double
    ) -> BuiltInBrightnessFollow.DisplayContext {
        BuiltInBrightnessFollow.DisplayContext(
            id: id,
            isBuiltIn: isBuiltIn,
            isBrightnessScheduled: scheduled,
            canAdjustBrightness: adjustable,
            currentBrightness: current
        )
    }

    func testNewFollowerIsAdoptedAtItsCurrentLevelWithoutMoving() {
        let plan = BuiltInBrightnessFollow.plan(
            builtInBrightness: 0.4,
            offsets: [:],
            displays: [
                context(id: 1, isBuiltIn: true, current: 0.4),
                context(id: 2, current: 0.7),
            ]
        )
        XCTAssertEqual(plan.offsets.keys.sorted(), [2])
        XCTAssertEqual(plan.offsets[2] ?? .nan, 0.3, accuracy: 1e-9)
        XCTAssertTrue(plan.adjustments.isEmpty)
    }

    func testFollowerTracksBuiltInAtItsOffset() {
        let plan = BuiltInBrightnessFollow.plan(
            builtInBrightness: 0.5,
            offsets: [2: 0.3],
            displays: [context(id: 2, current: 0.7)]
        )
        XCTAssertEqual(plan.offsets, [2: 0.3])
        XCTAssertEqual(plan.adjustments.map(\.displayID), [2])
        XCTAssertEqual(plan.adjustments.first?.targetBrightness ?? .nan, 0.8, accuracy: 1e-9)
    }

    func testClampedFollowerDoesNotRatchet() {
        // Built-in rises enough to pin the follower at 100%…
        let pinned = BuiltInBrightnessFollow.plan(
            builtInBrightness: 0.9,
            offsets: [2: 0.3],
            displays: [context(id: 2, current: 0.7)]
        )
        XCTAssertEqual(pinned.adjustments.map(\.displayID), [2])
        XCTAssertEqual(pinned.adjustments.first?.targetBrightness, 1.0)
        // …and the offset survives the clamp, so when the built-in comes back down the
        // follower returns to its original relationship instead of drifting darker.
        XCTAssertEqual(pinned.offsets, [2: 0.3])
        let released = BuiltInBrightnessFollow.plan(
            builtInBrightness: 0.4,
            offsets: pinned.offsets,
            displays: [context(id: 2, current: 1.0)]
        )
        XCTAssertEqual(released.adjustments.map(\.displayID), [2])
        XCTAssertEqual(released.adjustments.first?.targetBrightness ?? .nan, 0.7, accuracy: 1e-9)
    }

    func testSkipsBuiltInScheduledAndUnavailableDisplays() {
        let plan = BuiltInBrightnessFollow.plan(
            builtInBrightness: 0.5,
            offsets: [1: 0.0, 3: 0.1, 4: 0.1],
            displays: [
                context(id: 1, isBuiltIn: true, current: 0.5),
                context(id: 2, current: 0.6),
                context(id: 3, scheduled: true, current: 0.6),
                context(id: 4, adjustable: false, current: 0.6),
            ]
        )
        // Only the plain external carries an offset (freshly adopted); the built-in never
        // does, and the scheduled/unavailable entries are dropped as stale.
        XCTAssertEqual(plan.offsets.keys.sorted(), [2])
        XCTAssertEqual(plan.offsets[2] ?? .nan, 0.1, accuracy: 1e-9)
        XCTAssertTrue(plan.adjustments.isEmpty)
    }

    func testSubThresholdMoveIsSkipped() {
        let plan = BuiltInBrightnessFollow.plan(
            builtInBrightness: 0.401,
            offsets: [2: 0.3],
            displays: [context(id: 2, current: 0.7)]
        )
        XCTAssertEqual(plan.offsets, [2: 0.3])
        XCTAssertTrue(plan.adjustments.isEmpty)
    }

    func testNoBuiltInClearsOffsetsAndMovesNothing() {
        let plan = BuiltInBrightnessFollow.plan(
            builtInBrightness: nil,
            offsets: [2: 0.3],
            displays: [context(id: 2, current: 0.7)]
        )
        XCTAssertTrue(plan.offsets.isEmpty)
        XCTAssertTrue(plan.adjustments.isEmpty)
    }

    func testAnchoredOffsetCapturesManualTweak() {
        XCTAssertEqual(
            BuiltInBrightnessFollow.anchoredOffset(
                builtInBrightness: 0.4,
                display: context(id: 2, current: 0.55)
            ) ?? .nan,
            0.15,
            accuracy: 1e-9
        )
        XCTAssertNil(
            BuiltInBrightnessFollow.anchoredOffset(
                builtInBrightness: 0.4,
                display: context(id: 2, scheduled: true, current: 0.55)
            )
        )
        XCTAssertNil(
            BuiltInBrightnessFollow.anchoredOffset(
                builtInBrightness: nil,
                display: context(id: 2, current: 0.55)
            )
        )
    }
}
