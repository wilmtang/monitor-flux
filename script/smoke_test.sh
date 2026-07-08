#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 wilmtang. Part of MonitorFlux, free software under the GNU
# Affero General Public License v3.0 or later. See LICENSE. No warranty.

set -euo pipefail

# End-to-end smoke test: builds the app, launches it driving the detailed window, and
# asserts via CGWindowList that exactly one sizable window is on screen and substantially
# within a display. This catches the class of bug unit tests can't — the window not
# opening, opening blank-framed, opening duplicates, or (the reopen-after-close
# regression) opening off-screen/oversized so "Settings" appears to do nothing.
#
# It runs three scenarios:
#   open    (MONITORFLUX_OPEN_MAIN=1)      — the window opens once.
#   reopen  (MONITORFLUX_OPEN_MAIN=reopen) — open, close, then reopen; this is what users
#                                            hit clicking Settings again after closing.
#   dock    (MONITORFLUX_FORCE_DOCK)       — launch once with the Dock forced on and once
#                                            off; the LaunchServices app type must be
#                                            Foreground then UIElement, with the window on
#                                            screen either way. Guards the bug where an open
#                                            titled window pinned the Dock icon and the
#                                            toggle looked dead, and that accessory mode
#                                            still opens and places its window.
#
# For deeper UI assertions ("a Brightness slider exists and moving it changes state"),
# use XCUITest, which needs an Xcode app+UITest target — see README/AGENTS.md.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/MonitorFlux.app"

pkill -x MonitorFlux >/dev/null 2>&1 || true

# Build + sign the bundle without launching it (the scenarios below do their own launches).
"$ROOT_DIR/script/build_and_run.sh" --bundle >/dev/null 2>&1 || true

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

# LaunchServices reports "Foreground" while the app has a Dock icon and "UIElement"
# while it's a menu-bar accessory — the closest external observer of the Dock icon.
app_type() {
  lsappinfo info MonitorFlux 2>/dev/null | sed -n 's/.*type="\([^"]*\)".*/\1/p'
}

# Launch once with the Dock policy forced by MONITORFLUX_FORCE_DOCK, open the window, and
# assert both the LaunchServices app type and that the window is on screen. Forcing the
# policy via env (rather than toggling at runtime) pins the launch path deterministically
# without rewriting the developer's saved preference.
run_dock_case() {
  local force="$1" want_type="$2" result=0 got_type
  echo "scenario: MONITORFLUX_FORCE_DOCK=$force (expect $want_type)"
  MONITORFLUX_SAFE_MODE=1 MONITORFLUX_OPEN_MAIN=1 MONITORFLUX_FORCE_DOCK="$force" \
    /usr/bin/open -gn "$APP_BUNDLE"
  sleep 2
  got_type="$(app_type)"
  if [ "$got_type" != "$want_type" ]; then
    echo "FAIL: expected $want_type with Show in Dock $force, got '$got_type'"
    result=1
  fi
  # The window must be on screen in either policy — accessory mode (Dock off) has no
  # Dock icon but must still open and place its window, which is the mode the refactor
  # relies on activate()/orderFrontRegardless() for.
  set +e
  swift "$ROOT_DIR/script/check_main_window.swift"
  [ $? -eq 0 ] || result=1
  set -e
  pkill -x MonitorFlux >/dev/null 2>&1 || true
  sleep 1
  return "$result"
}

run_dock_scenario() {
  local result=0
  run_dock_case on Foreground || result=1
  run_dock_case off UIElement || result=1
  return "$result"
}

RESULT=0
run_scenario 1 2 || RESULT=1
run_scenario reopen 3 || RESULT=1
run_dock_scenario || RESULT=1

if [ "$RESULT" -eq 0 ]; then
  echo "smoke test: PASS"
else
  echo "smoke test: FAIL"
fi
exit "$RESULT"
