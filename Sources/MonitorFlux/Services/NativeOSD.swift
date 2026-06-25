import AppKit
import CoreGraphics
import ObjectiveC

/// Thin bridge to the private `OSDManager` (OSD.framework) — the same on-screen display macOS
/// itself draws for its brightness/volume bezel. Driving it makes our OSD pixel-identical to the
/// native one. This is the technique MonitorControl uses (`OSDUtils.showOsd`).
///
/// Bound dynamically, with no Objective-C bridging header: the class is looked up by name after
/// the framework is loaded, and the multi-argument instance method is invoked through its IMP.
/// `@MainActor` because the OSD must be driven from the main thread — which also keeps the cached
/// singleton clear of Swift 6's global-state concurrency checks.
@MainActor
enum NativeOSD {
    /// OSD image codes from OSD.framework's `_OSDGraphic`, matching MonitorControl's `OSDImage`.
    enum Image: Int64 {
        case contrast = 0
        case brightness = 1
        case speaker = 3
        case speakerMuted = 4
    }

    /// `-[OSDManager showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:]`
    private typealias ShowImageIMP = @convention(c) (
        AnyObject, Selector, Int64, UInt32, UInt32, UInt32, UInt32, UInt32, ObjCBool
    ) -> Void

    private static let showImageSelector = NSSelectorFromString(
        "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
    )

    /// The shared `OSDManager`, resolved once. `nil` if the private API isn't present (so the
    /// caller falls back to the custom panel).
    private static let manager: AnyObject? = {
        // OSD.framework isn't linked into the app; load it so the OSDManager class registers in
        // the Objective-C runtime. Harmless if AppKit already pulled it in (dlopen ref-counts).
        _ = dlopen("/System/Library/PrivateFrameworks/OSD.framework/Versions/A/OSD", RTLD_LAZY)
        guard let osdClass = NSClassFromString("OSDManager") else {
            return nil
        }
        let sharedSelector = NSSelectorFromString("sharedManager")
        guard (osdClass as AnyObject).responds(to: sharedSelector) else {
            return nil
        }
        return (osdClass as AnyObject).perform(sharedSelector)?.takeUnretainedValue()
    }()

    static var isAvailable: Bool {
        manager != nil
    }

    /// Flash the native bezel `image` on `displayID`, filling `filled` of `total` chiclets.
    /// Returns false when the private API is unavailable, so the caller can fall back to its own
    /// panel. `priority`/`msecUntilFade` match MonitorControl's call.
    @discardableResult
    static func show(_ image: Image, onDisplay displayID: CGDirectDisplayID, filled: Int, total: Int) -> Bool {
        guard let manager,
              let method = class_getInstanceMethod(object_getClass(manager), showImageSelector) else {
            return false
        }
        let invoke = unsafeBitCast(method_getImplementation(method), to: ShowImageIMP.self)
        invoke(
            manager,
            showImageSelector,
            image.rawValue,
            displayID,
            0x1F4,
            1000,
            UInt32(max(0, filled)),
            UInt32(max(1, total)),
            ObjCBool(false)
        )
        return true
    }
}
