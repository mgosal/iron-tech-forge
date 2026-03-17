#!/bin/bash
set -euo pipefail

# forge-create.sh — Create a new forge workspace for an issue on ANY repo
#
# Usage: ./scripts/forge-create.sh <owner/repo> <issue-id>
#
# This clones the target repo into .forge/<owner>-<repo>/issue-<id>/
# and creates a branch for the fix. The forge is completely isolated
# from the anti-gravity-forge project itself.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FORGE_BASE_DIR="${PROJECT_ROOT}/.forge"
BRANCH_PREFIX="ag/"

if [ $# -lt 2 ]; then
  echo "Usage: $0 <owner/repo> <issue-id>"
  echo "Example: $0 mgosal/CoS 42"
  exit 1
fi

REPO="$1"
ISSUE_ID="$2"
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)
REPO_SLUG="${OWNER}-${REPO_NAME}"

FORGE_DIR="${FORGE_BASE_DIR}/${REPO_SLUG}/issue-${ISSUE_ID}"
BRANCH_NAME="${BRANCH_PREFIX}issue-${ISSUE_ID}"

# Check if forge already exists
if [ -d "$FORGE_DIR" ]; then
  echo "Error: Forge already exists at ${FORGE_DIR}"
  exit 1
fi

# Create forge directory
mkdir -p "$FORGE_DIR"

# Clone the target repo (shallow clone for speed)
echo "Cloning ${REPO} into forge..."
gh repo clone "$REPO" "$FORGE_DIR" -- --depth=50 2>/dev/null || {
  echo "Error: Failed to clone ${REPO}. Check that the repo exists and you have access."
  rm -rf "$FORGE_DIR"
  exit 1
}

# Create the fix branch
cd "$FORGE_DIR"
BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
git checkout -b "$BRANCH_NAME" "origin/${BASE_BRANCH}"

# Create the forge-meta directory for pipeline artifacts
mkdir -p "${FORGE_DIR}/.forge-meta"

echo "✅ Forge created for ${REPO} issue #${ISSUE_ID}"
echo "   Workspace: ${FORGE_DIR}"
echo "   Branch:    ${BRANCH_NAME}"
echo "   Base:      ${BASE_BRANCH}"
echo "   Meta dir:  ${FORGE_DIR}/.forge-meta"
