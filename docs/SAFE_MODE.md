# Safe mode

Safe mode runs the **full MonitorFlux UI** while performing **no display-hardware writes
at all** — no gamma, no DDC, no backlight. It exists so you can build, launch, and test
the app without it fighting f.lux / MonitorControl over the gamma tables or flickering
your screen.

## Why it exists

The display gamma table is a single, shared, system-wide resource. When MonitorFlux runs
live it:

1. clears the tables on launch (`CGDisplayRestoreColorSyncSettings`) — a brief flicker,
2. writes its own warmth/brightness on top — which **overrides f.lux / MonitorControl**,
   and
3. restores again on quit — another flicker.

So every `build → launch → quit` cycle during development flickered the screen and stole
gamma from whatever color app you actually use. Safe mode makes that cycle inert.

## How to turn it on

It's controlled by one environment variable read once at launch:

```
MONITORFLUX_SAFE_MODE=1
```

You rarely set it by hand — the dev scripts do it for you:

| Command | Mode | Touches hardware? |
|---|---|---|
| `./script/build_and_run.sh` | live | **yes** — for actually using the app |
| `./script/build_and_run.sh --safe` | safe | no |
| `./script/build_and_run.sh --verify` | safe | no |
| `./script/smoke_test.sh` | safe | no |
| `swift test` | n/a | no (never launches the app) |

To set it manually:

```sh
MONITORFLUX_SAFE_MODE=1 open -n dist/MonitorFlux.app
```

`open` forwards the calling shell's environment to the launched app, so the variable
reaches the process (verifiable with `ps eww <pid> | tr ' ' '\n' | grep MONITORFLUX`).

## What it disables

Every hardware-writing path in `AppStore` is gated on `safeMode`. When on:

| Path | Live behavior | Safe-mode behavior |
|---|---|---|
| `reconcileColor()` | writes gamma via `GammaTemperatureService.apply` | **skipped**; status reads `Safe mode — gamma not applied` |
| `restoreColorTables()` | `CGDisplayRestoreColorSyncSettings` | **skipped** (no quit-flicker) |
| `runDDCCommand(…)` (brightness, contrast) | sends DDC over I²C | **skipped**; status reads `Safe mode — DDC not sent` |
| `applyVolume(…)` | sends DDC volume | **skipped** |
| `setNativeBrightness(…)` | `DisplayServicesSetBrightness` | **skipped** (UI cache still updates) |
| keyboard media-key tap | `CGEventTap` started | **not started**; status reads `Off (safe mode)` |

## What still works in safe mode

The point is that the UI is fully exercised — only the writes are suppressed:

- All windows, the popup, and every control render and respond.
- The **scheduled color temperature is still computed** (`currentTemperature`), so the UI
  shows the warmth it *would* apply — it just isn't written to the display.
- Slider positions still update (the per-display state and the native-brightness cache are
  still set; only the hardware call is skipped).
- Preferences load/save, the display list refreshes (incl. hotplug), and Location/solar
  scheduling all run normally.
- Reading the current backlight (`DisplayServicesGetBrightness`) still happens — reads
  have no side effects, no flicker, and don't conflict with other apps.

## How it's implemented

`AppStore` reads the flag once, first thing in `init`:

```swift
safeMode = ProcessInfo.processInfo.environment["MONITORFLUX_SAFE_MODE"] == "1"
```

and every hardware write is guarded, e.g.:

```swift
private func reconcileColor() {
    currentTemperature = preferences.gammaEnabled
        ? ColorSchedule.targetTemperature(preferences: preferences) : nil
    guard !safeMode else {
        colorMessage = "Safe mode — gamma not applied"
        return
    }
    let summary = gammaService.apply(displays: displays, preferences: preferences)
    colorMessage = summary.message
}
```

## Notes & limitations

- It's a **launch-time** switch, read once and never re-checked — you can't toggle it
  while the app is running. It's a developer/testing affordance, not a user preference.
- Live `run` is intentionally **not** safe: that's when you want MonitorFlux to actually
  control your displays (and would quit f.lux first).
- DDC values shown in safe mode are the stored preferences, not values read back from the
  monitor (MonitorFlux doesn't read DDC). Built-in backlight *is* read from DisplayServices.
