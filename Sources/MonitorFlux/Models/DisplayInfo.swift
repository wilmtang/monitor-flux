import CoreGraphics
import Foundation

struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    /// Stable identity used to key preferences — survives reconnects/reboots, unlike `id`.
    /// See `DisplayIdentity`.
    let persistentID: String
    let frameDescription: String
    let isBuiltIn: Bool
    let isOnline: Bool

    init(
        id: CGDirectDisplayID,
        name: String,
        persistentID: String? = nil,
        frameDescription: String,
        isBuiltIn: Bool,
        isOnline: Bool
    ) {
        self.id = id
        self.name = name
        // Default keeps older call sites/tests working: a display with no resolved EDID
        // identity falls back to the same `display-<id>` form `DisplayIdentity` uses.
        self.persistentID = persistentID ?? "display-\(id)"
        self.frameDescription = frameDescription
        self.isBuiltIn = isBuiltIn
        self.isOnline = isOnline
    }

    /// The preferences key for this display. Stable across reconnects (see `persistentID`).
    var key: String {
        persistentID
    }

    var kindLabel: String {
        isBuiltIn ? "Built-in" : "External"
    }
}
