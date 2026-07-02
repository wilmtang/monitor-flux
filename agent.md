# Agent Guide

This repo is a SwiftPM macOS app. Treat display control as a high-risk surface:
small mistakes can flicker monitors, leave gamma tables altered, or send bad DDC
commands to hardware.

## Commands

- Build and run the app bundle: `./script/build_and_run.sh`
- Verify launch: `./script/build_and_run.sh --verify`
- Run tests: `swift test`
- Smoke-test the detailed window opens (not blank / not duplicated): `./script/smoke_test.sh`
- Run without touching hardware: `./script/build_and_run.sh --safe`
- Make Accessibility (media keys) survive rebuilds: `./script/make_dev_cert.sh` (once)

**Safe mode** (`MONITORFLUX_SAFE_MODE=1`, set by `--safe`, `--verify`, and `smoke_test.sh`)
drives the full UI but performs **no gamma/DDC/backlight writes** — so testing doesn't
flicker the screen or fight f.lux/MonitorControl. Use it for any iteration where you only
need to see the UI. All hardware-writing paths in `AppStore` are gated on `safeMode`. Full
breakdown: [docs/SAFE_MODE.md](docs/SAFE_MODE.md).

Stop the running dev app before doing risky gamma work (or just use `--safe`):

```sh
pkill -x MonitorFlux || true
```

## Architecture

- `App/`: SwiftUI app entrypoint and AppKit delegate. Launches menu-bar-first
  (`LSUIElement`); the delegate drives the activation policy (Dock visibility). The only
  SwiftUI scene is the `MenuBarExtra`. The detailed window is an AppKit `NSWindow` +
  `NSHostingController` managed by `AppStore.showMainWindow()` — NOT a `WindowGroup`/
  `Settings` scene, because `openWindow` from a `.window` `MenuBarExtra` in an accessory
  app opens blank, duplicate windows. All app-level settings (Dock/keyboard/login) live
  in the window's "General" pane so they're reachable without an app menu. **Window-sizing
  gotcha (regressed twice — do not change without screenshotting):** the content MUST be an
  `NSHostingController` (a bare `NSHostingView` renders a `NavigationSplitView` blank), its
  default `sizingOptions` MUST stay (clearing them also blanks the columns), and the root
  view is `.frame(idealWidth:idealHeight:)`-pinned so the controller doesn't size the window
  to the tall detail pane (that produced an off-screen ~880x3305 "blank" window). Detail
  panes scroll internally (every pane is a full-bleed grouped `Form` — no extra `.padding()`
  around it, and `ColorScheduleView`'s hero rides in the form as its first section so its
  edges align with the cards below). Default content size is
  `mainWindowDefaultSize` (800×600) — a comfortable default, not a constraint: the grouped
  forms cap and center their own content width, so wider windows stay well-formed. The
  sidebar is collapsible by dragging the divider, so `ContentView` binds `columnVisibility` and
  adds a toolbar sidebar toggle (⌃⌘S) — otherwise a collapsed sidebar can't be brought back.
- **Window zoom** (`⌘+`/`⌘-`/`⌘0`, persisted as `AppPreferences.fontSizeStep`): semantic
  sizing only — root `.font(.system(size:))` + stepped `.controlSize` on `ContentView`,
  explicit fonts on the sidebar rows/headers (the sidebar list style ignores the environment
  font — the font must sit on the `Text` inside each `Label`), and `zoomFont(...)`
  (`Support/ZoomFont.swift`) instead of fixed text styles like `.font(.caption)` in
  settings-window views. Dynamic Type is inert on macOS (measured — pixel-identical A/B), so
  don't reach for `.dynamicTypeSize`. NEVER reintroduce a geometric zoom: NSView bounds
  scaling, CALayer transforms, `NSScrollView.magnification`, and `.scaleEffect` were each
  tried and ALL break click routing for SwiftUI content in a large `NSHostingView` — sidebar
  clicks surviving is a false positive (it's NSTableView-backed). Evidence + regression
  harness: [docs/ZOOM_PLAN.md](docs/ZOOM_PLAN.md), `prototype-zoom-matrix/`.
- `Services/HotKeyCenter.swift`: custom global shortcuts via Carbon `RegisterEventHotKey`
  (no Accessibility needed). Behind a `HotKeyRegistering` protocol so conflict bookkeeping is
  unit-tested with a fake. `Views/ShortcutRecorder.swift` captures combos with an app-level
  `NSEvent` local monitor — NOT an `NSViewRepresentable` (SwiftUI doesn't route key events to
  an embedded NSView, so capture silently never fires).
- `Services/AudioCapabilityService.swift`: CoreAudio detection of which displays have
  speakers (HDMI/DisplayPort output device, exact normalized name match) — gates the DDC
  volume slider so speakerless monitors don't show one.
- `Support/DisplayIdentity.swift`: stable per-display key from EDID (vendor/model/serial),
  NOT `CGDirectDisplayID` (which churns across reconnect/reboot). Preferences are keyed by it.
- `Models/`: persisted app/display preferences and navigation selection. Three
  color phases (Daytime/Sunset/Bedtime) via `ColorPhase`; `ScheduleSource`.
- `Stores/AppStore.swift`: main actor state owner and mutation gateway. Owns the
  `LocationService` and throttles live DDC slider writes (`scheduleDDC`).
- `Services/GammaPlan.swift`: pure gamma intent planning.
- `Support/GammaCompositor.swift`: pure math for warmth + brightness + contrast.
- `Support/HybridBrightness.swift`: pure math for the **unified brightness** scale — one
  0…1 position per display covering hardware (DDC/backlight) above the fixed 25% handoff
  notch and software (gamma, floored at 15% or 0 with "Allow dimming to black") below.
  `AppStore.brightnessControlKind(for:)` routes each display (hybrid / hardware-only /
  software-only / shade / unavailable) from its capabilities + per-display `DimmingMode`
  (resolved by `DimmingMode.resolved(_:isBuiltIn:)`: externals default `.automatic`, the
  built-in defaults `.hardware` and is **binary** — all-backlight or all-software, never
  hybrid, so flicker-sensitive users can park the backlight and dim purely in software);
  the slider, media keys, OSD fraction, and scheduled brightness targets all speak this
  scale via `unifiedBrightness`/`setUnifiedBrightness`/`scheduledComponents`.
- `Support/SolarCalculator.swift`: pure NOAA sunrise/sunset from lat/long.
- `Services/GammaTemperatureService.swift`: the only CoreGraphics gamma writer.
- `Services/NativeDDCBackend.swift`: Intel IOKit IOFramebuffer DDC/CI writes.
- `Services/Arm64DDCBackend.swift`: Apple Silicon DDC via the private `IOAVService`.
- `Services/HardwareDDCBackend.swift`: arch-selected native DDC (`#if arch(arm64)`)
  plus the optional `ddcctl` fallback.
- `Services/NativeBrightnessBackend.swift`: real backlight for the built-in/Apple
  panels via the private DisplayServices framework (resolved with `dlopen`/`dlsym`).
- `Services/LocationService.swift`: CoreLocation one-shot fix for the solar schedule.
- `Services/KeyboardControlService.swift`: a `CGEventTap` that routes the brightness/
  volume media keys to the display under the cursor (needs Accessibility permission).
  Two delivery paths exist: external USB keyboards send `NSSystemDefined` subtype 8
  (key code in the high 16 bits of `data1`, `isKeyDown == (keyFlags & 0xFF00) >> 8 == 0x0A`),
  the **built-in** keyboard sends brightness as plain `keyDown` 144/145 — the tap handles both.
  The shortcut **recorder** (`ShortcutRecorder.mediaShortcut(from:)`) normalizes the same two
  paths, so recording a brightness key always yields a media binding rather than a stray Carbon
  key-code-144 keyboard shortcut, and Option+brightness still passes through to macOS.
- `Services/OSDController.swift` + `Services/NativeOSD.swift`: the on-screen bezel.
  Brightness/volume use the **private `OSDManager`** (OSD.framework) so they're pixel-identical
  to macOS's own bezel (the MonitorControl approach); contrast and color/warmth have no native
  bezel, so they use a custom tinted SwiftUI panel (also the fallback if the private API is absent).
  `NativeOSD` binds `OSDManager` dynamically (dlopen + IMP cast), no bridging header.
- `Services/ShadeController.swift` + `Services/CoreDisplayInfo.swift`: software dimming for
  **AirPlay/virtual** displays. They ignore gamma, so `CoreDisplayInfo` detects them (private
  `CoreDisplay_DisplayCreateInfoDictionary`, `kCGDisplayIsAirPlay`/virtual) and `ShadeController`
  dims them with a black overlay window at `CGShieldingWindowLevel()` — the MonitorControl "shade".
- `Support/DragReorder.swift`: pure swap math for the popup's iOS-style drag-to-reorder (cards
  lift and siblings spring aside). The gesture lives on the card grip in `QuickControlsView` and
  reads the global coordinate space (not local — the grip rides the lifted card, which would feed back).
- `Views/Components.swift`: shared `MonitorSlider` (MonitorControl-style, no tick
  marks), `InfoButton` (jargon explainers), `WarningCard` (the one inline warning
  treatment — every in-window warning renders through it), and `GammaConflictBanner`
  (built on `WarningCard`).
- `Views/`: SwiftUI window, the `QuickControlsView` menu-bar popup (drag-to-reorder cards;
  the Warmth card mirrors the display cards), settings, and per-display controls. AirPlay/virtual
  displays get a stripped-down detail pane (overlay dimming only — no warmth/DDC/gamma/schedule,
  since those have no effect there).
- `Views/FluxCurveEditor.swift` + `Services/ColorSchedule.swift`: the schedule curve. A draggable
  "now" marker scrub-previews how the screen will look at any time — warmth via
  `AppStore.previewScheduleColor` (`schedulePreviewMinute`, a gamma override that doesn't touch
  stored prefs), plus each DDC external display's **scheduled brightness/contrast** at that time,
  sent transiently to the monitor firmware via `previewHardwareDDC` with **no stored-pref writes**
  (the live schedule is suspended while previewing; `restoreScheduledHardwareAfterPreview` puts the
  now-targets back on exit). Dragging the marker — or editing **any** schedule control — adopts
  Automatic mode (`colorMode = .clock`): phase temps and the fade go through `scheduleEditBinding`,
  while the wake/sunset/bedtime **times** go through `timeAnchorBinding`, which additionally pins the
  source to **Set times** (`.manualTimes`) — hand-placing a time means you're setting it, and a solar
  source would otherwise recompute over it. `timeAnchorBinding` also *reads* the solar-adjusted
  ("effective") anchor, so in Sunrise & sunset mode the curve, dots, and steppers show the computed
  sunrise/sunset (`ColorSchedule.solarAdjustedPreferences`). The preview is always temporary:
  `clearSchedulePreview` restores the live values whenever the Schedule pane reloads, the settings
  window loses key focus, the mode leaves clock, or Refresh is tapped.
- `script/make_icon.swift`: regenerates `Assets/AppIcon.icns` from code.
- `Tests/`: pure behavior tests; avoid tests that write real gamma or DDC.

## Engineering Rules

- Route every gamma-affecting feature through `GammaPlan` and
  `GammaCompositor`. Never add a second gamma writer.
- `GammaTemperatureService` must avoid repeated identical writes. Repeated gamma
  writes can cause visible flicker.
- Keep gamma-conflict *detection* off the per-drag path. `reconcileColor` runs on every
  warmth/software-dim slider tick, so the LUT read-back + running-app scan that spot a foreign
  gamma app live in `AppStore.refreshGammaConflictState` (driven by the 60s timer and display
  refreshes), never in `reconcileColor`. A foreign gamma app is a persistent condition, so a
  periodic check is enough — and detection must run before `apply` re-asserts our table.
- Normalize preferences with `ControlRanges` before saving or using values.
- **No no-op `@Published` writes on drag paths.** `objectWillChange` fires on every set — equal
  or not — and re-renders every observer of the store. Route preference edits through
  `updateGlobalPreferences`/`updateDisplayPreferences` (they skip equal values), and coalesce
  chatty status text through `reportDDCStatus` instead of assigning `ddcMessage` per write.
  Redundant publishes at mouse-event rate were the original slider-lag bug.
- Keep hardware DDC separate from gamma in naming and state. The unified Brightness control
  is the one deliberate blend of the two, and it goes through `HybridBrightness` +
  `AppStore.setUnifiedBrightness` only — never mix DDC and gamma ad hoc in a view or feature.
- Do not make Homebrew tools required. `ddcctl` is fallback only, and it is
  Intel-only — on Apple Silicon `Arm64DDCBackend` (IOAVService) is the real path.
- The menu bar popup is `QuickControlsView` with `.menuBarExtraStyle(.window)` and
  live sliders (MonitorControl-style). Continuous drags go through the 45 ms
  leading-edge throttle in `AppStore.scheduleDDC` (a trailing write settles on the
  final value), so the monitor tracks the drag without flooding the I2C bus. Don't
  regress it to a trailing-only debounce — that only updates the monitor on release.
- Keep DDC writes off the main thread; gamma writes stay routed through the single
  `GammaTemperatureService` writer.
- Use `MonitorSlider` (not a stepped SwiftUI `Slider`) for the popup; a `step:` on a
  macOS `Slider` draws tick marks. Round in the setter instead.
- Gamma is a single-owner resource: surface the `GammaConflictBanner` so users disable
  Night Shift / other color apps. Explain gamma vs DDC with `InfoButton` (assume the
  reader doesn't know the jargon).
- The media-key tap (`KeyboardControlService`) needs Accessibility permission. Ad-hoc dev
  builds drop the grant after each rebuild because the code hash changes; run
  `./script/make_dev_cert.sh` once to create a stable "MonitorFlux Dev" cert (build_and_run.sh
  then signs with it, or with `SIGN_IDENTITY` if set) so the grant persists. Custom hotkeys
  (`HotKeyCenter`, Carbon) need no Accessibility — prefer them for testing.
- **Never drive the built-in panel's real backlight automatically.** macOS manages it
  (auto-brightness, Night Shift); the *schedule* and the *media keys* must leave it alone —
  forcing a level fights macOS and jumps brightness on launch. Only *user-initiated* actions
  touch it: the manual native-backlight slider, and custom hotkeys (which pass
  `allowBuiltIn: true` to `adjustBrightnessUnderCursor`, since a custom combo has no macOS
  fallback). External-display **contrast** always goes through DDC; external **brightness** uses
  DDC when the panel supports it, else falls back to software (gamma/shade) dimming — the same
  fallback the live brightness slider uses, so scheduled brightness still works on non-DDC monitors.
- Saved DDC brightness/contrast is re-applied to **external** displays on launch/reconnect
  (`restoreHardwareSettings`); never re-apply to the built-in.
- **AirPlay/virtual displays ignore gamma.** Detect them with `CoreDisplayInfo.isVirtual` and
  dim them through `ShadeController` (overlay), not gamma. `GammaPlan` excludes them, and their
  detail/popup UI hides the controls that don't work (warmth, DDC, gamma, schedule). The shade is
  plain dimming, independent of the Warmth master, and darker-only.
- **Mirror sets:** gamma/shade writes target `DisplayInfo.effectiveID` (the mirror master via
  `CGDisplayMirrorsDisplay`), and `GammaPlan` dedupes a mirror set to one write through the master
  — never write gamma to a mirrored child.
- **OSD:** brightness/volume go through the native `OSDManager` bezel; contrast/color use the
  custom panel (no native bezel exists for them). Don't expect the native path to draw a glyph for
  contrast — macOS has none. The custom panel copies the native bezel's placement exactly:
  200×200, horizontally centered, **bottom edge 140 pt above the screen's bottom edge** (measured
  from OSDUIHelper's window frame) — not a percentage of screen height, which drifts per display.
- New behavior should get focused tests unless it directly touches real display
  hardware. The arm64 DDC packet builder and `SolarCalculator` are pure and tested
  (`GammaPlanTests` covers virtual-exclusion + mirror dedup; `DragReorderTests` the reorder math).

## UX bar — design like a senior Apple designer

Hold every user-facing change to what an Apple HI designer would ship. Outcomes over machinery,
restraint over options, and never trap the user:

- **Clarity first.** One obvious thing per surface. Plain-language labels (Warmth, not "gamma");
  jargon lives only in ⓘ tooltips, and those stay to **2–3 sentences** — deeper detail goes in the
  README, not the UI.
- **Restraint.** Don't add chrome, a toggle, or a third line when a sensible default will do. The
  popup stays calm; the slider and the schedule curve are the heroes. Reuse existing components
  (card layout, `MonitorSlider`, slider/stepper rows) instead of inventing one-offs, and keep
  sibling controls visually consistent (e.g. the Warmth card matches the display cards).
- **Reversible & safe.** Anything temporary or hardware-touching (a live preview, a gamma
  override) must read as temporary, be trivially undoable, and never silently persist — e.g. the
  schedule preview resets when the settings window reloads. Never leave the screen in a surprising
  state.
- **Native feel.** Prefer real system affordances (the `OSDManager` bezel, an `NSWindow` shade)
  over hand-rolled look-alikes; honor light/dark and accessibility; animations are spring-based and
  quick (like the card reorder).
- **Show, don't tell.** A visible cue (the "now" line on the curve, the warm/cool tint) beats a
  paragraph. When you must explain, use the fewest words that work.

When a change is UI, hold it to this bar — and screenshot it before calling it done.

## Verifying UI changes (hard-won)

- **A passing smoke test does NOT mean the UI renders.** `smoke_test.sh` only checks window
  *geometry* (on-screen, sane size) via `CGWindowList` — it has twice passed on a window that
  was blank or wrongly sized. Always screenshot the actual window and read it.
- **Screenshot pipeline (this machine is multi-display; plain `screencapture` misses/occludes
  the window):** the main window restores onto the **external** display and the test hooks open
  it non-activating, so capture by window id, not a full-screen crop:
  ```sh
  swift script/_shot_winid.swift              # list MonitorFlux windows: id x y w h layer title
  swift script/_shot_sck.swift <id> out.png   # ScreenCaptureKit capture by id (occlusion-proof)
  ```
  The popup is ≈312 wide; the main window is large/titled. Note: `_shot_sck` renders the OSD's
  `.hudWindow` vibrancy as flat gray (no blur) — judge the OSD with `_shot_crop.swift` over a real
  `screencapture` instead.
- **Launch hooks (env vars), set under `MONITORFLUX_SAFE_MODE=1`:**
  - `MONITORFLUX_OPEN_MAIN=1|reopen|activate` (`activate` opens the window key/active — the only
    way window-scoped shortcuts like ⌘+/⌘−/⌘0 and ⌘⇧D can fire; it steals focus, so verification
    only), `MONITORFLUX_SELECT=general|color|display|diagnostics`
    (or `display:<name substring>`, e.g. `display:AirPlay`, to target a specific display pane),
    `MONITORFLUX_ZOOM_STEP=N` (0…8, in-memory only) to render at a non-default zoom,
    `MONITORFLUX_EXPAND_ADVANCED=1` to open the display pane's Advanced disclosure on launch
  - `MONITORFLUX_OPEN_POPUP=1` opens the menu-bar popup ~1s after launch (it has no public "show"
    API) so it can be captured by id. **Needs an activating launch** — `open -n`, not `-gn`; when
    backgrounded the popup panel never appears. Pair with `MONITORFLUX_FAKE_DISPLAYS=N` for mock
    cards (even index = DDC, odd = non-DDC, index 2 = AirPlay/virtual) to exercise multi-display
    paths on a built-in-only Mac. **Dismiss the popup / `pkill -x MonitorFlux` when done** so it
    doesn't sit over the user's screen.
  - `MONITORFLUX_SHOW_OSD=brightness|color` (+ `MONITORFLUX_OSD_HOLD=1` holds it and forces the
    custom panel, since the native bezel can't be held or captured by id),
    `MONITORFLUX_SHOW_ONBOARDING=1` (+ `MONITORFLUX_ONBOARDING_PAGE=0|1` to open on a specific card).
- To drive a SwiftUI button in a test, use accessibility **`AXPress`** (find it by its `help`
  string — SwiftUI buttons often expose no AX title), not synthetic coordinate clicks (they
  miss). For shortcut recording, `AXPress` the Record button then `keystroke` the combo.
- **Don't spam GUI launches.** Each `open` pops the window onto the user's screen and (for the
  activating path) steals focus. Batch verification into one launch; the main-window test hooks
  use a non-activating window for this reason (the popup and `OPEN_MAIN=activate` hooks are the
  exceptions — they need an activating launch). Reuse a running instance instead of relaunching.

## Before Handing Off

Run:

```sh
swift test
./script/build_and_run.sh --verify
```

If you cannot run either command, say exactly why in the handoff.
