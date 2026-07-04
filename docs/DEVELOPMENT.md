# Developing, testing, and shipping MonitorFlux

Everything you need to run the app without fighting your real displays, drive its UI from
scripts for screenshots/verification, and cut a distributable build.

## Safe mode

Safe mode runs the **full UI** while performing **no display-hardware writes** — no gamma, no
DDC, no backlight. The gamma table is a single, shared, system-wide resource, so a live app
clears it on launch (a flicker), writes its own warmth/brightness over whatever color app you
use, and restores on quit (another flicker). Safe mode makes every `build → launch → quit`
cycle inert, so you can develop without stomping f.lux / MonitorControl or strobing your screen.

It's one launch-time environment variable, read once in `AppStore.init` and never re-checked:

```
MONITORFLUX_SAFE_MODE=1
```

Every hardware-writing path in `AppStore` is guarded on `safeMode` — `reconcileColor` (gamma),
`restoreColorTables`, `runDDCCommand` (brightness/contrast), `applyVolume`, `setNativeBrightness`,
`reconcileShades` (AirPlay overlays), and the media-key `CGEventTap` (not started). What still
runs: all windows/controls, preferences load/save, the display list + hotplug, location/solar
scheduling, and the *computation* of the scheduled temperature (`currentTemperature` updates so
the UI shows the warmth it would apply — it just isn't written). Backlight *reads*
(`DisplayServicesGetBrightness`) still happen; reads have no side effects.

The dev scripts set it for you:

| Command | Mode | Touches hardware? |
|---|---|---|
| `./script/build_and_run.sh` | live | **yes** — for actually using the app |
| `./script/build_and_run.sh --safe` | safe | no |
| `./script/build_and_run.sh --verify` | safe | no |
| `./script/smoke_test.sh` | safe | no |
| `swift test` | n/a | no (never launches the app) |

To set it by hand: `MONITORFLUX_SAFE_MODE=1 open -n dist/MonitorFlux.app` (`open` forwards the
shell environment to the launched app). Live `run` is intentionally *not* safe — that's when you
want MonitorFlux to actually control your displays.

## UI test / screenshot hooks

Launch-time environment variables that jump the app straight into a state, so a screenshot or
smoke run doesn't have to script the sidebar. All are read once at launch. Combine freely, e.g.
`MONITORFLUX_SAFE_MODE=1 MONITORFLUX_FAKE_DISPLAYS=2 MONITORFLUX_SELECT=display
MONITORFLUX_OPEN_MAIN=1`.

| Variable | Value | Effect |
|---|---|---|
| `MONITORFLUX_OPEN_MAIN` | `1` / `reopen` | open the main window on launch (`reopen` = open, close, reopen — the Settings-again path) |
| `MONITORFLUX_SELECT` | `general` / `color` / `diagnostics` / `display` / `display:<name>` | select a sidebar pane (`display` = first external; `display:<substr>` targets one by name) |
| `MONITORFLUX_FAKE_DISPLAYS` | count (1–4) | inject mock displays (index 0 DDC, 1 non-DDC, 2 AirPlay/virtual…) alongside the real ones |
| `MONITORFLUX_EXPAND_ADVANCED` | `1` | force a display pane's Advanced block open (persisted toggle is bypassed for the shot) |
| `MONITORFLUX_SCROLL_TO` | `warmth` / `brightness` / `advanced` / `schedule` | scroll a display pane's section into view on launch, so below-the-fold content (e.g. the schedule charts) is captured by window id with no live-UI scrolling; pair with `EXPAND_ADVANCED` for the `advanced`/`schedule` anchors |
| `MONITORFLUX_ZOOM_STEP` | `0`–`8` | settings-window zoom step |
| `MONITORFLUX_OPEN_POPUP` | `1` | open the menu-bar popup |
| `MONITORFLUX_SHOW_OSD` / `MONITORFLUX_OSD_FRACTION` / `MONITORFLUX_OSD_HOLD` | — / 0…1 / `1` | drive the OSD bezel for capture (`OSD_HOLD` keeps it up ~60 s) |
| `MONITORFLUX_FORCE_DOCK` / `MONITORFLUX_DOCK_OFF_AFTER` | on-off / seconds | force Dock presence / drop it after a delay |
| `MONITORFLUX_SHOW_ONBOARDING` / `MONITORFLUX_ONBOARDING_PAGE` | `1` / page index | show onboarding at a given page |
| `MONITORFLUX_DISMISS_HINT_AFTER` | seconds | auto-dismiss the "no external monitors" hint |

Screenshots are taken by window id (`script/_shot_sck.swift`); the zoom harness lives in
[`prototype-zoom-matrix/`](../prototype-zoom-matrix/). `swift test` covers the pure logic
(schedule resolution, hybrid-brightness math, preference migration, color signature); deeper "a
control exists and moving it changes state" assertions need XCUITest (an Xcode UITest target).

## Distributing (Developer ID signing + notarization)

`./script/make_dmg.sh` with no arguments produces an **ad-hoc signed** `.dmg` — it works, but
Gatekeeper blocks a normal double-click (right-click ▸ Open the first time). For a
double-click-to-open download, sign with a **Developer ID** certificate, notarize, and staple.

### No entitlements needed

Notarization requires the **hardened runtime**, and MonitorFlux uses private APIs — but the
hardened runtime doesn't break them:

- **IOAVService** (Apple Silicon DDC) and **CGDisplayIOServicePort** (Intel DDC) are bound with
  `@_silgen_name`, resolved at **link time** against already-linked Apple frameworks.
- **DisplayServices** (backlight), **OSD.framework** (`OSDManager`), and **CoreDisplay** (AirPlay
  detection) are `dlopen`'d at runtime from system paths. Under the hardened runtime `dlopen` is
  governed by **library validation**, which permits Apple- or team-signed libraries; all three
  are Apple-signed. Verified by `dlopen`ing DisplayServices from a hardened-runtime binary with
  no entitlements, and by running the app re-signed with `--options runtime`.

So **no entitlements file and no `disable-library-validation`**. (Accessibility, Location, and
global hotkeys are runtime TCC permissions the user grants, not entitlements.) Notarization is a
malware scan, not an API-policy review — private-API use doesn't cause rejection (MonitorControl
ships notarized with the same IOAVService approach).

### One-time setup

1. A paid **Apple Developer Program** membership.
2. A **Developer ID Application** certificate in your login keychain — confirm with
   `security find-identity -v -p codesigning`.
3. Store notary credentials once with an **app-specific password** (not your Apple ID password):

   ```sh
   xcrun notarytool store-credentials "MonitorFlux" \
     --apple-id "you@example.com" --team-id "TEAMID" --password "abcd-efgh-ijkl-mnop"
   ```

### Build a notarized .dmg

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="MonitorFlux" \
  ./script/make_dmg.sh
```

The script builds an optimized release `.app`, re-signs it with your Developer ID + hardened
runtime (`--options runtime`) + secure `--timestamp`, assembles and signs the `.dmg`, submits it
to Apple's notary service (`notarytool submit --wait`, a few minutes), then staples the ticket
so it verifies offline. Check with:

```sh
spctl -a -t open --context context:primary-signature -v dist/MonitorFlux-0.1.0.dmg
xcrun stapler validate dist/MonitorFlux-0.1.0.dmg
```

Notes: pass only `SIGN_IDENTITY` (omit `NOTARY_PROFILE`) to sign without notarizing, for a quick
local check. The app has no embedded frameworks or helper tools, so a single `codesign` of the
`.app` is enough (no `--deep`). If you ever add a bundled framework or XPC helper, sign nested
code inside-out before the app and re-test notarization.
