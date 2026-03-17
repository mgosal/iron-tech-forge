# 🔧 Anti Gravity Forge

An AI-powered auto-fix pipeline that monitors GitHub for issues, fixes them through a chain of specialized agents, and submits hardened draft PRs for human review.

## How It Works

1. **Mission Runner** polls your configured GitHub repos for issues labeled `ag-fix`
2. For each issue, it creates an isolated **Forge** (cloned workspace) in `.forge/`
3. Six agents run sequentially via Claude Opus (OpenRouter):

| Stage | Agent | Purpose |
|-------|-------|---------|
| 1 | **Triager** | Classify, scope, and plan the fix |
| 2 | **Engineer** | Implement the code changes |
| 3 | **Test Writer** | Write regression tests |
| 4 | **Security Gate** | SAST, dependency audit, secrets scan |
| 5 | **Code Reviewer** | Correctness and convention review |
| 6 | **PR Assembler** | Create structured draft PR |

Every stage is **gated** — failures halt the pipeline and notify humans.

## Quick Start

```bash
# 1. Set your API key
export OPENROUTER_API_KEY="sk-or-..."

# 2. Configure repos to watch
vim .antigravity/config.yml

# 3. Start the daemon
./scripts/start-mission.sh

# 4. Create an issue on any watched repo with label "ag-fix"
# The forge will pick it up on the next poll cycle.
```

## Multi-Repo Support

Configure which repos to watch in `.antigravity/config.yml`:

```yaml
repos:
  - name: "mgosal/anti-gravity-forge"   # specific repo
  - name: "mgosal/CoS"                  # another repo
  - name: "mgosal/*"                    # wildcard: ALL repos
```

Each forge is isolated: `.forge/<owner>-<repo>/issue-<id>/`

## Manual Run

```bash
# Fix a specific issue without the daemon
./scripts/forge-create.sh mgosal/CoS 42
./scripts/run-pipeline.sh mgosal/CoS 42

# Clean up after merge
./scripts/forge-cleanup.sh mgosal/CoS 42
```

## Project Structure

```
.agents/          — Agent personas and rules
.antigravity/     — Pipeline config, mission def, templates
scripts/          — Shell scripts (daemon, forge lifecycle, pipeline)
.forge/           — Runtime: cloned repos per issue (gitignored)
```

## Labels

| Label | Meaning |
|-------|---------|
| `ag-fix` | Trigger: issue needs automated fix |
| `ag-in-progress` | Pipeline is working on it |
| `ag-pr-ready` | Draft PR submitted |
| `ag-needs-human` | Pipeline halted, needs manual intervention |

---

*PRs are always draft. Humans are the final gate.*
