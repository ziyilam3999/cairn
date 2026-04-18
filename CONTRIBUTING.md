# Contributing

Thanks for your interest in contributing to `cairn`.

## Before you start

- Open an issue first for non-trivial changes so scope can be discussed before code is written
- Check existing issues and PRs to avoid duplicate work
- Note the v0.1.0 platform scope: Git Bash on Windows only (MINGW64 / MSYS). macOS / Linux / WSL2 / Cygwin support is planned for later releases.

## Development

Requires Git Bash (Windows), bash, and python3 on `PATH`.

```bash
git clone https://github.com/ziyilam3999/cairn.git
bash cairn/scripts/install.sh
```

The installer is idempotent — re-run anytime.

### What you just installed

- 4 hook scripts hardlinked into `~/.claude/hooks/`
- 5 hook entries merged into `~/.claude/settings.json`
- Storage directories under `~/.claude/cairn/`

See `README.md` → "What gets installed" for the full inventory.

## Proposing a change

1. Create a branch: `git checkout -b feat/short-description`
2. Make focused commits (conventional-commit prefixes preferred: `feat:`, `fix:`, `docs:`, `chore:`)
3. Push and open a PR
4. CI runs `bash -n` + `shellcheck --severity=error` on all scripts — both must pass

## Style

- Keep PRs focused on one concern
- Match the existing script style (bash, `#!/usr/bin/env bash`, `set -euo pipefail` where appropriate)
- Update README or `docs/capture-hooks.md` when user-facing behavior changes

## License

By contributing, you agree your contributions are licensed under the MIT License (see `LICENSE`).
