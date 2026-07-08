// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import AppKit
import SwiftUI

/// The MonitorControl-style popup shown from the menu bar: per-display brightness, contrast,
/// and volume, plus a global f.lux-style ambience (color temperature) control. Detailed
/// configuration lives in the on-demand window opened from the footer.
struct QuickControlsView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ambienceCard

            if store.displays.isEmpty {
                emptyHint("No displays detected — connect a monitor to control its brightness and color here.")
            } else {
                DisplayCardsList(displays: store.orderedDisplays)
                // Only the built-in panel is present: name what the user would gain by plugging
                // a monitor in, instead of leaving the area looking like nothing's missing.
                // Once read it's noise, so its ✕ hides it for good.
                if !store.displays.contains(where: { !$0.isBuiltIn }),
                   !store.preferences.hideNoExternalsHint {
                    emptyHint("No external monitors detected — connect one to control its brightness, contrast, and volume here.") {
                        dismissNoExternalsHint()
                    }
                    .transition(.opacity)
                }
            }

            Divider()

            PopupMenuRow(title: "Settings…", shortcut: "⌘,") {
                store.showMainWindow()
            }
            PopupMenuRow(title: "Quit MonitorFlux", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 312)
        // Backs the system panel translucency with a window-background layer so the popup
        // reads solid instead of letting the desktop bleed through. User-tunable in General
        // ("Popup background"); 0 restores the bare system panel.
        .background(
            Color(nsColor: .windowBackgroundColor)
                .opacity(store.preferences.popupBackdropOpacity)
        )
        // Capture this panel so the dismiss path can close exactly it, not every panel-shaped
        // window (which also caught open ⓘ popovers in the settings window).
        .background(PopupWindowAccessor())
        // The popup content exists exactly while the MenuBarExtra panel is open, so its
        // appear/disappear is the reliable "is the popup showing?" signal for the ⌘, command.
        // Opening also re-reads the backlight, so the built-in card's slider reflects any
        // keyboard brightness changes macOS handled since the last refresh.
        .onAppear {
            store.quickControlsPopupVisible = true
            store.refreshNativeBrightness()
            // Verification hook: dismiss the "no external monitors" hint through the same
            // animated path as its ✕ some seconds after the popup opens, so a screen recording
            // can capture the collapse — the popup's AX tree can't be scripted reliably.
            if let delay = ProcessInfo.processInfo.environment["MONITORFLUX_DISMISS_HINT_AFTER"]
                .flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    dismissNoExternalsHint()
                }
            }
        }
        .onDisappear { store.quickControlsPopupVisible = false }
    }

    /// Hide the no-externals hint for good, animating the layout collapse so the popup re-lays
    /// compact in the same session. The popup panel can't resize cleanly while open, so animating
    /// the height shows a brief downward bounce (~0.2 s) as its status-item anchor chases the
    /// shrinking content — see "The menu-bar popup can't resize while open" in docs/DESIGN.md.
    private func dismissNoExternalsHint() {
        withAnimation(.easeOut(duration: 0.3)) {
            store.updateGlobalPreferences { $0.hideNoExternalsHint = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .foregroundStyle(.orange)
            Text("MonitorFlux")
                .font(.headline)
            Spacer()
            Text(store.currentTemperature.map(KelvinFormatting.label(for:)) ?? "Off")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Ambience (global color temperature)

    private var ambienceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header mirrors the display cards: a leading icon, the title, then the chevron pinned
            // to the trailing edge — not tucked right after the title. The whole row opens the
            // Warmth schedule. (The jargon ⓘ moved off the popup; it lives in the schedule settings.)
            Button {
                // Tapping a card to deep-link into its settings dismisses the popup, just like
                // clicking the Settings row — otherwise the popup hangs open behind the window.
                dismissMenuBarPopup()
                store.openSettings(.color)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sun.max")
                        .foregroundStyle(.secondary)
                    // 13 pt like Control Center's module titles (and the display cards below).
                    Text("Warmth")
                        .font(.body)
                        .fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Warmth schedule settings")

            warmthRow

            // The mode (Off / Manual / Auto · schedule) moved out of the header's top-right to its
            // own quiet line, so the header matches the display cards and the slider stays full-width.
            HStack(spacing: 0) {
                modeChip
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .background(popupCardBackground())
    }

    /// Compact mode control that replaces the old Off/Fixed/Automatic segmented picker: a chip
    /// showing the current state ("Automatic" on a schedule, else "Fixed"/"Off") that opens a menu to
    /// switch. Keeps the popup calm — the warmth slider stays the hero and the mode is a quiet status
    /// you can tap.
    private var modeChip: some View {
        Menu {
            Picker("Mode", selection: modeBinding) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: modeChipAppearance.icon)
                    .font(.system(size: 9, weight: .bold))
                Text(modeChipAppearance.label)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(modeChipAppearance.tint.opacity(0.16)))
            .foregroundStyle(modeChipAppearance.tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// The mode the chip reflects — warmth on/off/mode is just `colorMode` now.
    private var currentMode: ColorMode {
        store.preferences.colorMode
    }

    private var modeChipAppearance: (icon: String, label: String, tint: Color) {
        switch currentMode {
        case .off:
            return ("power", "Off", Color.secondary)
        case .manual:
            return ("hand.point.up.left.fill", "Fixed", Color.orange)
        case .clock:
            return ("clock.fill", "Automatic", Color.blue)
        }
    }

    /// The global warmth (color-temperature) slider. Laid out exactly like the per-display
    /// `ControlRow` — a full-width `MonitorSlider` plus a fixed-width readout — so every slider
    /// in the popup shares the same track length and left/right edges. (The warm↔cool motif lives
    /// in the in-track thermometer glyph, the "K" readout, and the Warmth schedule view; the old
    /// flanking flame/snowflake were what made this track shorter than the brightness ones.)
    /// Dragging on a schedule re-warms the current phase (stays Automatic); off a schedule it's a
    /// "set it now" override → Fixed warmth. Always interactive: with warmth Off, a drag turns it
    /// on at the dragged value — the same "editing it adopts it" rule as the schedule curve —
    /// rather than a dead slider that needs a mode change first.
    private var warmthRow: some View {
        HStack(spacing: 10) {
            MonitorSlider(
                systemImage: "thermometer.sun",
                label: "Warmth",
                value: Double(editableTemperature),
                range: Double(ControlRanges.kelvin.lowerBound)...Double(ControlRanges.kelvin.upperBound),
                accessibilityValueText: KelvinFormatting.label(for: editableTemperature)
            ) { newValue in
                let rounded = Int((newValue / 100.0).rounded()) * 100
                store.updateGlobalPreferences { preferences in
                    if preferences.colorMode == .clock {
                        // On a schedule: warm/cool the phase that's active right now and stay
                        // Automatic — don't yank the whole schedule into Fixed.
                        let phase = ColorSchedule.currentPhase(preferences: preferences)
                        preferences.setTemperature(rounded, for: phase)
                    } else {
                        // From Fixed or Off, a drag pins a Fixed override (turning warmth on).
                        preferences.colorMode = .manual
                        preferences.manualTemperature = rounded
                    }
                }
            }
            Text(KelvinFormatting.label(for: editableTemperature))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }

    /// The warmth value the slider edits — the raw preference behind the active mode, exactly as
    /// the Schedule view's slider binds to `editedTemperature`. Binding the thumb to this stored
    /// anchor (not `store.currentTemperature`, the interpolated on-screen color) is what lets the
    /// drag track 1:1 across the whole range: mid-transition the live color is a blend compressed
    /// toward the phase being faded from, so reading it back pins the thumb inside a moving sub-band
    /// and the ends of the track become unreachable. Read and write resolve the phase the same way
    /// (`ColorSchedule.currentPhase`) so they stay in lockstep. The live applied color still shows
    /// in the popup header.
    private var editableTemperature: Int {
        let preferences = store.preferences
        return preferences.colorMode == .clock
            ? preferences.temperature(for: ColorSchedule.currentPhase(preferences: preferences))
            : preferences.manualTemperature
    }

    private var modeBinding: Binding<ColorMode> {
        Binding {
            store.preferences.colorMode
        } set: { newMode in
            store.updateGlobalPreferences { preferences in
                preferences.colorMode = newMode
            }
        }
    }

    /// A calm, card-styled empty state — a display glyph plus a sentence naming what the user
    /// gains by connecting a monitor — instead of a bare line or an empty area. `onClose`
    /// (the WarningCard pattern) adds a quiet ✕ in the top-right for hints worth silencing.
    private func emptyHint(_ text: String, onClose: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "display")
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Don't show this again")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(popupCardBackground())
    }
}

// MARK: - Reorderable display cards

/// The popup's display cards with an iOS-app-icon-style drag-to-reorder: grabbing a card's grip
/// lifts it (scale + shadow), it tracks the cursor, and the others slide out of the way with a
/// spring. Built on a plain `DragGesture` instead of `.draggable`, so the whole interaction stays
/// inside the menu-bar popover — the detached system drag session `.draggable` starts is what made
/// the old reorder feel awkward (and could dismiss the popover).
private struct DisplayCardsList: View {
    @EnvironmentObject private var store: AppStore
    let displays: [DisplayInfo]

    @State private var drag = DragReorderState()
    @State private var heights: [String: CGFloat] = [:]

    private static let spacing: CGFloat = 14
    private static let space = "displayCardsReorder"

    /// The order shown: the live (drag-mutated) order while dragging, else the store's order.
    private var order: [String] {
        drag.liveOrder ?? displays.map(\.key)
    }

    var body: some View {
        let byKey = Dictionary(displays.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(spacing: Self.spacing) {
            ForEach(order, id: \.self) { key in
                if let display = byKey[key] {
                    let isDragging = drag.draggingKey == key
                    DisplayCardView(
                        display: display,
                        isDragging: isDragging,
                        onDragChanged: { translationHeight in
                            handleDragChanged(key: key, translationHeight: translationHeight)
                        },
                        onDragEnded: { handleDragEnded() }
                    )
                    .background(heightReader(key: key))
                    .scaleEffect(isDragging ? 1.04 : 1, anchor: .center)
                    .shadow(
                        color: .black.opacity(isDragging ? 0.28 : 0),
                        radius: isDragging ? 10 : 0,
                        y: isDragging ? 6 : 0
                    )
                    .offset(y: isDragging ? drag.offset : 0)
                    .zIndex(isDragging ? 1 : 0)
                    // Siblings animate into their new slots when `order` changes; the dragged card
                    // opts out so its slot move stays instant and it never lags behind the cursor.
                    .animation(isDragging ? nil : .spring(response: 0.30, dampingFraction: 0.82), value: order)
                }
            }
        }
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(CardHeightKey.self) { heights = $0 }
        .onChange(of: displays.map(\.key)) { _, _ in
            // Once the drag has ended and the store's order has caught up (or the display set
            // changed underneath us), drop the local copy so external changes flow through.
            if drag.draggingKey == nil { drag.liveOrder = nil }
        }
    }

    private func heightReader(key: String) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(key: CardHeightKey.self, value: [key: geometry.size.height])
        }
    }

    private func handleDragChanged(key: String, translationHeight: CGFloat) {
        if drag.draggingKey != key {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.72)) {
                drag.begin(key: key, order: order)
            }
        }
        drag.update(translationHeight: translationHeight, heights: heights, spacing: Self.spacing)
    }

    private func handleDragEnded() {
        let committed = drag.liveOrder
        withAnimation(.spring(response: 0.34, dampingFraction: 0.8)) {
            drag.end()
        }
        if let committed {
            store.setDisplayOrder(committed)
        }
    }
}

/// Transient state for a card reorder drag. `liveOrder` is the locally-reordered key list shown
/// while dragging; `offset` is the lifted card's vertical travel from its current slot. The swap
/// math lives in the pure, unit-tested `DragReorder`.
private struct DragReorderState {
    var draggingKey: String?
    var liveOrder: [String]?
    var offset: CGFloat = 0
    private var lastTranslation: CGFloat = 0

    mutating func begin(key: String, order: [String]) {
        draggingKey = key
        liveOrder = order
        offset = 0
        lastTranslation = 0
    }

    mutating func update(translationHeight: CGFloat, heights: [String: CGFloat], spacing: CGFloat) {
        guard let key = draggingKey, let current = liveOrder else {
            return
        }
        offset += translationHeight - lastTranslation
        lastTranslation = translationHeight
        let resolved = DragReorder.resolve(
            order: current,
            draggingKey: key,
            offset: offset,
            heights: heights,
            spacing: spacing
        )
        liveOrder = resolved.order
        offset = resolved.offset
    }

    mutating func end() {
        draggingKey = nil
        offset = 0
        lastTranslation = 0
    }
}

/// Collects each card's measured height (keyed by display key) so the reorder math can pick the
/// correct swap threshold for cards of different sizes.
private struct CardHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Per-display card

/// One display's controls in the popup. Keep sliders visible so opening the menu is enough
/// to inspect and adjust the monitor without a second disclosure click.
private struct DisplayCardView: View {
    @EnvironmentObject private var store: AppStore
    let display: DisplayInfo
    var isDragging = false
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}

    var body: some View {
        let preferences = store.displayPreferences(for: display)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(isDragging ? .secondary : .tertiary)
                    .padding(.vertical, 4)
                    .padding(.trailing, 2)
                    .contentShape(Rectangle())
                    // A plain drag gesture on just the grip: it can't conflict with the sliders'
                    // own drag, and it drives the parent's lift/reorder via callbacks. Measured in
                    // the **global** space, not the grip's local space — the grip rides along with
                    // the lifted card's offset, so a local-space translation would feed back into
                    // itself and make the dragged card jitter. Global space is stable.
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .global)
                            .onChanged { onDragChanged($0.translation.height) }
                            .onEnded { _ in onDragEnded() }
                    )
                    .help("Drag to reorder")
                Button {
                    dismissMenuBarPopup()
                    store.openSettings(.display(display.key))
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                            .foregroundStyle(.secondary)
                        // 13 pt like Control Center's module titles (and the Warmth card).
                        Text(display.name)
                            .font(.body)
                            .fontWeight(.semibold)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(display.name) settings")
            }

            if display.isBuiltIn {
                builtInControls(preferences)
            } else {
                externalControls(preferences)
            }
        }
        .padding(12)
        .background(popupCardBackground())
    }

    @ViewBuilder
    private func builtInControls(_ preferences: DisplayPreferences) -> some View {
        brightnessRow
        if !store.canUseNativeBrightness(display) {
            caption("Software dimming (built-in panel has no backlight control)")
        } else if store.brightnessControlKind(for: display) == .softwareOnly {
            // The user opted the built-in into all-software dimming: name the state, since
            // the slider deliberately isn't moving the backlight here.
            caption("Software dimming — the backlight stays put")
        }
    }

    @ViewBuilder
    private func externalControls(_ preferences: DisplayPreferences) -> some View {
        brightnessRow

        switch store.brightnessControlKind(for: display) {
        case .shade:
            caption("Overlay dimming (AirPlay — no hardware control)")
        case .softwareOnly:
            caption(store.canUseDDC(for: display)
                ? "Software dimming"
                : "Software dimming (no DDC on this display)")
        case .unavailable:
            caption("No hardware brightness control on this display")
        case .hybrid, .hardwareOnly:
            EmptyView()
        }

        // Contrast and volume are DDC-only, independent of how brightness dims.
        if store.canUseDDC(for: display) {
            // On a contrast schedule, the slider re-levels the active phase and stays Automatic
            // (like brightness and warmth above); otherwise it sets the manual contrast.
            let contrastScheduled = store.isContrastScheduled(display)
            let contrastValue = contrastScheduled
                ? store.scheduledContrastValue(for: display)
                : preferences.hardwareContrast
            ControlRow(
                icon: "circle.lefthalf.filled",
                label: "Contrast",
                value: Double(contrastValue),
                range: ControlRanges.hardwarePercent,
                readout: "\(contrastValue)%"
            ) { newValue in
                if contrastScheduled {
                    store.setScheduledPhaseContrast(Int(newValue.rounded()), for: display)
                } else {
                    store.setHardwareContrast(Int(newValue.rounded()), for: display)
                }
            }

            // Volume only when the monitor actually has speakers (or the user forced it on)
            // — a speakerless display gets no useless volume slider.
            if store.shouldShowVolumeControl(for: display) {
                ControlRow(
                    icon: "speaker.wave.2.fill",
                    label: "Volume",
                    value: Double(preferences.hardwareVolume),
                    range: ControlRanges.hardwarePercent,
                    readout: "\(preferences.hardwareVolume)%"
                ) { store.setHardwareVolume(Int($0.rounded()), for: display) }
            }
        }
    }

    /// The one Brightness slider, on the unified 0…100 position scale for every path —
    /// backlight, DDC, hybrid (with the handoff notch), software, or shade. Below the notch
    /// the icon swaps sun → moon and the fill dims: the image is being darkened now, not the
    /// backlight. When this display's brightness is on a schedule, the slider re-levels the
    /// active phase and stays Automatic — the same behavior as the warmth slider on a schedule,
    /// rather than a manual value the schedule would overwrite at the next phase.
    private var brightnessRow: some View {
        let kind = store.brightnessControlKind(for: display)
        let scheduled = store.isBrightnessScheduled(display)
        let position = scheduled
            ? store.scheduledBrightnessPosition(for: display)
            : store.unifiedBrightness(for: display)
        let notch = kind == .hybrid ? HybridBrightness.handoffFraction : nil
        let inSoftwareZone = notch.map { position < $0 } ?? false
        return ControlRow(
            icon: inSoftwareZone ? "moon" : "sun.max",
            label: "Brightness",
            value: position * 100,
            range: ControlRanges.hardwarePercent,
            enabled: kind != .unavailable,
            notchFraction: notch,
            readout: "\(Int((position * 100).rounded()))%"
        ) { newValue in
            if scheduled {
                store.setScheduledPhaseBrightness(newValue / 100.0, for: display)
            } else {
                store.setUnifiedBrightness(newValue / 100.0, for: display)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Building blocks

/// A labeled MonitorControl-style slider row: the slider plus a fixed-width readout.
private struct ControlRow: View {
    let icon: String
    /// Spoken name / tooltip for the icon-only slider (e.g. "Contrast").
    let label: String
    let value: Double
    let range: ClosedRange<Int>
    var enabled = true
    var notchFraction: Double? = nil
    let readout: String
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            MonitorSlider(
                systemImage: icon,
                label: label,
                value: value,
                range: Double(range.lowerBound)...Double(range.upperBound),
                isEnabled: enabled,
                notchFraction: notchFraction,
                accessibilityValueText: readout,
                onChange: onChange
            )
            Text(readout)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}

private func popupCardBackground() -> some View {
    RoundedRectangle(cornerRadius: 10)
        .fill(Color.primary.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
}

/// Collapse the `MenuBarExtra(.window)` dropdown the way clicking a real `NSMenu` item does.
/// SwiftUI doesn't expose a dismiss for it, so first try to toggle the status item itself.
/// If SwiftUI's status button isn't discoverable, close only the visible popup panel: the
/// width gate keeps us from also closing the tiny status-item windows that back the icon.
@MainActor
func dismissMenuBarPopup() {
    if let button = menuBarStatusButton() {
        // Let the status item perform its normal toggle first. Closing the panel directly
        // bypasses SwiftUI's MenuBarExtra state and can leave the menu-bar icon highlighted.
        button.performClick(nil)
        Task { @MainActor in
            await Task.yield()
            closeMenuBarPopupWindows()
            button.highlight(false)
        }
        return
    }

    closeMenuBarPopupWindows()
    clearMenuBarHighlight()
}

/// Open the menu-bar popup programmatically — a dev/verification hook (paired with
/// `MONITORFLUX_OPEN_POPUP=1`) so the popup panel can be put on screen and captured by window id
/// with ScreenCaptureKit. The popup is a SwiftUI `MenuBarExtra` window with no public "show" API,
/// so this performs the same click the user would on the status item.
@MainActor
func openMenuBarPopup() {
    menuBarStatusButton()?.performClick(nil)
}

@MainActor
private func closeMenuBarPopupWindows() {
    // Close the tracked popup panel specifically. Fall back to the panel-shape heuristic only
    // when the window was never captured — and even then never a popover (an open ⓘ in the
    // settings window is one), which the width gate alone would wrongly close.
    if let window = MenuBarPopupWindow.current, window.isVisible {
        window.close()
        return
    }
    for window in NSApp.windows
    where window.isVisible
        && !window.styleMask.contains(.titled)
        && !window.ignoresMouseEvents
        && window.frame.width >= 120
        && !String(describing: type(of: window)).contains("Popover") {
        window.close()
    }
}

/// The live `MenuBarExtra` panel, captured while the popup is on screen (see
/// `PopupWindowAccessor`), so the dismiss path can target exactly it.
@MainActor
enum MenuBarPopupWindow {
    static weak var current: NSWindow?
}

/// A zero-size backing view that records its host window — the popup panel — into
/// `MenuBarPopupWindow.current`.
private struct PopupWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { MenuBarPopupWindow.current = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            MenuBarPopupWindow.current = window
        }
    }
}

@MainActor
private func menuBarStatusButton() -> NSStatusBarButton? {
    for window in NSApp.windows {
        if let button = statusBarButton(in: window.contentView) {
            return button
        }
        if let button = statusBarButton(in: window.contentView?.superview) {
            return button
        }
    }
    return nil
}

@MainActor
private func clearMenuBarHighlight() {
    // Closing the popup window ourselves leaves the MenuBarExtra's status-item button stuck in
    // its highlighted (pressed) state — SwiftUI never learns the panel went away. Clear the
    // highlight directly on the NSStatusBarButton so the menu-bar icon returns to normal.
    // Clear on this tick and again on the next: the synchronous clear handles the common case,
    // and the deferred one wins if SwiftUI re-asserts the highlight while reconciling the
    // window we closed out from under it.
    func clear() {
        for window in NSApp.windows {
            statusBarButton(in: window.contentView)?.highlight(false)
            statusBarButton(in: window.contentView?.superview)?.highlight(false)
        }
    }
    clear()
    Task { @MainActor in clear() }
}

/// Find the menu-bar status-item button anywhere in a window's view tree (SwiftUI nests it).
@MainActor
private func statusBarButton(in view: NSView?) -> NSStatusBarButton? {
    guard let view else { return nil }
    if let button = view as? NSStatusBarButton { return button }
    for subview in view.subviews {
        if let button = statusBarButton(in: subview) { return button }
    }
    return nil
}

/// A footer row that behaves like a real menu item: full-width hit target, accent
/// highlight on hover, a trailing keyboard-shortcut hint — and it dismisses the dropdown.
private struct PopupMenuRow: View {
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            dismissMenuBarPopup()
            action()
        } label: {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .foregroundStyle(isHovering ? .white : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.accentColor.opacity(0.9) : .clear)
            )
            .foregroundStyle(isHovering ? .white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
