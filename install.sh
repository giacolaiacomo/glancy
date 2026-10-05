#!/bin/zsh
# Build Glancy.app into ~/Applications, open it at login and start it.
# Needs the Swift toolchain (xcode-select --install) and cmake (brew install cmake).
set -e
cd "$(dirname "$0")"

APP="$HOME/Applications/Glancy.app"
if pgrep -x Glancy >/dev/null; then
  echo "→ Quitting the running Glancy…"
  osascript -e 'tell application id "ai.glancy.app" to quit' >/dev/null 2>&1 || true
  for _ in {1..30}; do pgrep -x Glancy >/dev/null || break; sleep 0.1; done
  pkill -x Glancy 2>/dev/null || true
fi

echo "→ Building…"
mkdir -p "$HOME/Applications"
./scripts/build-app.sh "$APP"

# The same login item as Settings › Open at login (you can turn it off there).
"$APP/Contents/MacOS/Glancy" --login-item on || echo "  (turn on Open at login in Glancy's settings)"
open "$APP"
echo "✓ Glancy installed in ~/Applications and running: look at the notch."
