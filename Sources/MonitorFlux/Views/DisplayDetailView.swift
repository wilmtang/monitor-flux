import SwiftUI

struct DisplayDetailView: View {
    @EnvironmentObject private var store: AppStore
    let display: DisplayInfo
    @State private var advancedExpanded = false

    private var displayPreferences: DisplayPreferences {
        store.displayPreferences(for: display)
    }

    private var gammaSlidersEnabled: Bool {
        store.preferences.gammaEnabled && displayPreferences.gammaControlsEnabled
    }

    var body: some View {
        Form {
            displaySection
            colorSection
            // Brightness/contrast, ordered most-real first: the monitor's own controls stay
            // up top; software (gamma) dimming and the day/night schedule tuck under Advanced.
            realControlsSection
            advancedSection
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(display.name)
    }

    private var displaySection: some View {
        Section("Display") {
            LabeledContent("Name", value: display.name)
            LabeledContent("Kind", value: display.kindLabel)
            LabeledContent("Resolution", value: display.frameDescription)
        }
    }

    private var colorSection: some View {
        Section("Warmth") {
            Toggle("Warm this display", isOn: displayBinding(\.colorEnabled))
                .disabled(!store.preferences.gammaEnabled)
            LabeledContent("Current", value: store.currentTemperature.map { "\($0) K" } ?? "Off")
        }
    }

    /// The display's *real* brightness/contrast — the monitor's own DDC controls, or the
    /// built-in backlight. Shown first because it's the everyday control.
    @ViewBuilder
    private var realControlsSection: some View {
        if display.isBuiltIn {
            Section {
                if store.canUseNativeBrightness(display) {
                    nativeBacklightRow
                    Text("The **real** backlight — the same level the brightness keys change. This is the everyday control; the software and scheduled options below are extras.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("No adjustable backlight", systemImage: "laptopcomputer")
                        .foregroundStyle(.secondary)
                    Text("This panel exposes no backlight API, so use the software (gamma) brightness below, or your keyboard's brightness keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                sectionHeader("Brightness", help: HelpText.backlight, helpTitle: "Backlight")
            }
        } else {
            Section {
                if store.ddcStatus.toolPath != nil {
                    Stepper(value: displayBinding(\.ddcDisplayIndex), in: ControlRanges.ddcDisplayIndex) {
                        LabeledContent("ddcctl display index", value: "\(displayPreferences.ddcDisplayIndex)")
                    }
                }

                hardwareSliderRow(title: "Brightness", icon: "sun.max", value: displayPreferences.hardwareBrightness) {
                    store.setHardwareBrightness($0, for: display)
                }
                hardwareSliderRow(title: "Contrast", icon: "circle.lefthalf.filled", value: displayPreferences.hardwareContrast) {
                    store.setHardwareContrast($0, for: display)
                }
                if store.shouldShowVolumeControl(for: display) {
                    hardwareSliderRow(title: "Volume", icon: "speaker.wave.2.fill", value: displayPreferences.hardwareVolume) {
                        store.setHardwareVolume($0, for: display)
                    }
                }
                if !store.displayHasDetectedAudio(display) {
                    Toggle("Show volume control", isOn: displayBinding(\.forceVolumeControl))
                    Text("No speakers were detected on this monitor, so the volume slider is hidden. Enable this only if it has built-in speakers you control over DDC.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("The monitor's **own** controls, sent over DDC — the real backlight, contrast, and volume, like its physical buttons. This is the everyday control; they send live as you drag.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                sectionHeader("Monitor", help: HelpText.ddc, helpTitle: "Monitor controls (DDC/CI)")
            }
        }
    }

    /// Software dimming + scheduling, collapsed by default so the everyday real brightness /
    /// contrast above stays the focus. Nothing is removed — just tucked behind one disclosure.
    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $advancedExpanded) {
                gammaContent
                Divider()
                    .padding(.vertical, 6)
                scheduleContent
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
            }
        }
    }

    /// Software (gamma) dimming — separate from the real backlight above.
    @ViewBuilder
    private var gammaContent: some View {
        advancedSubheader("Software dimming", help: HelpText.gamma, helpTitle: "Software dimming (gamma)")

        Toggle("Use software dimming", isOn: displayBinding(\.gammaControlsEnabled))
            .disabled(!store.preferences.gammaEnabled)

        gammaSliderRow(title: "Software brightness", keyPath: \.gammaBrightness, range: ControlRanges.gammaBrightnessPercent)
        gammaSliderRow(title: "Software contrast", keyPath: \.gammaContrast, range: ControlRanges.gammaContrastPercent)

        if !store.preferences.gammaEnabled {
            Text("Turn on Warmth on the Schedule screen to use these.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !displayPreferences.gammaControlsEnabled {
            Text("Turn on “Use software dimming” to adjust software brightness and contrast.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Dims the **image** via the color tables — it does not change the real backlight above. Use it to go dimmer than the monitor allows; heavy use can cause banding.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Automatic brightness/contrast on the day–night schedule.
    @ViewBuilder
    private var scheduleContent: some View {
        advancedSubheader("Schedule — automatic", help: HelpText.schedule, helpTitle: "Scheduled brightness & contrast")

        if display.isBuiltIn, store.canUseNativeBrightness(display) {
            // macOS already manages the built-in backlight (auto-brightness, Night Shift);
            // MonitorFlux doesn't schedule it, so it can't fight macOS or jump on launch.
            Text("The built-in display's brightness follows macOS (auto-brightness, Night Shift), so MonitorFlux doesn't schedule it. Brightness/contrast scheduling applies to external monitors.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Toggle("Schedule brightness", isOn: scheduleBinding(\.scheduleBrightness))
            if displayPreferences.scheduleBrightness {
                scheduleTargetRow(title: "Daytime", keyPath: \.dayBrightness)
                scheduleTargetRow(title: "Night", keyPath: \.nightBrightness)
            }

            if !display.isBuiltIn {
                Toggle("Schedule contrast", isOn: scheduleBinding(\.scheduleContrast))
                if displayPreferences.scheduleContrast {
                    scheduleTargetRow(title: "Daytime", keyPath: \.dayContrast)
                    scheduleTargetRow(title: "Night", keyPath: \.nightContrast)
                }
            }

            Text("Automatically eases the real brightness/contrast from a daytime to a night target. A manual change holds until the next phase.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(_ title: String, help: String, helpTitle: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(title: helpTitle, message: help)
        }
    }

    /// Left-aligned sub-header for the Advanced disclosure's two groups. The trailing Spacer keeps
    /// it flush-left (without it the DisclosureGroup centers the row, which read as "off"), and the
    /// top padding stops it from crowding the controls above.
    private func advancedSubheader(_ title: String, help: String, helpTitle: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            InfoButton(title: helpTitle, message: help)
            Spacer()
        }
        .padding(.top, 6)
    }

    private func gammaSliderRow(
        title: String,
        keyPath: WritableKeyPath<DisplayPreferences, Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 108, alignment: .leading)
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

    private var nativeBacklightRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max")
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text("Brightness")
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)
            Slider(
                value: Binding {
                    store.nativeBrightnessValue(for: display) * 100
                } set: { newValue in
                    store.setNativeBrightness(newValue / 100.0, for: display)
                },
                in: 0...100
            )
            Text("\(Int((store.nativeBrightnessValue(for: display) * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
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
                .lineLimit(1)
                .frame(width: 80, alignment: .leading)
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

    /// A target slider (0–100%) for a scheduled day/night value. Editing it re-applies the
    /// schedule immediately so the change previews when that phase is currently active.
    private func scheduleTargetRow(
        title: String,
        keyPath: WritableKeyPath<DisplayPreferences, Int>
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 74, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding {
                    Double(displayPreferences[keyPath: keyPath])
                } set: { newValue in
                    store.updateDisplayPreferences(for: display) { displayPreferences in
                        displayPreferences[keyPath: keyPath] = Int(newValue.rounded())
                            .clamped(to: ControlRanges.hardwarePercent)
                    }
                    store.reapplySchedule(for: display)
                },
                in: Double(ControlRanges.hardwarePercent.lowerBound)...Double(ControlRanges.hardwarePercent.upperBound)
            )
            Text("\(displayPreferences[keyPath: keyPath])%")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
        }
    }

    /// Like `displayBinding`, but re-applies the schedule after the change so toggling it on
    /// (or editing a target) takes effect now instead of at the next minute tick.
    private func scheduleBinding<Value>(
        _ keyPath: WritableKeyPath<DisplayPreferences, Value>
    ) -> Binding<Value> {
        Binding {
            displayPreferences[keyPath: keyPath]
        } set: { newValue in
            store.updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences[keyPath: keyPath] = newValue
            }
            store.reapplySchedule(for: display)
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
