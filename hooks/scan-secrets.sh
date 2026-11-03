#!/usr/bin/env bash
# Pre-commit secret scanner. Greps the staged diff (added lines only) for
# common secret shapes. On a hit: print "FILE:LINE category=NAME" to stderr
# (never echo the match itself), exit 1. On no hits: exit 0.

set -euo pipefail

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "${REPO}"

# Capture only ADDED lines (those prefixed with '+' in the staged diff,
# excluding the '+++ filename' headers).
diff_lines=$(git diff --cached --unified=0 --no-color) || exit 0
[ -n "${diff_lines}" ] || exit 0

# One ERE per category, matched with bash's built-in =~ instead of a piped
# grep. The old code forked six greps for every added line: merely wasteful on
# Linux, but Windows process creation costs ~50-100ms, so a 350-line diff turned
# the Stop hook into a multi-minute stall. Same patterns, same behaviour, no
# subprocesses.
CATEGORIES=(
  'aws_access_key|AKIA[0-9A-Z]{16}'
  'github_token|gh[pousr]_[A-Za-z0-9]{36,}'
  'slack_token|xox[abprs]-[A-Za-z0-9-]{10,}'
  'private_key|-----BEGIN ((RSA |EC |OPENSSH |PGP |DSA )?PRIVATE KEY|CERTIFICATE)-----'
  'jwt|eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
  "sensitive_assignment|(password|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*['\"]?[A-Za-z0-9_+/=-]{16,}"
)

# Walk the diff, tracking current file and current new-line number.
hit=0
current_file=""
current_line=0

check_line() {
  local content="$1" entry name regex
  for entry in "${CATEGORIES[@]}"; do
    name="${entry%%|*}"
    regex="${entry#*|}"
    # $regex is deliberately unquoted: quoting the right-hand side of =~ makes
    # bash match it as a literal string rather than as a regex.
    if [[ "${content}" =~ $regex ]]; then
      printf 'SECRET: %s:%s category=%s\n' "${current_file}" "${current_line}" "${name}" >&2
      hit=1
    fi
  done
}

while IFS= read -r line; do
  case "${line}" in
    "+++ "*)
      # +++ b/path/to/file
      current_file="${line#+++ b/}"
      ;;
    "@@ "*)
      # @@ -old,len +new,len @@ ...
      # Extract the new-side start.
      new_part="${line#*+}"          # e.g. "12,3 @@ ..."
      new_start="${new_part%%[,$' ']*}"
      current_line="${new_start}"
      ;;
    "+"*)
      # Added line (skip if it's actually the +++ header — handled above).
      content="${line#+}"
      check_line "${content}"
      current_line=$((current_line + 1))
      ;;
    " "*|"-"*)
      # context or removed; advance new-line counter only for context lines.
      [ "${line:0:1}" = " " ] && current_line=$((current_line + 1))
      ;;
  esac
done <<< "${diff_lines}"

if [ "${hit}" -ne 0 ]; then
  printf 'scan-secrets: refused to commit; scrub the file(s) above and retry.\n' >&2
  exit 1
fi
exit 0
