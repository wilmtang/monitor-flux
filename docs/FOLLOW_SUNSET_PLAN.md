# Follow Sunset, the f.lux way

Status: **implemented 2026-07-04** (engine: `ResolvedSchedule` + `ColorSchedule.resolved`;
UI: `ColorScheduleView` / `FluxCurveEditor`; tests: `ColorScheduleTests` §Follow-sunset).
Decision date: 2026-07-03. Supersedes the "solar follows only sunset" model from earlier the same day.

Implementation deltas from the plan below:
- In Follow-sunset mode **all three dots are vertical-only** (§4.2 as designed); the wake tick
  shows only when wake ≠ the daytime handle's position (sunrise mornings).
- Found & fixed during verification: a location fix arriving at launch (Core Location
  re-delivers one on every start once authorized) used to force `scheduleSource = .solar`,
  making Set-times impossible to keep across a relaunch. `applyLocation` now updates only
  the coordinates.

## 1. Why

Today's Follow-sunset mode swaps in the computed sunset but keeps wake **and bedtime** as
hand-set times, so the mode that claims to "follow" something still shows three editable
time knobs. Verdict: confusing. New direction, per explicit user decision:

> Copy whatever f.lux does, but give the user more control. Inputs are **location** and
> **wake time**. The 9-hour rule and the morning edge case become settings, with f.lux's
> behavior as the defaults.

"Set times" mode is untouched by this plan.

## 2. How f.lux actually works (verified)

Two inputs — location and "when I wake up" — derive everything:

| Boundary | Rule |
|---|---|
| Daytime begins | at **sunrise** (from location) |
| Sunset phase begins | at **actual sunset** (from location) |
| Bedtime begins | **9 hours before wake** (hardcoded: ~8 h sleep + ~1 h wind-down) |
| Bedtime ends | at wake — but the screen only returns to *daytime* at **sunrise** |

The phase at any moment is a priority check: sun up → Daytime; sun down and inside the
9 h-before-wake window → Bedtime; sun down otherwise → Sunset. Two consequences:

- **Winter mornings (the edge case):** wake 7:00, sunrise 7:57 → at 7:00 the screen steps
  from bedtime warmth up to *sunset* warmth, and only goes full daylight at 7:57. Most
  complained-about f.lux behavior; its devs call it unsolved.
- **Summer squeeze:** wake 5:30 → bedtime 20:30, before the 21:11 sunset. Bedtime wins over
  the sun (circadian-first): the screen enters bedtime warmth in daylight, and there is no
  evening sunset phase that day.

Sources: [macOS quickstart](https://justgetflux.com/news/pages/macquickstart/),
[forum: how do I adjust my bedtime](https://forum.justgetflux.com/topic/7894/how-do-i-adjust-my-bedtime),
[forum: how do I tell f.lux my bedtime](https://forum.justgetflux.com/topic/4185/how-do-i-tell-f-lux-what-my-bedtime-is).

## 3. The model

### Inputs (Follow-sunset mode)

| Input | Default | Control |
|---|---|---|
| Location | 47.6, −122.3 | existing lat/lon fields + "Use my location" |
| Wake time | 7:00 AM | existing Wake stepper (stored in `coolStartMinutes`) |
| **Bedtime starts** | **9 hr before wake** (f.lux) | new menu picker, 4–12 h in 30-min steps |
| **Mornings** | **At sunrise** (f.lux) | new segmented picker: At sunrise / At wake time |
| Phase warmths, Fade | unchanged | existing slider / chart dots / Fade menu |

Sunset and bedtime are **derived, not stored**. `warmStartMinutes` keeps holding the
Set-times bedtime; solar mode ignores it.

### Resolution rules (pure, per day)

```
sunrise, sunset ← SolarCalculator(location, today)        // nil → polar day/night or bad coords
bedtimeStart    ← wake − bedtimeLead                       // mod 24 h
dayStart        ← mornings == .sunrise ? (sunrise ?? wake) : wake

events = [ (dayStart, daytime), (sunset, sunset), (bedtimeStart, bedtime) ]

if mornings == .sunrise AND wake lies strictly inside the arc bedtimeStart → sunrise:
    events += (wake, sunset)         // pre-dawn bridge: awake, sun not yet up

drop any sunset event inside the arc bedtimeStart → dayStart
                                     // bedtime wins over the sun (f.lux circadian-first)

if sunrise/sunset are nil: use the three stored Set-times anchors (today's fallback)
```

The value at minute *m* is the **most recently begun event's** phase value, fading from the
previous event's value over the Fade window (capped to the gap) — exactly today's engine,
generalized from "three fixed anchors" to "a short list of events". Set-times mode *is* the
three stored anchors as events, so its behavior is bit-identical.

### Worked examples (Seattle, wake 7:00, lead 9 h → bedtime 22:00)

| Day | Sun | Mornings | Resulting day |
|---|---|---|---|
| Winter | ↑7:57 ↓16:25 | At sunrise | bedtime 22:00→7:00 · **sunset color 7:00→7:57** · day 7:57→16:25 · sunset 16:25→22:00 (f.lux exact) |
| Winter | ↑7:57 ↓16:25 | At wake time | bedtime 22:00→7:00 · day **7:00**→16:25 · sunset 16:25→22:00 |
| Summer | ↑5:12 ↓21:11 | At sunrise | bedtime 22:00→**5:12** (sun up ends bedtime; no bridge — wake is after sunrise) · day 5:12→21:11 · sunset 21:11→22:00 |
| Summer, wake 5:30 | ↑5:12 ↓21:11 | either | bedtime 20:30→5:12/5:30 · day → **20:30** — evening sunset event dropped; day fades straight into bedtime while the sun is still up |
| Night shift, wake 23:00 | any | either | bedtime 14:00→23:00, rest follows; the most-recent-event rule is total, nothing breaks. f.lux's own advice to night workers is "shift your wake time" |
| Polar / bad coords | nil | either | falls back to the stored Set-times anchors (unchanged from today) |

## 4. UI design

### 4.1 Schedule pane in Follow-sunset mode

```
┌─ Schedule ─────────────────────────────────────────────────────────────────┐
│  ☀  The sun is up — go outside!                 [ Off │ Fixed │ Automatic ] │
│                                                                             │
│  Daytime  ──────────────────────────────────────────●──          6,500 K   │
│                                                                             │
│                       [ Daytime │ Sunset │ Bedtime ]                        │
│         Pick a phase, then drag the slider above to set its warmth.        │
│                                                                             │
│                  Wake 7:00 AM, bedtime 10:00 PM (6,500 K)                   │
│                                                                             │
│  ┌───────────────────────────── chart (§4.2) ──────────────────────────┐   │
│  └──────────────────────────────────────────────────────────────────────┘   │
│  ● Daytime · 6,500 K  ● Sunset · 3,400 K  ● Bedtime · 2,700 K               │
│               Drag the time line to preview · drag a dot to set its warmth  │
│                                                                             │
│  Wake  7:00 AM [▲▼]      Sunset  4:25 PM  [▲▼]     Bedtime  10:00 PM [▲▼]  │
│  ^ blue, editable        ^ orange @ ~55%, stepper   ^ indigo @ ~55%,        │
│                            disabled (gray chrome)     stepper disabled      │
└─────────────────────────────────────────────────────────────────────────────┘
```

- **Wake** is the only live time control. Stepping it visibly drags **Bedtime** along
  (always wake − lead) and, with Mornings = At wake time, the day start too.
- **Sunset** and **Bedtime** keep their row, glyph and *hue* — orange and indigo, dimmed to
  ~55 % opacity (exact value eyeballed on device) — with the stepper chevrons disabled and
  gray. The times still read as "sunset is orange, bedtime is indigo"; they just aren't
  yours to type. The hero summary line ("Wake …, bedtime …") reads the **stored wake
  input**, not the derived day-start — so it says 7:00 AM even when daytime actually begins
  at a 5:12 sunrise.

### 4.2 The chart

All three dots stay full-color and draggable **vertically** (warmth). In Follow-sunset mode
the horizontal axis is locked for every dot — times come from the sun and the wake time, so
horizontal drag input is simply ignored (vertical still tracks). No more "drag sunset
sideways and silently switch to Set times".

Winter day, Mornings = At sunrise (note the pre-dawn bridge and the wake tick):

```
 6500K │                 ●━━━━━━━━━━━━━━━━━━━━━━━━━┓
       │              ┌──┘                          ┃
 3400K │      bridge ┌┘                             ┗━━●━━━━━━━━━━━━━━┓
       │  ┄┄┄┄┄┄┄┄┄┄┄┘                                                ┗━━●┄┄┄┄
 2700K │━━━━━━━━━━━━━┛                                                    ┗━━━
       └────┬────┬───▲╿───┬────┬────┬────┬────┬────┬────┬────┬────┬───▲───┬──
           2A   4A  6A╵8A 10A  12P  2P   4P   6P   8P   10P            ╵
                    wake 7:00 · sunrise 7:57              bedtime 10:00 PM
                    (thin blue tick at wake)              (= wake − 9 h)
```

Summer squeeze (wake 5:30): the curve steps day → bedtime directly at 8:30 PM; the sunset
dot still floats at its warmth on the (unused that day) sunset time, dimmed like its
stepper, so the user can still tune sunset warmth for the seasons where it applies.

The chart hint line gains three words in solar mode:
*"Drag the time line to preview · drag a dot to set its warmth · times follow the sun."*

### 4.3 Location & Sun section

```
┌─ Location & Sun ────────────────────────────────────────────────────────────┐
│  Schedule from                              [ Set times │ Follow sunset ]   │
│                                                                             │
│  Daytime while the sun is up, sunset warmth after sundown, bedtime warmth   │
│  before sleep — timed from your location and one time you set: your wake.   │
│                                                                             │
│  Bedtime starts                                     [ 9 hr before wake ⌄ ]  │
│  f.lux's rule: about 8 hours of sleep plus an hour to wind down.            │
│                                                                             │
│  Mornings                                   [ At sunrise │ At wake time ]   │
│  Stays warm until the sun is really up, even after you wake (like f.lux).   │
│                                                                             │
│  Latitude [ 47.6      ]   Longitude [ -122.3    ]                           │
│  ⌖ Use my location                                                          │
│  Location access                                              Authorized    │
│  Sun today                                        ↑ 5:12 AM · ↓ 9:11 PM     │
│  Warmth                                       Automatic — 6,500 K applied   │
└─────────────────────────────────────────────────────────────────────────────┘
```

- The two new rows appear **only** in Follow-sunset mode (like today's "Sunset today" row).
- "Bedtime starts" is a menu picker like Fade: 4 hr … 12 hr in 30-min steps, the stored
  value always included even if off-grid.
- The "Mornings" caption is dynamic, one line, swapping with the selection:
  - **At sunrise:** "Stays warm until the sun is really up, even after you wake (like f.lux)."
  - **At wake time:** "Brightens to daytime when you wake, even if it's still dark outside."
- "Sunset today" becomes "Sun today" with both sunrise and sunset, since sunrise now
  matters. The old caption ("…your wake and bedtime stay the times you set below") is gone —
  replaced by the section description above, which *is* the how-it-works text. No further
  explainer prose; anything jargon-y stays in ⓘ tooltips per the vocabulary decision.

### 4.4 Mode-switch semantics

- **Follow sunset → Set times:** freeze today's derived **sunset** (existing behavior) and
  **bedtime** (wake − lead) into the stored anchors so the chart doesn't jump. Wake is never
  overwritten — with Mornings = At sunrise the visible day-start moves from sunrise back to
  the wake time, a small honest jump ("set times" means *your* times, not a sun snapshot).
- **Set times → Follow sunset:** unchanged — prompt for location on first use; sunset and
  bedtime become derived; the stored bedtime is simply ignored until you switch back.

## 5. Engine and code changes

1. **`ScheduleTimeline`** (new, in `ColorSchedule.swift` or alongside): an ordered list of
   `(minute, ColorPhase)` events for the day, plus
   `ColorSchedule.timeline(preferences:date:calendar:)` implementing §3. Replaces
   `solarAdjustedPreferences` — a derived bedtime and a 4-event day can't be expressed as a
   mutated `AppPreferences`, which is why the old approach hits a wall.
2. **`scheduledValue`** reimplemented over events (most-recent event + capped fade — the
   existing algorithm, generalized). The current 3-anchor entry points become wrappers that
   build a 3-event timeline, so `scheduledTemperature` / `scheduledHardwareLevel` callers
   and existing unit tests keep working. The pre-dawn bridge maps to the *sunset* value for
   hardware brightness/contrast schedules too.
3. **Call sites of `solarAdjustedPreferences`** move to the timeline:
   `ColorSchedule.targetTemperature` / `currentPhase`, `SchedulePreview.plan`,
   `AppStore` (~line 1527), `ColorScheduleView.effectivePreferences`.
4. **`FluxCurveEditor`** takes the resolved timeline plus warmth bindings and a
   `timesLocked` flag, instead of six independent bindings; the curve renders from the same
   engine as the live schedule (single source of truth, bridge and squeeze included). Adds
   the wake tick.
5. **`AppPreferences`:** new `bedtimeLeadMinutes` (default **540**, clamp 240…720) and
   `morningStart` enum `sunrise | wakeTime` (default **sunrise**); both decode-with-default
   (no migration break), both join `ColorSignature`. New `ControlRanges.bedtimeLead`.
6. **`ColorScheduleView`:** steppers gain the locked style; new Location & Sun rows; wake
   stepper writes `coolStartMinutes` directly in solar mode (no cross-anchor clamp — wake is
   free, night shifts included); summary reads stored wake.
7. **Tests:** table-driven timeline tests for the six cases in §3; existing
   `ColorSchedule` tests unchanged via the wrappers.

## 6. Non-goals

- Set-times mode: zero behavior change.
- No per-phase fade durations (f.lux ties transition length to twilight; we keep the single
  Fade menu).
- No location search / geocoding UI (f.lux has one; out of scope).
- No third morning option ("earlier of sunrise and wake") unless asked.

## 7. Open questions

1. Bedtime-lead range 4–12 h in 30-min steps — generous enough?
2. Wake tick on the chart (§4.2): keep, or is the bedtime dot moving with the stepper
   feedback enough?
3. Locked-knob dimming is specced at ~55 % opacity with hue retained — final value to be
   eyeballed on device against both appearances.
