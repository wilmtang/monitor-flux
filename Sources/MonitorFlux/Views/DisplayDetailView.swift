import SwiftUI

struct DisplayDetailView: View {
    @EnvironmentObject private var store: AppStore
    let display: DisplayInfo

    private var displayPreferences: DisplayPreferences {
        store.displayPreferences(for: display)
    }

    private var gammaSlidersEnabled: Bool {
        store.preferences.gammaEnabled && displayPreferences.gammaControlsEnabled
    }

    var body: some View {
        Form {
            Section("Display") {
                LabeledContent("Name", value: display.name)
                LabeledContent("Kind", value: display.kindLabel)
                LabeledContent("Frame", value: display.frameDescription)
                LabeledContent("CoreGraphics ID", value: "\(display.id)")
            }

            Section("Color") {
                Toggle("Warm color", isOn: displayBinding(\.colorEnabled))
                    .disabled(!store.preferences.gammaEnabled)
                LabeledContent("Current", value: store.currentTemperature.map { "\($0) K" } ?? "Off")
            }

            Section {
                Toggle("Use gamma controls", isOn: displayBinding(\.gammaControlsEnabled))
                    .disabled(!store.preferences.gammaEnabled)

                gammaSliderRow(title: "Brightness", keyPath: \.gammaBrightness, range: ControlRanges.gammaBrightnessPercent)
                gammaSliderRow(title: "Contrast", keyPath: \.gammaContrast, range: ControlRanges.gammaContrastPercent)

                if !store.preferences.gammaEnabled {
                    Text("Enable gamma on the Schedule screen to use these.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !displayPreferences.gammaControlsEnabled {
                    Text("Turn on “Use gamma controls” to adjust software brightness and contrast.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                sectionHeader("Gamma Brightness & Contrast", help: HelpText.gamma, helpTitle: "Software (gamma) controls")
            }

            Section {
                if display.isBuiltIn {
                    Label("Built-in panel — no DDC", systemImage: "laptopcomputer")
                        .foregroundStyle(.secondary)
                    Text("Built-in displays don't support DDC. Use the gamma brightness above, or your keyboard's brightness keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Backend", value: store.ddcStatus.message)
                    Stepper(value: displayBinding(\.ddcDisplayIndex), in: ControlRanges.ddcDisplayIndex) {
                        LabeledContent("DDC display index (ddcctl fallback)", value: "\(displayPreferences.ddcDisplayIndex)")
                    }

                    hardwareSliderRow(title: "Brightness", icon: "sun.max", value: displayPreferences.hardwareBrightness) {
                        store.setHardwareBrightness($0, for: display)
                    }
                    hardwareSliderRow(title: "Contrast", icon: "circle.lefthalf.filled", value: displayPreferences.hardwareContrast) {
                        store.setHardwareContrast($0, for: display)
                    }
                    hardwareSliderRow(title: "Volume", icon: "speaker.wave.2.fill", value: displayPreferences.hardwareVolume) {
                        store.setHardwareVolume($0, for: display)
                    }

                    LabeledContent("Last DDC", value: store.ddcMessage)
                    Text("Sliders send to the monitor live as you drag.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                sectionHeader("Hardware DDC", help: HelpText.ddc, helpTitle: "Hardware (DDC/CI) controls")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(display.name)
    }

    private func sectionHeader(_ title: String, help: String, helpTitle: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(title: helpTitle, message: help)
        }
    }

    private func gammaSliderRow(
        title: String,
        keyPath: WritableKeyPath<DisplayPreferences, Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 74, alignment: .leading)
            Slider(
                value: displaySliderBinding(keyPath, range: range),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .disabled(!gammaSlidersEnabled)
            Text("\(displayPreferences[keyPath: keyPath])%")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }

    private func hardwareSliderRow(
        title: String,
        icon: String,
        value: Int,
        setter: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(title)
                .frame(width: 64, alignment: .leading)
            Slider(
                value: Binding { Double(value) } set: { setter(Int($0.rounded())) },
                in: Double(ControlRanges.hardwarePercent.lowerBound)...Double(ControlRanges.hardwarePercent.upperBound)
            )
            .disabled(!store.canUseDDC(for: display))
            Text("\(value)%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func displayBinding<Value>(
        _ keyPath: WritableKeyPath<DisplayPreferences, Value>
    ) -> Binding<Value> {
        Binding {
            displayPreferences[keyPath: keyPath]
        } set: { newValue in
            store.updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences[keyPath: keyPath] = newValue
            }
        }
    }

    private func displaySliderBinding(
        _ keyPath: WritableKeyPath<DisplayPreferences, Int>,
        range: ClosedRange<Int> = ControlRanges.hardwarePercent
    ) -> Binding<Double> {
        Binding {
            Double(displayPreferences[keyPath: keyPath])
        } set: { newValue in
            store.updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences[keyPath: keyPath] = Int(newValue.rounded()).clamped(to: range)
            }
        }
    }
}
