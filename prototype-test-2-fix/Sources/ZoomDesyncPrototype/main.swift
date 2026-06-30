import AppKit
import SwiftUI

private let zoomSteps: [CGFloat] = [0.70, 0.80, 0.90, 1.00, 1.10, 1.25, 1.50, 1.75, 2.00]

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var keyMonitor: Any?
    private let demoView = DemoView()
    private var zoomIndex = 3

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Zoom Desync Prototype"
        window.contentView = demoView
        window.acceptsMouseMovedEvents = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        setZoom(index: zoomIndex)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let key = event.charactersIgnoringModifiers else {
            return false
        }

        switch key {
        case "+", "=":
            setZoom(index: min(zoomIndex + 1, zoomSteps.count - 1))
            return true
        case "-", "_":
            setZoom(index: max(zoomIndex - 1, 0))
            return true
        case "0":
            setZoom(index: 3)
            return true
        default:
            return false
        }
    }

    private func setZoom(index: Int) {
        zoomIndex = index
        demoView.zoomScale = zoomSteps[index]
    }
}

private final class DemoView: NSView {
    override var isFlipped: Bool { true }

    var zoomScale: CGFloat = 1 {
        didSet {
            stageView.zoomScale = zoomScale
            updateLabels()
        }
    }

    private let zoomLabel = NSTextField(labelWithString: "")
    private let mouseLabel = NSTextField(labelWithString: "")
    private let clickLabel = NSTextField(labelWithString: "Last click: none")
    private let hintLabel = NSTextField(labelWithString: "Click the visible button edges after zooming in; the button action should still fire.")
    private let stageView = StageView()
    private var trackingAreaRef: NSTrackingArea?
    private var lastMousePoint = NSPoint.zero

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        [zoomLabel, mouseLabel, clickLabel, hintLabel].forEach { label in
            label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            label.textColor = .labelColor
            addSubview(label)
        }

        stageView.onClick = { [weak self] source, point in
            self?.clickLabel.stringValue = "Last click: \(source) at stage \(Self.format(point))"
        }
        addSubview(stageView)
        updateLabels()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let padding: CGFloat = 20
        zoomLabel.frame = NSRect(x: padding, y: 18, width: bounds.width - padding * 2, height: 18)
        mouseLabel.frame = NSRect(x: padding, y: 40, width: bounds.width - padding * 2, height: 18)
        clickLabel.frame = NSRect(x: padding, y: 62, width: bounds.width - padding * 2, height: 18)
        hintLabel.frame = NSRect(x: padding, y: 86, width: bounds.width - padding * 2, height: 18)

        let stageSize = NSSize(width: 420, height: 280)
        stageView.frame = NSRect(
            x: (bounds.width - stageSize.width) / 2,
            y: 130,
            width: stageSize.width,
            height: stageSize.height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaRef = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        lastMousePoint = convert(event.locationInWindow, from: nil)
        updateLabels()
    }

    override func mouseDown(with event: NSEvent) {
        let point = stageView.convert(event.locationInWindow, from: nil)
        clickLabel.stringValue = "Last click: outside button at stage \(Self.format(point))"
    }

    private func updateLabels() {
        zoomLabel.stringValue = "Zoom: \(Int((zoomScale * 100).rounded()))%    shortcuts: Cmd+  Cmd-  Cmd0"
        mouseLabel.stringValue = "Mouse: window \(Self.format(lastMousePoint))"
    }

    private static func format(_ point: NSPoint) -> String {
        "x \(Int(point.x.rounded())), y \(Int(point.y.rounded()))"
    }
}

private final class StageView: NSView {
    override var isFlipped: Bool { true }

    var zoomScale: CGFloat = 1 {
        didSet {
            needsLayout = true
        }
    }

    var onClick: ((String, NSPoint) -> Void)?

    private let contentView = ClickContentView()
    private lazy var buttonHost = NSHostingView(rootView: HostedButton { [weak self] in
        self?.buttonClicked()
    })

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.clear.cgColor
        contentView.onBackgroundClick = { [weak self] event in
            guard let self else { return }
            let point = convert(event.locationInWindow, from: nil)
            onClick?("miss", point)
        }
        addSubview(contentView)

        contentView.addSubview(buttonHost)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let s = max(zoomScale, 0.01)
        contentView.frame = bounds
        contentView.bounds = NSRect(x: 0, y: 0, width: bounds.width / s, height: bounds.height / s)
        buttonHost.frame = NSRect(
            x: (contentView.bounds.width - 120) / 2,
            y: (contentView.bounds.height - 36) / 2,
            width: 120,
            height: 36
        )
    }

    private func buttonClicked() {
        let event = NSApp.currentEvent
        let point = event.map { convert($0.locationInWindow, from: nil) } ?? .zero
        onClick?("button action", point)
    }
}

private final class ClickContentView: NSView {
    override var isFlipped: Bool { true }
    var onBackgroundClick: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?(event)
    }
}

private struct HostedButton: View {
    let onClick: () -> Void

    var body: some View {
        Button("Click me", action: onClick)
            .frame(width: 120, height: 36)
    }
}

let app = NSApplication.shared
private let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
