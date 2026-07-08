// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

/// The preferences key must be stable per physical monitor — that's what lets a multi-monitor
/// setup remember each display's settings and never cross-apply them.
final class DisplayIdentityTests: XCTestCase {
    func testKeyIsIndependentOfDisplayIDWhenEDIDIsPresent() {
        // Same monitor (vendor/model/serial), different macOS-assigned display IDs across
        // two sessions — the key must not change.
        let first = DisplayIdentity.key(vendor: 4, model: 41462, serial: 12345, displayID: 1)
        let second = DisplayIdentity.key(vendor: 4, model: 41462, serial: 12345, displayID: 99)
        XCTAssertEqual(first, second)
    }

    func testDistinctMonitorsGetDistinctKeys() {
        let a = DisplayIdentity.key(vendor: 4, model: 41462, serial: 12345, displayID: 1)
        let b = DisplayIdentity.key(vendor: 4, model: 41462, serial: 67890, displayID: 2)
        XCTAssertNotEqual(a, b)
    }

    func testFallsBackToDisplayIDWithoutEDID() {
        let key = DisplayIdentity.key(vendor: 0, model: 0, serial: 0, displayID: 7)
        XCTAssertEqual(key, "display-7")
    }

    func testSeriallessMonitorStillKeysOffVendorAndModel() {
        let key = DisplayIdentity.key(vendor: 4, model: 41462, serial: 0, displayID: 3)
        XCTAssertEqual(key, "v4-m41462")
    }

    func testIdenticalMonitorsAreDisambiguatedWhenBothConnected() {
        // Two monitors that report the same EDID identity (e.g. a matched pair with no
        // distinct serial) must still get separate preference keys while both are attached.
        let sources = [
            DisplayIdentity.Source(vendor: 4, model: 41462, serial: 0, displayID: 1),
            DisplayIdentity.Source(vendor: 4, model: 41462, serial: 0, displayID: 2),
        ]
        let keys = DisplayIdentity.keys(for: sources)
        XCTAssertEqual(keys, ["v4-m41462", "v4-m41462#2"])
        XCTAssertEqual(Set(keys).count, 2)
    }

    func testDistinctMonitorsKeepUnsuffixedKeys() {
        let sources = [
            DisplayIdentity.Source(vendor: 610, model: 42808, serial: 0, displayID: 1),
            DisplayIdentity.Source(vendor: 4, model: 41462, serial: 555, displayID: 2),
        ]
        let keys = DisplayIdentity.keys(for: sources)
        XCTAssertEqual(keys, ["v610-m42808", "v4-m41462-s555"])
    }
}
