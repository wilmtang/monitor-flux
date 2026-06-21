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

    func testChecksumUsesAddressSeed() {
        // The trailing checksum is an XOR over the leading bytes seeded with the I2C
        // address bytes (0x37 << 1) ^ 0x51, which aren't part of the buffer.
        let packet = Arm64DDCBackend.packet(feature: 0x10, value: 72)
        let seed = UInt8((0x37 << 1) ^ 0x51)
        let expected = packet.dropLast().reduce(seed) { $0 ^ $1 }

        XCTAssertEqual(packet.last, expected)
    }
}
