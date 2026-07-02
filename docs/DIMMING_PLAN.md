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
| **Automatic** (default) | DDC first, software continues below DDC 0 | software only | overlay only | backlight first, software continues below backlight 0 |
| **Monitor hardware** | DDC only (today's behavior) | slider disabled + "no hardware control" hint | n/a (hidden) | backlight only |
| **Software dimming** | gamma only, DDC left alone | software only | overlay only | n/a (hidden — backlight always exists) |

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
  on AirPlay; on the built-in it offers Automatic / Monitor hardware only.
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
