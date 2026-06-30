import AppKit

/// Wraps one hosted NSView with a uniform zoom (VS Code style) that scales both
/// rendering and hit-testing, while keeping the hosted view in a normal 1:1
/// coordinate system so SwiftUI's NSHostingView lays out cleanly.
///
/// Structure: ZoomContainerView → `canvas` (plain NSView) → hostedView.
///
///   - `canvas` is given a real frame of `bounds.size / scale` and its layer is
///     scaled by `scale`, so it RENDERS at our full size. The hosted view fills
///     `canvas` 1:1, so SwiftUI just sees a (possibly large) normal layout space.
///   - The transform lives on `canvas` — a plain, non-flipped NSView with the
///     standard center layer anchor — NOT on the hosted view. NSHostingView is
///     flipped, so AppKit gives its backing layer flipped geometry and a
///     non-center anchor; scaling that layer directly renders the content offset.
///     A plain canvas avoids that entirely.
///   - `canvas`'s frame ORIGIN is offset so the center-anchored scale lands the
///     content's bottom-left at our (0, 0) — see `canvasOrigin(for:)`.
///
/// Why not a scaled `bounds` instead of a layer transform? Giving the hosting
/// view a parent whose `bounds` size differs from its `frame` size makes SwiftUI
/// re-dirty its constraints every layout pass when laid out larger than the window
/// (zoom < 100%), looping the window's "update constraints" pass until AppKit throws.
///
/// A CALayer transform is invisible to AppKit's event system, so `hitTest` inverts
/// the exact same transform — clicks land on the visible control at every scale.
/// Top-left-origin (y-down) NSView, matching NSHostingView's flipped geometry so
/// the whole zoom chain shares one coordinate convention.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ZoomContainerView: NSView {
    private let canvas = FlippedView()
    private(set) var hostedView: NSView?
    private(set) var zoomScale: CGFloat = 1.0

    // Flipped (y-down, origin top-left) so the layer scale anchors at the top-left
    // corner — content grows/shrinks from the top, like every document window —
    // and matches the flipped NSHostingView inside, avoiding coordinate mismatches.
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

    // AppKit sets our frame on window resize; mark layout dirty so the scaled
    // geometry below is recomputed for the new size.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Origin that makes a center-anchored `scale(s)` render the canvas content's
    /// bottom-left at our (0, 0). With canvas frame size W/s and the default center
    /// anchor, the layer's position (in our coords) is the frame center; scaling
    /// around it renders the content centered on that point. Setting origin =
    /// (size/2)·(1 − 1/s) puts the frame center at our own center, so the scaled
    /// content (size W×H) fills us from the origin.
    private func canvasOrigin(for s: CGFloat) -> NSPoint {
        NSPoint(x: bounds.width / 2 * (1 - 1 / s),
                y: bounds.height / 2 * (1 - 1 / s))
    }

    override func layout() {
        super.layout()
        guard let hosted = hostedView else { return }
        let s = zoomScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Canvas laid out at logical size (bounds/s) with origin 0; the layer scale
        // below blows it up to fill us. Setting frame re-syncs the backing layer's
        // anchorPoint/position, so we override them AFTER to scale around the
        // bottom-left corner (anchor (0,0), positioned at our origin).
        canvas.frame = NSRect(x: 0, y: 0, width: bounds.width / s, height: bounds.height / s)
        hosted.frame = canvas.bounds          // hosted fills canvas 1:1
        if let layer = canvas.layer {
            // Flipped layer: anchorPoint (0,0) is the TOP-left corner; pin it at our
            // top-left (position 0,0) so the content scales from the top-left.
            layer.anchorPoint = .zero
            layer.position = .zero
            layer.transform = CATransform3DMakeScale(s, s, 1)
        }
        CATransaction.commit()
    }

    // `point` is in our coordinate space. With the canvas scaled by `s` from the
    // bottom-left origin, a container point maps to canvas-local by dividing by `s`.
    // canvas.frame.origin is (0,0), so NSView.hitTest takes the point directly.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard hostedView != nil else { return nil }
        let s = zoomScale
        return canvas.hitTest(NSPoint(x: point.x / s, y: point.y / s))
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
