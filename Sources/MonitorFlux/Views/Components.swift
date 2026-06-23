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

/// Plain-language explanations of the two control paths, surfaced via `InfoButton`.
enum HelpText {
    static let gamma = """
    “Gamma” is a software adjustment. MonitorFlux edits the color tables macOS uses to \
    render every pixel, which warms the color temperature and can dim brightness/contrast \
    on any display — including the built-in one. It does NOT change the monitor's real \
    backlight; it only changes the image the Mac sends out. Only one app should drive gamma \
    at a time, or they fight (see the color-conflict note).
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
    /// Called when the user closes the banner. It won't reappear until a fresh conflict.
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 5) {
                Text("Another app is also warming your screen")
                    .font(.callout)
                    .fontWeight(.semibold)
                Text("MonitorFlux warms the display by editing its gamma tables, and something else (macOS Night Shift, f.lux, or a similar tool) is editing them too — so colors can flicker or look wrong. Turn off Night Shift and quit other color tools for correct results.")
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
