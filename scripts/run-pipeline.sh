#!/bin/bash
set -euo pipefail

# run-pipeline.sh — Execute the full auto-fix pipeline for a single issue
#
# Usage: ./scripts/run-pipeline.sh <owner/repo> <issue-id>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env if it exists
if [ -f "${PROJECT_ROOT}/.env" ]; then
  set -a
  source "${PROJECT_ROOT}/.env"
  set +a
elif [ -f "${PROJECT_ROOT}/.env.local" ]; then
  set -a
  source "${PROJECT_ROOT}/.env.local"
  set +a
fi

if [ $# -lt 2 ]; then
  echo "Usage: $0 <owner/repo> <issue-id>"
  exit 1
fi

REPO="$1"
ISSUE_ID="$2"
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)
REPO_SLUG="${OWNER}-${REPO_NAME}"
CONFIG_FILE="${PROJECT_ROOT}/.forge-master/config.yml"

FORGE_BASE=$(grep 'base_dir:' "$CONFIG_FILE" | awk '{print $2}' | tr -d '"' || echo ".forge")
FORGE_DIR="${PROJECT_ROOT}/${FORGE_BASE}/${REPO_SLUG}/issue-${ISSUE_ID}"
META_DIR="${FORGE_DIR}/.forge-meta"
LOG_FILE="${META_DIR}/pipeline.log"
AGENTS_DIR="${PROJECT_ROOT}/.agents"
TEMPLATES_DIR="${PROJECT_ROOT}/.forge-master/templates"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

gate_check() {
  local file="$1" field="$2" expected="$3" stage="$4"
  if [ ! -s "$file" ]; then
    log "GATE FAILED at ${stage}: Output file is empty or missing."
    exit 1
  fi
  actual=$(jq -r "$field" "$file" 2>/dev/null || echo "parse_error")
  if [ "$actual" != "$expected" ]; then
    log "GATE FAILED at ${stage}: ${field} = ${actual} (expected ${expected})"
    gh issue edit "$ISSUE_ID" -R "$REPO" --add-label "forge-needs-human" --remove-label "forge-in-progress" 2>/dev/null || true
    gh issue comment "$ISSUE_ID" -R "$REPO" --body "⚠️ Forge Master pipeline halted at **${stage}**. Check the forge log for details." 2>/dev/null || true
    exit 1
  fi
}

invoke_agent() {
  local agent_name="$1"
  local extra_context="$2"
  local rules_file="${AGENTS_DIR}/rules/${agent_name}.md"
  local conventions_file="${AGENTS_DIR}/shared/conventions.md"

  local system_prompt
  system_prompt="$(cat "$rules_file")"
  [ -f "$conventions_file" ] && system_prompt="${system_prompt}\n\n---\n# Shared Conventions\n$(cat "$conventions_file")"
  [ "$agent_name" = "security-gate" ] && [ -f "${AGENTS_DIR}/shared/security-patterns.md" ] && system_prompt="${system_prompt}\n\n---\n# Security Patterns\n$(cat "${AGENTS_DIR}/shared/security-patterns.md")"

  local AGENT_MODEL=$(grep 'model:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"' || echo "anthropic/claude-3-opus")

  log "Invoking agent: ${agent_name} (${AGENT_MODEL})"
  
  # Use curl with verbose output on error
  set +e
  response=$(curl -s -S -w "\n%{http_code}" https://openrouter.ai/api/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    -d "$(jq -n --arg model "$AGENT_MODEL" --arg system "$system_prompt" --arg user "$extra_context" '{model: $model, messages: [{role: "system", content: $system}, {role: "user", content: $user}], max_tokens: 8192, temperature: 0}')")
  curl_exit=$?
  set -e

  http_code=$(echo "$response" | tail -n 1)
  body=$(echo "$response" | sed '$d')

  if [ "$curl_exit" -ne 0 ] || [ "$http_code" != "200" ]; then
    log "ERROR: Agent ${agent_name} call failed (Curl: ${curl_exit}, HTTP: ${http_code})"
    log "Response Body: ${body}"
    exit 1
  fi

  content=$(echo "$body" | jq -r '.choices[0].message.content // empty')
  if [ -z "$content" ]; then
    log "ERROR: No content in agent response for ${agent_name}."
    exit 1
  fi
  echo "$content"
}

extract_json() {
  local text="$1"
  # Try to find the last ```json block
  json=$(echo "$text" | awk '/^```json/{json=""; p=1; next} /^```$/{p=0} p{json=json $0 "\n"} END{print json}')
  
  if [ -z "$json" ]; then
    # Fallback: Find the last text between '{' and '}'
    json=$(echo "$text" | grep -o '{.*}' | tail -n 1 || echo "")
  fi
  
  if [ -z "$json" ]; then
    # Final fallback for multi-line JSON without markers
    json=$(echo "$text" | sed -n '/^{/,/^}/p' | tail -n 1000 || echo "")
  fi
  
  if [ -z "$json" ]; then
    echo "$text"
  else
    echo "$json"
  fi
}

if [ ! -d "$FORGE_DIR" ]; then exit 1; fi
if [ -z "${OPENROUTER_API_KEY:-}" ]; then exit 1; fi
mkdir -p "$META_DIR"

log "=== FORGE PIPELINE START: ${REPO} Issue #${ISSUE_ID} ==="
ISSUE_JSON=$(gh issue view "$ISSUE_ID" -R "$REPO" --json title,body,labels,comments 2>/dev/null || echo '{}')
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title // "Unknown"')
REPO_TREE=$(find "$FORGE_DIR" -type f -not -path '*/.git/*' -not -path '*/.forge-meta/*' -not -path '*/node_modules/*' | sed "s|${FORGE_DIR}/||" | head -200)

# Stage 1: Triage
log "--- Stage 1: Triager ---"
TRIAGE_RESPONSE=$(invoke_agent "triager" "# Issue #${ISSUE_ID} on ${REPO}\n\n## Issue Data\n\`\`\`json\n${ISSUE_JSON}\n\`\`\`\n\n## Repo Tree\n\`\`\`\n${REPO_TREE}\n\`\`\`")
extract_json "$TRIAGE_RESPONSE" > "${META_DIR}/triage.json"
gate_check "${META_DIR}/triage.json" ".actionable" "true" "Triage"

# Stage 2: Engineer
log "--- Stage 2: Engineer ---"
AFFECTED_FILES=$(jq -r '.affected_files[]' "${META_DIR}/triage.json" 2>/dev/null || echo "")
FILE_CONTENTS=""
for f in $AFFECTED_FILES; do
  if [ -f "${FORGE_DIR}/${f}" ]; then
    FILE_CONTENTS="${FILE_CONTENTS}\n\n### ${f}\n\`\`\`\n$(cat "${FORGE_DIR}/${f}")\n\`\`\`"
  fi
done
ENGINEER_RESPONSE=$(invoke_agent "engineer" "# Plan\n\`\`\`json\n$(cat "${META_DIR}/triage.json")\n\`\`\`\n\n# Affected Files\n${FILE_CONTENTS}")
extract_json "$ENGINEER_RESPONSE" > "${META_DIR}/engineer.json"
gate_check "${META_DIR}/engineer.json" ".build_passes" "true" "Engineer (build)"

# Stage 3: Test Writer
log "--- Stage 3: Test Writer ---"
DIFF=$(cd "$FORGE_DIR" && git diff HEAD 2>/dev/null || echo "")
TEST_RESPONSE=$(invoke_agent "test-writer" "# Triage\n\`\`\`json\n$(cat "${META_DIR}/triage.json")\n\`\`\`\n\n# Diff\n\`\`\`diff\n${DIFF}\n\`\`\`")
extract_json "$TEST_RESPONSE" > "${META_DIR}/tests.json"
gate_check "${META_DIR}/tests.json" ".all_tests_pass" "true" "Test Writer"

# Stage 4: Security
log "--- Stage 4: Security Gate ---"
SECURITY_RESPONSE=$(invoke_agent "security-gate" "# Diff\n\`\`\`diff\n${DIFF}\n\`\`\`")
extract_json "$SECURITY_RESPONSE" > "${META_DIR}/security-report.json"
gate_check "${META_DIR}/security-report.json" ".overall_passed" "true" "Security Gate"

# Stage 5: Review
log "--- Stage 5: Code Review ---"
REVIEW_RESPONSE=$(invoke_agent "code-reviewer" "# Diff\n\`\`\`diff\n${DIFF}\n\`\`\`")
extract_json "$REVIEW_RESPONSE" > "${META_DIR}/review.json"
CONFIDENCE=$(jq -r '.confidence_score' "${META_DIR}/review.json")
if (( $(echo "$CONFIDENCE < 0.5" | bc -l) )); then exit 1; fi

# Stage 6: Assembler
log "--- Stage 6: PR Assembly ---"
PR_RESPONSE=$(invoke_agent "pr-assembler" "# Context\n$(ls "${META_DIR}")")
echo "$PR_RESPONSE" > "${META_DIR}/pr-description.md"

# Get bot identity from environment or config
BOT_NAME="${AG_BOT_NAME:-$(grep 'name:' "$CONFIG_FILE" -A 0 | grep -v 'agent_name' | head -1 | sed 's/.*name: "\([^"]*\)".*/\1/' || echo "ForgeMaster")}"
BOT_EMAIL="${AG_BOT_EMAIL:-$(grep 'email:' "$CONFIG_FILE" | awk '{print $2}' | tr -d '"' || echo "bot@example.com")}"

cd "$FORGE_DIR"
git add -A
git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" commit -m "fix: resolve issue #${ISSUE_ID} (#${ISSUE_ID})" || true
BRANCH_NAME="ag/issue-${ISSUE_ID}"
git push origin "$BRANCH_NAME" 2>/dev/null || git push --set-upstream origin "$BRANCH_NAME"
BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
gh pr create -R "$REPO" --base "$BASE_BRANCH" --head "$BRANCH_NAME" --title "🔧 fix: ${ISSUE_TITLE}" --body-file "${META_DIR}/pr-description.md" --draft --label "forge-pr-ready" 2>/dev/null || true
gh issue edit "$ISSUE_ID" -R "$REPO" --add-label "forge-pr-ready" --remove-label "forge-in-progress" 2>/dev/null || true

log "=== FORGE PIPELINE COMPLETE ==="
