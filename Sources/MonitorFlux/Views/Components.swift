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
    “Gamma” is a software adjustment. MonitorFlux edits the color tables macOS uses to \
    render every pixel, which warms the color temperature and can dim brightness/contrast \
    on any wired display — including the built-in one. It does NOT change the monitor's real \
    backlight; it only changes the image the Mac sends out. Only one app should drive gamma \
    at a time, or they fight (see the color-conflict note). AirPlay and other wireless/virtual \
    displays ignore gamma entirely — those are dimmed with an overlay instead (see AirPlay dimming).
    """

    static let airplayDimming = """
    AirPlay and other wireless/virtual displays have no DDC controls and ignore the color-table \
    (gamma) adjustment, so MonitorFlux dims them a completely different way: it lays a translucent \
    black overlay over the screen and varies its opacity. That visibly dims everything on the \
    display — it isn't a backlight or color change — so it can only go darker than the display's \
    own setting, never brighter, and there's no warmth, contrast, or volume control for it.
    """

    static let ddc = """
    “DDC/CI” sends commands over the video cable to an external monitor's own firmware — the \
    same thing the monitor's physical buttons do. It changes the real backlight brightness, \
    contrast, and volume. It works on external displays only (not the built-in panel) and \
    depends on the monitor, cable, and port. On Apple Silicon this uses the private IOAVService.
    """

    static let backlight = """
    This sets the display's real backlight brightness through the private DisplayServices \
    framework — the same level the menu-bar brightness slider and the keyboard brightness keys \
    change. It works on the built-in panel and Apple displays.
    """

    static let schedule = """
    Scheduled brightness and contrast follow the same day–night timeline as the color \
    schedule: they hold the daytime target through the day, then ease to the night target \
    around sunset (and back at wake). Adjusting a slider by hand overrides the schedule until \
    the next phase change, so automation never fights you mid-task.
    """
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
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 320)
        }
    }
}

/// A continuous slider styled after MonitorControl: a rounded track, a white fill from the
/// left, the control's icon inside at the leading edge, and a circular knob. No tick marks.
struct MonitorSlider: View {
    let systemImage: String
    let value: Double
    let range: ClosedRange<Double>
    var isEnabled = true
    let onChange: (Double) -> Void

    private let height: CGFloat = 24

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return ((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let knobX = max(0, (width - height) * fraction)

            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14))
                Capsule()
                    .fill(Color.white.opacity(isEnabled ? 0.95 : 0.4))
                    .frame(width: knobX + height)
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
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
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Display Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.displays") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Dismiss. Reappears only if another app warms the screen again.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.25)))
    }
}
