import AppKit
import SwiftUI

@main
struct MonitorFluxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup("MonitorFlux", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    appDelegate.store = store
                }
        }

        MenuBarExtra("MonitorFlux", systemImage: "display") {
            MenuBarControlView()
                .environmentObject(store)
        }

        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(width: 480, height: 300)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.restoreColorTables()
    }
}
