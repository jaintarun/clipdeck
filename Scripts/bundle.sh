#!/bin/bash
# Assemble ClipMate.app from the SPM build. Mirrors what the spike proved.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ClipMate.app"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/ClipMateApp"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/ClipMateApp"

# Sign with a real identity when one exists, because TCC pins the Accessibility
# grant to the app's *designated requirement*, and the two signing modes produce
# very different ones (both measured with `codesign -d -r-`):
#
#   ad-hoc   => cdhash H"54305b65..."
#   identity => identifier "com.clipmateclone.app" and anchor apple generic
#               and certificate leaf[subject.CN] = "Apple Development: ..."
#
# The ad-hoc requirement is the binary's own hash, so EVERY rebuild produces a
# new cdhash that no longer satisfies the stored grant. The symptom is nasty:
# System Settings keeps showing the toggle ON while AXIsProcessTrusted() returns
# false, because the grant now authorises a binary that no longer exists. This
# cost a real debugging session on 2026-07-16, and would silently break the
# grant on every rebuild during dogfooding. The identity-based requirement
# contains no cdhash, so it survives rebuilds.
#
# Falls back to ad-hoc so the build still works on a machine with no identity,
# but warns — because there the grant must be re-approved after each rebuild.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"

if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "WARNING: no codesigning identity found — signed ad-hoc."
    echo "         The Accessibility grant will be invalidated by every rebuild."
fi

echo "Built $APP"
echo "Run: open $APP"
