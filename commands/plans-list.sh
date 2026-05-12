#!/usr/bin/env bash
# Print the list of plans in ~/.claude/plans/ as a 3-column table:
# last-modified timestamp, filename, and a wrapped first-heading summary,
# oldest first (newest at the bottom).
#
# Timestamp comes from `git log -1` of the file's last commit so the value is
# stable across hosts (git doesn't preserve mtimes on checkout). Files that
# aren't in git yet (uncommitted new plans) fall back to the local mtime and
# are flagged with a trailing "*" so it's clear they're local-only.
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
DATE_W=17  # "YYYY-MM-DD HH:MM" + optional "*" marker

shopt -s nullglob
cd "${PLANS_DIR}"

# Build records sorted ascending (newest at the bottom). Prefer the file's last
# git commit time (stable across hosts); fall back to local mtime with a "*"
# marker if the file isn't tracked yet.
declare -A FILE_DISP=()
files=()
while IFS=$'\t' read -r _ts disp f; do
  files+=("$f")
  FILE_DISP[$f]=$disp
done < <(
  for p in *.md; do
    [ -e "$p" ] || continue
    ts=$(git log -1 --format=%ct -- "$p" 2>/dev/null || true)
    marker=""
    if [ -z "${ts}" ]; then
      ts=$(stat -c '%Y' -- "$p")
      marker="*"
    fi
    disp=$(date -d "@${ts}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "                ")
    printf '%s\t%s%s\t%s\n' "${ts}" "${disp}" "${marker}" "${p}"
  done | sort -n
)

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
w=$(( cols - DATE_W - gap - maxn - gap ))
if [ "${w}" -lt 20 ]; then w=20; fi

date_pad=$(printf '%*s' "${DATE_W}" '')
name_pad=$(printf '%*s' "${maxn}" '')

for f in "${files[@]}"; do
  mtime=${FILE_DISP[$f]}
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
      printf '%-*s  %-*s  %s\n' "${DATE_W}" "${mtime}" "${maxn}" "${f}" "${line}"
    else
      printf '%s  %s  %s\n' "${date_pad}" "${name_pad}" "${line}"
    fi
    i=$(( i + 1 ))
  done <<< "${shown}"
done
