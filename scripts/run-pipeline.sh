#!/bin/bash
set -euo pipefail

# run-pipeline.sh v2 — Genuinely Agentic Auto-Fix Pipeline
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

# Source the tool dispatch library
source "${SCRIPT_DIR}/lib/tool-dispatch.sh"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

pause_for_human() {
  local reason="$1"
  log "PIPELINE PAUSED: ${reason}"
  gh issue edit "$ISSUE_ID" -R "$REPO" --add-label "forge-needs-human" --remove-label "forge-in-progress" 2>/dev/null || true
  exit 0
}

post_comment_and_pause() {
  local comment_body="$1"
  local reason="$2"
  gh issue comment "$ISSUE_ID" -R "$REPO" --body "$comment_body" 2>/dev/null || true
  pause_for_human "$reason"
}

extract_json() {
  local text="$1"
  json=$(echo "$text" | awk '/^```json/{json=""; p=1; next} /^```$/{p=0} p{json=json $0 "\n"} END{print json}')
  if [ -z "$json" ]; then json=$(echo "$text" | grep -o '{.*}' | tail -n 1 || echo ""); fi
  if [ -z "$json" ]; then json=$(echo "$text" | sed -n '/^{/,/^}/p' | tail -n 1000 || echo ""); fi
  if [ -z "$json" ]; then echo "$text"; else echo "$json"; fi
}

if [ ! -d "$FORGE_DIR" ]; then exit 1; fi
if [ -z "${OPENROUTER_API_KEY:-}" ]; then exit 1; fi
mkdir -p "$META_DIR"

log "🚀 === FORGE PIPELINE v2 START: ${REPO} Issue #${ISSUE_ID} ==="

ISSUE_JSON=$(gh issue view "$ISSUE_ID" -R "$REPO" --json title,body,labels,comments 2>/dev/null || echo '{}')
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title // "Unknown"')

# Validate if labels specify forge-needs-human
LABELS=$(echo "$ISSUE_JSON" | jq -r '.labels[].name' 2>/dev/null || echo "")
if echo "$LABELS" | grep -q "forge-needs-human"; then
  log "Issue is waiting on human input. Skipping."
  exit 0
fi

# Stage 0: Index Codebase
log "🔍 --- Stage 0: Indexing Codebase ---"
"${SCRIPT_DIR}/lib/codebase-index.sh" "$FORGE_DIR" 2>&1 | tee -a "$LOG_FILE" || true
CONTEXT_JSON=$(cat "${META_DIR}/context.json" 2>/dev/null || echo '{}')
BLANK_REPO=$(echo "$CONTEXT_JSON" | jq -r '.blank_repo // false')

readonly TOOLS_READ='[{"type":"function","function":{"name":"read_file","description":"Read file content","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},{"type":"function","function":{"name":"list_dir","description":"List directory structure","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},{"type":"function","function":{"name":"search_codebase","description":"Search for regex pattern across files","parameters":{"type":"object","properties":{"query":{"type":"string"},"path":{"type":"string"}},"required":["query","path"]}}}]'
# Full toolset for engineer/test
readonly TOOLS_FULL=$(echo "$TOOLS_READ" | jq '. + [{"type":"function","function":{"name":"write_file","description":"Write content to a file","parameters":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}}},{"type":"function","function":{"name":"apply_diff","description":"Apply a git diff patch","parameters":{"type":"object","properties":{"patch":{"type":"string"}},"required":["patch"]}}},{"type":"function","function":{"name":"run_shell","description":"Run an allowlisted build or test command","parameters":{"type":"object","properties":{"cmd":{"type":"string"}},"required":["cmd"]}}},{"type":"function","function":{"name":"sed_replace","description":"In-place regex string replacement","parameters":{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"replacement":{"type":"string"}},"required":["path","pattern","replacement"]}}},{"type":"function","function":{"name":"awk_query","description":"Execute an awk script","parameters":{"type":"object","properties":{"path":{"type":"string"},"query":{"type":"string"}},"required":["path","query"]}}},{"type":"function","function":{"name":"count_lines","description":"Count lines in a file","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}},{"type":"function","function":{"name":"file_diff","description":"Show diff between two files","parameters":{"type":"object","properties":{"path1":{"type":"string"},"path2":{"type":"string"}},"required":["path1","path2"]}}}]')

# Stage 1: Architect (if blank repo or flagged later)
if [ "$BLANK_REPO" = "true" ]; then
  log "🏗️ --- Stage 1: Architect (Blank Repo) ---"
  ARCHITECT_RAW=$(invoke_tool_agent "architect" "# Issue\n\`\`\`json\n${ISSUE_JSON}\n\`\`\`\n\n# Context\n\`\`\`json\n${CONTEXT_JSON}\n\`\`\`" "$TOOLS_READ")
  extract_json "$ARCHITECT_RAW" > "${META_DIR}/architect.json"
  
  if jq -e . >/dev/null 2>&1 <<< "$(cat "${META_DIR}/architect.json")"; then
    if [ "$(jq -r '.approved // false' "${META_DIR}/architect.json")" = "true" ]; then
      log "✅ Architect plan explicitly approved by human. Proceeding..."
    else
      ARCHITECT_COMMENT=$(jq -r '.comment_body // ""' "${META_DIR}/architect.json")
      if [ -z "$ARCHITECT_COMMENT" ]; then ARCHITECT_COMMENT=$(cat "${META_DIR}/architect.json"); fi
      echo "$ARCHITECT_COMMENT" > "${META_DIR}/architect.md"
      post_comment_and_pause "⏳ **Action Required: Architect Plan**\n\n$ARCHITECT_COMMENT" "Waiting for human to approve architect plan"
    fi
  else
    log "⚠️ Architect agent failed to output valid JSON. Falling back to raw text string."
    ARCHITECT_COMMENT=$(cat "${META_DIR}/architect.json" || echo "Fatal error extracting plan.")
    echo "$ARCHITECT_COMMENT" > "${META_DIR}/architect.md"
    post_comment_and_pause "⏳ **Action Required: Architect Plan**\n\n$ARCHITECT_COMMENT" "Waiting for human to approve architect plan"
  fi
fi

# Stage 2: Triage
log "📥 --- Stage 2: Triager ---"
TRIAGE_RAW=$(invoke_tool_agent "triager" "# Issue\n\`\`\`json\n${ISSUE_JSON}\n\`\`\`\n\n# Context\n\`\`\`json\n${CONTEXT_JSON}\n\`\`\`" "$TOOLS_READ")
extract_json "$TRIAGE_RAW" > "${META_DIR}/triage.json"

# Check triage outputs
if [ "$(jq -r '.actionable' "${META_DIR}/triage.json")" != "true" ]; then
  CLARIFICATION=$(jq -r '.clarification_needed // "Issue lacks actionable details."' "${META_DIR}/triage.json")
  post_comment_and_pause "### ⚠️ Triager Needs Clarification\n\n${CLARIFICATION}\n\n*Please reply below and add the \`forge-fix\` label to try again.*" "Triage Clarification Needed"
fi

if [ "$(jq -r '.architectural_change // false' "${META_DIR}/triage.json")" = "true" ]; then
  log "⚠️ --- Architect Escalation from Triager ---"
  ARCHITECT_RAW=$(invoke_tool_agent "architect" "# Issue\n\`\`\`json\n${ISSUE_JSON}\n\`\`\`\n\n# Triage Findings\n\`\`\`json\n$(cat "${META_DIR}/triage.json")\n\`\`\`" "$TOOLS_READ")
  extract_json "$ARCHITECT_RAW" > "${META_DIR}/architect.json"
  
  if jq -e . >/dev/null 2>&1 <<< "$(cat "${META_DIR}/architect.json")"; then
    if [ "$(jq -r '.approved // false' "${META_DIR}/architect.json")" = "true" ]; then
      log "✅ Structural plan explicitly approved by human. Proceeding..."
    else
      ARCHITECT_COMMENT=$(jq -r '.comment_body // ""' "${META_DIR}/architect.json")
      if [ -z "$ARCHITECT_COMMENT" ]; then ARCHITECT_COMMENT=$(cat "${META_DIR}/architect.json"); fi
      post_comment_and_pause "⏳ **Action Required: Structural Plan**\n\n$ARCHITECT_COMMENT" "Waiting for human to approve mid-issue structural plan"
    fi
  else
    log "⚠️ Architect agent failed to output valid JSON. Falling back to raw text string."
    ARCHITECT_COMMENT=$(cat "${META_DIR}/architect.json" || echo "Fatal error extracting plan.")
    post_comment_and_pause "⏳ **Action Required: Structural Plan**\n\n$ARCHITECT_COMMENT" "Waiting for human to approve mid-issue structural plan"
  fi
fi

# Configuration limits
MAX_RETRIES=$(grep 'max_retries:' "$CONFIG_FILE" | awk '{print $2}' || echo 3)

# Stage 3: Engineer Loop
log "🧑‍💻 --- Stage 3: Engineer Loop ---"
ENGINEER_PROMPT="# Plan\n\`\`\`json\n$(cat "${META_DIR}/triage.json")\n\`\`\`\n\n# Context\n\`\`\`json\n${CONTEXT_JSON}\n\`\`\`"
round=1
engineer_success=false

while [ $round -le $MAX_RETRIES ]; do
  log "⚙️ Engineer attempt $round..."
  ENGINEER_RAW=$(invoke_tool_agent "engineer" "$ENGINEER_PROMPT" "$TOOLS_FULL")
  extract_json "$ENGINEER_RAW" > "${META_DIR}/engineer.json"
  
  if [ "$(jq -r '.build_passes' "${META_DIR}/engineer.json")" = "true" ]; then
    log "✅ Engineer succeeded on round $round."
    engineer_success=true
    break
  fi
  
  if [ $round -eq $MAX_RETRIES ]; then
    log "❌ Engineer exhausted $MAX_RETRIES retries."
    ESCALATE=$(invoke_tool_agent "retry-escalation" "# Component: Engineer Build\n# Triage Plan\n\`\`\`json\n$(cat "${META_DIR}/triage.json")\n\`\`\`\n\n# Last Output\n\`\`\`json\n$(cat "${META_DIR}/engineer.json")\n\`\`\`" "null")
    post_comment_and_pause "🛑 **Engineer Retry Exhaustion:**\n\n$ESCALATE" "Engineer Retry Exhaustion"
  fi
  
  ENGINEER_PROMPT="${ENGINEER_PROMPT}\n\n# Round ${round} Failure\nThe build failed. See the exit_code and output in your previous message. You must fix the error."
  round=$((round+1))
done

# Stage 4: Test Loop
log "🧪 --- Stage 4: Test-Writer Loop ---"
DIFF=$(cd "$FORGE_DIR" && git diff HEAD 2>/dev/null || echo "")
TEST_PROMPT="# Plan\n\`\`\`json\n$(cat "${META_DIR}/triage.json")\n\`\`\`\n\n# Context\n\`\`\`json\n${CONTEXT_JSON}\n\`\`\`\n\n# Engineering Diff\n\`\`\`diff\n${DIFF}\n\`\`\`"
round=1
test_success=false

while [ $round -le $MAX_RETRIES ]; do
  log "⚙️ Test writer attempt $round..."
  TEST_RAW=$(invoke_tool_agent "test-writer" "$TEST_PROMPT" "$TOOLS_FULL")
  extract_json "$TEST_RAW" > "${META_DIR}/tests.json"
  
  if [ "$(jq -r '.all_tests_pass' "${META_DIR}/tests.json")" = "true" ]; then
    log "✅ Tests succeeded on round $round."
    test_success=true
    break
  fi
  
  if [ $round -eq $MAX_RETRIES ]; then
    log "❌ Test-Writer exhausted $MAX_RETRIES retries."
    ESCALATE=$(invoke_tool_agent "retry-escalation" "# Component: Test Execution\n# Plan\n\`\`\`json\n$(cat "${META_DIR}/triage.json")\n\`\`\`\n\n# Last Output\n\`\`\`json\n$(cat "${META_DIR}/tests.json")\n\`\`\`" "null")
    post_comment_and_pause "🛑 **Test-Writer Retry Exhaustion:**\n\n$ESCALATE" "Test-Writer Retry Exhaustion"
  fi
  
  TEST_PROMPT="${TEST_PROMPT}\n\n# Round ${round} Failure\nTests failed. See output in your previous message. Fix the tests or code."
  round=$((round+1))
done

# Stage 5: Security Gate (WIP - To be enabled in further stages)
# log "--- Stage 5: Security Gate ---"
# SECURITY_RAW=$(invoke_tool_agent "security-gate" "# Diff\n\`\`\`diff\n${DIFF}\n\`\`\`" "$TOOLS_READ")
# extract_json "$SECURITY_RAW" > "${META_DIR}/security-report.json"
# 
# if [ "$(jq -r '.overall_passed' "${META_DIR}/security-report.json")" != "true" ]; then
#   ADVICE=$(jq -r '.remediation_advice // "Security scan failed."' "${META_DIR}/security-report.json")
#   post_comment_and_pause "### 🚨 Security Vulnerability Detected\n\n${ADVICE}\n\n*Please reply with approval to bypass or adjust the code, then add the \`forge-fix\` label to retry.*" "Security Failure"
# fi

# Stage 5: Code Review
log "👀 --- Stage 5: Code Review ---"
REVIEW_RAW=$(invoke_tool_agent "code-reviewer" "# Diff\n\`\`\`diff\n${DIFF}\n\`\`\`" "$TOOLS_READ")
extract_json "$REVIEW_RAW" > "${META_DIR}/review.json"

CONFIDENCE=$(jq -r '.confidence_score' "${META_DIR}/review.json")
if (( $(echo "$CONFIDENCE < 0.7" | bc -l) )) || [ "$(jq -r '.approval_status' "${META_DIR}/review.json")" = "needs_work" ]; then
  COMMENTS=$(jq -r '.review_comments | join("\n- ")' "${META_DIR}/review.json")
  post_comment_and_pause "### 🧐 Code Review Feedback (Needs Work)\n\n- ${COMMENTS}\n\n*Please adjust the code or provide feedback, then add the \`forge-fix\` label.*" "Review Failure"
fi

# Stage 6: PR Assembly
log "📦 --- Stage 6: PR Assembly ---"
PR_RESPONSE=$(invoke_tool_agent "pr-assembler" "# Context\n$(ls "${META_DIR}")" "null")
echo "$PR_RESPONSE" > "${META_DIR}/pr-description.md"

# Publish PR
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

log "🎉 === FORGE PIPELINE COMPLETE ==="
