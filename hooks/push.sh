#!/usr/bin/env bash
# Stop hook: commit and push any changes in the claude-shared working tree.
# Generic identity (no hostname, no session id). Pre-commit secret scan.

set -euo pipefail

REPO="${HOME}/claude-shared"
LOG="${REPO}/.sync.log"
LOCK="${REPO}/.git/.sync.lock"

[ -d "${REPO}/.git" ] || exit 0

log() {
  printf '[%s] push: %s\n' "$(date -u +%FT%TZ)" "$*" >> "${LOG}"
}

run_under_lock() {
  cd "${REPO}"

  git add -A
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

  if timeout 30 git push --quiet 2>>"${LOG}"; then
    log "pushed ${nfiles} file(s)"
    return 0
  fi

  log "push failed; retrying after pull --rebase"
  if timeout 30 git pull --rebase --autostash --quiet 2>>"${LOG}" \
     && timeout 30 git push --quiet 2>>"${LOG}"; then
    log "pushed ${nfiles} file(s) after rebase"
    return 0
  fi

  # Rebase conflict or persistent push failure: park on side branch.
  git rebase --abort 2>/dev/null || true
  local branch="conflict/$(openssl rand -hex 4 2>/dev/null || printf '%s' "$RANDOM$RANDOM")-$(date -u +%FT%TZ)"
  git branch -q "${branch}" HEAD
  git reset --hard --quiet "$(git rev-parse @{upstream})" 2>/dev/null || git reset --hard --quiet origin/main 2>/dev/null || true
  printf 'claude-shared: push conflict; commit parked on local branch %s\n' "${branch}" >&2
  log "conflict parked on ${branch}"
  return 1
}

rc=0
(
  flock -n 9 || { log "lock busy, deferring"; exit 0; }
  run_under_lock
) 9>"${LOCK}" || rc=$?

exit "${rc}"
