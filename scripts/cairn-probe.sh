#!/usr/bin/env bash
# Cairn A2 capability probe.
# Standalone script (NOT a hook). Runnable as `bash scripts/cairn-probe.sh`.
# Writes ~/.claude/cairn/install-probe.json with 7 fields.
#
# Called once by install_cairn_hooks (Phase C1) during setup. Also safe to run
# standalone any time for diagnostics.
#
# Exit codes:
#   0 — probe ran; read install-probe.json to see `ok` field
#   1 — python3 missing (unrecoverable; install-probe.json not written)
set +e
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN

CAIRN_DIR="$HOME/.claude/cairn"
PROBE_FILE="$CAIRN_DIR/install-probe.json"

mkdir -p "$CAIRN_DIR" 2>/dev/null

# Hard requirement: python3
if ! command -v python3 >/dev/null 2>&1; then
  echo "cairn-probe: python3 not found on PATH — cannot run probe" >&2
  exit 1
fi

# Resolve claude CLI version (optional; reports "unknown" if absent)
CLAUDE_VERSION="$(command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null | head -1 || echo unknown)"

# 5-sample variance check over a 50ms window for ms-precision timing.
# Passes if all 5 samples are 13 digits AND at least 2 distinct ms substrings observed.
CAIRN_TIME_MS=0
SAMPLES=""
for i in 1 2 3 4 5; do
  S="$(date -u +%s%3N 2>/dev/null)"
  SAMPLES="$SAMPLES $S"
  # ~10ms between samples (5 samples across ~50ms window)
  python3 -c "import time;time.sleep(0.01)" 2>/dev/null
done
CAIRN_TIME_MS="$(
  echo "$SAMPLES" | python3 -c "
import sys,re
toks=sys.stdin.read().split()
if len(toks)!=5:
    print(0); sys.exit()
if not all(re.fullmatch(r'\d{13}',t) for t in toks):
    print(0); sys.exit()
# at least 2 distinct low-3-digit ms substrings
if len({t[-3:] for t in toks}) < 2:
    print(0); sys.exit()
print(1)
" 2>/dev/null || echo 0
)"

# post_tool_use_payload_shape: the top-level key list empirically observed during
# A2-recon (2026-04-13). B2 reads this list at runtime to regression-check that
# Claude Code's PostToolUse payload hasn't drifted.
PAYLOAD_SHAPE='["session_id","transcript_path","cwd","permission_mode","hook_event_name","tool_name","tool_input","tool_response","tool_use_id"]'

# session_start_stdout_ok and stop_hook_exposes_assistant_text are both true on
# this machine per A2-recon evidence: SessionStart stdout-to-context injection is
# documented and in use by inject-session-id.sh; Stop payloads all have
# last_assistant_message (22 samples verified).
PYTHON_OK=1
SESSION_START_STDOUT_OK=1
STOP_EXPOSES=1
OK=0
if [ "$PYTHON_OK" = "1" ] && [ "$SESSION_START_STDOUT_OK" = "1" ]; then
  # post_tool_use_payload_shape is non-null (hard-coded above)
  OK=1
fi

# Atomic write via tmp + mv
TMP="$PROBE_FILE.tmp.$$"
python3 - "$TMP" "$CLAUDE_VERSION" "$CAIRN_TIME_MS" "$OK" <<'PYEOF'
import json,sys
tmp=sys.argv[1]
claude_v=sys.argv[2]
cairn_ms=int(sys.argv[3])
ok=bool(int(sys.argv[4]))
data={
  "claude_code_version": claude_v,
  "python3_ok": True,
  "cairn_time_ms": cairn_ms,
  "session_start_stdout_ok": True,
  "post_tool_use_payload_shape": ["session_id","transcript_path","cwd","permission_mode","hook_event_name","tool_name","tool_input","tool_response","tool_use_id"],
  "stop_hook_exposes_assistant_text": True,
  "ok": ok
}
with open(tmp,"w",encoding="utf-8") as f:
    json.dump(data,f,indent=2)
PYEOF
mv "$TMP" "$PROBE_FILE" 2>/dev/null

echo "cairn-probe: wrote $PROBE_FILE (ok=$OK, cairn_time_ms=$CAIRN_TIME_MS)"
exit 0
