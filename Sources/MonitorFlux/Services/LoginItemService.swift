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
            // SMAppService can't register a login item for a build LaunchServices doesn't know
            // as an installed app (e.g. a dev build launched from the build folder).
            return "Not available — install the app first"
        case .requiresApproval:
            return "Requires approval in System Settings"
        @unknown default:
            return "Unknown"
        }
    }

    /// True when the login item can't be registered because the running app isn't an installed,
    /// LaunchServices-known bundle — i.e. a development build. Drives the explanatory caption.
    static func needsInstall() -> Bool {
        SMAppService.mainApp.status == .notFound
    }

    static func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
