import XCTest
@testable import MonitorFlux

final class DisplayOrderingTests: XCTestCase {
    func testSortedFollowsTheSavedOrder() {
        let sorted = DisplayOrdering.sorted(["a", "b", "c"], by: ["c", "a", "b"])
        XCTAssertEqual(sorted, ["c", "a", "b"])
    }

    func testUnlistedKeysKeepDetectionOrderAfterListedOnes() {
        // "b" is in the saved order; "a" and "c" are new and keep their detection order, last.
        let sorted = DisplayOrdering.sorted(["a", "b", "c"], by: ["b"])
        XCTAssertEqual(sorted, ["b", "a", "c"])
    }

    func testSortedIgnoresStaleKeysInOrder() {
        // "x" was saved but is no longer connected; it must not appear or disturb the rest.
        let sorted = DisplayOrdering.sorted(["a", "b"], by: ["x", "b", "a"])
        XCTAssertEqual(sorted, ["b", "a"])
    }

    func testReorderedMovesDraggedBeforeTarget() {
        XCTAssertEqual(DisplayOrdering.reordered(["a", "b", "c"], moving: "c", before: "a"), ["c", "a", "b"])
        XCTAssertEqual(DisplayOrdering.reordered(["a", "b", "c"], moving: "a", before: "c"), ["b", "a", "c"])
    }

    func testReorderedIsNoOpForMissingOrEqualKeys() {
        XCTAssertEqual(DisplayOrdering.reordered(["a", "b"], moving: "a", before: "a"), ["a", "b"])
        XCTAssertEqual(DisplayOrdering.reordered(["a", "b"], moving: "z", before: "a"), ["a", "b"])
        XCTAssertEqual(DisplayOrdering.reordered(["a", "b"], moving: "a", before: "z"), ["a", "b"])
    }
}
