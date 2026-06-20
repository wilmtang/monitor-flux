import CoreGraphics
import Foundation

struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let frameDescription: String
    let isBuiltIn: Bool
    let isOnline: Bool

    var key: String {
        String(id)
    }

    var kindLabel: String {
        isBuiltIn ? "Built-in" : "External"
    }
}
