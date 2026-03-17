# Mission: Auto-Fix

## Trigger
- GitHub issues with the `ag-fix` label
- Issue comments starting with `/ag`

## Pipeline Stages

1. **Triager** — Classify, scope, and plan the fix
2. **Engineer** — Implement the code changes
3. **Test Writer** — Write/update tests for the fix
4. **Security Gate** — SAST + dependency audit + secrets scan
5. **Code Reviewer** — Style, correctness, and convention check
6. **PR Assembler** — Create a draft PR with structured description

## Gating Rules

| Stage | Pass Condition | Fail Action |
|-------|---------------|-------------|
| Triager | `actionable == true` | Comment asking for clarification, label `ag-needs-human` |
| Engineer | `build_passes && lint_passes` | Retry once, then halt |
| Test Writer | `all_tests_pass` | Send back to Engineer (max 2 retries), then halt |
| Security Gate | `overall_passed == true` | Halt on critical/high, warn on medium |
| Code Reviewer | `confidence_score >= 0.5` | Halt if < 0.5, flag concerns if 0.5–0.8 |
| PR Assembler | PR created | — |

## /ag Command Syntax

```
/ag fix               — Full auto-fix pipeline
/ag fix --scope src/  — Limit scope to directory
/ag triage            — Run triager only
/ag review            — Run code reviewer on current PR
/ag security          — Run security gate on current PR
/ag status            — Report pipeline status
```
