#!/usr/bin/env bash
# Cairn H1 — SessionStart hook.
# Reads session_id from stdin JSON; writes session-tracking side-effect files;
# emits the cached primer to stdout (injected as context by Claude Code).
#
# Side effects (all atomic via tmp+mv, except jsonl touch which is O_APPEND no-op):
#   1. ~/.claude/cairn/last-session-id             — resolved session id
#   2. ~/.claude/cairn/last-session-date           — UTC YYYY-MM-DD at SessionStart
#   3. ~/.claude/cairn/sessions/{sid}.start        — UTC epoch seconds at SessionStart
#   4. ~/.claude/cairn/t1-run-scratch/{date}/{sid}.jsonl — empty-touch so downstream
#      hooks always find the file even on a silent session
#
# Budget: 500ms soft. Overruns logged to failures.log but H1 still completes.
set +e
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

CAIRN_DIR="$HOME/.claude/cairn"
FAILURES_LOG="$CAIRN_DIR/failures.log"
PRIMER_FILE="$CAIRN_DIR/last-global-index.md"
MAX_PRIMER_BYTES=8192

mkdir -p "$CAIRN_DIR/sessions" "$CAIRN_DIR/t1-run-scratch" "$CAIRN_DIR/t1-pending" 2>/dev/null

log_failure() {
  local msg="$1"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "cairn-session-start" "$msg" >> "$FAILURES_LOG" 2>/dev/null
}

# Read single JSON blob from stdin
INPUT="$(cat 2>/dev/null)"

# Resolve session_id via python3 if available, fallback to grep/sed
SESSION_ID=""
if command -v python3 >/dev/null 2>&1; then
  SESSION_ID="$(printf '%s' "$INPUT" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('session_id','') or '')
except Exception:
    print('')
" 2>/dev/null)"
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="$(printf '%s' "$INPUT" | grep -o '"session_id"[^,}]*' | head -1 | sed 's/.*"session_id"[[:space:]]*:[[:space:]]*"//;s/".*//')"
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="unknown-$$-$(date -u +%Y%m%d%H%M%S)"
  log_failure "session_id missing from stdin; using fallback $SESSION_ID"
fi

SESSION_DATE="$(date -u +%Y-%m-%d)"
EPOCH="$(date -u +%s)"

# Atomic write helper
atomic_write() {
  local content="$1"
  local path="$2"
  local tmp="$path.tmp.$$"
  printf '%s\n' "$content" > "$tmp" 2>/dev/null && mv "$tmp" "$path" 2>/dev/null
}

atomic_write "$SESSION_ID"   "$CAIRN_DIR/last-session-id"
atomic_write "$SESSION_DATE" "$CAIRN_DIR/last-session-date"
atomic_write "$EPOCH"        "$CAIRN_DIR/sessions/$SESSION_ID.start"

# Ensure day-directory and touch the jsonl file (O_APPEND no-op creates if absent)
DAY_DIR="$CAIRN_DIR/t1-run-scratch/$SESSION_DATE"
JSONL_FILE="$DAY_DIR/$SESSION_ID.jsonl"
mkdir -p "$DAY_DIR" 2>/dev/null
: >> "$JSONL_FILE" 2>/dev/null

# Tail failures.log for 24h warnings (bounded read, no full-file scan)
PRIMER_WARN=""
if [ -f "$FAILURES_LOG" ]; then
  CUTOFF="$(python3 -c "
from datetime import datetime,timedelta,timezone
print((datetime.now(timezone.utc)-timedelta(hours=24)).strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null)"
  if [ -n "$CUTOFF" ]; then
    RECENT_COUNT="$(tail -200 "$FAILURES_LOG" 2>/dev/null | awk -v c="$CUTOFF" -F'\t' '$1 >= c' | wc -l | tr -d '[:space:]')"
    if [ "${RECENT_COUNT:-0}" -ge 10 ] 2>/dev/null; then
      PRIMER_WARN="<!-- cairn: $RECENT_COUNT hook failures in the last 24h — check $FAILURES_LOG -->"
    fi
  fi
fi

# Emit primer to stdout (SessionStart stdout is injected as context).
# Cap at 8192 bytes with truncation marker.
if [ -n "$PRIMER_WARN" ]; then
  printf '%s\n' "$PRIMER_WARN"
fi
if [ -f "$PRIMER_FILE" ]; then
  PRIMER_SIZE="$(wc -c < "$PRIMER_FILE" 2>/dev/null | tr -d '[:space:]')"
  if [ "${PRIMER_SIZE:-0}" -gt "$MAX_PRIMER_BYTES" ] 2>/dev/null; then
    head -c "$MAX_PRIMER_BYTES" "$PRIMER_FILE" 2>/dev/null
    printf '\n<!-- primer truncated at %d bytes -->\n' "$MAX_PRIMER_BYTES"
  else
    cat "$PRIMER_FILE" 2>/dev/null
  fi
fi

exit 0
