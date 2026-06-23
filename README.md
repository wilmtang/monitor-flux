# MonitorFlux

MonitorFlux is a macOS display-control app that combines f.lux-style color
temperature scheduling with MonitorControl-style per-display controls.

The important design rule is that MonitorFlux owns exactly one gamma pipeline.
Warmth, gamma brightness, and gamma contrast are composed into one transfer
table per display, so those features do not overwrite each other or flicker by
fighting for the same macOS gamma table.

## How It Works

MonitorFlux has two separate control paths:

- **Gamma path:** color temperature, software brightness, and software contrast.
  These are pixel-level adjustments. They are planned in `GammaPlan`, composed
  in `GammaCompositor`, and applied by `GammaTemperatureService`.
- **Hardware DDC path:** brightness and contrast commands sent to external
  monitor firmware. These use native macOS IOKit I2C/DDC APIs first, with
  `ddcctl` only as an optional fallback if it already exists on the machine.

Gamma can be disabled globally. When disabled, MonitorFlux restores system color
tables and stops writing gamma. Hardware DDC controls can still be used.

## UI

- The **menu bar popup** (`QuickControlsView`, `.menuBarExtraStyle(.window)`) is
  modeled after MonitorControl: a card per display with live brightness, contrast,
  and volume sliders (a custom `MonitorSlider` — rounded track, icon-in-track, no
  tick marks), plus a global ambience (color-temperature) slider and an
  Off/Manual/Schedule mode. DDC writes are debounced so dragging doesn't flood the
  I2C bus. The Settings/Quit rows highlight on hover and show their shortcuts. The
  app is menu-bar-first (no Dock icon by default; a "Show in Dock" setting toggles it).
- The **Schedule** screen is modeled after f.lux preferences: three phase
  temperatures (Daytime / Sunset / Bedtime) over the same Kelvin range, a phase
  selector, a draggable three-handle schedule curve, wake/bedtime controls, and a
  **Manual times / Sunrise & sunset** source. In solar mode the daytime and sunset
  anchors come from your location (CoreLocation + `SolarCalculator`).
- Each **Display** screen separates:
  - Warm color enablement for that display.
  - Gamma brightness/contrast for pixel-level control.
  - Hardware DDC brightness/contrast for external monitor firmware control.

## Keyboard control

When enabled (Settings ▸ Keyboard), MonitorFlux taps the keyboard's brightness and
volume media keys and routes them to the external display **under your pointer** over
DDC — so the same keys that dim the built-in panel now drive whichever monitor you're
pointing at. Hold **Control** to dim the **built-in panel's real backlight** instead
(via the private DisplayServices framework — `NativeBrightnessBackend`; falls back to
gamma if unavailable). This needs Accessibility permission (System Settings ▸ Privacy &
Security ▸ Accessibility), since swallowing HID key events is privileged. Implemented
with a `CGEventTap` in `KeyboardControlService`. The built-in display's brightness
slider in the popup and detail window also drives the real backlight.

## Avoiding color conflicts

Gamma is a single, shared resource. macOS **Night Shift** and apps like **f.lux** also
rewrite the gamma tables, so running them alongside MonitorFlux makes the two fight —
colors flicker or look wrong. MonitorFlux shows a warning on the Schedule screen with a
shortcut to Display settings; disable Night Shift and quit other color tools for correct
results. Every MonitorFlux gamma write still flows through the single
`GammaTemperatureService`, and ⓘ buttons in the UI explain gamma vs DDC for newcomers.

## Safety Rules

- Do not add another independent gamma writer. All gamma-affecting features must
  flow through `GammaPlan` and `GammaCompositor`.
- Do not repeatedly write identical gamma tables. `GammaTemperatureService`
  tracks the last applied adjustment per display and skips unchanged writes to
  avoid flicker.
- Do not fake hardware brightness with gamma unless the UI clearly labels it as
  gamma brightness.
- Do not require Homebrew tools. Native DDC is the primary implementation.
- Keep preference values normalized with `ControlRanges` before saving or using
  them.

## DDC Caveats

DDC/CI support depends on the monitor, cable, dock, GPU path, and what macOS
exposes through IOKit. Built-in displays do not use DDC. The native path is
architecture-specific: **Apple Silicon** uses the private `IOAVService`
(`Arm64DDCBackend`, the same approach as MonitorControl/Lunar), while **Intel**
uses the IOFramebuffer I2C path (`NativeDDCBackend`). `ddcctl` is an optional
Intel-only fallback; when the native path fails and `ddcctl` is present,
MonitorFlux tries it and reports both errors if both backends fail. DDC over a
Mac's built-in HDMI port is generally unsupported — use USB-C/DisplayPort.

`IOAVService` is a private API. That's fine for a personal app but is not
App-Store-safe; it's isolated in `Arm64DDCBackend` behind the same error-reporting
fallback as the rest of the DDC stack.

## Run

```sh
./script/build_and_run.sh
```

Useful variants:

```sh
./script/build_and_run.sh --safe       # drive the UI but write no gamma/DDC/backlight
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

**Safe mode** (`--safe`, also used by `--verify` and `smoke_test.sh`, via
`MONITORFLUX_SAFE_MODE=1`) runs the full app without any gamma/DDC/backlight writes, so
testing doesn't flicker your screen or conflict with f.lux/MonitorControl. Use the plain
`run` (no flag) when you actually want MonitorFlux to control your displays. See
[docs/SAFE_MODE.md](docs/SAFE_MODE.md) for the full breakdown of what it disables.

## Package a .dmg

```sh
./script/make_dmg.sh      # -> dist/MonitorFlux-<version>.dmg
```

Builds an optimized release bundle and a compressed disk image with a drag-to-Applications
layout. The app is ad-hoc signed, so the first launch needs a right-click ▸ Open to clear
Gatekeeper; double-click-to-open requires a Developer ID signature + notarization (paid
Apple Developer account).

## Test

```sh
swift test
```

The tests cover schedule math, gamma composition, gamma planning, DDC packet
construction, and preference migration/normalization.

For UI/integration regressions that unit tests can't catch (the window not opening,
opening blank, opening duplicates, or opening off-screen), there's a launch smoke test:

```sh
./script/smoke_test.sh
```

It builds the app and runs two scenarios: `MONITORFLUX_OPEN_MAIN=1` (open the detailed
window once) and `MONITORFLUX_OPEN_MAIN=reopen` (open, close, then reopen — what users hit
by clicking Settings again after closing). For each it asserts via `CGWindowList` that
exactly one sizable window is on screen **and substantially within a display** — the
containment check is what catches a reopened window that orders front off-screen or
oversized. For deeper assertions ("a Brightness slider exists and dragging it changes
state"), the right tool is **XCUITest** (Apple's accessibility-driven UI test framework) —
it needs an Xcode app target + UI-test target, which a pure SwiftPM package doesn't provide.

## Acknowledgements

MonitorFlux's Apple Silicon DDC, built-in backlight, and media-key handling were
developed by studying [MonitorControl](https://github.com/MonitorControl/MonitorControl)
(MIT). See [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md) for details and the full license.
