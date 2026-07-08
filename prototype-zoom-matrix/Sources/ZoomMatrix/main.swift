// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
// Affero General Public License v3.0 or later. See LICENSE. No warranty.

import AppKit
import SwiftUI

// ---------------------------------------------------------------------------
// Zoom mechanism test matrix.
//
// Replicates the real MonitorFlux settings window structure (NSHostingController
// with sizingOptions=[], NavigationSplitView, grouped Form) and applies one of
// several candidate zoom mechanisms, selected via ZOOM_MODE:
//
//   bounds      — NSView bounds scaling (current ZoomContainerView, expected broken)
//   magnify     — NSScrollView.magnification wrapping the hosting view
//   scaleeffect — pure SwiftUI GeometryReader + .scaleEffect(anchor: .topLeading)
//   semantic    — no geometric transform; root .font scaled by zoom
//
// It is driven over a tiny file protocol in PROTO_DIR:
//   cmd-N.txt  : "zoom 1.5" | "click <winX> <winY>" | "quit"   (N = 1,2,3…)
//   ack-N.txt  : written when cmd-N has been fully processed
//   state.json : window id/frame/scale + expected calibration point (rewritten on change)
//   hits.log   : one line per control activation ("<seq> <probe-name>")
//
// Every interactive probe carries a uniquely colored solid marker so a driver
// can find its *visual* position in a screenshot and click exactly there.
// ---------------------------------------------------------------------------

let protoDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROTO_DIR"] ?? "/tmp/zoom-matrix")
let mode = ProcessInfo.processInfo.environment["ZOOM_MODE"] ?? "bounds"

// MARK: - Hit log

final class HitLog {
    static let shared = HitLog()
    private var seq = 0
    private let url = protoDir.appendingPathComponent("hits.log")

    func record(_ name: String) {
        seq += 1
        let line = "\(seq) \(name)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
        print("[HIT] \(line)", terminator: "")
        fflush(stdout)
    }
}

// MARK: - Probe palette (well separated; avoids system accent blue ~(0,122,255))

enum Probe: String, CaseIterable {
    case calib = "calib"
    case navSchedule = "nav-schedule"
    case navGeneral = "nav-general"
    case btnTop = "btn-top"
    case toggleA = "toggle-a"
    case btnTrailing = "btn-trailing"
    case btnBottom = "btn-bottom"

    var rgb: (Double, Double, Double) {
        switch self {
        case .calib:       return (255, 0, 255)   // magenta
        case .navSchedule: return (0, 255, 0)     // green
        case .navGeneral:  return (255, 255, 0)   // yellow
        case .btnTop:      return (255, 0, 0)     // red
        case .toggleA:     return (0, 255, 255)   // cyan
        case .btnTrailing: return (255, 128, 0)   // orange
        case .btnBottom:   return (128, 0, 255)   // purple
        }
    }

    var color: Color {
        let (r, g, b) = rgb
        return Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: 1)
    }
}

// MARK: - Zoom state for the SwiftUI-side modes

final class ZoomModel: ObservableObject {
    @Published var scale: CGFloat = 1.0
}

// MARK: - Demo content (mirrors the real ContentView shape)

struct DemoContent: View {
    @State private var selection: String? = "General"
    @State private var toggleA = false
    @State private var sliderValue = 0.4
    @State private var name = "text"
    @State private var pickerMode = "Auto"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape")
                    .background(Probe.navGeneral.color)
                    .tag("General")
                Label("Schedule", systemImage: "clock")
                    .background(Probe.navSchedule.color)
                    .tag("Schedule")
                Label("Display", systemImage: "display")
                    .tag("Display")
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 130, ideal: 150, max: 200)
        } detail: {
            detailView
        }
        .onChange(of: selection) { _, value in
            if let value { HitLog.shared.record("nav-\(value.lowercased())") }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if selection == "General" {
            generalPane
        } else {
            Text("\(selection ?? "none") placeholder")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var generalPane: some View {
        Form {
            Section("Probes") {
                Button {
                    HitLog.shared.record("btn-top")
                } label: {
                    Rectangle().fill(Probe.btnTop.color).frame(width: 90, height: 22)
                }
                .buttonStyle(.plain)

                Toggle("Warm shift toggle", isOn: $toggleA)
                    .background(Probe.toggleA.color)
                    .onChange(of: toggleA) { _, value in
                        HitLog.shared.record("toggle-a=\(value)")
                    }

                LabeledContent("Trailing control") {
                    Button {
                        HitLog.shared.record("btn-trailing")
                    } label: {
                        Rectangle().fill(Probe.btnTrailing.color).frame(width: 70, height: 22)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Slider(value: $sliderValue) { Text("Brightness") }
                Picker("Mode", selection: $pickerMode) {
                    Text("Auto").tag("Auto")
                    Text("Fixed").tag("Fixed")
                    Text("Off").tag("Off")
                }
                .onChange(of: pickerMode) { _, value in
                    HitLog.shared.record("picker=\(value)")
                }
            }

            Section {
                Button {
                    HitLog.shared.record("btn-bottom")
                } label: {
                    Rectangle().fill(Probe.btnBottom.color).frame(width: 90, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - SwiftUI wrappers for the two SwiftUI-side modes

struct ScaleEffectRoot: View {
    @ObservedObject var zoom: ZoomModel

    var body: some View {
        GeometryReader { proxy in
            let s = zoom.scale
            DemoContent()
                .frame(width: proxy.size.width / s, height: proxy.size.height / s)
                .scaleEffect(s, anchor: .topLeading)
        }
    }
}

struct SemanticRoot: View {
    @ObservedObject var zoom: ZoomModel

    var body: some View {
        DemoContent()
            .font(.system(size: 13 * zoom.scale))
            .dynamicTypeSize(Self.typeSize(for: zoom.scale))
    }

    static func typeSize(for s: CGFloat) -> DynamicTypeSize {
        switch s {
        case ..<1.05: .large
        case ..<1.2: .xLarge
        case ..<1.35: .xxLarge
        case ..<1.6: .accessibility1
        case ..<1.8: .accessibility2
        default: .accessibility3
        }
    }
}

// MARK: - sendevent mode: visual-only layer scale + event transform at the window

final class ScalingWindow: NSWindow {
    var eventScale: CGFloat = 1.0

    private static let mouseTypes: Set<NSEvent.EventType> = [
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .mouseMoved,
    ]

    override func sendEvent(_ event: NSEvent) {
        guard eventScale != 1.0, Self.mouseTypes.contains(event.type), let cv = contentView else {
            super.sendEvent(event)
            return
        }
        let p = event.locationInWindow
        let content = cv.convert(cv.bounds, to: nil)
        guard content.contains(p) else {
            super.sendEvent(event) // titlebar / traffic lights stay untransformed
            return
        }
        let s = eventScale
        let lx = content.minX + (p.x - content.minX) / s
        let ly = content.maxY - (content.maxY - p.y) / s
        guard let mapped = NSEvent.mouseEvent(
            with: event.type, location: NSPoint(x: lx, y: ly),
            modifierFlags: event.modifierFlags, timestamp: event.timestamp,
            windowNumber: windowNumber, context: nil,
            eventNumber: event.eventNumber, clickCount: event.clickCount,
            pressure: event.pressure) else {
            super.sendEvent(event)
            return
        }
        super.sendEvent(mapped)
    }

    override var mouseLocationOutsideOfEventStream: NSPoint {
        let p = super.mouseLocationOutsideOfEventStream
        guard eventScale != 1.0, let cv = contentView else { return p }
        let content = cv.convert(cv.bounds, to: nil)
        guard content.contains(p) else { return p }
        let s = eventScale
        return NSPoint(x: content.minX + (p.x - content.minX) / s,
                       y: content.maxY - (content.maxY - p.y) / s)
    }

    // AppKit controls (NSSwitch, sliders, steppers) run nested tracking loops
    // that dequeue events directly — those never pass through sendEvent. They
    // pull from the window, so transform here too.
    override func nextEvent(matching mask: NSEvent.EventTypeMask,
                            until expiration: Date?,
                            inMode mode: RunLoop.Mode,
                            dequeue deqFlag: Bool) -> NSEvent? {
        let event = super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: deqFlag)
        return transformIfNeeded(event)
    }

    private func transformIfNeeded(_ event: NSEvent?) -> NSEvent? {
        guard let event, eventScale != 1.0, Self.mouseTypes.contains(event.type),
              event.window === self, let cv = contentView else { return event }
        let p = event.locationInWindow
        let content = cv.convert(cv.bounds, to: nil)
        guard content.contains(p) else { return event }
        let s = eventScale
        let lx = content.minX + (p.x - content.minX) / s
        let ly = content.maxY - (content.maxY - p.y) / s
        return NSEvent.mouseEvent(
            with: event.type, location: NSPoint(x: lx, y: ly),
            modifierFlags: event.modifierFlags, timestamp: event.timestamp,
            windowNumber: windowNumber, context: nil,
            eventNumber: event.eventNumber, clickCount: event.clickCount,
            pressure: event.pressure) ?? event
    }
}

final class LayerScaleContainerView: NSView {
    private let canvas = FlippedView()
    private(set) var hostedView: NSView?
    private(set) var zoomScale: CGFloat = 1.0

    override var isFlipped: Bool { true }

    func install(_ view: NSView, scale: CGFloat) {
        zoomScale = max(scale, 0.01)
        if canvas.superview !== self {
            canvas.wantsLayer = true
            wantsLayer = true
            addSubview(canvas)
        }
        hostedView?.removeFromSuperview()
        hostedView = view
        canvas.addSubview(view)
        needsLayout = true
    }

    func setScale(_ scale: CGFloat) {
        let s = max(scale, 0.01)
        guard s != zoomScale else { return }
        zoomScale = s
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let hosted = hostedView else { return }
        let s = zoomScale
        let logical = NSSize(width: bounds.width / s, height: bounds.height / s)
        canvas.frame = NSRect(origin: .zero, size: logical)
        hosted.frame = canvas.bounds
        // Visual-only scale. AppKit re-syncs layer geometry after frame changes,
        // so re-assert transform + position on every layout pass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = canvas.layer {
            layer.transform = CATransform3DMakeScale(s, s, 1)
            // AppKit view-backing layers use anchorPoint (0,0); compute the
            // position for whatever anchor is in effect so top-left stays pinned.
            let a = layer.anchorPoint
            layer.position = CGPoint(x: a.x * logical.width * s, y: a.y * logical.height * s)
        }
        CATransaction.commit()
        (window as? ScalingWindow)?.eventScale = s
    }
}

// MARK: - ZoomContainerView (verbatim copy of the current in-app mechanism)

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ZoomContainerView: NSView {
    private let canvas = FlippedView()
    private(set) var hostedView: NSView?
    private(set) var zoomScale: CGFloat = 1.0

    override var isFlipped: Bool { true }

    func install(_ view: NSView, scale: CGFloat) {
        zoomScale = max(scale, 0.01)
        if canvas.superview !== self {
            canvas.wantsLayer = true
            addSubview(canvas)
        }
        hostedView?.removeFromSuperview()
        hostedView = view
        canvas.addSubview(view)
        needsLayout = true
    }

    func setScale(_ scale: CGFloat) {
        let s = max(scale, 0.01)
        guard s != zoomScale else { return }
        zoomScale = s
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let hosted = hostedView else { return }
        let s = zoomScale
        canvas.frame = bounds
        canvas.bounds = NSRect(x: 0, y: 0, width: bounds.width / s, height: bounds.height / s)
        hosted.frame = canvas.bounds
    }
}

// MARK: - Magnify container (NSScrollView.magnification)

final class MagnifyContainerView: NSView {
    let scrollView = NSScrollView()
    private(set) var hostedView: NSView?
    private(set) var zoomScale: CGFloat = 1.0

    override var isFlipped: Bool { true }

    func install(_ view: NSView, scale: CGFloat) {
        zoomScale = max(scale, 0.01)
        if scrollView.superview !== self {
            scrollView.hasVerticalScroller = false
            scrollView.hasHorizontalScroller = false
            scrollView.verticalScrollElasticity = .none
            scrollView.horizontalScrollElasticity = .none
            scrollView.drawsBackground = false
            scrollView.allowsMagnification = true
            addSubview(scrollView)
        }
        hostedView = view
        scrollView.documentView = view
        needsLayout = true
    }

    func setScale(_ scale: CGFloat) {
        let s = max(scale, 0.01)
        guard s != zoomScale else { return }
        zoomScale = s
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let hosted = hostedView else { return }
        let s = zoomScale
        scrollView.frame = bounds
        scrollView.setMagnification(s, centeredAt: .zero)
        hosted.frame = NSRect(x: 0, y: 0, width: bounds.width / s, height: bounds.height / s)
        scrollView.contentView.scroll(to: .zero)
    }
}

// MARK: - Plain fill container (scaleeffect / semantic modes)

final class FillContainerView: NSView {
    private(set) var hostedView: NSView?

    override var isFlipped: Bool { true }

    func install(_ view: NSView) {
        hostedView = view
        addSubview(view)
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        hostedView?.frame = bounds
    }
}

// MARK: - Calibration marker (in unscaled window chrome coordinates)

final class CalibrationView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1).setFill()
        bounds.fill()
    }
}

// MARK: - Wrapper VC (keeps NSHostingController in the VC hierarchy — required
// for NavigationSplitView column rendering, same as the real app)

final class WrapperViewController: NSViewController {
    let containerView: NSView
    init(containerView: NSView) {
        self.containerView = containerView
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = containerView }
}

// MARK: - App delegate / command loop

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let zoomModel = ZoomModel()
    var setScale: ((CGFloat) -> Void)!
    var currentScale: CGFloat = 1.0
    let calibView = CalibrationView()
    var nextCmd = 1
    var timer: Timer?
    var eventNumber = 1000

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: protoDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: protoDir.appendingPathComponent("hits.log"))

        NSApp.setActivationPolicy(.regular)

        let root = DemoContentRootView(mode: mode, zoomModel: zoomModel)
            .frame(minWidth: 320, idealWidth: 800, maxWidth: .infinity,
                   minHeight: 260, idealHeight: 600, maxHeight: .infinity)
        let hosting = NSHostingController(rootView: AnyView(root))
        hosting.sizingOptions = []

        let container: NSView
        switch mode {
        case "magnify":
            let magnify = MagnifyContainerView()
            magnify.install(hosting.view, scale: 1.0)
            setScale = { [weak self] s in magnify.setScale(s); self?.currentScale = s }
            container = magnify
        case "scaleeffect", "semantic":
            let fill = FillContainerView()
            fill.install(hosting.view)
            setScale = { [weak self] s in self?.zoomModel.scale = s; self?.currentScale = s }
            container = fill
        case "sendevent":
            let layerScale = LayerScaleContainerView()
            layerScale.install(hosting.view, scale: 1.0)
            setScale = { [weak self] s in layerScale.setScale(s); self?.currentScale = s }
            container = layerScale
        default: // "bounds"
            let boundsContainer = ZoomContainerView()
            boundsContainer.install(hosting.view, scale: 1.0)
            setScale = { [weak self] s in boundsContainer.setScale(s); self?.currentScale = s }
            container = boundsContainer
        }

        // Calibration marker lives in the *unscaled* container coordinate space.
        calibView.frame = NSRect(x: 10, y: 10, width: 16, height: 16)
        container.addSubview(calibView, positioned: .above, relativeTo: nil)

        let wrapperVC = WrapperViewController(containerView: container)
        wrapperVC.addChild(hosting)

        window = mode == "sendevent"
            ? ScalingWindow(contentViewController: wrapperVC)
            : NSWindow(contentViewController: wrapperVC)
        window.title = "ZoomMatrix — \(mode)"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 800, height: 600))
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        // AGENTS.md: open test windows on the built-in screen.
        let builtin = NSScreen.screens.first {
            guard let id = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
            return CGDisplayIsBuiltin(id) != 0
        } ?? NSScreen.main
        if let builtin {
            let f = builtin.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.minX + 60, y: f.maxY - 60 - window.frame.height))
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.writeState()
        }
        // .common mode so command polling keeps running during menu tracking
        // (menus spin the run loop in event-tracking mode).
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollCommands()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func writeState() {
        let calibCenterWindow = calibView.convert(NSPoint(x: 8, y: 8), to: nil)
        let f = window.frame
        let state: [String: Any] = [
            "windowID": window.windowNumber,
            "mode": mode,
            "scale": Double(currentScale),
            "frame": ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height],
            "calib": ["x": calibCenterWindow.x, "y": calibCenterWindow.y],
        ]
        let data = try! JSONSerialization.data(withJSONObject: state)
        try? data.write(to: protoDir.appendingPathComponent("state.json"))
    }

    func pollCommands() {
        while true {
            let cmdURL = protoDir.appendingPathComponent("cmd-\(nextCmd).txt")
            guard let raw = try? String(contentsOf: cmdURL, encoding: .utf8) else { return }
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            let n = nextCmd
            nextCmd += 1
            switch parts.first {
            case "zoom":
                let s = CGFloat(Double(parts[1]) ?? 1.0)
                setScale(s)
                window.contentView?.needsLayout = true
                // Give SwiftUI two runloop turns to settle layout before acking.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.writeState()
                    self?.ack(n)
                }
            case "click":
                let x = CGFloat(Double(parts[1]) ?? 0)
                let y = CGFloat(Double(parts[2]) ?? 0)
                let p = NSPoint(x: x, y: y)
                if let cv = window.contentView {
                    let hit = cv.hitTest(cv.superview!.convert(p, from: nil))
                    let chain = sequence(first: hit, next: { $0?.superview })
                        .prefix(5).compactMap { $0.map { String(describing: type(of: $0)) } }
                    print("[HITTEST] (\(x),\(y)) -> \(chain.joined(separator: " < "))")
                    fflush(stdout)
                }
                click(at: p) { [weak self] in self?.ack(n) }
            case "windows":
                // Dump all on-screen windows of this app (menus are windows too),
                // in CG global coordinates (top-left origin).
                var out: [[String: Any]] = []
                if let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] {
                    for info in list where (info[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier {
                        out.append([
                            "layer": info[kCGWindowLayer as String] as? Int ?? -1,
                            "bounds": info[kCGWindowBounds as String] as? [String: Any] ?? [:],
                            "name": info[kCGWindowName as String] as? String ?? "",
                        ])
                    }
                }
                let data = try! JSONSerialization.data(withJSONObject: out)
                try? data.write(to: protoDir.appendingPathComponent("windows.json"))
                ack(n)
            case "quit":
                ack(n)
                NSApp.terminate(nil)
            default:
                ack(n)
            }
        }
    }

    func click(at p: NSPoint, done: @escaping () -> Void) {
        window.makeKeyAndOrderFront(nil)
        // Post through the app's real event queue (not window.sendEvent):
        // AppKit controls like NSSwitch run a nested tracking loop that dequeues
        // the mouseUp from the queue — a directly-dispatched up never reaches it.
        eventNumber += 1
        let t = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown, location: p, modifierFlags: [],
            timestamp: t, windowNumber: window.windowNumber, context: nil,
            eventNumber: eventNumber, clickCount: 1, pressure: 1)!
        eventNumber += 1
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp, location: p, modifierFlags: [],
            timestamp: t + 0.05, windowNumber: window.windowNumber, context: nil,
            eventNumber: eventNumber, clickCount: 1, pressure: 1)!
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: done)
    }

    func ack(_ n: Int) {
        try? Data("ok\n".utf8).write(to: protoDir.appendingPathComponent("ack-\(n).txt"))
    }
}

struct DemoContentRootView: View {
    let mode: String
    @ObservedObject var zoomModel: ZoomModel

    var body: some View {
        switch mode {
        case "scaleeffect": AnyView(ScaleEffectRoot(zoom: zoomModel))
        case "semantic": AnyView(SemanticRoot(zoom: zoomModel))
        default: AnyView(DemoContent())
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
