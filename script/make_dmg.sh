#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
# Affero General Public License v3.0 or later. See LICENSE. No warranty.

set -euo pipefail

# Builds a consumer-facing disk image: a compressed .dmg containing MonitorFlux.app next to
# an /Applications symlink, so a user just drags the app across to install it.
#
#   ./script/make_dmg.sh                         -> ad-hoc signed (personal use)
#   SIGN_IDENTITY="Developer ID Application: …" \
#     NOTARY_PROFILE="MonitorFlux" ./script/make_dmg.sh   -> signed + notarized + stapled
#
# See docs/DEVELOPMENT.md for the one-time Apple Developer setup. This app needs NO special
# entitlements: its private APIs (IOAVService via @_silgen_name, DisplayServices via dlopen)
# all work under the hardened runtime that notarization requires (verified).

APP_NAME="MonitorFlux"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
STAGING_PARENT="$(mktemp -d)"
STAGING="$STAGING_PARENT/$APP_NAME"

# Optional distribution signing / notarization. Unset -> ad-hoc (right-click ▸ Open).
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

cleanup() {
  rm -rf "$STAGING_PARENT"
}
trap cleanup EXIT

# 1. Build an optimized .app bundle (no launch). build_and_run.sh ad-hoc signs it.
BUILD_CONFIG=release "$ROOT_DIR/script/build_and_run.sh" --bundle >/dev/null
[ -d "$APP_BUNDLE" ] || { echo "error: $APP_BUNDLE was not built" >&2; exit 1; }
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
DMG_PATH="$ROOT_DIR/dist/$APP_NAME-$APP_VERSION.dmg"

# 2. For distribution, re-sign with a Developer ID + the hardened runtime (required for
#    notarization) and a secure timestamp. The single binary has no nested code to sign.
if [ -n "$SIGN_IDENTITY" ]; then
  echo "Signing with Developer ID + hardened runtime: $SIGN_IDENTITY"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  codesign --verify --strict --verbose=2 "$APP_BUNDLE"
fi

# 3. Stage the drag-install layout: the app + a shortcut to /Applications.
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 4. Build a compressed read-only image.
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

# 5. Sign the image, then notarize + staple so Gatekeeper opens it with a normal double-click.
if [ -n "$SIGN_IDENTITY" ]; then
  codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi

if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
  echo "Submitting to Apple notary service (a few minutes)…"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  echo "Notarized + stapled — opens with a normal double-click."
elif [ -n "$SIGN_IDENTITY" ]; then
  echo "Developer ID signed but NOT notarized (set NOTARY_PROFILE to notarize)."
else
  echo "Ad-hoc signed (personal use). First launch: right-click ▸ Open."
  echo "Set SIGN_IDENTITY + NOTARY_PROFILE for a notarized build — see docs/DEVELOPMENT.md."
fi

SIZE="$(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')"
echo "Created $DMG_PATH ($SIZE)"
