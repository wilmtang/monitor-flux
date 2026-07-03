import Foundation

enum AppInfo {
    /// The bundle's marketing version — shown in General and the Diagnostics report. Falls back
    /// to a dev marker when running unbundled (e.g. straight from `swift build`).
    static var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "dev (unbundled)"
    }
}
