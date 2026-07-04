import AppKit
import SwiftUI

@main
struct MonitorFluxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra {
            QuickControlsView()
                .environmentObject(store)
        } label: {
            // The menu bar label renders at launch even when no window is open, so
            // it's where we wire the delegate and apply the launch activation policy.
            // thermometer.sun.fill = color temperature, distinct from MonitorControl's sun.
            Image(systemName: "thermometer.sun.fill")
                .foregroundStyle(menuBarTint)
                .onAppear {
                    appDelegate.store = store
                    store.refreshActivationPolicy()
                }
        }
        .menuBarExtraStyle(.window)
        // The popup's "Settings… ⌘," row is only a click target; the key equivalent has to live
        // in the app's main menu — the same (hidden) menu whose Quit item makes ⌘Q work while the
        // popup is open. There is no `Settings` scene (it opens blank/duplicate windows from a
        // `.window` MenuBarExtra — see agent.md), so provide the standard item ourselves.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    if store.quickControlsPopupVisible {
                        dismissMenuBarPopup()
                    }
                    store.showMainWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    /// Warmth motif on the status icon: it picks up an amber tint while the screen is actually
    /// warmed (the warm side of the range), and stays neutral in cool daylight or when warmth is
    /// off — a glanceable "your screen is warm right now" without a permanently-colored menu-bar icon.
    private var menuBarTint: Color {
        guard store.preferences.colorMode != .off,
              let temperature = store.currentTemperature,
              temperature < 4600 else {
            return .primary
        }
        return .warmAmber
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        store?.refreshActivationPolicy()

        // Test hooks: drive the detailed window at launch so a smoke test can verify it
        // (the menu-bar popup that normally opens it can't be scripted reliably).
        switch ProcessInfo.processInfo.environment["MONITORFLUX_OPEN_MAIN"] {
        case "1":
            // `activating: false`: show the window for the smoke test without pulling the
            // app to the foreground or stealing focus from the developer's current work.
            store?.showMainWindow(activating: false)
        case "activate":
            // Like "1", but key/active so window-scoped keyboard shortcuts (⌘+/⌘-/⌘0 zoom,
            // ⌃⌘S sidebar toggle, ⌘⇧D) can be exercised during verification. Steals focus —
            // verification only.
            store?.showMainWindow(activating: true)
        case "reopen":
            // Open → close → reopen. This is the path users hit by closing the window
            // and clicking Settings again; a regression leaves the reopened window
            // off-screen/oversized, so the smoke test finds no on-screen window.
            runReopenCycle()
        default:
            break
        }

        // `MONITORFLUX_OSD_FRACTION` overrides the sample fill level (0...1) — e.g. 1 fills
        // every segment, which is what the OSD-geometry capture uses to measure the full bar.
        let osdFraction = ProcessInfo.processInfo.environment["MONITORFLUX_OSD_FRACTION"]
            .flatMap(Double.init)
        switch ProcessInfo.processInfo.environment["MONITORFLUX_SHOW_OSD"] {
        case "1", "brightness":
            store?.showSampleOSD(fraction: osdFraction ?? 0.7)
        case "contrast":
            store?.showSampleOSD(.contrast, fraction: osdFraction ?? 0.7)
        case "color":
            // Warm end of the range, so the warmth-tinted glyph/bar is visible in a screenshot.
            store?.showSampleOSD(.color, fraction: osdFraction ?? 0.12)
        default:
            break
        }

        // Verification hook: flip Show in Dock off through the real toggle path some seconds
        // after launch, so a screen recording can capture the .regular→.accessory transition
        // (the settings window's AX tree can't be scripted reliably).
        if let delay = ProcessInfo.processInfo.environment["MONITORFLUX_DOCK_OFF_AFTER"]
            .flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.store?.setShowInDock(false)
            }
        }

        // Verification hook: open the menu-bar popup so it can be captured by window id (the
        // popup has no public "show" API). The status item exists once the scene's label has
        // appeared, so defer one tick.
        if ProcessInfo.processInfo.environment["MONITORFLUX_OPEN_POPUP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                openMenuBarPopup()
            }
        }

        // Screenshot hook: capture the settings window's own pixels to a PNG and quit — a faithful,
        // self-contained alternative to the external window-id capture (no `_shot_sck`, no live-UI
        // scrolling). Frame the shot with SELECT / EXPAND_ADVANCED / SCROLL_TO. `=1` uses a default
        // temp path. Runs last so it captures after the other launch hooks have applied.
        let env = ProcessInfo.processInfo.environment
        if let snapshot = env["MONITORFLUX_SNAPSHOT"], !snapshot.isEmpty, let store {
            let path = snapshot == "1"
                ? (NSTemporaryDirectory() as NSString).appendingPathComponent("monitorflux-snapshot.png")
                : snapshot
            WindowSnapshot.captureAndQuit(to: path, store: store)
        }

        // First-run welcome: show once on a fresh install. `MONITORFLUX_SHOW_ONBOARDING=1` forces
        // it for a screenshot run; the main-window and snapshot hooks suppress it so the geometry
        // check (or the shot) finds only the titled main window, not the welcome sheet.
        if env["MONITORFLUX_SHOW_ONBOARDING"] == "1" {
            store?.showOnboarding()
        } else if store?.preferences.hasSeenOnboarding == false,
                  env["MONITORFLUX_OPEN_MAIN"] == nil,
                  env["MONITORFLUX_SNAPSHOT"] == nil {
            store?.showOnboarding()
        }
    }

    /// Used only by the `MONITORFLUX_OPEN_MAIN=reopen` smoke test. Real runloop gaps
    /// between the steps let SwiftUI lay out (and, on a regression, mis-size) the window.
    /// Non-activating throughout so running the test doesn't steal focus.
    private func runReopenCycle() {
        store?.showMainWindow(activating: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            NSApp.windows.first {
                $0.styleMask.contains(.titled) && $0.title == "MonitorFlux"
            }?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self?.store?.showMainWindow(activating: false)
            }
        }
    }

    /// Clicking the Dock icon — present only while "Show in Dock" is on — must reopen the
    /// main window when nothing is showing, the same as any normal Mac app. Without this the
    /// icon is inert once the settings window is closed: the click does nothing. When a window
    /// is already up, returning true lets AppKit do its default (unminiaturize / bring forward).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            store?.showMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flushPendingPreferencesSave()
        store?.restoreColorTables()
    }
}
