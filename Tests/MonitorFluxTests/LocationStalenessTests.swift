// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

final class LocationStalenessTests: XCTestCase {
    private func utcInstant(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func zone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier)!
    }

    func testFarApartZonesMismatch() throws {
        let mismatch = try XCTUnwrap(LocationStaleness.check(
            placeZoneID: "America/Los_Angeles",
            systemZone: zone("Asia/Tokyo"),
            now: utcInstant(2026, 7, 1)
        ))
        XCTAssertEqual(mismatch.placeZoneID, "America/Los_Angeles")
        XCTAssertEqual(mismatch.systemZoneID, "Asia/Tokyo")
        XCTAssertEqual(mismatch.systemClockLabel, "Tokyo")
    }

    func testSameOffsetDifferentIDsDoNotWarn() {
        // Madrid and Paris are distinct IANA zones with identical offsets year-round;
        // comparing ids instead of offsets would nag someone who isn't traveling at all.
        XCTAssertNil(LocationStaleness.check(
            placeZoneID: "Europe/Madrid",
            systemZone: zone("Europe/Paris"),
            now: utcInstant(2026, 7, 1)
        ))
        XCTAssertNil(LocationStaleness.check(
            placeZoneID: "Europe/Madrid",
            systemZone: zone("Europe/Paris"),
            now: utcInstant(2026, 1, 1)
        ))
    }

    func testDSTAsymmetryIsEvaluatedAtNow() {
        // Phoenix skips DST: it matches Denver in winter and trails it by an hour in summer.
        XCTAssertNil(LocationStaleness.check(
            placeZoneID: "America/Phoenix",
            systemZone: zone("America/Denver"),
            now: utcInstant(2026, 1, 15)
        ))
        XCTAssertNotNil(LocationStaleness.check(
            placeZoneID: "America/Phoenix",
            systemZone: zone("America/Denver"),
            now: utcInstant(2026, 7, 15)
        ))
    }

    func testDismissalSilencesExactPairOnly() throws {
        let mismatch = try XCTUnwrap(LocationStaleness.check(
            placeZoneID: "America/Los_Angeles",
            systemZone: zone("Asia/Tokyo"),
            now: utcInstant(2026, 7, 1)
        ))

        XCTAssertNil(LocationStaleness.check(
            placeZoneID: "America/Los_Angeles",
            systemZone: zone("Asia/Tokyo"),
            now: utcInstant(2026, 7, 1),
            dismissedKey: mismatch.dismissalKey
        ), "the dismissed pair stays quiet")

        XCTAssertNotNil(LocationStaleness.check(
            placeZoneID: "America/Los_Angeles",
            systemZone: zone("Europe/London"),
            now: utcInstant(2026, 7, 1),
            dismissedKey: mismatch.dismissalKey
        ), "moving on to a different zone re-arms the hint")
    }

    func testUnknownPlaceZoneNeverWarns() {
        XCTAssertNil(LocationStaleness.check(
            placeZoneID: nil,
            systemZone: zone("Asia/Tokyo"),
            now: utcInstant(2026, 7, 1)
        ))
        XCTAssertNil(LocationStaleness.check(
            placeZoneID: "Not/A_Zone",
            systemZone: zone("Asia/Tokyo"),
            now: utcInstant(2026, 7, 1)
        ))
    }
}
