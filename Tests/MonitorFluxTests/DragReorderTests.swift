// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

final class DragReorderTests: XCTestCase {
    private let heights: [String: CGFloat] = ["a": 100, "b": 100, "c": 100]
    private let spacing: CGFloat = 14

    func testSmallOffsetDoesNotSwap() {
        let result = DragReorder.resolve(
            order: ["a", "b", "c"], draggingKey: "a", offset: 40, heights: heights, spacing: spacing
        )
        XCTAssertEqual(result.order, ["a", "b", "c"])
        XCTAssertEqual(result.offset, 40, accuracy: 0.0001)
    }

    func testCrossingDownSwapsAndKeepsResidualOffset() {
        // span for "b" = 100 + 14 = 114; crossing half (57) swaps a past b.
        let result = DragReorder.resolve(
            order: ["a", "b", "c"], draggingKey: "a", offset: 70, heights: heights, spacing: spacing
        )
        XCTAssertEqual(result.order, ["b", "a", "c"])
        // residual = 70 - 114 = -44, so the card stays continuous under the cursor.
        XCTAssertEqual(result.offset, 70 - 114, accuracy: 0.0001)
    }

    func testCrossingUpSwaps() {
        let result = DragReorder.resolve(
            order: ["a", "b", "c"], draggingKey: "c", offset: -70, heights: heights, spacing: spacing
        )
        XCTAssertEqual(result.order, ["a", "c", "b"])
        XCTAssertEqual(result.offset, -70 + 114, accuracy: 0.0001)
    }

    func testLargeOffsetSwapsPastMultipleNeighbors() {
        // 70 + 114 = 184 of travel: past b (>57) then past c (>57 of the next 114 span).
        let result = DragReorder.resolve(
            order: ["a", "b", "c"], draggingKey: "a", offset: 184, heights: heights, spacing: spacing
        )
        XCTAssertEqual(result.order, ["b", "c", "a"])
        XCTAssertEqual(result.offset, 184 - 114 - 114, accuracy: 0.0001)
    }

    func testStopsAtEnds() {
        // Already last; a downward offset can't swap further.
        let result = DragReorder.resolve(
            order: ["a", "b", "c"], draggingKey: "c", offset: 300, heights: heights, spacing: spacing
        )
        XCTAssertEqual(result.order, ["a", "b", "c"])
        XCTAssertEqual(result.offset, 300, accuracy: 0.0001)
    }

    func testVariableHeightsUseTheCrossedNeighborSpan() {
        // The short built-in card (40) is easier to cross than a tall one.
        let mixed: [String: CGFloat] = ["builtin": 40, "ext": 160]
        let down = DragReorder.resolve(
            order: ["builtin", "ext"], draggingKey: "builtin", offset: 90, heights: mixed, spacing: spacing
        )
        XCTAssertEqual(down.order, ["ext", "builtin"]) // span(ext)=174, half=87, 90>87 → swap
        XCTAssertEqual(down.offset, 90 - 174, accuracy: 0.0001)
    }
}
