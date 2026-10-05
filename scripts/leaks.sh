#!/bin/bash
# Runs the debug binary through `--selftest --exit` (hover → open → tab → settings → close, the real
# springs, ~5 s; the panel is visible on the notch meanwhile) under `leaks --atExit`, and reports.
# Fails when a leaked allocation has Glancy code on its stack; system-framework leaks are listed
# but do not fail the run.
#
# Isolation, so it runs beside the installed app without touching it:
# - CFFIXED_USER_HOME points the run at a temporary home: its own single-instance lock, shelf,
#   clipboard, timer and pid files; the real ones are never read or written.
# - Calendar is disabled for the run (its first start may show a permission prompt).
# - Media uses the installed app's adapter (symlinked) when present, else it is disabled too
#   (its AppleScript fallback could prompt for Automation).
# After the run: no perl child from this run may be left alive.
#
# Usage: scripts/leaks.sh [--no-build]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD=1
[[ "${1:-}" == "--no-build" ]] && BUILD=0

if [[ $BUILD -eq 1 ]]; then swift build 2>&1 | tail -1; fi
BIN="$ROOT/.build/debug/Glancy"
[[ -x "$BIN" ]] || { echo "no debug binary at $BIN" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/glancy-leaks.XXXXXX")"
HOME_DIR="$WORK/home"; ADAPTER="$WORK/adapter"
mkdir -p "$HOME_DIR" "$ADAPTER"
DISABLED="calendar"
INSTALLED="$HOME/Applications/Glancy.app/Contents"
if [[ -f "$INSTALLED/Resources/mediaremote-adapter.pl" && -d "$INSTALLED/Frameworks/MediaRemoteAdapter.framework" ]]; then
  ln -s "$INSTALLED/Resources/mediaremote-adapter.pl" "$ADAPTER/"
  ln -s "$INSTALLED/Frameworks/MediaRemoteAdapter.framework" "$ADAPTER/MediaRemoteAdapter.framework"
  [[ -x "$INSTALLED/MacOS/MediaRemoteAdapterTestClient" ]] && ln -s "$INSTALLED/MacOS/MediaRemoteAdapterTestClient" "$ADAPTER/"
else
  DISABLED="calendar,media"
fi

LOGDIR="$HOME/Library/Logs/Glancy"
mkdir -p "$LOGDIR"
OUT="$LOGDIR/leaks-$(date +%Y%m%d-%H%M%S).txt"
echo "leaks: $BIN --selftest --exit (disabled: $DISABLED) → $OUT"

CFFIXED_USER_HOME="$HOME_DIR" GLANCY_MEDIA_ADAPTER_DIR="$ADAPTER" MallocStackLogging=1 \
  leaks --atExit -- "$BIN" --selftest --exit -disabledModules "($DISABLED)" > "$OUT" 2>&1
LEAKS_STATUS=$?

# The selftest's own log (in the temporary home): every step's frame and state.
SELFTEST="$HOME_DIR/Library/Logs/Glancy/selftest.log"
if [[ -f "$SELFTEST" ]]; then
  echo "selftest steps: $(wc -l < "$SELFTEST" | tr -d ' ') (last: $(tail -1 "$SELFTEST" | sed 's/  */ /g'))"
else
  echo "selftest log missing (no notched display, or the run failed)"
fi

SUMMARY_LINE="$(grep -m1 -E '^Process [0-9]+: [0-9]+ leaks? for' "$OUT" || true)"
echo "${SUMMARY_LINE:-leaks: no summary line (status $LEAKS_STATUS) — see $OUT}"
TOTAL="$(echo "$SUMMARY_LINE" | sed -n 's/.*: \([0-9]*\) leaks\{0,1\} for.*/\1/p')"

# A leak is "ours" when a frame of its allocation stack is in the Glancy binary.
OURS="$(awk '
  /^STACK OF [0-9]+ INSTANCES? OF/ { if (stack != "" && ours) print stack; stack = $0; ours = 0; next }
  stack != "" { stack = stack "\n" $0; if ($0 ~ /Glancy(Kit)?[ .]|\(in Glancy\)/ && $0 !~ /leaks Report Version/) ours = 1 }
  /^$/ { if (stack != "" && ours) print stack "\n"; stack = ""; ours = 0 }
  END { if (stack != "" && ours) print stack }' "$OUT")"
OURS_COUNT="$(printf '%s' "$OURS" | grep -c '^STACK OF' || true)"

ORPHANS="$(pgrep -f "$ADAPTER" || true)"
if [[ -n "$ORPHANS" ]]; then
  echo "FAIL: perl child left running after quit: $ORPHANS"
  pkill -f "$ADAPTER" || true
fi

echo "leaked allocations: ${TOTAL:-?} total, ${OURS_COUNT} with Glancy code on the stack"
if [[ "$OURS_COUNT" -gt 0 ]]; then
  echo "--- ours ---"
  printf '%s\n' "$OURS" | head -80
fi
rm -rf "$WORK"
if [[ -z "$SUMMARY_LINE" || "$OURS_COUNT" -gt 0 || -n "$ORPHANS" ]]; then echo "leaks: FAIL"; exit 1; fi
echo "leaks: OK (report: $OUT)"
