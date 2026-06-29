import AppKit

/// Wraps one hosted NSView with a uniform zoom effect that keeps hit-testing correct.
///
/// How it works:
///   1. The hosted view is laid out at `bounds / scale` (smaller layout space).
///   2. `sublayerTransform` on ZoomContainerView's own layer scales all sublayers'
///      rendering back up to fill the container, from origin (0,0) = bottom-left
///      in AppKit's y-up space — without touching any child layer's position or anchorPoint.
///   3. `hitTest` divides incoming points by `scale` before forwarding to the
///      hosted view, so clicks always land on the visible control — not the
///      pre-scale layout position.
///
/// Using `sublayerTransform` (rather than mutating the hosted view's own layer) is key:
/// NSView's automatic layer-backing sync overwrites `layer.position` on the hosted view
/// whenever its frame changes, which would desync visual and hit-test coordinates.
/// `sublayerTransform` lives on the parent and is never touched by the child's sync.
final class ZoomContainerView: NSView {
    private(set) var hostedView: NSView?
    private(set) var zoomScale: CGFloat = 1.0

    func install(_ view: NSView, scale: CGFloat) {
        zoomScale = scale
        hostedView = view
        wantsLayer = true
        view.wantsLayer = true
        addSubview(view)
        needsLayout = true
    }

    func setScale(_ scale: CGFloat) {
        guard scale != zoomScale else { return }
        zoomScale = scale
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let hosted = hostedView else { return }
        let s = zoomScale
        // Give hosted view a smaller layout frame (1/s of our bounds). The
        // sublayerTransform below scales the visual rendering back up to fill us.
        hosted.frame = NSRect(x: 0, y: 0, width: bounds.width / s, height: bounds.height / s)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // sublayerTransform scales from (0,0) — bottom-left in AppKit's y-up space —
        // without touching hosted.layer's position/anchorPoint, which NSView manages.
        layer?.sublayerTransform = CATransform3DMakeScale(s, s, 1)
        CATransaction.commit()
    }

    // `point` arrives in our coordinate space (same as the window since we fill it).
    // sublayerTransform scales the hosted view's visual rendering by `zoomScale` from (0,0).
    // Dividing by scale converts to the hosted view's layout coordinate space (frame = bounds/s),
    // which is what NSView.hitTest expects. NSView.hitTest handles the isFlipped=true
    // coordinate flip for NSHostingView internally.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hosted = hostedView else { return nil }
        let p = NSPoint(x: point.x / zoomScale, y: point.y / zoomScale)
        guard p.x >= 0, p.x <= hosted.frame.width,
              p.y >= 0, p.y <= hosted.frame.height else { return nil }
        return hosted.hitTest(p)
    }
}

/// Thin NSViewController whose sole job is owning a ZoomContainerView as its
/// view, with the NSHostingController as a child so the VC hierarchy is intact
/// (NavigationSplitView column rendering requires the hosting controller to be
/// in the VC hierarchy, not just the view hierarchy).
final class ZoomWrapperViewController: NSViewController {
    let zoomView: ZoomContainerView

    init(zoomView: ZoomContainerView) {
        self.zoomView = zoomView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = zoomView
    }
}
