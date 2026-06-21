import AppKit
import SwiftUI

/// The MonitorControl-style popup shown from the menu bar: per-display brightness and
/// contrast, plus a global f.lux-style ambience (color temperature) control. Detailed
/// configuration lives in the on-demand window opened from the footer.
struct QuickControlsView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ambienceSection

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
            footer
        }
        .padding(16)
        .frame(width: 308)
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

    private var ambienceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sliderRow(
                icon: "thermometer.sun",
                value: ambienceBinding,
                range: ControlRanges.kelvin,
                step: 100,
                readout: "\(ambienceTemperature) K",
                disabled: !ambienceEnabled
            )

            Picker("Mode", selection: modeBinding) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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

    private var ambienceBinding: Binding<Double> {
        Binding {
            Double(ambienceTemperature)
        } set: { newValue in
            let rounded = Int((newValue / 100.0).rounded()) * 100
            // Dragging warmth in the popup is an immediate "set it now" override, so
            // it switches to Manual; the mode control returns to Schedule.
            store.updateGlobalPreferences { preferences in
                preferences.gammaEnabled = true
                preferences.colorMode = .manual
                preferences.manualTemperature = rounded
            }
        }
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
                // Built-in panels have no DDC; expose the software (gamma) brightness,
                // clearly the dimming control rather than backlight.
                sliderRow(
                    icon: "sun.max",
                    value: gammaBrightnessBinding(display),
                    range: ControlRanges.gammaBrightnessPercent,
                    step: 1,
                    readout: "\(preferences.gammaBrightness)%",
                    disabled: !store.preferences.gammaEnabled
                )
            } else {
                sliderRow(
                    icon: "sun.max",
                    value: hardwareBrightnessBinding(display),
                    range: ControlRanges.hardwarePercent,
                    step: 1,
                    readout: "\(preferences.hardwareBrightness)%",
                    disabled: false
                )
                sliderRow(
                    icon: "circle.lefthalf.filled",
                    value: hardwareContrastBinding(display),
                    range: ControlRanges.hardwarePercent,
                    step: 1,
                    readout: "\(preferences.hardwareContrast)%",
                    disabled: false
                )
            }
        }
    }

    private func hardwareBrightnessBinding(_ display: DisplayInfo) -> Binding<Double> {
        Binding {
            Double(store.displayPreferences(for: display).hardwareBrightness)
        } set: { newValue in
            store.setHardwareBrightness(Int(newValue.rounded()), for: display)
        }
    }

    private func hardwareContrastBinding(_ display: DisplayInfo) -> Binding<Double> {
        Binding {
            Double(store.displayPreferences(for: display).hardwareContrast)
        } set: { newValue in
            store.setHardwareContrast(Int(newValue.rounded()), for: display)
        }
    }

    private func gammaBrightnessBinding(_ display: DisplayInfo) -> Binding<Double> {
        Binding {
            Double(store.displayPreferences(for: display).gammaBrightness)
        } set: { newValue in
            store.updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences.gammaBrightness = Int(newValue.rounded())
                    .clamped(to: ControlRanges.gammaBrightnessPercent)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Settings…") {
                openWindow(id: "main")
                store.activateMainWindow()
            }
            Spacer()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Slider row

    private func sliderRow(
        icon: String,
        value: Binding<Double>,
        range: ClosedRange<Int>,
        step: Double,
        readout: String,
        disabled: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Slider(
                value: value,
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: step
            )
            .disabled(disabled)
            Text(readout)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
