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

/// Where the schedule's sunrise/sunset anchors come from.
enum ScheduleSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case manualTimes
    case solar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manualTimes:
            "Manual times"
        case .solar:
            "Sunrise & sunset"
        }
    }
}

/// The three f.lux-style schedule phases. Each has its own color temperature,
/// all sharing the same `ControlRanges.kelvin` min/max.
enum ColorPhase: String, CaseIterable, Identifiable, Sendable {
    case daytime
    case sunset
    case bedtime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daytime:
            "Daytime"
        case .sunset:
            "Sunset"
        case .bedtime:
            "Bedtime"
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

    func normalized() -> DisplayPreferences {
        var copy = self
        copy.ddcDisplayIndex = copy.ddcDisplayIndex.clamped(to: ControlRanges.ddcDisplayIndex)
        copy.hardwareBrightness = copy.hardwareBrightness.clamped(to: ControlRanges.hardwarePercent)
        copy.hardwareContrast = copy.hardwareContrast.clamped(to: ControlRanges.hardwarePercent)
        copy.gammaBrightness = copy.gammaBrightness.clamped(to: ControlRanges.gammaBrightnessPercent)
        copy.gammaContrast = copy.gammaContrast.clamped(to: ControlRanges.gammaContrastPercent)
        return copy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorEnabled = try container.decodeIfPresent(Bool.self, forKey: .colorEnabled) ?? true
        gammaControlsEnabled = try container.decodeIfPresent(Bool.self, forKey: .gammaControlsEnabled) ?? true
        ddcDisplayIndex = (try container.decodeIfPresent(Int.self, forKey: .ddcDisplayIndex) ?? 1)
            .clamped(to: ControlRanges.ddcDisplayIndex)
        hardwareBrightness = try container.decodeIfPresent(Int.self, forKey: .hardwareBrightness)
            ?? container.decodeIfPresent(Int.self, forKey: .brightness)
            ?? 50
        hardwareBrightness = hardwareBrightness.clamped(to: ControlRanges.hardwarePercent)
        hardwareContrast = try container.decodeIfPresent(Int.self, forKey: .hardwareContrast)
            ?? container.decodeIfPresent(Int.self, forKey: .contrast)
            ?? 70
        hardwareContrast = hardwareContrast.clamped(to: ControlRanges.hardwarePercent)
        gammaBrightness = (try container.decodeIfPresent(Int.self, forKey: .gammaBrightness) ?? 100)
            .clamped(to: ControlRanges.gammaBrightnessPercent)
        gammaContrast = (try container.decodeIfPresent(Int.self, forKey: .gammaContrast) ?? 100)
            .clamped(to: ControlRanges.gammaContrastPercent)
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
    var sunsetTemperature = 3400
    var nightTemperature = 2700
    var warmStartMinutes = 21 * 60
    var coolStartMinutes = 7 * 60
    var sunsetStartMinutes = 20 * 60
    var transitionMinutes = 45
    var scheduleSource: ScheduleSource = .manualTimes
    var startAtLogin = false
    var showInDock = false
    var latitude = "47.6"
    var longitude = "-122.3"
    var displayPreferences: [String: DisplayPreferences] = [:]

    static let defaults = AppPreferences()

    enum CodingKeys: String, CodingKey {
        case gammaEnabled
        case colorMode
        case manualTemperature
        case dayTemperature
        case sunsetTemperature
        case nightTemperature
        case warmStartMinutes
        case coolStartMinutes
        case sunsetStartMinutes
        case transitionMinutes
        case scheduleSource
        case startAtLogin
        case showInDock
        case latitude
        case longitude
        case displayPreferences
    }

    init() {}

    func normalized() -> AppPreferences {
        var copy = self
        copy.manualTemperature = copy.manualTemperature.clamped(to: ControlRanges.kelvin)
        copy.dayTemperature = copy.dayTemperature.clamped(to: ControlRanges.kelvin)
        copy.sunsetTemperature = copy.sunsetTemperature.clamped(to: ControlRanges.kelvin)
        copy.nightTemperature = copy.nightTemperature.clamped(to: ControlRanges.kelvin)
        copy.warmStartMinutes = copy.warmStartMinutes.clamped(to: ControlRanges.minuteOfDay)
        copy.coolStartMinutes = copy.coolStartMinutes.clamped(to: ControlRanges.minuteOfDay)
        copy.sunsetStartMinutes = copy.sunsetStartMinutes.clamped(to: ControlRanges.minuteOfDay)
        copy.transitionMinutes = copy.transitionMinutes.clamped(to: ControlRanges.transitionMinutes)
        copy.displayPreferences = copy.displayPreferences.mapValues { $0.normalized() }
        return copy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gammaEnabled = try container.decodeIfPresent(Bool.self, forKey: .gammaEnabled) ?? true
        colorMode = try container.decodeIfPresent(ColorMode.self, forKey: .colorMode) ?? .clock
        manualTemperature = (try container.decodeIfPresent(Int.self, forKey: .manualTemperature) ?? 4200)
            .clamped(to: ControlRanges.kelvin)
        dayTemperature = (try container.decodeIfPresent(Int.self, forKey: .dayTemperature) ?? 6500)
            .clamped(to: ControlRanges.kelvin)
        sunsetTemperature = (try container.decodeIfPresent(Int.self, forKey: .sunsetTemperature) ?? 3400)
            .clamped(to: ControlRanges.kelvin)
        nightTemperature = (try container.decodeIfPresent(Int.self, forKey: .nightTemperature) ?? 2700)
            .clamped(to: ControlRanges.kelvin)
        warmStartMinutes = (try container.decodeIfPresent(Int.self, forKey: .warmStartMinutes) ?? 21 * 60)
            .clamped(to: ControlRanges.minuteOfDay)
        coolStartMinutes = (try container.decodeIfPresent(Int.self, forKey: .coolStartMinutes) ?? 7 * 60)
            .clamped(to: ControlRanges.minuteOfDay)
        sunsetStartMinutes = (try container.decodeIfPresent(Int.self, forKey: .sunsetStartMinutes) ?? 20 * 60)
            .clamped(to: ControlRanges.minuteOfDay)
        transitionMinutes = (try container.decodeIfPresent(Int.self, forKey: .transitionMinutes) ?? 45)
            .clamped(to: ControlRanges.transitionMinutes)
        scheduleSource = try container.decodeIfPresent(ScheduleSource.self, forKey: .scheduleSource) ?? .manualTimes
        startAtLogin = try container.decodeIfPresent(Bool.self, forKey: .startAtLogin) ?? false
        showInDock = try container.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        latitude = try container.decodeIfPresent(String.self, forKey: .latitude) ?? "47.6"
        longitude = try container.decodeIfPresent(String.self, forKey: .longitude) ?? "-122.3"
        displayPreferences = try container.decodeIfPresent(
            [String: DisplayPreferences].self,
            forKey: .displayPreferences
        )?.mapValues { $0.normalized() } ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gammaEnabled, forKey: .gammaEnabled)
        try container.encode(colorMode, forKey: .colorMode)
        try container.encode(manualTemperature, forKey: .manualTemperature)
        try container.encode(dayTemperature, forKey: .dayTemperature)
        try container.encode(sunsetTemperature, forKey: .sunsetTemperature)
        try container.encode(nightTemperature, forKey: .nightTemperature)
        try container.encode(warmStartMinutes, forKey: .warmStartMinutes)
        try container.encode(coolStartMinutes, forKey: .coolStartMinutes)
        try container.encode(sunsetStartMinutes, forKey: .sunsetStartMinutes)
        try container.encode(transitionMinutes, forKey: .transitionMinutes)
        try container.encode(scheduleSource, forKey: .scheduleSource)
        try container.encode(startAtLogin, forKey: .startAtLogin)
        try container.encode(showInDock, forKey: .showInDock)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(displayPreferences, forKey: .displayPreferences)
    }
}

extension AppPreferences {
    /// The stored color temperature for a schedule phase.
    func temperature(for phase: ColorPhase) -> Int {
        switch phase {
        case .daytime:
            dayTemperature
        case .sunset:
            sunsetTemperature
        case .bedtime:
            nightTemperature
        }
    }

    /// The minute-of-day anchor at which a schedule phase begins.
    func startMinutes(for phase: ColorPhase) -> Int {
        switch phase {
        case .daytime:
            coolStartMinutes
        case .sunset:
            sunsetStartMinutes
        case .bedtime:
            warmStartMinutes
        }
    }

    mutating func setTemperature(_ value: Int, for phase: ColorPhase) {
        let clamped = value.clamped(to: ControlRanges.kelvin)
        switch phase {
        case .daytime:
            dayTemperature = clamped
        case .sunset:
            sunsetTemperature = clamped
        case .bedtime:
            nightTemperature = clamped
        }
    }
}
