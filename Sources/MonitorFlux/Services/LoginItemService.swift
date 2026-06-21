import Foundation
import ServiceManagement

enum LoginItemService {
    static func statusLabel() -> String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Enabled"
        case .notRegistered:
            return "Disabled"
        case .notFound:
            return "App bundle not found"
        case .requiresApproval:
            return "Requires approval"
        @unknown default:
            return "Unknown"
        }
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
