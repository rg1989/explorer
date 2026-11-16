#!/usr/bin/env bash
# Builds Explorer (this fork of Rascal) and installs /Applications/Explorer.app.
# Unlike install.sh it adds no command-line tool and never uses sudo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="/Applications/Explorer.app"

"$ROOT/build.sh" release
codesign --verify --deep --strict "$ROOT/build/Explorer.app"

pkill -f "$DEST/Contents/MacOS/FinderTwo" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$ROOT/build/Explorer.app" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" || true
echo "✓ Installed $DEST"
