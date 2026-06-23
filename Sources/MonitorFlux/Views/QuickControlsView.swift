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
                Text("No displays detected")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.displays) { display in
                    displayCard(display)
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
                Text("Ambience")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                InfoButton(title: "Ambience (color temperature)", message: HelpText.gamma)
                Spacer()
            }

            controlRow(
                icon: "thermometer.sun",
                value: Double(ambienceTemperature),
                range: ControlRanges.kelvin,
                enabled: ambienceEnabled,
                readout: "\(ambienceTemperature) K"
            ) { newValue in
                let rounded = Int((newValue / 100.0).rounded()) * 100
                // Dragging warmth here is an immediate "set it now" override -> Manual.
                store.updateGlobalPreferences { preferences in
                    preferences.gammaEnabled = true
                    preferences.colorMode = .manual
                    preferences.manualTemperature = rounded
                }
            }

            Picker("Mode", selection: modeBinding) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
        .background(cardBackground)
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

    // MARK: - Per-display cards

    @ViewBuilder
    private func displayCard(_ display: DisplayInfo) -> some View {
        let preferences = store.displayPreferences(for: display)

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                Text(display.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            if display.isBuiltIn {
                if store.canUseNativeBrightness(display) {
                    // Real backlight via DisplayServices.
                    let level = store.nativeBrightnessValue(for: display)
                    controlRow(
                        icon: "sun.max",
                        value: level * 100,
                        range: ControlRanges.hardwarePercent,
                        enabled: true,
                        readout: "\(Int((level * 100).rounded()))%"
                    ) { newValue in
                        store.setNativeBrightness(newValue / 100.0, for: display)
                    }
                } else {
                    // No backlight API; fall back to software (gamma) dimming.
                    controlRow(
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
            } else {
                controlRow(
                    icon: "sun.max",
                    value: Double(preferences.hardwareBrightness),
                    range: ControlRanges.hardwarePercent,
                    enabled: true,
                    readout: "\(preferences.hardwareBrightness)%"
                ) { store.setHardwareBrightness(Int($0.rounded()), for: display) }

                controlRow(
                    icon: "circle.lefthalf.filled",
                    value: Double(preferences.hardwareContrast),
                    range: ControlRanges.hardwarePercent,
                    enabled: true,
                    readout: "\(preferences.hardwareContrast)%"
                ) { store.setHardwareContrast(Int($0.rounded()), for: display) }

                // Volume is only shown when the monitor actually has speakers (or the user
                // forced it on) — a speakerless display gets no useless volume slider.
                if store.shouldShowVolumeControl(for: display) {
                    controlRow(
                        icon: "speaker.wave.2.fill",
                        value: Double(preferences.hardwareVolume),
                        range: ControlRanges.hardwarePercent,
                        enabled: true,
                        readout: "\(preferences.hardwareVolume)%"
                    ) { store.setHardwareVolume(Int($0.rounded()), for: display) }
                }
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    // MARK: - Building blocks

    private func controlRow(
        icon: String,
        value: Double,
        range: ClosedRange<Int>,
        enabled: Bool,
        readout: String,
        onChange: @escaping (Double) -> Void
    ) -> some View {
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

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.primary.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Collapse the `MenuBarExtra(.window)` dropdown the way clicking a real `NSMenu` item does.
/// SwiftUI doesn't expose a dismiss for it, so close the popup window directly: it's the
/// visible, non-titled, mouse-accepting panel — distinct from the titled main window and the
/// non-interactive OSD panel (which ignores mouse events).
@MainActor
func dismissMenuBarPopup() {
    for window in NSApp.windows
    where window.isVisible
        && !window.styleMask.contains(.titled)
        && !window.ignoresMouseEvents {
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
