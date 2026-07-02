import Foundation

enum PreferencesStore {
    private static let key = "MonitorFlux.preferences.v1"

    static func load() -> AppPreferences {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return .defaults
        }

        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data).normalized()
        } catch {
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
