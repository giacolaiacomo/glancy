#!/bin/bash
# End-to-end check of in-app updates, beside (never touching) the installed Glancy:
#   1. builds two universal, Developer ID signed copies with bundle id ai.glancy.updtest:
#      A = 0.2.90 and B = 0.2.91, both in lab mode (--lab: no lock, hot keys, prompts; the surface
#      off-screen) through LSEnvironment, so the copy Sparkle relaunches is a lab copy too;
#   2. packs B in a DMG, writes an appcast signed with the real EdDSA key (login keychain) and
#      serves it on 127.0.0.1 with python3 -m http.server;
#   3. opens A, whose launch check (GLANCY_UPDATE_UNATTENDED: every answer is "install") downloads,
#      verifies, installs B over A and relaunches;
#   4. proves the running process is B (Launch Services' record of the pid, the unified log,
#      codesign, spctl), then quits it, stops the server and removes the updtest preferences.
#
#   scripts/update-e2e.sh <scratch folder>
# Not notarized: Sparkle installs a local, non-quarantined update without Gatekeeper's approval.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${1:?usage: update-e2e.sh <scratch folder>}"
ID="ai.glancy.updtest"
PORT="${GLANCY_E2E_PORT:-8765}"
FEED="http://127.0.0.1:$PORT/appcast.xml"
rm -rf "$WORK"; mkdir -p "$WORK/A" "$WORK/B" "$WORK/feed" "$WORK/lab"
WORK="$(cd "$WORK" && pwd)"
APP="$WORK/A/Glancy.app"
TESTENV="GLANCY_LAB=1 GLANCY_LAB_HOME=$WORK/lab GLANCY_UPDATE_FEED=$FEED GLANCY_UPDATE_UNATTENDED=1"
SERVER=""; RUNNING=""
cleanup() {
  [[ -n "$SERVER" ]] && kill "$SERVER" 2>/dev/null || true
  # Only the copy this script opened (its own path), never anything by name.
  for pid in $(pgrep -f "$APP/Contents/MacOS/Glancy" || true); do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 1   # let the test copy quit and cfprefsd flush, then remove what it left
  defaults delete "$ID" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$ID.plist"
  rm -rf "$HOME/Library/Caches/$ID" "$HOME/Library/HTTPStorages/$ID" "$HOME/Library/HTTPStorages/$ID.binarycookies" \
    "$HOME/Library/Saved Application State/$ID.savedState"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true
}
trap cleanup EXIT

build() {   # build <version> <out>
  GLANCY_BUNDLE_ID="$ID" GLANCY_VERSION="$1" UNIVERSAL=1 GLANCY_TEST_ENV="$TESTENV" \
    "$ROOT/scripts/build-app.sh" "$2" 2>&1 | grep -E "^==> codesign|^built" || true
  [[ -d "$2" ]] || { echo "build of $1 failed" >&2; exit 1; }
}
echo "== build A 0.2.90 and B 0.2.91 ($ID, universal)"
build 0.2.90 "$APP"
build 0.2.91 "$WORK/B/Glancy.app"

echo "== feed: B's DMG + appcast signed with the real EdDSA key"
DMG="$WORK/feed/Glancy-0.2.91.dmg"
hdiutil create -quiet -volname Glancy -srcfolder "$WORK/B/Glancy.app" -fs HFS+ -format UDZO "$DMG"
echo "<p>Glancy 0.2.91 (test)</p>" > "$WORK/feed/notes.html"
GLANCY_APPCAST_URL_BASE="http://127.0.0.1:$PORT" GLANCY_APPCAST_NOTES="http://127.0.0.1:$PORT/notes.html" \
  "$ROOT/scripts/make-appcast.sh" "$DMG" 0.2.91 "$WORK/feed/appcast.xml"
grep -E "sparkle:version|shortVersionString|enclosure" "$WORK/feed/appcast.xml" | sed 's/^ *//'
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/feed" > "$WORK/server.log" 2>&1 &
SERVER=$!
for _ in $(seq 1 50); do curl -fsS "$FEED" >/dev/null 2>&1 && break; sleep 0.1; done

echo "== A before"
defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString
START="$(date '+%Y-%m-%d %H:%M:%S')"
open -n "$APP"
for _ in $(seq 1 100); do RUNNING="$(pgrep -f "$APP/Contents/MacOS/Glancy" || true)"; [[ -n "$RUNNING" ]] && break; sleep 0.1; done
[[ -n "$RUNNING" ]] || { echo "A did not start" >&2; exit 1; }
sleep 0.5
echo "A running, pid $RUNNING: $(lsappinfo info -only version "$(lsappinfo find pid=$RUNNING)" 2>/dev/null)"

echo "== waiting for the update (launch check after 3 s, download, install, relaunch)"
NEW=""
for _ in $(seq 1 240); do
  sleep 0.5
  pid="$(pgrep -f "$APP/Contents/MacOS/Glancy" || true)"
  if [[ -n "$pid" && "$pid" != "$RUNNING" ]]; then NEW="$pid"; break; fi
done
[[ -n "$NEW" ]] || { echo "no relaunch within 120 s" >&2; /usr/bin/log show --start "$START" --predicate 'subsystem == "ai.glancy.updates" OR subsystem == "org.sparkle-project.Sparkle" OR process == "Autoupdate"' --style compact | tail -40; exit 1; }
sleep 6   # B's own launch check: finds nothing newer

echo "== B after (pid $NEW, A was $RUNNING)"
echo "process: $(ps -o pid=,command= -p "$NEW")"
echo "launch services: $(lsappinfo info -only version "$(lsappinfo find pid=$NEW)") $(lsappinfo info -only bundleid "$(lsappinfo find pid=$NEW)")"
echo "bundle on disk: $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) ($(defaults read "$APP/Contents/Info.plist" CFBundleVersion))"
echo "-- unified log"
/usr/bin/log show --start "$START" --predicate 'subsystem == "ai.glancy.updates" OR (subsystem == "org.sparkle-project.Sparkle" AND NOT eventMessage CONTAINS "HTTPS")' --style compact \
  | grep -v "^Timestamp" || true
echo "-- codesign"
codesign -dvv "$APP" 2>&1 | grep -E "^Identifier|^Authority=Developer|^TeamIdentifier|^Runtime|^Timestamp|flags="
codesign --verify --strict --deep "$APP" && echo "codesign --verify --strict --deep: ok"
echo "-- spctl"
spctl -a -t exec -vv "$APP" 2>&1 || true
echo "-- feed requests"
cat "$WORK/server.log"
