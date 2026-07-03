# Codebase Audit — Findings & Fix Plan (2026-07-03)

Full-source audit (all of `Sources/`, docs, and the test suite — 164/164 passing at audit
time). Overall the codebase is healthy: the single-gamma-writer rule holds, the unified
brightness math is pure and tested, migrations are covered, and the docs match the code.
The items below are the gaps found, ordered as a phased fix plan. Each item is checked off
in the same commit that fixes it.

Legend: `[ ]` open · `[x]` done · `[~]` deferred (with reason)

## Phase 1 — Correctness fixes

- [x] **1. Quit always resets system color tables, even when gamma was never written.**
  `applicationWillTerminate` → `AppStore.restoreColorTables()` → `GammaTemperatureService.restore()`
  calls `CGDisplayRestoreColorSyncSettings()` unconditionally. Running MonitorFlux as a pure
  DDC controller (Warmth off) alongside f.lux/Night Shift means every quit flickers and stomps
  the other app's tables — against the app's own safety rules. Fix: gate the quit-path restore
  on "this session actually wrote gamma" (`didStartSession`).
  Files: `Services/GammaTemperatureService.swift`, `Stores/AppStore.swift`.

- [x] **2. Warmth via keyboard kicks the user off the Automatic schedule; the slider doesn't.**
  `AppStore.adjustColorTemperature` always sets `colorMode = .manual`, while the popup's warmth
  slider re-warms the active phase and stays Automatic. The hotkey comment even claims it
  matches the slider (stale). Fix: in clock mode, adjust the active phase's temperature.
  Files: `Stores/AppStore.swift`.

- [x] **3. Built-in brightness slider shows stale values.**
  The `nativeBrightness` cache is only refreshed in `refreshDisplays()`; bare brightness keys are
  handled by macOS, so the popup card and detail hero drift out of sync until the next display
  reconfiguration. Fix: re-read the backlight when the popup appears and when the main window
  becomes key.
  Files: `Stores/AppStore.swift`, `Views/QuickControlsView.swift`.

- [x] **4. Popup warmth slider's "drag to enable" path is dead code.**
  `onChange` sets `gammaEnabled = true`, but the slider is disabled whenever warmth is off, so the
  line can never fire when it matters. Decision: make the slider always interactive — dragging
  while Off turns warmth on (Fixed at the dragged value, or re-warms the phase on a schedule),
  consistent with "editing a schedule control adopts the schedule" elsewhere.
  Files: `Views/QuickControlsView.swift`.

- [x] **5. Misleading DDC status on non-capable displays.**
  `runDDCCommand`/`applyVolume` report the backend name ("Native DDC") as the reason when a
  display isn't DDC-capable. Fix: say the display doesn't expose DDC.
  Files: `Stores/AppStore.swift`.

## Phase 2 — Dead code & robustness

- [x] **6. Strip the inert `gammaContrast` preference and dead hybrid built-in branches.**
  `GammaPlan` hardcodes `contrastPercent: 100` (software contrast was removed), yet the field is
  still decoded/encoded/normalized, reset by the escape hatch, and part of `colorSignature`
  (where it can trigger pointless gamma recomputes). Old payloads with the key still decode fine
  (unknown JSON keys are ignored). Also remove the unreachable `isBuiltIn` handling inside
  `setUnifiedBrightness`'s `.hybrid` case and `hybridComponents` — the built-in never resolves
  to hybrid. The compositor's contrast math stays (pure, tested, documents the pipeline).
  Files: `Models/AppPreferences.swift`, `Stores/AppStore.swift`, tests.

- [x] **7. Re-apply color and schedule on wake from sleep.**
  Nothing observes `NSWorkspace.didWakeNotification`; after wake, gamma/scheduled hardware wait
  on the 60 s timer or a reconfiguration callback. Fix: on wake, run conflict detection →
  reconcile color → scheduled hardware (and refresh the backlight cache).
  Files: `Stores/AppStore.swift`.

## Phase 3 — UX & accessibility

- [x] **8. Make the custom sliders accessible.**
  `MonitorSlider` is a bare `DragGesture` view: no accessibility label/value, no adjustable
  action — VoiceOver users cannot set brightness/warmth from the popup or the detail hero (the
  only surfaces for unified brightness). Curve-editor handles have labels but no adjustable
  actions. Fix: accessibility element + label + value + `accessibilityAdjustableAction` on
  `MonitorSlider` (and a `.help` tooltip from the same label); adjustable actions on the
  `FluxCurveEditor` / `HardwareScheduleChart` handles.
  Files: `Views/Components.swift`, `Views/QuickControlsView.swift`, `Views/DisplayDetailView.swift`,
  `Views/FluxCurveEditor.swift`, `Views/HardwareScheduleChart.swift`.

- [x] **9. Solar schedule silently uses the default (Seattle) coordinates.**
  Picking "Sunrise & sunset" without ever granting location keeps the shipped default lat/long —
  plausible-but-wrong times for everyone else. Fix: request location when switching to solar if
  permission was never asked.
  Files: `Views/ColorScheduleView.swift`, `Stores/AppStore.swift`.

- [ ] **10. Small UX alignments.**
  Sidebar display order should match the popup's user-chosen card order; `MonitorSlider` height
  should scale with the window zoom (fixed 24 pt leaves small targets at 200 %); add a Version
  row to General (today the version is only in the hidden Diagnostics pane).
  *Dropped:* a neutral-point (100 %) marker on the Advanced software-brightness slider — it's a
  native `Slider`, and overlaying ticks on the native track is explicitly unreliable per
  agent.md (version-dependent track insets).
  Files: `Views/ContentView.swift`, `Views/Components.swift`, `Views/SettingsView.swift`,
  `Views/DiagnosticsView.swift`.

## Phase 4 — Structural (deferred)

- [~] **11. Split `AppStore` (1,888 lines) into coordinators with protocol seams.**
  Window management, scrub preview, DDC throttling, and hotkeys could each be extracted, with
  gamma/DDC/backlight writers behind protocols so `reconcileBuiltInDimming`,
  `applyScheduledHardware`, and the preview lifecycle get unit tests. Deferred: a large refactor
  best done as its own effort, not batched with bug fixes.

- [~] **12. Adopt `os.Logger` across gamma/DDC/schedule paths.**
  Field debugging currently relies on the Diagnostics pane's current-state strings. Deferred with
  the same reasoning.

## Other observations (no action planned)

- `MonitorSlider` pointer-to-value mapping uses the full track width while the knob travels an
  inset range — values jump slightly at the extreme ends. Cosmetic; matches MonitorControl feel.
- The OSD panel (`.floating`) sits below the AirPlay shade (`CGShieldingWindowLevel`), so the
  bezel appears dimmed on a shaded display. Cosmetic edge case.
- Arm64 DDC writes retry 5× with 20 ms sleeps on the shared serial queue — a dead monitor adds
  ~100 ms latency to other displays' writes. Revisit if multi-monitor drag lag is ever reported.
