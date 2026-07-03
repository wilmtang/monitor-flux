import AppKit
import SwiftUI

/// Owns the app's AppKit-managed windows (the detailed settings window and the first-run
/// welcome), extracted from `AppStore` so the store stays the state owner and this stays the
/// only place that builds and re-anchors windows. Methods take the store as a parameter
/// rather than holding it, so there's no retain cycle to manage.
@MainActor
final class WindowCoordinator {
    /// The single settings window instance, if it has ever been created. `AppStore`'s
    /// key-window observers compare against this to scope their behavior to our window.
    private(set) var mainWindow: MainWindow?
    private var onboardingWindow: NSWindow?

    /// Whether the settings window is currently on screen. Drives the "Show in Dock" policy:
    /// the Dock icon appears with the window and goes away when it closes.
    var isMainWindowVisible: Bool {
        mainWindow?.isVisible ?? false
    }

    private static let mainWindowDefaultSize = NSSize(width: 800, height: 600)

    /// Show the detailed window. It's managed with AppKit rather than a SwiftUI
    /// `WindowGroup` so there is exactly one instance and its content/environment always
    /// binds — `openWindow` from a `.window` `MenuBarExtra` in an accessory app opens
    /// blank, duplicate windows.
    /// - Parameter activating: when true (the real "Settings…" path) the app comes to the
    ///   foreground and the window takes keyboard focus. The smoke test passes false so it
    ///   can put the window on screen for `CGWindowList` without yanking focus away from
    ///   whatever the user is doing while tests run.
    func showMainWindow(store: AppStore, activating: Bool) {
        let window = mainWindow ?? makeMainWindow(store: store)
        mainWindow = window
        // Reopening a closed window, or restoring a frame saved on a now-disconnected
        // display, can leave it sized or positioned off every screen — it orders front
        // but is invisible, so "Settings" looks like it does nothing. Re-anchor first.
        ensureWindowIsUsable(window)
        if activating {
            window.allowsActivation = true
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

    private func makeMainWindow(store: AppStore) -> MainWindow {
        // A hosting *controller* (not a bare NSHostingView) is what renders a
        // NavigationSplitView's sidebar + detail columns correctly, and its default
        // sizingOptions must stay (clearing them blanks the columns). The ideal-size
        // frame modifier keeps the window at a sane 800×600 on open, while
        // `maxWidth/Height: .infinity` still lets the user resize. Detail panes
        // scroll internally (see ColorScheduleView).
        //
        // Window zoom (⌘+/⌘-/⌘0) is semantic — ContentView scales fonts, Dynamic
        // Type size, and control size from `fontSizeStep` — NOT a geometric
        // transform. Every transform-based zoom (NSView bounds scaling, CALayer
        // transforms, NSScrollView.magnification, .scaleEffect) breaks click routing
        // for SwiftUI content hosted in a large NSHostingView; measured evidence in
        // docs/ZOOM_PLAN.md and prototype-zoom-matrix/.
        let root = ContentView()
            .environmentObject(store)
            .frame(
                minWidth: 620, idealWidth: Self.mainWindowDefaultSize.width, maxWidth: .infinity,
                minHeight: 500, idealHeight: Self.mainWindowDefaultSize.height, maxHeight: .infinity
            )
        let controller = NSHostingController(rootView: root)
        let window = MainWindow(contentViewController: controller)
        window.title = "MonitorFlux"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.mainWindowDefaultSize)
        window.contentMinSize = NSSize(width: 620, height: 500)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        window.setFrameAutosaveName("MonitorFluxMainWindow")
        return window
    }

    /// Show the first-run welcome, activating the app (unlike the test-driven window paths)
    /// because first launch is a deliberate "look here". The seen flag is the store's job.
    func showOnboarding(store: AppStore) {
        let window = onboardingWindow ?? makeOnboardingWindow(store: store)
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Dismiss the welcome window (from a button or the close box).
    func completeOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    private func makeOnboardingWindow(store: AppStore) -> NSWindow {
        // Same NSHostingController pattern as the main window (a bare NSHostingView mis-renders),
        // but a small, fixed, non-resizable sheet — the content is pinned to its own frame.
        let root = OnboardingView()
            .environmentObject(store)
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

    /// ⌘Q from the settings window is handled here deterministically, because a MenuBarExtra
    /// app has no reliably-wired menu Quit for this window to fall through to:
    /// - `.regular` (Show in Dock on): quit the app, the normal expectation for a Dock app.
    /// - `.accessory` (Show in Dock off): don't kill the background menu-bar app — just close
    ///   the window; quitting is done from the menu-bar icon's Quit.
    /// The window gets a key equivalent before the main menu, so consuming it here is reliable.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCommandQ = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
            && event.charactersIgnoringModifiers == "q"
        if isCommandQ {
            if NSApp.activationPolicy() == .accessory {
                close()
            } else {
                NSApp.terminate(nil)
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
