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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .brightnessUp: "Brightness up"
        case .brightnessDown: "Brightness down"
        case .contrastUp: "Contrast up"
        case .contrastDown: "Contrast down"
        case .colorWarmer: "Color warmer"
        case .colorCooler: "Color cooler"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        }
    }

    /// SF Symbol shown beside the action in Settings.
    var icon: String {
        switch self {
        case .brightnessUp: "sun.max.fill"
        case .brightnessDown: "sun.min"
        case .contrastUp: "circle.righthalf.filled"
        case .contrastDown: "circle.lefthalf.filled"
        case .colorWarmer: "thermometer.sun.fill"
        case .colorCooler: "thermometer.snowflake"
        case .volumeUp: "speaker.wave.3.fill"
        case .volumeDown: "speaker.wave.1.fill"
        }
    }

    /// Suggested combo applied by "Reset to default". Shortcuts start unset (nothing is
    /// registered by default, so nothing can clash on first launch); this just gives each
    /// action a sensible ⌃⌥ binding to reset to. They can still conflict with another app —
    /// the recorder shows a ⚠️ if so.
    var defaultShortcut: GlobalShortcut {
        let controlOption = UInt32(controlKey | optionKey)
        let controlOptionShift = UInt32(controlKey | optionKey | shiftKey)
        switch self {
        case .brightnessUp: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_RightBracket), carbonModifiers: controlOption)
        case .brightnessDown: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: controlOption)
        case .contrastUp: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_RightBracket), carbonModifiers: controlOptionShift)
        case .contrastDown: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_LeftBracket), carbonModifiers: controlOptionShift)
        case .colorWarmer: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_Semicolon), carbonModifiers: controlOption)
        case .colorCooler: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_Quote), carbonModifiers: controlOption)
        case .volumeUp: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_Equal), carbonModifiers: controlOption)
        case .volumeDown: return GlobalShortcut(keyCode: UInt32(kVK_ANSI_Minus), carbonModifiers: controlOption)
        }
    }

    /// Stable per-action id passed to `RegisterEventHotKey` (1-based; 0 is avoided).
    var hotKeyID: UInt32 {
        UInt32((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }
}
