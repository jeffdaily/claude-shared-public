#!/usr/bin/env bash
# Idempotent installer for claude-shared. Wires symlinks from ~/.claude/ into
# the cloned ~/claude-shared/ working tree and registers SessionStart/Stop
# hooks via the symlinked settings.json.
#
# Run inside a running container after `gh auth login`, `gh auth setup-git`,
# and `claude login`. Never run during Docker image build — the gh auth check
# below will fail.
#
# Configuration:
#   GH_OWNER / GH_REPO control which repo this installer expects to find at
#   ${REPO_DIR}. Set them via env vars before running, or edit the defaults
#   below. The installer enforces that the repo is PRIVATE — fork this
#   public starter into your own private repo before populating it with
#   memories, plans, or anything else you do not want world-readable.
#
#   PROJECT_DIRS is an optional list of absolute project paths whose
#   per-project Claude memory you want synced. Each entry produces a
#   symlink at ~/.claude/projects/<slug>/memory/ pointing into this repo,
#   where <slug> is the path with '/' replaced by '-'.
#
# Usage:
#   ~/claude-shared/install.sh

set -euo pipefail

REPO_DIR="${HOME}/claude-shared"
CLAUDE_DIR="${HOME}/.claude"
BACKUP_DIR="${CLAUDE_DIR}/backups/pre-shared-$(date -u +%s)"

# --- Edit these for your fork ---
GH_OWNER="${CLAUDE_SHARED_OWNER:-CHANGE_ME}"
GH_REPO="${CLAUDE_SHARED_REPO_NAME:-claude-shared}"

# Optional: absolute paths of projects whose memory you want synced.
# Example: PROJECT_DIRS=("${HOME}/code/myrepo")
PROJECT_DIRS=()

declare -a LINKED=()
declare -a BACKED_UP=()
declare -a SKIPPED=()
declare -a WHIMSICAL=()

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
note() { printf 'install.sh: %s\n' "$*"; }

# ---------- 0. Configuration sanity ----------
if [ "${GH_OWNER}" = "CHANGE_ME" ]; then
  die "GH_OWNER is unset. Edit install.sh or export CLAUDE_SHARED_OWNER to point at your fork."
fi

# ---------- 1. Prerequisite check: gh installed and authed ----------
command -v gh >/dev/null 2>&1 || die "gh CLI not found. Install gh, then run: gh auth login && gh auth setup-git"
command -v jq >/dev/null 2>&1 || die "jq not found. Install jq and re-run."
command -v git >/dev/null 2>&1 || die "git not found."

if ! gh auth status >/dev/null 2>&1; then
  cat >&2 <<'EOF'
install.sh: gh is not logged in. Run:
    gh auth login
    gh auth setup-git
then re-run install.sh.
EOF
  exit 1
fi

# Defensive: idempotent, ensures gh is registered as the git credential helper.
gh auth setup-git >/dev/null 2>&1 || true

# ---------- 2. Repo present and configured ----------
if [ ! -d "${REPO_DIR}/.git" ]; then
  note "cloning ${GH_OWNER}/${GH_REPO} to ${REPO_DIR}"
  git clone --quiet "https://github.com/${GH_OWNER}/${GH_REPO}.git" "${REPO_DIR}"
fi
git -C "${REPO_DIR}" config --local pull.rebase true
git -C "${REPO_DIR}" config --local rebase.autoStash true

# ---------- 3. Visibility check: must be private ----------
vis=$(gh repo view "${GH_OWNER}/${GH_REPO}" --json visibility -q .visibility 2>/dev/null || echo UNKNOWN)
case "${vis}" in
  PRIVATE|INTERNAL)
    : ;;
  PUBLIC)
    die "REPO IS PUBLIC. Make it private before installing. (gh repo edit ${GH_OWNER}/${GH_REPO} --visibility private)"
    ;;
  *)
    die "Could not determine repo visibility (got '${vis}'). Verify access to ${GH_OWNER}/${GH_REPO}."
    ;;
esac

# ---------- 4. Ensure base directories exist ----------
mkdir -p "${CLAUDE_DIR}" "${CLAUDE_DIR}/backups"

# ---------- 5. Pre-flight: warn about whimsical pre-existing plan names ----------
# Heuristic: Claude's default plan names often start with first/second-person
# pronouns or imperative verbs (e.g. "you-are-a-...", "i-want-to-...",
# "let-me-...", "help-me-..."). Flag those for renaming. Real plan names
# typically start with a project keyword.
if [ -d "${CLAUDE_DIR}/plans" ] && [ ! -L "${CLAUDE_DIR}/plans" ]; then
  while IFS= read -r f; do
    base=$(basename "${f}")
    if [[ "${base}" =~ ^(you|i|we|us|me|lets?|please|help|make|build|create|do|can)- ]]; then
      WHIMSICAL+=("${base}")
    fi
  done < <(find "${CLAUDE_DIR}/plans" -maxdepth 1 -type f -name '*.md')
fi

# ---------- 6. Symlink helper ----------
# Args: source-in-claude (e.g. ~/.claude/CLAUDE.md), target-in-repo (e.g. ~/claude-shared/CLAUDE.md)
link_one() {
  local src="$1" tgt="$2"
  if [ -L "${src}" ]; then
    if [ "$(readlink -f "${src}")" = "$(readlink -f "${tgt}")" ]; then
      SKIPPED+=("${src} (already linked)")
      return 0
    fi
    rm "${src}"
  elif [ -e "${src}" ]; then
    local rel="${src#${HOME}/}"
    local dest="${BACKUP_DIR}/${rel}"
    mkdir -p "$(dirname "${dest}")"
    mv "${src}" "${dest}"
    BACKED_UP+=("${src} -> ${dest}")
  fi
  mkdir -p "$(dirname "${src}")"
  ln -s "${tgt}" "${src}"
  LINKED+=("${src} -> ${tgt}")
}

# ---------- 7. Apply links ----------
link_one "${CLAUDE_DIR}/CLAUDE.md"     "${REPO_DIR}/CLAUDE.md"
link_one "${CLAUDE_DIR}/settings.json" "${REPO_DIR}/settings.shared.json"
link_one "${CLAUDE_DIR}/plans"         "${REPO_DIR}/plans"
link_one "${CLAUDE_DIR}/skills"        "${REPO_DIR}/skills"
link_one "${CLAUDE_DIR}/commands"      "${REPO_DIR}/commands"
link_one "${CLAUDE_DIR}/agents"        "${REPO_DIR}/agents"

# Optional per-project memory symlinks.
for proj_dir in "${PROJECT_DIRS[@]}"; do
  [ -d "${proj_dir}" ] || { note "skipping missing project dir ${proj_dir}"; continue; }
  slug="${proj_dir//\//-}"
  mkdir -p "${CLAUDE_DIR}/projects/${slug}" "${REPO_DIR}/projects/${slug}/memory"
  link_one "${CLAUDE_DIR}/projects/${slug}/memory" \
           "${REPO_DIR}/projects/${slug}/memory"
done

# ---------- 8. Clean up legacy hook block in settings.local.json ----------
# Hooks live in ${REPO_DIR}/settings.shared.json (symlinked as
# ~/.claude/settings.json). Earlier installer versions merged them into
# settings.local.json instead; drop any stale 'hooks' block from
# settings.local.json on every install so a re-run migrates the container.
LOCAL_SETTINGS="${CLAUDE_DIR}/settings.local.json"
HOOKS_CLEANED=0
if [ -f "${LOCAL_SETTINGS}" ] && jq -e '.hooks' "${LOCAL_SETTINGS}" >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq 'del(.hooks)' "${LOCAL_SETTINGS}" > "${tmp}"
  mv "${tmp}" "${LOCAL_SETTINGS}"
  HOOKS_CLEANED=1
fi

# ---------- 9. Final summary ----------
echo
note "== install summary =="
if [ "${#LINKED[@]}" -gt 0 ]; then
  echo "  linked:"
  printf '    %s\n' "${LINKED[@]}"
fi
if [ "${#BACKED_UP[@]}" -gt 0 ]; then
  echo "  backed up (pre-existing real files moved aside):"
  printf '    %s\n' "${BACKED_UP[@]}"
fi
if [ "${#SKIPPED[@]}" -gt 0 ]; then
  echo "  skipped:"
  printf '    %s\n' "${SKIPPED[@]}"
fi
echo "  hooks: registered via ${REPO_DIR}/settings.shared.json (symlinked as ${CLAUDE_DIR}/settings.json)"
if [ "${HOOKS_CLEANED}" = 1 ]; then
  echo "  migrated: dropped legacy 'hooks' block from ${LOCAL_SETTINGS}"
fi
echo
if [ "${#WHIMSICAL[@]}" -gt 0 ]; then
  echo "WARNING: plan files with whimsical names found in ~/.claude/plans/:"
  printf '    %s\n' "${WHIMSICAL[@]}"
  echo "Rename via 'git mv' inside ${REPO_DIR}/plans/ before the next Stop hook"
  echo "fires; otherwise they will auto-commit under their whimsical names."
  echo
fi
note "done."
