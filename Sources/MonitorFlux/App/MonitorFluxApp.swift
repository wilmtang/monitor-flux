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
            Image(systemName: "sun.max")
                .onAppear {
                    appDelegate.store = store
                    store.refreshActivationPolicy()
                }
        }
        .menuBarExtraStyle(.window)

        WindowGroup("MonitorFlux", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    appDelegate.store = store
                }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(width: 480, height: 360)
        }
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
    }

    @objc private func windowVisibilityChanged() {
        // Re-evaluate after the window is actually gone so a closed detail window
        // can drop us back to accessory (no Dock icon) when "Show in Dock" is off.
        DispatchQueue.main.async { [weak self] in
            self?.store?.refreshActivationPolicy()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.restoreColorTables()
    }
}
