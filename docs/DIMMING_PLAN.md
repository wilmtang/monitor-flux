# Dimming modes: Hardware / Software / Automatic (hybrid)

Design plan (not yet implemented). Goal: MonitorControl-style choice of *how* a display dims,
plus a hybrid mode where dragging past the monitor's hardware minimum keeps dimming in
software — one slider, one mental model, no dead stop at "DDC 0 but still too bright".

## What exists today (the parts this builds on)

Per display, `DisplayPreferences` already persists both components:

- `hardwareBrightness` (0–100) → DDC writes via `setHardwareBrightness` / `scheduleDDC`
  (`Stores/AppStore.swift`)
- `gammaBrightness` (0–150) → gamma tables via `GammaPlan`/`GammaCompositor`, or the
  `ShadeController` overlay on AirPlay/virtual displays
- `gammaControlsEnabled` — the current per-display software-dimming opt-in, auto-seeded to
  `true` only when the display has no hardware path (`seedMissingDisplayPreferences`)

The media-key path (`adjustBrightnessUnderCursor`) already picks native backlight → DDC →
shade → gamma, and the schedule already falls back to software on non-DDC panels
(`applyScheduledBrightness`). What's missing is a *user-visible choice* and a *continuous
handoff* between the two — today software dimming is a separate slider buried in Advanced.

## The model

New per-display preference (replaces `gammaControlsEnabled` as the user-facing concept):

```swift
enum DimmingMode: String, Codable { case automatic, hardware, software }
var dimmingMode: DimmingMode = .automatic
```

| Mode (UI label) | DDC display | non-DDC external | AirPlay/virtual | Built-in |
|---|---|---|---|---|
| **Automatic** (default) | DDC first, software continues below DDC 0 | software only | overlay only | n/a — the built-in is binary, never hybrid (see 2026-07-02 built-in revision) |
| **Monitor hardware** | DDC only (today's behavior) | slider disabled + "no hardware control" hint | n/a (hidden) | backlight only (default) |
| **Software dimming** | gamma only, DDC left alone | software only | overlay only | gamma only — backlight left exactly where it is |

- Labels follow the de-jargon rule: "Automatic (recommended)" / "Monitor hardware" /
  "Software dimming"; DDC/gamma live in the ⓘ tooltip only.
- AirPlay/virtual displays get no picker at all (overlay is the only path — show a static
  `LabeledContent("Dimming", value: "Software (overlay)")` if anything).
- Migration: absent key → `.automatic`. Existing `gammaControlsEnabled == true` (seeded on
  non-DDC panels, or hand-enabled) → `.automatic`; `false` on DDC panels → `.automatic` too
  (hybrid only engages *below* DDC 0, so behavior is unchanged until the user drags past the
  floor). Keep decoding `gammaControlsEnabled` for one release to seed the new field.

## The slider (the crux)

**One "Brightness" slider per display — everywhere (detail pane hero + popup card). Its
position is the *perceived* brightness on a single unified scale.** In Automatic mode the
track has two zones separated by a small notch:

```
0%                    S=25%                                              100%
├── software zone ─────┼─────────────── hardware zone ────────────────────┤
│ gamma floor…100%     │ DDC 0…100 (or backlight 0…100 on the built-in)   │
```

- **Hardware zone** (notch → right end): maps linearly to DDC 0–100. This is the everyday
  range; at default the slider behaves exactly like today.
- **Software zone** (left end → notch): entered only by continuing past DDC 0. Maps linearly
  from gamma 100% down to the **safety floor** (gamma 15% — screen always stays readable;
  full black is never reachable from the unified control). On AirPlay the same zone maps to
  the shade's 0–85% opacity cap.
- **Notch = handoff point**, fixed at 25% of the track. Fixed beats proportional: the zones
  stay predictable across monitors, and 25% mirrors how much extra perceived dimming gamma
  actually buys. Rendered as a 1pt tick on the `MonitorSlider` track (like the volume
  bezel's segment gaps — quiet, not a second thumb).
- **Zone feedback, show-don't-tell:** below the notch the `MonitorSlider` fill switches from
  the white "backlight" fill to a dimmer fill (e.g. 55% white), and the leading icon swaps
  `sun.max` → `moon` — the visual language for "the image is being darkened now, not the
  backlight". No text needed on the popup.
- **Hardware / Software modes:** no notch — the whole track maps to the single component
  (DDC 0–100, or gamma floor–100). Same slider, simpler track.

### Invariant and mixed states

The unified drag path maintains: **gamma dims only when hardware sits at its floor** —
lowering through the notch first writes DDC 0, then starts easing gamma; raising back first
restores gamma to 100, then lifts DDC. Power users can still create mixed states (DDC 50 +
gamma 80) from Advanced; the unified slider then shows the *software* position (the darker
truth) and the first upward drag re-normalizes (gamma → 100) before lifting DDC — one
gesture, self-healing, nothing snaps visibly.

Mapping lives in a pure `Support/HybridBrightness.swift` (`split(unified:) -> (ddc, gamma)`,
`unified(ddc:gamma:)`) with round-trip/boundary/mixed-state unit tests — same pattern as
`GammaCompositor`.

## OSD

The native `OSDManager` bezel keeps showing brightness for the whole unified range — the bar
simply keeps stepping below the handoff (fraction = unified fraction, so the 25% handoff sits
at chiclet 4 of 16). No custom bezel, no glyph swap: macOS has no "software dimming" glyph and
inventing one on the *native* bezel path isn't possible anyway. The handoff is already visible
where the user is looking (the slider) and in the room (the backlight stops changing).

Media keys walk the same unified scale: 6% per press, 1% fine (⌥) — crossing the notch is
seamless, holding at the floor does nothing further.

## Settings surface (display detail pane)

- **Brightness section (hero, unchanged position):** the unified slider + its caption. The
  caption becomes mode-aware, e.g. Automatic on a DDC panel: *"Uses the monitor's own
  brightness first; keep dragging below the notch to darken the image further in software."*
- **"Dimming method" picker** directly under the slider (segmented, 3 options + ⓘ). Hidden
  on AirPlay; the built-in has no picker — its binary hardware/software choice is the
  Advanced "Use software dimming" toggle (2026-07-02 built-in revision).
- **Advanced keeps** contrast/volume unchanged, plus the raw "Software brightness" slider as
  the power-user escape hatch — it's the only place that reaches the 100–150 "boost" range
  and the only place that can drive gamma independently of the mode. The "Use software
  dimming" toggle goes away (superseded by the picker).
- Diagnostics rows: "Software dimming: On/Off" becomes "Dimming: Automatic · DDC 70% ·
  software 100%".

## Schedule interplay

Scheduled brightness targets the **unified scale** in Automatic mode — a 20% night target on
a monitor whose DDC 0 is still bright correctly lands in the software zone (today it clamps
at DDC 0). Hardware mode clamps the schedule to the hardware zone; Software mode drives gamma
only (already the non-DDC fallback today, `applyScheduledSoftwareBrightness`). The schedule
charts and preview scrub don't change — they just feed the unified setter, and
`previewHardwareDDC` keeps its no-persist contract for the DDC component.

## Safety rules (unchanged commitments)

- The unified control never reaches black: gamma floor 15%, shade cap 85% — recoverable by
  keyboard/slider alone.
- The built-in backlight is still never driven by the schedule or bare media keys
  (`allowBuiltIn` rules unchanged); Automatic on the built-in only affects the *manual*
  slider and custom hotkeys, which are user-initiated.
- Gamma writes stay routed through `GammaPlan`/`GammaTemperatureService` (single writer);
  DDC stays throttled via `scheduleDDC`. No new writers.

## Implementation phases (each shippable)

1. **Model + math:** `DimmingMode`, migration from `gammaControlsEnabled`,
   `HybridBrightness` mapping + tests. No UI change.
2. **Unified slider:** detail-pane hero + popup card use the unified value; `MonitorSlider`
   grows optional notch/zone rendering; method picker in the pane; Advanced toggle removed.
3. **Media keys + OSD:** `adjustBrightnessUnderCursor` walks the unified scale; OSD fraction
   = unified fraction.
4. **Schedule:** scheduled targets interpret as unified in Automatic mode.

## Implementation decisions (2026-07-02, shipped in phases 1–4)

Deltas and judgment calls made while implementing the plan + the inline answers below:

- **The `gammaControlsEnabled` gate is gone entirely** — the software-brightness *value* is
  the state and always applies; `dimmingMode` only routes the unified control. Picking
  "Monitor hardware" *clears* software dimming (to ≥100) instead of hiding it behind a gate,
  so there are no invisible mixed states. Migration: explicit legacy `true` → `.automatic`;
  explicit `false` → mode left unset **and a stale sub-100 gamma value reset to 100** (it was
  inert behind the gate; it must not start dimming on upgrade).
- **`dimmingMode` is stored optional** — `nil` resolves per display kind
  (`AppStore.dimmingMode(for:)`): externals → `.automatic`, built-in → `.hardware`. That keeps
  the built-in exactly as-is by default (answer 3) while new externals get hybrid.
- **Software dimming is decoupled from the Warmth master.** It's plain dimming, not a color
  change — without this, the unified slider's software zone (and scheduled dimming on non-DDC
  panels) would go dead whenever Warmth is off. Warmth still gates the temperature only.
  Conflict detection now keys on "may write gamma" (warmth on *or* any dimming active), and
  Diagnostics' "Disable Gamma and Restore" also neutralizes per-display dimming so it still
  fully restores.
- **Answer 2 (floor):** per-display **"Allow dimming to black"** toggle in Advanced sets the
  software floor to 0. The **notch stays at 25%** either way — moving the everyday hardware
  zone's geometry because of a power-user toggle would cost more predictability than the
  deep-dim tail gains in track length.
- **Answer 3 (built-in):** ~~the Advanced "Use software dimming" toggle *is* the hybrid opt-in
  (off ↔ `.hardware`, on ↔ `.automatic`)~~ — superseded by the 2026-07-02 built-in revision
  below: the toggle now flips between all-backlight and all-software (off ↔ `.hardware`,
  on ↔ `.software`), never hybrid. Still no separate Advanced software slider for the
  built-in, and the schedule still never touches it.
- **Answer 4 (icon):** kept the sun→moon swap *plus* the dimmed fill — the fill alone reads as
  "disabled"; the moon names the state at the exact moment the backlight stops responding.
- **The detail-pane hero is the same `MonitorSlider` as the popup** (not a native `Slider`
  with an overlay): the native track's inset is version-dependent, so a tick overlaid on it
  can't be trusted to sit on the track — and one control everywhere is the plan's point.
- **Mixed-state drag semantics** (in `HybridBrightness.resolve`): upward through the notch
  renormalizes gamma → 100 and only ever *lifts* hardware (`max`); downward from a mixed state
  holds the hardware and eases gamma, so nothing visibly snaps. The Advanced-only >100 boost
  is preserved by unified moves in the hardware zone.
- **Scheduled software-only targets ride the floored track** (`softwareOnlyGamma`), so a 0%
  night target stops at the floor instead of black (previously reachable on non-DDC panels),
  and the slider position matches the target percent. The scrub preview sends the DDC
  component through `previewHardwareDDC` (no persist) and previews the gamma component via the
  in-memory preview-preferences copy only.
- Dev hook: `MONITORFLUX_EXPAND_ADVANCED=1` opens the pane's Advanced disclosure on launch
  for screenshot verification.

## Built-in revision (2026-07-02): binary, never hybrid

Design change after using phases 1–4: the built-in panel does **not** get the hybrid slider
or the handoff notch at all. Its dimming is a binary choice, flipped by the Advanced
"Use software dimming" toggle:

- **Toggle off (default)** ↔ `.hardware`: the Brightness slider is 100% the real backlight,
  exactly like macOS's own control. Turning it off also clears any software dimming (≥100),
  as before.
- **Toggle on** ↔ `.software`: the Brightness slider is 100% software (gamma floor…100 —
  the same floored track non-DDC externals use, including "Allow dimming to black"). The
  backlight is **left exactly where it is**; the keyboard brightness keys still reach it
  (bare media keys always fall through to macOS on the built-in), so backlight and image
  dimming stay independently controllable.

**Why:** some eyes are sensitive to low backlight levels — many panels dim the backlight by
pulsing it (PWM), and the flicker gets harsher the lower the level. Those users want to park
the backlight at a comfortable steady level and do *all* dimming in software; a hybrid track
that drags the backlight down first is exactly wrong for them. This rationale is named in
the toggle's caption and the ⓘ tooltip (`HelpText.builtInDimmingChoice`).

Mechanics:

- `DimmingMode.resolved(stored:isBuiltIn:)` owns the rule: on the built-in only an explicit
  `.software` dims in software; `nil`/`.hardware`/`.automatic` all → `.hardware` (revised
  2026-07-02 — see "Built-in default revision" below). A stored `.automatic` is never a real
  built-in choice; it only comes from the old hybrid opt-in or the legacy
  `gammaControlsEnabled: true` migration (which seeds `.automatic` without knowing the display
  kind), so it resolves to the built-in's default (hardware) rather than silently starting the
  built-in in software. `AppStore.reconcileBuiltInDimming()` then folds that legacy state into
  an explicit hardware state on load — normalizing a migrated `.automatic` to `.hardware` and
  clearing any stale sub-100 gamma a pre-backlight-API build left behind, so an upgraded
  built-in can't come up dimmed with no way to lift it from the slider. Externals are unchanged.
- `brightnessControlKind` therefore never returns `.hybrid` for the built-in: it's
  `.hardwareOnly` or `.softwareOnly` (or `.softwareOnly` forced when there's no backlight
  API). Media keys, custom hotkeys, the OSD, and both sliders inherit the routing.
- The schedule still never drives the built-in (unchanged `allowBuiltIn` rules).
- Externals keep the full three-mode picker and the hybrid notch; `HybridBrightness` math is
  untouched.

## Built-in default revision (2026-07-02): hardware, not software

Follow-up after testing: the built-in must default to its **real backlight**, and it was
coming up on **software** instead. Cause — the built-in has no DDC path, so an earlier build
seeded the retired `gammaControlsEnabled: true` on it; the decoder migrates that to
`.automatic`, and the original built-in rule resolved `.automatic` → `.software` ("closest
surviving meaning of dim-past-the-backlight"). That reasoning is reversed here: on a laptop
with a working backlight, the everyday default should be the backlight, not a gamma dim.

- `DimmingMode.resolved` now maps the built-in's `nil`/`.hardware`/`.automatic` → `.hardware`;
  only an explicit `.software` (the Advanced "Use software dimming" toggle) dims in software.
- `AppStore.reconcileBuiltInDimming()` runs on each display refresh: for every built-in whose
  slider drives the backlight (`.hardwareOnly`), it normalizes a legacy `.automatic` to
  `.hardware` and clears any stale sub-100 gamma, so an upgraded panel can't stay dimmed with
  no slider recourse. Built-ins with no backlight API (forced `.softwareOnly`) and explicit
  `.software` built-ins are untouched, and externals are unchanged.

## Open questions - answered inline

1. Handoff notch at 25% of track — feels right against gamma's real perceived range, but
   worth trying 20/30% on hardware.
   1. My take: do as recommended
2. Software floor 15% gamma — dark rooms may want lower; expose in Advanced or keep fixed?
   1. My take: expose in advanced setting. User should be able to toggle a setting where the floor would set at 0% (complete dark). When this is toggled, the slider's hardware/software handoff notch position might need to change, use your UX judgement to decide whether the position need to change, if so what would be the position.
3. Built-in: adopt Automatic as its default (replacing today's Advanced software-dimming
   toggle), or keep the built-in exactly as-is in v1 and hybrid-ify externals only?
   1. keep the built-in exactly as-is in v1 and hybrid-ify externals only. And addtionally, remove the software dimming slider in advanced setting for built-in, so that once toggled the built-in screen's brightness is fully controlled by the main slider. Make the UX make sense.
4. Popup icon swap sun→moon in the software zone: keep, or is the dimmed fill alone quieter?
   1. Do as you recommmend as a role of UX designer
