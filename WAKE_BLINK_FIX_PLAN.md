# Fix plan: warmth/brightness blinks a few times when the external screen wakes

Self-contained implementation plan. Read `CLAUDE.md` first and follow its rules throughout —
especially: `GammaTemperatureService` is the ONLY gamma writer, repeated gamma writes cause
visible flicker, no no-op `@Published` writes, logging policy (`.notice` for automatic
screen-changing events, `.debug` for high-frequency detail), and all hardware writes gated on
`safeMode`. This file is untracked scratch — delete it after the work lands.

## Symptom

Waking the external screen makes its warmth AND brightness visibly blink several times before
settling. Warmth and software dimming share the same gamma LUT (`GammaCompositor` composites
`gammaBrightness` into the table), which is why they blink together.

## Root causes (verified by code reading, 2026-07-09)

The wake path was changed on 2026-07-08 in commit `60622b3` ("Fix gamma re-assert on wake…").
That commit fixed a real bug (wake left the screen un-warmed + false conflict banner) but the
implementation re-asserts too eagerly and fights WindowServer during the wake window:

1. **Zero-delay wake re-assert ping-pong.** The `NSWorkspace.didWakeNotification` handler
   (`Sources/MonitorFlux/Stores/AppStore.swift` ~line 248) immediately runs
   `refreshGammaConflictState()` → `gammaService.invalidateApplied()` (unconditional!) →
   `reconcileColor()` → `applyScheduledHardware()`. During wake, WindowServer re-applies the
   display's ICC profile LUT — often multiple times (initial wake, link re-train, per
   reconfiguration wave). Each OS stomp flashes the screen neutral/bright; each of our
   dirty-read re-asserts (the wake handler now, plus `refreshDisplays()` per debounced
   reconfiguration wave at ~line 543) flashes it back warm/dim. 2–3 waves ⇒ 4–6 visible
   transitions. The unconditional `invalidateApplied()` also forces a rewrite even when the
   LUT was untouched — a gratuitous repeated write, which CLAUDE.md itself warns can flicker.

2. **Write ordering doubles the gamma transitions when the schedule moved during sleep.**
   In both the wake handler and `refreshDisplays()`, `reconcileColor()` runs BEFORE
   `applyScheduledHardware()` (AppStore.swift ~lines 256–257 and ~570–572). If the machine
   slept across a phase boundary (day→night), the first gamma write asserts warmth with the
   STALE `gammaBrightness`; then `applyScheduledBrightness` (~line 2073) updates
   `gammaBrightness` → `preferences.didSet` (`colorSignature` changed, ~line 38) → a SECOND
   gamma write with the new dim level, with a DDC step in between. A visible staircase where
   one write would do.

3. **Polluted gamma baseline on display-ID churn (compounding warmth/dim).**
   `GammaTemperatureService` keys `baselines`, `appliedAdjustments`, and `lastSetTables` by
   `CGDirectDisplayID` (`Sources/MonitorFlux/Services/GammaTemperatureService.swift` ~lines
   39–43). External displays commonly re-enumerate with a NEW id after sleep (DP link drop).
   For an unseen id, `baselineTables(for:)` (~line 229) captures the CURRENT LUT as baseline —
   which may be our own already-warmed+dimmed table (the wake handler may have just written it
   via the old id, same panel). The next write then compounds warmth and dimming: an
   over-warm/over-dark step that the OS stomps then fight, adding extra visible swings, and it
   can settle visibly wrong until relaunch. Related leak: the old id lingers in
   `appliedAdjustments`, so the next `apply()` puts it in `droppedIDs` → `restoreDisplays`
   (~line 206) writes a stale baseline at an id that macOS may have reused.

4. **False gamma-conflict banner on multi-stomp wakes (cosmetic).** `gammaConflictStreak`
   declares a conflict at 2 consecutive dirty reads (AppStore.swift ~line 1848). A wake runs
   detection several times in a burst (wake handler + each reconfiguration wave), so two dirty
   reads with no foreign app is likely, and the banner flashes falsely.

5. **(Conditional) Follow built-in brightness steps the external during wake.**
   `builtInFollowOffsets` survives until `refreshDisplays()` clears it, and the ~2 s
   `followTimer` keeps polling across the wake; a transient mid-wake backlight reading moves
   the external via DDC, then corrects on the next poll. Only when the mode is on.

6. **(Minor) `restoreHardwareSettings()` re-sends saved DDC values on every reconfiguration
   wave** (AppStore.swift ~line 626), interleaving with the monitor's own power-on restore.
   Same value each time, so usually invisible — but some monitors visibly re-apply or pop
   their OSD.

## Fixes to implement

Priority order. A and B are the core fix; C is a real correctness fix; D is a small cosmetic
guard; E and F are optional hardening — implement them if the diff stays clean, otherwise note
them in the handoff.

### A. Coalesce the wake re-assert into the debounced refresh path (no immediate write)

In `AppStore.init`'s `didWakeNotification` handler:

- Stop writing immediately. Replace the body's `refreshGammaConflictState()` /
  `invalidateApplied()` / `reconcileColor()` / `applyScheduledHardware()` sequence with a
  deferred, coalesced refresh through the SAME generation-counter debounce that display
  reconfiguration uses (`handleDisplayReconfiguration()`, AppStore.swift ~line 348).
- Give `handleDisplayReconfiguration` a settle-delay parameter, e.g.
  `func handleDisplayReconfiguration(settleDelay: Duration = .milliseconds(400))`, keeping the
  C-callback call site unchanged. The wake handler calls it with ~1.5–2 s. The shared
  `displayRefreshGeneration` counter means wake + the reconfiguration callbacks that usually
  follow collapse into one `refreshDisplays()` after the layout settles. A wake that produces
  NO reconfiguration callbacks (the case commit 60622b3 worried about) is still covered by the
  wake-scheduled refresh itself.
- Keep in the wake handler (they're cheap and read-only): the `.notice` log line,
  `refreshNativeBrightness()`, and add `builtInFollowOffsets = [:]` (fix 5 — the next follow
  poll then adopts followers where they sit instead of moving them off a transient reading).
- REMOVE the unconditional `gammaService.invalidateApplied()`. The dirty-read invalidate
  inside `refreshGammaConflictState()` (~line 1846), which `refreshDisplays()` already calls
  before reconciling, covers the "LUT was reset" case. Clean LUT ⇒ zero gamma writes on wake.
- Add ONE trailing settle re-check at the end of `refreshDisplays()`: a generation-guarded
  task that sleeps ~2 s and, if no newer refresh superseded it, runs
  `refreshGammaConflictState()` + `reconcileColor()`. This catches a final OS stomp that lands
  after the last reconfiguration wave (today that's left un-warmed until the 60 s timer). One
  shot only — do NOT loop or retry.

Expected behavior after A: at most one visible transition per genuine OS LUT stomp, and none
when the LUT survived sleep. The screen may stay at the OS state for up to ~2 s after wake
before the single re-assert — that's intended.

### B. Reorder: scheduled hardware before color reconcile

In `refreshDisplays()` move `applyScheduledHardware()` to run BEFORE the
`reconcileColor()` call, keeping `refreshGammaConflictState()` first (it must read the LUT
before any write). Target order:

```
refreshGammaConflictState()
seedMissingDisplayPreferences() / reconcileBuiltInDimming()   // unchanged
applyScheduledHardware()        // may update gammaBrightness → didSet writes the FINAL table once
if !seeded, !reconciledBuiltInDim { reconcileColor() }        // cache-hit no-op when didSet already wrote
restoreHardwareSettings()
reconcileShades()
```

Why this is safe: `applyScheduledBrightness`'s `updateDisplayPreferences` skips equal values
(no-op when nothing changed), and when it does change `gammaBrightness` the `didSet` reconcile
writes the final composited table exactly once (the apply-cache was invalidated by the dirty
read when relevant); the explicit `reconcileColor()` afterwards then skips via
`appliedAdjustments` equality. The wake path gets this for free once A routes it through
`refreshDisplays()`.

### C. Key GammaTemperatureService state by persistent display identity, not CGDirectDisplayID

Goal: a display that re-enumerates with a new id after sleep must reuse its existing baseline
instead of capturing the current (possibly already-adjusted) LUT — eliminating the compounding
bug — and dirty detection must keep working across the churn.

- Re-key `baselines`, `appliedAdjustments`, and `lastSetTables` by `DisplayInfo.persistentID`
  (the EDID-stable string; see `Support/DisplayIdentity.swift`). `apply(displays:preferences:)`
  and `detectsForeignGammaChange(displays:)` already receive full `DisplayInfo`, so resolve
  id ↔ persistentID per call. `GammaPlan.adjustments` stays id-keyed — map through the passed
  displays.
- Maintain `lastKnownID: [String: CGDirectDisplayID]`, updated on each apply, so
  `restoreDisplays` for dropped entries can attempt the restore at the last-known id (a write
  to a dead id fails harmlessly; that's fine). `restore()` clears everything as today.
- Make the table I/O injectable for tests: init-injected closures
  `readTables: (CGDirectDisplayID) -> GammaTables?` and
  `writeTables: (GammaTables, CGDirectDisplayID) throws -> Void`, defaulting to the existing
  CoreGraphics implementations. No behavior change in production.
- Keep `invalidateApplied()` semantics: clears only the applied-adjustment cache, keeps
  baselines + lastSetTables (the doc comment at ~line 124 explains why — preserve it).

### D. Don't count conflict-streak dirty reads during the wake/reconfiguration settle window

Add a `displaySettlingUntil: Date` on `AppStore`, set to `now + ~10 s` in the wake handler and
in `handleDisplayReconfiguration()`. In `refreshGammaConflictState()`, while inside the
window: still do the dirty-read `invalidateApplied()` + rewrite handling, but cap
`gammaConflictStreak` at 1 so the banner can't be declared from wake noise alone. A persistent
foreign writer still trips it within ~2 timer cycles after the window — same steady-state as
today. Keep the edge-only `.notice` logs.

### E. (Optional) Restore saved DDC values once per connect, not per wave

Track `restoredHardwareKeys: Set<String>` (persistentID) in `AppStore`; `restoreHardwareSettings()`
skips displays already in the set and inserts after sending; remove keys for displays that
disappeared (alongside `pruneDisplayKeyedState()`). Launch and genuine reconnects still
restore; repeated waves of the same connect don't re-send.

### F. (Optional, skip if messy) Nothing else

Do not touch: the built-in backlight rules (never driven automatically), the 45 ms DDC drag
throttle, mirror-set dedup, AirPlay/shade paths, or the schedule-preview machinery. They're
uninvolved.

## Tests

- New `GammaTemperatureService` tests using the injected table I/O (pure, no real gamma —
  required by CLAUDE.md):
  - ID churn keeps the baseline: apply for (`idA`, `persistent-1`) with a warm adjustment;
    re-apply for (`idB`, `persistent-1`) after `invalidateApplied()`; assert the write to `idB`
    was scaled from the ORIGINAL baseline (no compounding) and that no fresh baseline was read
    from the current table.
  - Dirty detection across churn: after the re-apply at `idB`, a foreign table at `idB` is
    detected; our own table is not.
  - Dropped-display restore goes to the last-known id and prunes state.
- Existing tests must stay green (`GammaPlanTests`, `DragReorderTests`, etc.). If the
  reorder in B or the debounce change in A breaks an assumption in a test, fix the test only
  if its assumption is what this plan deliberately changes.

## Verification (required before handoff)

1. `swift test`
2. `./script/build_and_run.sh --verify`
3. Real-hardware wake check (gamma writes can't be verified in safe mode — coordinate so you
   don't flicker the screen while the user is working):
   - `pkill -x MonitorFlux || true`, then `./script/build_and_run.sh --telemetry`
   - Sleep the displays (`pmset displaysleepnow`), wait ~15 s, wake by key press.
   - In the telemetry stream expect: one "Woke from sleep" notice, at most one
     "Applied gamma…" burst per genuine LUT stomp (typically exactly one), NO
     "Foreign gamma change detected" edge, and visually at most one warm/dim transition on the
     external panel.
   - Repeat once across a schedule phase boundary if practical (or fake it by moving the
     bedtime anchor) to confirm the B staircase is gone: warmth and the new dim level arrive
     in a single gamma write.
4. Per repo memory/rules: quit the dev instance when done (`pkill -x MonitorFlux`).

## Handoff notes

- If you cannot run `swift test` or the verify script, say exactly why in your handoff.
- Do not commit unless the user asks; if asked, the user prefers a single commit for the whole
  working tree with a prose message and no footer, direct to `main`.
- `CLAUDE.md` is a symlink to `AGENTS.md` — if any inline doc there needs updating (the wake
  behavior isn't currently documented in it), edit `AGENTS.md`. Leave `docs/*.md` alone unless
  the user asks (they curate those by hand).
- Delete this plan file once the work is done.
