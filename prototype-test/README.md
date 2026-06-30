# Zoom Desync Prototype

Tiny standalone macOS prototype for reproducing visual/click desync without touching
the MonitorFlux app.

Run it with:

```sh
cd prototype-test
swift run
```

The window shows:

- the current zoom level
- the current mouse position
- the last click position and whether the button action fired
- a normal SwiftUI button, hosted in `NSHostingView`, in the middle of a stage

Use `Cmd+`, `Cmd-`, and `Cmd0` to change zoom. The prototype intentionally applies
a visual-only `CALayer` transform to the stage content. At zoom levels other than
100%, the button is drawn larger, but AppKit still hit-tests the original unscaled
view frames. Clicking the visually enlarged edges should miss the button, showing
the same class of bug as a visual transform that moves pixels without moving AppKit
event coordinates.

This is a reproduction sandbox, not a proposed fix.
