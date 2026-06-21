import AppKit
import Combine
import CoreGraphics
import CoreLocation
import Foundation

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
            PreferencesStore.save(preferences)
            reconcileColor()
        }
    }
    @Published private(set) var currentTemperature: Int?
    @Published private(set) var colorMessage = "Color disabled"
    @Published private(set) var ddcMessage = "DDC idle"
    @Published private(set) var loginItemMessage = LoginItemService.statusLabel()
    @Published private(set) var locationStatus = "Not requested"
    @Published private(set) var keyboardStatus = "Off"

    let locationService = LocationService()
    let keyboardService = KeyboardControlService()
    private let displayService = DisplayService()
    private let ddcBackend = HardwareDDCBackend()
    private let gammaService = GammaTemperatureService()
    private var timer: Timer?
    private var ddcWriteWorkItems: [String: DispatchWorkItem] = [:]
    private var displayRefreshGeneration = 0
    private var cancellables = Set<AnyCancellable>()

    init() {
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
        if preferences.keyboardControlEnabled {
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
        displays = displayService.listDisplays()
        if !seedMissingDisplayPreferences() {
            reconcileColor()
        }
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

    /// Promote to a regular app and activate so an on-demand window appears in front,
    /// even when the app is otherwise a menu-bar accessory.
    func activateMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
            let current = displayPreferences(for: builtIn).gammaBrightness
            updateDisplayPreferences(for: builtIn) { preferences in
                preferences.gammaBrightness = (current + delta).clamped(to: ControlRanges.gammaBrightnessPercent)
            }
            return true
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
        let value = displayPreferences(for: display).hardwareVolume
        ddcMessage = "Applying volume \(value)% to \(display.name)"
        let backend = ddcBackend
        let displayName = display.name
        Task { @MainActor in
            let failureMessage = await Task.detached {
                do {
                    try backend.setVolume(value, display: display)
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            ddcMessage = failureMessage ?? "Applied volume \(value)% to \(displayName)"
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

    private func scheduleDDC(key: String, for display: DisplayInfo, _ apply: @escaping () -> Void) {
        guard canUseDDC(for: display) else {
            return
        }
        ddcWriteWorkItems[key]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.ddcWriteWorkItems[key] = nil
            apply()
        }
        ddcWriteWorkItems[key] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item)
    }

    func restoreColorTables() {
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
                var displayPreferences = DisplayPreferences()
                displayPreferences.ddcDisplayIndex = display.isBuiltIn ? 1 : externalIndex
                next.displayPreferences[display.key] = displayPreferences
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

        ddcMessage = "Applying \(label) \(value)% to \(display.name)"
        let backend = ddcBackend
        let displayName = display.name

        Task { @MainActor in
            let failureMessage = await Task.detached {
                do {
                    switch kind {
                    case .brightness:
                        try backend.setBrightness(value, display: display, fallbackIndex: displayIndex)
                    case .contrast:
                        try backend.setContrast(value, display: display, fallbackIndex: displayIndex)
                    }
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value

            if let failureMessage {
                ddcMessage = failureMessage
            } else {
                ddcMessage = "Applied \(label) \(value)% to \(displayName)"
            }
        }
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
