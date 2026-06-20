import Foundation

enum ColorMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case off
    case manual
    case clock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:
            "Off"
        case .manual:
            "Manual"
        case .clock:
            "Schedule"
        }
    }
}

struct DisplayPreferences: Codable, Equatable, Sendable {
    var colorEnabled = true
    var gammaControlsEnabled = true
    var ddcDisplayIndex = 1
    var hardwareBrightness = 50
    var hardwareContrast = 70
    var gammaBrightness = 100
    var gammaContrast = 100

    enum CodingKeys: String, CodingKey {
        case colorEnabled
        case gammaControlsEnabled
        case ddcDisplayIndex
        case hardwareBrightness
        case hardwareContrast
        case gammaBrightness
        case gammaContrast
        case brightness
        case contrast
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorEnabled = try container.decodeIfPresent(Bool.self, forKey: .colorEnabled) ?? true
        gammaControlsEnabled = try container.decodeIfPresent(Bool.self, forKey: .gammaControlsEnabled) ?? true
        ddcDisplayIndex = try container.decodeIfPresent(Int.self, forKey: .ddcDisplayIndex) ?? 1
        hardwareBrightness = try container.decodeIfPresent(Int.self, forKey: .hardwareBrightness)
            ?? container.decodeIfPresent(Int.self, forKey: .brightness)
            ?? 50
        hardwareContrast = try container.decodeIfPresent(Int.self, forKey: .hardwareContrast)
            ?? container.decodeIfPresent(Int.self, forKey: .contrast)
            ?? 70
        gammaBrightness = try container.decodeIfPresent(Int.self, forKey: .gammaBrightness) ?? 100
        gammaContrast = try container.decodeIfPresent(Int.self, forKey: .gammaContrast) ?? 100
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorEnabled, forKey: .colorEnabled)
        try container.encode(gammaControlsEnabled, forKey: .gammaControlsEnabled)
        try container.encode(ddcDisplayIndex, forKey: .ddcDisplayIndex)
        try container.encode(hardwareBrightness, forKey: .hardwareBrightness)
        try container.encode(hardwareContrast, forKey: .hardwareContrast)
        try container.encode(gammaBrightness, forKey: .gammaBrightness)
        try container.encode(gammaContrast, forKey: .gammaContrast)
    }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var gammaEnabled = true
    var colorMode: ColorMode = .clock
    var manualTemperature = 4200
    var dayTemperature = 6500
    var nightTemperature = 3400
    var warmStartMinutes = 21 * 60
    var coolStartMinutes = 7 * 60
    var transitionMinutes = 45
    var startAtLogin = false
    var latitude = "47.6"
    var longitude = "-122.3"
    var displayPreferences: [String: DisplayPreferences] = [:]

    static let defaults = AppPreferences()

    enum CodingKeys: String, CodingKey {
        case gammaEnabled
        case colorMode
        case manualTemperature
        case dayTemperature
        case nightTemperature
        case warmStartMinutes
        case coolStartMinutes
        case transitionMinutes
        case startAtLogin
        case latitude
        case longitude
        case displayPreferences
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gammaEnabled = try container.decodeIfPresent(Bool.self, forKey: .gammaEnabled) ?? true
        colorMode = try container.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? .clock
        manualTemperature = try container.decodeIfPresent(Int.self, forKey: .manualTemperature) ?? 4200
        dayTemperature = try container.decodeIfPresent(Int.self, forKey: .dayTemperature) ?? 6500
        nightTemperature = try container.decodeIfPresent(Int.self, forKey: .nightTemperature) ?? 3400
        warmStartMinutes = try container.decodeIfPresent(Int.self, forKey: .warmStartMinutes) ?? 21 * 60
        coolStartMinutes = try container.decodeIfPresent(Int.self, forKey: .coolStartMinutes) ?? 7 * 60
        transitionMinutes = try container.decodeIfPresent(Int.self, forKey: .transitionMinutes) ?? 45
        startAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        latitude = try container.decodeIfPresent(String.self, forKey: .latitude) ?? "47.6"
        longitude = try container.decodeIfPresent(String.self, forKey: .longitude) ?? "-122.3"
        displayPreferences = try container.decodeIfPresent(
            [String: DisplayPreferences].self,
            forKey: .displayPreferences
        ) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gammaEnabled, forKey: .gammaEnabled)
        try container.encode(colorMode, forKey: .colorMode)
        try container.encode(manualTemperature, forKey: .manualTemperature)
        try container.encode(dayTemperature, forKey: .dayTemperature)
        try container.encode(nightTemperature, forKey: .nightTemperature)
        try container.encode(warmStartMinutes, forKey: .warmStartMinutes)
        try container.encode(coolStartMinutes, forKey: .coolStartMinutes)
        try container.encode(transitionMinutes, forKey: .transitionMinutes)
        try container.encode(startAtLogin, forKey: .startAtLogin)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(displayPreferences, forKey: .displayPreferences)
    }
}
