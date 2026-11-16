#!/usr/bin/env bash
# snapshot.sh — render Explorer's UI to PNGs entirely off-screen, so you can
# check a visual change without a second monitor or the app stealing focus.
#
#   ./snapshot.sh                 # browser window at $HOME, light + dark, + Settings panes
#   ./snapshot.sh ~/Downloads     # browser window at a specific folder
#   FT_SNAPSHOT_THEMES=rascal-dark ./snapshot.sh   # one theme
#   FT_SNAPSHOT_W=900 FT_SNAPSHOT_H=600 ./snapshot.sh
#
# Output: build/snapshots/*.png (dir is wiped each run). Also, smoketest.sh
# will drop state screenshots into build/snapshots/smoke/ if you run it with
# FT_SNAPSHOT_DIR set:  FT_SNAPSHOT_DIR=build/snapshots/smoke ./smoketest.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/build/Explorer.app/Contents/MacOS/FinderTwo"

# Run from a copy with its own bundle id, so nothing the run writes lands in
# the installed app's preferences (dev.rg1989.Explorer).
TEST_APP="$ROOT/build/ExplorerTests.app"
if [[ -x "$BIN" ]]; then
    rm -rf "$TEST_APP" && cp -R "$ROOT/build/Explorer.app" "$TEST_APP"
    plutil -replace CFBundleIdentifier -string dev.rg1989.Explorer.tests "$TEST_APP/Contents/Info.plist"
    codesign --force --deep --sign - "$TEST_APP" >/dev/null 2>&1
    BIN="$TEST_APP/Contents/MacOS/FinderTwo"
fi
OUT="${FT_SNAPSHOT_OUT:-$ROOT/build/snapshots}"
TARGET="${1:-$HOME}"

if [[ ! -x "$BIN" ]]; then
    echo "Binary not built. Run ./build.sh first."
    exit 1
fi

rm -rf "$OUT"; mkdir -p "$OUT"
pkill -f "$BIN" 2>/dev/null || true
sleep 0.3

FT_HEADLESS_TESTING=1 FT_SNAPSHOT="$OUT" FT_SNAPSHOT_PATH="$TARGET" "$BIN"
status=$?
echo
ls -1 "$OUT"/*.png 2>/dev/null || echo "no snapshots produced"
exit $status
