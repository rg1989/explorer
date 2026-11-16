#!/usr/bin/env bash
# make-dmg.sh — package Explorer.app into a distributable, drag-to-install .dmg.
#
# Usage:  ./make-dmg.sh
# Output: build/Explorer.dmg
#
# Then publish it so the landing page's "Download Explorer.dmg" button works:
#   gh release create v0.1.0 build/Explorer.dmg --title "Explorer 0.1.0" --notes "…"
#   # or upload to an existing release; the site points at
#   #   github.com/<you>/finder-2/releases/latest/download/Explorer.dmg
#
# Uses only hdiutil (ships with macOS) — no tools to install, no cost.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# Optional ARCH env produces a per-arch image, e.g. ARCH=arm64 → Explorer-arm64.dmg.
ARCH="${ARCH:-}"
SUFFIX=""
[[ -n "$ARCH" ]] && SUFFIX="-$ARCH"
APP="$ROOT/build/Explorer.app"
DMG="$ROOT/build/Explorer${SUFFIX}.dmg"
VOL="Explorer"

# Always compile a fresh release bundle (optionally for a specific arch).
echo "→ Building fresh release bundle${ARCH:+ ($ARCH)}…"
rm -rf "$APP"
ARCH="$ARCH" "$ROOT/build.sh" release >/dev/null

echo "→ Staging disk image contents…"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/Explorer.app"
ln -s /Applications "$STAGE/Applications"          # drag Explorer → Applications

echo "→ Building ${DMG}..."
rm -f "$DMG"
hdiutil create \
    -volname "$VOL" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

SIZE=$(du -h "$DMG" | cut -f1)
echo "✓ Built $DMG ($SIZE)"
echo "  Publish it to a GitHub release named so the URL ends in /Explorer.dmg."
