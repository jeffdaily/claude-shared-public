# claude-shared (public starter)

A starter template for personal cross-container sync of Claude Code config:
identity, preferences, plans, project memories, user-level skills, slash
commands, and agents. Each container symlinks selected paths under
`~/.claude/` into a per-user fork of this repo's working tree, and Claude
Code hooks auto-pull on session start and auto-push on session stop.

> **This starter is intentionally public so you can read and audit it.
> Fork it to a PRIVATE repo of your own before populating it with
> anything sensitive.** The installer enforces that the configured repo is
> private and will refuse to run otherwise.

## What gets synced

| `~/.claude/...` path | `~/claude-shared/...` target | Notes |
|---|---|---|
| `CLAUDE.md` | `CLAUDE.md` | Identity, plan rules, no-secrets rule |
| `settings.json` | `settings.shared.json` | Portable bits only |
| `plans/` | `plans/` | Flat layout; descriptive names |
| `skills/`, `commands/`, `agents/` | same | User-global only |
| `projects/<slug>/memory/` | same | Optional, opt-in via `PROJECT_DIRS` |

**Not synced (per-container/local only):** `.credentials.json`, sessions,
shell snapshots, history, cache, file-history, backups, mcp auth cache,
`settings.local.json` (your per-container overrides), `.commit-msg-pending`,
and anything else matching `.gitignore`.

## Setup (one time, per user)

1. Fork this repo to your own GitHub account (e.g. `github.com/YOU/claude-shared`).
2. **Make your fork private** — `gh repo edit YOU/claude-shared --visibility private`.
3. Edit `install.sh` and set `GH_OWNER` to your username (or export
   `CLAUDE_SHARED_OWNER=YOU` whenever you run it).
4. Optionally edit `PROJECT_DIRS` in `install.sh` to opt into per-project
   memory sync for projects that live at the same absolute path on every
   container you use.

## Setup (one time, per container)

Inside the running container, after `docker run`:

```sh
# bootstrap.sh installs gh, runs gh auth login, runs claude auth login.
# It is meant to be vendored into your Dockerfile project (see the header
# in the script).
bash /path/to/bootstrap.sh

# Or do the steps manually:
sudo apt-get update && sudo apt-get install -y gh                # per github cli install docs
gh auth login && gh auth setup-git                               # one-time per container
claude auth login                                                # one-time per container

# Then clone your fork + install (replace YOU with your username):
git clone https://github.com/YOU/claude-shared.git ~/claude-shared
CLAUDE_SHARED_OWNER=YOU ~/claude-shared/install.sh
```

`bootstrap.sh` is idempotent (each step short-circuits if already done) and
keeps the auth-setup steps version-controlled in one canonical place.

The manual flow also works in foreign environments (any Linux box with `gh`,
`git`, `jq`, and `claude` installed). `install.sh` must run *inside* a
running container because it gates on `gh auth status`.

## How sync works

- **`SessionStart` hook** runs `hooks/pull.sh`: `git pull --rebase` under a
  `flock`, with a `timeout`. Never blocks a session; logs to `.sync.log`.
- **`Stop` hook** runs `hooks/push.sh`: stages changes, runs
  `hooks/scan-secrets.sh`, commits with a generic identity
  (`claude-sync@local`, no hostname, no session id), pushes. Retries once on
  push failure via `pull --rebase`. On rebase conflict, parks the commit on
  `conflict/<random-id>-<timestamp>` and surfaces the branch to the user.
- **Descriptive commit messages.** Write a subject (or full message) to
  `.commit-msg-pending` before your turn ends; the Stop hook uses it and
  deletes the file after a successful commit. Falls back to `sync <TIMESTAMP>`
  if no pending message exists. The file is gitignored.
- **Statusline** reads the latest line of `.sync.log` and renders it
  persistently at the bottom of the terminal, so the most recent pull/push
  result (e.g. `push: pushed 3 file(s)` or `pull: ok (up to date)`) is always
  visible without leaving the session.

## Security

Your fork must remain **private**. `install.sh` aborts if it detects public
visibility. The pre-commit secret scan in `hooks/scan-secrets.sh` greps the
staged diff for AWS keys, GitHub/Slack tokens, JWTs, private-key headers,
and sensitive-word-adjacent high-entropy assignments. Content discipline is
documented in `CLAUDE.md` as a standing instruction that rides along to every
session.

## Bundled extras

- **`/plans` slash command** (`commands/plans.md` + `commands/plans-list.sh`):
  lists everything in `~/.claude/plans/`, sorted oldest-first, with summaries
  from each plan's first heading, word-wrapped to your terminal width.
  Detects the real terminal width by walking up the parent process tree to
  find a tty, since slash-command subshells have no tty of their own.
