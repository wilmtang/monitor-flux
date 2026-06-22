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
    @Published private(set) var locationStatus = "Not requested"
    @Published private(set) var keyboardStatus = "Off"
    /// Cached real backlight level (0...1) per display that supports DisplayServices.
    @Published private(set) var nativeBrightness: [CGDirectDisplayID: Double] = [:]

    /// Set by `MONITORFLUX_SAFE_MODE=1`. Skips every gamma/DDC/backlight hardware write so
    /// tests don't fight f.lux/MonitorControl or flicker the screen — the UI still updates.
    let safeMode: Bool

    let locationService = LocationService()
    let keyboardService = KeyboardControlService()
    private let displayService = DisplayService()
    private let ddcBackend = HardwareDDCBackend()
    private let nativeBrightnessBackend = NativeBrightnessBackend()
    private let gammaService = GammaTemperatureService()
    private var mainWindow: MainWindow?
    private var timer: Timer?
    /// Trailing (coalesced) DDC writes per control, and the last time each one actually
    /// wrote, so `scheduleDDC` can throttle a drag instead of only firing on release.
    private var ddcWriteWorkItems: [String: DispatchWorkItem] = [:]
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

        keyboardService.store = self
        if safeMode {
            keyboardStatus = "Off (safe mode)"
        } else if preferences.keyboardControlEnabled {
            keyboardStatus = keyboardService.start() ? "Active" : "Needs Accessibility permission"
        }

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
        displays = displayService.listDisplays()
        refreshNativeBrightness()
        if !seedMissingDisplayPreferences() {
            reconcileColor()
        }
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
        let window = MainWindow(
            contentRect: NSRect(origin: .zero, size: Self.mainWindowDefaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MonitorFlux"
        // Use an `NSHostingView` as the content view rather than
        // `NSWindow(contentViewController:)`: a hosting *controller* drives the window
        // size from SwiftUI's fitting size, so a closed-then-reopened window re-fit its
        // content to a giant height and ordered front off-screen. A content *view* lays
        // out inside whatever frame we set and never resizes the window.
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(self))
        window.contentMinSize = NSSize(width: 720, height: 500)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.setFrameAutosaveName("MonitorFluxMainWindow")
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
                keyboardService.requestAccessibilityPermission()
                keyboardStatus = "Grant Accessibility, then toggle again"
            }
        } else {
            keyboardService.stop()
            keyboardStatus = "Off"
        }
    }

    /// Media-key entry points. Without a modifier the target is the display under the
    /// cursor (external -> DDC; built-in is left to macOS). Control targets the built-in
    /// panel via software/gamma dimming. Returns true when handled (so the key is swallowed).
    func adjustBrightnessUnderCursor(by delta: Int, controlBuiltIn: Bool) -> Bool {
        if controlBuiltIn {
            guard let builtIn = displays.first(where: { $0.isBuiltIn }) else {
                return false
            }
            return adjustBuiltInBrightness(builtIn, by: delta)
        }
        guard let target = displayUnderCursor() else {
            return false
        }
        if target.isBuiltIn {
            return false
        }
        let current = displayPreferences(for: target).hardwareBrightness
        setHardwareBrightness(current + delta, for: target)
        return true
    }

    private func adjustBuiltInBrightness(_ display: DisplayInfo, by delta: Int) -> Bool {
        if canUseNativeBrightness(display) {
            setNativeBrightness(nativeBrightnessValue(for: display) + Double(delta) / 100.0, for: display)
            return true
        }
        // Fallback: software gamma dimming when DisplayServices is unavailable.
        let current = displayPreferences(for: display).gammaBrightness
        updateDisplayPreferences(for: display) { preferences in
            preferences.gammaBrightness = (current + delta).clamped(to: ControlRanges.gammaBrightnessPercent)
        }
        return true
    }

    func adjustVolumeUnderCursor(by delta: Int) -> Bool {
        guard let target = displayUnderCursor(), !target.isBuiltIn else {
            return false
        }
        let current = displayPreferences(for: target).hardwareVolume
        setHardwareVolume(current + delta, for: target)
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
        !display.isBuiltIn
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
            Task { @MainActor in
                self?.ddcMessage = failureMessage ?? "Applied volume \(value)% to \(displayName)"
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
        let summary = gammaService.apply(
            displays: displays,
            preferences: preferences
        )
        colorMessage = summary.message
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reconcileColor()
            }
        }
        timer?.tolerance = 10
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
            Task { @MainActor in
                self?.ddcMessage = failureMessage ?? "Applied \(label) \(value)% to \(displayName)"
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
