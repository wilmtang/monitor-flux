import Foundation

enum PreferencesStore {
    private static let key = "MonitorFlux.preferences.v1"
    /// Where an undecodable blob is stashed so a save can't overwrite it (see `load`).
    private static let corruptKey = "MonitorFlux.preferences.v1.corrupt"

    static func load() -> AppPreferences {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return .defaults
        }

        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data).normalized()
        } catch {
            // Don't silently factory-reset: the next save would overwrite the original for good.
            // Stash the undecodable blob under a side key and log, so the user's settings can be
            // recovered (or the decode bug diagnosed) from a bug report.
            UserDefaults.standard.set(data, forKey: corruptKey)
            AppLog.prefs.error(
                "Preferences failed to decode; backed up under \(corruptKey, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return .defaults
        }
    }

    static func save(_ preferences: AppPreferences) {
        do {
            let data = try exportData(preferences)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            assertionFailure("Failed to encode preferences: \(error)")
        }
    }

    static func exportData(_ preferences: AppPreferences) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(preferences.normalized())
    }

    static func importData(_ data: Data) throws -> AppPreferences {
        try JSONDecoder().decode(AppPreferences.self, from: data).normalized()
    }
}
