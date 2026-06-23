import AppKit
import SwiftUI

/// The MonitorControl-style popup shown from the menu bar: per-display brightness, contrast,
/// and volume, plus a global f.lux-style ambience (color temperature) control. Detailed
/// configuration lives in the on-demand window opened from the footer.
struct QuickControlsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ambienceCard

            if store.displays.isEmpty {
                emptyHint("No displays detected — connect a monitor to control its brightness and color here.")
            } else {
                ForEach(store.displays) { display in
                    DisplayCardView(display: display)
                }
                // Only the built-in panel is present: name what the user would gain by plugging
                // a monitor in, instead of leaving the area looking like nothing's missing.
                if !store.displays.contains(where: { !$0.isBuiltIn }) {
                    emptyHint("No external monitors detected — connect one to control its brightness, contrast, and volume here.")
                }
            }

            Divider()

            PopupMenuRow(title: "Settings…", shortcut: "⌘,") {
                store.showMainWindow()
            }
            PopupMenuRow(title: "Quit MonitorFlux", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 312)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.orange)
            Text("MonitorFlux")
                .font(.headline)
            Spacer()
            Text(store.currentTemperature.map { "\($0) K" } ?? "Off")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Ambience (global color temperature)

    private var ambienceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Warmth")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                InfoButton(title: "Warmth (color temperature)", message: HelpText.gamma)
                Spacer()
                modeChip
            }

            warmthRow
        }
        .padding(12)
        .background(popupCardBackground())
    }

    /// Compact mode control that replaces the old Off/Manual/Schedule segmented picker: a chip
    /// showing the current state ("Auto · schedule" on a schedule, else "Manual"/"Off") that opens
    /// a menu to switch. Keeps the popup calm — the warmth slider stays the hero and the mode is a
    /// quiet status you can tap.
    private var modeChip: some View {
        Menu {
            Picker("Mode", selection: modeBinding) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: modeChipAppearance.icon)
                    .font(.system(size: 9, weight: .bold))
                Text(modeChipAppearance.label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(modeChipAppearance.tint.opacity(0.16)))
            .foregroundStyle(modeChipAppearance.tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// The mode the chip reflects: Off when the warmth master is disabled, else the color mode.
    private var currentMode: ColorMode {
        store.preferences.gammaEnabled ? store.preferences.colorMode : .off
    }

    private var modeChipAppearance: (icon: String, label: String, tint: Color) {
        switch currentMode {
        case .off:
            return ("power", "Off", Color.secondary)
        case .manual:
            return ("hand.point.up.left.fill", "Manual", Color.orange)
        case .clock:
            return ("clock.fill", "Auto · schedule", Color.blue)
        }
    }

    /// The global warmth (color-temperature) slider, flanked by warm/cool end affordances: a
    /// flame at the low-Kelvin (warm) end and a snowflake at the high-Kelvin (cool) end, so the
    /// blue↔amber motif reads at a glance. Dragging is an immediate "set it now" override → Manual.
    private var warmthRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "flame.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .help("Warmer (lower color temperature)")
            MonitorSlider(
                systemImage: "thermometer.sun",
                value: Double(ambienceTemperature),
                range: Double(ControlRanges.kelvin.lowerBound)...Double(ControlRanges.kelvin.upperBound),
                isEnabled: ambienceEnabled
            ) { newValue in
                let rounded = Int((newValue / 100.0).rounded()) * 100
                store.updateGlobalPreferences { preferences in
                    preferences.gammaEnabled = true
                    preferences.colorMode = .manual
                    preferences.manualTemperature = rounded
                }
            }
            Image(systemName: "snowflake")
                .font(.system(size: 11))
                .foregroundStyle(.blue)
                .help("Cooler (higher color temperature)")
            Text("\(ambienceTemperature) K")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    private var ambienceEnabled: Bool {
        store.preferences.gammaEnabled && store.preferences.colorMode != .off
    }

    private var ambienceTemperature: Int {
        store.currentTemperature
            ?? (store.preferences.colorMode == .manual
                ? store.preferences.manualTemperature
                : store.preferences.dayTemperature)
    }

    private var modeBinding: Binding<ColorMode> {
        Binding {
            store.preferences.gammaEnabled ? store.preferences.colorMode : .off
        } set: { newMode in
            store.updateGlobalPreferences { preferences in
                if newMode != .off {
                    preferences.gammaEnabled = true
                }
                preferences.colorMode = newMode
            }
        }
    }

    /// A calm, card-styled empty state — a display glyph plus a sentence naming what the user
    /// gains by connecting a monitor — instead of a bare line or an empty area.
    private func emptyHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "display")
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(popupCardBackground())
    }
}

// MARK: - Per-display card

/// One display's controls in the popup. Brightness shows by default; contrast and volume
/// (external displays) tuck behind a per-card "More" disclosure so the popup stays calm.
private struct DisplayCardView: View {
    @EnvironmentObject private var store: AppStore
    let display: DisplayInfo
    @State private var expanded = false

    var body: some View {
        let preferences = store.displayPreferences(for: display)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                Text(display.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if !display.isBuiltIn {
                    moreButton
                }
            }

            if display.isBuiltIn {
                builtInControls(preferences)
            } else {
                externalControls(preferences)
            }
        }
        .padding(12)
        .background(popupCardBackground())
    }

    private var moreButton: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(expanded ? "Less" : "More")
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(expanded ? 180 : 0))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(expanded ? "Hide contrast and volume" : "Show contrast and volume")
    }

    @ViewBuilder
    private func builtInControls(_ preferences: DisplayPreferences) -> some View {
        if store.canUseNativeBrightness(display) {
            // Real backlight via DisplayServices.
            let level = store.nativeBrightnessValue(for: display)
            ControlRow(
                icon: "sun.max",
                value: level * 100,
                range: ControlRanges.hardwarePercent,
                readout: "\(Int((level * 100).rounded()))%"
            ) { newValue in
                store.setNativeBrightness(newValue / 100.0, for: display)
            }
        } else {
            // No backlight API; fall back to software (gamma) dimming.
            ControlRow(
                icon: "sun.max",
                value: Double(preferences.gammaBrightness),
                range: ControlRanges.gammaBrightnessPercent,
                enabled: store.preferences.gammaEnabled,
                readout: "\(preferences.gammaBrightness)%"
            ) { newValue in
                store.updateDisplayPreferences(for: display) { displayPreferences in
                    displayPreferences.gammaBrightness = Int(newValue.rounded())
                        .clamped(to: ControlRanges.gammaBrightnessPercent)
                }
            }
            Text("Software dimming (built-in panel has no DDC)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func externalControls(_ preferences: DisplayPreferences) -> some View {
        ControlRow(
            icon: "sun.max",
            value: Double(preferences.hardwareBrightness),
            range: ControlRanges.hardwarePercent,
            readout: "\(preferences.hardwareBrightness)%"
        ) { store.setHardwareBrightness(Int($0.rounded()), for: display) }

        if expanded {
            ControlRow(
                icon: "circle.lefthalf.filled",
                value: Double(preferences.hardwareContrast),
                range: ControlRanges.hardwarePercent,
                readout: "\(preferences.hardwareContrast)%"
            ) { store.setHardwareContrast(Int($0.rounded()), for: display) }

            // Volume only when the monitor actually has speakers (or the user forced it on)
            // — a speakerless display gets no useless volume slider.
            if store.shouldShowVolumeControl(for: display) {
                ControlRow(
                    icon: "speaker.wave.2.fill",
                    value: Double(preferences.hardwareVolume),
                    range: ControlRanges.hardwarePercent,
                    readout: "\(preferences.hardwareVolume)%"
                ) { store.setHardwareVolume(Int($0.rounded()), for: display) }
            }
        }
    }
}

// MARK: - Building blocks

/// A labeled MonitorControl-style slider row: the slider plus a fixed-width readout.
private struct ControlRow: View {
    let icon: String
    let value: Double
    let range: ClosedRange<Int>
    var enabled = true
    let readout: String
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            MonitorSlider(
                systemImage: icon,
                value: value,
                range: Double(range.lowerBound)...Double(range.upperBound),
                isEnabled: enabled,
                onChange: onChange
            )
            Text(readout)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

private func popupCardBackground() -> some View {
    RoundedRectangle(cornerRadius: 10)
        .fill(Color.primary.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
}

/// Collapse the `MenuBarExtra(.window)` dropdown the way clicking a real `NSMenu` item does.
/// SwiftUI doesn't expose a dismiss for it, so close the popup window directly: it's the
/// visible, non-titled, mouse-accepting panel. The width gate is what keeps us from also
/// closing the tiny (~31pt) status-item windows that back the menu-bar icon itself — closing
/// those makes the icon vanish while macOS keeps its slot. The titled main window and the
/// mouse-ignoring OSD panel are excluded too.
@MainActor
func dismissMenuBarPopup() {
    for window in NSApp.windows
    where window.isVisible
        && !window.styleMask.contains(.titled)
        && !window.ignoresMouseEvents
        && window.frame.width >= 120 {
        window.close()
    }
}

/// A footer row that behaves like a real menu item: full-width hit target, accent
/// highlight on hover, a trailing keyboard-shortcut hint — and it dismisses the dropdown.
private struct PopupMenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            dismissMenuBarPopup()
            action()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(isHovering ? .white : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.accentColor.opacity(0.9) : .clear)
            )
            .foregroundStyle(isHovering ? .white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
