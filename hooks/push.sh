#!/usr/bin/env bash
# Stop hook: commit and push any changes in the claude-shared working tree.
# Generic identity (no hostname, no session id). Pre-commit secret scan.

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LOG_TAG=push

[ -d "${REPO}/.git" ] || exit 0

# Generic identity for every git invocation in this script (commit + rebase
# replays). Without this, the rebase fallback below fails on containers where
# git user.email/user.name aren't configured globally, and the conflict-park
# path silently discards local commits via `git reset --hard`.
export GIT_AUTHOR_NAME=claude-sync
export GIT_AUTHOR_EMAIL=claude-sync@local
export GIT_COMMITTER_NAME=claude-sync
export GIT_COMMITTER_EMAIL=claude-sync@local

run_under_lock() {
  cd "${REPO}"

  git add -A
  # Untrack anything .gitignore covers. `git add -A` keeps updating a path that
  # was tracked before it was ignored (and re-adds one left unmerged by a
  # modify/delete stash pop), so an ignore rule alone never takes effect.
  git ls-files -ci --exclude-standard -z | xargs -0 -r git rm --cached -q --
  if git diff --cached --quiet; then
    log "no changes"
    return 0
  fi

  local nfiles
  nfiles=$(git diff --cached --name-only | wc -l)

  # Secret scan before commit. On failure, unstage and surface to user.
  if ! "${REPO}/hooks/scan-secrets.sh"; then
    git reset --quiet
    log "blocked (secret scan rejected ${nfiles} file(s))"
    return 1
  fi

  # Prefer a descriptive message left by the model in .commit-msg-pending.
  # File is gitignored. Removed only after a successful commit so a transient
  # failure doesn't lose the message.
  local msg_file="${REPO}/.commit-msg-pending"
  local msg
  if [ -s "${msg_file}" ]; then
    msg=$(cat "${msg_file}")
  else
    msg="sync $(date -u +%FT%TZ)"
  fi
  if ! git -c user.email=claude-sync@local -c user.name=claude-sync commit -q -F - <<< "${msg}"; then
    log "commit failed"
    return 1
  fi
  rm -f "${msg_file}"

  # Capture stderr so we can tell an auth/network failure (transient: expired
  # token, unreachable host) apart from a non-fast-forward (our branch diverged
  # and needs a rebase). The two demand opposite remedies.
  local push_err
  if push_err=$(timeout 30 git push --quiet 2>&1); then
    log "pushed ${nfiles} file(s)"
    return 0
  fi
  printf '%s\n' "${push_err}" >> "${LOG}"

  # Auth/network failure: the commit is fine on main, the remote is just
  # unreachable. Leave it on main to retry next turn. Parking it on a conflict/*
  # branch and resetting main -- the genuine-conflict remedy below -- would
  # litter a branch and rewind main on every turn while a token stays expired,
  # which is exactly wrong. This is not a conflict; do not call it one.
  # "Repository not found" is what GitHub returns for a PRIVATE repo the current
  # credential cannot see -- e.g. the gh credential helper is serving a different
  # active account's token after a `gh auth switch`. That is an auth failure, not
  # a divergence, and must never reach the conflict path below.
  if printf '%s' "${push_err}" | grep -qiE 'authentication failed|could not read username|invalid username or token|password authentication is not supported|could not resolve host|connection (timed out|refused)|failed to connect|unable to access|operation timed out|repository not found|permission denied|403 forbidden'; then
    local ahead
    ahead=$(git rev-list --count @{upstream}..HEAD 2>/dev/null || echo '?')
    printf 'claude-shared: push failed (auth/network -- refresh the GitHub token); %s local commit(s) kept on main, will retry next turn\n' "${ahead}" >&2
    log "push failed (auth/network); ${ahead} commit(s) kept on main"
    return 1
  fi

  # Remote rejected our ref (likely non-fast-forward): integrate by rebasing.
  log "push rejected (non-ff?); retrying after pull --rebase"
  if timeout 30 git pull --rebase --autostash --quiet 2>>"${LOG}" \
     && timeout 30 git push --quiet 2>>"${LOG}"; then
    log "pushed ${nfiles} file(s) after rebase"
    return 0
  fi

  # Genuine rebase conflict (divergent history that won't replay): park the
  # commit on a side branch so it is never lost, then reset main to upstream.
  #
  # The branch name must be a LEGAL REFNAME. An ISO-8601 timestamp is not --
  # `git check-ref-format` forbids colons -- so `date -u +%FT%TZ` here silently
  # made `git branch` fail while the reset below still ran, destroying exactly
  # the commit this path claims to preserve. Use a colon-free stamp, and never
  # reset unless the park demonstrably succeeded.
  git rebase --abort 2>/dev/null || true
  local branch="conflict/$(openssl rand -hex 4 2>/dev/null || printf '%s' "$RANDOM$RANDOM")-$(date -u +%Y%m%dT%H%M%SZ)"
  if ! git branch -q "${branch}" HEAD 2>>"${LOG}"; then
    printf 'claude-shared: push conflict, and parking branch %s could NOT be created; local commit(s) left on main, nothing reset\n' "${branch}" >&2
    log "conflict park FAILED (${branch}); commit(s) kept on main, no reset"
    return 1
  fi
  git reset --hard --quiet "$(git rev-parse @{upstream})" 2>/dev/null || git reset --hard --quiet origin/main 2>/dev/null || true
  printf 'claude-shared: push conflict; commit parked on local branch %s\n' "${branch}" >&2
  log "conflict parked on ${branch}"
  return 1
}

rc=0
sync_lock run_under_lock || rc=$?

exit "${rc}"
