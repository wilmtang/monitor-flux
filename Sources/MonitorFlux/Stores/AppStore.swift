import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []
    @Published var preferences: AppPreferences {
        didSet {
            PreferencesStore.save(preferences)
            reconcileColor()
        }
    }
    @Published private(set) var currentTemperature: Int?
    @Published private(set) var colorMessage = "Color disabled"
    @Published private(set) var ddcMessage = "DDC idle"

    private let displayService = DisplayService()
    private let ddcBackend = HardwareDDCBackend()
    private let gammaService = GammaTemperatureService()
    private var timer: Timer?

    init() {
        preferences = PreferencesStore.load()
        refreshDisplays()
        startTimer()
        reconcileColor()
    }

    var ddcStatus: DDCBackendStatus {
        ddcBackend.status
    }

    func refreshDisplays() {
        displays = displayService.listDisplays()
        seedMissingDisplayPreferences()
        reconcileColor()
    }

    func displayPreferences(for display: DisplayInfo) -> DisplayPreferences {
        preferences.displayPreferences[display.key, default: DisplayPreferences()]
    }

    func updateGlobalPreferences(_ update: (inout AppPreferences) -> Void) {
        var next = preferences
        update(&next)
        preferences = next
    }

    func updateDisplayPreferences(
        for display: DisplayInfo,
        _ update: (inout DisplayPreferences) -> Void
    ) {
        var next = preferences
        var displayPreferences = next.displayPreferences[display.key, default: DisplayPreferences()]
        update(&displayPreferences)
        next.displayPreferences[display.key] = displayPreferences
        preferences = next
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
                .clamped(to: 0...100)
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

    func restoreColorTables() {
        gammaService.restore()
        currentTemperature = nil
        colorMessage = "Color restored"
    }

    func disableColorAndRestore() {
        gammaService.restore()
        var next = preferences
        next.gammaEnabled = false
        preferences = next
        currentTemperature = nil
        colorMessage = "Gamma disabled"
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

    private func seedMissingDisplayPreferences() {
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
            preferences = next
        }
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
