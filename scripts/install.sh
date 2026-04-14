#!/usr/bin/env bash
#
# Cairn standalone installer.
#
# Wires four capture hooks (cairn-session-start, cairn-tool-use, cairn-stop,
# cairn-session-end) into ~/.claude/hooks/ and merges five hook registrations
# into ~/.claude/settings.json. Idempotent. Re-run anytime.
#
# v0.1.0 supports Git Bash on Windows only (MINGW64/MSYS).

set -u

# ----------------------------------------------------------------------------
# Resolve REPO_DIR from this script's location (so install.sh works from any cwd).
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ----------------------------------------------------------------------------
# Platform detect.
# ----------------------------------------------------------------------------
IS_WINDOWS=false
case "$(uname -s)" in
  MINGW*|MSYS*)
    IS_WINDOWS=true
    ;;
  CYGWIN*)
    echo "[error] Cygwin is not supported in v0.1.0; please install Git Bash" >&2
    exit 1
    ;;
  Linux|Darwin)
    echo "[error] v0.1.0 supports Git Bash on Windows only; macOS/Linux support is planned for a future release" >&2
    exit 1
    ;;
  *)
    echo "[error] unrecognized platform: $(uname -s)" >&2
    exit 1
    ;;
esac

# ----------------------------------------------------------------------------
# Preflight: required commands.
# ----------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo "[error] python3 not on PATH; install Python 3 and re-run" >&2
  exit 1
fi
if $IS_WINDOWS && ! command -v powershell.exe >/dev/null 2>&1; then
  echo "[error] powershell.exe not on PATH; required for hardlink creation on Windows" >&2
  exit 1
fi

# ----------------------------------------------------------------------------
# to_win_path — MINGW /c/... → Windows C:\...
# Ported verbatim from upstream setup.sh (lines 27-33).
# ----------------------------------------------------------------------------
to_win_path() {
  if $IS_WINDOWS; then
    echo "$1" | sed 's|^/c/|C:\\|' | sed 's|/|\\|g'
  else
    echo "$1"
  fi
}

# ----------------------------------------------------------------------------
# create_link — symlink/junction/hardlink helper.
# Ported from upstream setup.sh:37-88 with ONE deviation:
#
#   The upstream idempotency short-circuit at lines 43-50 uses
#   `(Get-Item $link).Target` to decide whether the existing link already
#   points at the expected target. `.Target` returns $null for hardlinks
#   (it only populates for symlinks and junctions), so the short-circuit
#   never fires on an existing cairn hardlink and the function falls
#   through to the .bak backup branch, breaking idempotency on re-run.
#
#   Replaced with a LinkType-based check: if LinkType == "HardLink", call
#   `fsutil hardlink list` and look for the expected target in the output.
# ----------------------------------------------------------------------------
create_link() {
  local target="$1"
  local link="$2"
  local type="${3:-dir}"

  if $IS_WINDOWS; then
    local link_type
    link_type="$(powershell.exe -Command "(Get-Item '$(to_win_path "$link")' -ErrorAction SilentlyContinue).LinkType" 2>/dev/null | tr -d '\r')"
    if [ "$link_type" = "HardLink" ]; then
      local win_target
      win_target="$(to_win_path "$target")"
      # fsutil hardlink list prints all hardlink names for the file; if our target appears, we're already linked.
      if powershell.exe -Command "fsutil hardlink list '$(to_win_path "$link")'" 2>/dev/null | tr -d '\r' | grep -Fq "${win_target#C:}"; then
        echo "  [ok]   $link -> $target"
        return 0
      fi
    fi
  elif [ -L "$link" ]; then
    local current
    current="$(readlink "$link")"
    if [ "$current" = "$target" ]; then
      echo "  [ok]   $link -> $target"
      return 0
    fi
    rm "$link"
  fi

  if [ -e "$link" ]; then
    if $IS_WINDOWS; then
      powershell.exe -Command "Move-Item -Path '$(to_win_path "$link")' -Destination '$(to_win_path "${link}.bak")' -Force" 2>/dev/null
    else
      mv "$link" "${link}.bak"
    fi
    echo "  [backup] $link -> ${link}.bak"
  fi

  mkdir -p "$(dirname "$link")"

  if $IS_WINDOWS; then
    if [ "$type" = "dir" ]; then
      powershell.exe -Command "New-Item -ItemType Junction -Path '$(to_win_path "$link")' -Target '$(to_win_path "$target")'" > /dev/null 2>&1
    else
      powershell.exe -Command "New-Item -ItemType HardLink -Path '$(to_win_path "$link")' -Target '$(to_win_path "$target")'" > /dev/null 2>&1
    fi
  else
    ln -s "$target" "$link"
  fi
  echo "  [new]  $link -> $target"
}

# ----------------------------------------------------------------------------
# verify_hardlink — post-link sanity check.
#
# Windows hardlinks require link and target on the same NTFS volume. PowerShell
# silently fails if they are not, so we MUST verify after every create_link.
# ----------------------------------------------------------------------------
verify_hardlink() {
  local link="$1"
  if [ ! -f "$link" ]; then
    return 1
  fi
  if $IS_WINDOWS; then
    local lt
    lt="$(powershell.exe -Command "(Get-Item '$(to_win_path "$link")').LinkType" 2>/dev/null | tr -d '\r')"
    if [ "$lt" = "HardLink" ]; then
      return 0
    fi
    return 1
  fi
  return 0
}

# ============================================================================
# Main install
# ============================================================================
echo "=== Cairn install ==="
echo "  REPO_DIR: $REPO_DIR"
echo "  HOME:     $HOME"

mkdir -p "$HOME/.claude/cairn/t1-run-scratch" \
         "$HOME/.claude/cairn/t1-pending" \
         "$HOME/.claude/cairn/sessions" \
         "$HOME/.claude/hooks"

# Link the four cairn hooks (explicit list — never a glob).
HOOKS=(cairn-session-start.sh cairn-tool-use.sh cairn-stop.sh cairn-session-end.sh)
for hook in "${HOOKS[@]}"; do
  src="$REPO_DIR/hooks/$hook"
  dst="$HOME/.claude/hooks/$hook"
  if [ ! -f "$src" ]; then
    echo "[error] missing source hook: $src" >&2
    exit 1
  fi
  create_link "$src" "$dst" file
  if ! verify_hardlink "$dst"; then
    echo "" >&2
    echo "[error] Windows hardlink verification failed for $dst" >&2
    echo "[error] Likely cause: cairn clone and \$HOME are on different volumes." >&2
    echo "[error] Clone cairn onto the same drive as \$HOME (typically C:\\) and retry." >&2
    exit 1
  fi
done

# Run the capability probe (writes ~/.claude/cairn/install-probe.json).
if [ -f "$REPO_DIR/scripts/cairn-probe.sh" ]; then
  bash "$REPO_DIR/scripts/cairn-probe.sh" || true
else
  echo "[error] missing $REPO_DIR/scripts/cairn-probe.sh" >&2
  exit 1
fi

# Merge five hook registrations into ~/.claude/settings.json via python3.
# This block is ported verbatim from upstream setup.sh:228-269 EXCEPT the
# json.load call is wrapped in try/except so we never silently overwrite a
# corrupt settings file.
SETTINGS="$HOME/.claude/settings.json"
python3 - "$SETTINGS" <<'PYEOF'
import json, sys, re, os, shutil, datetime

path = sys.argv[1]
if not os.path.exists(path):
    d = {}
else:
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except json.JSONDecodeError as e:
        ts = datetime.datetime.utcnow().strftime("%Y%m%d-%H%M%S")
        backup = f"{path}.bak.cairn-install-{ts}"
        shutil.copy2(path, backup)
        sys.stderr.write(
            f"[error] {path} is not valid JSON ({e}); original backed up to {backup}.\n"
            f"[error] Fix the file and re-run: bash scripts/install.sh\n"
        )
        sys.exit(1)

d.setdefault("hooks", {})

def canon(s):
    s = s.replace("$HOME", "~")
    s = re.sub(r"\\", "/", s)
    s = re.sub(r'["\']', "", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s

def add(event, entry):
    arr = d["hooks"].setdefault(event, [])
    new_canons = {canon(h.get("command", "")) for h in entry.get("hooks", [])}
    for existing in arr:
        ex_canons = {canon(h.get("command", "")) for h in existing.get("hooks", [])}
        if ex_canons == new_canons and existing.get("matcher") == entry.get("matcher"):
            return
    arr.append(entry)

cmd = lambda script: {"type": "command", "command": f"bash ~/.claude/hooks/{script}", "timeout": 10}

add("SessionStart", {"matcher": "startup|resume|clear|compact", "hooks": [cmd("cairn-session-start.sh")]})
add("PreToolUse",   {"matcher": ".*", "hooks": [cmd("cairn-tool-use.sh")]})
add("PostToolUse",  {"matcher": ".*", "hooks": [cmd("cairn-tool-use.sh")]})
add("Stop",         {"hooks": [cmd("cairn-stop.sh")]})
add("SessionEnd",   {"hooks": [cmd("cairn-session-end.sh")]})

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
os.replace(tmp, path)
print(f"  [ok] merged 5 cairn hook entries into {path}")
PYEOF

merge_rc=$?
if [ $merge_rc -ne 0 ]; then
  exit $merge_rc
fi

# Report probe verdict (non-fatal warning).
# Read via bash $HOME (not python's expanduser, which uses USERPROFILE on Windows
# and would bypass a HOME override during sandbox testing).
ok="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['ok'])" "$HOME/.claude/cairn/install-probe.json" 2>/dev/null || echo "False")"
if [ "$ok" = "True" ]; then
  echo "[ok] cairn installed"
else
  echo "[warn] probe ok=false — see ~/.claude/cairn/install-probe.json"
fi
exit 0
