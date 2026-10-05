#!/bin/zsh
# Stop Glancy and remove the app, its login item, its data, its settings and its permissions.
# Asks nothing; prints what it removes. The Claude Code hook log (~/.claude/hooks/data) is not Glancy's
# and is left alone.
APP="$HOME/Applications/Glancy.app"
ID=ai.glancy.app

if pgrep -x Glancy >/dev/null; then
  echo "→ Quitting Glancy"
  osascript -e "tell application id \"$ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..30}; do pgrep -x Glancy >/dev/null || break; sleep 0.1; done
  pkill -x Glancy 2>/dev/null || true
fi

for app in "$APP" "/Applications/Glancy.app"; do
  [[ -x "$app/Contents/MacOS/Glancy" ]] || continue
  echo "→ Login item: off"
  "$app/Contents/MacOS/Glancy" --login-item off >/dev/null 2>&1 || true
done

remove() {
  [[ -e "$1" ]] || return 0
  echo "→ Removing $1"
  rm -rf "$1"
}
remove "$APP"
[[ -w /Applications/Glancy.app ]] && remove /Applications/Glancy.app
remove "$HOME/Library/Application Support/Glancy"   # clipboard history, shelf, timer, window layouts
remove "$HOME/Library/Logs/Glancy"
remove "$HOME/Library/Caches/$ID"
remove "$HOME/Library/HTTPStorages/$ID"

if defaults read "$ID" >/dev/null 2>&1; then
  echo "→ Removing settings (defaults $ID)"
  defaults delete "$ID" >/dev/null 2>&1 || true
fi
echo "→ Resetting permissions granted to $ID (Accessibility, Calendar, Automation, Bluetooth…)"
tccutil reset All "$ID" >/dev/null 2>&1 || true

echo "✓ Glancy removed."
