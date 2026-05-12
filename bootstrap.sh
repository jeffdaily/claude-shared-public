#!/usr/bin/env bash
# bootstrap.sh - one-time setup for a fresh container so the rest of the
# claude-shared workflow can be installed.
#
# Why this exists
# ---------------
# claude-shared/install.sh assumes three things are already in place:
#   1. gh (GitHub CLI) installed and on PATH
#   2. gh authed against github.com with read access to your fork
#   3. claude CLI logged in
# A brand-new container has none of those. This script handles 1+2+3 in
# one shot. After it finishes you can clone your claude-shared fork and
# run its install.sh.
#
# Where to keep this file
# -----------------------
# The Dockerfile that builds your container probably lives in a separate
# repo. This script is version-controlled here so it has a canonical home;
# copy or vendor it into the Dockerfile-owning project as needed.
#
# When to run
# -----------
# Once, inside a running container, the first time you want to set up Claude
# Code + claude-shared in that container. Safe to re-run: each step skips
# itself if already done.
#
# How to run
# ----------
#   bash bootstrap.sh
#
# After it finishes (replace OWNER with your GitHub username and REPO with
# your fork's name):
#   git clone https://github.com/OWNER/REPO.git ~/claude-shared
#   CLAUDE_SHARED_OWNER=OWNER CLAUDE_SHARED_REPO_NAME=REPO ~/claude-shared/install.sh
#
# Assumptions
# -----------
# - Debian/Ubuntu base image (uses apt-get + dpkg).
# - claude CLI already on PATH (installed by the Dockerfile, not here).

set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

# ---------- 1. gh CLI ----------
if command -v gh >/dev/null 2>&1; then
  echo "bootstrap: gh already installed ($(gh --version | head -1))"
else
  echo "bootstrap: installing gh CLI"
  export DEBIAN_FRONTEND=noninteractive
  $SUDO apt-get update
  $SUDO apt-get install -y wget gpg
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | $SUDO dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
  $SUDO chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | $SUDO tee /etc/apt/sources.list.d/github-cli.list > /dev/null
  $SUDO apt-get update
  $SUDO apt-get install -y gh
fi

# ---------- 2. gh auth ----------
if gh auth status >/dev/null 2>&1; then
  echo "bootstrap: gh already authenticated"
else
  echo "bootstrap: launching 'gh auth login' (interactive)"
  gh auth login
  gh auth setup-git
fi

# ---------- 3. claude auth ----------
# 'claude auth status --json' prints {"loggedIn": true, ...} when authed.
# grep for that literal so we don't need jq as a bootstrap dependency.
if claude auth status --json 2>/dev/null | grep -q '"loggedIn":[[:space:]]*true'; then
  echo "bootstrap: claude already authenticated"
else
  echo "bootstrap: launching 'claude auth login' (interactive)"
  claude auth login
fi

echo
echo "bootstrap: done."
echo "  Next: git clone https://github.com/OWNER/REPO.git ~/claude-shared"
echo "        CLAUDE_SHARED_OWNER=OWNER CLAUDE_SHARED_REPO_NAME=REPO ~/claude-shared/install.sh"
