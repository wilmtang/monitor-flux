// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

@MainActor
final class DDCWriteSchedulerTests: XCTestCase {
    /// A short throttle window keeps the trailing-edge tests fast while staying far above
    /// timer jitter.
    private let interval = 0.05

    func testFirstWriteFiresImmediately() {
        let scheduler = DDCWriteScheduler(interval: interval)
        var written: [Int] = []

        scheduler.schedule(key: "1.b") { written.append(1) }

        XCTAssertEqual(written, [1], "The leading edge writes synchronously so the monitor tracks")
    }

    func testDragCoalescesToOneTrailingWriteWithTheLatestValue() {
        let scheduler = DDCWriteScheduler(interval: interval)
        var written: [Int] = []
        let settled = expectation(description: "trailing write")

        scheduler.schedule(key: "1.b") { written.append(1) }
        // Two more ticks inside the window: only the newest survives, as one trailing write.
        scheduler.schedule(key: "1.b") { written.append(2) }
        scheduler.schedule(key: "1.b") {
            written.append(3)
            settled.fulfill()
        }

        XCTAssertEqual(written, [1], "In-window writes must not fire on the leading edge")
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(written, [1, 3], "The drag settles on exactly the latest value")
    }

    func testWriteAfterQuietPeriodTakesTheLeadingEdgeAgain() {
        let scheduler = DDCWriteScheduler(interval: interval)
        var written: [Int] = []
        let quietPeriod = expectation(description: "throttle window passed")

        scheduler.schedule(key: "1.b") { written.append(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval * 2) { quietPeriod.fulfill() }
        wait(for: [quietPeriod], timeout: 2)

        scheduler.schedule(key: "1.b") { written.append(2) }
        XCTAssertEqual(written, [1, 2], "Past the window, the next write is immediate again")
    }

    func testControlsThrottleIndependently() {
        let scheduler = DDCWriteScheduler(interval: interval)
        var written: [String] = []

        scheduler.schedule(key: "1.b") { written.append("brightness") }
        scheduler.schedule(key: "1.c") { written.append("contrast") }

        XCTAssertEqual(written, ["brightness", "contrast"], "One control's window must not delay another's")
    }

    func testRetainOnlyCancelsPendingWritesForDeadKeys() {
        let scheduler = DDCWriteScheduler(interval: interval)
        var written: [Int] = []
        let windowPassed = expectation(description: "trailing deadline passed")

        scheduler.schedule(key: "1.b") { written.append(1) }
        scheduler.schedule(key: "1.b") { written.append(2) } // pending trailing write

        scheduler.retainOnly { _ in false } // the display disconnected

        DispatchQueue.main.asyncAfter(deadline: .now() + interval * 3) { windowPassed.fulfill() }
        wait(for: [windowPassed], timeout: 2)
        XCTAssertEqual(written, [1], "A cancelled trailing write must not land after its display is gone")
    }
}
