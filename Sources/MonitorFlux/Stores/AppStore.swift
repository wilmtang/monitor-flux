import AppKit
import Combine
import CoreGraphics
import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var preferences: AppPreferences {
        didSet {
            let normalized = preferences.normalized()
            guard normalized == preferences else {
                preferences = normalized
                return
            }
            // Coalesce disk writes and skip the gamma recompute unless a color-affecting
            // field actually changed. A continuous brightness/contrast/volume drag fires
            // this dozens of times a second; doing a synchronous save + full gamma pass on
            // every tick is what made the controls feel laggy next to MonitorControl.
            schedulePreferencesSave()
            // Leaving the clock schedule (to Manual/Off, or Warmth off) ends any scrub preview —
            // there's no live schedule left to preview.
            let endPreview = schedulePreviewMinute != nil
                && !(preferences.gammaEnabled && preferences.colorMode == .clock)
            if endPreview {
                schedulePreviewMinute = nil
            }
            if oldValue.colorSignature != preferences.colorSignature {
                reconcileColor()
                // The per-display software-brightness value (gammaBrightness) is part of the
                // color signature, so an AirPlay slider drag lands here — push it to the shade.
                reconcileShades()
            }
            if endPreview {
                // Restore the now scheduled brightness/contrast the preview overrode, deferred so
                // the restore's hardware writes don't re-enter this didSet.
                DispatchQueue.main.async { [weak self] in
                    self?.restoreScheduledHardwareAfterPreview()
                }
            }
        }
    }
    @Published private(set) var currentTemperature: Int?
    /// While non-nil, the schedule curve is being scrubbed to preview the warmth at this
    /// minute-of-day, and gamma shows that instead of the live color. Cleared when the settings
    /// window reloads (`clearSchedulePreview`), so a preview never silently persists.
    @Published private(set) var schedulePreviewMinute: Int?
    @Published private(set) var colorMessage = "Color disabled"
    @Published private(set) var ddcMessage = "DDC idle"
    @Published private(set) var loginItemMessage = LoginItemService.statusLabel()
    /// True for a dev build that LaunchServices doesn't know as installed, so the login item
    /// can't register — drives the explanatory caption in General.
    var loginItemNeedsInstall: Bool { LoginItemService.needsInstall() }
    @Published private(set) var locationStatus = "Not requested"
    @Published private(set) var keyboardStatus = "Off"
    /// Whether the app currently has Accessibility permission (needed only for the media-key
    /// tap). Tracked live so Settings can warn when it's missing and clear the warning once
    /// the user grants it. Re-checked when the app reactivates (e.g. after System Settings).
    @Published private(set) var accessibilityTrusted = false
    /// Cached real backlight level (0...1) per display that supports DisplayServices.
    @Published private(set) var nativeBrightness: [CGDirectDisplayID: Double] = [:]
    /// Displays that expose an audio output (monitor speakers). Drives whether the DDC
    /// volume slider is shown — a speakerless monitor gets no volume control.
    @Published private(set) var displaysWithAudio: Set<CGDirectDisplayID> = []
    /// Real per-external-display DDC support, probed non-destructively on connect (whether an
    /// IOAVService resolves). Drives canUseDDC so the software-dimming default and popup fallback
    /// reflect actual capability instead of assuming every external speaks DDC.
    @Published private(set) var ddcCapableByID: [CGDirectDisplayID: Bool] = [:]
    /// Custom-shortcut actions whose combo another app already owns, so they couldn't be
    /// registered. Surfaced as a warning next to the recorder.
    @Published private(set) var hotkeyConflicts: Set<HotKeyAction> = []
    /// True when any action has a `.media(...)` binding but `keyboardControlEnabled` is off.
    var hasInactiveMediaBindings: Bool {
        !preferences.keyboardControlEnabled
            && preferences.hotkeys.values.contains(where: { $0.asMedia != nil })
    }
    /// True when another app is also editing gamma (detected by reading the LUT back).
    @Published private(set) var gammaConflictDetected = false
    /// Known gamma apps running when the conflict was seen — the likely cause, named in the
    /// banner. Empty when none of the known apps is running (e.g. Night Shift, or an unknown app).
    @Published private(set) var gammaConflictApps: [String] = []
    /// The user closed the conflict banner; it reappears only when a fresh conflict is seen.
    @Published private(set) var gammaConflictBannerDismissed = false
    /// A settings pane requested from the menu-bar popup (e.g. tapping a display card). ContentView
    /// observes this, applies it to the sidebar selection, then clears it.
    @Published var requestedSelection: AppSelection?
    /// Whether the menu-bar popup is on screen, tracked by `QuickControlsView`'s appear/disappear.
    /// Read by the ⌘, Settings menu command so it only toggles the status item to dismiss the
    /// popup when the popup is actually open (a blind toggle would open it). Not `@Published` —
    /// nothing renders from it.
    var quickControlsPopupVisible = false

    /// Set by `MONITORFLUX_SAFE_MODE=1`. Skips every gamma/DDC/backlight hardware write so
    /// tests don't fight f.lux/MonitorControl or flicker the screen — the UI still updates.
    let safeMode: Bool

    let locationService = LocationService()
    let keyboardService = KeyboardControlService()
    private let displayService = DisplayService()
    private let ddcBackend = HardwareDDCBackend()
    private let nativeBrightnessBackend = NativeBrightnessBackend()
    private let audioCapabilityService = AudioCapabilityService()
    private let osd = OSDController()
    private let hotKeyCenter = HotKeyCenter()
    private let gammaService = GammaTemperatureService()
    /// Software dimming for AirPlay/virtual displays, which ignore gamma (see `ShadeController`).
    private let shadeController = ShadeController()
    /// Builds and re-anchors the settings and onboarding windows (see `WindowCoordinator`).
    private let windows = WindowCoordinator()
    private var timer: Timer?
    /// Throttles live DDC slider drags per control (leading edge + trailing settle), so the
    /// monitor tracks a drag without flooding the I2C bus. See `DDCWriteScheduler`.
    private let ddcWriteScheduler = DDCWriteScheduler()
    /// Last brightness/contrast targets the schedule wrote per display. We only re-apply when
    /// the scheduled target changes, so a manual adjustment between phase transitions sticks
    /// (f.lux-style) instead of being snapped back on the next tick. See `ScheduledHardware`.
    private var scheduledHardwareState = ScheduledHardware.State()
    /// Serializes the actual I2C writes so a throttled drag can't overlap two writes to
    /// the same bus. `.userInitiated` keeps the monitor responsive during a drag.
    private let ddcQueue = DispatchQueue(label: "app.monitorflux.ddc", qos: .userInitiated)
    private var pendingPreferencesSave: DispatchWorkItem?
    private var pendingDDCMessage: DispatchWorkItem?
    private var displayRefreshGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        safeMode = ProcessInfo.processInfo.environment["MONITORFLUX_SAFE_MODE"] == "1"
        preferences = PreferencesStore.load().normalized()
        // Test hook: `MONITORFLUX_ZOOM_STEP=N` opens the window at a given zoom step
        // (0…8) without persisting it, so a screenshot run can verify zoom rendering
        // at a non-default scale. In-memory only; the saved preference is untouched.
        if let raw = ProcessInfo.processInfo.environment["MONITORFLUX_ZOOM_STEP"],
           let step = Int(raw) {
            preferences.fontSizeStep = step.clamped(to: AppPreferences.fontSizeStepRange)
        }
        refreshDisplays()
        startTimer()

        locationStatus = locationService.statusMessage
        locationService.$statusMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                self?.locationStatus = message
            }
            .store(in: &cancellables)
        locationService.onLocation = { [weak self] coordinate in
            self?.applyLocation(coordinate)
        }

        accessibilityTrusted = keyboardService.hasAccessibilityPermission
        if safeMode {
            keyboardStatus = "Off (safe mode)"
        } else if preferences.keyboardControlEnabled {
            keyboardStatus = keyboardService.start() ? "Active" : "Needs Accessibility permission"
        }

        // Re-check Accessibility when the app comes forward, so granting it in System Settings
        // and switching back clears the warning (and starts the tap) without a relaunch.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshAccessibilityStatus()
            }
            .store(in: &cancellables)

        // Waking from sleep can leave stale gamma and an out-of-date scheduled brightness (the
        // 60s timer only catches up on its next tick, and a wake doesn't always reconfigure
        // displays). Re-run the reconcile chain right away — detection first, since it reads
        // the LUT that reconcileColor is about to overwrite.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                AppLog.schedule.notice("Woke from sleep; re-applying color and schedule")
                self.refreshNativeBrightness()
                self.refreshGammaConflictState()
                self.reconcileColor()
                self.applyScheduledHardware()
            }
            .store(in: &cancellables)

        // End any schedule-curve preview when the settings window loses key focus — switching
        // apps, clicking another window, or closing it — so a temporary preview never strands the
        // user on a previewed color.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
            .sink { [weak self] notification in
                guard let self, (notification.object as? NSWindow) === self.windows.mainWindow else {
                    return
                }
                self.clearSchedulePreview()
            }
            .store(in: &cancellables)

        // Coming back to the settings window re-reads the backlight, so the built-in display's
        // Brightness slider reflects any keyboard changes macOS handled while we weren't looking.
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] notification in
                guard let self, (notification.object as? NSWindow) === self.windows.mainWindow else {
                    return
                }
                self.refreshNativeBrightness()
            }
            .store(in: &cancellables)

        // Custom global shortcuts use Carbon hot keys, which (unlike the media-key tap) need
        // no Accessibility permission, so they're registered independently of that toggle.
        hotKeyCenter.onAction = { [weak self] action in
            self?.performHotKeyAction(action)
        }
        // Media-key bindings use media-key semantics: bare brightness keys leave the built-in
        // panel to macOS unless the binding is for the built-in-display shortcut group.
        keyboardService.onAction = { [weak self] action in
            self?.performMediaKeyAction(action) ?? false
        }
        refreshHotKeys()

        CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// macOS fires several reconfiguration callbacks for one hotplug (begin/end, plus
    /// one per display). Debounce so the display list rebuilds once, after the layout
    /// settles — picking up connect/disconnect/resolution/mirroring changes live.
    func handleDisplayReconfiguration() {
        displayRefreshGeneration += 1
        let generation = displayRefreshGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard self.displayRefreshGeneration == generation else {
                return
            }
            self.refreshDisplays()
        }
    }

    /// Sunrise/sunset for the stored coordinates today, or nil if it can't be computed
    /// (unparseable coordinates, or polar day/night).
    var solarTimes: SolarCalculator.Times? {
        guard let latitude = Double(preferences.latitude),
              let longitude = Double(preferences.longitude)
        else {
            return nil
        }
        return SolarCalculator.times(
            latitude: latitude,
            longitude: longitude,
            date: Date(),
            timeZone: Calendar.current.timeZone
        )
    }

    func requestLocation() {
        locationService.request()
    }

    /// Ask for location the first time the user picks the solar schedule. The shipped default
    /// coordinates are Seattle, so without this, "Sunrise & sunset" silently follows the wrong
    /// city until the user notices the times. Only fires when permission was never asked —
    /// a denied choice is respected (the Location rows explain how to fix it).
    func requestLocationIfNeverAsked() {
        guard locationService.authorizationStatus == .notDetermined else {
            return
        }
        locationService.request()
    }

    private func applyLocation(_ coordinate: CLLocationCoordinate2D) {
        updateGlobalPreferences { preferences in
            preferences.latitude = String(format: "%.4f", coordinate.latitude)
            preferences.longitude = String(format: "%.4f", coordinate.longitude)
            preferences.scheduleSource = .solar
        }
    }

    var ddcStatus: DDCBackendStatus {
        ddcBackend.status
    }

    func refreshDisplays() {
        // A display change (or the Refresh button) ends any schedule preview, so the user isn't
        // stranded on a previewed color or brightness. The reconcile + schedule below re-apply the
        // live values; clearing lastScheduled forces the scheduled brightness/contrast back over
        // whatever the preview last wrote.
        if schedulePreviewMinute != nil {
            schedulePreviewMinute = nil
            scheduledHardwareState = ScheduledHardware.State()
        }
        // The display layout may have changed; cached DDC service handles can be stale.
        ddcBackend.invalidateServiceCache()
        displays = displayService.listDisplays() + mockDisplaySpecs.map(\.display)
        pruneDisplayKeyedState()
        refreshNativeBrightness()
        refreshAudioCapability()
        refreshDDCCapability()
        // The non-drag entry point for conflict detection (reconcileColor no longer does it). Runs
        // before the re-apply below so it reads the on-screen LUT, not the one we're about to write.
        refreshGammaConflictState()
        let seeded = seedMissingDisplayPreferences()
        // Fold any legacy built-in dimming state into the built-in's hardware default before
        // re-applying color, so an upgraded built-in never comes up dimmed in software.
        let reconciledBuiltInDim = reconcileBuiltInDimming()
        if !seeded, !reconciledBuiltInDim {
            reconcileColor()
        }
        applyScheduledHardware()
        restoreHardwareSettings()
        // Match shade overlays to the current AirPlay/virtual displays (and drop any for
        // displays that just disconnected).
        reconcileShades()
    }

    /// Drop per-display bookkeeping for monitors that are no longer connected. Most display-keyed
    /// caches (`nativeBrightness`, `ddcCapableByID`, `displaysWithAudio`) are rebuilt wholesale on
    /// each refresh and the gamma service prunes its own, but the schedule's last-written targets and
    /// the DDC throttle timestamps are only ever touched for *live* displays — so a monitor that
    /// comes and goes leaves a stale entry behind. Each is a few bytes and `CGDirectDisplayID`s are
    /// reused, so the growth is tiny, but it's unbounded over a long uptime; prune on every change.
    private func pruneDisplayKeyedState() {
        let liveIDs = Set(displays.map(\.id))
        scheduledHardwareState.retainOnly(liveIDs)
        // The DDC throttle's keys are "<displayID>.<control>"; keep only live ones.
        ddcWriteScheduler.retainOnly { key in
            guard let idText = key.split(separator: ".").first,
                  let id = CGDirectDisplayID(idText)
            else {
                return false
            }
            return liveIDs.contains(id)
        }
    }

    /// Drive each AirPlay/virtual display's shade overlay from its software-brightness value.
    /// These displays ignore gamma, so this is their only working brightness path. Independent of
    /// the Warmth master — a shade is plain dimming, not a color change.
    private func reconcileShades() {
        guard !safeMode else {
            shadeController.removeAll()
            return
        }
        var active: Set<CGDirectDisplayID> = []
        for display in displays where display.isVirtual {
            let fraction = Double(displayPreferences(for: display).gammaBrightness.clamped(to: 0...100)) / 100.0
            // Only materialize an overlay when the display is actually dimmed; at full brightness
            // it's dropped so there's no invisible full-screen window sitting at shield level.
            guard fraction < 1 else {
                continue
            }
            shadeController.setBrightness(fraction, for: display.effectiveID)
            active.insert(display.effectiveID)
        }
        shadeController.retainOnly(active)
    }

    /// Re-send each external display's saved brightness/contrast over DDC on launch and on
    /// reconnect, so the monitor returns to your last manual setting. The slider already
    /// shows the saved value, but DDC is otherwise only written when you move it — so without
    /// this, a relaunch leaves the monitor at whatever it last had. Schedule-driven controls
    /// are left to the schedule, and volume is left alone to avoid surprise audio changes.
    private func restoreHardwareSettings() {
        guard !safeMode else {
            return
        }
        for display in displays where !display.isBuiltIn {
            let displayPreferences = displayPreferences(for: display)
            if !displayPreferences.scheduleBrightness {
                applyBrightness(for: display)
            }
            if !displayPreferences.scheduleContrast {
                applyContrast(for: display)
            }
        }
    }

    private func refreshAudioCapability() {
        let deviceNames = audioCapabilityService.displayAudioDeviceNames()
        var withAudio: Set<CGDirectDisplayID> = []
        for display in displays where !display.isBuiltIn {
            if audioCapabilityService.displayHasAudio(named: display.name, deviceNames: deviceNames) {
                withAudio.insert(display.id)
            }
        }
        displaysWithAudio = withAudio
    }

    /// Probe each external display's DDC capability non-destructively (does an IOAVService
    /// resolve?) and cache it. Runs on every refresh — i.e. on launch and on display-config
    /// changes — so a monitor moved to a port that can't carry DDC is re-evaluated.
    private func refreshDDCCapability() {
        let capable = ddcBackend.ddcCapableDisplays(displays)
        var map: [CGDirectDisplayID: Bool] = [:]
        for display in displays where !display.isBuiltIn {
            map[display.id] = capable.contains(display.id)
        }
        // Mock displays have no real IOAVService, so force their declared capability here.
        for spec in mockDisplaySpecs {
            map[spec.display.id] = spec.ddcCapable
        }
        ddcCapableByID = map
    }

    /// Dev/test hook: `MONITORFLUX_FAKE_DISPLAYS=N` injects up to 4 mock external monitors so the
    /// popup's multi-card behaviour (drag-to-reorder, tap-to-open) and the per-display control
    /// paths can be exercised on a machine with only the built-in panel. The mocks cover each
    /// brightness path: even index = DDC-capable, odd index = non-DDC (gamma software dimming),
    /// and index 2 is marked AirPlay/virtual (shade software dimming). Their hardware/shade writes
    /// are no-ops (no real service or `NSScreen`), so run under `MONITORFLUX_SAFE_MODE=1`. Inert
    /// unless the variable is set.
    private var mockDisplaySpecs: [(display: DisplayInfo, ddcCapable: Bool)] {
        guard let raw = ProcessInfo.processInfo.environment["MONITORFLUX_FAKE_DISPLAYS"],
              let count = Int(raw), count > 0 else {
            return []
        }
        return (0..<min(count, 4)).map { index in
            let isVirtual = index == 2
            let capable = !isVirtual && index % 2 == 0
            let label = isVirtual ? "Mock AirPlay" : (capable ? "Mock DDC" : "Mock non-DDC")
            return (
                DisplayInfo(
                    id: CGDirectDisplayID(0xF000_0001 + UInt32(index)),
                    name: "\(label) Monitor \(index + 1)",
                    persistentID: "mock-display-\(index)",
                    frameDescription: "2560 × 1440",
                    isBuiltIn: false,
                    isOnline: true,
                    isVirtual: isVirtual
                ),
                capable
            )
        }
    }

    /// Whether an audio output (monitor speakers) was detected for this display.
    func displayHasDetectedAudio(_ display: DisplayInfo) -> Bool {
        displaysWithAudio.contains(display.id)
    }

    /// Whether to show the DDC volume slider for a display: external, and either it reports
    /// an audio output (monitor speakers) or the user forced the control on.
    func shouldShowVolumeControl(for display: DisplayInfo) -> Bool {
        guard !display.isBuiltIn else {
            return false
        }
        return displayHasDetectedAudio(display) || displayPreferences(for: display).forceVolumeControl
    }

    func canUseNativeBrightness(_ display: DisplayInfo) -> Bool {
        nativeBrightnessBackend.canControl(display.id)
    }

    func nativeBrightnessValue(for display: DisplayInfo) -> Double {
        nativeBrightness[display.id] ?? Double(nativeBrightnessBackend.brightness(of: display.id) ?? 0.5)
    }

    func setNativeBrightness(_ value01: Double, for display: DisplayInfo) {
        let clamped = value01.clamped(to: 0...1)
        nativeBrightness[display.id] = clamped
        guard !safeMode else {
            return
        }
        nativeBrightnessBackend.setBrightness(Float(clamped), for: display.id)
    }

    /// Re-read the real backlight into the cache. Beyond each display refresh, this also runs
    /// when the popup opens and when the settings window becomes key: bare brightness keys on
    /// the built-in are handled by macOS (not us), so without a re-read the slider would show
    /// a stale level until the next display reconfiguration.
    func refreshNativeBrightness() {
        var levels: [CGDirectDisplayID: Double] = [:]
        for display in displays where nativeBrightnessBackend.canControl(display.id) {
            if let value = nativeBrightnessBackend.brightness(of: display.id) {
                levels[display.id] = Double(value)
            }
        }
        // Skip the no-op publish: this runs on every popup open / window focus, and an
        // unchanged @Published set would still re-render every observer.
        if nativeBrightness != levels {
            nativeBrightness = levels
        }
    }

    func displayPreferences(for display: DisplayInfo) -> DisplayPreferences {
        preferences.displayPreferences[display.key, default: DisplayPreferences()]
    }

    /// The display's dimming mode with the per-kind default resolved: externals default to
    /// `.automatic` (hybrid — hardware first, software below the hardware floor); the
    /// built-in panel defaults to `.hardware` and only ever dims all-backlight or
    /// all-software (the Advanced toggle flips between the two — no hybrid).
    func dimmingMode(for display: DisplayInfo) -> DimmingMode {
        DimmingMode.resolved(displayPreferences(for: display).dimmingMode, isBuiltIn: display.isBuiltIn)
    }

    func setDimmingMode(_ mode: DimmingMode, for display: DisplayInfo) {
        updateDisplayPreferences(for: display) { displayPreferences in
            displayPreferences.dimmingMode = mode
            // Hardware-only means the image isn't darkened in software: clear any software
            // dimming (an Advanced >100 boost survives). Leaving it applied would keep the
            // screen dim with no main-slider way to lift it.
            if mode == .hardware {
                displayPreferences.gammaBrightness = max(displayPreferences.gammaBrightness, 100)
            }
        }
    }

    /// The software floor (percent) for a display's unified brightness control.
    func softwareDimmingFloor(for display: DisplayInfo) -> Int {
        HybridBrightness.floorPercent(dimToBlack: displayPreferences(for: display).dimToBlack)
    }

    // MARK: - Unified brightness (the one Brightness slider per display)

    /// What a display's everyday Brightness slider drives, from its capabilities plus its
    /// dimming mode — so the popup card, the detail pane, and the media keys all route the
    /// same way.
    func brightnessControlKind(for display: DisplayInfo) -> BrightnessControlKind {
        if display.isVirtual {
            return .shade
        }
        if display.isBuiltIn {
            guard canUseNativeBrightness(display) else {
                // No backlight API at all: software dimming is the only path.
                return .softwareOnly
            }
            // The built-in is binary — all backlight (default, macOS's own domain) or all
            // software, flipped by the Advanced toggle. Never hybrid: a low-backlight-
            // sensitive user picks software dimming exactly to keep the backlight steady,
            // so the slider must not drive both.
            return dimmingMode(for: display) == .software ? .softwareOnly : .hardwareOnly
        }
        let hasDDC = canUseDDC(for: display)
        switch dimmingMode(for: display) {
        case .automatic:
            return hasDDC ? .hybrid : .softwareOnly
        case .hardware:
            return hasDDC ? .hardwareOnly : .unavailable
        case .software:
            return .softwareOnly
        }
    }

    /// The unified brightness position (0…1) — the single scale the everyday slider, the
    /// media keys, the OSD, and (in Automatic mode) the schedule share.
    func unifiedBrightness(for display: DisplayInfo) -> Double {
        let displayPreferences = displayPreferences(for: display)
        let floor = softwareDimmingFloor(for: display)
        switch brightnessControlKind(for: display) {
        case .hybrid:
            return HybridBrightness.unified(hybridComponents(for: display), floor: floor)
        case .hardwareOnly:
            return display.isBuiltIn
                ? nativeBrightnessValue(for: display)
                : Double(displayPreferences.hardwareBrightness) / 100.0
        case .softwareOnly:
            return HybridBrightness.softwareOnlyFraction(
                gamma: displayPreferences.gammaBrightness,
                floor: floor
            )
        case .shade:
            return Double(min(100, displayPreferences.gammaBrightness)) / 100.0
        case .unavailable:
            return Double(displayPreferences.hardwareBrightness) / 100.0
        }
    }

    /// Drive a display's brightness to a unified position. On a hybrid track this maintains
    /// the handoff invariant via `HybridBrightness.resolve`; components are only written when
    /// they actually change, so a software-zone drag doesn't hammer DDC with repeated zeros
    /// (and vice versa for gamma).
    func setUnifiedBrightness(_ position: Double, for display: DisplayInfo) {
        let floor = softwareDimmingFloor(for: display)
        switch brightnessControlKind(for: display) {
        case .hybrid:
            // Only DDC externals resolve to .hybrid (the built-in is binary — see
            // brightnessControlKind), so the hardware component is always a DDC write.
            let current = hybridComponents(for: display)
            let next = HybridBrightness.resolve(targetUnified: position, current: current, floor: floor)
            if next.hardware != current.hardware {
                setHardwareBrightness(next.hardware, for: display)
            }
            if next.gamma != current.gamma {
                updateDisplayPreferences(for: display) { displayPreferences in
                    displayPreferences.gammaBrightness = next.gamma
                }
            }
        case .hardwareOnly:
            if display.isBuiltIn {
                setNativeBrightness(position, for: display)
            } else {
                setHardwareBrightness(Int((position.clamped(to: 0...1) * 100).rounded()), for: display)
            }
        case .softwareOnly:
            let gamma = HybridBrightness.softwareOnlyGamma(fraction: position, floor: floor)
            updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences.gammaBrightness = gamma
            }
        case .shade:
            let value = Int((position.clamped(to: 0...1) * 100).rounded())
            updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences.gammaBrightness = value
            }
        case .unavailable:
            break
        }
    }

    /// Both dimming components as integer percents. Hybrid is DDC-external-only, so the
    /// hardware component is the stored DDC brightness.
    private func hybridComponents(for display: DisplayInfo) -> HybridBrightness.Components {
        let displayPreferences = displayPreferences(for: display)
        return HybridBrightness.Components(
            hardware: displayPreferences.hardwareBrightness,
            gamma: displayPreferences.gammaBrightness
        )
    }

    /// The popup's display cards in the user's chosen order (drag-to-reorder). Displays not yet
    /// in `displayOrder` — freshly connected ones — follow the ordered set in detection order.
    var orderedDisplays: [DisplayInfo] {
        let byKey = Dictionary(displays.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return DisplayOrdering.sorted(displays.map(\.key), by: preferences.displayOrder)
            .compactMap { byKey[$0] }
    }

    /// Persist the popup's full card order (the drag-to-reorder commit). `keys` is the complete
    /// set of currently-shown display keys in their new order.
    func setDisplayOrder(_ keys: [String]) {
        updateGlobalPreferences { $0.displayOrder = keys }
    }

    func updateGlobalPreferences(_ update: (inout AppPreferences) -> Void) {
        var next = preferences
        update(&next)
        let normalized = next.normalized()
        // Skip the no-op assignment: @Published fires objectWillChange on every set, even an
        // identical one, and both hot sliders round their raw drag value (warmth to 100 K,
        // DDC to whole percent) — so most drag ticks would otherwise re-render every view
        // observing the store at mouse-event rate. That was the visible slider lag.
        guard normalized != preferences else {
            return
        }
        preferences = normalized
    }

    func updateDisplayPreferences(
        for display: DisplayInfo,
        _ update: (inout DisplayPreferences) -> Void
    ) {
        var next = preferences
        var displayPreferences = next.displayPreferences[display.key, default: DisplayPreferences()]
        update(&displayPreferences)
        next.displayPreferences[display.key] = displayPreferences.normalized()
        let normalized = next.normalized()
        guard normalized != preferences else {
            return
        }
        preferences = normalized
    }

    /// Persist preferences shortly after the last change rather than on every mutation, so
    /// a continuous slider drag doesn't encode + write the whole blob dozens of times a
    /// second. Flushed eagerly on quit so nothing is lost.
    private func schedulePreferencesSave() {
        pendingPreferencesSave?.cancel()
        let snapshot = preferences
        let item = DispatchWorkItem { PreferencesStore.save(snapshot) }
        pendingPreferencesSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func flushPendingPreferencesSave() {
        guard let pending = pendingPreferencesSave else {
            return
        }
        pending.cancel()
        pendingPreferencesSave = nil
        PreferencesStore.save(preferences)
    }

    func exportedPreferencesData() throws -> Data {
        try PreferencesStore.exportData(preferences)
    }

    func importPreferences(from data: Data) throws {
        let imported = try PreferencesStore.importData(data)
        let loginItemChanged = preferences.startAtLogin != imported.startAtLogin
        schedulePreviewMinute = nil
        preferences = imported
        pendingPreferencesSave?.cancel()
        pendingPreferencesSave = nil
        PreferencesStore.save(imported)

        // Assigning `preferences` re-applies gamma/shades via didSet, and refreshDisplays()
        // below restores DDC values — but the media-key tap, the Carbon/media bindings, the
        // Dock policy, and the login item all hold state *outside* the struct, so their
        // appliers must re-run or the imported toggles silently don't take effect.
        refreshHotKeys()
        if !safeMode {
            if preferences.keyboardControlEnabled {
                keyboardStatus = keyboardService.start() ? "Active" : "Needs Accessibility permission"
            } else {
                keyboardService.stop()
                keyboardStatus = "Off"
            }
            accessibilityTrusted = keyboardService.hasAccessibilityPermission
        }
        refreshActivationPolicy()
        // Only touch the login item when the imported value differs — re-registering
        // unconditionally would replace the friendly "install the app first" status with a
        // raw service error on development builds.
        if loginItemChanged {
            do {
                try LoginItemService.setEnabled(imported.startAtLogin)
                loginItemMessage = LoginItemService.statusLabel()
            } catch {
                loginItemMessage = error.localizedDescription
            }
        }
        refreshDisplays()
    }

    func setStartAtLogin(_ isEnabled: Bool) {
        do {
            try LoginItemService.setEnabled(isEnabled)
            updateGlobalPreferences { preferences in
                preferences.startAtLogin = isEnabled
            }
            loginItemMessage = LoginItemService.statusLabel()
        } catch {
            loginItemMessage = error.localizedDescription
        }
    }

    func setShowInDock(_ isEnabled: Bool) {
        updateGlobalPreferences { preferences in
            preferences.showInDock = isEnabled
        }
        refreshActivationPolicy()
        // Dropping to .accessory deactivates the app, which would shove the settings window —
        // where this very toggle lives — behind other apps mid-click. That deactivation is
        // posted asynchronously, so re-assert front on the *next* runloop turn; doing it
        // inline races the deactivation and loses. Only the accessory direction needs this —
        // going .regular keeps the active window front on its own.
        guard !isEnabled, let window = windows.mainWindow, window.isVisible else { return }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func increaseFontSize() { setFontSizeStep(preferences.fontSizeStep + 1) }
    func decreaseFontSize() { setFontSizeStep(preferences.fontSizeStep - 1) }
    func resetFontSize() { setFontSizeStep(AppPreferences.defaultFontSizeStep) }

    private func setFontSizeStep(_ step: Int) {
        updateGlobalPreferences {
            $0.fontSizeStep = step.clamped(to: AppPreferences.fontSizeStepRange)
        }
    }

    /// The Dock icon follows the "Show in Dock" preference — and nothing else. An earlier
    /// design also forced a Dock icon while any titled window was open, but that masked the
    /// toggle: flipping it from the settings window (itself titled) visibly did nothing.
    /// Windows don't need the `.regular` policy — the open paths activate the app
    /// explicitly, which makes their window key and front in accessory mode too.
    func refreshActivationPolicy() {
        let policy: NSApplication.ActivationPolicy =
            showsDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    /// Normally the saved preference. `MONITORFLUX_FORCE_DOCK=on|off` overrides it so the
    /// smoke test can pin the launch policy and read it back from LaunchServices without
    /// mutating the developer's saved prefs — the activation policy is process state that
    /// no unit test can reach, and a MenuBarExtra app's AX tree vends no toggle to script.
    private var showsDockIcon: Bool {
        switch ProcessInfo.processInfo.environment["MONITORFLUX_FORCE_DOCK"] {
        case "on": return true
        case "off": return false
        default: return preferences.showInDock
        }
    }

    /// Open the main window and jump straight to a settings pane — used by the popup's tappable
    /// cards so e.g. a display card deep-links into that display's own settings.
    func openSettings(_ selection: AppSelection) {
        requestedSelection = selection
        showMainWindow()
    }

    /// Show the detailed window (built and re-anchored by `WindowCoordinator` — see there for
    /// the AppKit-not-WindowGroup rationale and the `activating:` test path).
    func showMainWindow(activating: Bool = true) {
        windows.showMainWindow(store: self, activating: activating)
    }

    /// Show the first-run welcome. Marked seen the moment it appears so it never pops twice —
    /// even if the user closes it with the window's close box instead of a button.
    func showOnboarding() {
        updateGlobalPreferences { preferences in
            preferences.hasSeenOnboarding = true
        }
        windows.showOnboarding(store: self)
    }

    /// Dismiss the welcome window (from a button or the close box). The seen flag was
    /// already set in `showOnboarding`.
    func completeOnboarding() {
        windows.completeOnboarding()
    }

    func setKeyboardControl(_ isEnabled: Bool) {
        updateGlobalPreferences { preferences in
            preferences.keyboardControlEnabled = isEnabled
        }
        if isEnabled {
            if keyboardService.start() {
                keyboardStatus = "Active"
            } else {
                requestAccessibility()
                keyboardStatus = "Grant Accessibility; MonitorFlux will start when you return"
            }
        } else {
            keyboardService.stop()
            keyboardStatus = "Off"
        }
        accessibilityTrusted = keyboardService.hasAccessibilityPermission
    }

    /// Re-read the Accessibility grant; if it just turned on and the user wants the media
    /// keys, start the tap so it works without re-toggling.
    func refreshAccessibilityStatus() {
        let trusted = keyboardService.hasAccessibilityPermission
        guard trusted != accessibilityTrusted else {
            return
        }
        accessibilityTrusted = trusted
        if trusted, preferences.keyboardControlEnabled, !safeMode {
            keyboardStatus = keyboardService.start() ? "Active" : keyboardStatus
        }
    }

    /// Show the system Accessibility prompt (only fires the first time per app identity) and
    /// open the Accessibility settings pane, so the user can grant it either way.
    func requestAccessibility() {
        keyboardService.requestAccessibilityPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Keyboard-control entry points, MonitorControl-style. Brightness/contrast target the
    /// external display under the cursor over DDC; the built-in panel's brightness is left
    /// to macOS. Color temperature is the global gamma warmth. Each returns true when
    /// handled, so the event tap swallows the key.
    /// - Parameter allowBuiltIn: when true, also drive the built-in panel's real backlight.
    ///   Media keys leave it false (macOS's own brightness keys handle the built-in); custom
    ///   hotkeys pass true, since there's no macOS fallback for a custom combo and the press
    ///   is user-initiated (so it's fine to override macOS, unlike the automatic schedule).
    func adjustBrightnessUnderCursor(by delta: Int, allowBuiltIn: Bool = false) -> Bool {
        guard let target = displayUnderCursor() else {
            return false
        }
        // Bare media keys leave the built-in panel to macOS (and a built-in with no backlight
        // API falls through too — `adjustBuiltInBrightness` is its custom-hotkey path).
        if target.isBuiltIn {
            guard allowBuiltIn, canUseNativeBrightness(target) else {
                return false
            }
        }
        return stepUnifiedBrightness(by: delta, for: target)
    }

    /// Step a display's brightness by `delta` points of the unified track and flash the OSD
    /// at the new position — so the keys walk the exact scale the slider shows: DDC (or the
    /// backlight) first, seamlessly across the notch into software dimming, holding at the
    /// floor. Returns false when the display has no adjustable path (non-DDC panel in
    /// Monitor-hardware mode), so the key falls through to macOS instead of being swallowed
    /// into a no-op.
    private func stepUnifiedBrightness(by delta: Int, for display: DisplayInfo) -> Bool {
        guard brightnessControlKind(for: display) != .unavailable else {
            return false
        }
        let next = (unifiedBrightness(for: display) + Double(delta) / 100.0).clamped(to: 0...1)
        setUnifiedBrightness(next, for: display)
        osd.show(.brightness, fraction: next, onDisplay: display.id)
        return true
    }

    func adjustContrastUnderCursor(by delta: Int) -> Bool {
        // Contrast is DDC-only for externals (there's no software-contrast path), so a non-DDC
        // monitor or the built-in panel lets the key fall through instead of swallowing a no-op.
        guard let target = displayUnderCursor(), !target.isBuiltIn, canUseDDC(for: target) else {
            return false
        }
        let current = displayPreferences(for: target).hardwareContrast
        let next = (current + delta).clamped(to: ControlRanges.hardwarePercent)
        setHardwareContrast(next, for: target)
        osd.show(.contrast, fraction: percentFraction(next), onDisplay: target.id)
        return true
    }

    /// Nudge the global color temperature by `delta` kelvin (±200 K normal, ±100 K fine),
    /// matching the Ambience slider: on a schedule it re-warms the phase that's active right
    /// now and stays Automatic; otherwise it pins a Fixed override. Positive cools (toward
    /// daylight), negative warms.
    func adjustColorTemperature(byKelvin delta: Int) -> Bool {
        let activePhase = ColorSchedule.currentPhase(preferences: preferences)
        let current = currentTemperature
            ?? (preferences.colorMode == .clock
                ? preferences.temperature(for: activePhase)
                : preferences.manualTemperature)
        let next = (current + delta).clamped(to: ControlRanges.kelvin)
        updateGlobalPreferences { preferences in
            preferences.gammaEnabled = true
            if preferences.colorMode == .clock {
                preferences.setTemperature(next, for: activePhase)
            } else {
                preferences.colorMode = .manual
                preferences.manualTemperature = next
            }
        }
        let span = Double(ControlRanges.kelvin.upperBound - ControlRanges.kelvin.lowerBound)
        let fraction = Double(next - ControlRanges.kelvin.lowerBound) / span
        osd.show(.color, fraction: fraction, onDisplay: displayUnderCursor()?.id)
        return true
    }

    func adjustVolumeUnderCursor(by delta: Int) -> Bool {
        // Volume rides DDC; a non-DDC monitor has no path, so let the key reach macOS instead of
        // swallowing it into a no-op.
        guard let target = displayUnderCursor(),
              shouldShowVolumeControl(for: target),
              canUseDDC(for: target) else {
            return false
        }
        let current = displayPreferences(for: target).hardwareVolume
        let next = (current + delta).clamped(to: ControlRanges.hardwarePercent)
        setHardwareVolume(next, for: target)
        osd.show(.volume, fraction: percentFraction(next), onDisplay: target.id)
        return true
    }

    private func percentFraction(_ percent: Int) -> Double {
        let range = ControlRanges.hardwarePercent
        return Double(percent - range.lowerBound) / Double(range.upperBound - range.lowerBound)
    }

    /// Flash a sample OSD — used only by `MONITORFLUX_SHOW_OSD` to screenshot the overlay.
    /// Targets the main display so a capture run knows which screen to grab.
    func showSampleOSD(_ kind: OSDController.Kind = .brightness, fraction: Double = 0.7) {
        osd.show(kind, fraction: fraction, onDisplay: CGMainDisplayID())
    }

    // MARK: - Custom global hotkeys

    private static let keyboardStep = 6
    private static let kelvinStep = 200
    /// Small steps for the fine (⌥) shortcut variants — the keyboard equivalent of a gentle
    /// slider nudge, like ⌥⇧ on the Mac's own brightness keys.
    private static let fineKeyboardStep = 1
    private static let fineKelvinStep = 100

    func hotkey(for action: HotKeyAction) -> ShortcutBinding? {
        preferences.hotkeys[action.rawValue]
    }

    /// Assign (or clear, with nil) a custom shortcut binding for an action and re-register.
    func setHotkey(_ shortcut: ShortcutBinding?, for action: HotKeyAction) {
        updateGlobalPreferences { preferences in
            preferences.hotkeys[action.rawValue] = shortcut
        }
        refreshHotKeys()
    }

    /// Turn the small-step (⌥) shortcut variants on or off and re-register bindings — off
    /// unregisters every fine shortcut, so ⌥ + media keys fall through to macOS again.
    func setFineAdjustments(_ isOn: Bool) {
        updateGlobalPreferences { preferences in
            preferences.fineAdjustmentsEnabled = isOn
        }
        refreshHotKeys()
    }

    private func refreshHotKeys() {
        guard !safeMode else {
            hotkeyConflicts = []
            keyboardService.mediaBindings = [:]
            return
        }
        // The resolution rules (defaults vs. customs, `.disabled`, the fine-adjustments gate)
        // live in the pure `HotkeyBindings.maps`.
        let maps = HotkeyBindings.maps(
            bindings: preferences.hotkeys,
            fineAdjustmentsEnabled: preferences.fineAdjustmentsEnabled
        )
        hotkeyConflicts = hotKeyCenter.update(maps.carbon)
        keyboardService.mediaBindings = maps.media
    }

    private func performHotKeyAction(_ action: HotKeyAction) {
        _ = performShortcutAction(action, allowBuiltInForPointerBrightness: true)
    }

    private func performMediaKeyAction(_ action: HotKeyAction) -> Bool {
        performShortcutAction(action, allowBuiltInForPointerBrightness: false)
    }

    private func performShortcutAction(
        _ action: HotKeyAction,
        allowBuiltInForPointerBrightness: Bool
    ) -> Bool {
        // Fine variants run the same adjustment as their base action, just with a small step.
        let step = action.isFine ? Self.fineKeyboardStep : Self.keyboardStep
        let kelvin = action.isFine ? Self.fineKelvinStep : Self.kelvinStep
        switch action {
        case .brightnessUp, .brightnessUpFine:
            return adjustBrightnessUnderCursor(by: step, allowBuiltIn: allowBuiltInForPointerBrightness)
        case .brightnessDown, .brightnessDownFine:
            return adjustBrightnessUnderCursor(by: -step, allowBuiltIn: allowBuiltInForPointerBrightness)
        case .contrastUp, .contrastUpFine:
            return adjustContrastUnderCursor(by: step)
        case .contrastDown, .contrastDownFine:
            return adjustContrastUnderCursor(by: -step)
        case .colorWarmer, .colorWarmerFine:
            return adjustColorTemperature(byKelvin: -kelvin)
        case .colorCooler, .colorCoolerFine:
            return adjustColorTemperature(byKelvin: kelvin)
        case .volumeUp:
            return adjustVolumeUnderCursor(by: step)
        case .volumeDown:
            return adjustVolumeUnderCursor(by: -step)
        case .builtInBrightnessUp, .builtInBrightnessUpFine:
            return adjustBuiltInBrightness(by: step)
        case .builtInBrightnessDown, .builtInBrightnessDownFine:
            return adjustBuiltInBrightness(by: -step)
        }
    }

    /// Built-in-set brightness: the unified walk over the backlight (continuing below its
    /// minimum in software when the hybrid opt-in is on), or software-only when the panel
    /// has no backlight API. Custom-hotkey-driven, so touching the backlight is fine.
    @discardableResult
    func adjustBuiltInBrightness(by delta: Int) -> Bool {
        guard let builtIn = displays.first(where: { $0.isBuiltIn }) else {
            return false
        }
        return stepUnifiedBrightness(by: delta, for: builtIn)
    }

    private func displayUnderCursor() -> DisplayInfo? {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber {
                let id = CGDirectDisplayID(number.uint32Value)
                if let match = displays.first(where: { $0.id == id }) {
                    return match
                }
            }
        }
        return displays.first(where: { !$0.isBuiltIn }) ?? displays.first
    }

    func canUseDDC(for display: DisplayInfo) -> Bool {
        guard !display.isBuiltIn else {
            return false
        }
        // Use the per-display probe (set on connect); assume capable until the first refresh.
        return ddcCapableByID[display.id] ?? true
    }

    /// Whether the display can dim its *real* backlight: the built-in panel through the native
    /// brightness API, or an external monitor through DDC (probed per-display on connect). When
    /// false, software (gamma) dimming is the fallback rather than an optional extra — it
    /// drives which brightness slider the popup shows.
    func canUseHardwareBrightness(_ display: DisplayInfo) -> Bool {
        if display.isBuiltIn {
            return canUseNativeBrightness(display)
        }
        return canUseDDC(for: display)
    }

    func applyBrightness(for display: DisplayInfo) {
        let displayPreferences = displayPreferences(for: display)
        runDDCCommand(
            kind: .brightness,
            label: "brightness",
            display: display,
            value: displayPreferences.hardwareBrightness,
            displayIndex: displayPreferences.ddcDisplayIndex
        )
    }

    func nudgeHardwareBrightness(for display: DisplayInfo, by delta: Int) {
        updateDisplayPreferences(for: display) { displayPreferences in
            displayPreferences.hardwareBrightness = (displayPreferences.hardwareBrightness + delta)
                .clamped(to: ControlRanges.hardwarePercent)
        }
        applyBrightness(for: display)
    }

    func applyContrast(for display: DisplayInfo) {
        let displayPreferences = displayPreferences(for: display)
        runDDCCommand(
            kind: .contrast,
            label: "contrast",
            display: display,
            value: displayPreferences.hardwareContrast,
            displayIndex: displayPreferences.ddcDisplayIndex
        )
    }

    func applyVolume(for display: DisplayInfo) {
        guard canUseDDC(for: display) else {
            reportDDCStatus(ddcUnavailableMessage(for: display))
            return
        }
        guard !safeMode else {
            reportDDCStatus("Safe mode — DDC not sent")
            return
        }
        let value = displayPreferences(for: display).hardwareVolume
        let backend = ddcBackend
        let displayName = display.name
        ddcQueue.async { [weak self] in
            let failureMessage: String?
            do {
                try backend.setVolume(value, display: display)
                failureMessage = nil
            } catch {
                failureMessage = error.localizedDescription
            }
            // DispatchQueue.main.async preserves submission (FIFO) order; separate Tasks
            // don't, so a stale "Applied N%" could otherwise land after a newer write.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failureMessage {
                        AppLog.ddc.error("volume write failed on \(displayName, privacy: .public): \(failureMessage, privacy: .public)")
                        self?.reportDDCStatus("Volume failed on \(displayName): \(failureMessage)", immediate: true)
                    } else {
                        AppLog.ddc.debug("Wrote volume \(value)% to \(displayName, privacy: .public)")
                        self?.reportDDCStatus("Applied volume \(value)% to \(displayName)")
                    }
                }
            }
        }
    }

    /// Live slider entry points for the quick-controls popup: update state now and
    /// coalesce the (slow) DDC write so a continuous drag doesn't flood the I2C bus.
    func setHardwareBrightness(_ value: Int, for display: DisplayInfo) {
        updateDisplayPreferences(for: display) { displayPreferences in
            displayPreferences.hardwareBrightness = value.clamped(to: ControlRanges.hardwarePercent)
        }
        scheduleDDC(key: "\(display.id).b", for: display) { [weak self] in
            self?.applyBrightness(for: display)
        }
    }

    func setHardwareContrast(_ value: Int, for display: DisplayInfo) {
        updateDisplayPreferences(for: display) { displayPreferences in
            displayPreferences.hardwareContrast = value.clamped(to: ControlRanges.hardwarePercent)
        }
        scheduleDDC(key: "\(display.id).c", for: display) { [weak self] in
            self?.applyContrast(for: display)
        }
    }

    func setHardwareVolume(_ value: Int, for display: DisplayInfo) {
        updateDisplayPreferences(for: display) { displayPreferences in
            displayPreferences.hardwareVolume = value.clamped(to: ControlRanges.hardwarePercent)
        }
        scheduleDDC(key: "\(display.id).v", for: display) { [weak self] in
            self?.applyVolume(for: display)
        }
    }

    /// Throttled DDC write for live slider drags (the timing lives in `DDCWriteScheduler`).
    private func scheduleDDC(key: String, for display: DisplayInfo, _ apply: @escaping () -> Void) {
        guard canUseDDC(for: display) else {
            return
        }
        ddcWriteScheduler.schedule(key: key, apply)
    }

    func restoreColorTables() {
        guard !safeMode else {
            return
        }
        // Only reset the tables if we wrote gamma this session — a no-write session must not
        // flicker on quit or clobber another color app's tables with a ColorSync reset.
        gammaService.restoreIfWritten()
        // Lift any AirPlay/virtual shade overlays too, so those screens return to full brightness
        // on quit (the shade isn't a gamma table, so the gamma restore above doesn't clear it).
        shadeController.removeAll()
        currentTemperature = nil
        colorMessage = "Color restored"
    }

    func disableColorAndRestore() {
        // `didSet` -> `reconcileColor` restores the tables, nils the temperature,
        // and updates `colorMessage` from the gamma service.
        updateGlobalPreferences { preferences in
            preferences.gammaEnabled = false
            // Software dimming is independent of the Warmth master, so the escape hatch must
            // also neutralize it — otherwise the tables would stay darkened after "restore".
            for key in preferences.displayPreferences.keys {
                preferences.displayPreferences[key]?.gammaBrightness = 100
            }
        }
    }

    private func reconcileColor() {
        // A held schedule preview wins: keep showing the scrubbed time. The 60s timer also lands
        // here, so without this it would snap the screen back to the live color mid-preview.
        if let minute = schedulePreviewMinute {
            applySchedulePreview(minute)
            return
        }
        let target = preferences.gammaEnabled
            ? ColorSchedule.targetTemperature(preferences: preferences)
            : nil
        // Publish only real changes — each @Published set is a full objectWillChange.
        if currentTemperature != target {
            currentTemperature = target
        }
        guard !safeMode else {
            colorMessage = "Safe mode — gamma not applied"
            return
        }
        // Ending all gamma output (Warmth off and no software dimming) clears the conflict banner
        // immediately — that's cheap (no LUT read), so it stays here for a responsive feel.
        // Detecting a *new* conflict is the expensive part (a per-display LUT read-back, plus a
        // running-app scan on a hit) and must NOT run here: this method fires on every
        // warmth/software-dim slider tick. `refreshGammaConflictState` does the detection on the
        // 60s timer and on display refresh, where an occasional check is plenty — a foreign gamma
        // app is a persistent condition, not one that appears between two drag frames.
        if !preferences.mayWriteGamma {
            gammaConflictDetected = false
            gammaConflictApps = []
        }
        let summary = gammaService.apply(
            displays: displays,
            preferences: preferences
        )
        if colorMessage != summary.message {
            colorMessage = summary.message
        }
    }

    /// Read the gamma LUT back to notice another app (Night Shift, f.lux…) fighting us for the
    /// single-owner gamma tables, naming the likely culprit. Deliberately kept off the per-drag
    /// `reconcileColor` path: the read-back is a CoreGraphics round-trip per display and, on a hit,
    /// an `NSWorkspace` running-app scan — fine once on the 60s timer or after a display change,
    /// wasteful at slider-drag frequency. Must run *before* `gammaService.apply` re-asserts our table
    /// (which would mask the foreign change). A freshly-detected conflict un-dismisses the banner.
    private func refreshGammaConflictState() {
        guard !safeMode, preferences.mayWriteGamma else {
            gammaConflictDetected = false
            gammaConflictApps = []
            return
        }
        let detected = gammaService.detectsForeignGammaChange(displays: displays)
        let wasDetected = gammaConflictDetected
        if detected, !wasDetected {
            gammaConflictBannerDismissed = false
        }
        gammaConflictDetected = detected
        // We can't ask the OS which process wrote the gamma table, so name any known gamma app
        // that's running as the likely cause.
        gammaConflictApps = detected ? GammaConflictApp.runningConflictingAppNames() : []
        // Log only the edges (detected / cleared), not every 60s poll while it persists.
        if detected, !wasDetected {
            let likely = gammaConflictApps.isEmpty ? "unknown app" : gammaConflictApps.joined(separator: ", ")
            AppLog.gamma.notice("Foreign gamma change detected (likely: \(likely, privacy: .public))")
        } else if !detected, wasDetected {
            AppLog.gamma.notice("Gamma conflict cleared")
        }
    }

    // MARK: - Schedule preview (scrub the curve to preview the screen's warmth)

    /// Scrub-preview the schedule: warm every gamma display to the curve's color at `minute`, so
    /// the user can see how the screen will look then. Temporary by design — `clearSchedulePreview`
    /// (called when the settings window reloads) restores the live color. The stored preferences
    /// are never touched, so nothing about the real schedule changes.
    func previewScheduleColor(atMinute minute: Int) {
        let clamped = minute.clamped(to: ControlRanges.minuteOfDay)
        schedulePreviewMinute = clamped
        // Scrubbing the time line commits to the schedule: adopt clock mode (turning Warmth on if
        // it was off, or switching from Manual), so the preview reflects the schedule the user is
        // now exploring. That mode change is real and persists; the preview itself stays temporary.
        if !preferences.gammaEnabled || preferences.colorMode != .clock {
            updateGlobalPreferences { preferences in
                preferences.gammaEnabled = true
                preferences.colorMode = .clock
            }
            // updateGlobalPreferences → reconcileColor, which honors schedulePreviewMinute and
            // applies the preview.
        } else {
            applySchedulePreview(clamped)
        }
    }

    /// Drop any active schedule preview and restore the live color. Idempotent.
    func clearSchedulePreview() {
        guard schedulePreviewMinute != nil else {
            return
        }
        schedulePreviewMinute = nil
        reconcileColor()
        restoreScheduledHardwareAfterPreview()
    }

    private func applySchedulePreview(_ minute: Int) {
        // What to show is computed by the pure `SchedulePreview.plan`: the warmth, a preview
        // copy of the preferences carrying the *software* brightness component (stored prefs
        // are never touched), and the transient DDC writes for the hardware component. The
        // live (now) schedule is suspended while previewing (see `applyScheduledHardware`);
        // `restoreScheduledHardwareAfterPreview` puts the now-targets back when it ends.
        let plan = SchedulePreview.plan(
            preferences: preferences,
            displays: displays.map { display in
                SchedulePreview.DisplayContext(
                    key: display.key,
                    id: display.id,
                    isBuiltIn: display.isBuiltIn,
                    isVirtual: display.isVirtual,
                    hasHardwareControl: canUseDDC(for: display),
                    dimmingMode: dimmingMode(for: display),
                    softwareFloor: softwareDimmingFloor(for: display)
                )
            },
            minuteOfDay: minute
        )
        currentTemperature = plan.temperature
        guard !safeMode else {
            colorMessage = "Safe mode — preview not applied"
            return
        }
        _ = gammaService.apply(displays: displays, preferences: plan.previewPreferences)
        for write in plan.hardwareWrites {
            guard let display = displays.first(where: { $0.id == write.displayID }) else {
                continue
            }
            previewHardwareDDC(
                write.kind,
                value: write.value,
                label: write.kind == .brightness ? "brightness" : "contrast",
                for: display
            )
        }
        colorMessage = "Preview · \(MinuteFormatting.label(for: minute)) · \(KelvinFormatting.label(for: plan.temperature))"
    }

    /// Send a brightness/contrast value to a display's DDC firmware *without* persisting it — the
    /// transient path the schedule scrub-preview uses, so scrubbing the curve never rewrites the
    /// user's stored hardware prefs (unlike `setHardwareBrightness`/`setHardwareContrast`). Throttled
    /// under the same per-control key as the live drag, so a continuous scrub doesn't flood the I2C
    /// bus and the post-preview now-write cleanly supersedes any still-pending preview write.
    private func previewHardwareDDC(_ kind: DDCControlKind, value: Int, label: String, for display: DisplayInfo) {
        let clamped = value.clamped(to: ControlRanges.hardwarePercent)
        let displayIndex = displayPreferences(for: display).ddcDisplayIndex
        let suffix = switch kind {
        case .brightness: "b"
        case .contrast: "c"
        }
        scheduleDDC(key: "\(display.id).\(suffix)", for: display) { [weak self] in
            self?.runDDCCommand(
                kind: kind,
                label: label,
                display: display,
                value: clamped,
                displayIndex: displayIndex
            )
        }
    }

    /// Re-apply each display's *current-time* scheduled brightness/contrast after a preview ends —
    /// the preview drove them to a different time, so force the now-targets back over it.
    private func restoreScheduledHardwareAfterPreview() {
        scheduledHardwareState = ScheduledHardware.State()
        applyScheduledHardware()
    }

    /// Hide the gamma-conflict banner until another foreign gamma change is detected.
    func dismissGammaConflictBanner() {
        gammaConflictBannerDismissed = true
    }

    /// The banner shows only when a conflict is currently detected and not dismissed.
    var showsGammaConflictBanner: Bool {
        gammaConflictDetected && !gammaConflictBannerDismissed
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let previousTemperature = self.currentTemperature
                // Detection reads the LUT, so it must run before reconcileColor re-applies our table.
                self.refreshGammaConflictState()
                self.reconcileColor()
                // Log only the *automatic* clock advance (not manual drags, which never route
                // through this timer) so a bug report shows warmth changing on its own.
                if self.preferences.colorMode == .clock,
                   self.currentTemperature != previousTemperature,
                   let temperature = self.currentTemperature {
                    AppLog.gamma.notice("Scheduled warmth advanced to \(temperature, privacy: .public) K")
                }
                self.applyScheduledHardware()
            }
        }
        timer?.tolerance = 10
    }

    /// Drive each display's scheduled brightness/contrast toward its day/night target.
    /// Called from the minute timer and after display/preference changes. The routing rules
    /// and the "only write when the target changes" tracking live in the pure
    /// `ScheduledHardware.plan`; this executes the writes it returns.
    /// - Parameter automatic: true for timer/wake/hotplug-driven runs (logged at `.notice`, so
    ///   an on-its-own change lands in a bug report); false when the user is editing a schedule
    ///   slider (logged at `.debug`, so a drag doesn't flood the report).
    func applyScheduledHardware(automatic: Bool = true) {
        guard !displays.isEmpty else {
            return
        }
        // While a schedule preview is held it drives brightness/contrast to the previewed time;
        // don't let the live (now) schedule fight it. `restoreScheduledHardwareAfterPreview`
        // re-applies the now-targets once the preview ends.
        guard schedulePreviewMinute == nil else {
            return
        }
        let effective = ColorSchedule.solarAdjustedPreferences(preferences)
        let calendar = Calendar.current
        let now = Date()
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

        let contexts = displays.map { display in
            ScheduledHardware.DisplayContext(
                id: display.id,
                isBuiltIn: display.isBuiltIn,
                hasControllableBacklight: canUseNativeBrightness(display),
                preferences: displayPreferences(for: display)
            )
        }
        let (writes, state) = ScheduledHardware.plan(
            displays: contexts,
            preferences: effective,
            minuteOfDay: minute,
            state: scheduledHardwareState
        )
        scheduledHardwareState = state

        for write in writes {
            guard let display = displays.first(where: { $0.id == write.displayID }) else {
                continue
            }
            let control = write.control == .brightness ? "brightness" : "contrast"
            if automatic {
                AppLog.schedule.notice("Schedule set \(control, privacy: .public) to \(write.target)% on \(display.name, privacy: .public)")
            } else {
                AppLog.schedule.debug("Schedule set \(control, privacy: .public) to \(write.target)% on \(display.name, privacy: .public)")
            }
            switch write.control {
            case .brightness:
                applyScheduledBrightness(write.target, for: display)
            case .contrast:
                setHardwareContrast(write.target, for: display)
            }
        }
    }

    private func applyScheduledBrightness(_ value: Int, for display: DisplayInfo) {
        // The built-in backlight is macOS-managed (auto-brightness / ambient sensor). Forcing
        // a scheduled level onto it fights macOS and jumps the brightness on every launch, so
        // the schedule never drives it — not even the software zone of a hybrid opt-in. Only
        // built-ins with no backlight API at all fall through to software dimming below.
        if display.isBuiltIn, canUseNativeBrightness(display) {
            return
        }
        // AirPlay/virtual screens dim via the shade overlay (its own never-black cap lives in
        // ShadeController); the write rides the normal didSet → reconcileShades path.
        if display.isVirtual {
            updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences.gammaBrightness = value.clamped(to: ControlRanges.hardwarePercent)
            }
            return
        }
        // Wired panel: the target is a *unified* position, routed per dimming mode — DDC plus
        // the software zone in Automatic (a 20% night target lands below the notch instead of
        // clamping at DDC 0), DDC only in Monitor hardware, the floored software-only track in
        // Software dimming and on panels with no DDC path. The canonical split also heals any
        // mixed state the schedule encounters. Gamma rides didSet → reconcileColor.
        let (hardware, gamma) = HybridBrightness.scheduledComponents(
            target: value,
            mode: dimmingMode(for: display),
            hasHardwareControl: canUseDDC(for: display),
            floor: softwareDimmingFloor(for: display)
        )
        if let hardware {
            setHardwareBrightness(hardware, for: display)
        }
        if let gamma {
            updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences.gammaBrightness = gamma
            }
        }
    }

    /// Re-evaluate the schedule for a display immediately (e.g. after the user toggles it on
    /// or edits a day/night target), bypassing the "unchanged target" guard so it applies now.
    func reapplySchedule(for display: DisplayInfo) {
        scheduledHardwareState.clear(display.id)
        // User-initiated (editing a schedule slider), so log the writes at .debug, not .notice.
        applyScheduledHardware(automatic: false)
    }

    private func seedMissingDisplayPreferences() -> Bool {
        var next = preferences
        var changed = false
        var externalIndex = 1

        for display in displays {
            if next.displayPreferences[display.key] == nil {
                // Carry settings forward from the old display-ID key (pre stable-identity
                // builds) when this monitor is still on the same ID this session, so the
                // switch to a stable key doesn't reset the user's brightness/contrast/color.
                let legacyKey = String(display.id)
                if legacyKey != display.key, let legacy = next.displayPreferences[legacyKey] {
                    next.displayPreferences[display.key] = legacy
                    next.displayPreferences[legacyKey] = nil
                } else {
                    var displayPreferences = DisplayPreferences()
                    displayPreferences.ddcDisplayIndex = display.isBuiltIn ? 1 : externalIndex
                    // `dimmingMode` stays unset: `dimmingMode(for:)` resolves the per-kind
                    // default (externals hybrid, built-in hardware-only).
                    next.displayPreferences[display.key] = displayPreferences
                }
                changed = true
            }

            if !display.isBuiltIn {
                externalIndex += 1
            }
        }

        if changed {
            preferences = next.normalized()
        }
        return changed
    }

    /// Fold legacy built-in dimming state into the built-in's real default: the backlight.
    ///
    /// The normalization rules live in the pure `BuiltInDimming.normalized` (see there for the
    /// history); this applies them to every built-in whose slider currently drives the real
    /// backlight (`.hardwareOnly`). Built-ins with no backlight API (still `.softwareOnly`) or
    /// an explicit software choice are left untouched. Returns true when a dim was cleared —
    /// a color-affecting change the `preferences` didSet already re-applied — so the caller
    /// can skip a redundant `reconcileColor()`.
    private func reconcileBuiltInDimming() -> Bool {
        var next = preferences
        var changed = false
        var clearedGamma = false

        for display in displays where display.isBuiltIn {
            guard let displayPreferences = next.displayPreferences[display.key],
                  brightnessControlKind(for: display) == .hardwareOnly,
                  let normalization = BuiltInDimming.normalized(displayPreferences)
            else {
                continue
            }
            next.displayPreferences[display.key] = normalization.preferences
            changed = true
            clearedGamma = clearedGamma || normalization.clearedGamma
        }

        if changed {
            preferences = next.normalized()
        }
        return clearedGamma
    }

    private func runDDCCommand(
        kind: DDCControlKind,
        label: String,
        display: DisplayInfo,
        value: Int,
        displayIndex: Int
    ) {
        guard canUseDDC(for: display) else {
            reportDDCStatus(ddcUnavailableMessage(for: display))
            return
        }
        guard !safeMode else {
            reportDDCStatus("Safe mode — DDC not sent")
            return
        }

        let backend = ddcBackend
        let displayName = display.name

        ddcQueue.async { [weak self] in
            let failureMessage: String?
            do {
                switch kind {
                case .brightness:
                    try backend.setBrightness(value, display: display, fallbackIndex: displayIndex)
                case .contrast:
                    try backend.setContrast(value, display: display, fallbackIndex: displayIndex)
                }
                failureMessage = nil
            } catch {
                failureMessage = error.localizedDescription
            }
            // FIFO main-queue hop so status messages can't arrive out of order (see applyVolume).
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let failureMessage {
                        AppLog.ddc.error("\(label, privacy: .public) write failed on \(displayName, privacy: .public): \(failureMessage, privacy: .public)")
                        self?.reportDDCStatus("\(label.capitalized) failed on \(displayName): \(failureMessage)", immediate: true)
                    } else {
                        // Per-write success is drag-frequency, so .debug (streamable, not persisted).
                        AppLog.ddc.debug("Wrote \(label, privacy: .public) \(value)% to \(displayName, privacy: .public)")
                        self?.reportDDCStatus("Applied \(label) \(value)% to \(displayName)")
                    }
                }
            }
        }
    }

    /// Why a DDC write to this display was skipped. The old text here was the backend's *name*
    /// ("Native DDC"), which read as a non-sequitur in the status line — say what's actually
    /// wrong with this display instead.
    private func ddcUnavailableMessage(for display: DisplayInfo) -> String {
        display.isBuiltIn
            ? "Built-in displays do not use DDC"
            : "\(display.name) doesn't expose DDC on this connection"
    }

    /// Publish a DDC status line without re-rendering the world on every write. `ddcMessage`
    /// is `@Published`, and `objectWillChange` is object-level — so the old per-write
    /// "Applying… / Applied…" pair invalidated every observing view ~40×/s during a drag,
    /// a hidden contributor to slider lag. Successes coalesce on a short trailing window
    /// (the settled value still lands); failures publish immediately.
    private func reportDDCStatus(_ message: String, immediate: Bool = false) {
        pendingDDCMessage?.cancel()
        pendingDDCMessage = nil
        if immediate {
            if ddcMessage != message {
                ddcMessage = message
            }
            return
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingDDCMessage = nil
                if self.ddcMessage != message {
                    self.ddcMessage = message
                }
            }
        }
        pendingDDCMessage = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
}

/// What a display's everyday Brightness slider drives (see
/// `AppStore.brightnessControlKind(for:)`), so the popup and the detail pane render the
/// same track for the same display.
enum BrightnessControlKind: Equatable {
    /// Unified two-zone track: hardware above the handoff notch, software (gamma) below.
    case hybrid
    /// Hardware only — DDC 0–100, or the built-in backlight.
    case hardwareOnly
    /// Software only — the whole track maps to gamma floor…100.
    case softwareOnly
    /// AirPlay/virtual: the shade overlay, 0–100.
    case shade
    /// No working path (non-DDC external in Monitor-hardware mode): disabled slider + hint.
    case unavailable
}

/// CoreGraphics display-reconfiguration callback (C calling convention, so it can't
/// capture context). The `AppStore` arrives via the registered context pointer; we
/// forward to it on the main actor.
private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else {
        return
    }
    let store = Unmanaged<AppStore>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in
        store.handleDisplayReconfiguration()
    }
}
