// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import XCTest
@testable import MonitorFlux

final class DDCPacketTests: XCTestCase {
    func testBrightnessPacketUsesSetVCPFeature() {
        let packet = NativeDDCBackend.packet(feature: 0x10, value: 45)

        XCTAssertEqual(packet, [0x51, 0x84, 0x03, 0x10, 0x00, 0x2D, 0x85])
    }

    func testPacketValueIsClamped() {
        let packet = NativeDDCBackend.packet(feature: 0x12, value: 500)

        XCTAssertEqual(packet[4], 0x00)
        XCTAssertEqual(packet[5], 100)
    }

    func testChecksumXorsToZeroWithDDCAddress() {
        let packet = NativeDDCBackend.packet(feature: 0x10, value: 72)
        let checksum = packet.reduce(UInt8(0x6E)) { partialResult, byte in
            partialResult ^ byte
        }

        XCTAssertEqual(checksum, 0)
    }
}
