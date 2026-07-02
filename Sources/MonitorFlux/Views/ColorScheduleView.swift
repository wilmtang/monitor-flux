import SwiftUI

struct ColorScheduleView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedPhase: ColorPhase = .daytime

    var body: some View {
        // One grouped form for the whole pane: the hero (slider + curve) is the first card,
        // so its edges line up with the setting cards below at every window width — no
        // hand-tuned padding to drift out of sync — and the pane has a single scroll view
        // instead of a Form nested inside a ScrollView.
        Form {
            Section {
                hero
                    .listRowInsets(EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18))
            }

            Section {
                HStack(spacing: 8) {
                    Text("Warmth")
                    InfoButton(title: "What is gamma?", message: HelpText.gamma)
                    Spacer()
                    Toggle("Warmth", isOn: preferenceBinding(\.gammaEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            Section("Transition") {
                Picker("Fade", selection: scheduleEditBinding(\.transitionMinutes)) {
                    ForEach(fadeOptions, id: \.self) { minutes in
                        Text(fadeLabel(minutes)).tag(minutes)
                    }
                }
            }

            locationSection

            Section {
                Button {
                    store.disableColorAndRestore()
                } label: {
                    Label("Turn off warmth & reset colors", systemImage: "arrow.uturn.backward.circle")
                }
                .help("Turns warmth off on every display and restores their original color — use this if colors look wrong or you want another color app to take over.")
                Text("Turns warmth off everywhere and restores each display's original color tables (undoing any warming or software dimming).")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Schedule")
        // A scrub preview is a temporary, exploratory state — never let it persist past this
        // screen. Reset it whenever the Schedule pane is (re)loaded or left, so the screen always
        // returns to the live color. Also open the phase tab on whatever phase is live now, so the
        // slider edits the phase the screen is actually in.
        .onAppear {
            store.clearSchedulePreview()
            selectedPhase = ColorSchedule.currentPhase(preferences: store.preferences)
        }
        .onDisappear { store.clearSchedulePreview() }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(systemName: statusIcon.symbol)
                    .zoomFont(size: 30)
                    .foregroundStyle(statusIcon.color)
                    .frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))

                Text(statusHeadline)
                    .zoomFont(.title2)
                    .fontWeight(.medium)

                Spacer()

                Picker("Mode", selection: preferenceBinding(\.colorMode)) {
                    ForEach(ColorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            // One row — phase label, slider, Kelvin readout — the same shape as System
            // Settings' Night Shift color-temperature row. The form gives the slider the
            // standard compact trailing track; the label and readout anchor the row's edges.
            HStack(spacing: 12) {
                Text(editingLabel)
                    .zoomFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Slider(value: temperatureSliderBinding, in: Double(ControlRanges.kelvin.lowerBound)...Double(ControlRanges.kelvin.upperBound))
                    .layoutPriority(1)
                    .disabled(!store.preferences.gammaEnabled || store.preferences.colorMode == .off)
                Text(KelvinFormatting.label(for: editedTemperature))
                    .zoomFont(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
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
                // Switching phases is a fresh editing intent, so drop any scrub preview and
                // snap the time line back to "now" — the same reset we do on enter/leave.
                .onChange(of: selectedPhase) { _, _ in
                    store.clearSchedulePreview()
                }

                Text("Pick a phase, then drag the slider above to set its warmth.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Text(scheduleSummary)
                .zoomFont(.title3)
                .foregroundStyle(.blue.opacity(0.72))
                .frame(maxWidth: .infinity)

            FluxCurveEditor(
                dayTemperature: scheduleEditBinding(\.dayTemperature),
                sunsetTemperature: scheduleEditBinding(\.sunsetTemperature),
                nightTemperature: scheduleEditBinding(\.nightTemperature),
                warmStartMinutes: timeAnchorBinding(.bedtime),
                coolStartMinutes: timeAnchorBinding(.daytime),
                sunsetStartMinutes: timeAnchorBinding(.sunset),
                transitionMinutes: store.preferences.transitionMinutes,
                previewMinute: store.schedulePreviewMinute,
                onPreview: { store.previewScheduleColor(atMinute: $0) }
            )
            .background(
                // Semantic fill so the card reads in both appearances — flat white was
                // invisible against a light window background.
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
            )

            curveLegend

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                timeStepper(.daytime, title: "Wake", tint: .blue)
                Spacer(minLength: 8)
                timeStepper(.sunset, title: "Sunset", tint: .orange)
                Spacer(minLength: 8)
                timeStepper(.bedtime, title: "Bedtime", tint: .indigo)
            }

            if store.showsGammaConflictBanner {
                GammaConflictBanner(
                    appNames: store.gammaConflictApps,
                    onClose: { store.dismissGammaConflictBanner() }
                )
            }
        }
    }

    private var locationSection: some View {
        Section("Location & Sun") {
            Picker("Schedule from", selection: scheduleSourceBinding) {
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
                LabeledContent("Sunrise today", value: solarLabel(store.solarTimes?.sunriseMinutes))
                LabeledContent("Sunset today", value: solarLabel(store.solarTimes?.sunsetMinutes))
                Text("Computed on-device from your coordinates and today's date (no internet), so they shift a little each day and the schedule follows the real sun.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("Warmth", value: store.colorMessage)
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
        store.preferences.colorMode == .manual ? ColorMode.manual.label : selectedPhase.label
    }

    private var statusHeadline: String {
        guard store.preferences.gammaEnabled else {
            return "Warmth is off"
        }
        guard store.preferences.colorMode != .off else {
            return "Warmth is off"
        }
        return liveTemperature >= 5200 ? "The sun is up — go outside!" : "Warming down for the night"
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
        // Use the effective anchors so the summary matches the chart and steppers when following the
        // sun (wake = today's sunrise), rather than the stored hand-set values underneath.
        let wake = MinuteFormatting.label(for: effectivePreferences.startMinutes(for: .daytime))
        let bed = MinuteFormatting.label(for: effectivePreferences.startMinutes(for: .bedtime))
        return "Wake \(wake), bedtime \(bed) (\(KelvinFormatting.label(for: liveTemperature)))"
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
            if let minute = store.schedulePreviewMinute {
                // Make the temporary preview obvious and one-tap reversible.
                HStack(spacing: 8) {
                    Image(systemName: "eye.fill").zoomFont(.caption2)
                    Text("Previewing \(MinuteFormatting.label(for: minute))")
                        .zoomFont(.caption, weight: .medium)
                        .monospacedDigit()
                    Button("Reset") { store.clearSchedulePreview() }
                        .buttonStyle(.plain)
                        .zoomFont(.caption, weight: .semibold)
                        .foregroundStyle(.blue)
                }
                .foregroundStyle(.orange)
            } else {
                Text("Drag the time line to preview · drag a dot to set its warmth")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func legendDot(_ color: Color, _ label: String, _ kelvin: Int) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text("\(label) · \(KelvinFormatting.label(for: kelvin))")
                .zoomFont(.caption)
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

    /// Like `preferenceBinding`, but editing the value also adopts the automatic schedule (Warmth on,
    /// mode → Automatic). Touching a schedule shape — a phase temperature or the fade — means the user
    /// wants the schedule, mirroring how dragging the time line switches to it. Used for the shape
    /// controls that aren't time anchors (those use `timeAnchorBinding`, which additionally pins the
    /// source to Set times); not for the Fixed-warmth or location settings.
    private func scheduleEditBinding<Value>(
        _ keyPath: WritableKeyPath<AppPreferences, Value>
    ) -> Binding<Value> {
        Binding {
            store.preferences[keyPath: keyPath]
        } set: { newValue in
            store.updateGlobalPreferences { preferences in
                preferences[keyPath: keyPath] = newValue
                preferences.gammaEnabled = true
                preferences.colorMode = .clock
            }
        }
    }

    /// A binding for a phase's start *time*, shared by the curve handle and the time stepper.
    ///
    /// Read returns the *effective* anchor: when the source is Sunrise & sunset, wake and sunset come
    /// from the day's computed solar times (bedtime is always the set hour), so the chart, dots, and
    /// steppers all show what's actually applied. Write commits the edit via `commitTimeEdit`, which
    /// switches the source to Set times — hand-placing a time means the user is setting it, and a
    /// solar source would otherwise recompute over it.
    private func timeAnchorBinding(_ phase: ColorPhase) -> Binding<Int> {
        Binding {
            effectivePreferences.startMinutes(for: phase)
        } set: { newValue in
            commitTimeEdit(phase, rawMinute: newValue)
        }
    }

    /// The preferences as the schedule actually applies them today: solar-adjusted when the source is
    /// Sunrise & sunset (and the coordinates parse), otherwise the stored values verbatim.
    private var effectivePreferences: AppPreferences {
        ColorSchedule.solarAdjustedPreferences(store.preferences)
    }

    /// Commit a phase time edit (from a dragged dot or a stepper). If we were following the sun, first
    /// freeze today's computed sunrise/sunset into the anchors so the other dots don't jump, then pin
    /// the source to Set times with this edit applied — clamped to keep daytime → sunset → bedtime
    /// order. Stays on the Automatic schedule (Warmth on); it never flips the mode to Fixed.
    private func commitTimeEdit(_ phase: ColorPhase, rawMinute: Int) {
        store.updateGlobalPreferences { preferences in
            if preferences.scheduleSource == .solar {
                let solar = ColorSchedule.solarAdjustedPreferences(preferences)
                preferences.coolStartMinutes = solar.coolStartMinutes
                preferences.sunsetStartMinutes = solar.sunsetStartMinutes
                preferences.scheduleSource = .manualTimes
            }
            let clamped = ColorSchedule.clampedStartMinute(rawMinute, for: phase, preferences: preferences)
            preferences.setStartMinutes(clamped, for: phase)
            preferences.gammaEnabled = true
            preferences.colorMode = .clock
        }
    }

    /// The "Schedule from" binding. Switching from Sunrise & sunset to Set times freezes the times
    /// currently shown (today's solar values) into the anchors, so the chart doesn't jump — it keeps
    /// what you see rather than restoring an older hand-set value.
    private var scheduleSourceBinding: Binding<ScheduleSource> {
        Binding {
            store.preferences.scheduleSource
        } set: { newSource in
            store.updateGlobalPreferences { preferences in
                if newSource == .manualTimes, preferences.scheduleSource == .solar {
                    let solar = ColorSchedule.solarAdjustedPreferences(preferences)
                    preferences.coolStartMinutes = solar.coolStartMinutes
                    preferences.sunsetStartMinutes = solar.sunsetStartMinutes
                }
                preferences.scheduleSource = newSource
            }
        }
    }

    /// One of the three time steppers under the chart (Wake / Sunset / Bedtime). Shows the effective
    /// time and nudges it in 15-min steps; editing routes through `timeAnchorBinding`.
    private func timeStepper(_ phase: ColorPhase, title: String, tint: Color) -> some View {
        Stepper(value: timeAnchorBinding(phase), in: ControlRanges.minuteOfDay, step: 15) {
            HStack(spacing: 5) {
                Text(title)
                    .zoomFont(.callout)
                    .foregroundStyle(tint.opacity(0.9))
                Text(MinuteFormatting.label(for: effectivePreferences.startMinutes(for: phase)))
                    .zoomFont(.title3)
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    /// Discrete fade durations for the Fade menu. The stored value is always included so a value set
    /// before the menu existed (the old stepper used 5-min steps, e.g. 50 min) still shows selected.
    private var fadeOptions: [Int] {
        let base = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120]
        let current = store.preferences.transitionMinutes
        return base.contains(current) ? base : (base + [current]).sorted()
    }

    private func fadeLabel(_ minutes: Int) -> String {
        minutes == 0 ? "Instant" : "\(minutes) min"
    }
}
