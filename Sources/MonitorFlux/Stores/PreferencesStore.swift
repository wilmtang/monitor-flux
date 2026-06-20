import Foundation

enum PreferencesStore {
    private static let key = "MonitorFlux.preferences.v1"

    static func load() -> AppPreferences {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return .defaults
        }

        do {
            return try JSONDecoder().decode(AppPreferences.self, from: data)
        } catch {
            return .defaults
        }
    }

    static func save(_ preferences: AppPreferences) {
        do {
            let data = try JSONEncoder().encode(preferences)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            assertionFailure("Failed to encode preferences: \(error)")
        }
    }
}
