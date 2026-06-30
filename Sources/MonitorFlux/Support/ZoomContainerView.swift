import AppKit

/// Wraps one hosted NSView with a uniform zoom (VS Code style) that scales both
/// rendering and event coordinates using `NSView` bounds scaling.
///
/// Structure: ZoomContainerView → `canvas` (FlippedView) → hostedView.
///
///   - `canvas.frame` fills the container at real pixel size.
///   - `canvas.bounds` is set to `frame.size / scale`, giving the hosted view a
///     logical coordinate system at the desired zoom level. AppKit renders the
///     bounds-sized content into the frame-sized area, producing the visual zoom.
///   - The hosted view fills `canvas.bounds` 1:1, so SwiftUI sees a stable,
///     normal-sized layout space and does not loop its constraint cycle.
///
/// Why bounds scaling instead of a CALayer transform?
///
/// A CALayer transform (or sublayerTransform) is invisible to AppKit's event
/// coordinate system. `hitTest` can be overridden to find the correct target view,
/// but after that, AppKit delivers the actual event using `NSEvent.locationInWindow`
/// and converts it to the target view's local coordinates via `convert(_:from:)`.
/// That conversion uses the view's *frame geometry* — the un-scaled logical frame —
/// not the visually scaled layer. So the visual position and the event coordinate
/// are permanently desynced at any zoom ≠ 100%.
///
/// `NSView.bounds` scaling is a native mechanism: `convert(_:from:)` automatically
/// accounts for the bounds-to-frame ratio, so hit-testing, click coordinates,
/// scroll events, and drag coordinates all land at the correct logical position.
///
/// The canvas is flipped (y-down) to match NSHostingView's coordinate convention,
/// so content anchors at the top-left corner and grows downward on zoom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class ZoomContainerView: NSView {
    private let canvas = FlippedView()
    private(set) var hostedView: NSView?
    private(set) var zoomScale: CGFloat = 1.0

    // Flipped (y-down, origin top-left) so subview layout starts from the top,
    // matching the flipped canvas and NSHostingView inside.
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

    override func layout() {
        super.layout()
        guard let hosted = hostedView else { return }
        let s = zoomScale
        // Canvas fills us at real pixel size; its bounds are the logical (zoomed)
        // coordinate space. AppKit scales rendering from bounds to frame and
        // applies the inverse on all coordinate conversions, so event delivery
        // and hit-testing automatically match the visual content at every scale.
        canvas.frame = bounds
        canvas.bounds = NSRect(x: 0, y: 0,
                               width: bounds.width / s,
                               height: bounds.height / s)
        hosted.frame = canvas.bounds
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
