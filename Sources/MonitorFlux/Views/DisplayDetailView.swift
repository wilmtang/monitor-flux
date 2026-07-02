import SwiftUI

struct DisplayDetailView: View {
    @EnvironmentObject private var store: AppStore
    let display: DisplayInfo
    /// Collapsed by default; `MONITORFLUX_EXPAND_ADVANCED=1` opens it on launch so UI
    /// verification can screenshot the Advanced controls without a click (dev hook only).
    @State private var advancedExpanded =
        ProcessInfo.processInfo.environment["MONITORFLUX_EXPAND_ADVANCED"] == "1"

    private var displayPreferences: DisplayPreferences {
        store.displayPreferences(for: display)
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
        .navigationTitle(display.name)
    }

    /// The only control an AirPlay/virtual display supports: overlay (“shade”) dimming, written
    /// through the same software-brightness value the popup uses. 0–100%, darker-only.
    private var airplayBrightnessSection: some View {
        Section {
            unifiedBrightnessRow
            Text("Dimmed with a translucent overlay, since AirPlay/wireless displays have no hardware brightness and ignore gamma. It only goes darker, not brighter.")
                .zoomFont(.caption)
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
                .settingsSwitch()
                .disabled(!store.preferences.gammaEnabled)
            LabeledContent("Current", value: store.currentTemperature.map(KelvinFormatting.label(for:)) ?? "Off")
            Text(store.preferences.gammaEnabled
                ? "Opt this display into the global warmth schedule and manual warmth changes."
                : "Enable Warmth on the Schedule screen to warm individual displays.")
                .zoomFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The one Brightness slider — the everyday control, on the unified position scale for
    /// every dimming path. Externals get the "Dimming method" picker directly beneath it.
    @ViewBuilder
    private var realControlsSection: some View {
        if display.isBuiltIn {
            Section {
                unifiedBrightnessRow
                brightnessCaption
            } header: {
                sectionHeader("Brightness", help: HelpText.backlight, helpTitle: "Backlight")
            }
        } else {
            Section {
                unifiedBrightnessRow
                dimmingMethodRow
                brightnessCaption
            } header: {
                sectionHeader("Brightness", help: HelpText.ddc, helpTitle: "Monitor brightness (DDC/CI)")
            }
        }
    }

    /// The hero slider, driven by the unified brightness position — the same `MonitorSlider`
    /// as the popup card, so the handoff notch, the dimmed software-zone fill, and the
    /// sun → moon icon swap look identical in both places.
    private var unifiedBrightnessRow: some View {
        let kind = store.brightnessControlKind(for: display)
        let position = store.unifiedBrightness(for: display)
        let notch = kind == .hybrid ? HybridBrightness.handoffFraction : nil
        let inSoftwareZone = notch.map { position < $0 } ?? false
        return HStack(spacing: 10) {
            Text("Brightness")
                .lineLimit(1)
                .frame(width: 108, alignment: .leading)
            MonitorSlider(
                systemImage: inSoftwareZone ? "moon" : "sun.max",
                value: position * 100,
                range: 0...100,
                isEnabled: kind != .unavailable,
                notchFraction: notch
            ) { newValue in
                store.setUnifiedBrightness(newValue / 100.0, for: display)
            }
            Text("\(Int((position * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    /// Segmented per-display choice of *how* the slider dims — externals only (the built-in
    /// keeps its Advanced software-dimming opt-in, and AirPlay has no choice to make).
    private var dimmingMethodRow: some View {
        HStack(spacing: 6) {
            Text("Dimming method")
                .zoomFont(.body)
            InfoButton(title: "Dimming method", message: HelpText.dimmingMethod)
            Spacer(minLength: 12)
            Picker("Dimming method", selection: dimmingModeBinding) {
                ForEach(DimmingMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var dimmingModeBinding: Binding<DimmingMode> {
        Binding {
            store.dimmingMode(for: display)
        } set: { newMode in
            store.setDimmingMode(newMode, for: display)
        }
    }

    /// Mode-aware explanation under the hero slider.
    private var brightnessCaption: some View {
        let text: LocalizedStringKey
        switch store.brightnessControlKind(for: display) {
        case .hybrid:
            text = display.isBuiltIn
                ? "This is the **real backlight** first; keep dragging below the notch and MonitorFlux darkens the **image** in software, dimmer than the panel's hardware minimum."
                : "Uses the monitor's **own brightness** first; keep dragging below the notch to darken the **image** further in software. Contrast and volume are under Advanced."
        case .hardwareOnly:
            text = display.isBuiltIn
                ? "This is the **real backlight** — the same hardware level as macOS's own brightness control. To go **dimmer than the panel's hardware minimum** (e.g. a dark room), turn on Software dimming under Advanced."
                : "The monitor's own brightness control, sent over DDC like its physical buttons. Contrast, volume, and DDC details are under Advanced."
        case .softwareOnly:
            if display.isBuiltIn {
                text = "This panel exposes no backlight API, so MonitorFlux darkens the **image** in software instead."
            } else if store.canUseDDC(for: display) {
                text = "Darkens the **image** in software; the monitor's own brightness is left alone."
            } else {
                text = "This connection doesn't expose the monitor's own brightness (no DDC), so MonitorFlux darkens the **image** in software."
            }
        case .unavailable:
            text = "This connection doesn't expose the monitor's own brightness (no DDC). Choose Automatic or Software dimming to dim the image instead."
        case .shade:
            text = "" // AirPlay renders its own section.
        }
        return Text(text)
            .zoomFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                            .zoomFont(size: 12, weight: .semibold)
                            .rotationEffect(.degrees(advancedExpanded ? 90 : 0))
                        Image(systemName: "slider.horizontal.3")
                        Text("Advanced")
                            .zoomFont(.headline)
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
                .zoomFont(.body)
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

    /// Software (gamma) dimming extras. The built-in keeps its opt-in toggle here (once on,
    /// the main Brightness slider covers the whole range — no separate slider); externals
    /// choose their method with the picker above, so this holds only the raw power-user
    /// slider. Both get the dim-to-black floor override.
    @ViewBuilder
    private var gammaContent: some View {
        if display.isBuiltIn {
            advancedGroup("Software dimming", help: HelpText.softwareDimming, helpTitle: "Software dimming (gamma)") {
                if store.canUseNativeBrightness(display) {
                    advancedToggleRow(
                        "Use software dimming",
                        isOn: softwareDimmingBinding
                    )
                    advancedCaption(store.dimmingMode(for: display) == .hardware
                        ? "Lets the Brightness slider above keep dimming **below the backlight's minimum** by darkening the image in software."
                        : "The Brightness slider above now keeps dimming **below the backlight's minimum** — the stretch left of the notch darkens the image in software.")
                } else {
                    advancedCaption("This panel has no backlight control, so the Brightness slider above always dims in software.")
                }
                dimToBlackRows
            }
        } else {
            advancedGroup("Software dimming", help: HelpText.softwareDimming, helpTitle: "Software dimming (gamma)") {
                advancedSliderRow(
                    title: "Software brightness",
                    icon: "sun.max",
                    value: displayPreferences.gammaBrightness,
                    range: ControlRanges.gammaBrightnessPercent
                ) { newValue in
                    store.updateDisplayPreferences(for: display) { displayPreferences in
                        displayPreferences.gammaBrightness = newValue
                    }
                }
                advancedCaption("The raw image-darkening level — 100% is neutral, and the Brightness slider drives it automatically below the notch. This is the only control that reaches the **100–150% boost** range, and it works in every dimming method. Heavy use can cause slight banding.")
                dimToBlackRows
            }
        }
    }

    /// The floor override for the unified slider: complete black instead of the 15% safety
    /// floor. Hidden while the slider has no software zone to floor (hardware-only modes).
    @ViewBuilder
    private var dimToBlackRows: some View {
        if [.hybrid, .softwareOnly].contains(store.brightnessControlKind(for: display)) {
            advancedToggleRow("Allow dimming to black", isOn: displayBinding(\.dimToBlack))
            advancedCaption("Lets the very bottom of the Brightness slider turn the screen **completely black** instead of stopping at a faintly readable level. Brightness-up keys and the slider still recover it.")
        }
    }

    /// The built-in's software-dimming opt-in, expressed through the dimming mode: off means
    /// backlight-only (which also clears any software dimming), on makes the main slider
    /// hybrid — backlight first, software below the notch.
    private var softwareDimmingBinding: Binding<Bool> {
        Binding {
            store.dimmingMode(for: display) != .hardware
        } set: { isOn in
            store.setDimmingMode(isOn ? .automatic : .hardware, for: display)
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
                        sunsetValue: scheduleBinding(\.sunsetBrightness),
                        nightValue: scheduleBinding(\.nightBrightness),
                        accent: .scheduleBrightness,
                        name: "Brightness schedule curve"
                    )
                    scheduleSliderRow(title: "Daytime brightness", keyPath: \.dayBrightness)
                    scheduleSliderRow(title: "Sunset brightness", keyPath: \.sunsetBrightness)
                    scheduleSliderRow(title: "Night brightness", keyPath: \.nightBrightness)
                }

                if !display.isBuiltIn {
                    advancedToggleRow("Schedule contrast", isOn: scheduleBinding(\.scheduleContrast))
                    if displayPreferences.scheduleContrast {
                        scheduleChart(
                            dayValue: scheduleBinding(\.dayContrast),
                            sunsetValue: scheduleBinding(\.sunsetContrast),
                            nightValue: scheduleBinding(\.nightContrast),
                            accent: .scheduleContrast,
                            name: "Contrast schedule curve"
                        )
                        scheduleSliderRow(title: "Daytime contrast", keyPath: \.dayContrast)
                        scheduleSliderRow(title: "Sunset contrast", keyPath: \.sunsetContrast)
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
                    .zoomFont(.headline)
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
        // A plain Toggle keeps the native row layout (label leading, switch trailing —
        // the pairing settingsSwitch() centers exactly); the leading pad lines the title
        // up with the icon column of the slider rows below.
        Toggle(isOn: isOn) {
            Text(title)
                .zoomFont(.body, weight: .medium)
                .padding(.leading, 30)
        }
        .settingsSwitch()
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
                    .zoomFont(size: 13, weight: .medium)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            Text(title)
                .zoomFont(.body)
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
                .monospacedDigit()
                .zoomFont(.body)
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
        sunsetValue: Binding<Int>,
        nightValue: Binding<Int>,
        accent: Color,
        name: String
    ) -> some View {
        HardwareScheduleChart(
            dayValue: dayValue,
            sunsetValue: sunsetValue,
            nightValue: nightValue,
            preferences: store.preferences,
            accent: accent,
            accessibilityName: name
        )
        .background(
            // Semantic fill so the card reads in both appearances — flat white was
            // invisible against a light window background.
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
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
            .zoomFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 30)
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
