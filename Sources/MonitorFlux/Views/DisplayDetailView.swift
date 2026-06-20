import SwiftUI

struct DisplayDetailView: View {
    @EnvironmentObject private var store: AppStore
    let display: DisplayInfo

    private var displayPreferences: DisplayPreferences {
        store.displayPreferences(for: display)
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

            Section("Gamma Brightness & Contrast") {
                Toggle("Use gamma controls", isOn: displayBinding(\.gammaControlsEnabled))
                    .disabled(!store.preferences.gammaEnabled)

                HStack {
                    Slider(value: displaySliderBinding(\.gammaBrightness, range: 0...150), in: 0...150, step: 1)
                        .disabled(!store.preferences.gammaEnabled || !displayPreferences.gammaControlsEnabled)
                    Text("\(displayPreferences.gammaBrightness)%")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }

                HStack {
                    Slider(value: displaySliderBinding(\.gammaContrast, range: 0...200), in: 0...200, step: 1)
                        .disabled(!store.preferences.gammaEnabled || !displayPreferences.gammaControlsEnabled)
                    Text("\(displayPreferences.gammaContrast)%")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }

            Section("Hardware DDC") {
                if display.isBuiltIn {
                    Label("Built-in panel", systemImage: "laptopcomputer")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Backend", value: store.ddcStatus.message)
                    Stepper(value: displayBinding(\.ddcDisplayIndex), in: 1...8) {
                        LabeledContent("DDC display", value: "\(displayPreferences.ddcDisplayIndex)")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Slider(value: displaySliderBinding(\.hardwareBrightness), in: 0...100, step: 1)
                            .disabled(!store.canUseDDC(for: display))
                        Text("\(displayPreferences.hardwareBrightness)%")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        Button {
                            store.applyBrightness(for: display)
                        } label: {
                            Label("Apply Brightness", systemImage: "sun.max")
                        }
                        .disabled(!store.canUseDDC(for: display))
                    }

                    HStack {
                        Slider(value: displaySliderBinding(\.hardwareContrast), in: 0...100, step: 1)
                            .disabled(!store.canUseDDC(for: display))
                        Text("\(displayPreferences.hardwareContrast)%")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                        Button {
                            store.applyContrast(for: display)
                        } label: {
                            Label("Apply Contrast", systemImage: "circle.lefthalf.filled")
                        }
                        .disabled(!store.canUseDDC(for: display))
                    }
                }

                LabeledContent("Last DDC", value: store.ddcMessage)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(display.name)
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
        range: ClosedRange<Int> = 0...100
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
