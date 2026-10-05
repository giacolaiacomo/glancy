#!/bin/bash
# Fails on periodic work that could run while collapsed (SPEC §1): Timer.scheduledTimer / Timer(…),
# TimelineView, usleep, and mouse-moved event monitors; and on windows / hosting views / pickers built
# outside the allow-listed, on-demand sites. Exceptions live in scripts/lint-allow.txt
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

# Windows, hosting views, pickers, samplers and capture sessions cost megabytes for as long as they
# live. They may only be built on a user's action and released after it: never in a module's
# init/start, never kept for later. Every site is listed in the allow-list with that reason.
PATTERNS+=(
  'NSHostingView\('
  'NSHostingController\('
  'NSWindow\('
  'NSPanel\('
  'ImageRenderer\('
  'NSColorSampler\('
  'AVCaptureSession\('
  'QLPreviewPanel\.shared\('
  'NSSharingServicePicker\('
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
  echo "lint: FAILED — no timers, TimelineView, usleep or mouse-moved monitors (SPEC §1); windows," >&2
  echo "      hosting views, pickers, samplers and capture sessions only on a user's action (allow-list)." >&2
  exit 1
fi
echo "lint: OK"
