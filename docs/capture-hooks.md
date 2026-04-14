# Cairn Capture Hooks — Spec

Cairn ships four bash scripts that Claude Code runs automatically at well-defined moments. Together they capture tool failures, lesson markers, and a per-session summary into a local JSONL store at `~/.claude/cairn/`. None of the hooks block the Claude Code TUI; all errors degrade to a local `failures.log`.

## ELI5

One script reads a primer when a session starts. One pairs every tool call's start and end so an unmatched start = a failure. One scans your last assistant message for `#cairn-stone:` lesson markers when a turn ends. One writes a one-line summary when the session ends. Every record is a single line in a notebook at `~/.claude/cairn/t1-run-scratch/{date}/{session-id}.jsonl`.

## Goal

Implement four harness-agnostic bash scripts at `~/.claude/hooks/cairn-*.sh`, registered in `~/.claude/settings.json`, all writing JSONL records to a shared T1 store. None block. None surface errors to the TUI.

---

## 1. Script layout

| Script | Hook events | Purpose |
|---|---|---|
| `cairn-session-start.sh` | `SessionStart` | H1: read primer, emit to stdout, write per-session anchor files |
| `cairn-tool-use.sh` | `PreToolUse`, `PostToolUse` (matcher `.*`) | H2a: pending-file pairing — Pre creates, Post deletes; orphans = failures |
| `cairn-stop.sh` | `Stop` | H2b: promote orphan pending files to `tool-failure` lines, then scan last assistant message for `#cairn-stone` lessons |
| `cairn-session-end.sh` | `SessionEnd` | H3: final orphan sweep + deterministic template summary line |

Every script:

- Shebang `#!/usr/bin/env bash`
- Invoked via `bash <script>` in `settings.json` (NTFS does not honor exec bit)
- LF line endings only — enforced at write time by `printf '%s\n'`
- Defensive header:

```bash
#!/usr/bin/env bash
set +e
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN  # prevent OAuth bypass via inherited env
```

The unset is defense-in-depth: any child process that inherits `ANTHROPIC_API_KEY` or `ANTHROPIC_AUTH_TOKEN` would resolve to that token instead of OAuth, silently burning pay-per-token credits. Applied to all four scripts.

---

## 2. T1 JSONL schema

**Path:** `~/.claude/cairn/t1-run-scratch/{YYYY-MM-DD}/{session-id}.jsonl`

The `{YYYY-MM-DD}` is computed once per session by H1 from `date -u +%Y-%m-%d` at SessionStart and frozen in `~/.claude/cairn/last-session-date`. H2a, H2b, and H3 all read that file so every hook for a given session writes to the same day-directory even if real wall-clock UTC crosses midnight mid-session.

**One record per line**, strict JSON (no trailing comma, no multiline).

**Required fields:**

```json
{"ts":"2026-04-13T09:12:33Z","session_id":"abc123","project":"/path/to/cwd","kind":"tool-failure|lesson|summary","payload":{}}
```

**`kind` enum:**
- `tool-failure` — emitted by H2b (orphan promotion) and H3 (final sweep)
- `lesson` — emitted by H2b on `#cairn-stone:` match
- `summary` — emitted by H3 once per session

**Payload shapes:**

```json
{"tool":"Bash","cmd_snippet":"...first 200 chars...","reason":"orphaned_pre_without_post"}
{"marker":"...captured text after #cairn-stone, max 500 chars..."}
{"source":"template","text":"...","tool_failures":4,"lessons":1,"duration_s":873}
```

**Session id source.** Read from hook payload stdin at key `session_id`. If absent, fall back to `unknown-{pid}-{YYYYMMDDhhmmss}`.

**H1 side-effect writes.** After resolving the session id, H1 atomically writes:

1. `~/.claude/cairn/last-session-id` — resolved id
2. `~/.claude/cairn/last-session-date` — `date -u +%Y-%m-%d`
3. `~/.claude/cairn/sessions/{session-id}.start` — UTC epoch seconds (sole source of truth for `duration_s`)
4. `~/.claude/cairn/t1-run-scratch/{YYYY-MM-DD}/{session-id}.jsonl` — touched empty via `: >> "$FILE"` so it exists before any other hook fires

The first three use `tmp + mv`; the touch is an O_APPEND no-op.

---

## 3. H1 — SessionStart primer

- Read `~/.claude/cairn/last-global-index.md` if present.
- If missing: emit zero bytes, exit 0 (never block session start).
- Size cap **8 KB** — truncate at byte 8192 and append `<!-- primer truncated at 8KB -->`.
- Emit to stdout as a system message (per `SessionStart` hook contract).
- Perform the four side-effect writes from §2.
- Tail the last 200 lines of `failures.log`; if any line within the last 24h, prepend a one-line warning to the primer.
- **Soft cost budget:** 500ms. Overruns log to `failures.log`; H1 still completes synchronously.

---

## 4. H2a — Tool-failure capture via Pre↔Post pairing

`PostToolUse` fires only on **successful** tool calls and its `tool_response` does not include `exit_code`, `is_error`, or `error`. Failures arrive on a separate `PostToolUseFailure` event. Rather than subscribe to that, Cairn uses Pre↔Post pairing — simpler and gives the full `tool_input` context.

**Mechanism.** `cairn-tool-use.sh` is registered on **both** `PreToolUse` and `PostToolUse` (matcher `.*`). It reads stdin JSON, branches on `hook_event_name`:

**On `PreToolUse`:**
- `mkdir -p ~/.claude/cairn/t1-pending/{session_id}/`
- Atomic write (`tmp + mv`) to `~/.claude/cairn/t1-pending/{session_id}/{tool_use_id}.json`:
  ```json
  {"ts":"...","tool_name":"Bash","cmd_snippet":"...first 200 chars..."}
  ```
- Cost budget: 30ms.

**On `PostToolUse`:**
- `rm -f ~/.claude/cairn/t1-pending/{session_id}/{tool_use_id}.json`
- Do **not** write a T1 line — success = resolved pending state.
- Cost budget: 20ms.

**Tool-input snippet rule.** For Bash, `cmd_snippet = tool_input.command[:200]`. For other tools, `cmd_snippet = json.dumps(tool_input, separators=(',',':'))[:200]`. This keeps the payload uniform.

**Atomicity.** Pending files are per-`tool_use_id`, so there is no append-concurrency concern. The jsonl appends in H2b and H3 rely on POSIX `O_APPEND` + `PIPE_BUF` atomicity (≥512 bytes on MSYS) with a hard 500-byte line cap. No flock.

**Overload counter.** `~/.claude/cairn/t1-run-scratch/{YYYY-MM-DD}/{session-id}.jsonl.count` is a 1-line integer file. Rules:

1. Orphan-promotion writes (H2b / H3) read the counter. If ≥**1000**, drop the jsonl write (still delete the pending file). Otherwise append + increment.
2. `lesson` and `summary` writes always proceed but cap counter at **1100** — once ≥ 1100 they still write the line but skip the increment.
3. The R-M-W is not race-free; bounded drift is acceptable because the counter is a safety valve, not an audit log.

---

## 5. H2b — Stop hook

Stop payload top-level fields: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, `stop_hook_active`, `last_assistant_message`.

Order of operations:

1. **Orphan promotion.** `ls ~/.claude/cairn/t1-pending/{session_id}/*.json 2>/dev/null`. For each pending file (orphan = Pre without Post = guaranteed failure):
   - Read the pending record.
   - Append a `tool-failure` T1 line with `payload = {"tool":...,"cmd_snippet":...,"reason":"orphaned_pre_without_post"}`.
   - Apply the 500-byte line cap and the §4 counter rules.
   - `rm -f` the pending file.
2. **Marker scan.** Read `last_assistant_message`. Match Python regex `#cairn-stone:?\s*([^\n]{1,500})`. On match, append a `lesson` T1 line with `payload.marker = group(1).strip()`.

**Cross-project note.** Because `~/.claude/settings.json` is global, hooks fire on every Claude Code session regardless of project. T1 data is correctly partitioned by `session_id` + day-directory, so there is no cross-project mixing in storage. Lesson capture is cross-project **by design** — the `cwd` field in every payload is the ground truth for "which project is this from"; downstream readers can filter by project.

**Cost budget:** 200ms.

---

## 6. H3 — SessionEnd template summary

- **Trigger:** `SessionEnd` hook. Runs synchronously inline. No async fork. Hard inner budget: 1 second; overrun logs to `failures.log` and still appends a summary line so the loop never runs dry.
- Re-runs the orphan-promotion sweep from §5 (belt-and-suspenders for sessions that crashed between a Pre and the corresponding Stop).
- Appends exactly one `summary` T1 line per session.

**Template text (literal):**

```
Session {session_id} · duration {duration_s}s · {N} tool failures captured · {M} lessons marked
```

Where:

- `session_id` ← `cat ~/.claude/cairn/last-session-id`
- `duration_s` ← `(date -u +%s) - cat ~/.claude/cairn/sessions/{session-id}.start`. Fallback `0` if the start file is missing (logged to `failures.log`).
- `N` ← `grep -c '"kind":"tool-failure"' <jsonl>`
- `M` ← `grep -c '"kind":"lesson"' <jsonl>`

**Summary payload:**

```json
{"source":"template","text":"Session abc123 · duration 873s · 4 tool failures captured · 1 lessons marked","tool_failures":4,"lessons":1,"duration_s":873}
```

There is no AI-generated summary path in this version — it would require an external API call and is intentionally out of scope.

---

## 7. Windows / MSYS notes

- **Reference env:** Git Bash on Windows 11 NTFS (MINGW64).
- **Paths:** forward slashes only; use `$HOME` not `~` in JSON. MSYS path-translate hazards mitigated by `cygpath -u` guarded by `command -v cygpath`. Colon-bearing arguments wrapped with `MSYS_NO_PATHCONV=1`.
- **Line endings:** LF only — enforced at write time by `printf '%s\n'` (never `echo`, never heredoc without `-e` review).
- **Executable bit:** not honored on NTFS — `settings.json` entries invoke `bash <script>` explicitly.
- **`jq` dependency:** none. JSON parsing uses `python3` one-liners.
- **`PIPE_BUF`:** POSIX mandates ≥ 512 bytes; MSYS2 inherits POSIX semantics. Every jsonl line is hard-capped at 500 bytes.

---

## 8. Hook registrations (`~/.claude/settings.json`)

```
SessionStart  → bash $HOME/.claude/hooks/cairn-session-start.sh   (matcher: startup|resume|clear|compact)
PreToolUse    → bash $HOME/.claude/hooks/cairn-tool-use.sh        (matcher: .*)
PostToolUse   → bash $HOME/.claude/hooks/cairn-tool-use.sh        (matcher: .*)
Stop          → bash $HOME/.claude/hooks/cairn-stop.sh
SessionEnd    → bash $HOME/.claude/hooks/cairn-session-end.sh
```

`cairn-tool-use.sh` appears in two event arrays but is a single script file (single hardlink) — the script branches on `hook_event_name`.

---

## 9. Capability probe

Written to `~/.claude/cairn/install-probe.json` at install time. Critical fields:

- `claude_code_version` — string
- `python3_ok` — boolean (critical)
- `cairn_time_ms` — `1` iff 5 samples of `date +%s%3N` across a 50ms window all match `^[0-9]{13}$` and at least 2 distinct low-3-digit substrings are observed; else `0`
- `session_start_stdout_ok` — boolean (critical)
- `post_tool_use_payload_shape` — object or null (critical)
- `stop_hook_exposes_assistant_text` — boolean
- `ok` — AND of the three critical checks

If `cairn_time_ms == 0`, all millisecond budgets degrade to 1-second telemetry resolution. Functional behavior is identical.

---

## 10. Failure aggregation

- All four hooks redirect errors to `~/.claude/cairn/failures.log` with format `{ts}\t{hook}\t{msg}` where `{ts}` is strict `YYYY-MM-DDTHH:MM:SSZ`.
- Hooks NEVER throw to Claude Code. Pattern: `set +e` + `trap '...' ERR` for structured logging + `exit 0` at EOF.
- H1 reads the tail (last 200 lines) of this log on next session start and surfaces counts ≥10/day as a warning line.

---

## Test cases

All binary. Each TC reads the session's day-directory via `cat ~/.claude/cairn/last-session-date`.

- **TC1** — `ls ~/.claude/hooks/cairn-session-start.sh ~/.claude/hooks/cairn-tool-use.sh ~/.claude/hooks/cairn-stop.sh ~/.claude/hooks/cairn-session-end.sh` exits 0 and prints 4 paths.
- **TC2** — `python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['ok'])" ~/.claude/cairn/install-probe.json` prints exactly `True`.
- **TC3** — Within 2 seconds of a fresh session start, all four H1 side-effect files exist (`last-session-id`, `last-session-date`, `sessions/{sid}.start`, empty jsonl).
- **TC4** — Inside a short session (< 100 tool calls), invoking `bash -c 'exit 1'` results in `grep -c '"kind":"tool-failure"' <jsonl>` returning ≥1 within 1 second after the next Stop hook.
- **TC4b** — After 1200 synthetic `exit 1` tool calls in one session, `grep -c '"kind":"tool-failure"' <jsonl>` returns exactly 1000 and the counter file reads `1000`.
- **TC5 [MANUAL]** — Trigger an assistant turn whose final message contains literal text `#cairn-stone: learned X`. Within 1 second after Stop, the jsonl file contains a line matching both `"kind":"lesson"` and `"marker":"learned X"`. Manual because there is no in-tree harness for coercing the assistant to emit a specific string. Skipped-as-pass with a log line if `stop_hook_exposes_assistant_text == false`.
- **TC6** — Within 3 seconds of session close, the jsonl contains exactly one line where `kind=="summary"`, `payload.source=="template"`, and `payload.duration_s`, `payload.tool_failures`, `payload.lessons` are integers ≥ 0. The `payload.text` matches the literal template with values substituted.
- **TC7** — With network disabled, close a session. Jsonl still contains a `"kind":"summary"` line with `"source":"template"`. Regression guard against any future revision that reintroduces network calls.
- **TC8** — On a fresh Windows 11 Git Bash install (no WSL, no `jq`, `python3` present), TC1–TC7 all pass.
- **TC9** — Inject a deliberate syntax error into `cairn-tool-use.sh`, run a tool call. The Claude Code session continues normally AND `~/.claude/cairn/failures.log` contains a line where column 2 (`\t`-split) equals `cairn-tool-use`.
