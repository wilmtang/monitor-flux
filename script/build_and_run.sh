#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
# Affero General Public License v3.0 or later. See LICENSE. No warranty.

set -euo pipefail

MODE="${1:-run}"
APP_NAME="MonitorFlux"
BUNDLE_ID="app.monitorflux.MonitorFlux"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${APP_VERSION:-0.1.0}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.icns"

# Any invocation replaces a running instance: two copies would fight for the gamma tables.
# The app installs a SIGTERM handler that restores the color tables before exiting, so this
# pkill doesn't leave the screen frozen at the last warmth.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true

# BUILD_CONFIG=release produces an optimized binary (used by make_dmg.sh); defaults to debug.
BUILD_CONFIG="${BUILD_CONFIG:-debug}"
swift build -c "$BUILD_CONFIG"
BUILD_BINARY="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

# SwiftPM resources (the offline place index) build into a bundle beside the binary; ship it
# in Contents/Resources, where PlaceIndex looks it up. Don't rely on Bundle.module: its
# generated fallback is an absolute .build path that only exists on the machine that built it.
BUILD_RESOURCE_BUNDLE="$(dirname "$BUILD_BINARY")/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "$BUILD_RESOURCE_BUNDLE" ]; then
  cp -R "$BUILD_RESOURCE_BUNDLE" "$APP_RESOURCES/"
fi

# Generate the app icon on first build, then bundle it.
if [ ! -f "$ICON_SOURCE" ] && [ -f "$ROOT_DIR/script/make_icon.swift" ]; then
  ( cd "$ROOT_DIR" && swift script/make_icon.swift ) >/dev/null 2>&1 || true
fi
ICON_PLIST_ENTRY=""
if [ -f "$ICON_SOURCE" ]; then
  cp "$ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
  ICON_PLIST_ENTRY="  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
"
fi

# Stamp the build with its git commit + UTC date so the app's About row (and the Diagnostics
# report) can identify exactly what shipped, VS Code-style. A dirty working tree is flagged so a
# local build off uncommitted changes is never mistaken for a clean commit.
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ "$GIT_COMMIT" != "unknown" ] && ! git -C "$ROOT_DIR" diff --quiet HEAD 2>/dev/null; then
  GIT_COMMIT="${GIT_COMMIT}-dirty"
fi
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>MonitorFluxGitCommit</key>
  <string>$GIT_COMMIT</string>
  <key>MonitorFluxBuildDate</key>
  <string>$BUILD_DATE</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSLocationWhenInUseUsageDescription</key>
  <string>MonitorFlux uses your location to compute local sunrise and sunset times for the color schedule.</string>
${ICON_PLIST_ENTRY}  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign so TCC can identify the app. A stable "MonitorFlux Dev" certificate (created by
# script/make_dev_cert.sh) keeps the code identity constant across rebuilds, so the
# Accessibility grant — needed for the media-key keyboard control — survives. Without it we
# fall back to ad-hoc, whose hash changes every build, so macOS re-prompts each rebuild.
# No hardened runtime, so the private IOAVService/@_silgen_name + DisplayServices dlopen keep
# resolving. SIGN_IDENTITY overrides.
SIGN_ID="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ] && security find-identity -p codesigning 2>/dev/null | grep -q "MonitorFlux Dev"; then
  SIGN_ID="MonitorFlux Dev"
fi
codesign --force --sign "${SIGN_ID:--}" "$APP_BUNDLE" >/dev/null 2>&1 || true

# In safe mode the app drives its UI but performs no gamma/DDC/backlight writes, so it
# doesn't fight f.lux/MonitorControl or flicker the screen. Used for verify/smoke runs.
# BACKGROUND=1 adds `open -g` so the app doesn't grab focus — used by --verify so building
# during a test run doesn't interrupt the developer.
open_app() {
  local bg_flag=""
  if [ "${BACKGROUND:-0}" = "1" ]; then
    bg_flag="-g"
  fi
  if [ "${SAFE_MODE:-0}" = "1" ]; then
    MONITORFLUX_SAFE_MODE=1 /usr/bin/open $bg_flag -n "$APP_BUNDLE"
  else
    /usr/bin/open $bg_flag -n "$APP_BUNDLE"
  fi
}

case "$MODE" in
  run)
    open_app
    ;;
  --bundle|bundle)
    # Build + sign the .app only; don't launch. Used by make_dmg.sh.
    echo "Built $APP_BUNDLE"
    ;;
  --safe|safe)
    SAFE_MODE=1
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    SAFE_MODE=1
    BACKGROUND=1
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    # A launch smoke check, not a session to keep: stop the instance we just started so it
    # doesn't sit in the menu bar (a safe-mode copy squatting over any real one) after verify.
    pkill -x "$APP_NAME" >/dev/null 2>&1 || true
    ;;
  *)
    echo "usage: $0 [run|--safe|--bundle|--debug|--logs|--telemetry|--verify]" >&2
    echo "  --safe: run without any gamma/DDC/backlight writes (no screen flicker, no f.lux conflict)" >&2
    exit 2
    ;;
esac
