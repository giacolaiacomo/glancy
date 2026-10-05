#!/bin/bash
# Fails on periodic work that could run while collapsed (SPEC §1): Timer.scheduledTimer / Timer(…),
# TimelineView, usleep, and mouse-moved event monitors. Exceptions live in scripts/lint-allow.txt
# as "path:pattern" lines and must be visible-only code.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ALLOW="scripts/lint-allow.txt"

PATTERNS=(
  'Timer\.scheduledTimer'
  'Timer\.publish'
  '[^A-Za-z.]Timer\('
  'TimelineView'
  'usleep\('
  'repeatForever'
  'addGlobalMonitorForEvents\(matching:[^)]*mouseMoved'
  'addLocalMonitorForEvents\(matching:[^)]*mouseMoved'
)

fail=0
for pat in "${PATTERNS[@]}"; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    file="${hit%%:*}"
    if grep -v '^#' "$ALLOW" 2>/dev/null | grep -qF "$file:$pat"; then continue; fi
    echo "lint: $hit"
    fail=1
  done < <(grep -rnE --include='*.swift' "$pat" Sources || true)
done

if [[ $fail -ne 0 ]]; then
  echo "lint: FAILED — no timers, TimelineView, usleep or mouse-moved monitors (SPEC §1)." >&2
  exit 1
fi
echo "lint: OK"
