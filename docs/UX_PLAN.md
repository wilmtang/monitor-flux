# MonitorFlux — UX redesign plan

A prioritized plan to make MonitorFlux more **intuitive** and **visually pleasant**, written as
a self-contained handoff. A fresh session/agent should be able to execute from this doc plus
[`agent.md`](../agent.md). Nothing here changes behavior unless a work item says so.

> **Execution status (2026-06-23):** Items **1–5 done**, item **6 partial** (Diagnostics hidden ✅;
> warmth motif & empty states 🟡; shortcut chips ⬜). Built clean, 80 unit tests pass, `smoke_test.sh`
> PASS on open+reopen, and every changed surface was screenshot-verified. Per-item notes are inline below.

---

## North star

> **Let people express intent — "dimmer," "warmer at night," "this monitor brighter" — and let
> the app pick the mechanism. Outcomes in front; machinery (gamma / DDC / software vs hardware)
> behind a disclosure or a tooltip.**

The app's current UX problem is that it exposes its *plumbing*: gamma vs DDC, software vs
hardware, a global master gate plus per-display gates, two keyboard sets. When a single control
needs a paragraph to explain (the gamma master-vs-per-display relationship does), the design is
carrying too much. Almost every remaining task is "remove a decision the user shouldn't have to
make," not "add chrome."

The signature assets are already good — the draggable **schedule curve** (`FluxCurveEditor`) and
the **OSD** (on-screen brightness/volume overlay). Lean into those; don't bury them.

---

## ⚠️ Read before you touch the UI (don't regress these)

Full detail is in [`agent.md`](../agent.md) → "Engineering Rules", "Verifying UI changes", and
"Architecture". The ones a redesign is most likely to break:

- **Detail window sizing (regressed twice).** The window is an AppKit `NSWindow` +
  `NSHostingController` in `AppStore.showMainWindow()`. The content MUST stay an
  `NSHostingController` (a bare `NSHostingView` renders `NavigationSplitView` blank), its default
  `sizingOptions` MUST stay, and the root view is `.frame(idealWidth:idealHeight:)`-pinned so it
  can't balloon off-screen. Long detail panes must scroll internally (e.g. `ColorScheduleView` is
  a `ScrollView`).
- **The built-in backlight belongs to macOS.** Never drive it automatically (schedule / media
  keys). Only user-initiated actions touch it (manual slider, custom hotkeys with
  `allowBuiltIn: true`).
- **Gamma is single-owner.** All gamma writes go through `GammaTemperatureService`; plan via
  `GammaPlan` / compose via `GammaCompositor`. Don't add a second writer.
- **A passing `smoke_test.sh` does NOT mean the UI rendered** — it only checks window geometry.
  **Screenshot every UI change**: launch with `MONITORFLUX_SAFE_MODE=1 MONITORFLUX_OPEN_MAIN=1
  MONITORFLUX_SELECT=general|color|display`, get the window id from `CGWindowListCopyWindowInfo`,
  `screencapture -l<id> -o -x out.png`, and look at it.
- To drive a SwiftUI button in a test use accessibility **`AXPress`** (find it by its `help`
  string — SwiftUI buttons expose no AX title), not coordinate clicks. **Don't spam launches** —
  each one pops a window on the user's screen.
- Use the existing **`MonitorSlider`** (not a stepped SwiftUI `Slider`, which draws tick marks).

Build / test / verify:

```sh
swift build && swift test          # unit tests (headless)
./script/build_and_run.sh --safe   # run the UI, no gamma/DDC/backlight writes
./script/smoke_test.sh             # window opens / on-screen (geometry only)
```

---

## Screen inventory & file map

| Surface | File | Notes |
|---|---|---|
| Menu-bar popup (primary surface) | `Sources/MonitorFlux/Views/QuickControlsView.swift` | "Ambience" card + per-display cards + Settings/Quit footer |
| Main window shell / sidebar (IA) | `Sources/MonitorFlux/Views/ContentView.swift` | `NavigationSplitView`: General, Color▸Schedule, Displays▸…, Diagnostics |
| Schedule screen | `Sources/MonitorFlux/Views/ColorScheduleView.swift` | status headline, **split-circle icon (replace)**, curve, steppers, forms |
| Day/night curve (signature) | `Sources/MonitorFlux/Views/FluxCurveEditor.swift` | draggable 3-handle curve |
| Per-display detail | `Sources/MonitorFlux/Views/DisplayDetailView.swift` | Display, Color, real brightness, gamma, schedule sections |
| General / Keyboard / Shortcuts | `Sources/MonitorFlux/Views/SettingsView.swift` | also the gamma master toggle + Accessibility warning |
| Diagnostics (dev-facing) | `Sources/MonitorFlux/Views/DiagnosticsView.swift` | color pipeline / DDC / displays |
| Shared components | `Sources/MonitorFlux/Views/Components.swift` | `MonitorSlider`, `InfoButton`, `GammaConflictBanner`, `HelpText` |
| State + mutations | `Sources/MonitorFlux/Stores/AppStore.swift` | `@MainActor`; `preferences.gammaEnabled` is the master flag |
| Prefs model | `Sources/MonitorFlux/Models/AppPreferences.swift` | `gammaEnabled` (master), `displayPreferences[key]` (per-display) |

---

## Design principles

1. **Outcomes, not mechanisms.** Primary labels name what the user gets; the precise term lives
   in the `InfoButton` (ⓘ) and an "Advanced" area.
2. **One control per intent.** A display has *one* "Brightness," not three (real / software /
   schedule). The app routes to the best mechanism; extras are progressive disclosure.
3. **One vocabulary.** The same concept has one name everywhere (see mapping below).
4. **Calm by default, powerful on demand.** Default views are sparse; advanced controls are one
   click away, never gone.
5. **A warmth motif.** A cool-blue ↔ warm-amber language across the warmth control, the curve,
   the OSD, and the menu-bar icon tint — meaning *and* delight, no gradients required (use end
   icons/dots: snowflake/flame, blue/amber).

---

## Vocabulary unification (current → proposed)

| Current (varies by screen) | Proposed (everywhere) |
|---|---|
| "Ambience" (popup) / "Warm color" (display) / "Enable gamma" / "Warm colors & software dimming" | **Warmth** |
| "Hardware DDC" | **Monitor** (its own brightness/contrast) |
| "Gamma" / "Gamma brightness" / "Use gamma controls" | **Software dimming**, and only inside Advanced / ⓘ |
| "Schedule Brightness & Contrast" | **Schedule** (under Advanced) |

> **⚠️ Prior-decision conflict — confirm before doing item 1.** In an earlier session the user was
> offered exactly these renames (de-jargon gamma, "Hardware DDC"→"Monitor", "Ambience"→"Warmth")
> and chose to **keep** the technical terms, selecting only "clarify the three brightness
> controls." This plan (and the UX recommendation behind it) **reverses** that. Re-confirm with
> the user that they now want the de-jargon pass before renaming primary labels. The technical
> terms must remain in the ⓘ tooltips and Advanced regardless.
>
> **✅ Re-confirmed 2026-06-23 — the user approved the de-jargon pass.** Item 1 is done; jargon stays
> in tooltips/Advanced as required.

---

## Work items (priority order)

### 1. ✅ Unify vocabulary to "Warmth" + de-jargon primary labels  ·  *low risk, high clarity*
> **✅ Done (2026-06-23).** Renamed primary labels: `QuickControlsView` "Ambience"→**Warmth**;
> `ColorScheduleView` "Enable gamma"→**Warmth**, "Disable Gamma and Restore"→"Disable Warmth & Restore",
> status headlines→"Warmth is off", "Gamma" status row→"Warmth"; `DisplayDetailView` "Color"/"Warm
> color"→**Warmth**/"Warm this display", "Hardware DDC — real brightness"→**Monitor**, "Backlight — real
> brightness"→**Brightness**, "Gamma — software dimming"→**Software dimming**, "Use gamma controls"→"Use
> software dimming"; `SettingsView` "Warm colors & software dimming"→"Enable warmth", "Color" section→
> **Warmth**. Jargon kept in `InfoButton`/`HelpText`; `gammaEnabled` and other identifiers untouched.
> Verified on the popup, Schedule, Display and General surfaces.

**Why:** same concept is called three things; "gamma/DDC" in primary labels reads as plumbing.
**Change:** rename per the table above in `QuickControlsView` (the "Ambience" card),
`ColorScheduleView`, `DisplayDetailView` (section headers + "Warm color"), `SettingsView` (the
master toggle). Keep `HelpText`/`InfoButton` carrying "gamma"/"DDC". **Do not** rename the
underlying `preferences.gammaEnabled` flag or change behavior — labels only.
**Acceptance:** no user-facing "Ambience"/"gamma"/"DDC" in primary labels; consistent "Warmth"/
"Monitor"; ⓘ tooltips still explain the real mechanism.
**Was blocked on:** the prior-decision confirmation above — ✅ resolved 2026-06-23 (user approved).

### 2. ✅ Menu-bar popup: hero warmth + "more" disclosure  ·  *medium*
> **✅ Done (2026-06-23).** Warmth card relabeled; per the resolved open-decision, the Off/Manual/Schedule
> segmented control was **replaced with a compact mode chip** (`modeChip`) that shows "Auto · schedule" /
> "Manual" / "Off" and opens a menu to switch. Warm/cool end affordances (flame/snowflake, blue/amber) on
> the warmth slider and a per-display **"More"** disclosure (one Brightness by default; contrast/volume
> behind More) are in place. Verified by popup screenshot.

**Why:** the popup is where people live; today it shows every slider for every display at once.
**Change (`QuickControlsView.swift`):**
- Warmth card stays at top; surface the schedule as a small **"Auto · schedule"** chip when
  `colorMode == .clock` (consider replacing the Off/Manual/Schedule segmented control with the
  chip — **open decision**, see below).
- Per-display card shows **one Brightness** slider by default; put contrast/volume behind a per-
  card **"more"** disclosure (`@State private var expanded`).
- Add cool/warm end affordances to the warmth slider (snowflake/flame, blue/amber tint).
**Acceptance:** default popup = warmth + one brightness per display; contrast/volume on "more".
**Verify:** screenshot the popup (drive the status item, capture the ~312-wide window).

### 3. ✅ Replace the Schedule split-circle icon  ·  *low*
> **✅ Done (2026-06-23, landed in an earlier commit).** The split-circle `ZStack` is gone; the header
> now shows a state-mirroring SF Symbol via `statusIcon` — `sun.max.fill` by day, `moon.stars.fill` at
> night, `moon.zzz.fill` when warmth is off. Verified on the Schedule pane.

**Why:** the orange/blue split `Circle` `ZStack` at the top of `ColorScheduleView` reads as a
meaningless logo (the user flagged it: "what is it even?").
**Change:** swap for a clear SF Symbol — `sun.horizon.fill` — or a small day→night swatch.
**Acceptance:** header icon communicates "day/night warmth."

### 4. ✅ Per-display pane: one Brightness + "Advanced"  ·  *higher risk, biggest intuitiveness win*
> **✅ Done (2026-06-23).** `DisplayDetailView` shows **Brightness** (the real control — the "Monitor"
> DDC section for external, backlight for built-in) + **Warmth** by default; **Software dimming (gamma)**
> and **Schedule** are collapsed under one `DisclosureGroup` labeled **Advanced** (`@State
> advancedExpanded`). All bindings/behavior preserved — pure reorganization. `smoke_test.sh` still PASS on
> open **and** reopen (no window-sizing regression). Verified by screenshot of an external display pane.

**Why:** `DisplayDetailView` stacks three "brightness" sections (Monitor/DDC, Gamma/software,
Schedule). Most users want one.
**Change:** show **Brightness** (the real control: DDC for external, backlight for built-in) +
**Warmth** by default. Move **Software dimming (gamma)**, **Schedule**, and any DDC details into a
SwiftUI `DisclosureGroup` labeled **Advanced**. Keep all current bindings/behavior; this is a
reorganization, not a rewrite. (The pane is already ordered real-first → gamma → schedule; this
collapses the latter two.)
**Acceptance:** one Brightness visible by default; software + schedule under Advanced; nothing
removed.
**Verify:** screenshot built-in and an external display detail; confirm scroll still works and the
window doesn't balloon (see sizing constraint).

### 5. ✅ First-run onboarding (2 cards)  ·  *medium-high, new surface*
> **✅ Done (2026-06-23).** Added a `hasSeenOnboarding` pref + `OnboardingView` (new file): card 1 "Two
> things, done well" (warm/cool gradient hero, two feature rows), card 2 the Accessibility ask framed by
> benefit, reusing `AppStore.requestAccessibility()`. Shown once on first launch via a small AppKit window
> (`AppStore.showOnboarding`/`completeOnboarding`); skippable; marked seen the moment it appears so it
> never re-pops. Test hooks: `MONITORFLUX_SHOW_ONBOARDING=1`, `MONITORFLUX_ONBOARDING_PAGE`. **macOS-26
> gotcha fixed:** primary CTAs use an explicit `.plain` accent capsule because `.borderedProminent` drops
> its label when the window isn't key (a menu-bar app's welcome window often isn't). Both cards verified
> by screenshot.

**Why:** the app drops users into a dense technical panel with no framing.
**Change:** add a `hasSeenOnboarding` pref; on first launch show a small sheet: (1) "MonitorFlux
does two things — warm your screen on a schedule, and control each monitor from the menu bar";
(2) the Accessibility ask, framed by benefit ("so the brightness/volume keys can drive your
external monitor"). Reuse the existing `requestAccessibility()` on `AppStore`.
**Acceptance:** shown once; skippable; permission framed by benefit.

### 6. 🟡 Smaller wins  ·  *low each*  — *partially done*
- **✅ Hide Diagnostics from the sidebar** — **Done (2026-06-23).** Removed the Diagnostics item from
  the `ContentView` sidebar; it's now reachable via a hidden **⌘⇧D** button (and `MONITORFLUX_SELECT=
  diagnostics` for tests).
- **🟡 Warmth color motif** — **Partial.** Flame/snowflake + blue/amber are on the popup warmth slider,
  and the onboarding uses cool→warm gradient heroes. **Not yet:** OSD glyph tint and menu-bar icon tint.
- **🟡 Empty states** — **Partial.** The popup empty state was reworded ("No displays detected — connect
  a monitor to control its brightness and color here."). **Not yet:** the external-specific "No external
  monitors detected — connect one…" copy.
- **⬜ Shortcut chips** — **Not done.** The monospace "Not set — record" pills in `ShortcutRecorder.swift`
  are unchanged; a cleaner key-cap chip style is still open.

---

## Open decisions for the user

> **✅ All resolved 2026-06-23:** (1) De-jargon — **yes, do it** (reverses the prior session).
> (2) Popup — **"Warmth + Auto chip"** (the segmented control was removed). (3) Display pane —
> **single "Brightness" + Advanced** (fully collapsed).

1. ✅ **De-jargon at all?** (Blocks item 1.) Prior session: user kept gamma/DDC/Ambience. Confirm
   the reversal, or keep technical terms and do only structural items (2–6). → **De-jargon approved.**
2. ✅ **Popup warmth control:** the **"Warmth + Auto chip"** direction (schedule surfaced as a chip)
   vs keeping the explicit **Off / Manual / Schedule** segmented control. → **Chip chosen.**
3. ✅ **How far to collapse the display pane** (item 4): single "Brightness" + Advanced, or keep the
   three sections but visually de-emphasize software/schedule. → **Single "Brightness" + Advanced.**

---

## Verification checklist (per UI change)

- [ ] `swift build && swift test` green.
- [ ] Screenshot the actual changed surface (`screencapture -l<windowid>`), look at it — geometry
      smoke test is not enough.
- [ ] Detail window still opens at a sane size on first-open **and** reopen (don't regress the
      blank/oversized bug): `MONITORFLUX_OPEN_MAIN=reopen` + `script/check_main_window.swift`.
- [ ] No behavior change unless intended (labels-only items must not touch `gammaEnabled` etc.).
- [ ] `./script/smoke_test.sh` passes (both `open` and `reopen` scenarios).
