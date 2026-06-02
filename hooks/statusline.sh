#!/usr/bin/env bash
# Format the Claude Code statusLine from ~/claude-shared/.sync.log.
#
# The Stop hook fires every turn and writes "no changes" most of the time,
# which buries the meaningful events (pushed, blocked, conflict, etc.). This
# script shows the most recent meaningful line and appends "(idle)" if the
# very last log entry was a boring no-op — so the user still sees that the
# hooks are running.

set -u

LOG="${HOME}/claude-shared/.sync.log"
[ -f "${LOG}" ] || exit 0

# "Boring" = a normal no-op invocation that proves the hook ran but says
# nothing interesting. Everything else (pushed, blocked, failed, conflict,
# pull with new commits, etc.) is meaningful.
BORING_RE=' (push: no changes|pull: ok \(up to date\)|push: lock busy|pull: lock busy)$'

last_real=$(grep -E -v "${BORING_RE}" "${LOG}" | tail -1)
last_any=$(tail -1 "${LOG}")
line="${last_real:-${last_any}}"

# If something boring has happened since the last meaningful event, flag it
# so the user can tell hooks are still alive.
if [ -n "${last_real}" ] && [ "${line}" != "${last_any}" ]; then
  line="${line} (idle)"
fi

printf '%s\n' "${line}" | sed 's/^\[//; s/\] / /'
