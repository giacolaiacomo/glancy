#!/bin/bash
# Launches the installed Glancy, lets it idle, then reports phys_footprint, CPU, wake-ups and
# child processes. Fails above the 40 MB budget (SPEC §1).
# Usage: scripts/footprint.sh [--demo] [--idle SECONDS]
set -euo pipefail

APP="$HOME/Applications/Glancy.app"
IDLE=60
LIMIT_MB=40
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --demo) ARGS+=(--demo) ;;
    --idle) IDLE="$2"; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -d "$APP" ]] || { echo "not installed: run scripts/build-app.sh first" >&2; exit 2; }

stop_app() {
  if pgrep -x Glancy >/dev/null; then
    osascript -e 'tell application id "ai.glancy.app" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do pgrep -x Glancy >/dev/null || return 0; sleep 0.1; done
    pkill -x Glancy 2>/dev/null || true
    for _ in $(seq 1 30); do pgrep -x Glancy >/dev/null || return 0; sleep 0.1; done
  fi
}

stop_app
if [[ ${#ARGS[@]} -gt 0 ]]; then open -n "$APP" --args "${ARGS[@]}"; else open -n "$APP"; fi
PID=""
for _ in $(seq 1 50); do PID="$(pgrep -x Glancy || true)"; [[ -n "$PID" ]] && break; sleep 0.1; done
[[ -n "$PID" ]] || { echo "Glancy did not start" >&2; exit 1; }
echo "Glancy pid $PID ${ARGS[*]:-} — idling ${IDLE}s"

# CPU: cumulative CPU time across the idle window (after a 5 s settle), as a percentage.
cpu_seconds() { ps -o time= -p "$PID" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
sleep 5
C0="$(cpu_seconds)"; T0="$(date +%s)"
sleep $((IDLE > 5 ? IDLE - 5 : 1))
C1="$(cpu_seconds)"; T1="$(date +%s)"
CPU="$(awk -v a="$C0" -v b="$C1" -v t=$((T1 - T0)) 'BEGIN { printf "%.2f", (b - a) / (t > 0 ? t : 1) * 100 }')"

# Footprint: `footprint` (phys_footprint), falling back to vmmap's summary.
FP_LINE="$(footprint -p "$PID" 2>/dev/null | grep -m1 -E 'phys_footprint:|Footprint:' || true)"
if [[ -z "$FP_LINE" ]]; then
  FP_LINE="$(vmmap --summary "$PID" 2>/dev/null | grep -m1 'Physical footprint:' || true)"
fi
FP_MB="$(echo "$FP_LINE" | awk '{
  for (i = 1; i <= NF; i++) if ($i ~ /^[0-9.]+$/ && $(i+1) ~ /^(B|KB|K|MB|M|GB|G)$/) { v = $i; u = $(i+1); break }
  else if ($i ~ /^[0-9.]+(K|M|G)$/) { v = substr($i, 1, length($i)-1); u = substr($i, length($i)); break }
  if (u ~ /^K/) v /= 1024; else if (u ~ /^G/) v *= 1024; else if (u == "B") v /= 1048576
  printf "%.1f", v }')"

# Wake-ups: top's idlew is cumulative; the difference over 10 s is the rate.
WAKE="$(top -l 2 -s 10 -pid "$PID" -stats pid,idlew 2>/dev/null | awk -v p="$PID" '
  $1 == p { gsub(/[^0-9]/, "", $2); v[n++] = $2 }
  END { if (n < 2) print "n/a"; else printf "%d in 10 s (%.1f/s)", v[1] - v[0], (v[1] - v[0]) / 10 }')"
CHILDREN="$(pgrep -P "$PID" | tr '\n' ' ' || true)"
CHILD_FP=""
for c in $CHILDREN; do
  CHILD_FP+="$(ps -o comm= -p "$c" | xargs basename) $(footprint "$c" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [KMG]B\).*/\1/p' | head -1)  "
done
# A frozen launch looks "light and idle": make sure the main thread reached the run loop.
HUNG="$(sample "$PID" 1 2>/dev/null | sed -n '/main-thread/,/Thread_/p' | grep -m1 -E 'applicationDidFinishLaunching|\.start\(hub:\)' || true)"

echo "phys_footprint: ${FP_MB:-?} MB   (${FP_LINE## })"
echo "cpu (avg over $((T1 - T0))s): ${CPU}%"
echo "idle wake-ups: $WAKE"
echo "child processes: ${CHILDREN:-none}${CHILD_FP:+  ($CHILD_FP)}"
if [[ -n "$HUNG" ]]; then echo "FAIL: main thread stuck in launch: $HUNG" >&2; exit 1; fi

if [[ ${#ARGS[@]} -gt 0 ]]; then
  # Leave the normal app running, as the user had it.
  stop_app; open "$APP"
fi

if [[ -z "$FP_MB" ]]; then echo "could not read the footprint" >&2; exit 1; fi
if awk -v v="$FP_MB" -v l="$LIMIT_MB" 'BEGIN { exit !(v > l) }'; then
  echo "FAIL: ${FP_MB} MB > ${LIMIT_MB} MB" >&2; exit 1
fi
echo "OK: ${FP_MB} MB ≤ ${LIMIT_MB} MB"
