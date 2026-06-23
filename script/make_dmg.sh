#!/usr/bin/env bash
set -euo pipefail

# Builds a consumer-facing disk image: a compressed .dmg containing MonitorFlux.app next to
# an /Applications symlink, so a user just drags the app across to install it.
#
#   ./script/make_dmg.sh            -> dist/MonitorFlux-<version>.dmg
#
# The app is ad-hoc signed (no Apple Developer ID), so first launch needs a right-click ▸
# Open to get past Gatekeeper. Proper Developer ID signing + notarization (so it opens with
# a normal double-click) needs a paid Apple Developer account — see the note at the end.

APP_NAME="MonitorFlux"
APP_VERSION="0.1.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/$APP_NAME-$APP_VERSION.dmg"
STAGING_PARENT="$(mktemp -d)"
STAGING="$STAGING_PARENT/$APP_NAME"

cleanup() {
  rm -rf "$STAGING_PARENT"
}
trap cleanup EXIT

# 1. Build an optimized .app bundle (no launch).
BUILD_CONFIG=release "$ROOT_DIR/script/build_and_run.sh" --bundle >/dev/null
[ -d "$APP_BUNDLE" ] || { echo "error: $APP_BUNDLE was not built" >&2; exit 1; }

# 2. Stage the drag-install layout: the app + a shortcut to /Applications.
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# 3. Build a compressed read-only image.
rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_PATH" >/dev/null

SIZE="$(du -h "$DMG_PATH" | cut -f1 | tr -d ' ')"
echo "Created $DMG_PATH ($SIZE)"
echo "Install: open the .dmg, drag $APP_NAME to Applications. First launch: right-click ▸ Open."
