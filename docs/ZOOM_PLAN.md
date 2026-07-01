# Settings-window zoom: root cause, evidence, and plan

*2026-07-01 · produced with the automated test harness in
[prototype-zoom-matrix/](../prototype-zoom-matrix/README.md)*

## TL;DR

Every geometric zoom mechanism available on macOS breaks click routing for
SwiftUI content hosted in a large `NSHostingView` — this is structural, not a
bug in any one attempt. Five mechanisms were tested against pixel ground truth;
only two pass all click probes at every zoom level:

- **`semantic`** — font-based scaling (`.font` + `.dynamicTypeSize`), pure
  SwiftUI, no coordinate math anywhere. Crisp text, zero desync risk.
  **This is the recommended fix** (Phase 1 below).
- **`sendevent`** — visual-only layer scale + a window subclass that rescales
  event coordinates. True whole-window zoom and all click probes pass, but
  **menu/popover positioning is measurably broken** and fixing it means
  stacking more AppKit overrides. Kept as the fallback if whole-window pixel
  zoom is a hard requirement (Phase 2).

Electron is not warranted: a native mechanism passes 18/18 click probes, and
the app's core (gamma tables, DDC, media-key taps, menu-bar extra) would need a
native helper process anyway.

## Root cause — why five attempts failed

macOS has no view-level transform (unlike iOS's `UIView.transform`). The only
"native" scaling mechanisms are `NSView` bounds scaling and CALayer transforms,
and both fail the same way for hosted SwiftUI:

1. **CALayer transforms** (sublayerTransform `cd994ff`, layer transform
   `8c25ee2`) are invisible to AppKit event geometry — `convert(_:from:)` uses
   frame geometry, so visual and click positions desync at any zoom ≠ 1.
2. **`NSView` bounds scaling** (`72569fa`, current branch) fixes AppKit's
   conversions, but `NSHostingView` routes events with SwiftUI's own
   window-geometry tracking, which reads the hosting view's *frame* and raw
   `locationInWindow` — blind to ancestor bounds scaling. AppKit-backed
   descendants (the `NSTableView` sidebar) still work; SwiftUI-rendered
   controls don't. This matches the measured matrix exactly.
3. **`NSScrollView.magnification`** is implemented as clip-view bounds scaling
   → identical failure (measured; this kills the "most promising" direction
   from the earlier root-cause analysis).
4. **SwiftUI `.scaleEffect`** fails for the same content because macOS SwiftUI
   renders forms/controls via AppKit-backed platform views whose event routing
   can't see the SwiftUI transform (also the reason the pre-`3ea405c` zoom
   broke).

General law for this repo: **any mechanism that makes visual geometry differ
from AppKit view-frame geometry above or below an `NSHostingView` boundary will
desync something** — the only questions are which subsystem (SwiftUI routing,
AppKit tracking loops, menus, tooltips, IME) and at which macOS release.

## Evidence

Method: replicate the real window structure (`NSHostingController` +
`NavigationSplitView` + grouped `Form`), color-mark every probe control,
screenshot at each zoom, click each probe at its **visual** position through
the app's real event queue, and record which actions fire. Probes: two plain
buttons, a trailing button, an `NSSwitch` toggle, two sidebar rows.

| mode | 1.0× | 1.5× | 2.0× | notes |
|---|---|---|---|---|
| bounds (current app) | 6/6 | 0–2/6 | 0–2/6 | only NSTableView sidebar survives |
| magnify | 6/6 | 2/6 | 2/6 | same failure signature as bounds |
| scaleeffect | 6/6 | 2/6 | 2/6 | same |
| **semantic** | 6/6 | 6/6 | 6/6 | text crisp (real glyphs at target size) |
| **sendevent** | 6/6 | 6/6 | 6/6 | text soft at 2× (raster upscale); **menus open at logical position & native size** (measured: menu at (296,247)pt from window top-left vs visual (~690,498) at 2×) |

All geometric failures are silent no-hits (SwiftUI claims the event and routes
it nowhere); some earlier diagnostics also showed clicks landing on *wrong*
controls — worse than dead.

## Phase 1 (recommended): semantic zoom, pure SwiftUI

Restore and extend the approach that already shipped in `6087bb8` (it was
removed in `cd994ff` for the whole-window scale, not because it was broken —
and the whole-window scale never worked).

1. **Remove the geometric plumbing**: delete
   `Support/ZoomContainerView.swift` (+ `ZoomWrapperViewController`); in
   `AppStore.makeMainWindow()` return to `NSHostingController` as
   `contentViewController` directly, `hosting.sizingOptions` back to default
   (agent.md window-sizing gotcha: default sizing options MUST stay — clearing
   them was only needed for the zoom container), keep the
   `.frame(idealWidth:idealHeight:)` pin. Drop `zoomContainerView` and the
   `setScale` call in `setFontSizeStep`.
2. **Restore root modifiers on `ContentView`** (from `6087bb8`, extended to the
   current `fontSizeStepRange` 0…8, keeping `fontSizeStep` persistence, the
   hidden ⌘+/⌘−/⌘0 command buttons, and the −/+/Reset controls in the General
   pane):
   - `.font(.system(size: settingsFontSize))` — sizes ≈
     `[11, 12, 13, 14.5, 16, 18, 20, 23, 26]`
   - `.dynamicTypeSize(settingsDynamicTypeSize)` — steps ≈
     `[.small, .medium, .large, .xLarge, .xxLarge, .xxxLarge, .accessibility1,
     .accessibility2, .accessibility3]`
     (dynamicTypeSize is what reaches the sidebar's text style — root `.font`
     alone measurably does not scale sidebar rows)
3. **Scale control chrome discretely**: `.controlSize(.large)` from step ≥ 5,
   `.extraLarge` from step ≥ 7 (macOS 14+), so switches/steppers/sliders grow
   with the text instead of staying miniature.
4. **Scale the split-view columns**: multiply
   `navigationSplitViewColumnWidth(min:ideal:max:)` by `settingsFontSize / 13`
   so the sidebar doesn't truncate at accessibility sizes.
5. **Optional polish**: apply the same two root modifiers to the menu-bar popup
   root view so both surfaces honor the preference; scale explicit paddings via
   a `@ScaledMetric`-style environment value only where visibly cramped.
6. **Docs/tests**: update the agent.md "Window text size" bullet (it already
   documents this approach — the code will match it again), keep
   `MONITORFLUX_ZOOM_STEP` as the screenshot hook, re-run
   `PreferencesMigrationTests`/`ColorSignatureTests` (fontSizeStep stays out of
   the color signature).

**Verification** (the part every previous attempt skipped):
- Re-run the harness `semantic` mode: `python3 prototype-zoom-matrix/driver.py
  /tmp/zm semantic` → must stay 18/18.
- In-app check with the real window: `MONITORFLUX_ZOOM_STEP=8
  ./script/build_and_run.sh --safe`, screenshot via `script/_shot_sck.swift`,
  and click-probe a toggle + sidebar row (AX check as in `6087bb8`).
- Hover/tooltips/menus need no special testing — there is no coordinate
  transform to break them.

Trade-off to accept: this scales text and (discretely) controls; it does not
magnify pixels uniformly. Layout reflows like a website with a larger font
rather than a screenshot blown up — which is also how native macOS apps behave
(no mainstream Mac app geometrically zooms its control chrome).

## Phase 2 (only if whole-window pixel zoom is a hard requirement): sendevent

Prototype-proven for clicks (18/18 including the NSSwitch nested tracking
loop), with this exact override set on an `NSWindow` subclass +
top-left-anchored layer scale (see `prototype-zoom-matrix` `sendevent` mode):
- `sendEvent(_:)` — rescale mouse-event `locationInWindow` (content region
  only; titlebar untouched)
- `nextEvent(matching:until:inMode:dequeue:)` — same transform; this is what
  fixes controls that run nested tracking loops (NSSwitch et al.)
- `mouseLocationOutsideOfEventStream`
- layer `position` must be re-asserted every `layout()` pass (AppKit resyncs
  view-backing layer geometry; anchorPoint is `(0,0)` for view layers)

Known open work before it could ship, in order of severity:
1. **Menus/popovers/tooltips open at logical positions and native size**
   (measured). Candidate fix: also override `convertPoint(toScreen:)` /
   `convertPoint(fromScreen:)` to scale content-region coordinates, then
   re-measure with the harness `windows` command; risk of double-transform in
   AppKit internals is real and macOS-version-dependent.
2. **Scroll events** are not yet transformed (`NSEvent.mouseEvent` can't build
   scrollWheel events — needs a `CGEvent` copy with rewritten location);
   detail panes scroll (`ColorScheduleView`), so this is mandatory.
3. **Hover/tracking areas, cursor rects, IME caret/candidate positioning,
   drag & drop** — untested; each is a potential repeat of the click saga.
4. **Rendering softness** at high zoom (raster upscale vs semantic's real
   glyphs; measured side-by-side at 2×).

Budget honestly: this is a hack stack over private AppKit dispatch behavior.
Every macOS release can move the cheese. The harness + menu probe make
regressions detectable, but the wart list above is why Phase 1 is the
recommendation.

## Electron — criteria, not a plan

Reconsider only if (a) whole-window pixel zoom is non-negotiable AND (b)
Phase 2's menu/hover/IME hardening hits a wall. Chromium gives free, crisp
`page zoom`, but the app keeps needing a native side (gamma/DDC/IOKit,
CGEventTap media keys, menu-bar presence, login item) — so Electron means a
two-process architecture and a full settings-UI rewrite, not a swap. If it
ever comes to that, keep the Swift core as a helper (JSON-RPC over stdio) and
port only the settings window; the menu-bar popup can stay native.

## Housekeeping

- `prototype-test/`, `prototype-test-2-fix/`, `prototype-swiftui-zoom/` are
  superseded by `prototype-zoom-matrix/` (their single-button click tests pass
  by degeneracy — any point in a one-control hosting view routes to that
  control — which is how broken approaches kept looking fixed). Safe to delete
  the first three once this plan lands.
- Update the memory/agent notes that blessed bounds scaling (`72569fa`'s
  commit message and the current `ZoomContainerView` doc comment describe a
  mechanism now measured broken).
