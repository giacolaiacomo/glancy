#!/usr/bin/env bash
# Builds a universal Glancy.app signed with Developer ID, notarizes and staples it, then wraps it
# in a signed, notarized, stapled DMG (drag to Applications).
#
#   GLANCY_VERSION=X.Y.Z scripts/make-dmg.sh   → dist/Glancy-X.Y.Z.dmg + dist/Glancy.dmg + dist/appcast.xml
#
# dist/Glancy.dmg is a byte-for-byte copy of the versioned DMG under a stable name: attach it to
# every release too, so https://github.com/giacolaiacomo/glancy/releases/latest/download/Glancy.dmg
# (the README's Download button) always serves the newest version. Sparkle's appcast keeps
# pointing at the versioned file.
#
# The appcast (scripts/make-appcast.sh) points Sparkle at the DMG of release vX.Y.Z and carries its
# EdDSA signature: the private key must be in the login keychain (Sparkle's generate_keys, account
# "glancy"; the first signing may ask for keychain access). Attach all three files to the release.
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
DMG="$DIST/Glancy-$VERSION.dmg"
rm -f "$DMG"
# The window: background with the arrow, the app on the left, Applications on the right (dmgbuild
# writes the Finder layout directly, no Finder scripting). It lives in a venv under .build.
VENV="$ROOT/.build/dmgvenv"
[[ -x "$VENV/bin/dmgbuild" ]] || { python3 -m venv "$VENV" && "$VENV/bin/pip" -q install dmgbuild; }
swift "$ROOT/scripts/make-dmg-background.swift" "$WORK"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D app="$WORK/Glancy.app" \
  -D background="$WORK/background.png" "Glancy" "$DMG" >/dev/null
codesign --force --timestamp -s "$IDENTITY" "$DMG"

echo "==> notarize dmg"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> verify"
spctl -a -t open --context context:primary-signature -v "$DMG"
spctl -a -t exec -v "$WORK/Glancy.app"
shasum -a 256 "$DMG"
echo "built $DMG"

echo "==> stable name for the README's download link"
STABLE="$DIST/Glancy.dmg"
cp -f "$DMG" "$STABLE"
cmp -s "$DMG" "$STABLE" || { echo "copy to $STABLE differs from $DMG" >&2; exit 1; }
echo "built $STABLE (same bytes)"

echo "==> appcast (EdDSA-signed, the stapled DMG as shipped)"
"$ROOT/scripts/make-appcast.sh" "$DMG" "$VERSION" "$DIST/appcast.xml"
