#!/bin/bash
# Builds Glancy.app (release) and signs it. Used by install.sh, the Homebrew formula and the release
# workflow.
#
#   scripts/build-app.sh <path/Glancy.app>     build the app at that path, nothing else
#   scripts/build-app.sh [--no-launch] [-- app args…]
#                                              no path: build, install to ~/Applications and relaunch
#
# UNIVERSAL=1 builds one binary for Apple Silicon and Intel (the bundled mediaremote-adapter is
# always built for both). Needs the Swift toolchain (xcode-select --install) and cmake.
#
# Signing, first match wins:
#   1. GLANCY_SIGN_IDENTITY, e.g. "Developer ID Application: …" or "-" for ad-hoc;
#   2. the first "Apple Development" identity in your keychain. A stable signature keeps the
#      permissions you granted (Accessibility, Calendar…) across rebuilds;
#   3. ad-hoc ("-"). It runs fine, but macOS sees every rebuild as a new app, so permissions
#      have to be granted again after each update.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="ai.glancy.app"
VERSION="${GLANCY_VERSION:-0.1.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
OUT=""
LAUNCH=1
APP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-launch) LAUNCH=0 ;;
    --) shift; APP_ARGS=("$@"); break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) OUT="$1" ;;
  esac
  shift
done

if [[ -n "${GLANCY_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$GLANCY_SIGN_IDENTITY"
else
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(Apple Development: .*\)"$/\1/p' | head -n 1)"
  IDENTITY="${IDENTITY:--}"
fi

command -v swift >/dev/null || { echo "swift not found: run xcode-select --install" >&2; exit 1; }
command -v cmake >/dev/null || { echo "cmake not found: brew install cmake" >&2; exit 1; }

cd "$ROOT"
if [[ -n "${UNIVERSAL:-}" ]]; then ARCHS=(arm64 x86_64); else ARCHS=("$(uname -m)"); fi
# --disable-sandbox: SwiftPM's own manifest sandbox can't nest inside Homebrew's (no dependencies to fetch).
BINS=()
for arch in "${ARCHS[@]}"; do
  echo "==> swift build -c release ($arch)"
  swift build --disable-sandbox -c release --arch "$arch" --product Glancy
  BINS+=("$(swift build --disable-sandbox -c release --arch "$arch" --show-bin-path)/Glancy")
done

if [[ -n "$OUT" ]]; then STAGE="$OUT"; else STAGE="$ROOT/build/Glancy.app"; fi
echo "==> assembling $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
if [[ ${#BINS[@]} -gt 1 ]]; then
  lipo -create "${BINS[@]}" -output "$STAGE/Contents/MacOS/Glancy"
else
  cp "${BINS[0]}" "$STAGE/Contents/MacOS/Glancy"
fi

# SwiftPM resource bundles, if any target ever declares resources.
for b in "$(dirname "${BINS[0]}")"/*.bundle; do
  [[ -e "$b" ]] && cp -R "$b" "$STAGE/Contents/Resources/"
done

echo "==> mediaremote-adapter (Vendor/mediaremote-adapter, BSD-3): bundled, not linked; arm64 + x86_64"
ADAPTER_SRC="$ROOT/Vendor/mediaremote-adapter"
ADAPTER_BUILD="$ROOT/build/mediaremote-adapter"
# A cache configured from another checkout path would refuse to build: start it fresh.
if [[ -f "$ADAPTER_BUILD/CMakeCache.txt" ]] && ! grep -qx "CMAKE_HOME_DIRECTORY:INTERNAL=$ADAPTER_SRC" "$ADAPTER_BUILD/CMakeCache.txt"; then
  rm -rf "$ADAPTER_BUILD"
fi
cmake -S "$ADAPTER_SRC" -B "$ADAPTER_BUILD" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" >/dev/null
cmake --build "$ADAPTER_BUILD" >/dev/null
cp "$ADAPTER_SRC/bin/mediaremote-adapter.pl" "$STAGE/Contents/Resources/mediaremote-adapter.pl"
ditto "$ADAPTER_BUILD/MediaRemoteAdapter.framework" "$STAGE/Contents/Frameworks/MediaRemoteAdapter.framework"
cp "$ADAPTER_BUILD/MediaRemoteAdapterTestClient" "$STAGE/Contents/MacOS/MediaRemoteAdapterTestClient"

echo "==> icon"
ICONTMP="$(mktemp -d)"
swift "$ROOT/scripts/make-icon.swift" "$ICONTMP/AppIcon.iconset"
iconutil -c icns "$ICONTMP/AppIcon.iconset" -o "$STAGE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONTMP"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>Glancy</string>
	<key>CFBundleDisplayName</key><string>Glancy</string>
	<key>CFBundleExecutable</key><string>Glancy</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>$VERSION</string>
	<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleLocalizations</key><array><string>en</string><string>it</string></array>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSUIElement</key><true/>
	<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSSupportsAutomaticTermination</key><false/>
	<key>NSSupportsSuddenTermination</key><false/>
	<key>NSCalendarsFullAccessUsageDescription</key><string>Glancy shows your next meeting and a Join button in the notch.</string>
	<key>NSCalendarsUsageDescription</key><string>Glancy shows your next meeting and a Join button in the notch.</string>
	<key>NSAppleEventsUsageDescription</key><string>Glancy reads what Music and Spotify are playing and controls playback from the notch, and switches dark mode, empties the Trash or sends a note to Apple Notes when you ask.</string>
	<key>NSCameraUsageDescription</key><string>Glancy shows your camera as a mirror in the notch, only while the mirror is open.</string>
	<key>NSMicrophoneUsageDescription</key><string>Glancy records voice notes when you ask, and mutes and unmutes your microphone from the notch.</string>
	<key>NSSpeechRecognitionUsageDescription</key><string>Glancy turns your voice notes into text on this Mac. The audio never leaves it.</string>
	<key>NSDesktopFolderUsageDescription</key><string>Glancy shows a new screenshot in the notch the moment it lands on your Desktop.</string>
	<key>NSDownloadsFolderUsageDescription</key><string>Glancy shows a finished download in the notch.</string>
	<key>NSBluetoothAlwaysUsageDescription</key><string>Glancy shows when your headphones connect and how much battery they have.</string>
	<key>NSHumanReadableCopyright</key><string>© 2026 Glancy contributors. MIT License.</string>
</dict>
</plist>
PLIST
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null

if [[ "$IDENTITY" == "-" ]]; then echo "==> codesign (ad-hoc)"; else echo "==> codesign ($IDENTITY)"; fi
# Nested adapter code first, same identity (boring.notch #998: a mismatch stops perl loading it).
codesign --force --timestamp=none -s "$IDENTITY" "$STAGE/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$STAGE/Contents/MacOS/MediaRemoteAdapterTestClient"
codesign --force --deep --options runtime --timestamp=none \
  --entitlements "$ROOT/scripts/Glancy.entitlements" -s "$IDENTITY" "$STAGE"
codesign --verify --strict "$STAGE"
echo "built $STAGE ($(lipo -archs "$STAGE/Contents/MacOS/Glancy"))"

# A path was given: that's all.
[[ -n "$OUT" ]] && exit 0

DEST="$HOME/Applications/Glancy.app"
echo "==> installing to $DEST"
if pgrep -x Glancy >/dev/null; then
  osascript -e 'tell application id "ai.glancy.app" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do pgrep -x Glancy >/dev/null || break; sleep 0.1; done
  pkill -x Glancy 2>/dev/null || true
  for _ in $(seq 1 30); do pgrep -x Glancy >/dev/null || break; sleep 0.1; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$STAGE" "$DEST"
codesign -dr - "$DEST" 2>&1 | sed -n 's/^designated => /designated requirement: /p'

if [[ $LAUNCH -eq 1 ]]; then
  echo "==> launching"
  if [[ ${#APP_ARGS[@]} -gt 0 ]]; then open -n "$DEST" --args "${APP_ARGS[@]}"; else open "$DEST"; fi
  for _ in $(seq 1 50); do pgrep -x Glancy >/dev/null && break; sleep 0.1; done
  if pid="$(pgrep -x Glancy)"; then echo "running, pid $pid"; else echo "Glancy did not start" >&2; exit 1; fi
fi
