// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

final class Arm64DDCPacketTests: XCTestCase {
    #if arch(arm64)
    func testHardwareBackendDoesNotAdvertiseIntelFallback() {
        let status = HardwareDDCBackend().status

        XCTAssertEqual(status.toolName, "Native IOAVService")
        XCTAssertNil(status.toolPath)
    }
    #endif

    func testBrightnessPacketLayoutAndChecksum() {
        // Layout: [0x80 | (len+1), len, feature, valueHi, valueLo, checksum] with len = 3.
        let packet = Arm64DDCBackend.packet(feature: 0x10, value: 50)

        XCTAssertEqual(packet, [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    func testValueIsClampedToHardwareRange() {
        let packet = Arm64DDCBackend.packet(feature: 0x12, value: 500)

        XCTAssertEqual(packet[3], 0x00) // high byte
        XCTAssertEqual(packet[4], 100)  // low byte clamped to 100
    }

    func testVolumePacketUsesVCP0x62() {
        let packet = Arm64DDCBackend.packet(feature: 0x62, value: 30)

        XCTAssertEqual(packet[2], 0x62) // VCP feature: audio speaker volume
        XCTAssertEqual(packet[4], 30)   // low byte
        let seed = UInt8((0x37 << 1) ^ 0x51)
        XCTAssertEqual(packet.last, packet.dropLast().reduce(seed) { $0 ^ $1 })
    }

    func testChecksumUsesAddressSeed() {
        // The trailing checksum is an XOR over the leading bytes seeded with the I2C
        // address bytes (0x37 << 1) ^ 0x51, which aren't part of the buffer.
        let packet = Arm64DDCBackend.packet(feature: 0x10, value: 72)
        let seed = UInt8((0x37 << 1) ^ 0x51)
        let expected = packet.dropLast().reduce(seed) { $0 ^ $1 }

        XCTAssertEqual(packet.last, expected)
    }

    // MARK: - Identical-monitor service de-duplication

    func testFirstDisplayTakesBestRankedCandidate() {
        // Nothing taken yet -> the best-ranked (first) candidate index is chosen.
        XCTAssertEqual(Arm64DDCBackend.chooseCandidateIndex(rankedIndices: [0, 1], taken: []), 0)
    }

    func testSecondIdenticalMonitorSkipsTheTakenCandidate() {
        // Two identical monitors rank candidates the same ([0, 1]); once the first display
        // has taken index 0, the second must get index 1 — not 0 again (the bug).
        XCTAssertEqual(Arm64DDCBackend.chooseCandidateIndex(rankedIndices: [0, 1], taken: [0]), 1)
    }

    func testHigherRankedCandidateWinsWhenFree() {
        // Ranking order is honored: index 2 is best-ranked here and is free, so it's chosen
        // even though lower indices exist.
        XCTAssertEqual(Arm64DDCBackend.chooseCandidateIndex(rankedIndices: [2, 0, 1], taken: [0]), 2)
    }

    func testFallsBackToBestRankedWhenAllTaken() {
        // Fewer services than displays: every candidate is taken, so fall back to best-ranked
        // rather than returning nil (a write is better than no write).
        XCTAssertEqual(Arm64DDCBackend.chooseCandidateIndex(rankedIndices: [1, 0], taken: [0, 1]), 1)
    }

    func testNoCandidatesYieldsNil() {
        XCTAssertNil(Arm64DDCBackend.chooseCandidateIndex(rankedIndices: [], taken: [0]))
    }

    // MARK: - DDC capability (global, non-borrowing — unlike the write-path fallback above)

    func testMatchScoreSerialBeatsModelAndStacks() {
        // Serial match (+5) and model match (+3) stack; either alone scores on its own.
        XCTAssertEqual(Arm64DDCBackend.matchScore(displayModel: 5, displaySerial: 9, candidateProductID: 5, candidateSerial: 9), 8)
        XCTAssertEqual(Arm64DDCBackend.matchScore(displayModel: 5, displaySerial: 9, candidateProductID: 5, candidateSerial: 0), 3)
        XCTAssertEqual(Arm64DDCBackend.matchScore(displayModel: 5, displaySerial: 9, candidateProductID: 9, candidateSerial: 9), 5)
        // No model/serial to match on (both zero) → score 0, never a coincidental match.
        XCTAssertEqual(Arm64DDCBackend.matchScore(displayModel: 0, displaySerial: 0, candidateProductID: 0, candidateSerial: 0), 0)
    }

    func testCapabilityGivesTheLoneServiceToTheMatchingDisplay() {
        // 1 DDC monitor (score 3) + 1 non-DDC monitor (score 0), 1 service: only the matching
        // one is capable — the non-DDC display does NOT borrow the service (the bug being fixed).
        let capable = Arm64DDCBackend.capableDisplayIDs(scores: [(1, 3), (2, 0)], serviceCount: 1)
        XCTAssertEqual(capable, [1])
    }

    func testCapabilityCreditsEveryDisplayWhenServicesCoverThem() {
        // 2 services for 2 displays → both capable even at score 0, so a lone DDC monitor whose
        // EDID doesn't match its own service is not wrongly demoted (no false negatives).
        let capable = Arm64DDCBackend.capableDisplayIDs(scores: [(1, 0), (2, 0)], serviceCount: 2)
        XCTAssertEqual(capable, [1, 2])
    }

    func testCapabilitySingleDisplaySingleServiceIsCapableEvenAtZeroScore() {
        let capable = Arm64DDCBackend.capableDisplayIDs(scores: [(7, 0)], serviceCount: 1)
        XCTAssertEqual(capable, [7])
    }

    func testCapabilityNoServicesMeansNoneCapable() {
        XCTAssertEqual(Arm64DDCBackend.capableDisplayIDs(scores: [(1, 0), (2, 3)], serviceCount: 0), [])
    }

    func testCapabilityPicksHigherScorersWhenServicesAreScarce() {
        // 2 services, 3 displays: the two best-scoring win; the score-0 (non-DDC) one is left out.
        let capable = Arm64DDCBackend.capableDisplayIDs(scores: [(1, 3), (2, 0), (3, 5)], serviceCount: 2)
        XCTAssertEqual(capable, [1, 3])
    }

    func testDDCTransportEligibilityExcludesBuiltInAndVirtualDisplays() {
        XCTAssertTrue(makeDisplay(id: 1).isDDCTransportEligible)
        XCTAssertFalse(makeDisplay(id: 2, isBuiltIn: true).isDDCTransportEligible)
        XCTAssertFalse(makeDisplay(id: 3, isVirtual: true).isDDCTransportEligible)
    }

    func testVirtualDisplayDoesNotInflateCapabilityAllocation() {
        let displays = [makeDisplay(id: 1), makeDisplay(id: 2, isVirtual: true)]
        let scores = displays
            .filter(\.isDDCTransportEligible)
            .map { (id: $0.id, score: 0) }

        XCTAssertEqual(Arm64DDCBackend.capableDisplayIDs(scores: scores, serviceCount: 1), [1])
    }

    private func makeDisplay(
        id: CGDirectDisplayID,
        isBuiltIn: Bool = false,
        isVirtual: Bool = false
    ) -> DisplayInfo {
        DisplayInfo(
            id: id,
            name: "Display \(id)",
            frameDescription: "",
            isBuiltIn: isBuiltIn,
            isVirtual: isVirtual
        )
    }
}
