#!/usr/bin/env bash
# Cairn H2b — Stop hook.
# Runs at every assistant-turn end. Two phases:
#   1. Orphan promotion — any pending files (Pre-without-Post) for this session
#      become tool-failure T1 lines; pending files deleted.
#   2. Lesson scan — reads last_assistant_message from stdin and extracts any
#      #cairn-stone: markers as lesson T1 lines.
#
# Budget: 200ms. Always exit 0.
set +e
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

CAIRN_DIR="$HOME/.claude/cairn"
FAILURES_LOG="$CAIRN_DIR/failures.log"

log_failure() {
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "cairn-stop" "$1" >> "$FAILURES_LOG" 2>/dev/null
}

if ! command -v python3 >/dev/null 2>&1; then
  log_failure "python3 missing; skipping"
  exit 0
fi

INPUT="$(cat 2>/dev/null)"

SESSION_ID="$(cat "$CAIRN_DIR/last-session-id" 2>/dev/null)"
SESSION_DATE="$(cat "$CAIRN_DIR/last-session-date" 2>/dev/null)"
if [ -z "$SESSION_ID" ] || [ -z "$SESSION_DATE" ]; then
  log_failure "missing last-session-id or last-session-date"
  exit 0
fi

JSONL_FILE="$CAIRN_DIR/t1-run-scratch/$SESSION_DATE/$SESSION_ID.jsonl"
COUNTER_FILE="$JSONL_FILE.count"
PENDING_DIR="$CAIRN_DIR/t1-pending/$SESSION_ID"

# Resolve cwd (for "project" field in T1 lines) from stdin, fall back to PWD
PROJECT_CWD="$(printf '%s' "$INPUT" | python3 -c "
import json,sys
try:
    print(json.load(sys.stdin).get('cwd',''))
except Exception:
    print('')
" 2>/dev/null)"
[ -z "$PROJECT_CWD" ] && PROJECT_CWD="$PWD"

# Counter helpers
read_counter() {
  local c=0
  [ -f "$COUNTER_FILE" ] && c="$(cat "$COUNTER_FILE" 2>/dev/null | tr -d '[:space:]')"
  [ -z "$c" ] && c=0
  echo "$c"
}
write_counter() {
  local v="$1"
  local tmp="$COUNTER_FILE.tmp.$$"
  printf '%s\n' "$v" > "$tmp" 2>/dev/null && mv "$tmp" "$COUNTER_FILE" 2>/dev/null
}

# Append a T1 line, enforcing 500-byte cap and counter rules.
# Args: kind, payload_json, counter_cap, mode
#   mode=drop   — skip write when counter >= cap (tool-failure path, cap=1000)
#   mode=always — always write; only skip counter increment past cap
#                 (lesson path, cap=1100 — spec §4 rule 3)
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
      return 1  # tool-failure path: drop the write entirely
    fi
    skip_increment=1  # always-write path: still append, just don't bump counter
  fi
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local line
  line="$(python3 -c "
import json,sys
ts,sid,proj,kind,payload=sys.argv[1:6]
try:
    p=json.loads(payload)
except Exception:
    p={'raw':payload}
d={'ts':ts,'session_id':sid,'project':proj,'kind':kind,'payload':p}
s=json.dumps(d,separators=(',',':'))
# Loop truncate cmd_snippet until line <= 500 bytes (PIPE_BUF atomicity).
# On each iteration: halve cmd_snippet. If it drops below 20 chars, drop
# entirely. Give up after 6 iterations (safety bound).
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
# Final guard: if still >500 even after dropping cmd_snippet, skip the write.
if len(s.encode('utf-8'))>500:
    sys.exit(2)
print(s)
" "$ts" "$SESSION_ID" "$PROJECT_CWD" "$kind" "$payload" 2>/dev/null)"
  if [ -z "$line" ]; then
    return 1
  fi
  mkdir -p "$(dirname "$JSONL_FILE")" 2>/dev/null
  printf '%s\n' "$line" >> "$JSONL_FILE" 2>/dev/null
  if [ "$skip_increment" = "0" ]; then
    write_counter "$((cur+1))"
  fi
  return 0
}

# Phase 1 — Orphan promotion
if [ -d "$PENDING_DIR" ]; then
  for pf in "$PENDING_DIR"/*.json; do
    [ -f "$pf" ] || continue
    payload="$(cat "$pf" 2>/dev/null)"
    [ -z "$payload" ] && rm -f "$pf" 2>/dev/null && continue
    # Inject reason field via python
    payload="$(printf '%s' "$payload" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    d={}
d['reason']='orphaned_pre_without_post'
print(json.dumps(d,separators=(',',':')))
" 2>/dev/null)"
    append_t1 "tool-failure" "$payload" 1000 drop
    rm -f "$pf" 2>/dev/null
  done
  # Remove pending dir if empty
  rmdir "$PENDING_DIR" 2>/dev/null
fi

# Phase 2 — Lesson scan
LESSON="$(printf '%s' "$INPUT" | python3 -c "
import json,sys,re
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
msg=d.get('last_assistant_message') or ''
m=re.search(r'#cairn-stone:?\s*([^\n]{1,500})', msg)
if m:
    print(m.group(1).strip())
" 2>/dev/null)"

if [ -n "$LESSON" ]; then
  payload="$(python3 -c "
import json,sys
print(json.dumps({'marker':sys.argv[1]},separators=(',',':')))
" "$LESSON" 2>/dev/null)"
  append_t1 "lesson" "$payload" 1100 always
fi

exit 0
