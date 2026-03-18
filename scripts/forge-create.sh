#!/bin/bash
set -euo pipefail

# forge-create.sh — Create a new forge workspace for an issue on ANY repo
#
# Usage: ./scripts/forge-create.sh <owner/repo> <issue-id>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env if it exists
if [ -f "${PROJECT_ROOT}/.env" ]; then
  export $(grep -v '^#' "${PROJECT_ROOT}/.env" | xargs)
elif [ -f "${PROJECT_ROOT}/.env.local" ]; then
  export $(grep -v '^#' "${PROJECT_ROOT}/.env.local" | xargs)
fi

CONFIG_FILE="${PROJECT_ROOT}/.forge-master/config.yml"
FORGE_BASE=$(grep 'base_dir:' "$CONFIG_FILE" | awk '{print $2}' | tr -d '"' || echo ".forge")
FORGE_BASE_DIR="${PROJECT_ROOT}/${FORGE_BASE}"
BRANCH_PREFIX="ag/"

if [ $# -lt 2 ]; then
  echo "Usage: $0 <owner/repo> <issue-id>"
  exit 1
fi

REPO="$1"
ISSUE_ID="$2"
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)
REPO_SLUG="${OWNER}-${REPO_NAME}"

FORGE_DIR="${FORGE_BASE_DIR}/${REPO_SLUG}/issue-${ISSUE_ID}"
BRANCH_NAME="${BRANCH_PREFIX}issue-${ISSUE_ID}"

# Ensure forge base directory exists
mkdir -p "$FORGE_BASE_DIR"

if [ -d "$FORGE_DIR" ]; then
  echo "Error: Forge already exists at ${FORGE_DIR}"
  exit 1
fi

mkdir -p "$FORGE_DIR"

echo "Cloning ${REPO} into forge..."
gh repo clone "$REPO" "$FORGE_DIR" -- --depth=50 2>/dev/null || {
  echo "Error: Failed to clone ${REPO}. Check that the repo exists and you have access."
  rm -rf "$FORGE_DIR"
  exit 1
}

cd "$FORGE_DIR"
BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
git checkout -b "$BRANCH_NAME" "origin/${BASE_BRANCH}"
git pull --rebase origin "${BASE_BRANCH}" 2>/dev/null || true

mkdir -p "${FORGE_DIR}/.forge-meta"

echo "✅ Forge created for ${REPO} issue #${ISSUE_ID}"
echo "   Workspace: ${FORGE_DIR}"
echo "   Branch:    ${BRANCH_NAME}"
