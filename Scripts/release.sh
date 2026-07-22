#!/bin/bash
# Build, assemble, and Developer ID-sign ClipDeck.app for notarized release.
#
# Dev/dogfood builds use bundle.sh (Apple Development identity, no hardened
# runtime) so the Accessibility grant survives rebuilds. THIS script is for
# distribution only: it signs with the Developer ID Application identity plus
# the hardened runtime and a secure timestamp, which the notary service
# requires. It carries NO credentials — notarization (which needs the App
# Store Connect API key) is run as a separate, un-committed step.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/ClipDeck.app"
SWIFT=/usr/bin/swift

"$SWIFT" build -c release --package-path "$ROOT"
BIN="$("$SWIFT" build -c release --package-path "$ROOT" --show-bin-path)/ClipMateApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN" "$APP/Contents/MacOS/ClipMateApp"

# --options runtime (hardened runtime) and --timestamp (secure timestamp) are
# both mandatory for the notary service to accept the build. The app needs no
# entitlements: the Accessibility API and CGEvent posting are gated by the
# runtime TCC grant, not by hardened-runtime entitlements.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"

if [ -z "$IDENTITY" ]; then
    echo "ERROR: no 'Developer ID Application' identity in the keychain." >&2
    echo "       Create one in Xcode > Settings > Accounts > Manage Certificates." >&2
    exit 1
fi

codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
echo "Signed with: $IDENTITY"

codesign --verify --strict --verbose=2 "$APP"
echo "Built and signed $APP"
