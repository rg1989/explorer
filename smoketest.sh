#!/usr/bin/env bash
# Runs Explorer's in-process test runner. The app is launched with
# FT_RUN_TESTS=1 (which makes it skip opening the default window and
# instead execute the TestRunner harness) and FT_HEADLESS_TESTING=1
# (which keeps any windows the harness creates far off-screen, so this
# never disrupts your foreground work).
#
# Exit code = number of failed assertions.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/Explorer.app"
BIN="$APP/Contents/MacOS/FinderTwo"

# Run from a copy with its own bundle id, so nothing the run writes lands in
# the installed app's preferences (dev.rg1989.Explorer).
TEST_APP="$ROOT/build/ExplorerTests.app"
if [[ -x "$BIN" ]]; then
    rm -rf "$TEST_APP" && cp -R "$ROOT/build/Explorer.app" "$TEST_APP"
    plutil -replace CFBundleIdentifier -string dev.rg1989.Explorer.tests "$TEST_APP/Contents/Info.plist"
    codesign --force --deep --sign - "$TEST_APP" >/dev/null 2>&1
    BIN="$TEST_APP/Contents/MacOS/FinderTwo"
fi

if [[ ! -x "$BIN" ]]; then
    echo "Binary not built. Run ./build.sh first."
    exit 1
fi

pkill -f "$BIN" 2>/dev/null || true
sleep 0.3

FT_RUN_TESTS=1 FT_HEADLESS_TESTING=1 "$BIN"
