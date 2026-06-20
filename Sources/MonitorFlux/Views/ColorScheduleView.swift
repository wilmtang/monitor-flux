import SwiftUI

struct ColorScheduleView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedPhase = "Daytime"

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(.orange.opacity(0.55))
                        Circle()
                            .trim(from: 0.08, to: 0.58)
                            .fill(.blue.opacity(0.82))
                            .rotationEffect(.degrees(22))
                    }
                    .frame(width: 44, height: 44)

                    Text(statusHeadline)
                        .font(.title2)
                        .fontWeight(.medium)

                    Spacer()

                    Picker("Mode", selection: preferenceBinding(\.colorMode)) {
                        ForEach(ColorMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }

                VStack(spacing: 10) {
                    Slider(value: temperatureSliderBinding, in: 1000...6500, step: 100)
                        .disabled(!store.preferences.gammaEnabled || store.preferences.colorMode == .off)
                    HStack {
                        Spacer()
                        Text("\(displayTemperature) K")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Picker("Phase", selection: $selectedPhase) {
                    Text("Daytime").tag("Daytime")
                    Text("Sunset").tag("Sunset")
                    Text("Bedtime").tag("Bedtime")
                }
                .pickerStyle(.segmented)
                .frame(width: 380)
                .frame(maxWidth: .infinity)

                Text(scheduleSummary)
                    .font(.title3)
                    .foregroundStyle(.blue.opacity(0.72))
                    .frame(maxWidth: .infinity)

                FluxCurveEditor(
                    dayTemperature: preferenceBinding(\.dayTemperature),
                    nightTemperature: preferenceBinding(\.nightTemperature),
                    warmStartMinutes: preferenceBinding(\.warmStartMinutes),
                    coolStartMinutes: preferenceBinding(\.coolStartMinutes),
                    transitionMinutes: store.preferences.transitionMinutes
                )
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(0.16))
                )

                HStack(spacing: 6) {
                    Stepper(value: preferenceBinding(\.coolStartMinutes), in: 0...1435, step: 15) {
                        Text(MinuteFormatting.label(for: store.preferences.coolStartMinutes))
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .monospacedDigit()
                    }
                    Text("is when I wake up.")
                        .font(.title3)
                        .foregroundStyle(.blue.opacity(0.9))
                    Spacer()
                    Stepper(value: preferenceBinding(\.warmStartMinutes), in: 0...1435, step: 15) {
                        Text(MinuteFormatting.label(for: store.preferences.warmStartMinutes))
                            .font(.title2)
                            .foregroundStyle(.orange)
                            .monospacedDigit()
                    }
                    Text("is bedtime.")
                        .font(.title3)
                        .foregroundStyle(.orange.opacity(0.9))
                }

                Divider()

                HStack(spacing: 14) {
                    Toggle("Enable gamma", isOn: preferenceBinding(\.gammaEnabled))
                    Toggle("Start at login", isOn: preferenceBinding(\.startAtLogin))
                    Spacer()
                    Button("Done") {
                        NSApp.keyWindow?.close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(34)

            Form {
                Section("Custom Colors") {
                    Stepper(value: preferenceBinding(\.dayTemperature), in: 1000...6500, step: 100) {
                        LabeledContent("Day", value: "\(store.preferences.dayTemperature) K")
                    }

                    Stepper(value: preferenceBinding(\.nightTemperature), in: 1000...6500, step: 100) {
                        LabeledContent("Night", value: "\(store.preferences.nightTemperature) K")
                    }

                    Stepper(value: preferenceBinding(\.transitionMinutes), in: 0...240, step: 5) {
                        LabeledContent("Fade", value: "\(store.preferences.transitionMinutes) min")
                    }
                }

                Section("Location") {
                    HStack {
                        TextField("Latitude", text: preferenceBinding(\.latitude))
                        TextField("Longitude", text: preferenceBinding(\.longitude))
                    }
                    LabeledContent("Gamma", value: store.colorMessage)
                }

                Section {
                    Button {
                        store.disableColorAndRestore()
                    } label: {
                        Label("Disable Gamma and Restore", systemImage: "arrow.uturn.backward.circle")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("Schedule")
    }

    private var displayTemperature: Int {
        store.currentTemperature
            ?? (store.preferences.colorMode == .manual
                ? store.preferences.manualTemperature
                : store.preferences.dayTemperature)
    }

    private var statusHeadline: String {
        guard store.preferences.gammaEnabled else {
            return "Gamma is off"
        }
        guard store.preferences.colorMode != .off else {
            return "Color warming is off"
        }
        return displayTemperature >= 5200 ? "The sun is up-go outside!" : "Warming down for the night"
    }

    private var scheduleSummary: String {
        let wake = MinuteFormatting.label(for: store.preferences.coolStartMinutes)
        let bed = MinuteFormatting.label(for: store.preferences.warmStartMinutes)
        return "Wake \(wake), bedtime \(bed) (\(displayTemperature) K)"
    }

    private var temperatureSliderBinding: Binding<Double> {
        Binding {
            Double(displayTemperature)
        } set: { newValue in
            let rounded = Int((newValue / 100.0).rounded()) * 100
            store.updateGlobalPreferences { preferences in
                switch selectedPhase {
                case "Bedtime":
                    preferences.nightTemperature = rounded
                case "Sunset":
                    preferences.manualTemperature = rounded
                    preferences.colorMode = .manual
                default:
                    preferences.dayTemperature = rounded
                }
            }
        }
    }

    private func preferenceBinding<Value>(
        _ keyPath: WritableKeyPath<AppPreferences, Value>
    ) -> Binding<Value> {
        Binding {
            store.preferences[keyPath: keyPath]
        } set: { newValue in
            store.updateGlobalPreferences { preferences in
                preferences[keyPath: keyPath] = newValue
            }
        }
    }
}
