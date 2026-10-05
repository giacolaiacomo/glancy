#!/bin/bash
# Claude Code hook for Glancy's Agents module: appends one compact JSON line per hook event to
#   ~/.claude/hooks/data/cc-dashboard/events.jsonl   (rotated to .1 at ~5 MB)
# Read-only observer: prints nothing (no decision) and always exits 0, so it can never block Claude Code.
# Keeps only: time, event name, session id, working folder, tool name, subagent type, the first 200
# characters of the prompt, the start/end source/reason, and which app the session runs in (the app's
# bundle id, TERM_PROGRAM and Claude Code's entry point: Terminal vs VS Code vs the Claude app).
# Needs jq (built into macOS 15+, or brew install jq). Older Glancy versions ignore the added fields.
OUT="$HOME/.claude/hooks/data/cc-dashboard/events.jsonl"
JQ="$(command -v jq || true)"
for c in /usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq; do [ -z "$JQ" ] && [ -x "$c" ] && JQ="$c"; done
[ -n "$JQ" ] || exit 0
mkdir -p "$(dirname "$OUT")" 2>/dev/null
if [ -f "$OUT" ] && [ "$(stat -f%z "$OUT" 2>/dev/null || echo 0)" -gt 5000000 ]; then
  mv "$OUT" "$OUT.1" 2>/dev/null
fi
"$JQ" -c '{
  ts: (now * 1000 | floor),
  event: .hook_event_name,
  session_id: .session_id,
  cwd: .cwd,
  tool_name: .tool_name,
  agent_type: .agent_type,
  prompt: ((.prompt // "") | tostring | .[0:200]),
  source: .source,
  reason: .reason,
  stop_hook_active: .stop_hook_active,
  host_bundle: env.__CFBundleIdentifier,
  term_program: env.TERM_PROGRAM,
  entrypoint: env.CLAUDE_CODE_ENTRYPOINT
} | with_entries(select(.value != null))' >> "$OUT" 2>/dev/null
exit 0
