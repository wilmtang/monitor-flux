import AppKit
import CoreGraphics
import Foundation

final class DisplayService {
    func listDisplays() -> [DisplayInfo] {
        var screenNames: [CGDirectDisplayID: String] = [:]

        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                continue
            }
            screenNames[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
        }

        var maxDisplays: UInt32 = 16
        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        let error = CGGetOnlineDisplayList(maxDisplays, &displayIDs, &displayCount)

        guard error == .success else {
            let fallbackIDs = NSScreen.screens.compactMap { screen -> CGDirectDisplayID? in
                let key = NSDeviceDescriptionKey("NSScreenNumber")
                guard let number = screen.deviceDescription[key] as? NSNumber else {
                    return nil
                }
                return CGDirectDisplayID(number.uint32Value)
            }
            return makeDisplayInfos(ids: fallbackIDs, names: screenNames)
        }

        if displayCount == maxDisplays {
            maxDisplays = displayCount + 8
            displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(maxDisplays))
            _ = CGGetOnlineDisplayList(maxDisplays, &displayIDs, &displayCount)
        }

        return makeDisplayInfos(ids: Array(displayIDs.prefix(Int(displayCount))), names: screenNames)
    }

    /// Build `DisplayInfo`s with stable EDID-based keys. Keys are assigned across the whole
    /// set at once so identical monitors (which share an EDID identity) can be disambiguated.
    private func makeDisplayInfos(
        ids: [CGDirectDisplayID],
        names: [CGDirectDisplayID: String]
    ) -> [DisplayInfo] {
        let sources = ids.map { id in
            DisplayIdentity.Source(
                vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id),
                displayID: id
            )
        }
        let keys = DisplayIdentity.keys(for: sources)

        return zip(ids, keys)
            .map { id, persistentID in
                makeDisplayInfo(
                    id: id,
                    name: names[id] ?? "Display \(id)",
                    persistentID: persistentID
                )
            }
            .sorted { first, second in
                if first.isBuiltIn != second.isBuiltIn {
                    return first.isBuiltIn
                }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    private func makeDisplayInfo(
        id: CGDirectDisplayID,
        name: String,
        persistentID: String
    ) -> DisplayInfo {
        let bounds = CGDisplayBounds(id)
        // User-facing resolution ("3440 × 1440", like System Settings) — the frame origin is
        // developer detail that read as noise next to it.
        let size = "\(Int(bounds.width)) × \(Int(bounds.height))"
        // `CGDisplayMirrorsDisplay` returns the mirror master, or `kCGNullDirectDisplay` (0) when
        // this display isn't mirroring another — map that to nil so `effectiveID` falls back to self.
        let mirrored = CGDisplayMirrorsDisplay(id)
        return DisplayInfo(
            id: id,
            name: name,
            persistentID: persistentID,
            frameDescription: size,
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            isOnline: CGDisplayIsOnline(id) != 0,
            isVirtual: CoreDisplayInfo.isVirtual(id),
            mirrorMaster: mirrored == 0 ? nil : mirrored
        )
    }
}
