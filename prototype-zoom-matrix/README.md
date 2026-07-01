# Zoom mechanism test matrix

Automated harness that answers, with pixel ground truth, the question this repo
has been fighting: **which zoom mechanism keeps clicks working on a large
`NSHostingView`?** It replicates the real settings-window structure
(`NSHostingController` with `sizingOptions = []`, `NavigationSplitView`,
grouped `Form`) — the earlier prototypes used a single hosted button, which
routes correctly by degeneracy and is why fixes kept "passing" there and then
failing in the app.

## How it works

1. The app applies one zoom mechanism (env `ZOOM_MODE`) and is driven over a
   file protocol in `PROTO_DIR` (`cmd-N.txt` → `ack-N.txt`): `zoom <s>`,
   `click <winX> <winY>`, `windows`, `quit`.
2. Every interactive probe carries a uniquely colored solid marker.
3. `driver.py` screenshots the window (`script/_shot_sck.swift`), finds each
   marker's **visual** position (`analyze.swift`, palette calibrated to the
   P3 built-in display), converts image px → window points via a calibration
   marker rendered in unscaled window coordinates, then commands a click there.
4. Clicks are posted through `NSApp.postEvent` (the real event queue — AppKit
   controls like `NSSwitch` run nested tracking loops that dequeue from it;
   `window.sendEvent` alone hangs them).
5. Control actions append to `hits.log`; the driver prints a pass/fail matrix.

## Run

```sh
swift build
python3 driver.py /tmp/zoom-matrix-results [mode ...]
# modes: bounds magnify scaleeffect semantic sendevent (default: first four)
```

Open windows appear on the built-in screen (AGENTS.md rule) and quit at the end.

## Modes

| mode | mechanism |
|---|---|
| `bounds` | `NSView` bounds scaling — verbatim copy of the in-app `ZoomContainerView` |
| `magnify` | `NSScrollView.magnification` wrapping the hosting view |
| `scaleeffect` | pure SwiftUI `GeometryReader` + `.scaleEffect(anchor: .topLeading)` |
| `semantic` | no geometric transform; root `.font(.system(size: 13*s))` + `.dynamicTypeSize` |
| `sendevent` | visual-only `CALayer` scale + `ScalingWindow` transforming `sendEvent`/`nextEvent(matching:)`/`mouseLocationOutsideOfEventStream` |

## Results (2026-07-01, macOS 26)

Probes: btn-top, toggle(NSSwitch), btn-trailing, btn-bottom, sidebar×2. See
[docs/ZOOM_PLAN.md](../docs/ZOOM_PLAN.md) for the full analysis.

| mode | 1.0× | 1.5× | 2.0× |
|---|---|---|---|
| bounds | 6/6 | 0/6–2/6 | 0/6–2/6 |
| magnify | 6/6 | 2/6 | 2/6 |
| scaleeffect | 6/6 | 2/6 | 2/6 |
| **semantic** | **6/6** | **6/6** | **6/6** |
| **sendevent** | **6/6** | **6/6** | **6/6** |

(The 2/6 passes are the sidebar rows — `NSTableView`-backed, converted by
AppKit; the failures are all SwiftUI-rendered content.)

`sendevent` additionally fails **menu positioning** (measured via the
`windows` command with a Picker open at 2×: the menu opens at the *logical*
offset (296, 247)pt from the window's top-left instead of the visual
(~690, 498), and at native size).
