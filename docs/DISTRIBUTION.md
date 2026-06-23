# Distributing MonitorFlux (Developer ID signing + notarization)

`./script/make_dmg.sh` with no arguments produces an **ad-hoc signed** `.dmg`. That works,
but because it isn't signed with an Apple **Developer ID** or notarized, Gatekeeper blocks a
normal double-click — the user has to right-click ▸ Open the first time (and on some Macs
dismiss a scary warning). For a friction-free, double-click-to-open download you need to
**sign with a Developer ID certificate, notarize, and staple**.

## Does MonitorFlux need special entitlements? No.

Notarization requires the **hardened runtime**. MonitorFlux uses private APIs, so the worry
is whether the hardened runtime breaks them. It doesn't:

- **IOAVService** (Apple Silicon DDC) and **CGDisplayIOServicePort** (Intel DDC) are bound
  with `@_silgen_name`, i.e. resolved at **link time** against already-linked Apple
  frameworks. The hardened runtime doesn't affect that.
- **DisplayServices** (built-in backlight) is `dlopen`'d at runtime from
  `/System/Library/PrivateFrameworks/`. Under the hardened runtime, `dlopen` is governed by
  **library validation**, which permits libraries signed by Apple or your team. DisplayServices
  is Apple-signed, so it loads — **verified** by `dlopen`ing it from a hardened-runtime-signed
  test binary with no entitlements, and by running the whole app re-signed with
  `--options runtime` (it launches and passes `codesign --verify --strict`).

So **no entitlements file and no `disable-library-validation`** are required. (Accessibility
for the media-key tap, Location for solar times, and global hot keys are runtime TCC
permissions the user grants — not hardened-runtime entitlements.)

Notarization is a malware scan, not an API-policy review, so private-API use does not cause a
rejection (MonitorControl itself ships notarized with the same IOAVService approach).

## Prerequisites (one-time)

1. A paid **Apple Developer Program** membership ($99/yr).
2. A **Developer ID Application** certificate in your login keychain (Xcode ▸ Settings ▸
   Accounts ▸ Manage Certificates ▸ + ▸ Developer ID Application, or download from
   developer.apple.com). Confirm it's there:

   ```sh
   security find-identity -v -p codesigning
   # → "Developer ID Application: Your Name (TEAMID)"
   ```

3. Store notarization credentials in the keychain once, so the script doesn't need them
   inline. Use an **app-specific password** (appleid.apple.com ▸ Sign-In and Security ▸
   App-Specific Passwords), not your real Apple ID password:

   ```sh
   xcrun notarytool store-credentials "MonitorFlux" \
     --apple-id "you@example.com" \
     --team-id "TEAMID" \
     --password "abcd-efgh-ijkl-mnop"      # the app-specific password
   ```

   `"MonitorFlux"` is the profile name you'll pass as `NOTARY_PROFILE`.

## Build a notarized .dmg

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="MonitorFlux" \
  ./script/make_dmg.sh
```

The script will:

1. Build an optimized release `MonitorFlux.app`.
2. Re-sign it with your Developer ID, the **hardened runtime** (`--options runtime`), and a
   secure `--timestamp`.
3. Assemble and compress the `.dmg` (app + `/Applications` symlink).
4. Sign the `.dmg`, **submit it to Apple's notary service** (`notarytool submit --wait`,
   a few minutes), then **staple** the ticket so it verifies offline.

Verify the result:

```sh
spctl -a -t open --context context:primary-signature -v dist/MonitorFlux-0.1.0.dmg
xcrun stapler validate dist/MonitorFlux-0.1.0.dmg
```

A notarized + stapled `.dmg` opens with a normal double-click on any Mac, no warning.

## Notes

- Provide only `SIGN_IDENTITY` (omit `NOTARY_PROFILE`) to Developer-ID-sign without
  notarizing — useful for a quick local check of the signing step.
- The app has no embedded frameworks or helper tools, so a single `codesign` of the `.app`
  is sufficient (no `--deep` needed).
- If you ever add a bundled framework or XPC helper, sign nested code **inside-out** before
  signing the app, and re-test notarization.
