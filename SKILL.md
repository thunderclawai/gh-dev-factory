---
name: gh-dev-factory
description: "Autonomous development factory using GitHub Issues/PRs as a work loop. Single cron job scans for work, plans issues, delegates code to Claude Code, and auto-merges PRs. Requires gh CLI authenticated and Claude Code installed."
license: MIT
metadata:
  {"openclaw":{"emoji":"🏭","requires":{"bins":["gh","git","claude"]},"install":[{"id":"brew","kind":"brew","formula":"gh","bins":["gh"],"label":"Install GitHub CLI (brew)"}]}}
---

# gh-dev-factory

Autonomous dev loop driven by a single cron job. Scans GitHub for work, plans issues, delegates implementation to Claude Code, and auto-merges PRs. GitHub is the source of truth — no state files needed.

## How It Works

One cron job runs every 30 minutes. Each cycle:

1. **Scan** — Run `scan.py` to rank open issues and PRs by priority
2. **Cheap actions first** — Merge ready PRs, plan unplanned issues, add labels
3. **One expensive action** — Delegate one implementation task to Claude Code via `run-claude.sh`
4. **Auto-merge** — If Claude Code produces a passing PR, merge it in the same cycle

The job never writes code directly. All implementation goes through `run-claude.sh` → Claude Code subprocess.

## Architecture

### Single Job Design

Earlier versions split scan and build into two jobs. In practice, a single combined job works better:
- Plan + build + merge can happen in one 30-min cycle
- No coordination overhead between jobs
- Simpler to reason about and debug
- GitHub is the only state — no factory-state.md files to manage

### scan.py

`scripts/scan.py` scans a repo and outputs a ranked JSON queue:

```json
[{"type": "issue", "number": 42, "title": "...", "state": "needs_plan", "priority": 1}]
```

Priority order: `changes_requested` > `approved` > `needs_review` > `draft` > `planned` > `needs_plan`

It also **auto-updates epic checklists** — any issue labeled `epic` gets its checkbox list synced with actual issue states (closed → checked, new issues → appended).

Issues labeled `blocked` or `epic` are skipped from the work queue.

### run-claude.sh

`scripts/run-claude.sh` delegates implementation to Claude Code:

```bash
bash scripts/run-claude.sh <repo-dir> <number> <branch> <mode>
```

Modes:
- `issue` — Implement a planned issue from scratch
- `pr-fix` — Fix a failing PR or address review comments

Claude Code reads the issue/PR, writes the code, and commits. The calling job handles branch push, PR creation, and merge.

## Setup

### 1. Add FACTORY.md to your repo

Create `FACTORY.md` in the repo root. This is the factory's configuration:

```markdown
# FACTORY.md

## Project
- **Repo:** owner/repo
- **Stack:** Your tech stack
- **Description:** What this project does

## Test & Lint
- **Test command:** npm test (or python3 build.py, etc.)
- **Lint command:** none

## Merge Strategy
- Squash merge
- Delete branch after merge

## Branch Naming
- `factory/<issue-number>-<short-slug>`

## Boundaries (do not touch)
- `.github/`
- `FACTORY.md`

## Labels
- `planned` — has implementation plan, ready to build
- `blocked` — skip during factory scan
- `epic` — tracking issue, skip

## Human Checkpoints
- Auto-merge when tests pass
- No human review required

## Budget
- Max open PRs: 2
```

### 2. Create the cron job

Single job that handles everything:

```bash
openclaw cron add \
  --name "factory-myproject" \
  --cron "15,45 * * * *" \
  --tz "Europe/Sofia" \
  --session isolated \
  --model sonnet \
  --announce \
  --message "<see CRON PROMPT below>"
```

### 3. Cron Prompt Template

```
You are the factory for {owner}/{repo}. One scan per cycle, do everything you can.

## Step 1: Scan
python3 {baseDir}/scripts/scan.py {owner}/{repo}
gh pr list --repo {owner}/{repo} --state open --json number,isDraft | jq length

## Step 2: Do all cheap actions first

**Merge ready PRs (non-draft):**
gh pr merge <number> --repo {owner}/{repo} --squash --delete-branch

**Do NOT merge draft PRs** — drafts mean incomplete work.

## Step 3: ONE expensive action (if any)

**Draft PR or changes_requested PR:**
Delegate to Claude Code:
bash {baseDir}/scripts/run-claude.sh {repoDir} <number> <branch> pr-fix
Run with pty:true, background:true, timeout:900.
Poll with process action:poll every 60 seconds. When done, read final logs.

**Issue — needs_plan:**
Read the issue. Comment implementation plan. Add `planned` label.
Then if open PRs < {maxOpenPRs}, immediately continue to build it.

**Issue — planned (no PR yet):**
If open PRs >= {maxOpenPRs}, STOP.
Delegate to Claude Code:
bash {baseDir}/scripts/run-claude.sh {repoDir} <number> factory/<number>-<slug> issue
Run with pty:true, background:true, timeout:900.
Poll with process action:poll every 60 seconds. When done, read final logs.

## Step 4: After Claude Code finishes
Check if PR was marked ready (non-draft). If so:
gh pr merge <number> --repo {owner}/{repo} --squash --delete-branch

## Step 5: Nothing to do?
Respond HEARTBEAT_OK. Do NOT send any notifications.

## Hard rules
- Do ALL cheap actions before expensive ones
- ONE expensive action per cycle
- NEVER write code directly. All implementation via run-claude.sh.
- NEVER use Edit or Write tools on repo files.
- Auto-merge ready PRs. No review step.
- Max {maxOpenPRs} open PRs.
- GitHub is source of truth.
- Poll Claude Code every 60 seconds, not more frequent.
- If Claude Code is already running (check process list), HEARTBEAT_OK.
- Keep responses short.
```

Replace:
- `{owner}/{repo}` — GitHub repo (e.g. `thunderclawai/thunderclawai.github.io`)
- `{baseDir}` — path to this skill (e.g. `~/.openclaw/workspace/skills/gh-dev-factory`)
- `{repoDir}` — local checkout path (e.g. `~/.openclaw/workspace/my-repo`)
- `{maxOpenPRs}` — from FACTORY.md budget (typically 2)

## The Cycle In Detail

### Priority Order

Each cycle processes ONE expensive action. Cheap actions (merging ready PRs, adding labels) are batched first.

1. **Merge ready PRs** — Non-draft PRs get squash-merged immediately
2. **Plan unplanned issues** — Comment implementation plan, add `planned` label
3. **Build planned issues** — Delegate to Claude Code, push PR
4. **Fix failing PRs** — Delegate fixes to Claude Code

### What Scan Does (cheap)
- Rank the work queue
- Auto-update epic checklists
- Plan issues (comment + label)

### What Build Does (expensive)
- Delegate to Claude Code via `run-claude.sh`
- Push branch, open/update PR
- Merge if ready

## Rules

- **One expensive action per cycle.** Cheap actions can batch.
- **Never write code directly.** All implementation via run-claude.sh → Claude Code.
- **FACTORY.md is law.** Follow its rules, boundaries, and checkpoints.
- **GitHub is source of truth.** No state files. Check issue/PR state each cycle.
- **Auto-merge when passing.** No human review unless FACTORY.md says otherwise.
- **Small PRs.** If too large, break into sub-issues.
- **Cheap when idle.** HEARTBEAT_OK when nothing to do.
- **PR body is truth.** Unchecked items = work not done.
- **Don't merge drafts.** Drafts mean Claude Code hasn't finished.

## Manual Mode

- `factory scan` — run scan only (reports queue)
- `factory build` — run build only (picks one item, delegates)
- `factory run` — scan then build in sequence
- `factory status` — show queue depth, open PRs, recent activity

## Scan Output Format

```json
[
  {"type": "issue", "number": 42, "title": "Add dark mode", "state": "planned", "priority": 1},
  {"type": "pr", "number": 43, "title": "feat: dark mode", "state": "needs_review", "priority": 2}
]
```

States: `needs_plan`, `planned`, `draft`, `needs_review`, `changes_requested`, `approved`

## Epic Auto-Update

`scan.py` automatically syncs epic checklists on every run:
- Marks closed issues as `[x]`
- Marks reopened issues as `[ ]`
- Appends new issues not yet in the checklist
- Only affects issues labeled `epic`

No manual epic maintenance needed.
