# MonitorFlux design notes

How the non-obvious parts of the app work today, and why they're built that way. This is the
reference to read before changing warmth, dimming, the schedule, or the settings-window zoom —
it captures decisions that the code alone doesn't explain. (Historical, feature-by-feature
implementation plans live in git history; this is the distilled, current-state version.)

## Core invariants

These hold across every feature below. Breaking one is a bug, not a trade-off.

- **Single gamma writer.** All color-table writes go through `GammaPlan` →
  `GammaTemperatureService` (and DDC through the `DDCWriteScheduler` throttle). The gamma table
  is a shared, system-wide resource; two writers fight (that's why only one of MonitorFlux /
  Night Shift / f.lux should drive it). The quit-path restore is gated on "this session
  actually wrote gamma" (`didStartSession`) so running as a pure DDC controller never stomps
  another color app's tables.
- **Never fully black from the everyday controls.** The unified Brightness slider and the bare
  media keys bottom out at a readable floor (gamma 15%, AirPlay shade 85% cap). Full black is
  only reachable via the per-display Advanced **Allow dimming to black** opt-in.
- **The built-in backlight is never driven by the schedule or bare media keys.** macOS already
  manages it (auto-brightness / ambient sensor); MonitorFlux only touches it through the
  manual slider and user-initiated custom hotkeys.
- **Software dimming is independent of warmth.** Dimming the image (gamma brightness) is plain
  dimming, not a color change, so it keeps working when warmth is Off. Warmth's mode gates only
  the color temperature.

## Warmth and the color schedule

### One control: the mode

Warmth on/off/mode is a single preference, `colorMode`, with three cases — there is **no**
separate master switch:

| Mode (UI) | `colorMode` | Applied temperature |
|---|---|---|
| **Off** | `.off` | none (`targetTemperature` → nil) |
| **Fixed** | `.manual` | a constant `manualTemperature` |
| **Automatic** | `.clock` | the scheduled temperature for the current time |

`.off` is the single "no warmth" state. (An earlier `gammaEnabled` master flag sat on top of
the mode and could disagree with it — two ways to be off. It was removed; old payloads that
stored `gammaEnabled: false` migrate to `.off` on load.) Editing a warmth value from Off or
Fixed adopts the appropriate mode: dragging the popup/Schedule slider pins Fixed; dragging the
curve or scrubbing the time line adopts Automatic. This "editing a control adopts it" rule is
why the slider is always live.

### The day & night schedule

The schedule is three phases — **Daytime / Sunset / Bedtime** — each with a stored warmth, plus
a **Fade** that eases between them (the value at a minute is the most-recently-begun phase's
value, fading from the previous over the Fade window, capped to the gap between events).

The phase **times** come from one of two sources:

- **Set times** — the three stored anchors (wake, sunset, bedtime), edited directly.
- **Follow sunset** — the f.lux model (below): times derive from location + wake.

The **Day & night schedule** section (the times, source, and Fade) is shown in **every** mode,
not just Automatic. The same timeline drives warmth (when Automatic) *and* each monitor's
scheduled brightness/contrast, which are independent channels — hiding the times when warmth is
Off or Fixed would strand a scheduled brightness on times the user can't see. Only the warmth
*curve* (phase picker, chart, legend) is Automatic-only; the shared timeline is always editable,
and editing it must not change warmth's mode.

### Follow sunset (the f.lux model)

Two inputs — **location** and **wake time** — derive everything; the 9-hour bedtime rule and
the winter-morning behavior that f.lux hardcodes become adjustable settings with f.lux's values
as defaults.

| Boundary | Rule |
|---|---|
| Daytime begins | at **sunrise** (or at wake, per the Mornings setting) |
| Sunset phase begins | at **actual sunset** |
| Bedtime begins | **`bedtimeLeadMinutes` before wake** (default 540 = ~8 h sleep + 1 h wind-down) |
| Bedtime ends | at wake; the screen only returns to *daytime* at sunrise |

The engine resolves a per-day ordered list of `(minute, phase)` events (`ResolvedSchedule` /
`ColorSchedule.resolved`), generalizing the three-anchor model so a derived bedtime and a
4-event day (the pre-dawn bridge) are expressible. Set-times mode is just the three stored
anchors as events, so it's bit-identical to before. Edge cases the rules handle:

- **Winter mornings** (Mornings = At sunrise): wake 7:00 but sunrise 7:57 → at 7:00 the screen
  steps up to *sunset* warmth (a pre-dawn "bridge" event), reaching full daylight at sunrise.
  Mornings = At wake time skips the bridge and goes to daytime at wake.
- **Summer squeeze:** an early wake can push bedtime before the real sunset; bedtime wins over
  the sun (circadian-first), so that day has no evening sunset phase. The sunset dot still
  floats at its warmth (dimmed) so it's tunable for the seasons where it applies.
- **Polar / bad coordinates:** solar times come back nil → fall back to the stored Set-times
  anchors.

In Follow-sunset the chart's three dots are **vertical-only** (warmth); the times come from the
sun and wake, so horizontal drags are ignored and the Sunset/Bedtime steppers are disabled
(dimmed, hue retained). Only **Wake** is a live time control; stepping it drags Bedtime along.
Switching Follow-sunset → Set times freezes today's derived sunset and bedtime into the stored
anchors so the chart doesn't jump.

## Dimming: Hardware / Software / Automatic

MonitorFlux presents **one Brightness slider** per display whose position is *perceived*
brightness on a single unified scale, hiding the DDC-vs-gamma split. `brightnessControlKind`
resolves how a display dims: `.hybrid`, `.hardwareOnly`, `.softwareOnly`, `.unavailable`
(no DDC, no gamma path), or `.shade` (AirPlay/virtual — overlay only).

### The unified slider and the handoff

In **Automatic** (hybrid) mode the track has two zones split by a fixed notch at 25%
(`HybridBrightness.handoffFraction`):

```
0%                    notch=25%                                          100%
├── software zone ──────┼──────────────── hardware zone ──────────────────┤
│ gamma floor…100%      │ DDC 0…100 (or backlight 0…100 on the built-in)  │
```

- **Hardware zone** (notch → right): maps to DDC 0–100 — the everyday range.
- **Software zone** (left → notch): entered by dragging past DDC 0; maps gamma 100% → the floor
  (15%, or 0 with **Allow dimming to black**). On AirPlay this is the shade's 0–85% opacity.
- **Invariant:** gamma only dims once hardware is at its floor. Lowering writes DDC 0 first,
  then eases gamma; raising restores gamma to 100 first, then lifts DDC. A mixed state made from
  Advanced (e.g. DDC 50 + gamma 80) shows the *software* position and self-heals on the first
  upward drag. The mapping is a pure `Support/HybridBrightness.swift` with round-trip tests.
- **Show-don't-tell feedback:** below the notch the slider fill dims and the icon swaps
  `sun.max` → `moon` — "the image is being darkened now, not the backlight". The native OSD
  bezel keeps stepping across the whole unified range.

`DimmingMode` (`.automatic` / `.hardware` / `.software`) is stored optional; `nil` resolves per
display kind (externals → `.automatic`, built-in → `.hardware`). **Monitor hardware** is DDC
only and *clears* software dimming (no invisible mixed states); **Software dimming** drives gamma
only. Media keys and scheduled brightness walk the same unified scale (a night target below the
notch keeps dimming in software instead of clamping at DDC 0).

### The built-in is binary, never hybrid

Some eyes are sensitive to low backlight levels — many panels dim the backlight with PWM and
the flicker worsens as it drops. So the built-in gets no hybrid notch; the Advanced **Use
software dimming** toggle flips between two whole-slider behaviors:

- **Off (default)** ↔ `.hardware`: the slider is 100% the real backlight, like macOS's own
  control (and clears any software dimming).
- **On** ↔ `.software`: the slider is 100% software gamma (floored), and the backlight is left
  where it is — the keyboard brightness keys still reach it, so backlight and image dim
  independently.

`brightnessControlKind` therefore never returns `.hybrid` for the built-in. On load,
`reconcileBuiltInDimming` normalizes legacy `.automatic` (from the retired per-display
`gammaControlsEnabled` opt-in) back to `.hardware` and clears any stale sub-100 gamma, so an
upgraded laptop can't come up dimmed with no slider recourse.

## Settings-window zoom: semantic, not geometric

The settings window scales by **font**, not by a geometric transform. `fontSizeStep` (0…8) maps
to `settingsZoomScale`; a root `.font`, a `zoomFont` sweep over fixed text styles
(`Support/ZoomFont.swift`), stepped `.controlSize`, scaled split-view column widths, and
explicit sidebar row/header fonts (the sidebar ignores the environment font) do the work.

**Why not a real zoom:** macOS has no view-level transform, and every geometric mechanism
(NSView bounds scaling, `NSScrollView.magnification`, CALayer transforms, SwiftUI `.scaleEffect`)
desyncs click routing for SwiftUI hosted in a large `NSHostingView` — SwiftUI routes events with
its own window-geometry tracking that's blind to ancestor bounds scaling, so clicks land nowhere
(or on the wrong control). This was measured across five mechanisms against pixel ground truth in
[`prototype-zoom-matrix/`](../prototype-zoom-matrix/); only semantic scaling passes every click
probe at every zoom. General law: any mechanism that makes visual geometry differ from AppKit
view-frame geometry across an `NSHostingView` boundary will desync something. `dynamicTypeSize`
is inert on current macOS and is not used.

## Known limitations (cosmetic, no action planned)

- `MonitorSlider` maps the pointer across the full track width while the knob travels an inset
  range, so values jump slightly at the extreme ends (matches MonitorControl's feel).
- The OSD panel sits below the AirPlay shade window level, so the bezel looks dimmed on a shaded
  display.
- Arm64 DDC writes retry 5× with 20 ms sleeps on a shared serial queue, so a dead monitor adds
  ~100 ms latency to other displays' writes.

## Prior art

Apps studied while building MonitorFlux:

- [Lunar](https://github.com/alin23/lunar)
- [MonitorControl](https://github.com/MonitorControl/MonitorControl) — same IOAVService DDC approach
- [macos-dimly](https://github.com/punshnut/macos-dimly)
- [BrightIntosh](https://github.com/niklasr22/BrightIntosh)
