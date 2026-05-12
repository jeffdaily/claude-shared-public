#!/usr/bin/env bash
# SessionStart hook: pull latest from claude-shared repo.
# Never blocks a session — exits 0 on any failure and logs to .sync.log.

set -euo pipefail

REPO="${HOME}/claude-shared"
LOG="${REPO}/.sync.log"
LOCK="${REPO}/.git/.sync.lock"

[ -d "${REPO}/.git" ] || exit 0

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
