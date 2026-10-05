#!/bin/zsh
# Regenerate the README images (docs/) from the real UI, filled with made-up demo data
# (glancy-render --demo) so that no real sessions, events, music, clipboard or windows end up in them.
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

swift build --product glancy-render
"$(swift build --show-bin-path)/glancy-render" "$TMP/renders" --demo >/dev/null
swift scripts/make-icon.swift "$TMP/AppIcon.iconset" >/dev/null
cp "$TMP/AppIcon.iconset/icon_512x512.png" "$TMP/icon.png"
swift scripts/compose.swift "$TMP/renders" "$TMP/icon.png" "$TMP"

mkdir -p docs
sips -Z 256 "$TMP/icon.png" --out docs/icon.png >/dev/null
# JPEG keeps the README light
sips -s format jpeg -s formatOptions 84 "$TMP/hero.png" --out docs/hero.jpg >/dev/null
sips -s format jpeg -s formatOptions 84 "$TMP/screens.png" --out docs/screens.jpg >/dev/null
# GitHub social preview: 1280×640, must stay under 1 MB
sips -z 640 1280 -s format jpeg -s formatOptions 88 "$TMP/hero.png" --out docs/social-preview.jpg >/dev/null
ls -lh docs/*.jpg docs/*.png
