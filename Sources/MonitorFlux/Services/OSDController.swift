import AppKit
import CoreGraphics
import ObjectiveC
import SwiftUI

/// A MonitorControl/macOS-style on-screen display. Brightness, contrast, and volume use the
/// **real system bezel** via the private `OSDManager` (OSD.framework) — exactly what macOS
/// itself draws, so the overlay is pixel-identical to the native one (this is how MonitorControl
/// matches it). Color/warmth has no native bezel image, so it keeps a custom floating panel with
/// the app's cool→warm tint; that same panel is also the fallback if the private API is ever
/// unavailable.
@MainActor
final class OSDController {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    /// Where macOS puts its own bezel: OSDUIHelper's 200×200 window sits horizontally
    /// centered with its bottom edge exactly 140 pt above the screen's bottom edge
    /// (measured from its window frame on macOS 26 — not a fraction of the screen
    /// height). The custom panel uses the same rule so warmth/contrast flashes in
    /// precisely the spot the native brightness/volume bezel uses.
    private static let nativeBezelBottomGap: CGFloat = 140

    enum Kind {
        case brightness
        case contrast
        case volume
        case color

        func systemImage(fraction: Double) -> String {
            switch self {
            case .brightness: "sun.max"
            case .contrast: "circle.lefthalf.filled"
            case .volume:
                if fraction <= 0 { "speaker.slash.fill" }
                else if fraction < 0.34 { "speaker.wave.1.fill" }
                else if fraction < 0.67 { "speaker.wave.2.fill" }
                else { "speaker.wave.3.fill" }
            case .color: "thermometer.sun.fill"
            }
        }

        /// The native OSD.framework image code for this control, or `nil` to use the custom panel.
        /// Brightness and volume have real macOS bezels; contrast and color do not (macOS has no
        /// contrast or color-temperature bezel — the contrast code renders the level bar with no
        /// glyph), so they keep the custom panel, which draws a proper icon over the bar.
        var nativeImage: NativeOSD.Image? {
            switch self {
            case .brightness: .brightness
            case .volume: .speaker
            case .contrast, .color: nil
            }
        }
    }

    /// Flash the OSD for `kind` at `fraction` (0...1) on the display with `displayID`
    /// (falling back to the main screen). Re-showing resets the auto-hide timer.
    func show(_ kind: Kind, fraction: Double, onDisplay displayID: CGDirectDisplayID?) {
        let clampedFraction = fraction.clamped(to: 0...1)

        // Use the native system bezel for brightness/contrast/volume. The screenshot-capture
        // hook forces the custom panel (the native bezel can't be held on screen or captured by
        // window id), so UI verification still works.
        let wantsCapture = ProcessInfo.processInfo.environment["MONITORFLUX_OSD_HOLD"] == "1"
        if !wantsCapture, let nativeImage = kind.nativeImage {
            let id = displayID ?? CGMainDisplayID()
            let image: NativeOSD.Image = (kind == .volume && clampedFraction <= 0) ? .speakerMuted : nativeImage
            if NativeOSD.show(image, onDisplay: id, filled: Int((clampedFraction * 100).rounded()), total: 100) {
                // Native bezel shown; tear down any leftover custom panel so the two can't overlap.
                hideWorkItem?.cancel()
                panel?.orderOut(nil)
                return
            }
        }

        showCustomPanel(kind, fraction: clampedFraction, onDisplay: displayID)
    }

    /// The custom floating panel — used for color/warmth, the screenshot-capture hook, and as a
    /// fallback when the native bezel is unavailable.
    private func showCustomPanel(_ kind: Kind, fraction: Double, onDisplay displayID: CGDirectDisplayID?) {
        let panel = panel ?? makePanel()
        self.panel = panel

        let clampedFraction = fraction.clamped(to: 0...1)
        // Warmth keeps the app's cool→warm tint; brightness/contrast/volume stay white like
        // macOS's native overlays.
        let tint: Color = kind == .color ? .warmth(for: clampedFraction) : .white
        let view = OSDView(systemImage: kind.systemImage(fraction: clampedFraction), fraction: clampedFraction, tint: tint)
        (panel.contentView as? NSHostingView<OSDView>)?.rootView = view

        let screen = displayID.flatMap(Self.screen(for:)) ?? NSScreen.main
        if let screen {
            let size = panel.frame.size
            let origin = NSPoint(
                x: screen.frame.midX - size.width / 2,
                y: screen.frame.minY + Self.nativeBezelBottomGap
            )
            panel.setFrameOrigin(origin)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + (ProcessInfo.processInfo.environment["MONITORFLUX_OSD_HOLD"] == "1" ? 60 : 1.3), execute: item)
    }

    private func fadeOut() {
        guard let panel else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak panel] in
                panel?.orderOut(nil)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: OSDView(systemImage: "sun.max.fill", fraction: 0))
        return panel
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        }
    }

    /// 0...1 fill for segment `index` of a `segments`-segment level bar showing `fraction`:
    /// whole segments below the level read 1, the segment straddling the level fills
    /// proportionally, the rest read 0. Pulled out (and `nonisolated`) so the partial-fill
    /// behavior — every sub-segment step moves the bar — is unit-testable.
    nonisolated static func segmentFill(fraction: Double, index: Int, segments: Int) -> Double {
        (fraction * Double(segments) - Double(index)).clamped(to: 0...1)
    }
}

/// The OSD's content: a large glyph over a 16-segment level bar on a dark HUD panel, laid out
/// to match the macOS brightness/volume bezel **pixel-for-pixel** (measured from a screenshot
/// of OSDUIHelper's 200×200 window on macOS 15.7):
/// - glyph: thin-stroke, ~112 pt tall, centered at (100, 87), ~55%-white gray (not bright white)
/// - level bar: 159×6 pt whose *center* sits at (100, 176) — a continuous darker-than-panel
///   track under 9 pt lit chiclets with 1 pt gaps (the empty side is the bare track; the
///   native bezel draws no per-chiclet outlines there)
/// - no border ring around the panel
private struct OSDView: View {
    let systemImage: String
    let fraction: Double
    var tint: Color = .white

    private let segments = 16
    private let segmentWidth: CGFloat = 9
    private let segmentSpacing: CGFloat = 1
    private let barHeight: CGFloat = 6
    private var barWidth: CGFloat {
        CGFloat(segments) * segmentWidth + CGFloat(segments - 1) * segmentSpacing // 159
    }
    /// The native glyph/chiclet gray over the dark blur reads as ~55% white; the HUD
    /// vibrancy brightens marks a touch, so 0.50 lands on the native gray in a screenshot.
    private let markOpacity = 0.50

    /// 0...1 fill for the segment at `index`: whole segments below the level read 1, the one
    /// segment straddling the level fills proportionally, the rest read 0. That partial
    /// boundary segment is what makes a sub-segment step — warmth's 200 K is ~0.6 of a
    /// segment — visibly nudge the bar on every keypress, instead of stalling between ticks
    /// the way integer (rounded) segment counts did. (The native bezel does the same for its
    /// quarter-step ⌥⇧ presses.)
    private func fillAmount(at index: Int) -> Double {
        OSDController.segmentFill(fraction: fraction, index: index, segments: segments)
    }

    var body: some View {
        ZStack {
            Image(systemName: systemImage)
                .font(.system(size: 106, weight: .regular))
                .foregroundStyle(tint.opacity(markOpacity))
                .position(x: 100, y: 87)

            levelBar
                .position(x: 100, y: 176)
        }
        .frame(width: 200, height: 200)
        .background(
            OSDVisualEffectBackground()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .environment(\.colorScheme, .dark)
    }

    private var levelBar: some View {
        ZStack(alignment: .leading) {
            // The recessed track: slightly darker than the panel, one continuous strip.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.black.opacity(0.27))
            HStack(spacing: segmentSpacing) {
                ForEach(0..<segments, id: \.self) { index in
                    ZStack(alignment: .leading) {
                        Color.clear
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(tint.opacity(markOpacity))
                            .frame(width: segmentWidth * fillAmount(at: index))
                    }
                    .frame(width: segmentWidth, height: barHeight)
                }
            }
        }
        .frame(width: barWidth, height: barHeight)
    }
}

/// The system OSD's frosted backing: an always-dark HUD vibrancy view, so the overlay looks the
/// same as macOS's own regardless of the user's light/dark appearance.
private struct OSDVisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
