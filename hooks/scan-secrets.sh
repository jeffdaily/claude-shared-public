#!/usr/bin/env bash
# Pre-commit secret scanner. Greps the staged diff (added lines only) for
# common secret shapes. On a hit: print "FILE:LINE category=NAME" to stderr
# (never echo the match itself), exit 1. On no hits: exit 0.

set -euo pipefail

REPO="${HOME}/claude-shared"
cd "${REPO}"

# Capture only ADDED lines (those prefixed with '+' in the staged diff,
# excluding the '+++ filename' headers).
diff_lines=$(git diff --cached --unified=0 --no-color) || exit 0
[ -n "${diff_lines}" ] || exit 0

# Walk the diff, tracking current file and current new-line number.
hit=0
current_file=""
current_line=0

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
      check_category() {
        local name="$1" regex="$2"
        if printf '%s' "${content}" | grep -Eq -- "${regex}"; then
          printf 'SECRET: %s:%s category=%s\n' "${current_file}" "${current_line}" "${name}" >&2
          hit=1
        fi
      }
      check_category aws_access_key 'AKIA[0-9A-Z]{16}'
      check_category github_token   'gh[pousr]_[A-Za-z0-9]{36,}'
      check_category slack_token    'xox[abprs]-[A-Za-z0-9-]{10,}'
      check_category private_key    '-----BEGIN ((RSA |EC |OPENSSH |PGP |DSA )?PRIVATE KEY|CERTIFICATE)-----'
      check_category jwt            'eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
      check_category sensitive_assignment "(password|secret|token|api[_-]?key)[[:space:]]*[:=][[:space:]]*['\"]?[A-Za-z0-9_+/=-]{16,}"
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
