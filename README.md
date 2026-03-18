# Iron Tech Forge

An experimental auto-fix pipeline that monitors GitHub for issues, attempts to resolve them through a chain of specialized agents, and submits draft PRs for human review.

> [!NOTE]
> This project is **platform-independent** and has zero dependencies on any specific AI platform. It was built *on* and *with* Anti-Gravity, but operates as a standalone Unix-native tool.

Fixes are built in an isolated **Forge** — a dedicated cloned workspace per issue — where agents process the code sequentially before any code reaches a PR.

---

## Architecture

Iron Tech Forge is a **zero-dependency, Unix-native agent framework**. Unlike modern "heavy" frameworks (LangChain, CrewAI), it relies entirely on standard Bash scripts, `curl`, and `jq` to orchestrate multi-agent workflows.

### Why Bash?
- **Zero-Dependency**: No `npm install`, no `pip install`. If you have `bash`, `curl`, and `jq`, you have a forge.
- **Transparent**: Every prompt and response is a discrete file in `.forge-meta/`. No hidden internal logic or complex abstractions.
- **Composable**: Easily wraps existing CLI tools (like `gh`, `git`, or `docker`) without specialized "integrations."

### Framework Comparison

| Feature | Iron Tech Forge | Devin / OpenHands | LangChain / CrewAI |
|---------|---------------------|-------------------|-------------------|
| **Language** | Bash / Unix Shell | Python / JS | Python / JS |
| **Logic** | Linear Assembly Line | Re-entrant Loops | Graph / Sequential |
| **Sandbox** | `git clone` (Shallow) | Docker / VM | Local / Varied |
| **Primary Tool** | `curl` + `jq` | Persistent OS Shell | Library-specific SDKs |
| **Complexity** | Minimalist | High | High |

---

## High-Level Flow

```
GitHub Issue (forge-fix label or /forge command)
        │
        ▼
┌─────────────────┐
│     IronTech     │  Polling daemon (start-irontech.sh)
└────────┬────────┘
         │  Polls configured repos every N seconds
         ▼
┌─────────────────┐
│   Issue Triager  │  Agent 1: classify, scope, plan
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│    Forge Setup   │  Clone target repo → .forge/<owner>-<repo>/issue-<id>/
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│    Engineer      │  Agent 2: implement the fix
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   Test Writer    │  Agent 3: write/update tests
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Security Gate   │  Agent 4: SAST + dependency audit + secrets scan
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Code Reviewer   │  Agent 5: style, correctness, conventions
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   PR Assembler   │  Agent 6: create PR with structured description
└────────┬────────┘
         │
         ▼
  GitHub PR (draft, assigned to human reviewer)
```

### Runtime Environment

- **Phase 1 (current):** Local machine, invoked manually via `start-irontech.sh`
- **Phase 2 (planned):** Dedicated VPS with systemd service, webhook-triggered instead of polling
- **AI backbone:** Claude Opus via [OpenRouter](https://openrouter.ai) API
- **Workspace isolation:** Cloned repos in `.forge/` directory, namespaced by `<owner>-<repo>`

### Multi-Repo Design

Iron Tech Forge is **repo-agnostic**. It runs as a standalone service and operates on any repo — including itself.

```
~/code/iron-tech-forge/                  ← the tool itself (this repo)
├── .agents/                             ← agent brains (shared across all repos)
├── .forge-master/config.yml             ← which repos to watch
├── scripts/                             ← pipeline scripts
└── .forge/                              ← runtime workspaces (gitignored)
    ├── mgosal-iron-tech-forge/          ← forges for THIS repo (self-referential)
    │   └── issue-1/
    ├── mgosal-CoS/                      ← forges for another repo
    │   └── issue-42/
    └── mgosal-some-project/
        └── issue-7/
```

Agent rules live in `.agents/` and are **never mixed** with target repo code. The forge clones each target repo fresh, so there's zero cross-contamination between projects.

---

## Quick Start

```bash
# 1. Set your OpenRouter API key in .env.local
echo "OPENROUTER_API_KEY=sk-or-..." >> .env.local

# 2. Configure which repos to watch
vim .forge-master/config.yml

# 3. Start the IronTech daemon
./scripts/start-irontech.sh

# 4. Create an issue on any watched repo with label "forge-fix"
#    The forge will pick it up on the next poll cycle.
```

### Manual Run (Single Issue)

```bash
# Fix a specific issue without the daemon
./scripts/forge-create.sh mgosal/CoS 42
./scripts/run-pipeline.sh mgosal/CoS 42

# Clean up after PR is merged
./scripts/forge-cleanup.sh mgosal/CoS 42

# Clean up ALL forges
./scripts/forge-cleanup.sh --all
```

---

## Configuration

**File:** `.forge-master/config.yml`

```yaml
mission:
  poll_interval: 60          # seconds between GitHub polls
  max_concurrent_forges: 3   # parallel issue limit across ALL repos
  bot:
    name: "ForgeMaster"
    email: "bot@example.com"

repos:
  - name: "mgosal/iron-tech-forge"      # specific repo
  - name: "mgosal/CoS"                  # another specific repo

labels:
  trigger: "forge-fix"
  in_progress: "forge-in-progress"
  pr_ready: "forge-pr-ready"
  needs_human: "forge-needs-human"

forge:
  base_dir: ".forge"
  base_branch: "main"
  branch_prefix: "forge/issue-"
  cleanup_after_merge: true

agents:
  model: "anthropic/claude-opus"   # via OpenRouter
  provider: "openrouter"
  max_tokens: 8192
  temperature: 0
```

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OPENROUTER_API_KEY` | Yes | OpenRouter API key for Claude Opus |
| `AG_BOT_EMAIL` | No | Secret email override for Git commits |
| `AG_POLL_INTERVAL` | No | Override poll interval (default: 60s) |
| `AG_MAX_FORGES` | No | Override max concurrent forges (default: 3) |

### GitHub Labels

| Label | Meaning |
|-------|---------|
| `forge-fix` | **Trigger:** issue needs automated fix |
| `forge-in-progress` | Pipeline is actively working on it |
| `forge-pr-ready` | Draft PR has been submitted |
| `forge-needs-human` | Pipeline halted — manual intervention required |

---

## Pipeline Stages — Detailed Specifications

### Stage 1: Issue Triager

**Agent file:** `.agents/rules/triager.md`

**Input:** Raw GitHub issue (title, body, labels, comments)

**Responsibilities:**
1. Parse the issue to extract the actual problem
2. Classify severity: `trivial` | `standard` | `complex`
3. Identify likely affected files/modules
4. Produce a scoped implementation plan

**Output contract:** `.forge-meta/triage.json`

---

### Stage 2: Engineer

**Agent file:** `.agents/rules/engineer.md`

**Responsibilities:**
1. Read the implementation plan from triage
2. Implement the fix following existing code style
3. Ensure the code compiles/passes linting

---

### Stage 3: Test Writer

**Agent file:** `.agents/rules/test-writer.md`

**Responsibilities:**
1. Write tests that cover the specific fix
2. Run the test suite to verify

---

### Stage 4: Security Gate

**Agent file:** `.agents/rules/security-gate.md`

**Sub-checks:** SAST + Dependency Audit + Secrets Scan

---

### Stage 5: Code Reviewer

**Agent file:** `.agents/rules/code-reviewer.md`

**Responsibilities:**
1. Review code changes for correctness and maintainability

---

### Stage 6: PR Assembler

**Agent file:** `.agents/rules/pr-assembler.md`

**Responsibilities:**
1. Fill in the PR description template
2. **Auto-Close Logic**: Includes "Closes #ID" to automatically resolve issues upon merge.

---

## Forge Lifecycle

Each issue gets its own cloned workspace — a **Forge**.

```
1. forge:create  →  gh repo clone <target> .forge/<slug>/issue-<id>/
                     git checkout -b forge/issue-<id>
2. agents work   →  inside the cloned workspace
3. forge:submit  →  git push, gh pr create (draft)
4. forge:cleanup →  rm -rf the forge dir
```

---

## Project Structure

```
iron-tech-forge/
├── .forge-master/
│   ├── config.yml                     # Pipeline configuration
│   ├── missions/
│   │   └── auto-fix.md                # Mission definition
│   └── templates/
│       └── pr-description.md          # PR body template
├── .agents/
│   ├── rules/                         # Agent "brains"
│   └── shared/                        # Shared conventions
├── scripts/
│   ├── start-irontech.sh              # Polling daemon
│   ├── forge-create.sh                # Setup forge
│   ├── run-pipeline.sh                # Main orchestration
│   └── forge-cleanup.sh               # Cleanup script
├── .forge/                            # Runtime workspaces (gitignored)
├── .gitignore
└── README.md
```

---

## Design Principles

1. **Every stage is gated.** No stage runs until the prior gate passes.
2. **Every action is logged.** `.forge-meta/pipeline.log` is the source of truth.
3. **Humans are the final gate.** PRs are always draft. No auto-merge.

---

## Roadmap

### Phase 1 — Core Pipeline ✅ (Built)
- [x] IronTech (polling daemon)
- [x] Forge lifecycle (create/cleanup)
- [x] Zero-dependency Unix-native architecture
- [x] Auto-closing issue logic

### Phase 2 — Operational Hardening (Current / Planned)
- [ ] **Dockerization**: Containerize for one-click deployment.
- [ ] **Re-entrant Engineering**: Terminal-looping for self-healing fixes.
- [ ] **Webhook Triggering**: Move to real-time events.

---

## Current Deficiencies & Limitations

1. **Linear Logic**: Agents cannot "re-try" a fix if a test fails (yet).
2. **Polling Latency**: Daemon-based polling instead of Webhooks.
3. **Hardware Bound**: Designed for single-machine use.

*PRs are always draft. Human review is required before merging.*
