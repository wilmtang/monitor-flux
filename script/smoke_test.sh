#!/usr/bin/env bash
set -euo pipefail

# End-to-end smoke test: builds the app, launches it with the detailed window opened
# (MONITORFLUX_OPEN_MAIN=1), and asserts via CGWindowList that exactly one sizable
# window is on screen. This catches the class of bug unit tests can't — the window not
# opening, opening blank-framed, or opening duplicates.
#
# For deeper UI assertions ("a Brightness slider exists and moving it changes state"),
# use XCUITest, which needs an Xcode app+UITest target — see README/agent.md.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/MonitorFlux.app"

pkill -x MonitorFlux >/dev/null 2>&1 || true

# Build + sign the bundle (this also launches once; we stop it immediately).
"$ROOT_DIR/script/build_and_run.sh" --verify >/dev/null 2>&1 || true
pkill -x MonitorFlux >/dev/null 2>&1 || true
sleep 1

# Safe mode: drive the UI but write no gamma/DDC/backlight, so the smoke test never
# flickers the screen or fights f.lux/MonitorControl.
MONITORFLUX_SAFE_MODE=1 MONITORFLUX_OPEN_MAIN=1 /usr/bin/open -n "$APP_BUNDLE"
sleep 2

set +e
swift "$ROOT_DIR/script/check_main_window.swift"
RESULT=$?
set -e

pkill -x MonitorFlux >/dev/null 2>&1 || true
exit "$RESULT"
