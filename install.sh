#!/usr/bin/env bash
# Idempotent installer for claude-shared. Wires symlinks from ~/.claude/ into
# the cloned claude-shared working tree and registers SessionStart/Stop hooks.
#
# Runs on two platforms:
#
#   Linux            Repo at ~/claude-shared. ~/.claude/settings.json is a
#                    symlink to the repo's settings.shared.json.
#
#   Windows          Git Bash + Developer Mode (for native symlinks). The repo
#                    can live on any drive; the installer finds it from its own
#                    location. ~/.claude/settings.json stays a REAL, machine-
#                    local file -- the shared keys are merged into it and the
#                    hook commands are rewritten to invoke Git Bash explicitly,
#                    because the hook command strings are per-platform.
#
# Run after `gh auth login`, `gh auth setup-git`, and `claude login`. Never
# run during Docker image build -- the gh auth check below will fail.
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
#   where <slug> is the path with every non-alphanumeric character replaced
#   by '-' (Claude Code's own rule). On Windows the slug comes from the
#   Windows form of the path (D:/code/myrepo -> D--code-myrepo), so the same
#   project gets separate memory on Linux and on Windows.
#
# Usage:
#   ~/claude-shared/install.sh          # Linux
#   ./install.sh                        # Windows Git Bash, from the checkout

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
  *)                    IS_WINDOWS=0 ;;
esac

# Git Bash's `ln -s` silently COPIES by default, which would fork every file
# from the repo and break sync in a way that looks like it worked. Force real
# NTFS symlinks and fail loudly if the OS refuses (Developer Mode off).
if [ "${IS_WINDOWS}" = 1 ]; then
  export MSYS="${MSYS:+${MSYS} }winsymlinks:nativestrict"
fi

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
declare -a NOTES=()

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
# The repo is wherever this script lives. Only fall back to cloning when this
# script was copied out of the checkout (e.g. vendored into an image).
if [ -d "${SELF_DIR}/.git" ]; then
  REPO_DIR="${SELF_DIR}"
else
  REPO_DIR="${HOME}/claude-shared"
  if [ ! -d "${REPO_DIR}/.git" ]; then
    note "cloning ${GH_OWNER}/${GH_REPO} to ${REPO_DIR}"
    git clone --quiet "https://github.com/${GH_OWNER}/${GH_REPO}.git" "${REPO_DIR}"
  fi
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
  if ! ln -s "${tgt}" "${src}"; then
    if [ "${IS_WINDOWS}" = 1 ]; then
      die "could not create a native symlink at ${src}. Windows allows unprivileged symlinks only with Developer Mode ON (Settings > System > For developers), or from an Administrator shell."
    fi
    die "could not create symlink ${src} -> ${tgt}"
  fi
  # nativestrict makes ln fail loudly on refusal, but guard against a silent
  # copy from any other MSYS setting: a copy here would fork the file from the
  # repo and quietly stop syncing it.
  [ -L "${src}" ] || die "${src} is not a symlink after linking (MSYS=${MSYS:-unset} produced a copy). Refusing to continue."
  LINKED+=("${src} -> ${tgt}")
}

# Claude Code's project slug: the absolute path with every non-alphanumeric
# character replaced by '-'. On Windows it is computed from the Windows form of
# the path (D:/code/myrepo), not the Git Bash form (/d/code/myrepo).
project_slug() {
  local p="$1"
  if [ "${IS_WINDOWS}" = 1 ]; then
    p="$(cygpath -m "${p}")"
  fi
  printf '%s' "${p//[^a-zA-Z0-9]/-}"
}

# ---------- 7. Apply links ----------
link_one "${CLAUDE_DIR}/CLAUDE.md" "${REPO_DIR}/CLAUDE.md"
link_one "${CLAUDE_DIR}/plans"     "${REPO_DIR}/plans"
link_one "${CLAUDE_DIR}/skills"    "${REPO_DIR}/skills"
link_one "${CLAUDE_DIR}/commands"  "${REPO_DIR}/commands"
link_one "${CLAUDE_DIR}/agents"    "${REPO_DIR}/agents"

if [ "${IS_WINDOWS}" = 0 ]; then
  link_one "${CLAUDE_DIR}/settings.json" "${REPO_DIR}/settings.shared.json"
else
  # Convenience only: the hooks resolve the repo from their own path, but a
  # ~/claude-shared that matches the Linux layout keeps the docs and any stray
  # ${HOME}/claude-shared reference working.
  if [ "${REPO_DIR}" != "${HOME}/claude-shared" ]; then
    if [ -L "${HOME}/claude-shared" ] && [ "$(readlink -f "${HOME}/claude-shared")" = "$(readlink -f "${REPO_DIR}")" ]; then
      SKIPPED+=("${HOME}/claude-shared (already linked)")
    elif [ -e "${HOME}/claude-shared" ] && [ ! -L "${HOME}/claude-shared" ]; then
      NOTES+=("${HOME}/claude-shared exists as a real directory; left alone. The repo is ${REPO_DIR}.")
    else
      [ -L "${HOME}/claude-shared" ] && rm "${HOME}/claude-shared"
      ln -s "${REPO_DIR}" "${HOME}/claude-shared" || die "could not link ${HOME}/claude-shared -> ${REPO_DIR}"
      LINKED+=("${HOME}/claude-shared -> ${REPO_DIR}")
    fi
  fi
fi

# Optional per-project memory symlinks.
for proj_dir in ${PROJECT_DIRS[@]+"${PROJECT_DIRS[@]}"}; do
  [ -d "${proj_dir}" ] || { note "skipping missing project dir ${proj_dir}"; continue; }
  slug="$(project_slug "${proj_dir}")"
  mkdir -p "${CLAUDE_DIR}/projects/${slug}" "${REPO_DIR}/projects/${slug}/memory"
  link_one "${CLAUDE_DIR}/projects/${slug}/memory" \
           "${REPO_DIR}/projects/${slug}/memory"
done

# ---------- 7b. Windows: merge shared settings into the local settings.json ----------
# settings.json stays a REAL file here, because the hook commands must name the
# Git Bash binary explicitly and so are not portable strings. Everything in
# settings.shared.json is merged in (shared keys win), any local autoMode is
# preserved, and the hook/statusLine commands are rewritten.
if [ "${IS_WINDOWS}" = 1 ]; then
  SHARED_SETTINGS="${REPO_DIR}/settings.shared.json"
  TARGET_SETTINGS="${CLAUDE_DIR}/settings.json"

  # Locate the Git Bash binary Claude Code should use for hooks.
  if [ -n "${CLAUDE_CODE_GIT_BASH_PATH:-}" ] && [ -f "${CLAUDE_CODE_GIT_BASH_PATH}" ]; then
    BASH_EXE="${CLAUDE_CODE_GIT_BASH_PATH}"
  else
    BASH_EXE="$(cygpath -w "$(command -v bash)")"
    [ -f "${BASH_EXE}" ] || BASH_EXE="${BASH_EXE}.exe"
  fi
  [ -f "${BASH_EXE}" ] || die "could not locate bash.exe for hook commands (tried '${BASH_EXE}'). Set CLAUDE_CODE_GIT_BASH_PATH and re-run."

  # `-lc` (login shell) matters: a bare `-c` inherits the Windows PATH, which
  # has no /mingw64/bin, so git, timeout and openssl are all missing and every
  # hook fails. The login profile also derives HOME from the Windows variables,
  # which git needs to find ~/.gitconfig and therefore the gh credential helper.
  hook_cmd() { printf '"%s" -lc "%s"' "${BASH_EXE}" "$1"; }
  PULL_CMD="$(hook_cmd "${REPO_DIR}/hooks/pull.sh")"
  PUSH_CMD="$(hook_cmd "${REPO_DIR}/hooks/push.sh")"
  STATUS_CMD="$(hook_cmd "${REPO_DIR}/hooks/statusline.sh")"

  # An earlier run (or a hand edit) may have left a symlink here; replace it
  # with a real file, keeping whatever it pointed at as the starting point.
  base_json='{}'
  if [ -e "${TARGET_SETTINGS}" ]; then
    if ! base_json=$(jq '.' "${TARGET_SETTINGS}" 2>/dev/null); then
      die "${TARGET_SETTINGS} is not valid JSON. Fix or move it aside, then re-run."
    fi
    if [ ! -L "${TARGET_SETTINGS}" ]; then
      mkdir -p "${BACKUP_DIR}"
      cp "${TARGET_SETTINGS}" "${BACKUP_DIR}/settings.json.bak"
      BACKED_UP+=("${TARGET_SETTINGS} -> ${BACKUP_DIR}/settings.json.bak (copy; original updated in place)")
    else
      rm "${TARGET_SETTINGS}"
    fi
  fi

  merged=$(jq -n \
    --argjson local "${base_json}" \
    --slurpfile shared "${SHARED_SETTINGS}" \
    --arg pull "${PULL_CMD}" \
    --arg push "${PUSH_CMD}" \
    --arg status "${STATUS_CMD}" \
    '($local * ($shared[0] | del(.autoMode)))
     | .hooks = ((.hooks // {})
         | .SessionStart = [{hooks: [{type: "command", command: $pull}]}]
         | .Stop         = [{hooks: [{type: "command", command: $push}]}])
     | .statusLine = {type: "command", command: $status}')
  printf '%s\n' "${merged}" > "${TARGET_SETTINGS}.tmp"
  mv "${TARGET_SETTINGS}.tmp" "${TARGET_SETTINGS}"
  NOTES+=("${TARGET_SETTINGS} is a real file, not a symlink: shared keys merged in, hooks pointed at ${BASH_EXE}. Re-run install.sh after changing settings.shared.json.")
fi

# ---------- 8. Clean up legacy hook block in settings.local.json ----------
# Hooks live in ${REPO_DIR}/settings.shared.json (symlinked as
# ~/.claude/settings.json on Linux; merged into it on Windows). Earlier
# installer versions merged them into settings.local.json instead; drop any
# stale 'hooks' block from settings.local.json on every install so a re-run
# migrates the machine.
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
if [ "${IS_WINDOWS}" = 1 ]; then
  echo "  platform: Windows (Git Bash)"
else
  echo "  platform: Linux"
fi
echo "  repo:     ${REPO_DIR}"
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
if [ "${IS_WINDOWS}" = 1 ]; then
  echo "  hooks: registered in ${CLAUDE_DIR}/settings.json (merged from ${REPO_DIR}/settings.shared.json)"
else
  echo "  hooks: registered via ${REPO_DIR}/settings.shared.json (symlinked as ${CLAUDE_DIR}/settings.json)"
fi
if [ "${HOOKS_CLEANED}" = 1 ]; then
  echo "  migrated: dropped legacy 'hooks' block from ${LOCAL_SETTINGS}"
fi
echo
if [ "${#NOTES[@]}" -gt 0 ]; then
  echo "NOTES:"
  printf '    %s\n' "${NOTES[@]}"
  echo
fi
if [ "${#WHIMSICAL[@]}" -gt 0 ]; then
  echo "WARNING: plan files with whimsical names found in ~/.claude/plans/:"
  printf '    %s\n' "${WHIMSICAL[@]}"
  echo "Rename via 'git mv' inside ${REPO_DIR}/plans/ before the next Stop hook"
  echo "fires; otherwise they will auto-commit under their whimsical names."
  echo
fi
note "done."
