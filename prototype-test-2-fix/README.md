# Zoom Desync Fix Prototype

Tiny standalone macOS prototype for testing a native visual/click desync fix without
touching the MonitorFlux app.

Run it with:

```sh
cd prototype-test-2-fix
swift run
```

The window shows:

- the current zoom level
- the current mouse position
- the last click position and whether the button action fired
- a normal SwiftUI button, hosted in `NSHostingView`, in the middle of a stage

Use `Cmd+`, `Cmd-`, and `Cmd0` to change zoom. This version fixes the desync by
changing the stage content's `bounds` instead of applying a visual-only `CALayer`
transform. The button is drawn larger, and AppKit converts clicks through the same
zoomed coordinate system.

This is a small native fix sandbox, not a full MonitorFlux patch.

## Fix

The broken prototype scaled `contentView.layer`, which only moved pixels. AppKit
still used the unscaled view frames for event coordinates.

This version removes the layer transform and zooms the content by changing the
content view's `bounds`:

```swift
let s = max(zoomScale, 0.01)
contentView.frame = bounds
contentView.bounds = NSRect(x: 0, y: 0, width: bounds.width / s, height: bounds.height / s)
```

The hosted SwiftUI button is then centered inside `contentView.bounds`, so AppKit
draws and hit-tests through the same scaled coordinate system.

## Diff From Broken Prototype

```diff
--- prototype-test/Sources/ZoomDesyncPrototype/main.swift
+++ prototype-test-2-fix/Sources/ZoomDesyncPrototype/main.swift
@@ -75,7 +75,7 @@
     private let zoomLabel = NSTextField(labelWithString: "")
     private let mouseLabel = NSTextField(labelWithString: "")
     private let clickLabel = NSTextField(labelWithString: "Last click: none")
-    private let hintLabel = NSTextField(labelWithString: "Click the visible button edges after zooming in; the action should miss.")
+    private let hintLabel = NSTextField(labelWithString: "Click the visible button edges after zooming in; the button action should still fire.")
     private let stageView = StageView()
     private var trackingAreaRef: NSTrackingArea?
     private var lastMousePoint = NSPoint.zero
@@ -157,7 +157,7 @@
 
     var zoomScale: CGFloat = 1 {
         didSet {
-            applyVisualScale()
+            needsLayout = true
         }
     }
 
@@ -191,23 +191,17 @@
 
     override func layout() {
         super.layout()
+        let s = max(zoomScale, 0.01)
         contentView.frame = bounds
+        contentView.bounds = NSRect(x: 0, y: 0, width: bounds.width / s, height: bounds.height / s)
         buttonHost.frame = NSRect(
-            x: (bounds.width - 120) / 2,
-            y: (bounds.height - 36) / 2,
+            x: (contentView.bounds.width - 120) / 2,
+            y: (contentView.bounds.height - 36) / 2,
             width: 120,
             height: 36
         )
-        applyVisualScale()
     }
 
-    private func applyVisualScale() {
-        CATransaction.begin()
-        CATransaction.setDisableActions(true)
-        contentView.layer?.setAffineTransform(CGAffineTransform(scaleX: zoomScale, y: zoomScale))
-        CATransaction.commit()
-    }
-
     private func buttonClicked() {
         let event = NSApp.currentEvent
         let point = event.map { convert($0.locationInWindow, from: nil) } ?? .zero
```
