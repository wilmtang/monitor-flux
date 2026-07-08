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
  manual slider and user-initiated custom hotkeys. Follow built-in brightness only *reads* it —
  writing it would put us in a tug-of-war with the ambient sensor, and the follow loop would
  then propagate macOS's counter-moves to every external (a real drift we hit with an earlier
  two-way design).
- **Follow built-in brightness is one-way and offset-based.** Eligible externals track the
  built-in backlight at a per-display offset (`BuiltInBrightnessFollow`): a manual tweak on a
  follower re-anchors its offset, targets map against the built-in's *absolute* level (so a
  clamped follower never ratchets), and a follower without an offset yet is adopted where it
  sits — enabling the mode, reconnecting a display, or toggling it off never moves anything by
  itself, so there is no state to restore. Displays on a brightness schedule are skipped; a
  ~2 s poll picks up macOS's own backlight moves. Linked contrast is a separate, absolute,
  external-DDC-only copy (the built-in has no monitor contrast channel) that likewise skips
  scheduled displays.
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

### Scheduled brightness/contrast behave like warmth

The per-display brightness/contrast schedule (`HardwareScheduleChart` in the display pane's
Advanced section) is the smaller sibling of the warmth curve, and shares its two live behaviors so
the three read as one system:

- **Draggable "now" line → scrub-preview.** Each hardware chart's white marker drags exactly like
  the warmth curve's (same `marker` treatment: faint reference at real now, prominent draggable
  marker at the scrubbed minute). Dragging calls the shared `AppStore.previewScheduleColor`, which
  already drives *both* warmth (gamma) and every display's scheduled brightness/contrast to the
  scrubbed time — so the whole screen previews together, and every chart's marker moves in lockstep
  (they read the one `schedulePreviewMinute`). The hardware charts pass `adoptClockMode: false`:
  scrubbing a brightness/contrast timeline previews the screen but must **not** flip Warmth from
  Off/Fixed into Automatic (only the warmth marker adopts clock mode — editing warmth means you
  want the warmth schedule). The preview is temporary; the display pane clears it on
  appear/disappear, same contract as the Schedule pane.
- **Popup slider re-levels the active phase.** When a display's brightness (resp. contrast)
  schedule is on, dragging its **popup** slider edits the *currently active phase's* target
  (`dayBrightness`/`sunsetBrightness`/`nightBrightness`, a unified position; the contrast trio, a
  DDC percent) and stays on schedule — a real, persisted schedule edit, the exact analogue of the
  popup warmth slider re-warming the live phase via `setTemperature(for: currentPhase)`. Without
  this the popup wrote a manual value the schedule would overwrite at the next phase. The slider
  also *reads* the active phase's anchor (`AppStore.scheduledBrightnessPosition` /
  `scheduledContrastValue`), not the applied value — binding to the applied value would feed back
  on itself as each drag tick re-applies the schedule (the same reason the warmth slider binds to
  `editableTemperature`). Gated by `isBrightnessScheduled`/`isContrastScheduled`, which mirror the
  planner's exclusions (never the macOS-managed built-in backlight; contrast is DDC-only).

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

### Location lookup: city/ZIP search, offline

The raw Latitude/Longitude fields are replaced by one f.lux-style **Location** row
(`Views/LocationField.swift`): it shows the resolved place name ("Seattle, Washington", or the
coordinates when no name is known — `AppPreferences.locationDisplayLabel`) with a Change button;
editing turns it into a single search field with up to 5 inline suggestion rows (no floating
popover — the settings window has enough hosting gotchas). One field parses three shapes:
**city-name prefix**, **5-digit US ZIP**, and **raw `lat, lon`** — the coordinate form is the
escape hatch that let the two raw fields go away. Return accepts the top hit, Esc cancels.
Search state is view-local `@State`; only the final pick writes preferences (`AppStore.applyPlace`,
one `updateGlobalPreferences` setting `latitude`/`longitude`/`locationName` together).

**Resolution is a bundled offline index, not a geocoding service.** The options considered:

- **MapKit** (`MKLocalSearchCompleter` + `MKLocalSearch`): free, no key, but network-required —
  offline you can't change location at all, and it breaks the pane's "Computed on-device"
  promise. `CLGeocoder` is out entirely: deprecated in the 2025 SDKs (macOS 26) in favor of
  `MKGeocodingRequest`, which doesn't exist below macOS 26 — a two-headed availability fork.
- **Third-party HTTP geocoders** (Nominatim, Open-Meteo): nothing over MapKit, plus a ToS,
  rate limits, and a privacy disclosure. Rejected.
- **Bundled index (chosen):** GeoNames `cities15000` (~34k cities worldwide, pop ≥ 15k;
  CC BY 4.0 — attribution in the README) + the US Census ZCTA gazetteer (~34k ZIP centroids,
  public domain). Sunset shifts ~1 min per ~20 km east–west, so a city centroid is solar-grade;
  towns under 15k pop type their nearest city or coordinates.

`script/make_place_index.swift` regenerates the committed `Resources/places.tsv` (like
`make_icon.swift` for the icon). The file is a line-oriented TSV that dictionary-encodes the two
repeated columns — IANA timezone ids (`T` rows) and admin1/state names (`A` rows) — so cities and
ZIPs reference them by index; the whole thing is ~2.3 MB. It ships via the SwiftPM resource
bundle, which `build_and_run.sh` copies into `Contents/Resources` (`PlaceIndex.loadBundled`
deliberately avoids `Bundle.module`, whose generated fallback is an absolute `.build` path that
only resolves on the build machine). `Support/PlaceIndex.swift` is the pure, tested planner —
diacritic-folded word-prefix search ranked by population, ZIP/coordinate classification, and
`nearest(latitude:longitude:)` so a Core Location fix ("Use my location") also gets a city name
(and a timezone) without a reverse-geocode call. The ~2 MB parse runs once off-main
(`AppStore.loadedPlaceIndex`, cached for the session). `SolarCalculator` and
`ColorSchedule.resolved` are untouched; the feature only changes the coordinates the schedule
already consumes. Deferred until real users report misses: a one-shot `MKLocalSearch` "Search
online" row appended under the local suggestions.

**Traveling (timezone changes, stale locations).** Three pieces:

- **A location-source bit.** `locationFollowsDevice: Bool = true` (the default matches the prior
  behavior: once authorized, Core Location re-fixes on every launch). `AppStore.requestLocation`
  ("Use my location") sets it; picking a search result or typing coordinates (`applyPlace`) clears
  it. `applyLocation` returns early unless it's set — without the gate, the every-launch fix would
  silently clobber a manually chosen city.
- **Timezone/clock observers** (in `AppStore.init`). The schedule tick re-reads `Calendar.current`
  every minute, but Foundation caches the system timezone in-process — after a flight the app would
  keep computing in the departure zone. `NSSystemTimeZoneDidChange` →
  `handleSystemTimeZoneChange`: `NSTimeZone.resetSystemTimeZone()`, re-resolve the schedule
  immediately, then follows-device-and-authorized requests a fresh (silent, no prompt) fix while a
  manual city runs the staleness check. `NSSystemClockDidChange` (big clock jumps) re-resolves
  only. DST transitions ride the same path; Set-times anchors are minutes-of-local-clock and need
  nothing. The hint is also evaluated once per launch (catches "launched after landing") and when
  the Schedule pane appears.
- **A staleness hint — never an auto-switch** (`Support/LocationStaleness.swift`). Each city
  carries its IANA timezone (a GeoNames column; ZIPs borrow their nearest city's). When the stored
  place's UTC offset differs from the system zone's by ≥ 1 h (compare offsets *at now*, not zone
  ids — Madrid vs Paris must not warn; offsets also get DST right, e.g. Phoenix/Denver in summer),
  `AppStore.locationMismatch` is set and the Follow-sunset section shows a `WarningCard` — "Your
  Mac's clock is set to Tokyo time, but the sunset schedule follows Seattle" — with a
  Use-my-location button and a dismiss. Dismissal is remembered keyed on the (place, system-zone)
  pair (`dismissedLocationMismatchKey`), so it returns when either side changes. A manual choice is
  never overwritten without the user acting (reversible & safe).

The mismatch predicate is pure (`LocationStaleness.check(placeZoneID:systemZone:now:dismissedKey:)`)
and tested: equal offsets with different ids, the DST asymmetry cases, dismissal re-arming. The
Schedule pane's location states are verifiable offline via the `MONITORFLUX_LOCATION_DEMO=<query>`
(pins a searched place — `tokyo` trips the hint on a Pacific-time Mac) and
`MONITORFLUX_LOCATION_QUERY=<prefix>` (opens the row mid-search) launch hooks.

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

## On-screen display (OSD) bezel

Brightness and volume use the **native macOS bezel** through the private `OSDManager`
(OSD.framework), so they're pixel-identical to what macOS itself draws. Contrast and warmth have
no native bezel image (macOS's contrast code draws the level bar with no glyph, and there's no
color-temperature bezel at all), so they use a **custom SwiftUI panel** in the same 200×200 spot —
also the fallback if the private API is ever unavailable.

**Covering, not flushing (the blink).** The native bezel and the custom panel occupy the exact
same screen position, and the native bezel is a window at level ~2005 (owned by `OSDUIHelper`), so
a native brightness/volume bezel still fading would sit *over* a contrast/warmth panel triggered
right after — hiding it. Two approaches were tried:

- **Dismiss the native bezel** via the private `-[OSDManager fadeClassicImageOnDisplay:]`. This
  works when the bezel is at full opacity, but on a bezel that's **already mid-fade it re-brightens
  it to full first**, then fades again — a visible blink. This was verified with a controlled
  frame-by-frame screen recording: same setup (show a bezel, let it start fading), differing only
  in whether the call fires ~150 ms into the fade. Without it, the bezel fades to nothing; with it,
  the bezel jumps back to full and restarts its fade. `OSDManager` is a private, **undocumented**
  API, so this is empirical, not a guarantee — but it's reproducible.
- **Cover it (chosen).** The custom panel's window level is set to `CGShieldingWindowLevel() - 1`
  — above the native bezel so a lingering one is covered and simply fades out underneath, but
  below the lock-screen shield so, like the native bezel, the OSD never floats over the login
  window. No call touches the native bezel, so there's nothing to blink; a recording confirms the
  custom OSD cleanly covers a still-visible native bezel with no ghost. Anchoring to
  `CGShieldingWindowLevel()` (not a hard-coded 2005) survives the native level shifting between
  macOS versions — worst case it degrades to the old "covered" bug, never a crash.

**Per-symbol glyph sizing.** The custom panel's glyph point size is tuned per symbol
(`Kind.glyphPointSize`), not fixed: SF Symbols fill their box very differently, so at one size the
solid contrast disc and the filled `thermometer.sun.fill` look much larger than `sun.max`'s airy
outline (measured against the native bezel at the same scale: sun ~110 pt, contrast disc ~105 pt
but solid, warmth ~127 pt). The filled glyphs are sized down (contrast 82, warmth 76) to read at
the sun's visual weight.

## ⌘-Tab switcher promotion when the Dock icon appears

The settings window is an on-demand `NSWindow`, and the app only becomes a Dock app (`.regular`)
while that window is open and "Show in Dock" is on (see the Dock-policy prose in `AGENTS.md`).
Getting the ⌘-Tab switcher to list the app *correctly* the instant it gains a Dock icon has been
the single most-regressed corner of the app. This section is the reference for why, so it stops
being rediscovered from scratch.

### Three orthogonal concepts (don't conflate them)

The bug lives in the gap between three things that all sound alike but are not:

- **Activation *policy*** — `NSApplication.ActivationPolicy`, `.regular` / `.accessory`. App-wide.
  Set with `NSApp.setActivationPolicy(_:)` in `AppStore.refreshActivationPolicy()`. `.regular` =
  Dock icon + a slot in the ⌘-Tab switcher; `.accessory` = menu-bar-only, invisible to ⌘-Tab.
- **Window *level*** — `NSWindow.Level`, `.normal` / `.floating`. Per-window z-order. Set with
  `window.level = .floating` in `holdWindowFrontAcrossActivationDip`, reset in
  `endDockTransitionSmoothing`. This is only ever used as a *mask* (see Solution B); it has nothing
  to do with the switcher directly.
- **Active** — `NSApp.isActive`. Whether the app is the frontmost/focused app (owns the menu bar,
  receives key events). Not a property you assign — it flips when the app is activated
  (`NSApp.activate`) or deactivated, and is reported by `didBecomeActive` / `didResignActive`.

Nothing visible on screen distinguishes "the app just became active" from "nothing happened" — no
Dock icon, no window. That invisibility is why this bug is so slippery: the entire failure is a
timing relationship between *active* and the *policy* flip, and none of it can be seen or logged
after the fact.

### How the switcher orders apps

The ⌘-Tab switcher is a most-recently-used (MRU) list of `.regular` apps, maintained by the Dock:

- An app that **launches** as `.regular` is inserted at the **front** of the list by its launch
  activation. (This is the intuition "a new app just gets ⌘-Tab focus.")
- An **already-running `.accessory` app that flips to `.regular`** via `setActivationPolicy` is a
  different animal: the Dock *registers* it and **appends it to the end** of the MRU. It is moved
  to the front only by a subsequent **activation event** (an `.accessory`→active, or resign→become,
  transition) that occurs **while the app is already `.regular`**.

So the rule that governs everything here: **to land at the front of the switcher, the app needs a
genuine activation that happens *after* it is registered as `.regular`.** Registering while
already active — with no fresh activation afterward — parks it at the end. When that happens, the
app is the *active* app yet sits last in the switcher, an inconsistent state where ⌘-Tab-away then
⌘-Tab-back does **not** return to the settings window.

### The two rise paths, and why one keeps breaking

The app enters `.regular` from two places, and they differ in exactly the way that matters:

- **The "Show in Dock" toggle** — clicked *inside the already-open, already-active settings
  window*. The app is active before and after the flip; there is no natural activation event to
  ride, so it *must* synthesize one. It does, via `promoteInAppSwitcher` (Solution B below), and it
  works.
- **Opening the settings window from the popup** — "Settings…" in the menu-bar popup calls
  `showMainWindow`, which activates the app and orders the window front, then flips the policy.

`8c341bd` first fixed the toggle by *always* synthesizing the activation (the Dock bounce) whenever
the policy went `.regular`. But on the window-open path the bounce ran while the window was still
opening, and that **blinked** the opening window. `c4c0447` removed the bounce from the window-open
path to kill the blink, on the stated premise that *"the popup is a nonactivating panel, so
`showMainWindow`'s activate lands after the policy flip and promotes for free."* **That premise is
false** (see Findings): opening the popup activates the app, so by the time "Settings…" runs the
app is already active, the policy flips while active, and — with the bounce now removed — nothing
promotes it. The original bug returned on the popup path while the toggle stayed correct.

### The two solutions, and what they actually mean

Both aim at the same target — a real activation *after* the `.regular` registration — but from
opposite directions.

**Solution A — reorder `showMainWindow`: register, *then* activate.** Today the order is
`activate → makeKeyAndOrderFront → setActivationPolicy(.regular)`: the activation is requested
while the app is still `.accessory`, before it is registered as a Dock app, so the Dock has nothing
to promote. Reorder it to *order the window on screen without activating* → `setActivationPolicy(.regular)`
(registers while still inactive) → **then** `NSApp.activate`. Now the one activation is a clean
inactive→active transition of an app that is *already* registered as regular — exactly the event
the Dock promotes to the front. **What it really means:** don't synthesize anything; make the
window's own natural opening-activation *be* the promoting event, by making sure it fires after
registration instead of before. No resign, no bounce, so structurally **nothing can blink**.
*Hypothesised precondition:* the app must be **inactive** when the policy flips, else step 3's
activate is a no-op on an already-active app. **This worry turned out not to bind** — see Findings:
the reorder fixes the active-at-entry case too, because the decisive part is that the activate is
*issued after* the `.regular` registration, not the app's activeness at the flip.

**Solution B — masked bounce: synthesize the activation and hide it.** Keep the app active, flip to
`.regular`, then deliberately hand activation to the windowless Dock (`dock.activate`) so the app
*resigns* and immediately takes it back — a real resign→become-active round trip, which is the
activation event the switcher promotes on. The resign would briefly show the desktop (the "blink"),
so the settings window is pinned at `.floating` across the sub-second dip
(`holdWindowFrontAcrossActivationDip`) — nothing on screen moves. **What it really means:** the
activation the switcher needs doesn't exist naturally (the app never resigned), so manufacture one
and cover it. This is what the toggle path already does. To use it on the window-open path without
the `c4c0447` blink, the bounce must be **deferred until the window has fully opened and taken
key** — a settled, floating-pinned window masks the dip; a still-opening one does not. Works
regardless of whether the app is active at entry, at the cost of more moving parts.

The relationship: **A avoids the problem, B covers it up.** A is preferable when its precondition
holds; B is the fallback that always works.

### Why this is genuinely hard to verify

The switcher's MRU order is undocumented Dock state. It is **not exposed by any API**, does not
appear in logs, and synthetic ⌘-Tab key events (`CGEventPost`) are dropped by the switcher. So the
only ground-truth check is a **human (or HID-level automation) pressing ⌘-Tab and looking.** Both
prior fixes shipped validated by *reasoning* about Dock behavior rather than observation — and one
of those chains of reasoning rested on the false "nonactivating popup" premise. Do not trust a fix
here that hasn't been exercised with a real click and a real ⌘-Tab.

### Findings (2026-07-07, verified with a real ⌘-Tab)

Measured on macOS 15.7 with an instrumented build. The switcher's MRU can't be read from
logs, so the check was **behavioral**: open the settings window, activate a decoy app
(TextEdit), activate Finder, press one real ⌘-Tab (driven at HID level), and read the
resulting frontmost app with `lsappinfo front`. Landing on **MonitorFlux** = promoted
correctly; landing on the **TextEdit** decoy = parked at the end. Every cell below was run
with the same deterministic decoy so a "wrong" result is unambiguous.

- **The popup activates the app.** With the app launched fully in the background, opening the
  menu-bar popup logged `NSApp.isActive == true`. So by the time "Settings…" runs, the app is
  already active and the policy flips while active — falsifying the `c4c0447` "nonactivating
  popup" premise. (A *mouse* click on the icon couldn't be scripted here — the compositor
  hides non-allowlisted apps and blocks clicks onto them — but the programmatic popup open
  goes through the same activation path, and the behavioral result below is conclusive on its
  own.)

- **Both entry states were broken before the fix**, and the reorder fixes both:

  | window opens while… | old order (activate → flip) | Solution A (order → flip → activate) |
  |---|---|---|
  | app **inactive** at entry | ⌘-Tab → TextEdit ✗ | ⌘-Tab → MonitorFlux ✓ |
  | app **active** at entry (popup) | ⌘-Tab → TextEdit ✗ | ⌘-Tab → MonitorFlux ✓ |

  The old-order rows are the control: identical protocol, only the code differs, so the test
  demonstrably distinguishes broken from fixed.

- **Solution A alone is the fix; Solution B was not needed here.** The surprise was that the
  reorder fixes the *active*-at-entry case too, even though the policy still flips while the
  app is active. The decisive element isn't the app's activeness at the flip — it's that
  Solution A issues an `NSApp.activate` **after** the `.regular` registration (the old order's
  only activation happened *before* it, inside `showMainWindow`'s window-ordering). That
  post-registration activate is what the Dock promotes on, active or not. So the
  precondition worry in "The two solutions" above turned out not to bite: no bounce, no blink,
  both paths fixed. The Show-in-Dock **toggle** path still uses Solution B
  (`promoteInAppSwitcher`) — it has no window-opening activation to reorder, so it must
  synthesize one — and was left unchanged.

- **The shipped change** (see `AppStore.showMainWindow` + `WindowCoordinator.activateMainWindow`):
  order the window on screen without activating → `refreshActivationPolicy()` → `activateMainWindow()`.

## The menu-bar popup can't resize while open (the no-externals hint gap)

When only the built-in panel is present, `QuickControlsView` shows a dismissible **"No external
monitors detected"** card. Clicking its ✕ **fades the card out in place but keeps the space it
held** until the popup closes; the next open lays out compact (`hintFadingOut` +
`hideNoExternalsHint`). That transient blank space looks like a bug, and the "obvious fix" —
shrink the live popup on dismiss — flickers. This is the reference for why, so the tradeoff isn't
relitigated from scratch.

### What the popup actually is

`MenuBarExtra { QuickControlsView() }.menuBarExtraStyle(.window)` (in `MonitorFluxApp`) is backed
at runtime by — verified by dumping the live window's class chain —

```
SwiftUI.MenuBarExtraWindow<AnyView>  →  NSPanel  →  NSWindow  →  NSResponder  →  NSObject
```

a **private SwiftUI subclass of `NSPanel`** (`.nonactivatingPanel`, level 101 — the nonactivating
style is why opening the popup doesn't steal key focus), whose content is hosted by an
**`NSHostingController`**. Two facts follow, and both matter below: SwiftUI *creates, sizes, and
positions* this window itself — we get no handle beyond the `view.window` captured in
`PopupWindowAccessor` — and the hosting controller's default auto-sizing is a **standing binding:
SwiftUI content ideal-size → window size**. Change the content height and SwiftUI resizes the
window for you, on its own schedule.

### Why resizing flickers: a top-pinned window in a bottom-left coordinate space

Every `NSWindow` is positioned by its **bottom-left `origin`**, in a screen space where **y
increases upward** (this is universal AppKit, not specific to the dropdown). The top edge is a
*derived* value, never stored:

```
top = origin.y + height     ← for a menu-bar dropdown this must stay pinned under the status item
```

So shrinking the content by Δ while keeping the top still requires changing **two** things
together:

```
height   → height − Δ
origin.y → origin.y + Δ      (raise the bottom so the top doesn't move)
```

A normal app window has no such constraint — it keeps its bottom-left fixed and lets the top move,
so a resize is one clean operation nobody notices. A dropdown needs the *opposite* (hold the top,
move the bottom), and AppKit has no "resize from the top" primitive, so it takes two operations to
fake it — and they land on **different frames**:

- the **resize** is `NSHostingController` reacting to the now-smaller content, and
- the **reposition** is `MenuBarExtraWindow` re-anchoring under the status item on the next
  runloop tick.

For the one frame in between, the window has the new (smaller) `height` but the old `origin.y`, so
`top = origin.y + (height − Δ)` — the top **dips down** — then the next frame the origin corrects
and it snaps back up.

### Instant vs. animated — same cause, different exposure

Measured with 60 fps screen recordings of the dismissal:

- **Instant collapse** (drop the card, no animation): the height changes once → the one-frame
  mismatch happens **once** → a single ~16 ms downward flick. Near-imperceptible, but present.
- **Animated collapse** (fade + shrink over ~0.3 s): the height changes on *every* animation frame
  → the reposition lag is present on *every* one → a **sustained ~0.2 s bounce** as the anchor
  chases the shrinking content. The animation doesn't cause the wobble; it amplifies the
  single-frame lag into something you plainly see.

### Why a manual atomic fix is hard (not impossible)

`NSWindow.setFrame(_:display:animate: false)` *does* set origin+size atomically, so in principle
one hand-driven call is glitch-free. But **we don't drive the resize** — SwiftUI does, via the
hosting controller's standing content-size→window-size binding. Calling `setFrame` ourselves just
adds a **second writer**: SwiftUI's non-atomic path still fires on the content change and its next
layout pass can stomp our frame. To make our call authoritative we'd first have to **sever that
binding** — clear the hosting controller's `sizingOptions` — on a controller SwiftUI owns
privately for the panel (no public handle; we'd be runtime-walking to reach it), and then own
*all* popup sizing by hand forever. `sizingOptions` is also the exact knob that blanks the main
window if touched (see the window-sizing gotcha in `AGENTS.md`). Fragile, for a one-frame cosmetic
win. And `MenuBarExtra` exposes no sizing/resizability/anchor modifier of its own — unlike
`WindowGroup`, there's no supported seam to ask for an atomic top-anchored resize.

### The shipped choice

Sidestep it entirely: **never change the window height while the popup is open.** `hintFadingOut`
fades the dismissed card out but holds its space until the popup closes; the persisted
`hideNoExternalsHint` then drops it from the layout so the *next* open is compact. No resize → no
reposition → no flicker. The only visible cost is the transient gap for the rest of that one
session.

Two experiment branches implement the alternatives, for anyone who wants to feel the tradeoff on
their own hardware: `popup-hint-collapse-instant` (the ~16 ms flick) and
`popup-hint-collapse-animated` (the visible bounce).

## Known limitations (cosmetic, no action planned)

- `MonitorSlider` maps the pointer across the full track width while the knob travels an inset
  range, so values jump slightly at the extreme ends (matches MonitorControl's feel).
- The OSD panel sits below the AirPlay shade window level, so the bezel looks dimmed on a shaded
  display.
- Arm64 DDC writes retry 5× with 20 ms sleeps on a shared serial queue, so a dead monitor adds
  ~100 ms latency to other displays' writes.
- **No DDC read-back.** An external display's brightness/contrast slider positions are the
  *stored preferences*, not values read from the monitor — MonitorFlux only ever writes DDC/CI,
  never queries it. So a change made with the monitor's own buttons doesn't move our sliders, and
  `restoreHardwareSettings` re-asserts the saved value over it on the next launch/hotplug. (Lunar
  and MonitorControl read VCP values back; MonitorFlux deliberately doesn't, to keep the DDC path
  write-only and avoid the extra bus traffic and per-monitor quirks of reads.)

## Prior art

Apps studied while building MonitorFlux:

- [Lunar](https://github.com/alin23/lunar)
- [MonitorControl](https://github.com/MonitorControl/MonitorControl) — same IOAVService DDC approach
- [macos-dimly](https://github.com/punshnut/macos-dimly)
- [BrightIntosh](https://github.com/niklasr22/BrightIntosh)
