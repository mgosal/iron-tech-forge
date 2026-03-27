#!/bin/bash
set -euo pipefail

# start-irontech.sh — Polling daemon that monitors GitHub for issues across MULTIPLE repos
#
# Usage: ./scripts/start-irontech.sh

# SCRIPT_DIR and PROJECT_ROOT are already defined above if they were, but let's be sure.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env if it exists (using set -a for cleaner export)
if [ -f "${PROJECT_ROOT}/.env" ]; then
  set -a
  source "${PROJECT_ROOT}/.env"
  set +a
elif [ -f "${PROJECT_ROOT}/.env.local" ]; then
  set -a
  source "${PROJECT_ROOT}/.env.local"
  set +a
fi

PID_FILE="${PROJECT_ROOT}/.irontech.pid"
CONFIG_FILE="${PROJECT_ROOT}/.forge-master/config.yml"

# Identify Forge base directory and set up persistent logging
FORGE_BASE=$(grep 'base_dir:' "$CONFIG_FILE" | awk '{print $2}' | tr -d '"' || echo "forge_workspaces")
FORGE_DIR="${PROJECT_ROOT}/${FORGE_BASE}"
MISSION_LOG="${FORGE_DIR}/irontech.log"
LOG_ARCHIVE="${FORGE_DIR}/logs"

# Ensure directories exist
mkdir -p "$LOG_ARCHIVE"

# Rotate log if it already exists from a previous session
if [ -f "$MISSION_LOG" ]; then
  ARCHIVE_NAME="irontech_$(date +%Y%m%d_%H%M%S).log"
  mv "$MISSION_LOG" "${LOG_ARCHIVE}/${ARCHIVE_NAME}"
fi

# Extract defaults from config.yml (using basic grep/sed for portability)
POLL_INTERVAL_CONFIG=$(grep 'poll_interval:' "$CONFIG_FILE" | awk '{print $2}' | tr -d ' ' || echo 60)
MAX_FORGES_CONFIG=$(grep 'max_concurrent_forges:' "$CONFIG_FILE" | awk '{print $2}' | tr -d ' ' || echo 3)

POLL_INTERVAL="${AG_POLL_INTERVAL:-$POLL_INTERVAL_CONFIG}"
MAX_FORGES="${AG_MAX_FORGES:-$MAX_FORGES_CONFIG}"

LABEL_TRIGGER="forge-fix"
LABEL_IN_PROGRESS="forge-in-progress"
LABEL_NEEDS_HUMAN="forge-needs-human"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [mission] $1" | tee -a "$MISSION_LOG"
}

active_forge_count() {
  if [ ! -d "$FORGE_DIR" ]; then echo 0; return; fi
  find "$FORGE_DIR" -mindepth 2 -maxdepth 2 -type d -name 'issue-*' 2>/dev/null | wc -l | tr -d ' '
}

resolve_repos() {
  local raw_repos
  if [ -n "${AG_REPOS:-}" ]; then
    # Use comma or space-separated repos from environment variable
    raw_repos=$(echo "$AG_REPOS" | tr ',' ' ')
  else
    # Fallback to config file
    raw_repos=$(grep -E '^\s+- name:' "$CONFIG_FILE" 2>/dev/null | sed 's/.*name:\s*"\?\([^"]*\)"\?.*/\1/' | xargs 2>/dev/null || echo "")
  fi

  local resolved=()
  for entry in $raw_repos; do
    if [[ "$entry" == *"/*" ]]; then
      local owner="${entry%/*}"
      local owner_repos
      owner_repos=$(gh repo list "$owner" --json nameWithOwner --jq '.[].nameWithOwner' --limit 100 2>/dev/null || echo "")
      for r in $owner_repos; do resolved+=("$r"); done
    else
      resolved+=("$entry")
    fi
  done
  echo "${resolved[@]}"
}


if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "Error: OPENROUTER_API_KEY is not set."
  exit 1
fi

if [ -f "$PID_FILE" ]; then
  old_pid=$(cat "$PID_FILE")
  if kill -0 "$old_pid" 2>/dev/null; then exit 1; else rm -f "$PID_FILE"; fi
fi

mkdir -p "$(dirname "$PID_FILE")"
echo $$ > "$PID_FILE"

cleanup() { log "🛑 Shutting down..."; rm -f "$PID_FILE"; exit 0; }
trap cleanup SIGTERM SIGINT SIGHUP

log "🚀 === IronTech started (PID $$) ==="

while true; do
  if [ "$(active_forge_count)" -lt "$MAX_FORGES" ]; then
    REPOS=$(resolve_repos)
    for REPO in $REPOS; do
      # 1. Check for initialization requests (/forge-init in title)
      INIT_ISSUES=$(gh issue list -R "$REPO" --search "/forge-init in:title" --json number --jq '.[].number' 2>/dev/null || echo "")
      for INIT_ID in $INIT_ISSUES; do
        log "🆕 Initializing repository ${REPO} via issue #${INIT_ID}"
        "${SCRIPT_DIR}/repo-init.sh" "$REPO" "$INIT_ID" 2>&1 | tee -a "$MISSION_LOG" || true
      done

      # 2. Process regular issues
      ISSUES=$(gh issue list -R "$REPO" --label "$LABEL_TRIGGER" --json number --jq '.[].number' 2>/dev/null || echo "")
      IN_PROGRESS=$(gh issue list -R "$REPO" --label "$LABEL_IN_PROGRESS" --json number --jq '.[].number' 2>/dev/null || echo "")
      for ISSUE_ID in $ISSUES; do
        if ! echo "$IN_PROGRESS" | grep -q "^${ISSUE_ID}$"; then
          # Verify that the user who added the label is a collaborator
          LABELER=$(gh api repos/$REPO/issues/$ISSUE_ID/events --jq '[.[] | select(.event == "labeled" and .label.name == "'"$LABEL_TRIGGER"'")] | last | .actor.login' 2>/dev/null || echo "")
          if [ -n "$LABELER" ]; then
            if ! gh api "repos/$REPO/collaborators/$LABELER" >/dev/null 2>&1; then
              log "⚠️ Permission Denied: User $LABELER is not a collaborator. Skipping issue #${ISSUE_ID}."
              gh issue edit "$ISSUE_ID" -R "$REPO" --remove-label "$LABEL_TRIGGER" 2>/dev/null || true
              gh issue comment "$ISSUE_ID" -R "$REPO" --body "⚠️ **Permission Denied:** Only contributors can add this label. The \`${LABEL_TRIGGER}\` label has been removed." 2>/dev/null || true
              continue
            fi
          fi

          if [ "$(active_forge_count)" -ge "$MAX_FORGES" ]; then break 2; fi
          log "⚙️ Processing ${REPO} issue #${ISSUE_ID}"
          gh issue edit "$ISSUE_ID" -R "$REPO" --add-label "$LABEL_IN_PROGRESS" --remove-label "$LABEL_TRIGGER" 2>/dev/null || true
          gh issue comment "$ISSUE_ID" -R "$REPO" --body "🔧 **Iron Tech Forge activated.**" 2>/dev/null || true
          "${SCRIPT_DIR}/forge-create.sh" "$REPO" "$ISSUE_ID" 2>&1 | tee -a "$MISSION_LOG" || continue
          "${SCRIPT_DIR}/run-pipeline.sh" "$REPO" "$ISSUE_ID" 2>&1 | tee -a "$MISSION_LOG" || true
          
          # Selective Cleanup: Only wipe if NOT waiting for human input
          if gh issue view "$ISSUE_ID" -R "$REPO" --json labels --jq '.labels[].name' 2>/dev/null | grep -q "forge-needs-human"; then
            log "⏸️ Pipeline paused for human. Preserving workspace for ${REPO} issue #${ISSUE_ID}."
            continue
          fi

          "${SCRIPT_DIR}/forge-cleanup.sh" "$REPO" "$ISSUE_ID" "--force" 2>&1 | tee -a "$MISSION_LOG" || true
        fi
      done
    done

  fi
  sleep "$POLL_INTERVAL"
done
