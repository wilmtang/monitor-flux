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
    }

    /// Warmth motif on the status icon: it picks up an amber tint while the screen is actually
    /// warmed (the warm side of the range), and stays neutral in cool daylight or when warmth is
    /// off — a glanceable "your screen is warm right now" without a permanently-colored menu-bar icon.
    private var menuBarTint: Color {
        guard store.preferences.gammaEnabled,
              store.preferences.colorMode != .off,
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowVisibilityChanged),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // Test hooks: drive the detailed window at launch so a smoke test can verify it
        // (the menu-bar popup that normally opens it can't be scripted reliably).
        switch ProcessInfo.processInfo.environment["MONITORFLUX_OPEN_MAIN"] {
        case "1":
            // `activating: false`: show the window for the smoke test without pulling the
            // app to the foreground or stealing focus from the developer's current work.
            store?.showMainWindow(activating: false)
        case "activate":
            // Like "1", but key/active so window-scoped keyboard shortcuts (⌃⌘S sidebar toggle,
            // ⌘⇧D) can be exercised during verification. Steals focus — verification only.
            store?.showMainWindow(activating: true)
        case "reopen":
            // Open → close → reopen. This is the path users hit by closing the window
            // and clicking Settings again; a regression leaves the reopened window
            // off-screen/oversized, so the smoke test finds no on-screen window.
            runReopenCycle()
        default:
            break
        }

        switch ProcessInfo.processInfo.environment["MONITORFLUX_SHOW_OSD"] {
        case "1", "brightness":
            store?.showSampleOSD()
        case "color":
            // Warm end of the range, so the warmth-tinted glyph/bar is visible in a screenshot.
            store?.showSampleOSD(.color, fraction: 0.12)
        default:
            break
        }

        // Verification hook: open the menu-bar popup so it can be captured by window id (the
        // popup has no public "show" API). The status item exists once the scene's label has
        // appeared, so defer one tick.
        if ProcessInfo.processInfo.environment["MONITORFLUX_OPEN_POPUP"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                openMenuBarPopup()
            }
        }

        // First-run welcome: show once on a fresh install. `MONITORFLUX_SHOW_ONBOARDING=1` forces
        // it for a screenshot run; the main-window test hook suppresses it so the smoke geometry
        // check finds only the titled main window, not the welcome sheet.
        let env = ProcessInfo.processInfo.environment
        if env["MONITORFLUX_SHOW_ONBOARDING"] == "1" {
            store?.showOnboarding()
        } else if store?.preferences.hasSeenOnboarding == false,
                  env["MONITORFLUX_OPEN_MAIN"] == nil {
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

    @objc private func windowVisibilityChanged() {
        // Re-evaluate after the window is actually gone so a closed detail window
        // can drop us back to accessory (no Dock icon) when "Show in Dock" is off.
        DispatchQueue.main.async { [weak self] in
            self?.store?.refreshActivationPolicy()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.flushPendingPreferencesSave()
        store?.restoreColorTables()
    }
}
