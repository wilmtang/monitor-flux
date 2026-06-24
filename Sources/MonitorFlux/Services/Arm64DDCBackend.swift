import CoreGraphics
import Foundation
import IOKit

// DDC/CI over I2C on Apple Silicon goes through the private `IOAVService` API rather
// than the Intel IOFramebuffer path. The technique and byte layout follow MonitorControl
// (MIT), `Support/Arm64DDC.swift`; see ACKNOWLEDGEMENTS.md. These symbols are exported by
// IOKit (already linked); `@_silgen_name` binds to them the same way `NativeDDCBackend`
// binds to `CGDisplayIOServicePort`.
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

/// Caches the resolved `IOAVService` per display so a brightness/contrast/volume drag
/// doesn't walk the whole IORegistry on every write — the per-write walk was a real source
/// of DDC lag. Thread-safe because writes run on a background serial queue. Invalidated on
/// display reconfiguration, where a hot-plug can hand the same `CGDirectDisplayID` a new
/// service.
private final class Arm64DDCServiceCache: @unchecked Sendable {
    static let shared = Arm64DDCServiceCache()
    private let lock = NSLock()

    private struct Assignment {
        let candidateIndex: Int
        let service: CFTypeRef
    }
    private var services: [CGDirectDisplayID: Assignment] = [:]

    /// Resolve (and cache) the service for `id`, choosing the best candidate whose stable
    /// discovery index isn't already assigned to a *different* display. Two identical
    /// monitors (same model, no distinct serial) score equally against every candidate, so
    /// without this they'd both pick candidate 0 and DDC writes for the second would hit the
    /// first. We dedupe on the candidate *index* rather than the `CFTypeRef`: every
    /// `resolveRanked()` call mints fresh service objects (so `===` across displays never
    /// matches), but `discoverCandidates()` walks the IORegistry in a stable order, so index
    /// N refers to the same physical service each time (the cache is cleared on hot-plug).
    func service(for id: CGDirectDisplayID, resolveRanked: () -> [(index: Int, service: CFTypeRef)]) -> CFTypeRef? {
        lock.lock()
        if let cached = services[id] {
            lock.unlock()
            return cached.service
        }
        lock.unlock()

        // Resolve outside the lock (the IORegistry walk is slow).
        let ranked = resolveRanked()
        guard !ranked.isEmpty else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        if let cached = services[id] {
            return cached.service
        }
        let takenIndices = Set(services.values.map(\.candidateIndex))
        let chosenIndex = Arm64DDCBackend.chooseCandidateIndex(
            rankedIndices: ranked.map(\.index),
            taken: takenIndices
        )
        let chosen = ranked.first { $0.index == chosenIndex } ?? ranked[0]
        services[id] = Assignment(candidateIndex: chosen.index, service: chosen.service)
        return chosen.service
    }

    /// Drop one display's cached service (e.g. after a failed write to it), leaving other
    /// displays' cached services intact so they don't have to re-walk the IORegistry.
    func invalidate(displayID: CGDirectDisplayID) {
        lock.lock()
        services[displayID] = nil
        lock.unlock()
    }

    func invalidate() {
        lock.lock()
        services.removeAll()
        lock.unlock()
    }
}

/// Apple Silicon DDC writer. Resolves each display's `IOAVService` once and caches it
/// (see `Arm64DDCServiceCache`); stays a `Sendable` value type so it can be used from the
/// background DDC queue.
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

    /// Drop any cached `IOAVService`s; call when the display layout changes.
    static func invalidateServiceCache() {
        Arm64DDCServiceCache.shared.invalidate()
    }

    /// Non-destructive DDC capability probe: whether macOS exposes an `IOAVService` for this
    /// display (an external `DCPAVServiceProxy`). True means DDC writes have a service to target;
    /// false means none exists — built-in HDMI, DisplayLink, and some docks/KVMs don't expose
    /// one. This only walks the IORegistry (the same resolution a write would do, so it also
    /// warms the cache); it sends nothing to the monitor.
    func hasService(for display: DisplayInfo) -> Bool {
        guard !display.isBuiltIn else {
            return false
        }
        return Arm64DDCServiceCache.shared.service(for: display.id, resolveRanked: {
            Self.avServicesRanked(for: display.id)
        }) != nil
    }

    func setVCPFeature(_ feature: UInt8, value: Int, display: DisplayInfo) throws {
        guard !display.isBuiltIn else {
            throw Arm64DDCError.builtInDisplay
        }
        guard let service = Arm64DDCServiceCache.shared.service(for: display.id, resolveRanked: {
            Self.avServicesRanked(for: display.id)
        }) else {
            throw Arm64DDCError.noMatchingService
        }
        guard Self.write(service: service, feature: feature, value: value) else {
            // A stale cached service (e.g. the monitor was re-plugged) can fail the write;
            // drop just this display's entry so the next attempt re-resolves, without
            // forcing every other display to re-walk the IORegistry.
            Arm64DDCServiceCache.shared.invalidate(displayID: display.id)
            throw Arm64DDCError.writeFailed
        }
    }

    // MARK: - Candidate selection (pure, unit-tested)

    /// Pick the best-ranked candidate index (rankedIndices is best-first) that no other
    /// display has already taken, so identical monitors get distinct services. Falls back to
    /// the best-ranked index when all are taken (fewer services than displays).
    static func chooseCandidateIndex(rankedIndices: [Int], taken: Set<Int>) -> Int? {
        rankedIndices.first { !taken.contains($0) } ?? rankedIndices.first
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
        // No settle delay before the first attempt: with the service cached, the common
        // (success-on-first-try) path is now a single fast I2C write. Only back off
        // between retries, where a brief pause genuinely helps a busy bus recover.
        for attempt in 0..<5 {
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
    /// with the external `DCPAVServiceProxy` that follows it, then rank the resulting services
    /// for `displayID` by EDID product/serial match (via public CoreGraphics APIs), best
    /// first. Each entry keeps its stable discovery `index`; ties keep IORegistry order. The
    /// cache dedupes on that index so two identical monitors get distinct services instead of
    /// both taking candidate 0.
    private static func avServicesRanked(for displayID: CGDirectDisplayID) -> [(index: Int, service: CFTypeRef)] {
        let candidates = discoverCandidates()
        guard !candidates.isEmpty else {
            return []
        }

        let model = Int64(CGDisplayModelNumber(displayID))
        let serial = Int64(CGDisplaySerialNumber(displayID))

        return candidates
            .enumerated()
            .map { index, candidate -> (score: Int, index: Int, service: CFTypeRef) in
                var score = 0
                if serial != 0, candidate.serialNumber == serial {
                    score += 5
                }
                if model != 0, candidate.productID == model {
                    score += 3
                }
                return (score, index, candidate.service)
            }
            .sorted { first, second in
                first.score != second.score ? first.score > second.score : first.index < second.index
            }
            .map { (index: $0.index, service: $0.service) }
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
