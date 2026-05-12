# User-Global Claude Code Instructions

This file is synced via the `claude-shared` repo to every Claude Code container
you run. It carries your identity, preferences, and a small set of standing
instructions that must hold across every session. **Edit it to suit yourself.**

## About the user

(Add personal details here. Keep abstract — no real names of internal
products, customers, hostnames, or environments. Use placeholders like
`<EMPLOYER>`, `<TEAM>`, `<INTERNAL_HOST>` when in doubt.)

## Standing instructions

### Plan naming

When creating a plan file in `~/.claude/plans/`, use a descriptive
kebab-case name reflecting the project and task. Examples:

- `repo-feature-x-design.md`
- `service-y-bug-investigation.md`
- `migration-from-a-to-b.md`

Do not use whimsical adjective-noun-name combinations (e.g.
`sparkling-hammock`, `eager-simon`).

### Plan drafts

While iterating on a plan, name it `~/.claude/plans/draft-<descriptive>.md`.
Rename to `<descriptive>.md` (via `git mv` so history is preserved) only when
the plan is finalized. `draft-*.md` files are still synced and committed so
iteration survives a container restart, but the `draft-` prefix signals that
the plan is not yet stable.

### No secrets in synced files

Never write any of the following into memory files, plan files, this
`CLAUDE.md`, or any other file under `~/claude-shared/`:

- Secrets, API tokens, passwords, signed URLs, JWTs
- Internal hostnames, internal IP addresses, internal URLs
- Customer names, employer-internal codenames, project codenames
- Real usernames, real email addresses (other than your own public one)
- Production database names, prod resource identifiers

Refer to such values abstractly using placeholders:

- `<API_TOKEN>`, `<GH_TOKEN>`, `<AWS_KEY>`
- `<INTERNAL_HOST>`, `<PROD_DB_URL>`, `<INTERNAL_URL>`
- `<CUSTOMER>`, `<TEAM>`, `<CODENAME>`

If a user pastes a real secret or internal identifier into a session, treat
it as ephemeral conversation context only. Do not echo it back; do not
persist it to any file under `~/claude-shared/` or its symlinked targets.

A mandatory pre-commit secret scanner (`hooks/scan-secrets.sh`) is the last
line of defense. It will block the commit if any of the patterns above leak
through, but content discipline at write time is the primary protection.

### Commit messages for claude-shared

The Stop hook (`hooks/push.sh`) auto-commits changes inside the
`~/claude-shared/` working tree at the end of every turn so work survives a
container exit and the pre-commit secret scan runs on every change. The
default commit message is `sync <TIMESTAMP>`, which makes for noisy history.

To leave a descriptive message instead, write a one-line summary (multi-line
is fine, first line is the subject) to `~/claude-shared/.commit-msg-pending`
before your turn ends. The Stop hook will use the file's contents as the
commit message and delete the file after a successful commit. The file is
gitignored, so a stray pending-message never gets committed itself.

Apply this when you make a non-trivial change inside `~/claude-shared/` (or
to anything symlinked into it: `~/.claude/CLAUDE.md`, plans, memory, slash
commands, hooks, etc.). For trivial tweaks the sync fallback is fine — don't
write a pending message just to write one.

Never rebase or force-push `main` of your claude-shared fork. Other live
Claude sessions across containers pull from the same branch; rewriting
history breaks them.

### Per-project consistency (optional)

If you want a project's per-project Claude memory to sync across containers,
the project must be checked out at the *same absolute path* in every
container. The project "slug" Claude uses (e.g. `-home-you-code-myrepo`)
encodes that path, and the symlinks in `~/.claude/projects/<slug>/memory/`
won't line up otherwise. Add the absolute path to `PROJECT_DIRS` in
`install.sh` and keep the checkout location consistent across containers.
