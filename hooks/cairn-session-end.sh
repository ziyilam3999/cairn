#!/usr/bin/env bash
# Cairn H3 — SessionEnd hook.
# Two phases (synchronous, inline, 1s hard budget):
#   1. Final orphan sweep — belt-and-suspenders for pending files that survived
#      past the last Stop (session crash, etc).
#   2. Template summary — writes exactly one "summary" T1 line with the literal
#      template string and derivable fields.
set +e
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

CAIRN_DIR="$HOME/.claude/cairn"
FAILURES_LOG="$CAIRN_DIR/failures.log"

log_failure() {
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "cairn-session-end" "$1" >> "$FAILURES_LOG" 2>/dev/null
}

if ! command -v python3 >/dev/null 2>&1; then
  log_failure "python3 missing; skipping"
  exit 0
fi

SESSION_ID="$(cat "$CAIRN_DIR/last-session-id" 2>/dev/null)"
SESSION_DATE="$(cat "$CAIRN_DIR/last-session-date" 2>/dev/null)"
if [ -z "$SESSION_ID" ] || [ -z "$SESSION_DATE" ]; then
  log_failure "missing last-session-id or last-session-date"
  exit 0
fi

JSONL_FILE="$CAIRN_DIR/t1-run-scratch/$SESSION_DATE/$SESSION_ID.jsonl"
COUNTER_FILE="$JSONL_FILE.count"
PENDING_DIR="$CAIRN_DIR/t1-pending/$SESSION_ID"
START_FILE="$CAIRN_DIR/sessions/$SESSION_ID.start"

INPUT="$(cat 2>/dev/null)"
PROJECT_CWD="$(printf '%s' "$INPUT" | python3 -c "
import json,sys
try:
    print(json.load(sys.stdin).get('cwd',''))
except Exception:
    print('')
" 2>/dev/null)"
[ -z "$PROJECT_CWD" ] && PROJECT_CWD="$PWD"

read_counter() {
  local c=0
  [ -f "$COUNTER_FILE" ] && c="$(cat "$COUNTER_FILE" 2>/dev/null | tr -d '[:space:]')"
  [ -z "$c" ] && c=0
  echo "$c"
}
write_counter() {
  local tmp="$COUNTER_FILE.tmp.$$"
  printf '%s\n' "$1" > "$tmp" 2>/dev/null && mv "$tmp" "$COUNTER_FILE" 2>/dev/null
}

append_t1() {
  local kind="$1"
  local payload="$2"
  local cap="$3"
  local mode="${4:-drop}"
  local cur skip_increment
  cur="$(read_counter)"
  skip_increment=0
  if [ "$cur" -ge "$cap" ] 2>/dev/null; then
    if [ "$mode" = "drop" ]; then
      return 1
    fi
    skip_increment=1
  fi
  local ts line
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  line="$(python3 -c "
import json,sys
ts,sid,proj,kind,payload=sys.argv[1:6]
try:
    p=json.loads(payload)
except Exception:
    p={'raw':payload}
d={'ts':ts,'session_id':sid,'project':proj,'kind':kind,'payload':p}
s=json.dumps(d,separators=(',',':'))
for _ in range(6):
    if len(s.encode('utf-8'))<=500:
        break
    if isinstance(p,dict) and 'cmd_snippet' in p and p.get('cmd_snippet'):
        cur=p['cmd_snippet']
        if len(cur)>20:
            p['cmd_snippet']=cur[:len(cur)//2]
        else:
            p['cmd_snippet']=''
        d['payload']=p
        s=json.dumps(d,separators=(',',':'))
    else:
        break
if len(s.encode('utf-8'))>500:
    sys.exit(2)
print(s)
" "$ts" "$SESSION_ID" "$PROJECT_CWD" "$kind" "$payload" 2>/dev/null)"
  [ -z "$line" ] && return 1
  mkdir -p "$(dirname "$JSONL_FILE")" 2>/dev/null
  printf '%s\n' "$line" >> "$JSONL_FILE" 2>/dev/null
  if [ "$skip_increment" = "0" ]; then
    write_counter "$((cur+1))"
  fi
  return 0
}

# Phase 1 — Final orphan sweep
if [ -d "$PENDING_DIR" ]; then
  for pf in "$PENDING_DIR"/*.json; do
    [ -f "$pf" ] || continue
    payload="$(cat "$pf" 2>/dev/null)"
    [ -z "$payload" ] && rm -f "$pf" 2>/dev/null && continue
    payload="$(printf '%s' "$payload" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
d['reason']='orphaned_at_session_end'
print(json.dumps(d,separators=(',',':')))
" 2>/dev/null)"
    append_t1 "tool-failure" "$payload" 1000 drop
    rm -f "$pf" 2>/dev/null
  done
  rmdir "$PENDING_DIR" 2>/dev/null
fi

# Phase 2 — Template summary
NOW_EPOCH="$(date -u +%s)"
DURATION_S=0
if [ -f "$START_FILE" ]; then
  START_EPOCH="$(cat "$START_FILE" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$START_EPOCH" ] && [ "$START_EPOCH" -gt 0 ] 2>/dev/null; then
    DURATION_S="$((NOW_EPOCH - START_EPOCH))"
    [ "$DURATION_S" -lt 0 ] && DURATION_S=0
  else
    log_failure "start file $START_FILE unreadable or zero; duration fallback 0"
  fi
else
  log_failure "missing start file $START_FILE; duration fallback 0"
fi

TOOL_FAILURES=0
LESSONS=0
if [ -f "$JSONL_FILE" ]; then
  TOOL_FAILURES="$(grep -c '"kind":"tool-failure"' "$JSONL_FILE" 2>/dev/null)"
  LESSONS="$(grep -c '"kind":"lesson"' "$JSONL_FILE" 2>/dev/null)"
  [ -z "$TOOL_FAILURES" ] && TOOL_FAILURES=0
  [ -z "$LESSONS" ] && LESSONS=0
fi

SUMMARY_TEXT="Session $SESSION_ID · duration ${DURATION_S}s · $TOOL_FAILURES tool failures captured · $LESSONS lessons marked"

PAYLOAD="$(python3 -c "
import json,sys
print(json.dumps({
    'source':'template',
    'text':sys.argv[1],
    'tool_failures':int(sys.argv[2]),
    'lessons':int(sys.argv[3]),
    'duration_s':int(sys.argv[4])
},separators=(',',':')))
" "$SUMMARY_TEXT" "$TOOL_FAILURES" "$LESSONS" "$DURATION_S" 2>/dev/null)"

append_t1 "summary" "$PAYLOAD" 1100 always

exit 0
