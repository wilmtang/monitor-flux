import SwiftUI

struct DisplayDetailView: View {
    @EnvironmentObject private var store: AppStore
    let display: DisplayInfo
    /// Dev hook: `MONITORFLUX_EXPAND_ADVANCED=1` forces Advanced open on launch so UI verification
    /// can screenshot those controls without flipping the switch.
    private let forceAdvancedOpen =
        ProcessInfo.processInfo.environment["MONITORFLUX_EXPAND_ADVANCED"] == "1"

    /// Whether the Advanced block is revealed. Backed by a persisted global preference (so it
    /// stays put across displays and launches until the user flips it again), or forced by the
    /// dev hook above.
    private var advancedShown: Bool {
        store.preferences.showsAdvancedControls || forceAdvancedOpen
    }

    private var displayPreferences: DisplayPreferences {
        store.displayPreferences(for: display)
    }

    var body: some View {
        // Wrapped in a ScrollViewReader so the `MONITORFLUX_SCROLL_TO` screenshot hook can bring a
        // below-the-fold section into view on launch — capturing the schedule charts etc. by window
        // id then needs no live-UI scrolling. Inert without the env var.
        ScrollViewReader { proxy in
            Form {
                displaySection
                if display.isVirtual {
                    // AirPlay/virtual display: no hardware controls and gamma is ignored, so the only
                    // thing that works is the overlay-based dimming. Everything else (warmth, DDC
                    // contrast/volume, software gamma, schedule) is hidden because it has no effect here.
                    airplayBrightnessSection.id(ScrollAnchor.brightness)
                } else {
                    colorSection.id(ScrollAnchor.warmth)
                    // Brightness, then contrast in its own section, ordered most-real first: the
                    // monitor's own controls stay up top; software (gamma) dimming and the day/night
                    // schedule tuck under Advanced.
                    realControlsSection.id(ScrollAnchor.brightness)
                    contrastSection
                    advancedSection.id(ScrollAnchor.advanced)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(display.name)
            .onAppear { scrollToLaunchTarget(using: proxy) }
        }
    }

    /// Named scroll targets for the `MONITORFLUX_SCROLL_TO` launch hook.
    private enum ScrollAnchor {
        static let warmth = "warmth"
        static let brightness = "brightness"
        static let advanced = "advanced"
        static let schedule = "schedule"
    }

    /// Screenshot hook: `MONITORFLUX_SCROLL_TO=<anchor>` scrolls a named section into view shortly
    /// after launch, so below-the-fold content (e.g. the schedule charts) can be captured by window
    /// id with no live-UI control. Anchors: `warmth`, `brightness`, `advanced`, `schedule`. Pair
    /// with `MONITORFLUX_EXPAND_ADVANCED=1` when the target lives inside Advanced. Read once.
    private func scrollToLaunchTarget(using proxy: ScrollViewProxy) {
        guard let anchor = ProcessInfo.processInfo.environment["MONITORFLUX_SCROLL_TO"],
              !anchor.isEmpty else { return }
        // Defer past the grouped Form's initial layout (and any expanded Advanced block); a
        // scrollTo to an id that hasn't materialized yet is a silent no-op. Two nudges cover the
        // case where the first fires before the rows exist.
        for delay in [0.4, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    /// The only control an AirPlay/virtual display supports: overlay (“shade”) dimming, written
    /// through the same software-brightness value the popup uses. 0–100%, darker-only.
    private var airplayBrightnessSection: some View {
        Section {
            unifiedBrightnessRow
            Text("Dimmed with an overlay — wireless displays have no hardware brightness. Darker only, not brighter.")
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
                .disabled(store.preferences.colorMode == .off)
            LabeledContent("Current", value: store.currentTemperature.map(KelvinFormatting.label(for:)) ?? "Off")
            Text(store.preferences.colorMode != .off
                ? "Include this display in warmth changes."
                : "Turn on warmth in Schedule to warm individual displays.")
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

    /// Contrast stands in its own section — like Warmth — rather than riding under the
    /// Brightness slider. A monitor-native DDC control, so it's shown only for wired externals
    /// whose panel answers DDC.
    @ViewBuilder
    private var contrastSection: some View {
        if !display.isBuiltIn, store.canUseDDC(for: display) {
            Section {
                contrastRow
            } header: {
                sectionHeader("Contrast", help: HelpText.contrast, helpTitle: "Monitor contrast (DDC/CI)")
            }
        }
    }

    /// Contrast — a monitor-native DDC control. Same `MonitorSlider` + label/readout columns as
    /// the Brightness hero row, so the two tracks share their left/right edges.
    private var contrastRow: some View {
        let zoomScale = store.preferences.settingsZoomScale
        return HStack(spacing: 10) {
            Text("Contrast")
                .lineLimit(1)
                .frame(width: (108 * zoomScale).rounded(), alignment: .leading)
            MonitorSlider(
                systemImage: "circle.lefthalf.filled",
                label: "Contrast",
                value: Double(displayPreferences.hardwareContrast),
                range: Double(ControlRanges.hardwarePercent.lowerBound)...Double(ControlRanges.hardwarePercent.upperBound)
            ) { newValue in
                store.setHardwareContrast(Int(newValue.rounded()), for: display)
            }
            Text("\(displayPreferences.hardwareContrast)%")
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: (44 * zoomScale).rounded(), alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    /// The hero slider, driven by the unified brightness position — the same `MonitorSlider`
    /// as the popup card, so the handoff notch, the dimmed software-zone fill, and the
    /// sun → moon icon swap look identical in both places.
    private var unifiedBrightnessRow: some View {
        let kind = store.brightnessControlKind(for: display)
        let position = store.unifiedBrightness(for: display)
        let notch = kind == .hybrid ? HybridBrightness.handoffFraction : nil
        let inSoftwareZone = notch.map { position < $0 } ?? false
        // The label/readout columns scale with the zoom — fixed at 13 pt metrics, "100%"
        // wraps into two stacked lines at higher zoom steps.
        let zoomScale = store.preferences.settingsZoomScale
        return HStack(spacing: 10) {
            Text("Brightness")
                .lineLimit(1)
                .frame(width: (108 * zoomScale).rounded(), alignment: .leading)
            MonitorSlider(
                systemImage: inSoftwareZone ? "moon" : "sun.max",
                label: "Brightness",
                value: position * 100,
                range: 0...100,
                isEnabled: kind != .unavailable,
                notchFraction: notch
            ) { newValue in
                store.setUnifiedBrightness(newValue / 100.0, for: display)
            }
            Text("\(Int((position * 100).rounded()))%")
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: (44 * zoomScale).rounded(), alignment: .trailing)
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
            text = "Uses the monitor's **own brightness** first; drag below the notch to darken the **image** in software."
        case .hardwareOnly:
            text = display.isBuiltIn
                ? "The **real backlight**, same as macOS's brightness control. To dim the **image** instead, turn on Software dimming under Advanced."
                : "The monitor's own brightness, sent over the cable like its physical buttons."
        case .softwareOnly:
            if display.isBuiltIn {
                text = store.canUseNativeBrightness(display)
                    ? "Darkens the **image** in software; the **backlight stays put** (keyboard keys still control it). Switch back under Advanced."
                    : "This panel has no backlight control, so brightness dims the **image** in software."
            } else if store.canUseDDC(for: display) {
                text = "Darkens the **image** in software; the monitor's own brightness is left alone."
            } else {
                text = "No DDC on this connection, so brightness dims the **image** in software."
            }
        case .unavailable:
            text = "No DDC on this connection. Switch to Software dimming to dim the **image** instead."
        case .shade:
            text = "" // AirPlay renders its own section.
        }
        return Text(text)
            .zoomFont(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Software dimming + scheduling, hidden by default so the everyday real brightness /
    /// contrast above stays the focus. A switch reveals it — and, being a persisted preference,
    /// it stays revealed across displays and launches until flipped off. Nothing is removed.
    private var advancedSection: some View {
        Section {
            Toggle(isOn: advancedShownBinding) {
                HStack(spacing: 12) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                    Text("Show Advanced Settings")
                        .zoomFont(.headline)
                }
            }
            .settingsSwitch()
            .padding(.vertical, 2)

            if advancedShown {
                advancedContent
            }
        }
    }

    /// Drives the Advanced switch: reads/writes the persisted preference, animating the reveal so
    /// the block slides in rather than snapping. The dev hook can force the content open without
    /// touching the stored value, so the switch still reflects the real preference.
    private var advancedShownBinding: Binding<Bool> {
        Binding {
            store.preferences.showsAdvancedControls
        } set: { newValue in
            withAnimation(.snappy(duration: 0.16)) {
                store.updateGlobalPreferences { $0.showsAdvancedControls = newValue }
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
                .id(ScrollAnchor.schedule)
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
                advancedToggleRow("Show volume control", icon: "speaker.wave.2.fill", isOn: displayBinding(\.forceVolumeControl))
                advancedCaption("No speakers detected. Turn on only if this monitor has built-in speakers.")
            }

            advancedCaption("Volume is a monitor-native control, sent live as you drag.")
        }
    }

    /// Software (gamma) dimming extras. The built-in keeps its binary toggle here — off, the
    /// main Brightness slider is the real backlight; on, it dims purely in software and the
    /// backlight stays put (no hybrid, no separate slider). Externals choose their method
    /// with the picker above, so this holds only the raw power-user slider. Both get the
    /// dim-to-black floor override.
    @ViewBuilder
    private var gammaContent: some View {
        if display.isBuiltIn {
            advancedGroup("Software dimming", help: HelpText.builtInDimmingChoice, helpTitle: "Software dimming (gamma)") {
                if store.canUseNativeBrightness(display) {
                    advancedToggleRow(
                        "Use software dimming",
                        isOn: softwareDimmingBinding
                    )
                    advancedCaption(store.dimmingMode(for: display) == .hardware
                        ? "Dims the **image** instead of the **backlight**, which stays put. Worth trying if low backlight levels strain your eyes — many panels flicker more the dimmer they get."
                        : "The Brightness slider now dims the **image**; the **backlight stays put** (keyboard keys still control it). Turn off to drive the backlight directly.")
                } else {
                    advancedCaption("This panel has no backlight control, so brightness always dims the image.")
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
                advancedCaption("The raw image level — 100% is neutral; the Brightness slider drives it below the notch. The only way to **boost past 100%** for a dim panel. Heavy use can cause slight banding.")
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
            advancedCaption("Lets the bottom of the Brightness slider go **fully black** instead of stopping at a dim, readable level. The slider and brightness keys still recover it.")
        }
    }

    /// The built-in's binary dimming choice, expressed through the dimming mode: off means
    /// backlight-only (which also clears any software dimming), on hands the whole slider
    /// to software dimming — the backlight is left exactly where it is. Never hybrid.
    private var softwareDimmingBinding: Binding<Bool> {
        Binding {
            store.dimmingMode(for: display) != .hardware
        } set: { isOn in
            store.setDimmingMode(isOn ? .software : .hardware, for: display)
        }
    }

    /// Automatic brightness/contrast on the day–night schedule.
    private var scheduleContent: some View {
        advancedGroup("Schedule — automatic", help: HelpText.schedule, helpTitle: "Scheduled brightness & contrast") {
            if display.isBuiltIn, store.canUseNativeBrightness(display) {
                // macOS already manages the built-in backlight (auto-brightness / ambient sensor);
                // MonitorFlux doesn't schedule it, so it can't fight macOS or jump on launch.
                advancedCaption("macOS manages the built-in brightness (auto-brightness), so it isn't scheduled. Scheduling applies to external monitors.")
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

                // Contrast is DDC-only, so a non-DDC monitor can't schedule it — hide the toggle
                // rather than offer a control whose writes are silently dropped.
                if !display.isBuiltIn, store.canUseDDC(for: display) {
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

                advancedCaption(scheduleCaption)
            }
        }
    }

    /// The schedule explainer, with the unified-target hint when this display's scheduled
    /// brightness can continue below the hardware minimum (Automatic dimming on a DDC panel).
    private var scheduleCaption: LocalizedStringKey {
        let base = "Eases brightness/contrast from the daytime value to the night value on the **same times as Warmth** (set in Schedule). A manual change holds until the next phase."
        if store.brightnessControlKind(for: display) == .hybrid, !display.isBuiltIn {
            return LocalizedStringKey(base + " A target below the notch keeps dimming in software.")
        }
        return LocalizedStringKey(base)
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

    /// Leading pad that lines Advanced titles/captions up with the slider rows' icon column
    /// (its scaled 18 pt frame + the 12 pt row spacing).
    private var advancedLeadingPad: CGFloat {
        (18 * store.preferences.settingsZoomScale).rounded() + 12
    }

    private func advancedToggleRow(
        _ title: String,
        icon: String? = nil,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        // A plain Toggle keeps the native row layout (label leading, switch trailing —
        // the pairing settingsSwitch() centers exactly). With an icon, it fills the same
        // 18 pt column as the slider rows; without one, a leading pad lines the title up
        // with that column either way.
        let zoomScale = store.preferences.settingsZoomScale
        return Toggle(isOn: isOn) {
            if let icon {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .zoomFont(size: 13, weight: .medium)
                        .frame(width: (18 * zoomScale).rounded())
                        .foregroundStyle(.secondary)
                    Text(title)
                        .zoomFont(.body, weight: .medium)
                }
            } else {
                Text(title)
                    .zoomFont(.body, weight: .medium)
                    .padding(.leading, advancedLeadingPad)
            }
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
        // Columns scale with the zoom, like the hero row's — fixed 13 pt metrics wrap the
        // readout and overflow the icon frame at higher zoom steps.
        let zoomScale = store.preferences.settingsZoomScale
        return HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .zoomFont(size: 13, weight: .medium)
                    .frame(width: (18 * zoomScale).rounded())
                    .foregroundStyle(.secondary)
            } else {
                Color.clear
                    .frame(width: (18 * zoomScale).rounded())
                    .accessibilityHidden(true)
            }
            Text(title)
                .zoomFont(.body)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: (168 * zoomScale).rounded(), alignment: .leading)
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
                .lineLimit(1)
                .frame(width: (52 * zoomScale).rounded(), alignment: .trailing)
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
            schedule: ColorSchedule.resolved(preferences: store.preferences),
            accent: accent,
            accessibilityName: name
        )
        .background(
            // Semantic fill so the card reads in both appearances — flat white was
            // invisible against a light window background.
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
        )
        // Line the chart's left edge up with the toggles and sliders around it (which sit in
        // the icon column). Without this the chart bled the full width and jutted out to the left.
        .padding(.leading, advancedLeadingPad)
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
            .padding(.leading, advancedLeadingPad)
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
