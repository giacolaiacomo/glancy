#!/bin/bash
# Writes the Sparkle appcast for one release: a single <item> pointing at the DMG attached to the
# GitHub release, EdDSA-signed with the private key in the login keychain (Sparkle's sign_update,
# account "glancy"). Glancy reads it from
#   https://github.com/giacolaiacomo/glancy/releases/latest/download/appcast.xml
# so the newest release always carries the current appcast.
#
#   scripts/make-appcast.sh <Glancy-X.Y.Z.dmg> <X.Y.Z> <out/appcast.xml>
#
# Environment:
#   GLANCY_APPCAST_URL_BASE   download folder (default: the release's own,
#                             https://github.com/giacolaiacomo/glancy/releases/download/vX.Y.Z)
#   GLANCY_APPCAST_NOTES      release-notes link (default: the GitHub release page)
#   GLANCY_APPCAST_SIGNATURE  'sparkle:edSignature="…" length="…"' instead of signing (tests only)
#   GLANCY_SPARKLE_ACCOUNT    keychain account of the EdDSA key (default "glancy")
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE="${1:?usage: make-appcast.sh <archive> <version> <out.xml>}"
VERSION="${2:?usage: make-appcast.sh <archive> <version> <out.xml>}"
OUT="${3:?usage: make-appcast.sh <archive> <version> <out.xml>}"
[[ -f "$ARCHIVE" ]] || { echo "make-appcast: no archive at $ARCHIVE" >&2; exit 1; }

BUILD="$("$ROOT/scripts/build-number.sh" "$VERSION")"
REPO="https://github.com/giacolaiacomo/glancy"
BASE="${GLANCY_APPCAST_URL_BASE:-$REPO/releases/download/v$VERSION}"
NOTES="${GLANCY_APPCAST_NOTES:-$REPO/releases/tag/v$VERSION}"
NAME="$(basename "$ARCHIVE")"

if [[ -n "${GLANCY_APPCAST_SIGNATURE:-}" ]]; then
  SIG="$GLANCY_APPCAST_SIGNATURE"
else
  SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
  [[ -x "$SIGN_UPDATE" ]] || { echo "make-appcast: $SIGN_UPDATE missing (swift package resolve)" >&2; exit 1; }
  SIG="$("$SIGN_UPDATE" --account "${GLANCY_SPARKLE_ACCOUNT:-glancy}" "$ARCHIVE")"
fi
[[ "$SIG" =~ sparkle:edSignature=\"[^\"]+\"\ length=\"[0-9]+\" ]] \
  || { echo "make-appcast: unexpected signature output: $SIG" >&2; exit 1; }

DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Glancy</title>
    <link>$REPO</link>
    <description>Glancy updates</description>
    <language>en</language>
    <item>
      <title>Glancy $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$NOTES</sparkle:releaseNotesLink>
      <sparkle:fullReleaseNotesLink>$REPO/releases</sparkle:fullReleaseNotesLink>
      <enclosure url="$BASE/$NAME" $SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$OUT"
echo "appcast $OUT ($VERSION, build $BUILD)"
