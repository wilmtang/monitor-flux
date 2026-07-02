import AppKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

/// Developer-facing state dump: everything the app knows about its environment, permissions,
/// color pipeline, DDC path, and each display — plus a one-click plaintext report for bug
/// reports. Values come straight from live store state; nothing here writes hardware except
/// the explicit reset button.
struct DiagnosticsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var copiedReport = false
    @State private var preferencesTransferMessage: String?

    var body: some View {
        Form {
            appSection
            colorSection
            ddcSection
            ForEach(store.displays) { display in
                displaySection(display)
            }
            actionsSection
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
    }

    // MARK: - Sections

    private var appSection: some View {
        Section("App") {
            LabeledContent("Version", value: Self.appVersion)
            LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            LabeledContent("Safe mode", value: store.safeMode ? "On — no hardware writes" : "Off")
            LabeledContent("Accessibility", value: store.accessibilityTrusted ? "Granted" : "Not granted")
            LabeledContent("Keyboard control", value: store.keyboardStatus)
            LabeledContent("Location access", value: store.locationStatus)
            LabeledContent("Login item", value: store.loginItemMessage)
            if !store.hotkeyConflicts.isEmpty {
                LabeledContent(
                    "Shortcut conflicts",
                    value: store.hotkeyConflicts.map(\.label).sorted().joined(separator: ", ")
                )
            }
        }
    }

    private var colorSection: some View {
        Section("Color Pipeline") {
            LabeledContent("Warmth master", value: store.preferences.gammaEnabled ? "On" : "Off")
            LabeledContent("Mode", value: store.preferences.colorMode.label)
            LabeledContent("Schedule from", value: store.preferences.scheduleSource.label)
            LabeledContent("Current", value: store.currentTemperature.map(KelvinFormatting.label(for:)) ?? "Off")
            LabeledContent("Gamma status", value: store.colorMessage)
            LabeledContent(
                "Preview",
                value: store.schedulePreviewMinute.map { "Scrubbing \(MinuteFormatting.label(for: $0))" } ?? "None"
            )
            if let times = store.solarTimes {
                LabeledContent("Sunrise today", value: solarLabel(times.sunriseMinutes))
                LabeledContent("Sunset today", value: solarLabel(times.sunsetMinutes))
            }
            LabeledContent(
                "Gamma conflict",
                value: store.gammaConflictDetected
                    ? (store.gammaConflictApps.isEmpty
                        ? "Foreign gamma change detected"
                        : "Detected — \(store.gammaConflictApps.joined(separator: ", "))")
                    : "None detected"
            )
        }
    }

    private var ddcSection: some View {
        Section("DDC") {
            LabeledContent("Backend", value: store.ddcStatus.toolName)
            LabeledContent("Fallback path", value: store.ddcStatus.toolPath ?? "None")
            LabeledContent("Last status", value: store.ddcMessage)
        }
    }

    private func displaySection(_ display: DisplayInfo) -> some View {
        let preferences = store.displayPreferences(for: display)
        let bounds = CGDisplayBounds(display.id)
        return Section(display.name) {
            LabeledContent("Kind", value: displayKind(display))
            LabeledContent("Resolution", value: display.frameDescription)
            LabeledContent("Position", value: "(\(Int(bounds.origin.x)), \(Int(bounds.origin.y)))")
            LabeledContent("Display ID") {
                Text(String(display.id)).monospacedDigit()
            }
            LabeledContent("Identity key") {
                Text(display.persistentID)
                    .zoomFont(.caption, design: .monospaced)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            if let master = display.mirrorMaster {
                LabeledContent("Mirrors", value: "Display \(master)")
            }
            if display.isBuiltIn {
                LabeledContent(
                    "Native backlight",
                    value: store.canUseNativeBrightness(display)
                        ? "\(Int((store.nativeBrightnessValue(for: display) * 100).rounded()))%"
                        : "Not available"
                )
            } else {
                LabeledContent("DDC", value: store.canUseDDC(for: display) ? "Capable" : "Not available")
                LabeledContent("Speakers", value: store.displayHasDetectedAudio(display) ? "Detected" : "None detected")
                LabeledContent(
                    "Hardware settings",
                    value: "Brightness \(preferences.hardwareBrightness)% · Contrast \(preferences.hardwareContrast)% · Volume \(preferences.hardwareVolume)%"
                )
            }
            LabeledContent(
                "Software dimming",
                value: preferences.gammaControlsEnabled
                    ? "On · brightness \(preferences.gammaBrightness)%"
                    : "Off"
            )
            LabeledContent("Warmth opt-in", value: preferences.colorEnabled ? "On" : "Off")
            LabeledContent("Scheduled", value: scheduledControlsLabel(preferences, isBuiltIn: display.isBuiltIn))
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                copyReport()
            } label: {
                Label(copiedReport ? "Copied" : "Copy Diagnostics Report", systemImage: copiedReport ? "checkmark" : "doc.on.doc")
            }
            Text("Copies everything on this screen as plain text — paste it into a bug report.")
                .zoomFont(.caption)
                .foregroundStyle(.secondary)

            Button {
                store.disableColorAndRestore()
            } label: {
                Label("Disable Gamma and Restore", systemImage: "arrow.uturn.backward.circle")
            }

            Divider()

            Button {
                exportPreferences()
            } label: {
                Label("Export Preferences JSON…", systemImage: "square.and.arrow.up")
            }

            Button {
                importPreferences()
            } label: {
                Label("Import Preferences JSON…", systemImage: "square.and.arrow.down")
            }

            Text(preferencesTransferMessage ?? "Import replaces saved preferences and applies current display settings immediately.")
                .zoomFont(.caption)
                .foregroundStyle(preferencesTransferMessage == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formatting

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version ?? "dev (unbundled)"
    }

    private func solarLabel(_ minutes: Int?) -> String {
        minutes.map(MinuteFormatting.label(for:)) ?? "—"
    }

    private func displayKind(_ display: DisplayInfo) -> String {
        var parts = [display.kindLabel]
        if display.isVirtual {
            parts.append("AirPlay/virtual")
        }
        if !display.isOnline {
            parts.append("offline")
        }
        return parts.joined(separator: " · ")
    }

    private func scheduledControlsLabel(_ preferences: DisplayPreferences, isBuiltIn: Bool) -> String {
        var scheduled: [String] = []
        if preferences.scheduleBrightness {
            scheduled.append("brightness \(preferences.dayBrightness)→\(preferences.nightBrightness)%")
        }
        if preferences.scheduleContrast, !isBuiltIn {
            scheduled.append("contrast \(preferences.dayContrast)→\(preferences.nightContrast)%")
        }
        return scheduled.isEmpty ? "Nothing" : scheduled.joined(separator: " · ")
    }

    // MARK: - Report

    private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(reportText(), forType: .string)
        copiedReport = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedReport = false
        }
    }

    @MainActor
    private func exportPreferences() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MonitorFlux-Preferences.json"
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try store.exportedPreferencesData().write(to: url, options: .atomic)
            preferencesTransferMessage = "Exported preferences to \(url.lastPathComponent)."
        } catch {
            preferencesTransferMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func importPreferences() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try store.importPreferences(from: Data(contentsOf: url))
            preferencesTransferMessage = store.safeMode
                ? "Imported preferences. Safe mode skipped hardware writes."
                : "Imported preferences and applied current display settings."
        } catch {
            preferencesTransferMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    /// The whole pane as plain text, mirroring the rows above so the report and the screen
    /// can't drift apart in structure.
    private func reportText() -> String {
        var lines: [String] = []
        lines.append("MonitorFlux Diagnostics")
        lines.append("Version: \(Self.appVersion)")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Safe mode: \(store.safeMode ? "on" : "off")")
        lines.append("Accessibility: \(store.accessibilityTrusted ? "granted" : "not granted")")
        lines.append("Keyboard control: \(store.keyboardStatus)")
        lines.append("Location access: \(store.locationStatus)")
        lines.append("Login item: \(store.loginItemMessage)")
        if !store.hotkeyConflicts.isEmpty {
            lines.append("Shortcut conflicts: \(store.hotkeyConflicts.map(\.label).sorted().joined(separator: ", "))")
        }

        lines.append("")
        lines.append("Color pipeline")
        lines.append("Warmth master: \(store.preferences.gammaEnabled ? "on" : "off")")
        lines.append("Mode: \(store.preferences.colorMode.label)")
        lines.append("Schedule from: \(store.preferences.scheduleSource.label)")
        lines.append("Current: \(store.currentTemperature.map(KelvinFormatting.label(for:)) ?? "Off")")
        lines.append("Gamma status: \(store.colorMessage)")
        if let minute = store.schedulePreviewMinute {
            lines.append("Preview: scrubbing \(MinuteFormatting.label(for: minute))")
        }
        if let times = store.solarTimes {
            lines.append("Sunrise today: \(solarLabel(times.sunriseMinutes))")
            lines.append("Sunset today: \(solarLabel(times.sunsetMinutes))")
        }
        lines.append("Gamma conflict: \(store.gammaConflictDetected ? "detected (\(store.gammaConflictApps.joined(separator: ", ")))" : "none detected")")

        lines.append("")
        lines.append("DDC")
        lines.append("Backend: \(store.ddcStatus.toolName)")
        lines.append("Fallback path: \(store.ddcStatus.toolPath ?? "none")")
        lines.append("Last status: \(store.ddcMessage)")

        for display in store.displays {
            let preferences = store.displayPreferences(for: display)
            let bounds = CGDisplayBounds(display.id)
            lines.append("")
            lines.append("Display: \(display.name)")
            lines.append("Kind: \(displayKind(display))")
            lines.append("Resolution: \(display.frameDescription) at (\(Int(bounds.origin.x)), \(Int(bounds.origin.y)))")
            lines.append("Display ID: \(display.id)")
            lines.append("Identity key: \(display.persistentID)")
            if let master = display.mirrorMaster {
                lines.append("Mirrors: display \(master)")
            }
            if display.isBuiltIn {
                let backlight = store.canUseNativeBrightness(display)
                    ? "\(Int((store.nativeBrightnessValue(for: display) * 100).rounded()))%"
                    : "not available"
                lines.append("Native backlight: \(backlight)")
            } else {
                lines.append("DDC: \(store.canUseDDC(for: display) ? "capable" : "not available")")
                lines.append("Speakers: \(store.displayHasDetectedAudio(display) ? "detected" : "none detected")")
                lines.append("Hardware: brightness \(preferences.hardwareBrightness)%, contrast \(preferences.hardwareContrast)%, volume \(preferences.hardwareVolume)%")
            }
            lines.append("Software dimming: \(preferences.gammaControlsEnabled ? "on, brightness \(preferences.gammaBrightness)%" : "off")")
            lines.append("Warmth opt-in: \(preferences.colorEnabled ? "on" : "off")")
            lines.append("Scheduled: \(scheduledControlsLabel(preferences, isBuiltIn: display.isBuiltIn))")
        }
        return lines.joined(separator: "\n")
    }
}
