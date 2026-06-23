import SwiftUI

struct ColorScheduleView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedPhase: ColorPhase = .daytime

    var body: some View {
        ScrollView {
            content
        }
        .navigationTitle("Schedule")
    }

    private var content: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Image(systemName: statusIcon.symbol)
                        .font(.system(size: 30))
                        .foregroundStyle(statusIcon.color)
                        .frame(width: 44, height: 44)
                        .contentTransition(.symbolEffect(.replace))

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
                    Slider(value: temperatureSliderBinding, in: Double(ControlRanges.kelvin.lowerBound)...Double(ControlRanges.kelvin.upperBound))
                        .disabled(!store.preferences.gammaEnabled || store.preferences.colorMode == .off)
                    HStack {
                        Text(editingLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(editedTemperature) K")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                VStack(spacing: 4) {
                    Picker("Phase", selection: $selectedPhase) {
                        ForEach(ColorPhase.allCases) { phase in
                            Text(phase.label).tag(phase)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 380)
                    .disabled(store.preferences.colorMode != .clock)

                    Text("Pick a phase, then drag the slider above to set its warmth.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Text(scheduleSummary)
                    .font(.title3)
                    .foregroundStyle(.blue.opacity(0.72))
                    .frame(maxWidth: .infinity)

                FluxCurveEditor(
                    dayTemperature: preferenceBinding(\.dayTemperature),
                    sunsetTemperature: preferenceBinding(\.sunsetTemperature),
                    nightTemperature: preferenceBinding(\.nightTemperature),
                    warmStartMinutes: preferenceBinding(\.warmStartMinutes),
                    coolStartMinutes: preferenceBinding(\.coolStartMinutes),
                    sunsetStartMinutes: preferenceBinding(\.sunsetStartMinutes),
                    transitionMinutes: store.preferences.transitionMinutes
                )
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(0.16))
                )

                curveLegend

                HStack(spacing: 6) {
                    Stepper(value: preferenceBinding(\.coolStartMinutes), in: ControlRanges.minuteOfDay, step: 15) {
                        Text(MinuteFormatting.label(for: store.preferences.coolStartMinutes))
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .monospacedDigit()
                    }
                    Text("is when I wake up.")
                        .font(.title3)
                        .foregroundStyle(.blue.opacity(0.9))
                    Spacer()
                    Stepper(value: preferenceBinding(\.warmStartMinutes), in: ControlRanges.minuteOfDay, step: 15) {
                        Text(MinuteFormatting.label(for: store.preferences.warmStartMinutes))
                            .font(.title2)
                            .foregroundStyle(.orange)
                            .monospacedDigit()
                    }
                    Text("is bedtime.")
                        .font(.title3)
                        .foregroundStyle(.orange.opacity(0.9))
                }

                if store.showsGammaConflictBanner {
                    GammaConflictBanner(onClose: { store.dismissGammaConflictBanner() })
                }

                Divider()

                HStack(spacing: 14) {
                    Toggle("Enable gamma", isOn: preferenceBinding(\.gammaEnabled))
                    InfoButton(title: "What is gamma?", message: HelpText.gamma)
                    Toggle("Start at login", isOn: Binding {
                        store.preferences.startAtLogin
                    } set: { isEnabled in
                        store.setStartAtLogin(isEnabled)
                    })
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
                    Stepper(value: preferenceBinding(\.dayTemperature), in: ControlRanges.kelvin, step: 100) {
                        LabeledContent("Daytime", value: "\(store.preferences.dayTemperature) K")
                    }

                    Stepper(value: preferenceBinding(\.sunsetTemperature), in: ControlRanges.kelvin, step: 100) {
                        LabeledContent("Sunset", value: "\(store.preferences.sunsetTemperature) K")
                    }

                    Stepper(value: preferenceBinding(\.nightTemperature), in: ControlRanges.kelvin, step: 100) {
                        LabeledContent("Bedtime", value: "\(store.preferences.nightTemperature) K")
                    }

                    Stepper(value: preferenceBinding(\.transitionMinutes), in: ControlRanges.transitionMinutes, step: 5) {
                        LabeledContent("Fade", value: "\(store.preferences.transitionMinutes) min")
                    }
                }

                Section("Location & Sun") {
                    Picker("Schedule from", selection: preferenceBinding(\.scheduleSource)) {
                        ForEach(ScheduleSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        TextField("Latitude", text: preferenceBinding(\.latitude))
                        TextField("Longitude", text: preferenceBinding(\.longitude))
                    }

                    Button {
                        store.requestLocation()
                    } label: {
                        Label("Use my location", systemImage: "location")
                    }
                    LabeledContent("Location access", value: store.locationStatus)

                    if store.preferences.scheduleSource == .solar {
                        LabeledContent("Sunrise", value: solarLabel(store.solarTimes?.sunriseMinutes))
                        LabeledContent("Sunset", value: solarLabel(store.solarTimes?.sunsetMinutes))
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
    }

    /// The temperature actually applied to displays right now (drives status text).
    private var liveTemperature: Int {
        store.currentTemperature
            ?? (store.preferences.colorMode == .manual
                ? store.preferences.manualTemperature
                : store.preferences.dayTemperature)
    }

    /// The temperature the slider edits: the manual value in Manual mode, otherwise
    /// the selected phase's stored value.
    private var editedTemperature: Int {
        store.preferences.colorMode == .manual
            ? store.preferences.manualTemperature
            : store.preferences.temperature(for: selectedPhase)
    }

    private var editingLabel: String {
        store.preferences.colorMode == .manual ? "Manual" : selectedPhase.label
    }

    private var statusHeadline: String {
        guard store.preferences.gammaEnabled else {
            return "Gamma is off"
        }
        guard store.preferences.colorMode != .off else {
            return "Color warming is off"
        }
        return liveTemperature >= 5200 ? "The sun is up-go outside!" : "Warming down for the night"
    }

    /// A glyph that mirrors the headline: a sun by day, a warm moon at night, dimmed when
    /// color warming is off — instead of the abstract two-tone disc it replaces.
    private var statusIcon: (symbol: String, color: Color) {
        guard store.preferences.gammaEnabled, store.preferences.colorMode != .off else {
            return ("moon.zzz.fill", .secondary)
        }
        return liveTemperature >= 5200
            ? ("sun.max.fill", .phaseDaytime)
            : ("moon.stars.fill", .phaseBedtime)
    }

    private var scheduleSummary: String {
        let wake = MinuteFormatting.label(for: store.preferences.coolStartMinutes)
        let bed = MinuteFormatting.label(for: store.preferences.warmStartMinutes)
        return "Wake \(wake), bedtime \(bed) (\(liveTemperature) K)"
    }

    private func solarLabel(_ minutes: Int?) -> String {
        guard let minutes else {
            return "—"
        }
        return MinuteFormatting.label(for: minutes)
    }

    private var curveLegend: some View {
        HStack(spacing: 14) {
            legendDot(.phaseDaytime, "Daytime", store.preferences.dayTemperature)
            legendDot(.phaseSunset, "Sunset", store.preferences.sunsetTemperature)
            legendDot(.phaseBedtime, "Bedtime", store.preferences.nightTemperature)
            Spacer()
            Text("Drag each dot to set its time & warmth")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func legendDot(_ color: Color, _ label: String, _ kelvin: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text("\(label) · \(kelvin) K")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var temperatureSliderBinding: Binding<Double> {
        Binding {
            Double(editedTemperature)
        } set: { newValue in
            let rounded = Int((newValue / 100.0).rounded()) * 100
            store.updateGlobalPreferences { preferences in
                if preferences.colorMode == .manual {
                    preferences.manualTemperature = rounded
                } else {
                    preferences.setTemperature(rounded, for: selectedPhase)
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
