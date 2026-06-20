import CoreGraphics
import Foundation
import IOKit
import IOKit.i2c

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePortShim(_ display: CGDirectDisplayID) -> io_service_t

enum NativeDDCError: LocalizedError, Sendable {
    case builtInDisplay
    case missingFramebuffer
    case noI2CBuses
    case noUsableBus(String)
    case badPacket

    var errorDescription: String? {
        switch self {
        case .builtInDisplay:
            "Built-in displays do not use DDC."
        case .missingFramebuffer:
            "macOS did not expose an IOKit framebuffer for this display."
        case .noI2CBuses:
            "No I2C/DDC buses were exposed for this display."
        case .noUsableBus(let detail):
            "No DDC bus accepted the command. \(detail)"
        case .badPacket:
            "Could not build a DDC/CI packet."
        }
    }
}

struct NativeDDCBackend: Sendable {
    func setBrightness(_ value: Int, display: DisplayInfo) throws {
        try setVCPFeature(0x10, value: value, display: display)
    }

    func setContrast(_ value: Int, display: DisplayInfo) throws {
        try setVCPFeature(0x12, value: value, display: display)
    }

    func setVCPFeature(_ feature: UInt8, value: Int, display: DisplayInfo) throws {
        guard !display.isBuiltIn else {
            throw NativeDDCError.builtInDisplay
        }

        let framebuffer = CGDisplayIOServicePortShim(display.id)
        guard framebuffer != 0 else {
            throw NativeDDCError.missingFramebuffer
        }

        var busCount = IOItemCount(0)
        let countResult = IOFBGetI2CInterfaceCount(framebuffer, &busCount)
        guard countResult == kIOReturnSuccess else {
            throw NativeDDCError.noUsableBus("I2C count failed: \(countResult)")
        }
        guard busCount > 0 else {
            throw NativeDDCError.noI2CBuses
        }

        var lastFailure = ""
        for bus in 0..<busCount {
            var interface = io_service_t(0)
            let copyResult = IOFBCopyI2CInterfaceForBus(framebuffer, IOOptionBits(bus), &interface)
            guard copyResult == kIOReturnSuccess, interface != 0 else {
                lastFailure = "Bus \(bus) copy failed: \(copyResult)"
                continue
            }
            defer {
                IOObjectRelease(interface)
            }

            do {
                try send(feature: feature, value: value, interface: interface)
                return
            } catch {
                lastFailure = "Bus \(bus): \(error.localizedDescription)"
            }
        }

        throw NativeDDCError.noUsableBus(lastFailure)
    }

    static func packet(feature: UInt8, value: Int) -> [UInt8] {
        let clamped = UInt16(value.clamped(to: 0...100))
        let high = UInt8((clamped >> 8) & 0xFF)
        let low = UInt8(clamped & 0xFF)
        var bytes: [UInt8] = [
            0x51,
            0x84,
            0x03,
            feature,
            high,
            low
        ]
        bytes.append(checksum(for: bytes))
        return bytes
    }

    static func checksum(for bytes: [UInt8]) -> UInt8 {
        bytes.reduce(UInt8(0x6E)) { partialResult, byte in
            partialResult ^ byte
        }
    }

    private func send(feature: UInt8, value: Int, interface: io_service_t) throws {
        var connect: IOI2CConnectRef?
        let openResult = IOI2CInterfaceOpen(interface, IOOptionBits(0), &connect)
        guard openResult == kIOReturnSuccess, let connect else {
            throw NativeDDCError.noUsableBus("Open failed: \(openResult)")
        }
        defer {
            IOI2CInterfaceClose(connect, IOOptionBits(0))
        }

        var request = IOI2CRequest()
        var packet = Self.packet(feature: feature, value: value)
        guard !packet.isEmpty else {
            throw NativeDDCError.badPacket
        }

        let result = packet.withUnsafeMutableBytes { rawBuffer -> IOReturn in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kIOReturnBadArgument
            }

            request.sendAddress = 0x6E
            request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
            request.sendBuffer = vm_address_t(UInt(bitPattern: baseAddress))
            request.sendBytes = UInt32(rawBuffer.count)
            request.replyAddress = 0
            request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
            request.replyBuffer = 0
            request.replyBytes = 0
            request.minReplyDelay = 0
            request.commFlags = 0
            return IOI2CSendRequest(connect, IOOptionBits(0), &request)
        }

        guard result == kIOReturnSuccess else {
            throw NativeDDCError.noUsableBus("Send failed: \(result)")
        }
        guard request.result == kIOReturnSuccess else {
            throw NativeDDCError.noUsableBus("Transaction failed: \(request.result)")
        }
    }
}
