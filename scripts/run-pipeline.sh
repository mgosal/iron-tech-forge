#!/bin/bash
set -euo pipefail

# run-pipeline.sh — Execute the full auto-fix pipeline for a single issue
#
# Usage: ./scripts/run-pipeline.sh <owner/repo> <issue-id>
#
# The forge must already be created via forge-create.sh.
# The pipeline runs INSIDE the cloned target repo, not inside anti-gravity-forge itself.
#
# Prerequisites:
#   - gh CLI authenticated
#   - OPENROUTER_API_KEY set in environment

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -lt 2 ]; then
  echo "Usage: $0 <owner/repo> <issue-id>"
  exit 1
fi

REPO="$1"
ISSUE_ID="$2"
OWNER=$(echo "$REPO" | cut -d'/' -f1)
REPO_NAME=$(echo "$REPO" | cut -d'/' -f2)
REPO_SLUG="${OWNER}-${REPO_NAME}"

FORGE_DIR="${PROJECT_ROOT}/.forge/${REPO_SLUG}/issue-${ISSUE_ID}"
META_DIR="${FORGE_DIR}/.forge-meta"
LOG_FILE="${META_DIR}/pipeline.log"

# Agent definitions live in anti-gravity-forge, NOT in the target repo
AGENTS_DIR="${PROJECT_ROOT}/.agents"
TEMPLATES_DIR="${PROJECT_ROOT}/.antigravity/templates"

# ── Helpers ──────────────────────────────────────────────────────────────

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a "$LOG_FILE"
}

gate_check() {
  local file="$1" field="$2" expected="$3" stage="$4"
  actual=$(jq -r "$field" "$file")
  if [ "$actual" != "$expected" ]; then
    log "GATE FAILED at ${stage}: ${field} = ${actual} (expected ${expected})"
    gh issue edit "$ISSUE_ID" -R "$REPO" --add-label "ag-needs-human" --remove-label "ag-in-progress" 2>/dev/null || true
    gh issue comment "$ISSUE_ID" -R "$REPO" --body "⚠️ Anti Gravity pipeline halted at **${stage}**. \`${field}\` = \`${actual}\` (expected \`${expected}\`). Check the forge log for details." 2>/dev/null || true
    exit 1
  fi
}

invoke_agent() {
  local agent_name="$1"
  local extra_context="$2"

  local rules_file="${AGENTS_DIR}/rules/${agent_name}.md"
  local conventions_file="${AGENTS_DIR}/shared/conventions.md"

  if [ ! -f "$rules_file" ]; then
    log "ERROR: Agent rules file not found: ${rules_file}"
    exit 1
  fi

  local system_prompt
  system_prompt="$(cat "$rules_file")"

  if [ -f "$conventions_file" ]; then
    system_prompt="${system_prompt}

---
# Shared Project Conventions
$(cat "$conventions_file")"
  fi

  if [ "$agent_name" = "security-gate" ] && [ -f "${AGENTS_DIR}/shared/security-patterns.md" ]; then
    system_prompt="${system_prompt}

---
# Security Anti-Patterns Reference
$(cat "${AGENTS_DIR}/shared/security-patterns.md")"
  fi

  log "Invoking agent: ${agent_name}"

  local response
  response=$(curl -s https://openrouter.ai/api/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    -d "$(jq -n \
      --arg model "anthropic/claude-opus" \
      --arg system "$system_prompt" \
      --arg user "$extra_context" \
      '{
        model: $model,
        messages: [
          { role: "system", content: $system },
          { role: "user", content: $user }
        ],
        max_tokens: 8192,
        temperature: 0
      }'
    )")

  local content
  content=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [ -z "$content" ]; then
    log "ERROR: No response from agent ${agent_name}. API response: $(echo "$response" | jq -c '.error // .')"
    exit 1
  fi

  echo "$content"
}

extract_json() {
  local text="$1"
  local json
  json=$(echo "$text" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
  if [ -z "$json" ]; then
    json=$(echo "$text" | sed -n '/^{/,/^}/p')
  fi
  if [ -z "$json" ]; then
    json="$text"
  fi
  echo "$json"
}

# ── Preflight ────────────────────────────────────────────────────────────

if [ ! -d "$FORGE_DIR" ]; then
  echo "Error: Forge not found at ${FORGE_DIR}. Run forge-create.sh first."
  echo "  ./scripts/forge-create.sh ${REPO} ${ISSUE_ID}"
  exit 1
fi

if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  echo "Error: OPENROUTER_API_KEY is not set."
  exit 1
fi

mkdir -p "$META_DIR"

# ── Pipeline ─────────────────────────────────────────────────────────────

log "=== FORGE PIPELINE START: ${REPO} Issue #${ISSUE_ID} ==="

# Fetch issue data from GitHub (targeting the specific repo)
log "Fetching issue data from ${REPO}..."
ISSUE_JSON=$(gh issue view "$ISSUE_ID" -R "$REPO" --json title,body,labels,comments 2>/dev/null || echo '{}')
ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title // "Unknown"')

log "Issue: ${ISSUE_TITLE}"

# Build repo context (file tree of the TARGET repo, not anti-gravity-forge)
REPO_TREE=$(find "$FORGE_DIR" -type f \
  -not -path '*/.git/*' \
  -not -path '*/.forge-meta/*' \
  -not -path '*/node_modules/*' \
  -not -path '*/.next/*' \
  -not -path '*/dist/*' \
  -not -path '*/__pycache__/*' \
  | sed "s|${FORGE_DIR}/||" \
  | head -200)

# ── Stage 1: TRIAGE ─────────────────────────────────────────────────────

log "--- Stage 1: Triager ---"

TRIAGE_INPUT="# Issue #${ISSUE_ID} on ${REPO}

## Issue Data
\`\`\`json
${ISSUE_JSON}
\`\`\`

## Repository File Tree
\`\`\`
${REPO_TREE}
\`\`\`

Please analyze this issue and produce your triage.json output."

TRIAGE_RESPONSE=$(invoke_agent "triager" "$TRIAGE_INPUT")
extract_json "$TRIAGE_RESPONSE" > "${META_DIR}/triage.json"

gate_check "${META_DIR}/triage.json" ".actionable" "true" "Triage"
log "Triage complete. Classification: $(jq -r .classification "${META_DIR}/triage.json")"

# ── Stage 2: ENGINEER ───────────────────────────────────────────────────

log "--- Stage 2: Engineer ---"

AFFECTED_FILES=$(jq -r '.affected_files[]' "${META_DIR}/triage.json" 2>/dev/null || echo "")
FILE_CONTENTS=""
for f in $AFFECTED_FILES; do
  filepath="${FORGE_DIR}/${f}"
  if [ -f "$filepath" ]; then
    FILE_CONTENTS="${FILE_CONTENTS}

### ${f}
\`\`\`
$(cat "$filepath")
\`\`\`"
  fi
done

ENGINEER_INPUT="# Triage Plan
\`\`\`json
$(cat "${META_DIR}/triage.json")
\`\`\`

# Affected File Contents
${FILE_CONTENTS}

# Repository File Tree
\`\`\`
${REPO_TREE}
\`\`\`

Implement the fix as described in the triage plan. Output:
1. For each file you modify, provide the full updated file content in a code block labeled with the file path.
2. After the file contents, provide your engineer.json output."

ENGINEER_RESPONSE=$(invoke_agent "engineer" "$ENGINEER_INPUT")

# TODO: Parse file modifications from engineer response and apply them to the forge worktree.
# The engineer returns file contents in labeled code blocks — a parser is needed to extract
# and write them. For now, extract just the JSON contract.
extract_json "$ENGINEER_RESPONSE" > "${META_DIR}/engineer.json"

gate_check "${META_DIR}/engineer.json" ".build_passes" "true" "Engineer (build)"
gate_check "${META_DIR}/engineer.json" ".lint_passes" "true" "Engineer (lint)"
log "Engineering complete. Files modified: $(jq '.files_modified | length' "${META_DIR}/engineer.json")"

# ── Stage 3: TEST WRITER ────────────────────────────────────────────────

log "--- Stage 3: Test Writer ---"

DIFF=$(cd "$FORGE_DIR" && git diff HEAD 2>/dev/null || echo "(no diff yet)")

TEST_INPUT="# Triage
\`\`\`json
$(cat "${META_DIR}/triage.json")
\`\`\`

# Engineer Output
\`\`\`json
$(cat "${META_DIR}/engineer.json")
\`\`\`

# Current Diff
\`\`\`diff
${DIFF}
\`\`\`

# Repository File Tree
\`\`\`
${REPO_TREE}
\`\`\`

Write tests as described in your rules. Output:
1. Test file contents in labeled code blocks.
2. Your tests.json output."

TEST_RESPONSE=$(invoke_agent "test-writer" "$TEST_INPUT")
extract_json "$TEST_RESPONSE" > "${META_DIR}/tests.json"

gate_check "${META_DIR}/tests.json" ".all_tests_pass" "true" "Test Writer"
log "Tests complete. Added: $(jq .tests_added "${META_DIR}/tests.json")"

# ── Stage 4: SECURITY GATE ──────────────────────────────────────────────

log "--- Stage 4: Security Gate ---"

SECURITY_INPUT="# Full Diff (${REPO})
\`\`\`diff
${DIFF}
\`\`\`

# Triage Context
\`\`\`json
$(cat "${META_DIR}/triage.json")
\`\`\`

Perform your security analysis on this diff and produce security-report.json."

SECURITY_RESPONSE=$(invoke_agent "security-gate" "$SECURITY_INPUT")
extract_json "$SECURITY_RESPONSE" > "${META_DIR}/security-report.json"

gate_check "${META_DIR}/security-report.json" ".overall_passed" "true" "Security Gate"
log "Security gate passed."

# ── Stage 5: CODE REVIEW ────────────────────────────────────────────────

log "--- Stage 5: Code Review ---"

REVIEW_INPUT="# Full Diff (${REPO})
\`\`\`diff
${DIFF}
\`\`\`

# Triage
\`\`\`json
$(cat "${META_DIR}/triage.json")
\`\`\`

# Security Report
\`\`\`json
$(cat "${META_DIR}/security-report.json")
\`\`\`

Review this fix and produce review.json."

REVIEW_RESPONSE=$(invoke_agent "code-reviewer" "$REVIEW_INPUT")
extract_json "$REVIEW_RESPONSE" > "${META_DIR}/review.json"

CONFIDENCE=$(jq -r '.confidence_score' "${META_DIR}/review.json")
if (( $(echo "$CONFIDENCE < 0.5" | bc -l) )); then
  log "GATE FAILED at Code Review: confidence ${CONFIDENCE} < 0.5"
  gh issue edit "$ISSUE_ID" -R "$REPO" --add-label "ag-needs-human" --remove-label "ag-in-progress" 2>/dev/null || true
  gh issue comment "$ISSUE_ID" -R "$REPO" --body "⚠️ Anti Gravity pipeline halted at **Code Review**. Confidence: ${CONFIDENCE} (threshold: 0.5)." 2>/dev/null || true
  exit 1
fi
log "Code review complete. Confidence: ${CONFIDENCE}"

# ── Stage 6: PR ASSEMBLY ────────────────────────────────────────────────

log "--- Stage 6: PR Assembly ---"

PR_INPUT="# Pipeline Outputs for ${REPO} Issue #${ISSUE_ID}

## triage.json
\`\`\`json
$(cat "${META_DIR}/triage.json")
\`\`\`

## engineer.json
\`\`\`json
$(cat "${META_DIR}/engineer.json")
\`\`\`

## tests.json
\`\`\`json
$(cat "${META_DIR}/tests.json")
\`\`\`

## security-report.json
\`\`\`json
$(cat "${META_DIR}/security-report.json")
\`\`\`

## review.json
\`\`\`json
$(cat "${META_DIR}/review.json")
\`\`\`

## PR Template
\`\`\`
$(cat "${TEMPLATES_DIR}/pr-description.md")
\`\`\`

Generate the final PR description by filling in the template. Output ONLY the markdown."

PR_RESPONSE=$(invoke_agent "pr-assembler" "$PR_INPUT")
echo "$PR_RESPONSE" > "${META_DIR}/pr-description.md"

# Commit, push, and create PR on the TARGET repo
cd "$FORGE_DIR"
git add -A
git commit -m "fix: resolve issue #${ISSUE_ID}

$(jq -r '.problem_statement' "${META_DIR}/triage.json")

Generated by Anti Gravity Forge" || {
  log "Warning: Nothing to commit."
}

BRANCH_NAME="ag/issue-${ISSUE_ID}"
git push origin "$BRANCH_NAME" 2>/dev/null || git push --set-upstream origin "$BRANCH_NAME"

# Detect base branch of the target repo
BASE_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

gh pr create \
  -R "$REPO" \
  --base "$BASE_BRANCH" \
  --head "$BRANCH_NAME" \
  --title "🔧 fix: ${ISSUE_TITLE}" \
  --body-file "${META_DIR}/pr-description.md" \
  --draft \
  --label "ag-pr-ready" 2>/dev/null || {
  log "Warning: PR creation failed. Branch pushed for manual PR creation."
}

gh issue edit "$ISSUE_ID" -R "$REPO" --add-label "ag-pr-ready" --remove-label "ag-in-progress" 2>/dev/null || true
gh issue comment "$ISSUE_ID" -R "$REPO" --body "✅ Anti Gravity Forge has submitted a draft PR for review." 2>/dev/null || true

log "=== FORGE PIPELINE COMPLETE: ${REPO} Issue #${ISSUE_ID} ==="
echo ""
echo "✅ Pipeline complete for ${REPO} issue #${ISSUE_ID}"
echo "   Branch: ${BRANCH_NAME}"
echo "   Log:    ${LOG_FILE}"
