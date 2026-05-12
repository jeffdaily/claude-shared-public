#!/usr/bin/env bash
# Print the list of plans in ~/.claude/plans/ as a 2-column table:
# filename and a wrapped first-heading summary, oldest mtime first.
#
# Terminal width detection: the subshell spawned by Claude Code's slash-command
# host has no tty, so `tput cols` falls back to 80. Borrow the parent process's
# tty via /proc/$PPID/fd/0 to get the real width.

set -u

PLANS_DIR="${HOME}/.claude/plans"
[ -d "${PLANS_DIR}" ] || { echo "no plans dir at ${PLANS_DIR}" >&2; exit 1; }

cols=80
found_tty=""
debug=""
debug+="self_pid=$$ ppid=$PPID"$'\n'
pid=$PPID
hop=0
while [ -n "${pid}" ] && [ "${pid}" != "0" ] && [ "${pid}" != "1" ] && [ "${hop}" -lt 8 ]; do
  comm=$(cat /proc/${pid}/comm 2>/dev/null || echo "?")
  debug+="  hop=${hop} pid=${pid} comm=${comm}"$'\n'
  for fd in 0 1 2; do
    p=$(readlink /proc/${pid}/fd/${fd} 2>/dev/null || true)
    if [ -n "${p}" ]; then
      debug+="    fd${fd} -> ${p}"$'\n'
      case "${p}" in
        /dev/pts/*|/dev/tty*)
          sz=$(stty -F "${p}" size 2>/dev/null || true)
          if [ -n "${sz}" ]; then
            cols=${sz##* }
            found_tty="${p}"
            debug+="    => stty size: ${sz}, cols=${cols}"$'\n'
            break 3
          fi
          ;;
      esac
    fi
  done
  pid=$(ps -o ppid= -p "${pid}" 2>/dev/null | tr -d ' ' || echo "")
  hop=$((hop+1))
done

if [ -z "${found_tty}" ] || [ -n "${PLANS_DEBUG:-}" ]; then
  printf '[plans-list debug] no tty found in ancestors; using cols=%s\n' "${cols}"
  printf '%s' "${debug}"
  echo
fi

MAX_LINES=3

shopt -s nullglob
cd "${PLANS_DIR}"
files=()
while IFS= read -r f; do files+=("$f"); done < <(ls -tr -- *.md 2>/dev/null)

if [ "${#files[@]}" -eq 0 ]; then
  echo "(no plans)"
  exit 0
fi

maxn=0
for f in "${files[@]}"; do
  l=${#f}
  if [ "${l}" -gt "${maxn}" ]; then maxn=${l}; fi
done

gap=2
w=$(( cols - maxn - gap ))
if [ "${w}" -lt 20 ]; then w=20; fi

pad=$(printf '%*s' "${maxn}" '')

for f in "${files[@]}"; do
  title=$(head -1 "$f" | sed 's/^#* *//; s/[[:space:]]\+$//')

  wrapped=$(printf '%s\n' "${title}" | fmt -w "${w}" 2>/dev/null || printf '%s\n' "${title}")
  total=$(printf '%s\n' "${wrapped}" | wc -l)
  shown=$(printf '%s\n' "${wrapped}" | head -n "${MAX_LINES}")

  if [ "${total}" -gt "${MAX_LINES}" ]; then
    last=$(printf '%s\n' "${shown}" | tail -n 1)
    rest=$(printf '%s\n' "${shown}" | head -n $(( MAX_LINES - 1 )))
    cut=$(( w - 3 ))
    if [ "${#last}" -gt "${cut}" ]; then
      last="${last:0:${cut}}..."
    else
      last="${last}..."
    fi
    if [ "${MAX_LINES}" -gt 1 ]; then
      shown=$(printf '%s\n%s' "${rest}" "${last}")
    else
      shown="${last}"
    fi
  fi

  i=0
  while IFS= read -r line; do
    if [ "${i}" -eq 0 ]; then
      printf '%-*s  %s\n' "${maxn}" "${f}" "${line}"
    else
      printf '%s  %s\n' "${pad}" "${line}"
    fi
    i=$(( i + 1 ))
  done <<< "${shown}"
done
