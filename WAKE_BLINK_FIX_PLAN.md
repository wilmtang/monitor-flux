# Fix plan: warmth/brightness blinks when an external screen wakes

Self-contained implementation plan. Read `CLAUDE.md` first and follow its rules throughout —
especially: `GammaTemperatureService` is the only gamma writer, repeated gamma writes can flicker,
no no-op `@Published` writes, automatic screen-changing logs use `.notice`, drag-frequency detail
uses `.debug`, and every hardware write remains gated by `safeMode`.

This is a tracked planning artifact (commit `a347b34`), not untracked scratch. Delete it only with
the eventual implementation, not as an unrelated cleanup.

## Symptom

Waking an external screen makes warmth and brightness visibly blink several times before settling.
Warmth and software dimming share one gamma LUT (`GammaCompositor` composites `gammaBrightness`
into the same table), so repeated gamma writes can move both together.

## Findings from the current code (2026-07-09)

The wake path changed in commit `60622b3` ("Fix gamma re-assert on wake…"). That fixed a real bug:
after macOS reset the LUT, an unchanged scheduled temperature was skipped by the gamma apply cache.
The current implementation is nevertheless too eager:

1. **The wake handler always forces an immediate gamma write.**
   `NSWorkspace.didWakeNotification` immediately calls `refreshGammaConflictState()`, then
   unconditionally calls `gammaService.invalidateApplied()`, `reconcileColor()`, and
   `applyScheduledHardware()`. The unconditional invalidation guarantees a rewrite even when the
   LUT survived sleep. Display-reconfiguration callbacks can later run `refreshDisplays()`, which
   performs the same detection/reconcile chain again. Separate callback bursts more than 400 ms
   apart therefore produce multiple MonitorFlux rewrites during one wake.

   The exact number and timing of WindowServer/ICC resets is hardware behavior, not something code
   reading proves. Treat the observed blink plus the guaranteed MonitorFlux writes as the evidence;
   verify the resulting timing on real hardware rather than encoding an assumed number of OS
   "stomps."

2. **Wake applies scheduled brightness after the first color reconcile.**
   Both the wake handler and `refreshDisplays()` currently run `reconcileColor()` before
   `applyScheduledHardware()`. If sleep crossed a scheduled phase boundary and the new unified
   brightness has a software component, the first reconcile uses the old `gammaBrightness`.
   `applyScheduledBrightness` then updates `gammaBrightness`, whose `preferences.didSet` causes
   another gamma pass with the final value. For the common one-external-display case this is an
   avoidable two-step transition.

3. **The conflict banner and repeated DDC restores are consequences, not separate first fixes.**
   Multiple dirty reads in separate refresh bursts can advance `gammaConflictStreak` to 2, and
   every `refreshDisplays()` calls `restoreHardwareSettings()`. Coalescing the wake burst first may
   remove both symptoms without more state.

## Important non-findings

Do not implement these from code reading alone:

- **Do not re-key gamma baselines by `persistentID` yet.** A gamma baseline belongs to the current
  ColorSync/profile state, not merely the panel's EDID. Reusing it across a display-ID/profile
  change can overwrite a legitimate new profile. Re-keying `appliedAdjustments` alone can also
  skip the first write to a new `CGDirectDisplayID` when the adjustment is unchanged.
- **Never restore a baseline to a stale "last-known" display ID.** CoreGraphics documents that
  calls using a removed ID fail, but the numeric ID can later identify a different display. Only
  restore when the current `DisplayInfo` set proves that the same persistent identity owns the ID;
  otherwise prune the stale entry without writing.
- **Do not add a persistent `restoredHardwareKeys` set.** A monitor can reset its DDC state on wake
  without disappearing from the final display list, so such a set can suppress a required restore.
- **Do not clear follow-brightness offsets immediately on wake.** The first built-in backlight read
  can be transient; adopting against it can create a wrong offset and a later jump. If telemetry
  proves the follow timer writes during wake, suspend the timer until the settled refresh instead.

## Minimal fix

### A. Replace the immediate wake write with one wake-aware debounced refresh

Route wake and display-reconfiguration events through the existing generation-counter debounce,
with one extra invariant: **a normal 400 ms callback must never shorten a pending wake settle
delay**.

- Rename/generalize `handleDisplayReconfiguration()` only if that makes the call sites clearer;
  do not introduce a scheduler type. Keep the existing `displayRefreshGeneration` guard.
- Add the smallest wake-pending state needed so `didWakeNotification` schedules a refresh after
  about 1.5 seconds of quiet. While that wake refresh is pending, every subsequent display
  callback must restart the same 1.5-second quiet period, not replace it with the normal 400 ms
  delay. With no reconfiguration callbacks, the wake's own task still runs.
- When the generation-guarded task finally wins, clear the wake-pending state and call
  `refreshDisplays()` once.
- In the wake handler keep the `.notice` log and `refreshNativeBrightness()`; remove the immediate
  `refreshGammaConflictState()` / unconditional `invalidateApplied()` / `reconcileColor()` /
  `applyScheduledHardware()` sequence.
- If no conflict is currently detected, reset `gammaConflictStreak` to 0 when wake begins. This
  prevents a stale one-shot dirty read from before sleep plus the wake's first dirty read from
  becoming a false two-read conflict; preserve the streak when a real conflict is already active.
- Do not add a trailing retry in the first implementation. `refreshDisplays()` already detects a
  dirty LUT before reconciling, and that dirty read invalidates the apply cache. A clean read means
  no forced gamma rewrite. Add one wake-specific trailing check only if real-hardware telemetry
  shows a late OS reset after the quiet-window refresh.

Expected result: one MonitorFlux refresh/reconcile per wake/reconfiguration burst, including a wake
that emits no display callbacks. The screen can remain at the OS-restored appearance for roughly
1.5 seconds before MonitorFlux reapplies the final state; that tradeoff is intentional.

### B. Apply scheduled hardware before the explicit color reconcile

In `refreshDisplays()`, keep gamma conflict detection first because it must read the LUT before any
write. Move `applyScheduledHardware()` before the explicit `reconcileColor()`:

```swift
refreshGammaConflictState()
let seeded = seedMissingDisplayPreferences()
let reconciledBuiltInDim = reconcileBuiltInDimming()
applyScheduledHardware() // a gammaBrightness change reconciles through preferences.didSet
if !seeded, !reconciledBuiltInDim {
    reconcileColor()      // cache hit/no-op if the schedule already wrote the final table
}
restoreHardwareSettings()
reconcileShades()
```

`updateDisplayPreferences` already skips equal values. When one scheduled display's software
brightness changed, its `didSet` gamma pass uses the final scheduled value; the following explicit
reconcile skips the equal adjustment. Do not add batching for multiple scheduled software-dim
displays unless telemetry shows their separate `didSet` passes are a real wake flicker source.

## Conditional follow-ups — only after measurement

1. **Late LUT reset:** if the settled refresh is still followed by a dirty LUT, add one
   wake-specific, generation-guarded recheck. It must not be scheduled by launch/manual refreshes,
   must not loop, and wake-settle dirty reads must not advance `gammaConflictStreak` into a false
   banner.
2. **Display-ID churn:** first add a temporary `.debug` observation of
   `(persistentID, CGDirectDisplayID)` across wake and reproduce the churn. If gamma cache work is
   then necessary, the cache must track both identity and current ID, force validation on ID change,
   respect a changed ColorSync baseline, and never write to an unverified stale ID.
3. **Gamma service tests:** if table I/O is injected, inject all three side effects — table read,
   table write, and global `CGDisplayRestoreColorSyncSettings()` — and make the table value visible
   to `@testable` tests. Injecting only read/write still touches real display hardware when
   `ensureSessionStarted()` runs.
4. **Follow built-in brightness:** if a follow write appears during the settle window, invalidate
   the follow timer on wake and restart it after the settled refresh; do not merely clear offsets
   against a transient reading.
5. **DDC restore:** after A, there should be one restore pass per settled burst. If one restore is
   still visibly harmful, measure the monitor's actual reset behavior before adding cache state.

## Tests and verification

This change is primarily ordering and real-hardware timing; do not manufacture a new abstraction
just to unit-test `Task.sleep`. Add a focused test only if implementation extracts non-trivial pure
decision logic. Existing pure behavior tests must remain green.

Before handoff:

1. Run `swift test`.
2. Run `./script/build_and_run.sh --verify` (safe mode; confirms launch/UI without hardware writes).
3. Perform the hardware regression check outside safe mode, coordinated so it does not surprise the
   user:
   - `pkill -x MonitorFlux || true`
   - `./script/build_and_run.sh --telemetry`
   - Sleep displays with `pmset displaysleepnow`, wait about 15 seconds, then wake them.
   - Repeat at least three times. Expect one wake notice, at most one MonitorFlux "Applied gamma"
     burst after the final callback burst, no false conflict edge, and visually no repeated
     warm/dim ping-pong.
   - Repeat across a scheduled brightness phase boundary if practical. For one software-dim
     display, the new warmth/brightness state should arrive in one final gamma pass.
4. If a late reset, follow write, ID change, or repeated DDC restore is actually observed, implement
   only the matching conditional follow-up and record the evidence in the handoff.
5. Quit the development instance with `pkill -x MonitorFlux`.

## Handoff

- State exactly which verification commands ran and their results; do not claim a hardware check
  was performed if it was not.
- Do not commit unless asked.
- `CLAUDE.md` is a symlink to `AGENTS.md`; do not edit either unless the implemented behavior needs
  a durable project rule.
