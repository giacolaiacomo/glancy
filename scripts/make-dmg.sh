#!/usr/bin/env bash
# Builds a universal Glancy.app signed with Developer ID, notarizes and staples it, then wraps it
# in a signed, notarized, stapled DMG (drag to Applications).
#
#   scripts/make-dmg.sh            → dist/Glancy-<version>.dmg
#
# Needs, once:
#   - a "Developer ID Application" certificate in the login keychain (Xcode → Settings → Accounts →
#     Manage Certificates → + → Developer ID Application);
#   - notary credentials in the keychain:
#       xcrun notarytool store-credentials glancy --apple-id <email> --team-id <TEAM> --password <app-specific>
#     (profile name overridable with GLANCY_NOTARY_PROFILE).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${GLANCY_NOTARY_PROFILE:-glancy}"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(Developer ID Application: .*\)"$/\1/p' | head -n 1)"
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application certificate in the keychain" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
  || { echo "no notary credentials: xcrun notarytool store-credentials $PROFILE …" >&2; exit 1; }

VERSION="${GLANCY_VERSION:-$(sed -n 's/^VERSION="\${GLANCY_VERSION:-\(.*\)}"$/\1/p' "$ROOT/scripts/build-app.sh")}"
export GLANCY_VERSION="$VERSION"
DIST="$ROOT/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DIST"

echo "==> build + sign ($IDENTITY)"
GLANCY_SIGN_IDENTITY="$IDENTITY" UNIVERSAL=1 "$ROOT/scripts/build-app.sh" "$WORK/Glancy.app"

echo "==> notarize app"
ditto -c -k --keepParent "$WORK/Glancy.app" "$WORK/Glancy.zip"
xcrun notarytool submit "$WORK/Glancy.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$WORK/Glancy.app"

echo "==> dmg"
mkdir "$WORK/dmg"
ditto "$WORK/Glancy.app" "$WORK/dmg/Glancy.app"
ln -s /Applications "$WORK/dmg/Applications"
DMG="$DIST/Glancy-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Glancy" -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
codesign --force --timestamp -s "$IDENTITY" "$DMG"

echo "==> notarize dmg"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> verify"
spctl -a -t open --context context:primary-signature -v "$DMG"
spctl -a -t exec -v "$WORK/Glancy.app"
shasum -a 256 "$DMG"
echo "built $DMG"
