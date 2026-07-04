import SwiftUI

// Zoom-aware replacement for fixed text styles inside the settings window.
//
// The window zoom (⌘+/⌘-/⌘0) is semantic: ContentView scales the root default
// font from `fontSizeStep`, and body text follows it. Explicit text styles like
// `.font(.caption)` are absolute, and Dynamic Type is inert on macOS (measured —
// see docs/DESIGN.md), so they would stay small while everything else grows.
// `zoomFont` renders the same visual role at the current zoom.
//
// The scale rides the environment with a 1.0 default, so shared components used
// outside the settings window (menu-bar popup, onboarding) keep normal sizes.

private struct SettingsZoomScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var settingsZoomScale: CGFloat {
        get { self[SettingsZoomScaleKey.self] }
        set { self[SettingsZoomScaleKey.self] = newValue }
    }
}

/// Text roles with their macOS base point sizes (and inherent weight, for headline).
enum ZoomFontRole {
    case caption2, caption, footnote, callout, subheadline, body, headline, title3, title2, title

    var baseSize: CGFloat {
        switch self {
        case .caption2: 10
        // Deliberately 11, not SwiftUI's 10: `.caption` is this app's role for the
        // description text under controls, and System Settings pairs its 13 pt rows with
        // 11 pt descriptions (measured from its rendered pixels).
        case .caption: 11
        case .footnote: 10
        case .callout: 12
        case .subheadline: 11
        case .body: 13
        case .headline: 13
        case .title3: 15
        case .title2: 17
        case .title: 22
        }
    }

    var baseWeight: Font.Weight {
        self == .headline ? .semibold : .regular
    }
}

private struct ZoomFontModifier: ViewModifier {
    @Environment(\.settingsZoomScale) private var zoomScale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(
            size: (size * zoomScale * 2).rounded() / 2,
            weight: weight,
            design: design
        ))
    }
}

extension View {
    /// Zoom-aware `.font(.caption)` etc. — same role, scaled with the window zoom.
    func zoomFont(_ role: ZoomFontRole, weight: Font.Weight? = nil, design: Font.Design = .default) -> some View {
        modifier(ZoomFontModifier(size: role.baseSize, weight: weight ?? role.baseWeight, design: design))
    }

    /// Zoom-aware `.font(.system(size:weight:design:))`.
    func zoomFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(ZoomFontModifier(size: size, weight: weight, design: design))
    }
}
