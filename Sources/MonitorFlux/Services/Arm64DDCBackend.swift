import CoreGraphics
import Foundation
import IOKit

// DDC/CI over I2C on Apple Silicon goes through the private `IOAVService` API rather
// than the Intel IOFramebuffer path. The technique and byte layout follow MonitorControl
// (MIT) — github.com/MonitorControl/MonitorControl `Support/Arm64DDC.swift` — and Lunar.
// These symbols are exported by IOKit (already linked); `@_silgen_name` binds to them
// the same way `NativeDDCBackend` binds to `CGDisplayIOServicePort`.
@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(
    _ allocator: CFAllocator?,
    _ service: io_service_t
) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(
    _ service: CFTypeRef,
    _ chipAddress: UInt32,
    _ offset: UInt32,
    _ inputBuffer: UnsafeMutableRawPointer,
    _ inputBufferSize: UInt32
) -> IOReturn

private let arm64DDC7BitAddress: UInt8 = 0x37 // DisplayPort DDC chip address
private let arm64DDCDataAddress: UInt8 = 0x51 // DDC/CI data offset

enum Arm64DDCError: LocalizedError, Sendable {
    case builtInDisplay
    case noMatchingService
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .builtInDisplay:
            "Built-in displays do not use DDC."
        case .noMatchingService:
            "No Apple Silicon DDC service (IOAVService) was found for this display. Built-in HDMI ports and some docks/KVMs don't expose one — a direct USB-C/DisplayPort connection usually does."
        case .writeFailed:
            "The display did not accept the DDC command (IOAVServiceWriteI2C failed)."
        }
    }
}

/// Stateless Apple Silicon DDC writer. Like `NativeDDCBackend`, it resolves the display's
/// service per call (no cached `CFTypeRef` state to keep it `Sendable` for detached writes).
struct Arm64DDCBackend: Sendable {
    func setBrightness(_ value: Int, display: DisplayInfo) throws {
        try setVCPFeature(0x10, value: value, display: display)
    }

    func setContrast(_ value: Int, display: DisplayInfo) throws {
        try setVCPFeature(0x12, value: value, display: display)
    }

    func setVolume(_ value: Int, display: DisplayInfo) throws {
        try setVCPFeature(0x62, value: value, display: display)
    }

    func setVCPFeature(_ feature: UInt8, value: Int, display: DisplayInfo) throws {
        guard !display.isBuiltIn else {
            throw Arm64DDCError.builtInDisplay
        }
        guard let service = Self.avService(for: display.id) else {
            throw Arm64DDCError.noMatchingService
        }
        guard Self.write(service: service, feature: feature, value: value) else {
            throw Arm64DDCError.writeFailed
        }
    }

    // MARK: - Packet construction (pure, unit-tested)

    /// The DDC/CI "set VCP feature" packet passed to `IOAVServiceWriteI2C`:
    /// `[0x80 | (len+1), len, feature, valueHi, valueLo, checksum]`.
    static func packet(feature: UInt8, value: Int) -> [UInt8] {
        let clamped = UInt16(value.clamped(to: ControlRanges.hardwarePercent))
        let payload: [UInt8] = [feature, UInt8(clamped >> 8), UInt8(clamped & 0xFF)]
        var bytes: [UInt8] = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)] + payload + [0]
        // The checksum seed includes the I2C address bytes, which aren't in the buffer.
        let seed = UInt8((arm64DDC7BitAddress << 1) ^ arm64DDCDataAddress)
        bytes[bytes.count - 1] = bytes.dropLast().reduce(seed) { $0 ^ $1 }
        return bytes
    }

    // MARK: - Write

    private static func write(service: CFTypeRef, feature: UInt8, value: Int) -> Bool {
        var bytes = packet(feature: feature, value: value)
        for attempt in 0..<5 {
            usleep(10000)
            let result = bytes.withUnsafeMutableBytes { buffer -> IOReturn in
                guard let base = buffer.baseAddress else {
                    return kIOReturnBadArgument
                }
                return IOAVServiceWriteI2C(
                    service,
                    UInt32(arm64DDC7BitAddress),
                    UInt32(arm64DDCDataAddress),
                    base,
                    UInt32(buffer.count)
                )
            }
            if result == kIOReturnSuccess {
                return true
            }
            if attempt < 4 {
                usleep(20000)
            }
        }
        return false
    }

    // MARK: - Service discovery & matching

    private struct Candidate {
        var productID: Int64?
        var serialNumber: Int64?
        var service: CFTypeRef
    }

    /// Walk the IORegistry pairing each framebuffer (`AppleCLCD2` / `IOMobileFramebufferShim`)
    /// with the external `DCPAVServiceProxy` that follows it, then match the resulting
    /// services to `displayID` by EDID product/serial (via public CoreGraphics APIs).
    private static func avService(for displayID: CGDirectDisplayID) -> CFTypeRef? {
        let candidates = discoverCandidates()
        guard !candidates.isEmpty else {
            return nil
        }

        let model = Int64(CGDisplayModelNumber(displayID))
        let serial = Int64(CGDisplaySerialNumber(displayID))

        var best: (score: Int, service: CFTypeRef)?
        for candidate in candidates {
            var score = 0
            if serial != 0, candidate.serialNumber == serial {
                score += 5
            }
            if model != 0, candidate.productID == model {
                score += 3
            }
            if best == nil || score > best!.score {
                best = (score, candidate.service)
            }
        }

        if let best, best.score > 0 {
            return best.service
        }
        // No identity match: a single external display/service pair is unambiguous.
        if candidates.count == 1 {
            return candidates[0].service
        }
        return best?.service
    }

    private static func discoverCandidates() -> [Candidate] {
        var candidates: [Candidate] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else {
            return candidates
        }
        defer {
            IOObjectRelease(root)
        }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(
            root,
            "IOService",
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else {
            return candidates
        }
        defer {
            IOObjectRelease(iterator)
        }

        let framebufferNames = ["AppleCLCD2", "IOMobileFramebufferShim"]
        var pending: (productID: Int64?, serialNumber: Int64?)?

        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 {
                break
            }
            defer {
                IOObjectRelease(entry)
            }

            guard let name = entryName(entry) else {
                continue
            }

            if framebufferNames.contains(where: { name.contains($0) }) {
                pending = productAttributes(of: entry)
            } else if name.contains("DCPAVServiceProxy") {
                guard isExternal(entry),
                      let service = IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?
                        .takeRetainedValue()
                else {
                    continue
                }
                candidates.append(
                    Candidate(
                        productID: pending?.productID,
                        serialNumber: pending?.serialNumber,
                        service: service
                    )
                )
            }
        }
        return candidates
    }

    private static func entryName(_ entry: io_registry_entry_t) -> String? {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer {
            buffer.deallocate()
        }
        guard IORegistryEntryGetName(entry, buffer) == KERN_SUCCESS else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func isExternal(_ entry: io_registry_entry_t) -> Bool {
        guard let raw = IORegistryEntryCreateCFProperty(
            entry,
            "Location" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        )?.takeRetainedValue() as? String else {
            return false
        }
        return raw == "External"
    }

    private static func productAttributes(of entry: io_registry_entry_t) -> (productID: Int64?, serialNumber: Int64?) {
        guard let attributes = IORegistryEntryCreateCFProperty(
            entry,
            "DisplayAttributes" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        )?.takeRetainedValue() as? NSDictionary,
            let product = attributes["ProductAttributes"] as? NSDictionary
        else {
            return (nil, nil)
        }
        let productID = product["ProductID"] as? Int64 ?? (product["ProductID"] as? Int).map(Int64.init)
        let serial = product["SerialNumber"] as? Int64 ?? (product["SerialNumber"] as? Int).map(Int64.init)
        return (productID, serial)
    }
}
