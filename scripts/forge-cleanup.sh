#!/bin/bash
set -euo pipefail

# forge-cleanup.sh — Remove a completed forge workspace
#
# Usage: ./scripts/forge-cleanup.sh <owner/repo> <issue-id> [--force]
#        ./scripts/forge-cleanup.sh --all [--force]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/.forge-master/config.yml"
FORGE_BASE=$(grep 'base_dir:' "$CONFIG_FILE" | awk '{print $2}' | tr -d '"' || echo ".forge")
FORGE_BASE_DIR="${PROJECT_ROOT}/${FORGE_BASE}"

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
  gh issue edit "$issue_id" -R "$repo" --remove-label "ag-in-progress" 2>/dev/null || true

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
  echo "       $0 --status"
  exit 1
fi

if [ "$1" = "--status" ]; then
  if [ ! -d "$FORGE_BASE_DIR" ]; then
    echo "No active forges found."
    exit 0
  fi
  echo "=== Active Forge Workspaces ==="
  for repo_dir in "${FORGE_BASE_DIR}"/*/; do
    [ -d "$repo_dir" ] || continue
    for issue_dir in "${repo_dir}"issue-*/; do
      [ -d "$issue_dir" ] || continue
      issue_id=$(basename "$issue_dir" | sed 's/issue-//')
      if cd "$issue_dir" 2>/dev/null; then
        repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "unknown")
        labels=$(gh issue view "$issue_id" --json labels -q '.labels[].name' 2>/dev/null | xargs || echo "none")
        echo "- ${repo} #${issue_id} (Labels: ${labels})"
        cd - >/dev/null
      else
        echo "- Unknown repo #${issue_id} at ${issue_dir}"
      fi
    done
  done
  exit 0
elif [ "$1" = "--all" ]; then
  force="${2:-false}"
  if [ ! -d "$FORGE_BASE_DIR" ]; then
    echo "No forges found."
    exit 0
  fi
  for repo_dir in "${FORGE_BASE_DIR}"/*/; do
    [ -d "$repo_dir" ] || continue
    for issue_dir in "${repo_dir}"issue-*/; do
      [ -d "$issue_dir" ] || continue
      issue_id=$(basename "$issue_dir" | sed 's/issue-//')
      if cd "$issue_dir" 2>/dev/null; then
        repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
        cd - >/dev/null
        if [ -n "$repo" ]; then
          cleanup_forge "$repo" "$issue_id" "$force"
          continue
        fi
      fi
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
