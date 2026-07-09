// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import SwiftUI

struct ColorScheduleView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedPhase: ColorPhase = .daytime

    var body: some View {
        // ScrollViewReader mirrors DisplayDetailView: the `MONITORFLUX_SCROLL_TO=schedule`
        // screenshot hook brings the below-the-fold schedule section (the Location rows) into
        // view on launch. Inert without the env var.
        ScrollViewReader { proxy in
            form
                .onAppear { scrollToLaunchTarget(using: proxy) }
        }
    }

    // One grouped form for the whole pane: the hero (slider + curve) is the first card, so its
    // edges line up with the setting cards below at every window width — no hand-tuned padding to
    // drift out of sync — and the pane has a single scroll view instead of a Form nested in one.
    private var form: some View {
        Form {
            Section {
                hero
                    .listRowInsets(EdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18))
            }

            // The shared day-and-night timeline: the times, source, and fade that Warmth (when
            // Automatic) AND each monitor's scheduled brightness/contrast all ride. It's always
            // shown — those channels are independent, so hiding it based on Warmth's mode would
            // strand a scheduled brightness on times you can't see.
            scheduleSection
                .id("schedule")

            Section {
                Button {
                    store.disableColorAndRestore()
                } label: {
                    Label("Turn off warmth & reset colors", systemImage: "arrow.uturn.backward.circle")
                }
                .settingsPushButton()
                .help("Turns warmth off everywhere and restores original colors — use this if colors look wrong or another color app should take over.")
                Text("Turns warmth off everywhere and restores each display's original colors.")
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
            // Opening the pane is the moment the traveling hint is readable — re-evaluate it
            // (cheap, and a no-op publish when nothing changed).
            store.refreshLocationMismatch()
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

                InfoButton(title: "What is warmth?", message: HelpText.gamma)

                Spacer()

                Picker("Mode", selection: preferenceBinding(\.colorMode)) {
                    ForEach(ColorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            // The hero is Warmth-only now: Off shows nothing to set, Fixed shows one slider,
            // Automatic shows the warmth curve. The shared times live in their own section below
            // so they stay reachable in every mode.
            if store.preferences.colorMode == .off {
                Text("Warmth is off. Choose Fixed for a constant warmth, or Automatic to follow the schedule below.")
                    .zoomFont(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // One row — Fixed/phase label, slider, Kelvin readout — the same shape as System
                // Settings' Night Shift color-temperature row.
                HStack(spacing: 12) {
                    Text(editingLabel)
                        .zoomFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Slider(value: temperatureSliderBinding, in: Double(ControlRanges.kelvin.lowerBound)...Double(ControlRanges.kelvin.upperBound))
                        .layoutPriority(1)
                    Text(KelvinFormatting.label(for: editedTemperature))
                        .zoomFont(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }

                if isFixed {
                    Text("Holds one warmth around the clock. Automatic follows the schedule below instead.")
                        .zoomFont(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 4) {
                        Picker("Phase", selection: $selectedPhase) {
                            ForEach(ColorPhase.allCases) { phase in
                                Text(phase.label).tag(phase)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 380)
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
                        schedule: schedule,
                        timesLocked: followsSunset,
                        wakeTickMinute: wakeTickMinute,
                        previewMinute: store.schedulePreviewMinute,
                        onPreview: { store.previewScheduleColor(atMinute: $0) },
                        onTimeEdit: { phase, minute in commitTimeEdit(phase, rawMinute: minute) }
                    )
                    .background(
                        // Semantic fill so the card reads in both appearances — flat white was
                        // invisible against a light window background.
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.quaternary)
                    )

                    curveLegend
                }
            }

            if store.showsGammaConflictBanner {
                GammaConflictBanner(
                    appNames: store.gammaConflictApps,
                    onClose: { store.dismissGammaConflictBanner() }
                )
            }
        }
    }

    /// The shared day-and-night timeline: the phase times, their source (Set times / Follow
    /// sunset), and the fade. Warmth (when Automatic) and every monitor's scheduled brightness
    /// and contrast ride these, so the section is always shown regardless of Warmth's mode —
    /// hiding it would strand a scheduled brightness on times the user can no longer see.
    private var scheduleSection: some View {
        Section("Day & night schedule") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                timeStepper(.daytime, title: "Wake", tint: .phaseDaytime)
                Spacer(minLength: 8)
                timeStepper(.sunset, title: "Sunset", tint: .phaseSunset)
                Spacer(minLength: 8)
                timeStepper(.bedtime, title: "Bedtime", tint: .phaseBedtime)
            }

            Picker("Schedule from", selection: scheduleSourceBinding) {
                ForEach(ScheduleSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)

            if followsSunset {
                Text("Timed from your location and wake time: daytime while the sun's up, sunset warmth after sundown, bedtime warmth before sleep. Computed on-device.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Bedtime starts", selection: preferenceBinding(\.bedtimeLeadMinutes)) {
                    ForEach(bedtimeLeadOptions, id: \.self) { minutes in
                        Text(bedtimeLeadLabel(minutes)).tag(minutes)
                    }
                }
                Text("f.lux's rule: about 8 hours of sleep plus an hour to wind down.")
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Mornings", selection: preferenceBinding(\.morningStart)) {
                    ForEach(MorningStart.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text(morningCaption)
                    .zoomFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Location only feeds the sun math, so these rows belong to Follow-sunset.
                LocationField()

                if let mismatch = store.locationMismatch {
                    // Traveling: the Mac's clock and the schedule's place disagree. A hint
                    // only — the searched location is never overwritten without the user.
                    WarningCard(
                        title: "Traveling?",
                        message: "Your Mac's clock is set to \(mismatch.systemClockLabel) time, "
                            + "but the sunset schedule follows \(store.preferences.locationDisplayLabel).",
                        onClose: { store.dismissLocationMismatch() },
                        closeHelp: "Dismiss. Reappears if your Mac's time zone changes again."
                    ) {
                        Button("Use my location") {
                            store.requestLocation()
                        }
                    }
                }

                Button {
                    store.requestLocation()
                } label: {
                    Label("Use my location", systemImage: "location")
                }
                .settingsPushButton()
                LabeledContent("Location access", value: store.locationStatus)

                LabeledContent("Sun today", value: sunTodayLabel)
            }

            Picker("Fade", selection: preferenceBinding(\.transitionMinutes)) {
                ForEach(fadeOptions, id: \.self) { minutes in
                    Text(fadeLabel(minutes)).tag(minutes)
                }
            }

            Text("Warmth (when Automatic), and each monitor's scheduled brightness & contrast, all follow these times.")
                .zoomFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        guard store.preferences.colorMode != .off else {
            return "Warmth is off"
        }
        // The day/night headlines describe the schedule; Fixed has neither, so give it its own.
        if isFixed {
            return "Fixed warmth"
        }
        return liveTemperature >= 5200 ? "The sun is up — go outside!" : "Warming down for the night"
    }

    /// A glyph that mirrors the headline: a sun by day, a warm moon at night, dimmed when
    /// color warming is off — instead of the abstract two-tone disc it replaces.
    private var statusIcon: (symbol: String, color: Color) {
        guard store.preferences.colorMode != .off else {
            return ("moon.zzz.fill", .secondary)
        }
        return liveTemperature >= 5200
            ? ("sun.max.fill", .phaseDaytime)
            : ("moon.stars.fill", .phaseBedtime)
    }

    private var scheduleSummary: String {
        // Read the resolved day so the summary matches the chart and steppers when following the
        // sun. "Wake" is the wake *input* — not the daytime start, which sunrise mornings put at
        // the sunrise itself.
        let wake = MinuteFormatting.label(for: schedule.wakeMinutes)
        let bed = MinuteFormatting.label(for: schedule.bedtimeStartMinutes)
        return "Wake \(wake), bedtime \(bed) (\(KelvinFormatting.label(for: liveTemperature)))"
    }

    /// Both solar times on one row ("↑ 5:12 AM · ↓ 9:11 PM") — sunrise matters now that
    /// f.lux-style mornings brighten at the real sunrise.
    private var sunTodayLabel: String {
        guard let times = store.solarTimes,
              let sunrise = times.sunriseMinutes,
              let sunset = times.sunsetMinutes
        else {
            return "—"
        }
        return "↑ \(MinuteFormatting.label(for: sunrise)) · ↓ \(MinuteFormatting.label(for: sunset))"
    }

    private var morningCaption: String {
        switch store.preferences.morningStart {
        case .sunrise:
            "Stays warm until the sun is really up, even after you wake (like f.lux)."
        case .wakeTime:
            "Brightens to daytime when you wake, even if it's still dark outside."
        }
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
                Text(followsSunset
                    ? "Drag the time line to preview · dots set warmth · times follow the sun"
                    : "Drag the time line to preview · drag a dot to set its warmth")
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

    /// Like `preferenceBinding`, but editing the value also adopts Automatic (turning warmth on if
    /// it was Off). Only the warmth *phase temperatures* (the curve dots) use this: dragging a
    /// warmth value means you want the warmth schedule. The shared timeline controls (times, source,
    /// fade, bedtime lead, mornings) deliberately use plain `preferenceBinding` — they feed
    /// brightness and contrast schedules too, so editing them must NOT change Warmth's mode.
    private func scheduleEditBinding<Value>(
        _ keyPath: WritableKeyPath<AppPreferences, Value>
    ) -> Binding<Value> {
        Binding {
            store.preferences[keyPath: keyPath]
        } set: { newValue in
            store.updateGlobalPreferences { preferences in
                preferences[keyPath: keyPath] = newValue
                preferences.colorMode = .clock
            }
        }
    }

    /// A binding for a phase's start *time*, shared by the curve handle and the time stepper.
    ///
    /// Read returns the *displayed* anchor from the resolved day — derived from the sun and the
    /// wake time in Follow-sunset mode — so the chart, dots, and steppers all show what's
    /// actually applied. Write commits the edit via `commitTimeEdit`.
    private func timeAnchorBinding(_ phase: ColorPhase) -> Binding<Int> {
        Binding {
            displayedMinutes(for: phase)
        } set: { newValue in
            commitTimeEdit(phase, rawMinute: newValue)
        }
    }

    /// Today's schedule as the engine applies it (solar-resolved in Follow-sunset mode).
    private var schedule: ResolvedSchedule {
        ColorSchedule.resolved(preferences: store.preferences)
    }

    private var followsSunset: Bool {
        store.preferences.scheduleSource == .solar
    }

    /// Screenshot hook (same contract as DisplayDetailView's): `MONITORFLUX_SCROLL_TO=schedule`
    /// scrolls the Day & night section into view shortly after launch. Two nudges, since a
    /// scrollTo before the grouped Form materializes its rows is a silent no-op.
    private func scrollToLaunchTarget(using proxy: ScrollViewProxy) {
        guard let anchor = ProcessInfo.processInfo.environment["MONITORFLUX_SCROLL_TO"],
              !anchor.isEmpty else { return }
        for delay in [0.4, 0.9] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    /// Fixed mode: one constant warmth, so the hero shows just the slider and a one-line
    /// explainer — the warmth *curve* (phases, chart, legend) hides, since a constant has no
    /// phases. The shared Day & night schedule section stays put in every mode; it drives
    /// brightness and contrast schedules too, not only warmth.
    private var isFixed: Bool {
        store.preferences.colorMode == .manual
    }

    /// The wake marker on the chart — only when the daytime handle sits elsewhere (sunrise
    /// mornings put it on the sunrise), so the one time the user controls stays visible.
    private var wakeTickMinute: Int? {
        guard followsSunset, schedule.followsSun,
              schedule.wakeMinutes != schedule.dayStartMinutes
        else {
            return nil
        }
        return schedule.wakeMinutes
    }

    /// The time shown for a phase's row/handle. The daytime row is titled "Wake" and shows the
    /// wake *input* — in Follow-sunset sunrise mornings the daytime color actually starts at
    /// sunrise, but the row edits (and must display) the wake time.
    private func displayedMinutes(for phase: ColorPhase) -> Int {
        switch phase {
        case .daytime:
            schedule.wakeMinutes
        case .sunset:
            schedule.sunsetMinutes
        case .bedtime:
            schedule.bedtimeStartMinutes
        }
    }

    /// Commit a phase time edit (from a dragged curve dot or a stepper). These are the shared
    /// timeline anchors that brightness and contrast schedules also ride, so editing one must NOT
    /// touch Warmth's mode — adjusting Wake for a scheduled brightness shouldn't flip Warmth from
    /// Fixed/Off into Automatic. (The warmth curve dots that call this only appear in Automatic
    /// anyway, so nothing regresses there.)
    ///
    /// While following the sun only the wake input is editable, and it lands unclamped — night
    /// shifts are legal, bedtime rides along at a fixed lead, and the resolver sorts the day out.
    /// Set-times edits clamp into the daytime → sunset → bedtime cyclic order.
    private func commitTimeEdit(_ phase: ColorPhase, rawMinute: Int) {
        store.updateGlobalPreferences { preferences in
            if preferences.scheduleSource == .solar {
                guard phase == .daytime else {
                    return // sunset and bedtime are derived; their controls are disabled
                }
                // Wrap rather than clamp so a wake near midnight can step across into the AM
                // (night shifts are legal here — the resolver sorts the day out).
                preferences.coolStartMinutes = ((rawMinute % 1440) + 1440) % 1440
            } else {
                let clamped = ColorSchedule.clampedStartMinute(rawMinute, for: phase, preferences: preferences)
                preferences.setStartMinutes(clamped, for: phase)
            }
        }
    }

    /// The "Schedule from" binding. Switching from Follow-sunset to Set times freezes today's
    /// derived sunset *and bedtime* into the stored anchors, so the chart doesn't jump — it keeps
    /// the schedule you can see rather than restoring older hand-set values. Wake is never
    /// overwritten: it's the same input in both modes (on sunrise mornings the visible day start
    /// moves from the sunrise back to the wake time — "set times" means your times, not a sun
    /// snapshot). The frozen bedtime re-clamps so a squeezed day can't leave the anchors out of
    /// cyclic order.
    private var scheduleSourceBinding: Binding<ScheduleSource> {
        Binding {
            store.preferences.scheduleSource
        } set: { newSource in
            store.updateGlobalPreferences { preferences in
                if newSource == .manualTimes, preferences.scheduleSource == .solar {
                    let resolved = ColorSchedule.resolved(preferences: preferences)
                    // Land the raw derived values, then re-clamp each against the *new*
                    // neighbors: a squeezed day (or a night-shift wake) can put them out of
                    // the cyclic order Set-times requires.
                    preferences.warmStartMinutes = resolved.bedtimeStartMinutes
                    preferences.sunsetStartMinutes = ColorSchedule.clampedStartMinute(
                        resolved.sunsetMinutes,
                        for: .sunset,
                        preferences: preferences
                    )
                    preferences.warmStartMinutes = ColorSchedule.clampedStartMinute(
                        resolved.bedtimeStartMinutes,
                        for: .bedtime,
                        preferences: preferences
                    )
                }
                preferences.scheduleSource = newSource
            }
            // Following the sun needs real coordinates — prompt on the first switch so the
            // schedule doesn't silently run on the shipped default (Seattle) location.
            if newSource == .solar {
                store.requestLocationIfNeverAsked()
            }
            // The traveling hint only applies to Follow-sunset: entering evaluates it,
            // leaving clears it.
            store.refreshLocationMismatch()
        }
    }

    /// One of the three time rows under the chart (Wake / Sunset / Bedtime), stepping in 15-min
    /// increments. While following the sun only Wake stays editable — sunset and bedtime are
    /// derived, so their steppers disable, keeping their hue at reduced strength (the value is
    /// still worth reading; it just isn't yours to type).
    private func timeStepper(_ phase: ColorPhase, title: String, tint: Color) -> some View {
        let locked = followsSunset && phase != .daytime
        // Build the row by hand rather than with `Stepper`'s own label: a labelled Stepper
        // stretches, parking its chevrons at the cell's trailing edge, far from the time they
        // change. A labels-hidden Stepper is just the chevrons, so the whole group hugs tight —
        // "Wake 7:00 AM ⌃⌄" reads as one unit.
        let minute = displayedMinutes(for: phase)
        return HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .zoomFont(.callout)
                    .foregroundStyle(tint.opacity(locked ? 0.5 : 0.9))
                // Reserve the column at a two-digit-hour width so the chevrons don't jump
                // when the hour shrinks (12:00 → 1:00). The hidden placeholder keeps the same
                // AM/PM as the value; the real time left-aligns inside the fixed slot.
                Text(MinuteFormatting.label(for: widestSizingMinute(for: minute)))
                    .zoomFont(.title3)
                    .monospacedDigit()
                    .hidden()
                    .overlay(alignment: .leading) {
                        Text(MinuteFormatting.label(for: minute))
                            .zoomFont(.title3)
                            .foregroundStyle(tint.opacity(locked ? 0.55 : 1))
                            .monospacedDigit()
                    }
            }
            .lineLimit(1)
            // Not `Stepper(value:in:)`: a bounded stepper clamps to 0…1439 and disables its
            // up-arrow at 11:59 PM, so bedtime (whose legal arc wraps past midnight into the
            // early AM) got stuck at the top of the day. Step the raw minute instead and let
            // `commitTimeEdit`'s cyclic clamp normalize the wrap.
            Stepper("",
                    onIncrement: { commitTimeEdit(phase, rawMinute: minute + 15) },
                    onDecrement: { commitTimeEdit(phase, rawMinute: minute - 15) })
                .labelsHidden()
                .disabled(locked)
        }
        .fixedSize()
    }

    /// A minute whose time label is the widest the column can show for `minute`'s half of the
    /// day: a two-digit hour (10:00) in the same AM/PM. With `.monospacedDigit()` every
    /// two-digit-hour time is the same width, so reserving this keeps the stepper chevrons put
    /// when the hour narrows to one digit. 12-hour and 24-hour locales both hold steady.
    private func widestSizingMinute(for minute: Int) -> Int {
        let normalized = ((minute % 1440) + 1440) % 1440
        return normalized < 720 ? 600 : 1320 // 10:00 AM · 10:00 PM
    }

    /// Discrete "Bedtime starts" leads: 4–12 h in 30-min steps. The stored value is always
    /// included so an off-grid one still shows selected (mirrors `fadeOptions`).
    private var bedtimeLeadOptions: [Int] {
        let base = Array(stride(
            from: ControlRanges.bedtimeLeadMinutes.lowerBound,
            through: ControlRanges.bedtimeLeadMinutes.upperBound,
            by: 30
        ))
        let current = store.preferences.bedtimeLeadMinutes
        return base.contains(current) ? base : (base + [current]).sorted()
    }

    private func bedtimeLeadLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        let duration = rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
        return "\(duration) before wake"
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
