import XCTest
@testable import MonitorFlux

final class Arm64DDCPacketTests: XCTestCase {
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
}
