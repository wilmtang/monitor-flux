import Carbon.HIToolbox
import Foundation

/// A user-assigned global keyboard shortcut: a virtual key code plus Carbon modifier flags
/// (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`), as `RegisterEventHotKey` wants them.
struct GlobalShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// A glyph string like "⌘⌥B" for display. Best-effort key naming; falls back to the code.
    var displayString: String {
        var result = ""
        if carbonModifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    /// The shortcut split into display tokens — each modifier glyph, then the key — for rendering
    /// as individual key-caps (e.g. ⌃⌥B → ["⌃", "⌥", "B"]). Same order as `displayString`.
    var displayTokens: [String] {
        var tokens: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { tokens.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { tokens.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { tokens.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { tokens.append("⌘") }
        tokens.append(Self.keyName(for: keyCode))
        return tokens
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let named = specialKeyNames[Int(keyCode)] {
            return named
        }
        return characterKeyNames[Int(keyCode)] ?? "key\(keyCode)"
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "␣", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let characterKeyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Grave: "`",
    ]
}

/// A media-key binding handled by `KeyboardControlService`, not Carbon.
struct MediaKeyShortcut: Codable, Hashable, Sendable {
    var keyCode: Int
    var control = false
    var shift = false
    var command = false
    /// ⌥ variants are how fine adjustments ride the same media keys (⌥ + a bound combo =
    /// small step). An ⌥ combo that isn't bound still passes through to macOS.
    var option = false

    var displayTokens: [String] {
        var tokens: [String] = []
        if control { tokens.append("⌃") }
        if option { tokens.append("⌥") }
        if shift { tokens.append("⇧") }
        if command { tokens.append("⌘") }
        switch keyCode {
        case MediaKey.brightnessUp:
            tokens.append("Brightness ↑")
        case MediaKey.brightnessDown:
            tokens.append("Brightness ↓")
        case MediaKey.soundUp:
            tokens.append("Volume ↑")
        case MediaKey.soundDown:
            tokens.append("Volume ↓")
        default:
            tokens.append("Media key")
        }
        return tokens
    }

    var displayString: String {
        displayTokens.joined(separator: " ")
    }

    func matches(keyCode: Int, control: Bool, shift: Bool, command: Bool, option: Bool) -> Bool {
        self.keyCode == keyCode
            && self.control == control
            && self.shift == shift
            && self.command == command
            && self.option == option
    }
}

extension MediaKeyShortcut {
    private enum CodingKeys: String, CodingKey {
        case keyCode
        case control
        case shift
        case command
        case option
    }

    /// Hand-written so shortcuts saved before `option` existed still decode (a synthesized
    /// decoder would throw on the missing key, and `decodeHotkeys` would then drop every
    /// custom binding by falling back to the legacy format).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(Int.self, forKey: .keyCode)
        control = try container.decodeIfPresent(Bool.self, forKey: .control) ?? false
        shift = try container.decodeIfPresent(Bool.self, forKey: .shift) ?? false
        command = try container.decodeIfPresent(Bool.self, forKey: .command) ?? false
        option = try container.decodeIfPresent(Bool.self, forKey: .option) ?? false
    }
}

/// A user-assigned shortcut binding: either a normal Carbon keyboard combo or a media-key
/// combo routed through the `CGEventTap`. Persisted in `AppPreferences.hotkeys`.
enum ShortcutBinding: Codable, Equatable, Sendable {
    case disabled
    case keyboard(GlobalShortcut)
    case media(MediaKeyShortcut)

    var asKeyboard: GlobalShortcut? {
        if case .keyboard(let shortcut) = self { return shortcut }
        return nil
    }

    var asMedia: MediaKeyShortcut? {
        if case .media(let shortcut) = self { return shortcut }
        return nil
    }

    var isDisabled: Bool {
        if case .disabled = self { return true }
        return false
    }

    /// Display tokens for rendering as key-caps, delegating to the wrapped variant.
    var displayTokens: [String] {
        switch self {
        case .disabled: []
        case .keyboard(let shortcut): shortcut.displayTokens
        case .media(let shortcut): shortcut.displayTokens
        }
    }
}

/// The two shortcut sets: one acting on the display under the pointer, one always on the
/// built-in panel. (If the pointer is on the built-in, both act on it — that's fine.)
enum HotKeyGroup: CaseIterable {
    case underPointer
    case builtIn

    var label: String {
        switch self {
        case .underPointer: "Display under pointer"
        case .builtIn: "Built-in display"
        }
    }

    var footnote: String {
        switch self {
        case .underPointer:
            "Brightness/contrast act on the external monitor under your pointer; color is global. Volume keys stay with macOS unless you record them here."
        case .builtIn:
            "Always act on the built-in panel's real backlight brightness. The built-in panel has no contrast control."
        }
    }
}

/// The controls a custom hotkey can drive. Each carries a fixed Carbon hot-key id so a press
/// can be routed back to the right action.
enum HotKeyAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case brightnessUp
    case brightnessDown
    case contrastUp
    case contrastDown
    case colorWarmer
    case colorCooler
    case volumeUp
    case volumeDown
    // Built-in-display set (brightness only — the panel has no contrast control). Appended so the
    // other actions keep their `hotKeyID`s, and thus their saved shortcuts.
    case builtInBrightnessUp
    case builtInBrightnessDown
    // Fine (small-step) variants, active only while "Fine adjustments" is on. Appended, like the
    // built-in set, so every earlier action keeps its `hotKeyID` and saved shortcut. Volume has no
    // fine variant: macOS itself already does fine system volume with ⌥⇧.
    case brightnessUpFine
    case brightnessDownFine
    case contrastUpFine
    case contrastDownFine
    case colorWarmerFine
    case colorCoolerFine
    case builtInBrightnessUpFine
    case builtInBrightnessDownFine

    var id: String { rawValue }

    /// True for the small-step variants that only exist while "Fine adjustments" is enabled.
    var isFine: Bool {
        baseAction != self
    }

    /// The coarse action a fine variant is the small-step version of; `self` for base actions.
    var baseAction: HotKeyAction {
        switch self {
        case .brightnessUpFine: .brightnessUp
        case .brightnessDownFine: .brightnessDown
        case .contrastUpFine: .contrastUp
        case .contrastDownFine: .contrastDown
        case .colorWarmerFine: .colorWarmer
        case .colorCoolerFine: .colorCooler
        case .builtInBrightnessUpFine: .builtInBrightnessUp
        case .builtInBrightnessDownFine: .builtInBrightnessDown
        default: self
        }
    }

    /// Which set this action belongs to — drives the Settings grouping and the target it acts on.
    var group: HotKeyGroup {
        switch baseAction {
        case .builtInBrightnessUp, .builtInBrightnessDown:
            .builtIn
        default:
            .underPointer
        }
    }

    var label: String {
        if isFine {
            return baseAction.label + " (fine)"
        }
        switch self {
        case .brightnessUp, .builtInBrightnessUp: return "Brightness up"
        case .brightnessDown, .builtInBrightnessDown: return "Brightness down"
        case .contrastUp: return "Contrast up"
        case .contrastDown: return "Contrast down"
        // "Warmth", not "Color": every other surface (popup card, Schedule pane, key hints)
        // calls this control Warmth, so the shortcut rows use the same word.
        case .colorWarmer: return "Warmth warmer"
        case .colorCooler: return "Warmth cooler"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        default: return baseAction.label
        }
    }

    /// SF Symbol shown beside the action in Settings.
    var icon: String {
        switch baseAction {
        case .brightnessUp, .builtInBrightnessUp: "sun.max.fill"
        case .brightnessDown, .builtInBrightnessDown: "sun.min"
        case .contrastUp: "circle.righthalf.filled"
        case .contrastDown: "circle.lefthalf.filled"
        case .colorWarmer: "thermometer.sun.fill"
        case .colorCooler: "thermometer.snowflake"
        case .volumeUp: "speaker.wave.3.fill"
        case .volumeDown: "speaker.wave.1.fill"
        default: "keyboard"
        }
    }

    /// Suggested normal-key combo for people who want a Carbon shortcut instead of a media key.
    /// It is not the factory default; rows with `mediaShortcut` reset to that media binding.
    var suggestedKeyboardShortcut: GlobalShortcut {
        // Under-pointer set is ⌃⌥-based; built-in set is ⌘⌥-based, so suggestions do not collide.
        // Fine variants add one more modifier (⌘, or ⇧ for the already-⌘⌥ built-in set) so they
        // stay adjacent to their base combo without colliding with it.
        let controlOption = UInt32(controlKey | optionKey)
        let controlOptionShift = UInt32(controlKey | optionKey | shiftKey)
        let commandOption = UInt32(cmdKey | optionKey)
        let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)
        let controlOptionShiftCommand = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let commandOptionShift = UInt32(cmdKey | optionKey | shiftKey)
        switch self {
        case .brightnessUp: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_RightBracket), carbonModifiers: controlOption)
        case .brightnessDown: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: controlOption)
        case .contrastUp: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_RightBracket), carbonModifiers: controlOptionShift)
        case .contrastDown: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: controlOptionShift)
        case .colorWarmer: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_Semicolon), carbonModifiers: controlOption)
        case .colorCooler: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_Quote), carbonModifiers: controlOption)
        case .volumeUp: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_Equal), carbonModifiers: controlOption)
        case .volumeDown: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_Minus), carbonModifiers: controlOption)
        case .builtInBrightnessUp: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_RightBracket), carbonModifiers: commandOption)
        case .builtInBrightnessDown: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: commandOption)
        case .brightnessUpFine: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_RightBracket), carbonModifiers: controlOptionCommand)
        case .brightnessDownFine: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: controlOptionCommand)
        case .contrastUpFine: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_RightBracket), carbonModifiers: controlOptionShiftCommand)
        case .contrastDownFine: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: controlOptionShiftCommand)
        case .colorWarmerFine: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_Semicolon), carbonModifiers: controlOptionCommand)
        case .colorCoolerFine: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_Quote), carbonModifiers: controlOptionCommand)
        case .builtInBrightnessUpFine: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_RightBracket), carbonModifiers: commandOptionShift)
        case .builtInBrightnessDownFine: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: commandOptionShift)
        }
    }

    /// Built-in media-key path, when one already exists for this action. This is separate
    /// from the optional custom Carbon shortcut: media keys are `NSSystemDefined` events,
    /// not globally registered Carbon key combos. A fine variant's default is its base
    /// combo plus ⌥ — mirroring how ⌥⇧ turns the Mac's own brightness keys into small steps.
    var mediaShortcut: MediaKeyShortcut? {
        switch self {
        case .brightnessUp:
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp)
        case .brightnessDown:
            MediaKeyShortcut(keyCode: MediaKey.brightnessDown)
        case .contrastUp:
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, control: true)
        case .contrastDown:
            MediaKeyShortcut(keyCode: MediaKey.brightnessDown, control: true)
        case .colorWarmer:
            MediaKeyShortcut(keyCode: MediaKey.brightnessDown, shift: true)
        case .colorCooler:
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, shift: true)
        case .volumeUp, .volumeDown:
            nil
        case .builtInBrightnessUp:
            MediaKeyShortcut(keyCode: MediaKey.brightnessUp, command: true)
        case .builtInBrightnessDown:
            MediaKeyShortcut(keyCode: MediaKey.brightnessDown, command: true)
        case .brightnessUpFine, .brightnessDownFine, .contrastUpFine, .contrastDownFine,
             .colorWarmerFine, .colorCoolerFine, .builtInBrightnessUpFine, .builtInBrightnessDownFine:
            baseAction.mediaShortcut.map { base in
                var fine = base
                fine.option = true
                return fine
            }
        }
    }

    /// Stable per-action id passed to `RegisterEventHotKey` (1-based; 0 is avoided).
    var hotKeyID: UInt32 {
        UInt32((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }
}
