#!/usr/bin/env bash
# Cairn H2a — PreToolUse + PostToolUse pairing hook.
# Registered on BOTH events in ~/.claude/settings.json with matcher ".*".
# Branches on hook_event_name:
#   PreToolUse  — writes a pending file keyed by tool_use_id
#   PostToolUse — deletes the pending file (success resolves it)
# Failure detection happens later in H2b/H3 via orphan promotion (any pending
# file that survives = PreToolUse without matching PostToolUse = failure).
#
# Budgets: 30ms Pre, 20ms Post. Errors → failures.log. Always exit 0.
set +e
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

CAIRN_DIR="$HOME/.claude/cairn"
FAILURES_LOG="$CAIRN_DIR/failures.log"

log_failure() {
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "cairn-tool-use" "$1" >> "$FAILURES_LOG" 2>/dev/null
}

if ! command -v python3 >/dev/null 2>&1; then
  log_failure "python3 missing; skipping"
  exit 0
fi

INPUT="$(cat 2>/dev/null)"

# Parse stdin via python3 — extract all fields in one pass
PARSED="$(printf '%s' "$INPUT" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('|||||'); sys.exit()
ev=d.get('hook_event_name','')
sid=d.get('session_id','')
tid=d.get('tool_use_id','')
tname=d.get('tool_name','')
ti=d.get('tool_input') or {}
if ev=='PreToolUse':
    if tname=='Bash':
        snip=(ti.get('command') or '')[:200]
    else:
        snip=json.dumps(ti,separators=(',',':'))[:200]
else:
    snip=''
# emit pipe-delimited: ev|sid|tid|tname|snip
# snip may contain pipes — use TAB instead
print('{}\t{}\t{}\t{}\t{}'.format(ev,sid,tid,tname,snip))
" 2>/dev/null)"

IFS=$'\t' read -r EVENT SESSION_ID TOOL_USE_ID TOOL_NAME CMD_SNIPPET <<< "$PARSED"

if [ -z "$EVENT" ] || [ -z "$SESSION_ID" ] || [ -z "$TOOL_USE_ID" ]; then
  log_failure "missing fields (event=$EVENT sid=$SESSION_ID tid=$TOOL_USE_ID)"
  exit 0
fi

PENDING_DIR="$CAIRN_DIR/t1-pending/$SESSION_ID"
PENDING_FILE="$PENDING_DIR/$TOOL_USE_ID.json"

case "$EVENT" in
  PreToolUse)
    mkdir -p "$PENDING_DIR" 2>/dev/null
    # Pending file content matches spec §2 tool-failure payload shape exactly:
    # {"tool":"Bash","cmd_snippet":"..."}  — no inner "ts" (top-level ts is
    # computed fresh by append_t1 during orphan promotion).
    # Tool name and cmd_snippet pass via argv (not stdin pipe-delim) so a pipe
    # character inside cmd_snippet cannot corrupt parsing.
    TMP="$PENDING_FILE.tmp.$$"
    python3 -c "
import json,sys
tool=sys.argv[1]
snip=sys.argv[2]
out=sys.argv[3]
json.dump({'tool':tool,'cmd_snippet':snip},open(out,'w',encoding='utf-8'))
" "$TOOL_NAME" "$CMD_SNIPPET" "$TMP" 2>/dev/null && mv "$TMP" "$PENDING_FILE" 2>/dev/null
    ;;
  PostToolUse)
    rm -f "$PENDING_FILE" 2>/dev/null
    ;;
  *)
    log_failure "unexpected event $EVENT"
    ;;
esac

exit 0
