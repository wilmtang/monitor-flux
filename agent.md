# Agent Guide

This repo is a SwiftPM macOS app. Treat display control as a high-risk surface:
small mistakes can flicker monitors, leave gamma tables altered, or send bad DDC
commands to hardware.

## Commands

- Build and run the app bundle: `./script/build_and_run.sh`
- Verify launch: `./script/build_and_run.sh --verify`
- Run tests: `swift test`
- Smoke-test the detailed window opens (not blank / not duplicated): `./script/smoke_test.sh`

Stop the running dev app before doing risky gamma work:

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
  in the window's "General" pane so they're reachable without an app menu.
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
- The media-key tap (`KeyboardControlService`) needs Accessibility permission; ad-hoc
  dev builds re-prompt after each rebuild because the code signature changes.
- New behavior should get focused tests unless it directly touches real display
  hardware. The arm64 DDC packet builder and `SolarCalculator` are pure and tested.

## Before Handing Off

Run:

```sh
swift test
./script/build_and_run.sh --verify
```

If you cannot run either command, say exactly why in the handoff.
