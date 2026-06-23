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
  panes scroll internally (`ColorScheduleView` is a `ScrollView`).
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
  `LocationService` and debounces live DDC slider writes.
- `Services/GammaPlan.swift`: pure gamma intent planning.
- `Support/GammaCompositor.swift`: pure math for warmth + brightness + contrast.
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
- `Views/Components.swift`: shared `MonitorSlider` (MonitorControl-style, no tick
  marks), `InfoButton` (jargon explainers), and `GammaConflictBanner`.
- `Views/`: SwiftUI window, the `QuickControlsView` menu-bar popup, settings, and
  per-display controls.
- `script/make_icon.swift`: regenerates `Assets/AppIcon.icns` from code.
- `Tests/`: pure behavior tests; avoid tests that write real gamma or DDC.

## Engineering Rules

- Route every gamma-affecting feature through `GammaPlan` and
  `GammaCompositor`. Never add a second gamma writer.
- `GammaTemperatureService` must avoid repeated identical writes. Repeated gamma
  writes can cause visible flicker.
- Normalize preferences with `ControlRanges` before saving or using values.
- Keep hardware DDC separate from gamma controls in naming, state, and UI.
- Do not make Homebrew tools required. `ddcctl` is fallback only, and it is
  Intel-only — on Apple Silicon `Arm64DDCBackend` (IOAVService) is the real path.
- The menu bar popup is `QuickControlsView` with `.menuBarExtraStyle(.window)` and
  live sliders (MonitorControl-style). Debounce DDC writes from continuous drags
  (see `AppStore.scheduleDDCApply`) so a drag doesn't flood the I2C bus.
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
  fallback). External-display brightness/contrast always go through DDC.
- Saved DDC brightness/contrast is re-applied to **external** displays on launch/reconnect
  (`restoreHardwareSettings`); never re-apply to the built-in.
- New behavior should get focused tests unless it directly touches real display
  hardware. The arm64 DDC packet builder and `SolarCalculator` are pure and tested.

## Verifying UI changes (hard-won)

- **A passing smoke test does NOT mean the UI renders.** `smoke_test.sh` only checks window
  *geometry* (on-screen, sane size) via `CGWindowList` — it has twice passed on a window that
  was blank or wrongly sized. Always screenshot the actual window:
  `screencapture -l<windowID> -o -x out.png` (get the id from `CGWindowListCopyWindowInfo`),
  then read it. Test hooks: `MONITORFLUX_OPEN_MAIN=1|reopen`, `MONITORFLUX_SELECT=general|color|display`.
- To drive a SwiftUI button in a test, use accessibility **`AXPress`** (find it by its `help`
  string — SwiftUI buttons often expose no AX title), not synthetic coordinate clicks (they
  miss). For shortcut recording, `AXPress` the Record button then `keystroke` the combo.
- **Don't spam GUI launches.** Each `open` pops the window onto the user's screen and (for the
  activating path) steals focus. Batch verification into one launch; the smoke/test hooks use a
  non-activating window for this reason. Reuse a running instance instead of relaunching.

## Before Handing Off

Run:

```sh
swift test
./script/build_and_run.sh --verify
```

If you cannot run either command, say exactly why in the handoff.
