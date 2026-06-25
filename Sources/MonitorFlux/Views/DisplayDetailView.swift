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
            if display.isVirtual {
                // AirPlay/virtual display: no hardware controls and gamma is ignored, so the only
                // thing that works is the overlay-based dimming. Everything else (warmth, DDC
                // contrast/volume, software gamma, schedule) is hidden because it has no effect here.
                airplayBrightnessSection
            } else {
                colorSection
                // Brightness/contrast, ordered most-real first: the monitor's own controls stay
                // up top; software (gamma) dimming and the day/night schedule tuck under Advanced.
                realControlsSection
                advancedSection
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(display.name)
    }

    /// The only control an AirPlay/virtual display supports: overlay (“shade”) dimming, written
    /// through the same software-brightness value the popup uses. 0–100%, darker-only.
    private var airplayBrightnessSection: some View {
        let level = min(100, displayPreferences.gammaBrightness)
        return Section {
            HStack(spacing: 10) {
                Image(systemName: "sun.max")
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text("Brightness")
                    .lineLimit(1)
                    .frame(width: 80, alignment: .leading)
                Slider(
                    value: Binding {
                        Double(level)
                    } set: { newValue in
                        store.updateDisplayPreferences(for: display) { displayPreferences in
                            displayPreferences.gammaBrightness = Int(newValue.rounded())
                                .clamped(to: ControlRanges.hardwarePercent)
                        }
                    },
                    in: 0...100
                )
                Text("\(level)%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            Text("Dimmed with a translucent overlay, since AirPlay/wireless displays have no hardware brightness and ignore gamma. It only goes darker, not brighter.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            sectionHeader("Brightness", help: HelpText.airplayDimming, helpTitle: "AirPlay dimming")
        }
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
            Text(store.preferences.gammaEnabled
                ? "Opt this display into the global warmth schedule and manual warmth changes."
                : "Enable Warmth on the Schedule screen to warm individual displays.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    Text("This is the **real backlight** — the same hardware level as macOS's own brightness control. To go **dimmer than the panel's hardware minimum** (e.g. a dark room), turn on Software dimming under Advanced.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                hardwareSliderRow(title: "Brightness", icon: "sun.max", value: displayPreferences.hardwareBrightness) {
                    store.setHardwareBrightness($0, for: display)
                }

                Text("The monitor's own brightness control, sent over DDC like its physical buttons. Contrast, volume, and DDC details are under Advanced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                sectionHeader("Brightness", help: HelpText.ddc, helpTitle: "Monitor brightness (DDC/CI)")
            }
        }
    }

    /// Software dimming + scheduling, collapsed by default so the everyday real brightness /
    /// contrast above stays the focus. Nothing is removed — just tucked behind one disclosure.
    private var advancedSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.16)) {
                        advancedExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                        Image(systemName: "slider.horizontal.3")
                        Text("Advanced")
                            .font(.headline)
                        Spacer(minLength: 0)
                    }
                    // Order matters: pad and stretch to full width *first*, then take the
                    // content shape last so the entire row — padding and the empty space out
                    // to the trailing edge — is the tap target, not just the label glyphs.
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(advancedExpanded ? "Collapse Advanced" : "Expand Advanced")

                if advancedExpanded {
                    advancedContent
                }
            }
        }
    }

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !display.isBuiltIn {
                monitorAdvancedContent
                advancedDivider
            }
            gammaContent
            advancedDivider
            scheduleContent
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// External monitor controls that matter, but not often enough to crowd the default pane.
    private var monitorAdvancedContent: some View {
        advancedGroup("Monitor extras", help: HelpText.ddc, helpTitle: "Monitor controls (DDC/CI)") {
            if store.ddcStatus.toolPath != nil {
                Stepper(value: displayBinding(\.ddcDisplayIndex), in: ControlRanges.ddcDisplayIndex) {
                    LabeledContent("ddcctl display index", value: "\(displayPreferences.ddcDisplayIndex)")
                }
                .font(.body)
            }

            advancedSliderRow(
                title: "Contrast",
                icon: "circle.lefthalf.filled",
                value: displayPreferences.hardwareContrast,
                range: ControlRanges.hardwarePercent,
                isEnabled: store.canUseDDC(for: display)
            ) {
                store.setHardwareContrast($0, for: display)
            }

            if store.shouldShowVolumeControl(for: display) {
                advancedSliderRow(
                    title: "Volume",
                    icon: "speaker.wave.2.fill",
                    value: displayPreferences.hardwareVolume,
                    range: ControlRanges.hardwarePercent,
                    isEnabled: store.canUseDDC(for: display)
                ) {
                    store.setHardwareVolume($0, for: display)
                }
            }

            if !store.displayHasDetectedAudio(display) {
                advancedToggleRow("Show volume control", isOn: displayBinding(\.forceVolumeControl))
                advancedCaption("No speakers were detected on this monitor. Enable this only if it has built-in speakers controlled over DDC.")
            }

            advancedCaption("Contrast and volume are also monitor-native controls. They send live as you drag.")
        }
    }

    /// Software (gamma) dimming — separate from the real backlight above.
    private var gammaContent: some View {
        advancedGroup("Software dimming", help: HelpText.gamma, helpTitle: "Software dimming (gamma)") {
            advancedToggleRow(
                "Use software dimming",
                isOn: displayBinding(\.gammaControlsEnabled),
                isEnabled: store.preferences.gammaEnabled
            )

            advancedSliderRow(
                title: "Software brightness",
                icon: "sun.max",
                value: displayPreferences.gammaBrightness,
                range: ControlRanges.gammaBrightnessPercent,
                isEnabled: gammaSlidersEnabled
            ) { newValue in
                store.updateDisplayPreferences(for: display) { displayPreferences in
                    displayPreferences.gammaBrightness = newValue
                }
            }

            if !store.preferences.gammaEnabled {
                advancedCaption("Turn on Warmth on the Schedule screen to use this.")
            } else if !displayPreferences.gammaControlsEnabled {
                advancedCaption("Turn on “Use software dimming” to adjust software brightness.")
            } else {
                advancedCaption("Darkens the **image** with the color tables, stacked on top of the real backlight above — so the screen can go **below its hardware-minimum brightness**. It never touches the backlight itself; heavy use can cause slight banding.")
            }
        }
    }

    /// Automatic brightness/contrast on the day–night schedule.
    private var scheduleContent: some View {
        advancedGroup("Schedule — automatic", help: HelpText.schedule, helpTitle: "Scheduled brightness & contrast") {
            if display.isBuiltIn, store.canUseNativeBrightness(display) {
                // macOS already manages the built-in backlight (auto-brightness / ambient sensor);
                // MonitorFlux doesn't schedule it, so it can't fight macOS or jump on launch.
                advancedCaption("The built-in display's brightness is managed by macOS (auto-brightness), so MonitorFlux doesn't schedule it. Brightness/contrast scheduling applies to external monitors.")
            } else {
                advancedToggleRow("Schedule brightness", isOn: scheduleBinding(\.scheduleBrightness))
                if displayPreferences.scheduleBrightness {
                    scheduleChart(
                        dayValue: scheduleBinding(\.dayBrightness),
                        nightValue: scheduleBinding(\.nightBrightness),
                        accent: .scheduleBrightness,
                        name: "Brightness schedule curve"
                    )
                    scheduleSliderRow(title: "Daytime brightness", keyPath: \.dayBrightness)
                    scheduleSliderRow(title: "Night brightness", keyPath: \.nightBrightness)
                }

                if !display.isBuiltIn {
                    advancedToggleRow("Schedule contrast", isOn: scheduleBinding(\.scheduleContrast))
                    if displayPreferences.scheduleContrast {
                        scheduleChart(
                            dayValue: scheduleBinding(\.dayContrast),
                            nightValue: scheduleBinding(\.nightContrast),
                            accent: .scheduleContrast,
                            name: "Contrast schedule curve"
                        )
                        scheduleSliderRow(title: "Daytime contrast", keyPath: \.dayContrast)
                        scheduleSliderRow(title: "Night contrast", keyPath: \.nightContrast)
                    }
                }

                advancedCaption("Eases the real brightness/contrast from the daytime value to the night value on the **same day–night timeline as Warmth** (set on the Schedule screen — wake, bedtime, and fade). A manual change holds until the next phase.")
            }
        }
    }

    private func sectionHeader(_ title: String, help: String, helpTitle: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            InfoButton(title: helpTitle, message: help)
        }
    }

    private func advancedGroup<Content: View>(
        _ title: String,
        help: String,
        helpTitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                InfoButton(title: helpTitle, message: help)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var advancedDivider: some View {
        Divider()
            .padding(.vertical, 2)
    }

    private func advancedToggleRow(
        _ title: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(title)
                .font(.body.weight(.medium))
            Spacer(minLength: 16)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
        }
        .disabled(!isEnabled)
        .padding(.vertical, 3)
    }

    private func advancedSliderRow(
        title: String,
        icon: String?,
        value: Int,
        range: ClosedRange<Int>,
        isEnabled: Bool = true,
        setter: @escaping (Int) -> Void
    ) -> some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.body)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 168, alignment: .leading)
            Slider(
                value: Binding {
                    Double(value)
                } set: { newValue in
                    setter(Int(newValue.rounded()).clamped(to: range))
                },
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .disabled(!isEnabled)
            .layoutPriority(1)
            Text("\(value)%")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    /// A compact day→night curve above the schedule sliders, matching the warmth chart's look at a
    /// smaller size. The handles drag through `scheduleBinding`, so an edit re-applies the schedule
    /// immediately — same as dragging the sliders below.
    private func scheduleChart(
        dayValue: Binding<Int>,
        nightValue: Binding<Int>,
        accent: Color,
        name: String
    ) -> some View {
        HardwareScheduleChart(
            dayValue: dayValue,
            nightValue: nightValue,
            preferences: store.preferences,
            accent: accent,
            accessibilityName: name
        )
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.16))
        )
        .padding(.bottom, 2)
    }

    /// A slider row for a scheduled brightness/contrast day/night target. Re-applies the schedule
    /// on change so edits take effect immediately, not at the next minute tick.
    private func scheduleSliderRow(
        title: String,
        keyPath: WritableKeyPath<DisplayPreferences, Int>
    ) -> some View {
        advancedSliderRow(
            title: title,
            icon: nil,
            value: displayPreferences[keyPath: keyPath],
            range: ControlRanges.hardwarePercent
        ) { newValue in
            store.updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences[keyPath: keyPath] = newValue
            }
            store.reapplySchedule(for: display)
        }
    }

    private func advancedCaption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 30)
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

}
