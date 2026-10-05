#!/bin/bash
# Long-run soak of the installed Glancy (SPEC §1 "Light", RESEARCH §8: leaks show up over hours).
# Samples phys_footprint, CPU time, threads, open fds and child processes every interval into
# ~/Library/Logs/Glancy/soak-<date>.csv, then summarises growth per hour.
#
# FAIL when phys_footprint grows > 5 MB per 24 h (least-squares slope), when open fds grow
# monotonically (never down, last > first, ≥ 3 samples), or when the app dies during the run.
# Runs shorter than 1 h only give an indicative verdict (exit 0) unless --strict.
#
# Usage: scripts/soak.sh [--hours N] [--interval SECONDS] [--strict] [--dry-run]
#   --hours     run length, default 24 (fractions ok: 0.05 = 3 min)
#   --interval  seconds between samples, default 600 (shorter runs: duration / 6, ≥ 10 s)
#   --dry-run   print the plan and one sample, write nothing
# A Glancy that is already running is measured as it is (never relaunched); otherwise the
# installed app is opened.
set -euo pipefail

APP="$HOME/Applications/Glancy.app"
HOURS=24
INTERVAL=""
STRICT=0
DRY=0
LIMIT_MB_PER_DAY=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hours) HOURS="$2"; shift ;;
    --interval) INTERVAL="$2"; shift ;;
    --strict) STRICT=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

DURATION="$(awk -v h="$HOURS" 'BEGIN { printf "%d", h * 3600 }')"
if [[ -z "$INTERVAL" ]]; then
  INTERVAL="$(awk -v d="$DURATION" 'BEGIN { i = d / 6; if (i > 600) i = 600; if (i < 10) i = 10; printf "%d", i }')"
fi
LOGDIR="$HOME/Library/Logs/Glancy"
STAMP="$(date +%Y%m%d-%H%M%S)"
CSV="$LOGDIR/soak-$STAMP.csv"
SUMMARY="$LOGDIR/soak-$STAMP.summary.txt"

pid_of() { pgrep -x Glancy | head -1 || true; }

PID="$(pid_of)"
LAUNCHED=0
if [[ -z "$PID" ]]; then
  if [[ $DRY -eq 1 ]]; then
    echo "dry run: Glancy is not running; would open $APP"
  else
    [[ -d "$APP" ]] || { echo "not installed: $APP (run scripts/build-app.sh)" >&2; exit 2; }
    open "$APP"
    for _ in $(seq 1 50); do PID="$(pid_of)"; [[ -n "$PID" ]] && break; sleep 0.1; done
    [[ -n "$PID" ]] || { echo "Glancy did not start" >&2; exit 1; }
    LAUNCHED=1
    sleep 10   # let launch settle before the first sample
  fi
fi

# One sample → "footprint_mb,cpu_s,threads,fds,children,children_mb" (empty when the pid is gone).
cpu_seconds() {
  ps -o time= -p "$1" 2>/dev/null | awk -F'[:.]' '{ if (NF==3) printf "%.2f", $1*60+$2+$3/100; else if (NF==4) printf "%.2f", $1*3600+$2*60+$3+$4/100 }'
}
footprint_mb() {
  footprint -f bytes --noCategories -p "$1" 2>/dev/null | sed -n 's/.*Footprint: \([0-9]*\) B.*/\1/p' | head -1 \
    | awk '{ printf "%.2f", $1 / 1048576 }'
}
sample() {
  local p="$1"
  kill -0 "$p" 2>/dev/null || return 1
  local fp cpu thr fds kids kmb=0
  fp="$(footprint_mb "$p")"
  cpu="$(cpu_seconds "$p")"
  thr="$(( $(ps -M -p "$p" 2>/dev/null | wc -l) - 1 ))"
  fds="$(lsof -nP -p "$p" 2>/dev/null | awk 'NR > 1 && $4 ~ /^[0-9]+[urw]?$/' | wc -l | tr -d ' ')"
  kids="$(pgrep -P "$p" | tr '\n' ' ' | sed 's/ $//')"
  for k in $kids; do
    kmb="$(awk -v a="$kmb" -v b="$(footprint_mb "$k")" 'BEGIN { printf "%.2f", a + b }')"
  done
  echo "${fp:-},${cpu:-},${thr},${fds},$(echo "$kids" | wc -w | tr -d ' '),${kmb}"
}

echo "soak: Glancy pid ${PID:-?}, ${HOURS} h, every ${INTERVAL} s$([[ $LAUNCHED -eq 1 ]] && echo ' (launched by this run)')"
if [[ $DRY -eq 1 ]]; then
  echo "dry run: would write $CSV and $SUMMARY"
  if [[ -n "$PID" ]]; then echo "sample now: footprint_mb,cpu_s,threads,fds,children,children_mb = $(sample "$PID")"; fi
  exit 0
fi

mkdir -p "$LOGDIR"
echo "time,elapsed_h,footprint_mb,cpu_s,threads,fds,children,children_mb" > "$CSV"
echo "csv: $CSV"
T0="$(date +%s)"
DIED=0
while :; do
  NOW="$(date +%s)"
  ELAPSED="$(awk -v a="$T0" -v b="$NOW" 'BEGIN { printf "%.4f", (b - a) / 3600 }')"
  if ! ROW="$(sample "$PID")"; then
    echo "$(date -u +%FT%TZ),$ELAPSED,,,,,," >> "$CSV"
    DIED=1
    echo "Glancy (pid $PID) is gone at ${ELAPSED} h" >&2
    break
  fi
  echo "$(date -u +%FT%TZ),$ELAPSED,$ROW" >> "$CSV"
  echo "  ${ELAPSED} h  $ROW"
  (( NOW - T0 >= DURATION )) && break
  NEXT=$(( NOW + INTERVAL ))
  END=$(( T0 + DURATION ))
  (( NEXT > END )) && NEXT=$END
  sleep $(( NEXT - NOW > 0 ? NEXT - NOW : 1 ))
done

# Summary: least-squares slope of footprint (MB/h), CPU % over the run, fd trend, threads range.
awk -F, -v limit="$LIMIT_MB_PER_DAY" -v died="$DIED" -v strict="$STRICT" '
  NR == 1 || $3 == "" { next }
  {
    n++; x = $2; y = $3
    sx += x; sy += y; sxx += x * x; sxy += x * y
    if (n == 1) { fp0 = y; cpu0 = $4; fd0 = $6; t0 = x; thmin = $5; thmax = $5 }
    fp1 = y; cpu1 = $4; fd1 = $6; t1 = x
    if ($5 < thmin) thmin = $5; if ($5 > thmax) thmax = $5
    if (n > 1 && $6 < prevfd) fddown = 1
    prevfd = $6; kids = $7; kmb = $8
  }
  END {
    if (n < 2) { print "summary: fewer than 2 samples"; exit died ? 1 : 0 }
    d = n * sxx - sx * sx
    slope = d > 0 ? (n * sxy - sx * sy) / d : 0
    hours = t1 - t0
    cpu = hours > 0 ? (cpu1 - cpu0) / (hours * 3600) * 100 : 0
    printf "samples: %d over %.2f h\n", n, hours
    printf "footprint: %.2f → %.2f MB, slope %+.3f MB/h (%+.2f MB per 24 h; limit %d)\n", fp0, fp1, slope, slope * 24, limit
    printf "cpu: %.3f %% average\n", cpu
    printf "threads: %d–%d   fds: %d → %d   children: %d (%.1f MB)\n", thmin, thmax, fd0, fd1, kids, kmb
    fail = ""
    if (died) fail = fail " app-died"
    if (slope * 24 > limit) fail = fail " footprint-growth"
    if (n >= 3 && !fddown && fd1 > fd0) fail = fail " fds-monotonic"
    verdict = fail == "" ? "PASS" : "FAIL:" fail
    short = hours < 1
    if (short) printf "verdict: %s (indicative only: run < 1 h)\n", verdict
    else printf "verdict: %s\n", verdict
    exit (fail != "" && (!short || strict || died)) ? 1 : 0
  }' "$CSV" | tee "$SUMMARY"
STATUS=${PIPESTATUS[0]}
echo "summary: $SUMMARY"
exit "$STATUS"
