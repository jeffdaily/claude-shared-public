#!/usr/bin/env bash
# SessionStart hook: pull latest from claude-shared repo.
# Never blocks a session — exits 0 on any failure and logs to .sync.log.

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LOG_TAG=pull

[ -d "${REPO}/.git" ] || exit 0

# Rebase replays need a git identity even when there's nothing to replay
# (autostash pop can also need one). Set generic, container-independent values
# so this hook works on hosts without global git config.
export GIT_AUTHOR_NAME=claude-sync
export GIT_AUTHOR_EMAIL=claude-sync@local
export GIT_COMMITTER_NAME=claude-sync
export GIT_COMMITTER_EMAIL=claude-sync@local

do_pull() {
  if out=$(timeout 15 git -C "${REPO}" pull --rebase --autostash 2>&1); then
    # pull exits 0 even when popping the autostash conflicts, leaving unmerged
    # files that make every later pull fail and that push.sh would commit with
    # conflict markers. The stash still holds every local change, so park it on
    # a conflict/* branch and put the tree back on upstream.
    if [ -n "$(git -C "${REPO}" ls-files -u)" ]; then
      local branch="conflict/autostash-$(date -u +%Y%m%dT%H%M%SZ)"
      if git -C "${REPO}" branch -q "${branch}" 'stash@{0}' 2>>"${LOG}"; then
        git -C "${REPO}" reset --hard --quiet
        git -C "${REPO}" stash drop --quiet
        log "failed (autostash conflict; local changes parked on ${branch})"
      else
        log "failed (autostash conflict; could not park, tree left unmerged)"
      fi
      return 0
    fi
    if printf '%s' "${out}" | grep -q 'Already up to date'; then
      log "ok (up to date)"
    else
      log "ok (new commits)"
    fi
  else
    rc=$?
    log "failed (rc=${rc}): $(printf '%s' "${out}" | tr '\n' ' ' | head -c 240)"
    # Best-effort cleanup if a rebase was left mid-way.
    git -C "${REPO}" rebase --abort 2>/dev/null || true
  fi
  return 0
}

sync_lock do_pull || true

exit 0
