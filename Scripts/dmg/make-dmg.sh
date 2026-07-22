#!/bin/bash
# Package a built ClipDeck.app into a laid-out DMG: custom window background
# with an arrow pointing at an Applications drop target, icon positions baked
# into the .DS_Store. Produces an UNSIGNED dmg; sign, notarize, and staple it
# afterward (see the release runbook). Contains NO credentials.
#
# Usage: Scripts/dmg/make-dmg.sh <path-to-ClipDeck.app> <output.dmg>
#
# dmgbuild writes the layout directly (no Finder/AppleScript, so nothing pops
# on screen). It lives in a throwaway venv so the repo keeps no Python deps.
set -euo pipefail

APP="${1:?usage: make-dmg.sh <ClipDeck.app> <output.dmg>}"
OUT="${2:?usage: make-dmg.sh <ClipDeck.app> <output.dmg>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# 1. Render the window background (1x + @2x) and fold into a HiDPI TIFF.
/usr/bin/swift "$HERE/render_bg.swift" "$STAGE"
/usr/bin/tiffutil -cathidpicheck "$STAGE/bg.png" "$STAGE/bg@2x.png" -out "$STAGE/background.tiff"

# 2. Build the DMG with dmgbuild.
VENV="$STAGE/venv"
/usr/bin/python3 -m venv "$VENV"
"$VENV/bin/python3" -m pip install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet dmgbuild pyobjc-framework-Quartz

rm -f "$OUT"
APP_PATH="$APP" BG_TIFF="$STAGE/background.tiff" \
  "$VENV/bin/dmgbuild" -s "$HERE/settings.py" "ClipDeck" "$OUT"

echo "Built $OUT"
