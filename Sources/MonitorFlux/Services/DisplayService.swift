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
            return NSScreen.screens.compactMap { screen in
                let key = NSDeviceDescriptionKey("NSScreenNumber")
                guard let number = screen.deviceDescription[key] as? NSNumber else {
                    return nil
                }
                let displayID = CGDirectDisplayID(number.uint32Value)
                return makeDisplayInfo(id: displayID, name: screen.localizedName)
            }
        }

        if displayCount == maxDisplays {
            maxDisplays = displayCount + 8
            displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(maxDisplays))
            _ = CGGetOnlineDisplayList(maxDisplays, &displayIDs, &displayCount)
        }

        return displayIDs
            .prefix(Int(displayCount))
            .map { displayID in
                makeDisplayInfo(
                    id: displayID,
                    name: screenNames[displayID] ?? "Display \(displayID)"
                )
            }
            .sorted { first, second in
                if first.isBuiltIn != second.isBuiltIn {
                    return first.isBuiltIn
                }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    private func makeDisplayInfo(id: CGDirectDisplayID, name: String) -> DisplayInfo {
        let bounds = CGDisplayBounds(id)
        let size = "\(Int(bounds.width)) x \(Int(bounds.height))"
        let origin = "(\(Int(bounds.origin.x)), \(Int(bounds.origin.y)))"
        return DisplayInfo(
            id: id,
            name: name,
            frameDescription: "\(size) @ \(origin)",
            isBuiltIn: CGDisplayIsBuiltin(id) != 0,
            isOnline: CGDisplayIsOnline(id) != 0
        )
    }
}
