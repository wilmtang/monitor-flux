import AppKit
import CoreGraphics
import SwiftUI

/// A MonitorControl/macOS-style on-screen display: a floating, non-activating panel that
/// flashes an icon + level bar on the relevant display when a control changes by keyboard,
/// then fades out. Non-activating so it never steals focus.
@MainActor
final class OSDController {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

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
    }

    /// Flash the OSD for `kind` at `fraction` (0...1) on the display with `displayID`
    /// (falling back to the main screen). Re-showing resets the auto-hide timer.
    func show(_ kind: Kind, fraction: Double, onDisplay displayID: CGDirectDisplayID?) {
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
                y: screen.frame.minY + screen.frame.height * 0.10
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
}

/// The OSD's content: a large glyph over a 16-segment level bar on a frosted panel, echoing
/// the system brightness/volume overlay.
private struct OSDView: View {
    let systemImage: String
    let fraction: Double
    var tint: Color = .white

    private let segments = 16
    private var filledSegments: Int {
        guard fraction > 0 else { return 0 }
        return min(segments, max(1, Int((fraction * Double(segments)).rounded(.up))))
    }

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: systemImage)
                .font(.system(size: 58, weight: .regular))
                .foregroundStyle(tint.opacity(0.78))
                .frame(height: 66)

            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(index < filledSegments ? tint.opacity(0.78) : Color.black.opacity(0.18))
                        .frame(height: 8)
                }
            }
            .frame(width: 160)
        }
        .padding(26)
        .frame(width: 200, height: 200)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }
}
