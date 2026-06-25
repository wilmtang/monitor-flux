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
            if oldValue.colorSignature != preferences.colorSignature {
                reconcileColor()
            }
        }
    }
    @Published private(set) var currentTemperature: Int?
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
    private var mainWindow: MainWindow?
    private var onboardingWindow: NSWindow?
    private var timer: Timer?
    /// Trailing (coalesced) DDC writes per control, and the last time each one actually
    /// wrote, so `scheduleDDC` can throttle a drag instead of only firing on release.
    private var ddcWriteWorkItems: [String: DispatchWorkItem] = [:]
    /// Last brightness/contrast the schedule wrote per display. We only re-apply when the
    /// scheduled target changes, so a manual adjustment between phase transitions sticks
    /// (f.lux-style) instead of being snapped back on the next tick.
    private var lastScheduledBrightness: [CGDirectDisplayID: Int] = [:]
    private var lastScheduledContrast: [CGDirectDisplayID: Int] = [:]
    private var ddcLastWrite: [String: DispatchTime] = [:]
    /// Serializes the actual I2C writes so a throttled drag can't overlap two writes to
    /// the same bus. `.userInitiated` keeps the monitor responsive during a drag.
    private let ddcQueue = DispatchQueue(label: "app.monitorflux.ddc", qos: .userInitiated)
    private var pendingPreferencesSave: DispatchWorkItem?
    private var displayRefreshGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
        safeMode = ProcessInfo.processInfo.environment["MONITORFLUX_SAFE_MODE"] == "1"
        preferences = PreferencesStore.load().normalized()
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
        // The display layout may have changed; cached DDC service handles can be stale.
        ddcBackend.invalidateServiceCache()
        displays = displayService.listDisplays() + mockDisplaySpecs.map(\.display)
        refreshNativeBrightness()
        refreshAudioCapability()
        refreshDDCCapability()
        if !seedMissingDisplayPreferences() {
            reconcileColor()
        }
        applyScheduledHardware()
        restoreHardwareSettings()
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
    /// popup's multi-card behaviour (drag-to-reorder, tap-to-open) and the per-display
    /// DDC-vs-software-dimming fallback can be exercised on a machine with only the built-in
    /// panel. Even-indexed mocks are marked DDC-capable, odd-indexed ones non-DDC, so both
    /// brightness-slider paths are visible. Their (no-op) hardware writes are best run under
    /// `MONITORFLUX_SAFE_MODE=1`. Inert unless the variable is set.
    private var mockDisplaySpecs: [(display: DisplayInfo, ddcCapable: Bool)] {
        guard let raw = ProcessInfo.processInfo.environment["MONITORFLUX_FAKE_DISPLAYS"],
              let count = Int(raw), count > 0 else {
            return []
        }
        return (0..<min(count, 4)).map { index in
            let capable = index % 2 == 0
            return (
                DisplayInfo(
                    id: CGDirectDisplayID(0xF000_0001 + UInt32(index)),
                    name: "\(capable ? "Mock DDC" : "Mock non-DDC") Monitor \(index + 1)",
                    persistentID: "mock-display-\(index)",
                    frameDescription: "2560 × 1440",
                    isBuiltIn: false,
                    isOnline: true
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

    private func refreshNativeBrightness() {
        var levels: [CGDirectDisplayID: Double] = [:]
        for display in displays where nativeBrightnessBackend.canControl(display.id) {
            if let value = nativeBrightnessBackend.brightness(of: display.id) {
                levels[display.id] = Double(value)
            }
        }
        nativeBrightness = levels
    }

    func displayPreferences(for display: DisplayInfo) -> DisplayPreferences {
        preferences.displayPreferences[display.key, default: DisplayPreferences()]
    }

    /// The popup's display cards in the user's chosen order (drag-to-reorder). Displays not yet
    /// in `displayOrder` — freshly connected ones — follow the ordered set in detection order.
    var orderedDisplays: [DisplayInfo] {
        let byKey = Dictionary(displays.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return DisplayOrdering.sorted(displays.map(\.key), by: preferences.displayOrder)
            .compactMap { byKey[$0] }
    }

    /// Persist a new card order, moving `draggedKey` to just before `targetKey`.
    func moveDisplay(key draggedKey: String, before targetKey: String) {
        let newOrder = DisplayOrdering.reordered(
            orderedDisplays.map(\.key),
            moving: draggedKey,
            before: targetKey
        )
        updateGlobalPreferences { $0.displayOrder = newOrder }
    }

    func updateGlobalPreferences(_ update: (inout AppPreferences) -> Void) {
        var next = preferences
        update(&next)
        preferences = next.normalized()
    }

    func updateDisplayPreferences(
        for display: DisplayInfo,
        _ update: (inout DisplayPreferences) -> Void
    ) {
        var next = preferences
        var displayPreferences = next.displayPreferences[display.key, default: DisplayPreferences()]
        update(&displayPreferences)
        next.displayPreferences[display.key] = displayPreferences.normalized()
        preferences = next.normalized()
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
    }

    /// The app launches as a menu-bar accessory (no Dock icon). It shows a Dock icon
    /// when the user enables "Show in Dock", or temporarily while a standard window is
    /// open so the window can become key and front even in accessory mode.
    func refreshActivationPolicy() {
        let hasStandardWindow = NSApp.windows.contains { window in
            window.isVisible && window.styleMask.contains(.titled)
        }
        let policy: NSApplication.ActivationPolicy =
            (preferences.showInDock || hasStandardWindow) ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    /// Show the detailed window. It's managed with AppKit rather than a SwiftUI
    /// `WindowGroup` so there is exactly one instance and its content/environment always
    /// binds — `openWindow` from a `.window` `MenuBarExtra` in an accessory app opens
    /// blank, duplicate windows.
    /// - Parameter activating: when true (the real "Settings…" path) the app comes to the
    ///   foreground and the window takes keyboard focus. The smoke test passes false so it
    ///   can put the window on screen for `CGWindowList` without yanking focus away from
    ///   whatever the user is doing while tests run.
    /// Open the main window and jump straight to a settings pane — used by the popup's tappable
    /// cards so e.g. a display card deep-links into that display's own settings.
    func openSettings(_ selection: AppSelection) {
        requestedSelection = selection
        showMainWindow()
    }

    func showMainWindow(activating: Bool = true) {
        let window = mainWindow ?? makeMainWindow()
        mainWindow = window
        // Reopening a closed window, or restoring a frame saved on a now-disconnected
        // display, can leave it sized or positioned off every screen — it orders front
        // but is invisible, so "Settings" looks like it does nothing. Re-anchor first.
        ensureWindowIsUsable(window)
        if activating {
            window.allowsActivation = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            // Test path: the window must appear on screen for CGWindowList, but showing it
            // must not pull focus from the developer's work. Making the window unable to
            // become key/main means ordering it front doesn't activate the app — which is
            // exactly what was stealing focus when running the tests.
            window.allowsActivation = false
            window.orderFront(nil)
        }
    }

    private static let mainWindowDefaultSize = NSSize(width: 880, height: 600)

    private func makeMainWindow() -> MainWindow {
        // A hosting *controller* (not a bare NSHostingView) is what renders a
        // NavigationSplitView's sidebar + detail correctly, and its default
        // `sizingOptions` must stay (clearing them renders the columns blank). Those
        // options size the window to SwiftUI's fitting height, though, which for a tall
        // detail pane is enormous — that was the off-screen "blank window". Pinning an
        // ideal size on the root bounds the fitting height to 880x600 so the window opens
        // and reopens at a sane size, while `maxWidth/Height: .infinity` still lets the
        // user resize it. Detail panes scroll internally (see ColorScheduleView).
        let root = ContentView()
            .environmentObject(self)
            .frame(
                minWidth: 720, idealWidth: Self.mainWindowDefaultSize.width, maxWidth: .infinity,
                minHeight: 500, idealHeight: Self.mainWindowDefaultSize.height, maxHeight: .infinity
            )
        let controller = NSHostingController(rootView: root)
        let window = MainWindow(contentViewController: controller)
        window.title = "MonitorFlux"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.mainWindowDefaultSize)
        window.contentMinSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.setFrameAutosaveName("MonitorFluxMainWindow")
        return window
    }

    /// Show the first-run welcome. Marked seen the moment it appears so it never pops twice —
    /// even if the user closes it with the window's close box instead of a button. Activates the
    /// app (unlike the test-driven window paths) because first launch is a deliberate "look here".
    func showOnboarding() {
        updateGlobalPreferences { preferences in
            preferences.hasSeenOnboarding = true
        }
        let window = onboardingWindow ?? makeOnboardingWindow()
        onboardingWindow = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Dismiss the welcome window (from a button or the close box) and drop back to the normal
    /// activation policy. The seen flag was already set in `showOnboarding`.
    func completeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        refreshActivationPolicy()
    }

    private func makeOnboardingWindow() -> NSWindow {
        // Same NSHostingController pattern as the main window (a bare NSHostingView mis-renders),
        // but a small, fixed, non-resizable sheet — the content is pinned to its own frame.
        let root = OnboardingView()
            .environmentObject(self)
        let controller = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: controller)
        window.title = "Welcome to MonitorFlux"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        return window
    }

    /// Reset the window to a sane, on-screen frame when it would otherwise be invisible:
    /// larger than any display, or with too little overlap with a screen to see or grab.
    /// A well-placed, user-resized frame is left untouched.
    private func ensureWindowIsUsable(_ window: NSWindow) {
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        guard !visibleFrames.isEmpty else {
            return
        }
        let frame = window.frame
        let frameArea = frame.width * frame.height

        let oversized = visibleFrames.allSatisfy { screen in
            frame.width > screen.width || frame.height > screen.height
        }
        let visibleArea = visibleFrames.reduce(CGFloat(0)) { total, screen in
            let overlap = screen.intersection(frame)
            return overlap.isNull ? total : total + overlap.width * overlap.height
        }
        let mostlyOffscreen = frameArea <= 0 || visibleArea < frameArea * 0.5

        if oversized || mostlyOffscreen {
            window.setContentSize(Self.mainWindowDefaultSize)
            window.center()
        }
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
        if target.isBuiltIn {
            guard allowBuiltIn, canUseNativeBrightness(target) else {
                return false
            }
            let next = (nativeBrightnessValue(for: target) + Double(delta) / 100.0).clamped(to: 0...1)
            setNativeBrightness(next, for: target)
            osd.show(.brightness, fraction: next, onDisplay: target.id)
            return true
        }
        // External with a DDC path: drive the real backlight over DDC.
        if canUseDDC(for: target) {
            let current = displayPreferences(for: target).hardwareBrightness
            let next = (current + delta).clamped(to: ControlRanges.hardwarePercent)
            setHardwareBrightness(next, for: target)
            osd.show(.brightness, fraction: percentFraction(next), onDisplay: target.id)
            return true
        }
        // No DDC path to the backlight — software-dim via gamma, the same fallback the popup
        // shows for a non-DDC monitor. Only when gamma can actually take effect; otherwise let
        // the key fall through to macOS rather than swallowing it into a no-op (the bug that made
        // brightness keys feel dead on a monitor the DDC probe can't drive).
        guard preferences.gammaEnabled, displayPreferences(for: target).gammaControlsEnabled else {
            return false
        }
        let next = (displayPreferences(for: target).gammaBrightness + delta)
            .clamped(to: ControlRanges.gammaBrightnessPercent)
        updateDisplayPreferences(for: target) { $0.gammaBrightness = next }
        osd.show(.brightness, fraction: Double(next) / 100.0, onDisplay: target.id)
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

    /// Nudge the global color temperature (200 K per step) and pin it as a manual override,
    /// matching the Ambience slider. Positive steps cool (toward daylight), negative warm.
    func adjustColorTemperature(bySteps steps: Int) -> Bool {
        let current = currentTemperature
            ?? (preferences.colorMode == .manual ? preferences.manualTemperature : preferences.dayTemperature)
        let next = (current + steps * 200).clamped(to: ControlRanges.kelvin)
        updateGlobalPreferences { preferences in
            preferences.gammaEnabled = true
            preferences.colorMode = .manual
            preferences.manualTemperature = next
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
    func showSampleOSD(_ kind: OSDController.Kind = .brightness, fraction: Double = 0.7) {
        osd.show(kind, fraction: fraction, onDisplay: displays.first?.id)
    }

    // MARK: - Custom global hotkeys

    private static let keyboardStep = 6

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

    private func refreshHotKeys() {
        guard !safeMode else {
            hotkeyConflicts = []
            keyboardService.mediaBindings = [:]
            return
        }
        var carbonMap: [HotKeyAction: GlobalShortcut] = [:]
        var mediaMap: [MediaKeyShortcut: HotKeyAction] = [:]

        for action in HotKeyAction.allCases {
            guard preferences.hotkeys[action.rawValue] == nil,
                  let shortcut = action.mediaShortcut
            else {
                continue
            }
            mediaMap[shortcut] = action
        }

        for (key, binding) in preferences.hotkeys {
            guard let action = HotKeyAction(rawValue: key) else { continue }
            switch binding {
            case .disabled:
                continue
            case .keyboard(let shortcut):
                carbonMap[action] = shortcut
            case .media(let shortcut):
                mediaMap[shortcut] = action
            }
        }
        hotkeyConflicts = hotKeyCenter.update(carbonMap)
        keyboardService.mediaBindings = mediaMap
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
        let step = Self.keyboardStep
        switch action {
        case .brightnessUp:
            return adjustBrightnessUnderCursor(by: step, allowBuiltIn: allowBuiltInForPointerBrightness)
        case .brightnessDown:
            return adjustBrightnessUnderCursor(by: -step, allowBuiltIn: allowBuiltInForPointerBrightness)
        case .contrastUp:
            return adjustContrastUnderCursor(by: step)
        case .contrastDown:
            return adjustContrastUnderCursor(by: -step)
        case .colorWarmer:
            return adjustColorTemperature(bySteps: -1)
        case .colorCooler:
            return adjustColorTemperature(bySteps: 1)
        case .volumeUp:
            return adjustVolumeUnderCursor(by: step)
        case .volumeDown:
            return adjustVolumeUnderCursor(by: -step)
        case .builtInBrightnessUp:
            return adjustBuiltInBrightness(by: step)
        case .builtInBrightnessDown:
            return adjustBuiltInBrightness(by: -step)
        }
    }

    /// Built-in-set brightness: the real backlight (or software gamma if no backlight API).
    @discardableResult
    func adjustBuiltInBrightness(by delta: Int) -> Bool {
        guard let builtIn = displays.first(where: { $0.isBuiltIn }) else {
            return false
        }
        if canUseNativeBrightness(builtIn) {
            let next = (nativeBrightnessValue(for: builtIn) + Double(delta) / 100.0).clamped(to: 0...1)
            setNativeBrightness(next, for: builtIn)
            osd.show(.brightness, fraction: next, onDisplay: builtIn.id)
        } else {
            let next = (displayPreferences(for: builtIn).gammaBrightness + delta)
                .clamped(to: ControlRanges.gammaBrightnessPercent)
            updateDisplayPreferences(for: builtIn) { $0.gammaBrightness = next }
            osd.show(.brightness, fraction: Double(next) / 100.0, onDisplay: builtIn.id)
        }
        return true
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
    /// false, software (gamma) dimming is the fallback rather than an optional extra — so this
    /// drives both the default for `gammaControlsEnabled` and which brightness slider the popup
    /// shows.
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
            ddcMessage = display.isBuiltIn ? "Built-in displays do not use DDC" : ddcStatus.message
            return
        }
        guard !safeMode else {
            ddcMessage = "Safe mode — DDC not sent"
            return
        }
        let value = displayPreferences(for: display).hardwareVolume
        ddcMessage = "Applying volume \(value)% to \(display.name)"
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
                    self?.ddcMessage = failureMessage ?? "Applied volume \(value)% to \(displayName)"
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

    /// How often a held drag is allowed to push a DDC write. Throttling (rather than the
    /// old trailing-only debounce) lets the monitor track the slider live instead of only
    /// jumping once the user lets go — the behaviour that made MonitorControl feel smoother.
    private static let ddcThrottleInterval = 0.045

    private func scheduleDDC(key: String, for display: DisplayInfo, _ apply: @escaping () -> Void) {
        guard canUseDDC(for: display) else {
            return
        }
        let now = DispatchTime.now()
        let elapsed = ddcLastWrite[key].map {
            Double(now.uptimeNanoseconds &- $0.uptimeNanoseconds) / 1_000_000_000
        } ?? .infinity

        // A newer value supersedes any still-pending trailing write for this control.
        ddcWriteWorkItems[key]?.cancel()
        ddcWriteWorkItems[key] = nil

        guard elapsed < Self.ddcThrottleInterval else {
            // Leading edge: enough time has passed, write now so the monitor tracks.
            ddcLastWrite[key] = now
            apply()
            return
        }

        // Trailing edge: coalesce until the throttle window elapses, then write the
        // latest value so the drag still settles on exactly where the user left it.
        let delay = Self.ddcThrottleInterval - elapsed
        let item = DispatchWorkItem { [weak self] in
            self?.ddcWriteWorkItems[key] = nil
            self?.ddcLastWrite[key] = DispatchTime.now()
            apply()
        }
        ddcWriteWorkItems[key] = item
        DispatchQueue.main.asyncAfter(deadline: now + delay, execute: item)
    }

    func restoreColorTables() {
        guard !safeMode else {
            return
        }
        gammaService.restore()
        currentTemperature = nil
        colorMessage = "Color restored"
    }

    func disableColorAndRestore() {
        // `didSet` -> `reconcileColor` restores the tables, nils the temperature,
        // and updates `colorMessage` from the gamma service.
        updateGlobalPreferences { preferences in
            preferences.gammaEnabled = false
        }
    }

    private func reconcileColor() {
        currentTemperature = preferences.gammaEnabled
            ? ColorSchedule.targetTemperature(preferences: preferences)
            : nil
        guard !safeMode else {
            colorMessage = "Safe mode — gamma not applied"
            return
        }
        // Read the LUT back (before re-applying) to notice another gamma app fighting us.
        // A freshly-detected conflict un-dismisses the banner so it reappears.
        if preferences.gammaEnabled {
            let detected = gammaService.detectsForeignGammaChange(displays: displays)
            if detected, !gammaConflictDetected {
                gammaConflictBannerDismissed = false
            }
            gammaConflictDetected = detected
            // We can't ask the OS which process wrote the gamma table, so name any known gamma
            // app that's running as the likely cause.
            gammaConflictApps = detected ? GammaConflictApp.runningConflictingAppNames() : []
        } else {
            gammaConflictDetected = false
            gammaConflictApps = []
        }
        let summary = gammaService.apply(
            displays: displays,
            preferences: preferences
        )
        colorMessage = summary.message
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
                self?.reconcileColor()
                self?.applyScheduledHardware()
            }
        }
        timer?.tolerance = 10
    }

    /// Drive each display's scheduled brightness/contrast toward its day/night target.
    /// Called from the minute timer and after display/preference changes. Only writes when
    /// the scheduled target actually changes (see `lastScheduled*`), so manual tweaks hold.
    func applyScheduledHardware() {
        guard !displays.isEmpty else {
            return
        }
        let effective = ColorSchedule.solarAdjustedPreferences(preferences)
        let calendar = Calendar.current
        let now = Date()
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)

        for display in displays {
            let displayPreferences = displayPreferences(for: display)

            if displayPreferences.scheduleBrightness {
                let target = ColorSchedule.scheduledHardwareLevel(
                    dayValue: displayPreferences.dayBrightness,
                    nightValue: displayPreferences.nightBrightness,
                    preferences: effective,
                    minuteOfDay: minute
                )
                if lastScheduledBrightness[display.id] != target {
                    lastScheduledBrightness[display.id] = target
                    applyScheduledBrightness(target, for: display)
                }
            } else {
                lastScheduledBrightness[display.id] = nil
            }

            // Contrast is a DDC-only control, so the schedule skips the built-in panel.
            if displayPreferences.scheduleContrast, !display.isBuiltIn {
                let target = ColorSchedule.scheduledHardwareLevel(
                    dayValue: displayPreferences.dayContrast,
                    nightValue: displayPreferences.nightContrast,
                    preferences: effective,
                    minuteOfDay: minute
                )
                if lastScheduledContrast[display.id] != target {
                    lastScheduledContrast[display.id] = target
                    setHardwareContrast(target, for: display)
                }
            } else {
                lastScheduledContrast[display.id] = nil
            }
        }
    }

    private func applyScheduledBrightness(_ value: Int, for display: DisplayInfo) {
        if display.isBuiltIn {
            // The built-in backlight is macOS-managed (auto-brightness, Night Shift). Forcing
            // a scheduled level onto it fights macOS and jumps the brightness on every launch,
            // so leave the real backlight to macOS. Only software-dim built-ins that expose no
            // backlight API at all.
            guard !canUseNativeBrightness(display) else {
                return
            }
            updateDisplayPreferences(for: display) { displayPreferences in
                displayPreferences.gammaBrightness = value.clamped(to: ControlRanges.gammaBrightnessPercent)
            }
        } else {
            setHardwareBrightness(value, for: display)
        }
    }

    /// Re-evaluate the schedule for a display immediately (e.g. after the user toggles it on
    /// or edits a day/night target), bypassing the "unchanged target" guard so it applies now.
    func reapplySchedule(for display: DisplayInfo) {
        lastScheduledBrightness[display.id] = nil
        lastScheduledContrast[display.id] = nil
        applyScheduledHardware()
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
                    // Software dimming defaults OFF when the display can dim in hardware (native
                    // backlight or DDC) — it's the fallback only for panels with no hardware path.
                    // Existing, already-seeded displays keep whatever the user has set.
                    displayPreferences.gammaControlsEnabled = !canUseHardwareBrightness(display)
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

    private func runDDCCommand(
        kind: DDCControlKind,
        label: String,
        display: DisplayInfo,
        value: Int,
        displayIndex: Int
    ) {
        guard canUseDDC(for: display) else {
            ddcMessage = display.isBuiltIn
                ? "Built-in displays do not use DDC"
                : ddcStatus.message
            return
        }
        guard !safeMode else {
            ddcMessage = "Safe mode — DDC not sent"
            return
        }

        ddcMessage = "Applying \(label) \(value)% to \(display.name)"
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
                    self?.ddcMessage = failureMessage ?? "Applied \(label) \(value)% to \(displayName)"
                }
            }
        }
    }
}

/// The detailed window. Subclassing `NSWindow` lets the smoke test show it on screen
/// without activating the app: when `allowsActivation` is false the window can't become
/// key or main, so ordering it front leaves focus with whatever app the developer is using.
/// Real use sets `allowsActivation` true, so it behaves like an ordinary window.
final class MainWindow: NSWindow {
    var allowsActivation = true

    override var canBecomeKey: Bool {
        allowsActivation
    }

    override var canBecomeMain: Bool {
        allowsActivation
    }
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
