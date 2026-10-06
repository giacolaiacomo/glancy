#!/bin/bash
# Fails on periodic work that could run while collapsed (SPEC §1): Timer.scheduledTimer / Timer(…),
# TimelineView, usleep, and mouse-moved event monitors; on windows / hosting views / pickers built
# outside the allow-listed, on-demand sites; on AppleScript outside AppleScriptRunner; and on
# main-actor-isolated callbacks the system calls from another thread (the crash class of wave 4). Exceptions live in scripts/lint-allow.txt
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

# A cancelled Task.sleep keeps its task until the original deadline (an hour-long wait re-armed on
# every open left one behind each time): waits go through Delay.sleep (Support/Delay.swift).
PATTERNS+=(
  'Task\.sleep\('
)

# NSAppleScript is not thread-safe and may block on the Automation prompt: every script runs on
# AppleScriptRunner's one serial queue (Support/AppleScriptRunner.swift), never on main.
PATTERNS+=(
  'NSAppleScript\('
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

# Callbacks that run off the main thread must not be main-actor isolated. In Swift 6 a closure
# literal formed in a @MainActor context and handed straight to an Apple API whose block is not
# @Sendable inherits the main actor, and the runtime traps (EXC_BREAKPOINT in
# swift_task_checkIsolated) when the system calls it on its own queue: the speech-permission
# answer did exactly that. Same for an @objc method of a @MainActor class that the system calls
# from another queue (IOBluetooth's connect notification: four crash reports). In files that use
# @MainActor:
#   - a closure passed to one of the APIs below must be written `{ @Sendable … }` and hop to main
#     itself (or be built in a nonisolated helper);
#   - an @objc method must be `nonisolated` (and hop to main), unless the allow-list says it is only
#     ever called on main (a menu action, a notification posted on main), as
#     "path:isolation:<text of the line>".
CALLBACK_APIS='(requestAuthorization|requestAccess|requestFullAccessToEvents|generateBestRepresentation|generateRepresentations|openApplication|recognitionTask|setEventHandler|setCancelHandler|setRegistrationHandler|DispatchWorkItem|completionHandler:|getNotificationSettings|addPeriodicTimeObserver|requestRecordPermission|AddPropertyListenerBlock)'
while IFS= read -r file; do
  while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    text="${hit#*:}"
    allowed=0
    while IFS= read -r entry; do
      [[ -n "$entry" && "$text" == *"$entry"* ]] && { allowed=1; break; }
    done < <(grep -v '^#' "$ALLOW" 2>/dev/null | grep -F "$file:isolation:" | sed "s|^$file:isolation:||")
    [[ $allowed -eq 1 ]] && continue
    echo "lint: $file:$hit"
    fail=1
  done < <(awk -v API="$CALLBACK_APIS" '
    { line = $0; sub(/\/\/.*$/, "", line) }
    line !~ /@Sendable|await |func |@escaping/ && (line ~ (API "([(][^{}]*[)])? *[{]") || line ~ /PropertyListenerBlock *= *[{]/) {
      printf "%d: off-main callback closure without @Sendable: %s\n", NR, $0
    }
    prev_objc && line ~ /func / && line !~ /nonisolated/ { printf "%d: @objc method not nonisolated: %s\n", NR, $0 }
    { prev_objc = (line ~ /@objc[ \t]*$/) }
    line ~ /@objc[ \t(]/ && line ~ /func / && line !~ /nonisolated/ { printf "%d: @objc method not nonisolated: %s\n", NR, $0 }
  ' "$file")
done < <(grep -rlE --include='*.swift' '@MainActor' Sources)

if [[ $fail -ne 0 ]]; then
  echo "lint: FAILED — no timers, TimelineView, usleep or mouse-moved monitors (SPEC §1); windows," >&2
  echo "      hosting views, pickers, samplers and capture sessions only on a user's action (allow-list);" >&2
  echo "      AppleScript only through AppleScriptRunner; off-main callbacks @Sendable, @objc entry" >&2
  echo "      points of @MainActor classes nonisolated (allow-list: path:isolation:<line text>)." >&2
  exit 1
fi
echo "lint: OK"
