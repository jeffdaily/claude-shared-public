#!/usr/bin/env bash
# SessionStart hook: pull latest from claude-shared repo.
# Never blocks a session — exits 0 on any failure and logs to .sync.log.

set -euo pipefail

REPO="${HOME}/claude-shared"
LOG="${REPO}/.sync.log"
LOCK="${REPO}/.git/.sync.lock"

[ -d "${REPO}/.git" ] || exit 0

# Rebase replays need a git identity even when there's nothing to replay
# (autostash pop can also need one). Set generic, container-independent values
# so this hook works on hosts without global git config.
export GIT_AUTHOR_NAME=claude-sync
export GIT_AUTHOR_EMAIL=claude-sync@local
export GIT_COMMITTER_NAME=claude-sync
export GIT_COMMITTER_EMAIL=claude-sync@local

log() {
  printf '[%s] pull: %s\n' "$(date -u +%FT%TZ)" "$*" >> "${LOG}"
}

(
  flock -n 9 || { log "lock busy, skipping"; exit 0; }
  if out=$(timeout 15 git -C "${REPO}" pull --rebase --autostash 2>&1); then
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
) 9>"${LOCK}" || true

exit 0
