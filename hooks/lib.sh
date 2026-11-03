#!/usr/bin/env bash
# Shared helpers for the claude-shared hooks. Sourced, never executed.
#
# Two things every hook needs that it cannot assume on every platform:
#
#   REPO       The repo used to be pinned at ${HOME}/claude-shared. On Windows
#              the checkout can live anywhere (e.g. D:\code\claude-shared),
#              and $HOME is not reliably present in the environment a hook
#              inherits, so each hook derives the repo from its own path. This
#              is identical to the old value on Linux containers.
#
#   sync_lock  flock(1) ships with Linux but NOT with Git Bash on Windows. The
#              old `flock -n 9 || { log "lock busy"; exit 0; }` idiom turned a
#              missing binary (exit 127) into the lock-busy branch, so on
#              Windows both hooks exited 0 every turn while logging a plausible
#              message: a silent no-op sync that looked healthy. sync_lock
#              falls back to an atomic mkdir lock when flock is absent.

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HOOKS_DIR}/.." && pwd)"
LOG="${REPO}/.sync.log"

# Git Bash spawned from a non-login context can leave HOME empty, which sends
# git looking for ~/.gitconfig -- and therefore the gh credential helper -- in
# the wrong place, turning every push into an auth failure. Recover it from the
# Windows-side variables when we can.
if [ -z "${HOME:-}" ]; then
  if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
    HOME="$(cygpath -u "${USERPROFILE}")"
    export HOME
  fi
fi

# LOG_TAG is set by each hook ("pull"/"push"). statusline.sh pattern-matches on
# these lines, so keep the format stable.
log() {
  printf '[%s] %s: %s\n' "$(date -u +%FT%TZ)" "${LOG_TAG:-hook}" "$*" >> "${LOG}"
}

# sync_lock <fn-name>
# Run <fn-name> under an exclusive, non-blocking lock. Returns the function's
# exit status, or 0 (after logging) when another process holds the lock.
# Never blocks -- a hook must not stall a session.
sync_lock() {
  local body="$1" rc=0

  if command -v flock >/dev/null 2>&1; then
    (
      flock -n 9 || { log "lock busy, skipping"; exit 0; }
      "${body}"
    ) 9>"${REPO}/.git/.sync.lock" || rc=$?
    return "${rc}"
  fi

  # mkdir is atomic on NTFS too, so it works as the mutex. Unlike flock it is
  # not released when the holder dies, so break a lock left behind by a crashed
  # or killed hook rather than wedging the sync forever.
  local lockdir="${REPO}/.git/.sync.lock.d"
  local stale_secs=300
  if ! mkdir "${lockdir}" 2>/dev/null; then
    local mtime now age
    mtime=$(stat -c %Y "${lockdir}" 2>/dev/null || echo 0)
    now=$(date +%s)
    age=$(( now - mtime ))
    if [ "${mtime}" -eq 0 ] || [ "${age}" -ge "${stale_secs}" ]; then
      log "breaking stale lock (${age}s old)"
      rm -rf "${lockdir}"
      mkdir "${lockdir}" 2>/dev/null || { log "lock busy, skipping"; return 0; }
    else
      log "lock busy, skipping"
      return 0
    fi
  fi

  trap 'rm -rf "${lockdir}"' EXIT INT TERM
  "${body}" || rc=$?
  rm -rf "${lockdir}"
  trap - EXIT INT TERM
  return "${rc}"
}
