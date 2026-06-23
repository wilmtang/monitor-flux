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
                .onAppear {
                    appDelegate.store = store
                    store.refreshActivationPolicy()
                }
        }
        .menuBarExtraStyle(.window)
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
        case "reopen":
            // Open → close → reopen. This is the path users hit by closing the window
            // and clicking Settings again; a regression leaves the reopened window
            // off-screen/oversized, so the smoke test finds no on-screen window.
            runReopenCycle()
        default:
            break
        }

        if ProcessInfo.processInfo.environment["MONITORFLUX_SHOW_OSD"] == "1" {
            store?.showSampleOSD()
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
