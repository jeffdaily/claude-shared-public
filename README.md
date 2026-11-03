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

## Setup (one time, per Windows machine)

Windows is supported by the same `install.sh`, run from **Git Bash** (not
PowerShell or cmd). Two requirements beyond the Linux ones:

- **Developer Mode ON** (Settings > System > For developers), so unprivileged
  symlinks are allowed. Without it `install.sh` aborts with instructions.
  Running Git Bash as Administrator also works.
- `gh`, `jq`, `git` on the Git Bash `PATH`, and `gh auth login` done.

```sh
git clone https://github.com/YOU/claude-shared.git /d/code/claude-shared
CLAUDE_SHARED_OWNER=YOU /d/code/claude-shared/install.sh
```

The checkout does not have to live at `~/claude-shared`: the installer and the
hooks locate the repo from their own path. A `~/claude-shared` symlink to the
real checkout is created anyway so the Linux-shaped paths in these docs keep
working.

What differs from Linux, all handled by the installer:

| | Linux | Windows | Why |
|---|---|---|---|
| `~/.claude/settings.json` | symlink to `settings.shared.json` | real file; shared keys merged in, local keys kept | The hook commands must name the Git Bash binary, so they are not portable. **Re-run `install.sh` after editing `settings.shared.json`.** |
| Hook commands | `~/claude-shared/hooks/x.sh` | `"C:\...\bash.exe" -lc "/d/.../hooks/x.sh"` | The hook may be spawned by `cmd.exe`, which cannot run a `.sh`. `-lc` (login shell) is required: a bare `-c` inherits the Windows `PATH`, which has no `/mingw64/bin`, so `git`/`timeout`/`openssl` would be missing. |
| `PROJECT_DIRS` memory slug | `/home/me/myrepo` -> `-home-me-myrepo` | `D:/code/myrepo` -> `D--code-myrepo` | Claude derives the slug from the checkout path, so the same project has separate memory on each platform. |

Windows traps the scripts defend against; each fails silently if you hand-roll
the setup:

- **`ln -s` in Git Bash copies instead of linking** unless
  `MSYS=winsymlinks:nativestrict` is set. A copy looks installed and then never
  syncs again. `install.sh` sets it and verifies each result is really a link.
- **`flock` does not exist in Git Bash.** A missing binary exits 127, which
  would take the hooks' lock-busy branch, so they would exit 0 every turn while
  logging a healthy-looking message and never sync. `hooks/lib.sh` falls back
  to an atomic `mkdir` lock (with stale-lock breaking, since a `mkdir` lock is
  not released when the holder dies).
- **Process spawning is far costlier than on Linux.** `scan-secrets.sh`
  matches with bash's built-in `=~` instead of piping each added line into
  `grep`, which on Windows stalled the `Stop` hook for minutes on large diffs.
- **CRLF checkouts.** `.gitattributes` pins `eol=lf`: a clone with
  `core.autocrlf=true` would check the `.sh` files out as CRLF, which breaks
  the shebang and leaves a stray CR on every unquoted value.

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
- **Status line** (`hooks/statusline.sh`): surfaces the most recent
  *meaningful* line from `.sync.log` (pushed, blocked, conflict, …) rather
  than the boring `no changes` no-op that the Stop hook writes most turns,
  and appends `(idle)` when nothing interesting has happened since — so you
  can still tell the sync hooks are alive. Wired up via `statusLine` in
  `settings.shared.json`.
