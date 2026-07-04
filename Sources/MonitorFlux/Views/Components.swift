import AppKit
import SwiftUI

/// Schedule-phase accent colors, shared by the curve editor handles, the legend, and the
/// status icon so a phase looks the same everywhere. Sunset is a saturated "real" orange so
/// it reads as clearly distinct from the daytime yellow next to it.
extension Color {
    static let phaseDaytime = Color.yellow
    static let phaseSunset = Color(red: 1.0, green: 0.42, blue: 0.0)
    static let phaseBedtime = Color.indigo
}

/// Accent colors for the per-display brightness/contrast schedule charts. Deliberately distinct
/// from the warmth curve's blue→orange so each control reads as its own thing: a warm gold for
/// brightness (the sun motif) and a cool teal for contrast.
extension Color {
    static let scheduleBrightness = Color(red: 1.0, green: 0.78, blue: 0.28)
    static let scheduleContrast = Color(red: 0.36, green: 0.78, blue: 0.86)
}

/// The warmth motif's two poles, shared by the OSD glyph, the menu-bar icon, and the popup's
/// warm/cool slider ends so "warm" and "cool" look the same everywhere.
extension Color {
    static let warmAmber = Color(red: 1.0, green: 0.58, blue: 0.18)
    static let coolBlue = Color(red: 0.42, green: 0.64, blue: 1.0)

    /// Cool-blue ↔ warm-amber tint for a position on the warmth axis. `fraction` is 0 at the warm
    /// (low-Kelvin) end and 1 at the cool (high-Kelvin) end — the same convention the OSD/schedule use.
    static func warmth(for fraction: Double) -> Color {
        blend(warmAmber, coolBlue, fraction.clamped(to: 0...1))
    }

    /// Warm/cool tint for a specific color temperature within `range`.
    static func warmth(kelvin: Int, in range: ClosedRange<Int> = ControlRanges.kelvin) -> Color {
        let span = Double(range.upperBound - range.lowerBound)
        let fraction = span > 0 ? Double(kelvin - range.lowerBound) / span : 0.5
        return warmth(for: fraction)
    }

    private static func blend(_ a: Color, _ b: Color, _ t: Double) -> Color {
        guard let na = NSColor(a).usingColorSpace(.sRGB),
              let nb = NSColor(b).usingColorSpace(.sRGB) else { return a }
        return Color(
            red: Double(na.redComponent) + (Double(nb.redComponent) - Double(na.redComponent)) * t,
            green: Double(na.greenComponent) + (Double(nb.greenComponent) - Double(na.greenComponent)) * t,
            blue: Double(na.blueComponent) + (Double(nb.blueComponent) - Double(na.blueComponent)) * t
        )
    }
}

/// Plain-language explanations of the two control paths, surfaced via `InfoButton`.
enum HelpText {
    static let gamma = """
    Warms the screen by tinting its colors, not by changing the backlight. Only one color app \
    can do this at a time — turn off Night Shift or f.lux. Wired displays only.
    """

    static let airplayDimming = """
    Wireless displays can't be controlled directly, so they're dimmed with a dark overlay — \
    darker only, and no warmth, contrast, or volume.
    """

    static let ddc = """
    Controls an external monitor's own brightness, contrast, and volume over the video cable — \
    the same settings as its physical buttons. Support varies by monitor and cable.
    """

    static let backlight = """
    Sets the real backlight — the same level as the keyboard brightness keys and the menu-bar \
    slider. Works on the built-in and Apple displays.
    """

    static let dimmingMethod = """
    Automatic uses the monitor's own brightness first, then darkens the image in software once \
    it bottoms out. Monitor hardware uses only the monitor's control; Software dims the image only.
    """

    static let softwareDimming = """
    Darkens the image itself, so the screen can go below its hardware minimum without touching \
    the backlight. 100% is neutral; above 100% brightens a dim panel. Heavy use can cause slight banding.
    """

    static let builtInDimmingChoice = """
    Off, the Brightness slider drives the real backlight. On, it darkens the image in software \
    and leaves the backlight alone — steadier for eyes sensitive to backlight flicker at low levels.
    """

    static let schedule = """
    Brightness and contrast follow the same day–night times as Warmth: the daytime value by day, \
    easing to the night value at sunset and back at wake.
    """
}

/// Sizes a switch `Toggle` like a System Settings row. SwiftUI's default switch is one visual
/// notch larger than the one System Settings pairs with 13 pt labels, and its baseline floats
/// the label ~1 pt above the pill's center; the compact switch centers the label exactly
/// (both measured against System Settings pixels). Apply to every switch in the settings
/// window — the size steps with the window zoom alongside `settingsControlSize`.
private struct SettingsSwitch: ViewModifier {
    @EnvironmentObject private var store: AppStore

    func body(content: Content) -> some View {
        content
            .toggleStyle(.switch)
            .controlSize(store.preferences.settingsSwitchControlSize)
    }
}

extension View {
    /// Switch sized and centered like a System Settings row. See `SettingsSwitch`.
    func settingsSwitch() -> some View {
        modifier(SettingsSwitch())
    }
}

/// A System Settings-style push button that stays optically centered at every window zoom.
///
/// The native bordered bezel keeps its fixed-metric baseline placement while the window
/// zoom inflates the label font: at zoom step 5 the label rides ~2.5 pt above the bezel's
/// center (measured from rendered pixels: 10 px above the cap vs 14 px below the descenders
/// at 2x; at the default zoom the native bezel is fine). Drawing the same bezel in SwiftUI
/// makes the centering plain layout, so it can't drift with the font. Metrics match the
/// native regular bezel at 13 pt — 20 pt tall, ~9 pt label inset, 5 pt radius — and scale
/// with the zoom.
struct SettingsPushButtonStyle: ButtonStyle {
    @Environment(\.settingsZoomScale) private var zoomScale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let radius = 5 * zoomScale
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        configuration.label
            .padding(.horizontal, 9 * zoomScale)
            .frame(minHeight: (20 * zoomScale).rounded())
            .background(
                shape
                    .fill(Color(nsColor: .controlColor))
                    // The bezel's rim: dark mode has a faint light top edge, light mode a
                    // hairline outline (both visible in native captures).
                    .overlay(shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08), lineWidth: 0.5))
                    .overlay(shape.fill(Color.primary.opacity(configuration.isPressed ? 0.08 : 0)))
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.12), radius: 0.5, y: 0.5)
            )
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

extension View {
    /// Settings-window push button, centered at every zoom. See `SettingsPushButtonStyle`.
    func settingsPushButton() -> some View {
        buttonStyle(SettingsPushButtonStyle())
    }
}

/// A small ⓘ button that reveals a popover explainer. Assumes the reader doesn't know the jargon.
struct InfoButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).zoomFont(.headline)
                Text(message)
                    .zoomFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}

/// A continuous slider styled after MonitorControl: a rounded track, a white fill from the
/// left, the control's icon inside at the leading edge, and a circular knob. No tick marks —
/// except the optional handoff notch of a hybrid (hardware + software) brightness track.
struct MonitorSlider: View {
    let systemImage: String
    /// The control's name — spoken by VoiceOver and shown as the hover tooltip. Several
    /// tracks are icon-only (the popup's contrast/volume rows), so this is their only name.
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var isEnabled = true
    /// When set, a quiet 1 pt handoff tick at this track fraction; below it the fill dims to
    /// 55% white — the "image is being darkened now, not the backlight" look of the unified
    /// brightness track's software zone.
    var notchFraction: Double? = nil
    /// Spoken value override (e.g. "3400 K" for warmth). Defaults to the track percentage.
    var accessibilityValueText: String? = nil
    let onChange: (Double) -> Void

    @Environment(\.settingsZoomScale) private var zoomScale

    /// Track/knob size rides the window zoom (the environment default is 1.0, so the popup —
    /// which doesn't zoom — keeps the native 24 pt). Without this, a zoomed detail pane grew
    /// its text but left the slider a fixed small target.
    private var height: CGFloat {
        (24 * zoomScale).rounded()
    }

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return ((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }

    /// The thumb sits below the handoff notch — the software (image-dimming) zone.
    private var inSoftwareZone: Bool {
        notchFraction.map { fraction < $0 } ?? false
    }

    private var fillOpacity: Double {
        guard isEnabled else { return 0.4 }
        return inSoftwareZone ? 0.55 : 0.95
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knobX = max(0, (width - height) * fraction)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule()
                    .fill(Color.white.opacity(fillOpacity))
                    .frame(width: knobX + height)
                if let notch = notchFraction {
                    // Where the knob's center sits at the notch position — a segment-gap-like
                    // tick (quiet, not a second thumb). Dark over the white fill, light over
                    // the empty track.
                    Capsule()
                        .fill(fraction >= notch ? Color.black.opacity(0.28) : Color.white.opacity(0.45))
                        .frame(width: 1, height: 10)
                        .position(x: height / 2 + (width - height) * notch, y: height / 2)
                }
                Image(systemName: systemImage)
                    .zoomFont(size: 12, weight: .semibold)
                    .foregroundStyle(.black.opacity(0.6))
                    .padding(.leading, 8)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(.black.opacity(0.06)))
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
                    .frame(width: height, height: height)
                    .offset(x: knobX)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard isEnabled, width > 0 else { return }
                        let f = (drag.location.x / width).clamped(to: 0...1)
                        onChange(range.lowerBound + f * (range.upperBound - range.lowerBound))
                    }
            )
            .opacity(isEnabled ? 1 : 0.55)
        }
        .frame(height: height)
        .help(label)
        // The track is drawn shapes on a DragGesture — invisible to VoiceOver without an
        // explicit element. Expose it as an adjustable control (VO ↑/↓ steps 5% of the range;
        // setters round/clamp as they do for drags) so the popup and detail hero aren't
        // pointer-only.
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValueText ?? "\(Int((fraction * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = (range.upperBound - range.lowerBound) * 0.05
            switch direction {
            case .increment:
                onChange(min(range.upperBound, value + step))
            case .decrement:
                onChange(max(range.lowerBound, value - step))
            @unknown default:
                break
            }
        }
    }
}

/// The one inline warning treatment: yellow triangle, semibold title, secondary detail, and
/// optional link-style actions on a tinted card. Every in-window warning (Accessibility,
/// media-key bindings, gamma conflicts) renders through this so they all read the same.
struct WarningCard<Actions: View>: View {
    let title: String
    let message: String
    /// When set, shows a dismiss button in the top-right corner.
    var onClose: (() -> Void)? = nil
    var closeHelp: String = "Dismiss"
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .zoomFont(.callout)
                    .fontWeight(.semibold)
                Text(message)
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions
                    .buttonStyle(.link)
                    .zoomFont(.caption)
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(closeHelp)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.25)))
    }
}

/// Warns that gamma is a shared, single-owner resource: Night Shift and other color apps
/// will fight MonitorFlux. Links straight to the Displays settings pane.
struct GammaConflictBanner: View {
    /// Known gamma apps detected running — named as the likely cause. Empty falls back to the
    /// generic wording, since macOS keeps no record of which process actually wrote the table.
    var appNames: [String] = []
    /// Called when the user closes the banner. It won't reappear until a fresh conflict.
    var onClose: (() -> Void)?

    private var title: String {
        appNames.isEmpty
            ? "Another app is also warming your screen"
            : "\(Self.joined(appNames)) \(appNames.count == 1 ? "is" : "are") also adjusting your screen colors"
    }

    private var detail: String {
        guard !appNames.isEmpty else {
            return "MonitorFlux warms the display by editing its gamma tables, and something else (macOS Night Shift, f.lux, or a similar tool) is editing them too — so colors can flicker or look wrong. Turn off Night Shift and quit other color tools for correct results."
        }
        let them = appNames.count == 1 ? "it" : "them"
        return "\(Self.joined(appNames)) is editing the display's color (gamma) tables at the same time as MonitorFlux, so colors can flicker or look wrong. Quitting \(them) — or turning off macOS Night Shift if it's on — restores correct color."
    }

    /// Grammatical join: "f.lux", "f.lux and Lunar", "f.lux, Lunar, and MonitorControl".
    static func joined(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + (names.last ?? "")
        }
    }

    var body: some View {
        WarningCard(
            title: title,
            message: detail,
            onClose: onClose,
            closeHelp: "Dismiss. Reappears only if another app warms the screen again."
        ) {
            Button("Open Display Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
