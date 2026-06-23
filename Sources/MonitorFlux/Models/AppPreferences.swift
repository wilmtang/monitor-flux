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
    var hardwareVolume = 50
    var gammaBrightness = 100
    var gammaContrast = 100
    /// Force-show the DDC volume slider even when no audio output is detected for this
    /// display. Off by default: the slider is hidden unless the monitor reports speakers.
    var forceVolumeControl = false
    /// Per-display brightness/contrast scheduling: ride the day/night timeline from a
    /// daytime target to a night target. Off by default.
    var scheduleBrightness = false
    var scheduleContrast = false
    var dayBrightness = 90
    var nightBrightness = 40
    var dayContrast = 75
    var nightContrast = 65

    enum CodingKeys: String, CodingKey {
        case colorEnabled
        case gammaControlsEnabled
        case ddcDisplayIndex
        case hardwareBrightness
        case hardwareContrast
        case hardwareVolume
        case gammaBrightness
        case gammaContrast
        case forceVolumeControl
        case scheduleBrightness
        case scheduleContrast
        case dayBrightness
        case nightBrightness
        case dayContrast
        case nightContrast
        case brightness
        case contrast
    }

    init() {}

    func normalized() -> DisplayPreferences {
        var copy = self
        copy.ddcDisplayIndex = copy.ddcDisplayIndex.clamped(to: ControlRanges.ddcDisplayIndex)
        copy.hardwareBrightness = copy.hardwareBrightness.clamped(to: ControlRanges.hardwarePercent)
        copy.hardwareContrast = copy.hardwareContrast.clamped(to: ControlRanges.hardwarePercent)
        copy.hardwareVolume = copy.hardwareVolume.clamped(to: ControlRanges.hardwarePercent)
        copy.gammaBrightness = copy.gammaBrightness.clamped(to: ControlRanges.gammaBrightnessPercent)
        copy.gammaContrast = copy.gammaContrast.clamped(to: ControlRanges.gammaContrastPercent)
        copy.dayBrightness = copy.dayBrightness.clamped(to: ControlRanges.hardwarePercent)
        copy.nightBrightness = copy.nightBrightness.clamped(to: ControlRanges.hardwarePercent)
        copy.dayContrast = copy.dayContrast.clamped(to: ControlRanges.hardwarePercent)
        copy.nightContrast = copy.nightContrast.clamped(to: ControlRanges.hardwarePercent)
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
        hardwareVolume = (try container.decodeIfPresent(Int.self, forKey: .hardwareVolume) ?? 50)
            .clamped(to: ControlRanges.hardwarePercent)
        gammaBrightness = (try container.decodeIfPresent(Int.self, forKey: .gammaBrightness) ?? 100)
            .clamped(to: ControlRanges.gammaBrightnessPercent)
        gammaContrast = (try container.decodeIfPresent(Int.self, forKey: .gammaContrast) ?? 100)
            .clamped(to: ControlRanges.gammaContrastPercent)
        forceVolumeControl = try container.decodeIfPresent(Bool.self, forKey: .forceVolumeControl) ?? false
        scheduleBrightness = try container.decodeIfPresent(Bool.self, forKey: .scheduleBrightness) ?? false
        scheduleContrast = try container.decodeIfPresent(Bool.self, forKey: .scheduleContrast) ?? false
        dayBrightness = (try container.decodeIfPresent(Int.self, forKey: .dayBrightness) ?? 90)
            .clamped(to: ControlRanges.hardwarePercent)
        nightBrightness = (try container.decodeIfPresent(Int.self, forKey: .nightBrightness) ?? 40)
            .clamped(to: ControlRanges.hardwarePercent)
        dayContrast = (try container.decodeIfPresent(Int.self, forKey: .dayContrast) ?? 75)
            .clamped(to: ControlRanges.hardwarePercent)
        nightContrast = (try container.decodeIfPresent(Int.self, forKey: .nightContrast) ?? 65)
            .clamped(to: ControlRanges.hardwarePercent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorEnabled, forKey: .colorEnabled)
        try container.encode(gammaControlsEnabled, forKey: .gammaControlsEnabled)
        try container.encode(ddcDisplayIndex, forKey: .ddcDisplayIndex)
        try container.encode(hardwareBrightness, forKey: .hardwareBrightness)
        try container.encode(hardwareContrast, forKey: .hardwareContrast)
        try container.encode(hardwareVolume, forKey: .hardwareVolume)
        try container.encode(gammaBrightness, forKey: .gammaBrightness)
        try container.encode(gammaContrast, forKey: .gammaContrast)
        try container.encode(forceVolumeControl, forKey: .forceVolumeControl)
        try container.encode(scheduleBrightness, forKey: .scheduleBrightness)
        try container.encode(scheduleContrast, forKey: .scheduleContrast)
        try container.encode(dayBrightness, forKey: .dayBrightness)
        try container.encode(nightBrightness, forKey: .nightBrightness)
        try container.encode(dayContrast, forKey: .dayContrast)
        try container.encode(nightContrast, forKey: .nightContrast)
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
    var keyboardControlEnabled = false
    /// Whether the first-run onboarding has been shown. False on a fresh install; set true the
    /// first time the welcome sheet appears so it never pops again.
    var hasSeenOnboarding = false
    /// Show the developer-facing Diagnostics pane in the sidebar. Off by default (also reachable
    /// via ⌘⇧D); a toggle in General turns it on for people who want it.
    var showDiagnostics = false
    var latitude = "47.6"
    var longitude = "-122.3"
    var displayPreferences: [String: DisplayPreferences] = [:]
    /// User-assigned global shortcuts, keyed by `HotKeyAction.rawValue`. Empty by default —
    /// the media keys cover brightness/contrast/color/volume out of the box.
    var hotkeys: [String: GlobalShortcut] = [:]

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
        case keyboardControlEnabled
        case hasSeenOnboarding
        case showDiagnostics
        case latitude
        case longitude
        case displayPreferences
        case hotkeys
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
        keyboardControlEnabled = try container.decodeIfPresent(Bool.self, forKey: .keyboardControlEnabled) ?? false
        hasSeenOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? false
        showDiagnostics = try container.decodeIfPresent(Bool.self, forKey: .showDiagnostics) ?? false
        latitude = try container.decodeIfPresent(String.self, forKey: .latitude) ?? "47.6"
        longitude = try container.decodeIfPresent(String.self, forKey: .longitude) ?? "-122.3"
        displayPreferences = try container.decodeIfPresent(
            [String: DisplayPreferences].self,
            forKey: .displayPreferences
        )?.mapValues { $0.normalized() } ?? [:]
        hotkeys = try container.decodeIfPresent([String: GlobalShortcut].self, forKey: .hotkeys) ?? [:]
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
        try container.encode(keyboardControlEnabled, forKey: .keyboardControlEnabled)
        try container.encode(hasSeenOnboarding, forKey: .hasSeenOnboarding)
        try container.encode(showDiagnostics, forKey: .showDiagnostics)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(displayPreferences, forKey: .displayPreferences)
        try container.encode(hotkeys, forKey: .hotkeys)
    }
}

extension AppPreferences {
    /// The subset of state that changes the gamma/color output. Mutating only DDC or
    /// native-backlight values (a brightness/contrast/volume drag) leaves this unchanged,
    /// so the relatively expensive main-thread gamma recompute can be skipped — that's
    /// what keeps a hardware drag smooth. Time-of-day is excluded on purpose: the 60s
    /// timer drives clock-based temperature changes, not preference mutations.
    struct ColorSignature: Equatable {
        var gammaEnabled: Bool
        var colorMode: ColorMode
        var manualTemperature: Int
        var dayTemperature: Int
        var sunsetTemperature: Int
        var nightTemperature: Int
        var warmStartMinutes: Int
        var coolStartMinutes: Int
        var sunsetStartMinutes: Int
        var transitionMinutes: Int
        var scheduleSource: ScheduleSource
        var latitude: String
        var longitude: String
        /// Per display: the gamma-affecting fields, keyed by display key.
        var perDisplay: [String: [Int]]
    }

    var colorSignature: ColorSignature {
        ColorSignature(
            gammaEnabled: gammaEnabled,
            colorMode: colorMode,
            manualTemperature: manualTemperature,
            dayTemperature: dayTemperature,
            sunsetTemperature: sunsetTemperature,
            nightTemperature: nightTemperature,
            warmStartMinutes: warmStartMinutes,
            coolStartMinutes: coolStartMinutes,
            sunsetStartMinutes: sunsetStartMinutes,
            transitionMinutes: transitionMinutes,
            scheduleSource: scheduleSource,
            latitude: latitude,
            longitude: longitude,
            perDisplay: displayPreferences.mapValues { displayPreferences in
                [
                    displayPreferences.colorEnabled ? 1 : 0,
                    displayPreferences.gammaControlsEnabled ? 1 : 0,
                    displayPreferences.gammaBrightness,
                    displayPreferences.gammaContrast,
                ]
            }
        )
    }

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
