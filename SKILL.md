---
name: gh-dev-factory
description: "Autonomous development factory using GitHub Issues/PRs as a work loop. Two cron jobs: factory-scan (orchestration, never codes) and factory-build (delegates to Claude Code, never codes directly). Also supports manual triggers. Requires gh CLI authenticated."
license: MIT
metadata:
  {"openclaw":{"emoji":"🏭","requires":{"bins":["gh","git","claude"]},"install":[{"id":"brew","kind":"brew","formula":"gh","bins":["gh"],"label":"Install GitHub CLI (brew)"}]}}
---

# gh-dev-factory

Autonomous dev loop driven by two cron jobs with strict separation of concerns. One scans and orchestrates. The other builds by delegating to Claude Code. Neither ever writes code directly in its own session.

## Architecture: Two Jobs, Hard Boundary

The factory is split into two cron jobs because a single-job design fails: the orchestrator model (Sonnet) ignores delegation instructions and implements code changes directly using its own tools. The fix is architectural — make it physically impossible.

### factory-scan (orchestrator)

**Runs every 20 minutes.** Scans GitHub for work, writes plans on issues, reviews PRs, merges approved PRs, manages labels and deploys. This job is the brain.

**NEVER writes code. NEVER creates branches. NEVER opens PRs. NEVER runs Claude Code.** If scan finds work that requires implementation, it ensures the issue is labeled `planned` and stops. The build job picks it up next.

What scan DOES do:
- Run `scan.py` to rank the work queue
- Comment implementation plans on unplanned issues, add `planned` label
- Review PRs for correctness (approve / request changes)
- Merge approved PRs using configured strategy
- Verify CI status, comment deploy URLs
- Update `factory-state.md`
- Respond `HEARTBEAT_OK` when idle or done

### factory-build (implementer)

**Runs every 20 minutes, offset by 10 minutes from scan.** Its ONLY job is to find the highest-priority item that needs code and delegate to Claude Code via `run-claude.sh`.

**NEVER writes code directly. NEVER uses Edit/Write tools on repo files.** It reads the scan output, picks one item, then runs `run-claude.sh` as a subprocess. Claude Code (the subprocess) does all implementation. The build job monitors exit status, pushes the branch, opens/updates the PR, and stops.

What build DOES do:
- Run `scan.py` to find work needing implementation
- For a `planned` issue: run `run-claude.sh <repo> <number> <branch> issue`
- For a `draft` PR or `changes_requested` PR: run `run-claude.sh <repo> <number> <branch> pr-fix`
- Push the branch, open or update the PR
- Update `factory-state.md`
- Respond `HEARTBEAT_OK` when idle or done

### Why Two Jobs?

| Concern | factory-scan | factory-build |
|---------|-------------|---------------|
| Model | sonnet (cheap) | sonnet (orchestrates Claude Code) |
| Writes code? | NEVER | NEVER (delegates to Claude Code) |
| Runs Claude Code? | NEVER | YES, via run-claude.sh |
| Creates branches/PRs? | NO | YES (after Claude Code finishes) |
| Reviews PRs? | YES | NO |
| Merges PRs? | YES | NO |
| Plans issues? | YES | NO |

## Cron Setup

```bash
# SCAN: orchestration, planning, review, merge, deploy
openclaw cron add \
  --name "factory-scan" \
  --every "20m" \
  --tz "America/New_York" \
  --session isolated \
  --message "<see SCAN PROMPT below>" \
  --model sonnet \
  --announce

# BUILD: delegates implementation to Claude Code subprocess
openclaw cron add \
  --name "factory-build" \
  --every "20m" \
  --offset "10m" \
  --tz "America/New_York" \
  --session isolated \
  --message "<see BUILD PROMPT below>" \
  --model sonnet \
  --announce
```

## Manual Mode

- `factory scan` — run scan only (read-only, reports queue)
- `factory build` — run build only (picks one item, delegates to Claude Code)
- `factory run` — run scan then build in sequence
- `factory init` — interactive setup
- `factory new owner/repo` — scaffold new repo
- `factory release` — tag + changelog + GitHub Release
- `factory deploy` — deploy to production
- `factory status` — budget, queue, schedule report

## Budget Awareness

Every run burns tokens. FACTORY.md declares billing model and limits.

```
## Budget
- Billing: subscription  # or "api"
- Max cycles per day: 10
- Max open PRs: 2
- Scan model: sonnet
- Act model: sonnet  # Claude Code uses this for implementation
```

### State Persistence

```markdown
<!-- {workspace}/memory/factory-state.md -->
# Factory State
- **Date:** 2026-02-07
- **Cycles today:** 3
- **Last cycle:** 14:30 UTC — PR #42, pushed review fixes
- **Open PRs:** 2
- **Queue depth:** 5
```

On each run:
1. Read factory-state.md
2. If date changed, reset cycles to 0
3. If cycles_today >= max, respond "budget exhausted" and stop (HEARTBEAT_OK)
4. If open_prs >= max, only work on existing PRs
5. Run one action, update state file

## The Scan Cycle (factory-scan job)

Run `python3 {baseDir}/scripts/scan.py {repo}` to get the ranked queue.

If empty: respond `HEARTBEAT_OK`. Stop.

Otherwise, take the first item and do ONE of these (in priority order):

### PR — changes_requested
Read review comments. DO NOT fix the code. That is the build job's responsibility. Stop. (Build job will pick this up.)

### PR — approved
Merge using configured strategy. Verify linked issue closed. Update state file. Stop.

### PR — needs_review
Review for correctness, tests, rule adherence. Never approve a PR you authored. Request changes or approve. Stop.

### PR — draft
Check CI status. If CI is failing, stop — build job will fix it. If CI is green and all checklist items are checked, mark ready for review. Stop.

### Issue — needs_plan
Read the issue. Comment implementation plan: approach, files, test strategy. Add `planned` label. Stop.

### Issue — planned (no PR yet)
Stop. This is the build job's responsibility.

**Scan never creates branches, never writes code, never opens PRs.** If the highest-priority item needs implementation, scan skips it for the build job.

## The Build Cycle (factory-build job)

Run `python3 {baseDir}/scripts/scan.py {repo}` to get the ranked queue.

If empty: respond `HEARTBEAT_OK`. Stop.

Otherwise, find the first item that needs implementation:

### Issue — planned (no PR yet)
If open_prs >= max_open_prs, skip. Otherwise:
1. Determine branch name: `factory/{number}-{slug}`
2. Run: `bash {baseDir}/scripts/run-claude.sh <repo-dir> <number> <branch> issue`
3. If Claude Code exits 0: push branch, open draft PR with `Closes #{number}`
4. Update state file. Stop.

### PR — draft (CI failing)
1. Run: `bash {baseDir}/scripts/run-claude.sh <repo-dir> <number> <branch> pr-fix`
2. If Claude Code exits 0: push the branch
3. Update state file. Stop.

### PR — changes_requested
1. Run: `bash {baseDir}/scripts/run-claude.sh <repo-dir> <number> <branch> pr-fix`
2. If Claude Code exits 0: push the branch
3. Update state file. Stop.

If no item needs implementation: respond `HEARTBEAT_OK`. Stop.

**Build never reviews PRs, never merges, never plans issues, never writes code directly.** It ONLY delegates to Claude Code via run-claude.sh.

## Rules

- **One item per cycle.** Do not chain actions.
- **Hard role separation.** Scan never codes. Build never reviews/merges/plans.
- **Build never writes code directly.** All implementation goes through run-claude.sh → Claude Code subprocess.
- **Never self-approve.** If you authored it, you cannot approve it.
- **Small PRs.** If too large, break into sub-issues first.
- **FACTORY.md is law.** Follow its rules, boundaries, and checkpoints.
- **CLAUDE.md is context.** Follow its code style and conventions.
- **Respect human checkpoints.** Never auto-merge if config says no.
- **Releases are deliberate.** Never auto-tag or auto-release.
- **Respect the budget.** Never exceed cycle limits. When exhausted, stop.
- **Cheap when idle.** Minimal response when nothing to do.
- **PR body is truth.** If a PR has unchecked items, the work is not done.

## Scan Output Format

scan.py returns JSON sorted by priority:

```json
[{"type": "issue|pr", "number": 42, "title": "...", "state": "...", "priority": 1}]
```

States: needs_plan, planned, draft, needs_review, changes_requested, approved.

Priority: changes_requested > approved > needs_review > draft > planned > needs_plan.

Finish in-progress work before starting new work.
