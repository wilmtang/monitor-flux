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
            "Fixed"
        case .clock:
            "Automatic"
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
            "Set times"
        case .solar:
            "Sunrise & sunset"
        }
    }
}

/// How a display's unified Brightness control dims it. `.automatic` drives the hardware
/// backlight first (DDC, or the built-in backlight) and continues in software below the
/// hardware minimum; `.hardware` uses only the real backlight; `.software` darkens the image
/// via the color tables and leaves the hardware alone.
///
/// Stored optionally: `nil` means "unset", resolved per display kind by
/// `AppStore.dimmingMode(for:)` — externals default to `.automatic` (hybrid), the built-in
/// panel to `.hardware` (its hybrid slider stays an explicit opt-in).
enum DimmingMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case hardware
    case software

    var id: String { rawValue }

    /// De-jargon UI label — DDC/gamma live only in the ⓘ tooltip.
    var label: String {
        switch self {
        case .automatic:
            "Automatic"
        case .hardware:
            "Monitor hardware"
        case .software:
            "Software dimming"
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
    /// How the unified Brightness control dims this display; nil = per-display-kind default
    /// (see `DimmingMode`). Replaces the old `gammaControlsEnabled` gate: the software
    /// brightness *value* now always applies, and the mode only routes the unified control.
    var dimmingMode: DimmingMode?
    /// Lets the unified Brightness control reach complete black (software floor 0 instead of
    /// the 15% safety floor). Opt-in from Advanced; brightness-up keys still recover.
    var dimToBlack = false
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
    var sunsetBrightness = 65
    var nightBrightness = 40
    var dayContrast = 75
    var sunsetContrast = 70
    var nightContrast = 65

    enum CodingKeys: String, CodingKey {
        case colorEnabled
        case dimmingMode
        case dimToBlack
        /// Legacy (pre-dimming-mode) software-dimming opt-in gate; decoded for one release
        /// to seed `dimmingMode`, never encoded.
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
        case sunsetBrightness
        case nightBrightness
        case dayContrast
        case sunsetContrast
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
        copy.sunsetBrightness = copy.sunsetBrightness.clamped(to: ControlRanges.hardwarePercent)
        copy.nightBrightness = copy.nightBrightness.clamped(to: ControlRanges.hardwarePercent)
        copy.dayContrast = copy.dayContrast.clamped(to: ControlRanges.hardwarePercent)
        copy.sunsetContrast = copy.sunsetContrast.clamped(to: ControlRanges.hardwarePercent)
        copy.nightContrast = copy.nightContrast.clamped(to: ControlRanges.hardwarePercent)
        return copy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorEnabled = try container.decodeIfPresent(Bool.self, forKey: .colorEnabled) ?? true
        dimmingMode = try container.decodeIfPresent(DimmingMode.self, forKey: .dimmingMode)
        dimToBlack = try container.decodeIfPresent(Bool.self, forKey: .dimToBlack) ?? false
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
        sunsetBrightness = (try container.decodeIfPresent(Int.self, forKey: .sunsetBrightness) ?? 65)
            .clamped(to: ControlRanges.hardwarePercent)
        nightBrightness = (try container.decodeIfPresent(Int.self, forKey: .nightBrightness) ?? 40)
            .clamped(to: ControlRanges.hardwarePercent)
        dayContrast = (try container.decodeIfPresent(Int.self, forKey: .dayContrast) ?? 75)
            .clamped(to: ControlRanges.hardwarePercent)
        sunsetContrast = (try container.decodeIfPresent(Int.self, forKey: .sunsetContrast) ?? 70)
            .clamped(to: ControlRanges.hardwarePercent)
        nightContrast = (try container.decodeIfPresent(Int.self, forKey: .nightContrast) ?? 65)
            .clamped(to: ControlRanges.hardwarePercent)
        // Migrate the legacy `gammaControlsEnabled` gate (one release). An explicit `true`
        // (seeded on panels with no hardware path, or hand-enabled) becomes `.automatic`; an
        // explicit `false` leaves the mode unset — the per-display-kind default matches the
        // old behavior — and resets any stale software-brightness value, because the gate is
        // gone: a sub-100 value that was inert behind `false` must not start dimming on
        // upgrade. Absent (fresh installs, new payloads) seeds nothing.
        if dimmingMode == nil,
           let legacyGate = try container.decodeIfPresent(Bool.self, forKey: .gammaControlsEnabled) {
            if legacyGate {
                dimmingMode = .automatic
            } else if gammaBrightness < 100 {
                gammaBrightness = 100
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorEnabled, forKey: .colorEnabled)
        try container.encodeIfPresent(dimmingMode, forKey: .dimmingMode)
        try container.encode(dimToBlack, forKey: .dimToBlack)
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
        try container.encode(sunsetBrightness, forKey: .sunsetBrightness)
        try container.encode(nightBrightness, forKey: .nightBrightness)
        try container.encode(dayContrast, forKey: .dayContrast)
        try container.encode(sunsetContrast, forKey: .sunsetContrast)
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
    /// Master switch for the small-step (⌥) shortcut variants. Off by default: the fine
    /// shortcuts neither fire nor appear in Settings, and ⌥ + media keys stay with macOS.
    var fineAdjustmentsEnabled = false
    /// Whether the first-run onboarding has been shown. False on a fresh install; set true the
    /// first time the welcome sheet appears so it never pops again.
    var hasSeenOnboarding = false
    /// Show the developer-facing Diagnostics pane in the sidebar. Off by default (also reachable
    /// via ⌘⇧D); a toggle in General turns it on for people who want it.
    var showDiagnostics = false
    /// Settings-window text zoom (⌘+ / ⌘- / ⌘0). This drives SwiftUI semantic text sizing,
    /// not a post-layout scale transform, so hit testing stays aligned with the UI.
    var fontSizeStep = AppPreferences.defaultFontSizeStep
    var latitude = "47.6"
    var longitude = "-122.3"
    var displayPreferences: [String: DisplayPreferences] = [:]
    /// Shortcut overrides, keyed by `HotKeyAction.rawValue`. Missing key means use that
    /// action's media-key default, when it has one.
    var hotkeys: [String: ShortcutBinding] = [:]
    /// User-chosen order of the popup's display cards, by `DisplayInfo.key`. Keys not listed
    /// (newly connected displays) sort after the listed ones in detection order.
    var displayOrder: [String] = []

    static let defaults = AppPreferences()
    static let fontSizeStepRange = 0...8
    static let defaultFontSizeStep = 3

    /// Maps fontSizeStep to a window zoom scale factor (1.0 = default, VS Code-style).
    var settingsZoomScale: CGFloat {
        let scales: [CGFloat] = [0.70, 0.80, 0.90, 1.00, 1.10, 1.25, 1.50, 1.75, 2.00]
        return scales[fontSizeStep.clamped(to: Self.fontSizeStepRange)]
    }

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
        case fineAdjustmentsEnabled
        case hasSeenOnboarding
        case showDiagnostics
        case fontSizeStep
        case latitude
        case longitude
        case displayPreferences
        case hotkeys
        case displayOrder
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
        copy.fontSizeStep = copy.fontSizeStep.clamped(to: Self.fontSizeStepRange)
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
        fineAdjustmentsEnabled = try container.decodeIfPresent(Bool.self, forKey: .fineAdjustmentsEnabled) ?? false
        hasSeenOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasSeenOnboarding) ?? false
        showDiagnostics = try container.decodeIfPresent(Bool.self, forKey: .showDiagnostics) ?? false
        fontSizeStep = (try container.decodeIfPresent(Int.self, forKey: .fontSizeStep) ?? AppPreferences.defaultFontSizeStep)
            .clamped(to: AppPreferences.fontSizeStepRange)
        latitude = try container.decodeIfPresent(String.self, forKey: .latitude) ?? "47.6"
        longitude = try container.decodeIfPresent(String.self, forKey: .longitude) ?? "-122.3"
        displayPreferences = try container.decodeIfPresent(
            [String: DisplayPreferences].self,
            forKey: .displayPreferences
        )?.mapValues { $0.normalized() } ?? [:]
        hotkeys = try Self.decodeHotkeys(from: container) ?? [:]
        displayOrder = try container.decodeIfPresent([String].self, forKey: .displayOrder) ?? []
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
        try container.encode(fineAdjustmentsEnabled, forKey: .fineAdjustmentsEnabled)
        try container.encode(hasSeenOnboarding, forKey: .hasSeenOnboarding)
        try container.encode(showDiagnostics, forKey: .showDiagnostics)
        try container.encode(fontSizeStep, forKey: .fontSizeStep)
        try container.encode(latitude, forKey: .latitude)
        try container.encode(longitude, forKey: .longitude)
        try container.encode(displayPreferences, forKey: .displayPreferences)
        try container.encode(hotkeys, forKey: .hotkeys)
        try container.encode(displayOrder, forKey: .displayOrder)
    }

    /// Try the new `ShortcutBinding` format; fall back to legacy `GlobalShortcut` values
    /// and wrap them as `.keyboard(...)`. Returns nil when the key is absent.
    private static func decodeHotkeys(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> [String: ShortcutBinding]? {
        // New format: each value is a ShortcutBinding (tagged enum).
        if let bindings = try? container.decodeIfPresent(
            [String: ShortcutBinding].self,
            forKey: .hotkeys
        ) {
            return bindings
        }
        // Legacy format: each value is a bare GlobalShortcut. Wrap as .keyboard.
        guard let legacy = try container.decodeIfPresent(
            [String: GlobalShortcut].self,
            forKey: .hotkeys
        ) else {
            return nil
        }
        return legacy.mapValues { .keyboard($0) }
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
                    displayPreferences.gammaBrightness,
                    displayPreferences.gammaContrast,
                ]
            }
        )
    }

    /// True when MonitorFlux may currently be writing gamma tables: the Warmth master is on,
    /// or some display carries a non-neutral software brightness (software dimming is plain
    /// dimming, independent of the Warmth master). Gates gamma-conflict detection.
    var mayWriteGamma: Bool {
        gammaEnabled || displayPreferences.values.contains { $0.gammaBrightness != 100 }
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

    mutating func setStartMinutes(_ value: Int, for phase: ColorPhase) {
        switch phase {
        case .daytime:
            coolStartMinutes = value
        case .sunset:
            sunsetStartMinutes = value
        case .bedtime:
            warmStartMinutes = value
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
