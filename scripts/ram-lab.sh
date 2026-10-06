#!/bin/bash
# Memory lab: measures Glancy's memory without touching the installed app. Runs the release build
# as `GlancyLab --lab` (App/Lab.swift): demo data in a scratch folder, its own defaults suite, no
# lock, no hot keys / taps / monitors / Accessibility / prompts, the surface 20 000 pt off-screen
# (it renders for real, nobody sees it). Never starts, stops or reads ~/Applications/Glancy.app.
#
#   launch → idle IDLE s → [measure "idle"] → tour every tab and settings page ROUNDS times
#   → AFTER s after the panel closed → [measure "after"] → (--leak M: M more tours → [measure "leak"])
#
# A measurement: phys_footprint and its peak, malloc in use (malloc_zone_statistics, all zones),
# graphics (dirty IOSurface / IOAccelerator / CoreAnimation / CG raster from vmmap --summary), live
# Swift tasks (swift-inspect), the top 20 heap classes, CPU while collapsed. Details per run go to
# lab-out/<label>/; the table is printed and appended to lab-out/<label>/table.txt.
#
# Usage: scripts/ram-lab.sh [--label NAME] [--rounds N] [--idle S] [--after S] [--leak M] [--no-build]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LABEL="run"; ROUNDS=3; IDLE=60; AFTER=30; LEAK=0; BUILD=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) LABEL="$2"; shift ;;
    --rounds) ROUNDS="$2"; shift ;;
    --idle) IDLE="$2"; shift ;;
    --after) AFTER="$2"; shift ;;
    --leak) LEAK="$2"; shift ;;
    --no-build) BUILD=0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ $BUILD -eq 1 ]]; then swift build -c release --product Glancy 2>&1 | grep -E "error|warning: |Build" || true; fi
BIN_DIR="$(swift build -c release --show-bin-path)"
# Its own name (never mistaken for the installed Glancy) and get-task-allow, so swift-inspect can
# count the Swift tasks. Same code as the release build.
# One copy per label: several labs may run side by side (bisection).
mkdir -p "$BIN_DIR/lab/$LABEL"
LAB="$BIN_DIR/lab/$LABEL/GlancyLab"
cp "$BIN_DIR/Glancy" "$LAB"
# Sparkle (linked, @loader_path rpath): the framework sits beside the copy, as in the build folder.
rm -rf "$BIN_DIR/lab/$LABEL/Sparkle.framework"
ditto "$BIN_DIR/Sparkle.framework" "$BIN_DIR/lab/$LABEL/Sparkle.framework"
ENT="$(mktemp -t glancy-lab-ent)"
cat > "$ENT" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
EOF
codesign -s - -f --entitlements "$ENT" "$LAB" 2>/dev/null
rm -f "$ENT"

OUT="$ROOT/lab-out/$LABEL"
mkdir -p "$OUT"
SCRATCH="$(mktemp -d -t glancy-lab)"
LOG="$OUT/app.log"
mkdir -p "$SCRATCH/home"
CFFIXED_USER_HOME="$SCRATCH/home" GLANCY_LAB=1 GLANCY_LAB_HOME="$SCRATCH" GLANCY_LAB_ROUNDS="$ROUNDS" \
  "$LAB" --lab > "$LOG" 2>&1 &
PID=$!
cleanup() {
  # Only the lab's own pid, never anything by name.
  if kill -0 "$PID" 2>/dev/null; then kill -TERM "$PID" 2>/dev/null || true; fi
  for _ in $(seq 1 30); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

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
to_mb() { awk '{ v = $1; u = substr(v, length(v)); n = v + 0
  if (u == "K") n /= 1024; else if (u == "G") n *= 1024; else if (u == "B") n /= 1048576; printf "%.1f", n }'; }

ROWS=()
measure() {   # measure <name> <cpu%>
  local name="$1" cpu="$2" from
  from=$(( $(lines) + 1 ))
  kill -USR2 "$PID"
  wait_for "lab: now" "$from" 10
  local line; line="$(tail -n +"$from" "$LOG" | grep -m1 "lab: now")"
  local fp inuse
  fp="$(sed -E 's/.*footprint=([0-9.]+).*/\1/' <<< "$line")"
  inuse="$(sed -E 's/.*malloc_in_use=([0-9.]+).*/\1/' <<< "$line")"
  vmmap --summary "$PID" > "$OUT/$name.vmmap.txt" 2>/dev/null || true
  local peak gfx
  peak="$(grep -m1 'Physical footprint (peak):' "$OUT/$name.vmmap.txt" | awk '{print $NF}' | to_mb)"
  # Dirty column of the graphics regions (NAME … VIRTUAL RESIDENT DIRTY SWAPPED VOL NONVOL EMPTY COUNT).
  gfx="$(grep -E '^(IOSurface|IOAccelerator|CoreAnimation|CG raster data)' "$OUT/$name.vmmap.txt" | awk '{
    d = $(NF-5); u = substr(d, length(d)); n = d + 0
    if (u == "K") n /= 1024; else if (u == "G") n *= 1024
    s += n } END { printf "%.1f", s }')"
  footprint -p "$PID" > "$OUT/$name.footprint.txt" 2>/dev/null || true
  heap -sortBySize "$PID" > "$OUT/$name.heap.txt" 2>/dev/null || true
  swift-inspect dump-concurrency "$PID" > "$OUT/$name.tasks.txt" 2>/dev/null || true
  local tasks; tasks="$(grep -cE '^ *Task [0-9]+ - ' "$OUT/$name.tasks.txt" || true)"
  ROWS+=("$(printf '%-8s %9s %9s %9s %9s %7s %7s' "$name" "$fp" "$peak" "$inuse" "$gfx" "$tasks" "$cpu")")
  echo "measured $name: footprint $fp MB, malloc in use $inuse MB, graphics $gfx MB, tasks $tasks, cpu $cpu%"
}

wait_for "lab: ready" 1 30
echo "lab pid $PID (scratch $SCRATCH) — idling ${IDLE}s"
sleep 5
C0="$(cpu_seconds)"; T0="$(date +%s)"
sleep $(( IDLE > 5 ? IDLE - 5 : 1 ))
C1="$(cpu_seconds)"; T1="$(date +%s)"
CPU="$(awk -v a="$C0" -v b="$C1" -v t=$((T1 - T0)) 'BEGIN { printf "%.2f", (b - a) / (t > 0 ? t : 1) * 100 }')"
measure idle "$CPU"

tour() {   # tour → waits for the panel to close; prints the tour's peak footprint
  local from; from=$(( $(lines) + 1 ))
  kill -USR1 "$PID"
  wait_for "tour: done" "$from" $(( 60 * ROUNDS + 60 ))
  tail -n +"$from" "$LOG" | grep '^tour:' >> "$OUT/tour.txt"
  tail -n +"$from" "$LOG" | sed -nE 's/.*peak +([0-9.]+)\).*/\1/p' | sort -n | tail -1
}
echo "touring ${ROUNDS}×"
TOUR_PEAK="$(tour)"
# The tour logs "done" 5 s after closing; AFTER counts from the close.
sleep $(( AFTER > 5 ? AFTER - 5 : 0 ))
C0="$(cpu_seconds)"; sleep 10; C1="$(cpu_seconds)"
CPU="$(awk -v a="$C0" -v b="$C1" 'BEGIN { printf "%.2f", (b - a) / 10 * 100 }')"
measure after "$CPU"
AFTER_INUSE="$(awk '{print $4}' <<< "${ROWS[1]}")"

if [[ $LEAK -gt 0 ]]; then
  echo "leak check: $LEAK more tours of ${ROUNDS} rounds"
  for _ in $(seq 1 "$LEAK"); do tour > /dev/null; done
  sleep $(( AFTER > 5 ? AFTER - 5 : 0 ))
  measure leak "-"
  LEAK_INUSE="$(awk '{print $4}' <<< "${ROWS[2]}")"
  GROWTH="$(awk -v a="$AFTER_INUSE" -v b="$LEAK_INUSE" -v n=$(( LEAK * ROUNDS )) 'BEGIN { printf "%.3f", (b - a) / n }')"
fi

{
  echo "== $LABEL  $(date '+%Y-%m-%d %H:%M')  $(git rev-parse --short HEAD)$(git diff --quiet || echo '+dirty')  rounds=$ROUNDS idle=${IDLE}s after=${AFTER}s"
  printf '%-8s %9s %9s %9s %9s %7s %7s\n' "point" "fp MB" "peak MB" "heap MB" "gfx MB" "tasks" "cpu %"
  for r in "${ROWS[@]}"; do echo "$r"; done
  echo "peak while open (tour): ${TOUR_PEAK:-?} MB"
  [[ -n "${GROWTH:-}" ]] && echo "heap growth per tour round: ${GROWTH} MB (${LEAK}×${ROUNDS} more rounds)"
  echo "top heap classes after the tour (count bytes class):"
  grep -A22 'COUNT      BYTES' "$OUT/after.heap.txt" | tail -n +3 | awk '{ printf "  %7s %10s  ", $1, $2; for (i = 4; i <= NF - 2; i++) printf "%s ", $i; print "" }' | cut -c1-120
} | tee -a "$OUT/table.txt"
