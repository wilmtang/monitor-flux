#!/usr/bin/env bash
set -euo pipefail

# End-to-end smoke test: builds the app, launches it driving the detailed window, and
# asserts via CGWindowList that exactly one sizable window is on screen and substantially
# within a display. This catches the class of bug unit tests can't — the window not
# opening, opening blank-framed, opening duplicates, or (the reopen-after-close
# regression) opening off-screen/oversized so "Settings" appears to do nothing.
#
# It runs two scenarios:
#   open    (MONITORFLUX_OPEN_MAIN=1)      — the window opens once.
#   reopen  (MONITORFLUX_OPEN_MAIN=reopen) — open, close, then reopen; this is what users
#                                            hit clicking Settings again after closing.
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
# flickers the screen or fights f.lux/MonitorControl. The reopen scenario needs extra
# settle time because the app opens, closes, then reopens the window with runloop gaps.
run_scenario() {
  local mode="$1" settle="$2"
  echo "scenario: MONITORFLUX_OPEN_MAIN=$mode"
  # -g launches in the background; combined with the app's non-activating test path, the
  # window appears for CGWindowList without stealing focus from the developer's work.
  MONITORFLUX_SAFE_MODE=1 MONITORFLUX_OPEN_MAIN="$mode" /usr/bin/open -gn "$APP_BUNDLE"
  sleep "$settle"
  set +e
  swift "$ROOT_DIR/script/check_main_window.swift"
  local result=$?
  set -e
  pkill -x MonitorFlux >/dev/null 2>&1 || true
  sleep 1
  return "$result"
}

RESULT=0
run_scenario 1 2 || RESULT=1
run_scenario reopen 3 || RESULT=1

if [ "$RESULT" -eq 0 ]; then
  echo "smoke test: PASS"
else
  echo "smoke test: FAIL"
fi
exit "$RESULT"
