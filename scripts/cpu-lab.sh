#!/bin/bash
# CPU lab: what a closed notch costs, per live state, without touching the installed app. Runs the
# release build as `GlancyLab --lab` (App/Lab.swift) once per state of CollapsedStates
# (GLANCY_LAB_STATE): demo data, that state's modules only, a notch and an external display's pill,
# both 20 000 pt off-screen (they render for real, nobody sees them). Never starts, stops or reads
# ~/Applications/Glancy.app.
#
#   per state: launch → settle → [measure "closed" over WINDOW s] → open + close the panel on each
#   display → 3 s → [measure "after" over WINDOW s]
#
# A measurement: CPU % of the lab process (ps time delta) and layout passes per second of each
# surface (SurfaceHostingView.layoutPasses, from the lab's SIGUSR2 line).
# `--monitor S`: also the Monitor tab held open for S seconds (CPU %, plus a 10 s `sample`), in the
# state `--monitor-state` (default "monitor": that module alone; "all": every module, as on a Mac
# with agents working, music playing… and the other display's wings beside the open panel).
# The table goes to lab-out/cpu-<label>/table.txt.
#
# Usage: scripts/cpu-lab.sh [--label NAME] [--states "a b …"|none] [--monitor-state NAME] [--window S] [--monitor S] [--no-build]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LABEL="run"; STATES=""; WINDOW=6; MONITOR=0; MONITOR_STATE="monitor"; BUILD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift ;;
    --states) STATES="$2"; shift ;;
    --window) WINDOW="$2"; shift ;;
    --monitor) MONITOR="$2"; shift ;;
    --monitor-state) MONITOR_STATE="$2"; shift ;;
    --no-build) BUILD=0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ $BUILD -eq 1 ]]; then swift build -c release --product Glancy 2>&1 | grep -E "error|warning: |Build" || true; fi
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$BIN_DIR/lab/cpu-$LABEL"
LAB="$BIN_DIR/lab/cpu-$LABEL/GlancyLab"
if [[ $BUILD -eq 1 || ! -x "$LAB" ]]; then
  cp "$BIN_DIR/Glancy" "$LAB"
  rm -rf "$BIN_DIR/lab/cpu-$LABEL/Sparkle.framework"
  ditto "$BIN_DIR/Sparkle.framework" "$BIN_DIR/lab/cpu-$LABEL/Sparkle.framework"
  codesign -s - -f "$LAB" 2>/dev/null
fi

if [[ -z "$STATES" ]]; then
  STATES="$(sed -nE 's/.*Case\(name: "([^"]+)".*/\1/p; s/.*agentsCase\("([^"]+)".*/\1/p' Sources/GlancyKit/App/CollapsedStates.swift | tr '\n' ' ')"
fi

[[ "$STATES" == none ]] && STATES=""   # --states none: the Monitor run only
OUT="$ROOT/lab-out/cpu-$LABEL"
mkdir -p "$OUT"
PID=""; SCRATCH=""; LOG=""
cleanup() {
  # Only the lab's own pid, never anything by name.
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then kill -TERM "$PID" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
  fi
  [[ -n "$SCRATCH" ]] && rm -rf "$SCRATCH"
  PID=""; SCRATCH=""
}
trap cleanup EXIT

launch() {   # launch <state> <scope>
  SCRATCH="$(mktemp -d -t glancy-cpulab)"
  LOG="$OUT/$1.log"
  mkdir -p "$SCRATCH/home"
  CFFIXED_USER_HOME="$SCRATCH/home" GLANCY_LAB=1 GLANCY_LAB_HOME="$SCRATCH" GLANCY_LAB_STATE="$1" GLANCY_LAB_SCOPE="$2" \
    "$LAB" --lab > "$LOG" 2>&1 &
  PID=$!
}

wait_for() {   # wait_for <pattern> <after-line> <timeout s>
  local pattern="$1" from="$2" limit="$3" t=0
  while (( t < limit * 10 )); do
    if tail -n +"$from" "$LOG" | grep -q "$pattern"; then return 0; fi
    kill -0 "$PID" 2>/dev/null || { echo "lab exited:" >&2; cat "$LOG" >&2; exit 1; }
    sleep 0.1; t=$((t + 1))
  done
  echo "timed out waiting for '$pattern'" >&2; exit 1
}
lines() { wc -l < "$LOG" | tr -d ' '; }
cpu_seconds() { ps -o time= -p "$PID" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
passes() {   # prints "notch pill" layout passes so far
  local from; from=$(( $(lines) + 1 ))
  kill -USR2 "$PID"
  wait_for "lab: now" "$from" 10
  tail -n +"$from" "$LOG" | grep -m1 "lab: now" | sed -E 's/.*passes=//' | tr ',' '\n' |
    awk -F: '/^lab:/ { n = $2 } /^lab-pill:/ { p = $2 } END { print n + 0, p + 0 }'
}
measure() {   # measure → "cpu% notch/s pill/s"
  local p0 p1 c0 c1 t0 t1
  p0="$(passes)"; c0="$(cpu_seconds)"; t0="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
  sleep "$WINDOW"
  c1="$(cpu_seconds)"; t1="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"; p1="$(passes)"
  awk -v a="$c0" -v b="$c1" -v t0="$t0" -v t1="$t1" -v p0="$p0" -v p1="$p1" 'BEGIN {
    split(p0, x, " "); split(p1, y, " "); t = t1 - t0
    printf "%.2f %.1f %.1f", (b - a) / t * 100, (y[1] - x[1]) / t, (y[2] - x[2]) / t }'
}

ROWS=()
for state in $STATES; do
  launch "$state" cycle
  wait_for "lab: ready" 1 30
  settle="$(grep -m1 'lab: ready' "$LOG" | sed -nE 's/.*settle=([0-9.]+).*/\1/p')"
  sleep "$(awk -v s="${settle:-1.2}" 'BEGIN { print s + 2 }')"
  read -r cc cn cp <<< "$(measure)"
  from=$(( $(lines) + 1 ))
  kill -USR1 "$PID"
  wait_for "tour: done" "$from" 30
  sleep 3
  read -r ac an ap <<< "$(measure)"
  row="$(printf '%-26s %8s %9s %9s %8s %9s %9s' "$state" "$cc" "$cn" "$cp" "$ac" "$an" "$ap")"
  echo "$row"
  ROWS+=("$row")
  cleanup
done

MON=""
if [[ $MONITOR -gt 0 ]]; then
  launch "$MONITOR_STATE" monitor
  wait_for "lab: ready" 1 30
  from=$(( $(lines) + 1 ))
  kill -USR1 "$PID"
  wait_for "tour: done" "$from" 30
  sleep 3
  c0="$(cpu_seconds)"; sleep "$MONITOR"; c1="$(cpu_seconds)"
  MON="$(awk -v a="$c0" -v b="$c1" -v t="$MONITOR" 'BEGIN { printf "%.2f", (b - a) / t * 100 }')"
  sample "$PID" 10 -file "$OUT/monitor-$MONITOR_STATE.sample.txt" > /dev/null 2>&1 || true
  echo "monitor tab open ${MONITOR}s ($MONITOR_STATE): ${MON}% CPU (sample: $OUT/monitor-$MONITOR_STATE.sample.txt)"
  cleanup
fi

{
  echo "== $LABEL  $(date '+%Y-%m-%d %H:%M')  $(git rev-parse --short HEAD)$(git diff --quiet || echo '+dirty')  window=${WINDOW}s"
  printf '%-26s %8s %9s %9s %8s %9s %9s\n' "state" "cpu %" "notch/s" "pill/s" "cpu %" "notch/s" "pill/s"
  printf '%-26s %28s %28s\n' "" "closed (never opened)" "after open+close on each"
  for r in "${ROWS[@]+"${ROWS[@]}"}"; do echo "$r"; done
  [[ -n "$MON" ]] && echo "monitor tab open ${MONITOR}s ($MONITOR_STATE): ${MON}% CPU"
} | tee -a "$OUT/table.txt"
