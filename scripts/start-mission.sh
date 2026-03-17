#!/bin/bash
set -euo pipefail

# start-mission.sh — Polling daemon that monitors GitHub for issues across MULTIPLE repos
#
# Usage: ./scripts/start-mission.sh
#
# This reads repos from .antigravity/config.yml and polls each one for
# issues labeled "ag-fix". Supports wildcards (e.g. "mgosal/*").
#
# Environment:
#   OPENROUTER_API_KEY   — Required
#   AG_POLL_INTERVAL     — Override poll interval (default: 60s)
#   AG_MAX_FORGES        — Override max concurrent forges (default: 3)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PID_FILE="${PROJECT_ROOT}/.antigravity/.mission.pid"
MISSION_LOG="${PROJECT_ROOT}/.antigravity/mission.log"
CONFIG_FILE="${PROJECT_ROOT}/.antigravity/config.yml"

POLL_INTERVAL="${AG_POLL_INTERVAL:-60}"
MAX_FORGES="${AG_MAX_FORGES:-3}"

LABEL_TRIGGER="ag-fix"
LABEL_IN_PROGRESS="ag-in-progress"
LABEL_NEEDS_HUMAN="ag-needs-human"

# ── Helpers ──────────────────────────────────────────────────────────────

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [mission] $1" | tee -a "$MISSION_LOG"
}

active_forge_count() {
  local forge_dir="${PROJECT_ROOT}/.forge"
  if [ ! -d "$forge_dir" ]; then
    echo 0
    return
  fi
  # Count issue-* dirs across all repo slugs
  find "$forge_dir" -mindepth 2 -maxdepth 2 -type d -name 'issue-*' 2>/dev/null | wc -l | tr -d ' '
}

# Resolve repo list from config.yml
# Supports entries like "mgosal/CoS" or "mgosal/*" (wildcard = all repos for owner)
resolve_repos() {
  # Parse repo names from config.yml (simple grep — no yaml parser dependency)
  local raw_repos
  raw_repos=$(grep -E '^\s+- name:' "$CONFIG_FILE" | sed 's/.*name:\s*"\?\([^"]*\)"\?.*/\1/' | sed 's/#.*//' | xargs)

  local resolved=()
  for entry in $raw_repos; do
    if [[ "$entry" == *"/*" ]]; then
      # Wildcard: list all repos for the owner
      local owner="${entry%/*}"
      log "Resolving wildcard: ${entry}"
      local owner_repos
      owner_repos=$(gh repo list "$owner" --json nameWithOwner --jq '.[].nameWithOwner' --limit 100 2>/dev/null || echo "")
      for r in $owner_repos; do
        resolved+=("$r")
      done
    else
      resolved+=("$entry")
    fi
  done

  echo "${resolved[@]}"
}

# ── Preflight ────────────────────────────────────────────────────────────

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "Error: OPENROUTER_API_KEY is not set."
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI (gh) is required."
  exit 1
fi

if ! gh auth status &>/dev/null; then
  echo "Error: GitHub CLI not authenticated. Run 'gh auth login'."
  exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "Error: Config not found at ${CONFIG_FILE}"
  exit 1
fi

# Check for existing daemon
if [ -f "$PID_FILE" ]; then
  old_pid=$(cat "$PID_FILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "Error: Mission Runner already running (PID ${old_pid}). Use stop-mission.sh."
    exit 1
  else
    rm -f "$PID_FILE"
  fi
fi

# ── Daemon ───────────────────────────────────────────────────────────────

mkdir -p "$(dirname "$PID_FILE")"
echo $$ > "$PID_FILE"

cleanup() {
  log "Mission Runner shutting down (PID $$)..."
  rm -f "$PID_FILE"
  exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

log "=== Mission Runner started (PID $$) ==="
log "Poll interval: ${POLL_INTERVAL}s | Max concurrent forges: ${MAX_FORGES}"

while true; do
  # Check capacity
  CURRENT_FORGES=$(active_forge_count)
  if [ "$CURRENT_FORGES" -ge "$MAX_FORGES" ]; then
    log "At capacity (${CURRENT_FORGES}/${MAX_FORGES} forges). Skipping poll."
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Resolve repos to watch
  REPOS=$(resolve_repos)
  if [ -z "$REPOS" ]; then
    log "No repos configured. Check .antigravity/config.yml"
    sleep "$POLL_INTERVAL"
    continue
  fi

  # ── Poll each repo ──────────────────────────────────────────────────
  for REPO in $REPOS; do
    log "Polling ${REPO} for label '${LABEL_TRIGGER}'..."

    ISSUES=$(gh issue list -R "$REPO" --label "$LABEL_TRIGGER" --json number --jq '.[].number' 2>/dev/null || echo "")
    IN_PROGRESS=$(gh issue list -R "$REPO" --label "$LABEL_IN_PROGRESS" --json number --jq '.[].number' 2>/dev/null || echo "")

    for ISSUE_ID in $ISSUES; do
      # Skip if in progress
      if echo "$IN_PROGRESS" | grep -q "^${ISSUE_ID}$"; then
        continue
      fi

      # Re-check capacity
      CURRENT_FORGES=$(active_forge_count)
      if [ "$CURRENT_FORGES" -ge "$MAX_FORGES" ]; then
        log "Reached capacity. Deferring remaining issues."
        break 2
      fi

      ISSUE_TITLE=$(gh issue view "$ISSUE_ID" -R "$REPO" --json title --jq '.title' 2>/dev/null || echo "Issue #${ISSUE_ID}")
      log "Processing ${REPO} issue #${ISSUE_ID}: ${ISSUE_TITLE}"

      # Mark as in-progress
      gh issue edit "$ISSUE_ID" -R "$REPO" --add-label "$LABEL_IN_PROGRESS" --remove-label "$LABEL_TRIGGER" 2>/dev/null || true
      gh issue comment "$ISSUE_ID" -R "$REPO" --body "🔧 **Anti Gravity Forge activated.** Working on this issue now." 2>/dev/null || true

      # Create forge (clones the target repo)
      "${SCRIPT_DIR}/forge-create.sh" "$REPO" "$ISSUE_ID" 2>&1 | tee -a "$MISSION_LOG" || {
        log "ERROR: Failed to create forge for ${REPO} issue #${ISSUE_ID}"
        gh issue edit "$ISSUE_ID" -R "$REPO" --add-label "$LABEL_NEEDS_HUMAN" --remove-label "$LABEL_IN_PROGRESS" 2>/dev/null || true
        gh issue comment "$ISSUE_ID" -R "$REPO" --body "❌ Anti Gravity Forge failed to initialize." 2>/dev/null || true
        continue
      }

      # Run pipeline
      "${SCRIPT_DIR}/run-pipeline.sh" "$REPO" "$ISSUE_ID" 2>&1 | tee -a "$MISSION_LOG" || {
        log "ERROR: Pipeline failed for ${REPO} issue #${ISSUE_ID}"
        continue
      }

      log "Successfully processed ${REPO} issue #${ISSUE_ID}"
    done
  done

  log "Poll complete. Sleeping ${POLL_INTERVAL}s..."
  sleep "$POLL_INTERVAL"
done
