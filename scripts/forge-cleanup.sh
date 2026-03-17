#!/bin/bash
set -euo pipefail

# forge-cleanup.sh — Remove a completed forge workspace
#
# Usage: ./scripts/forge-cleanup.sh <owner/repo> <issue-id> [--force]
#        ./scripts/forge-cleanup.sh --all [--force]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FORGE_BASE_DIR="${PROJECT_ROOT}/.forge"

cleanup_forge() {
  local repo="$1"
  local issue_id="$2"
  local force="${3:-false}"

  local owner repo_name repo_slug forge_dir
  owner=$(echo "$repo" | cut -d'/' -f1)
  repo_name=$(echo "$repo" | cut -d'/' -f2)
  repo_slug="${owner}-${repo_name}"
  forge_dir="${FORGE_BASE_DIR}/${repo_slug}/issue-${issue_id}"

  if [ ! -d "$forge_dir" ]; then
    echo "Warning: No forge found at ${forge_dir}"
    return 1
  fi

  echo "Cleaning up forge for ${repo} issue #${issue_id}..."

  if [ "$force" = "--force" ]; then
    rm -rf "$forge_dir"
  else
    if cd "$forge_dir" && ! git diff --quiet HEAD 2>/dev/null; then
      echo "Error: Forge has uncommitted changes. Use --force to override."
      return 1
    fi
    rm -rf "$forge_dir"
  fi

  local repo_dir="${FORGE_BASE_DIR}/${repo_slug}"
  if [ -d "$repo_dir" ] && [ -z "$(ls -A "$repo_dir" 2>/dev/null)" ]; then
    rmdir "$repo_dir"
  fi

  echo "✅ Forge for ${repo} issue #${issue_id} cleaned up."
}

if [ $# -lt 1 ]; then
  echo "Usage: $0 <owner/repo> <issue-id> [--force]"
  echo "       $0 --all [--force]"
  exit 1
fi

if [ "$1" = "--all" ]; then
  force="${2:-false}"
  if [ ! -d "$FORGE_BASE_DIR" ]; then
    echo "No forges found."
    exit 0
  fi
  for repo_dir in "${FORGE_BASE_DIR}"/*/; do
    [ -d "$repo_dir" ] || continue
    for issue_dir in "${repo_dir}"issue-*/; do
      [ -d "$issue_dir" ] || continue
      rm -rf "$issue_dir"
    done
    if [ -z "$(ls -A "$repo_dir" 2>/dev/null)" ]; then
      rmdir "$repo_dir"
    fi
  done
  echo "✅ All forges cleaned up."
else
  if [ $# -lt 2 ]; then
    echo "Usage: $0 <owner/repo> <issue-id> [--force]"
    exit 1
  fi
  cleanup_forge "$1" "$2" "${3:-false}"
fi
