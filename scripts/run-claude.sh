#!/bin/bash
# Factory build worker: delegates ALL implementation to Claude Code.
#
# Usage: run-claude.sh <repo-dir> <number> <branch-name> <mode>
#   mode: "issue"    — Two-phase in one go: Opus plans (.plan.md) → Sonnet implements
#         "pr-fix"   — fix CI failures or review comments on an existing PR
#         "implement" — Phase 2 only: Sonnet implements from existing .plan.md
#
# Exit codes:
#   0 — success (committed and pushed)
#   1 — fatal error
#   2 — Claude Code ran but made no changes
set -euo pipefail

if [ $# -lt 4 ]; then
  echo "Usage: run-claude.sh <repo-dir> <number> <branch-name> <mode>" >&2
  exit 1
fi

REPO_DIR="$1"
NUMBER="$2"
BRANCH="$3"
MODE="$4"

if [ ! -d "$REPO_DIR" ]; then
  echo "ERROR: repo directory does not exist: $REPO_DIR" >&2
  exit 1
fi

if ! command -v claude &>/dev/null; then
  echo "ERROR: claude CLI not found in PATH" >&2
  exit 1
fi

cd "$REPO_DIR"

# ── Clean working tree ───────────────────────────────────────────
git reset --hard HEAD 2>/dev/null || true
git clean -fd 2>/dev/null || true

# ── Git setup ────────────────────────────────────────────────────
git fetch origin

DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | grep 'HEAD branch' | awk '{print $NF}')
DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"

if [ "$MODE" = "issue" ]; then
  git checkout -B "$BRANCH" "origin/$DEFAULT_BRANCH"
elif [ "$MODE" = "implement" ] || [ "$MODE" = "pr-fix" ]; then
  git checkout "$BRANCH"
  git pull origin "$BRANCH" 2>/dev/null || true
else
  echo "ERROR: unknown mode '$MODE'" >&2
  exit 1
fi

# ── Helper: run claude with model ────────────────────────────────
run_claude() {
  local prompt="$1"
  local model="$2"
  local label="$3"

  echo ">>> [$label] model=$model number=$NUMBER branch=$BRANCH"

  local prompt_file=$(mktemp)
  printf '%s' "$prompt" > "$prompt_file"

  local wrapper=$(mktemp /tmp/claude-wrapper-XXXXXX.js)
  cat > "$wrapper" << 'JSEOF'
const { execFileSync } = require('child_process');
const fs = require('fs');
const promptFile = process.argv[2];
const repoDir = process.argv[3];
const model = process.argv[4] || 'opus';
const prompt = fs.readFileSync(promptFile, 'utf8');
try {
  const out = execFileSync('claude', [
    '-p', prompt,
    '--model', model,
    '--allowedTools', 'Bash,Read,Write,Edit,Glob,Grep',
    '--output-format', 'text'
  ], {
    timeout: 1200000,
    env: { ...process.env, CI: '1' },
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe'],
    maxBuffer: 50 * 1024 * 1024,
    cwd: repoDir
  });
  process.stdout.write(out);
} catch(e) {
  if (e.stdout) process.stdout.write(e.stdout);
  if (e.stderr) process.stderr.write(e.stderr);
  process.exit(e.status || 1);
}
JSEOF

  local output
  output=$(CI=1 node "$wrapper" "$prompt_file" "$REPO_DIR" "$model" 2>&1) || true
  rm -f "$prompt_file" "$wrapper"
  echo "$output"
}

# ── Build prompts ────────────────────────────────────────────────
PLAN_PROMPT="You are planning issue #$NUMBER on branch $BRANCH.

Your job is to create a detailed implementation plan — you do NOT write any code.

1. **Context** — Read CLAUDE.md if it exists. Run: gh issue view $NUMBER --json title,body to get the spec. Read referenced issues/PRs if any. Read ALL relevant source files to understand the codebase.
2. **Analyze** — Understand the full scope. Identify every file that needs changes. Trace through the code to understand dependencies and side effects.
3. **Write plan** — Create a file called .plan.md in the repo root with this structure:

# Plan: <issue title>

## Issue
#$NUMBER — <one-line summary>

## Analysis
<What you found reading the codebase. Key files, how things work currently, what's broken/missing.>

## Changes

### <filename.js> (modify)
- <Specific change 1: what to add/remove/modify and why>
- <Specific change 2>
- <Include line numbers or function names where possible>

### <newfile.js> (create)
- <Purpose of the file>
- <Key functions/exports it needs>
- <How it integrates with existing code>

### <file-to-delete.js> (delete)
- <Why this file is no longer needed>

## Order of Operations
1. <First thing to do>
2. <Second thing>
3. <etc — implementation order matters>

## Testing
- <How to verify each change>
- <Edge cases to watch for>

## Risks
- <Anything tricky or likely to break>

4. **Commit** — git add .plan.md && git commit -m 'plan: <issue title>'
5. **Push** — git push origin HEAD --force-with-lease
6. **Open draft PR** — gh pr create --draft --title '<issue title>' --body 'Closes #$NUMBER' --head $BRANCH
7. **Update PR body** — Include the acceptance criteria from the issue as a checklist (all unchecked).

Do NOT write any implementation code. Only .plan.md. Print a short summary of what you planned."

IMPLEMENT_PROMPT="You are implementing issue #$NUMBER on branch $BRANCH.

A detailed implementation plan exists in .plan.md at the repo root. Follow it precisely.

1. **Read the plan** — Read .plan.md carefully. This is your spec. Follow the order of operations.
2. **Read CLAUDE.md** if it exists for repo conventions.
3. **Implement** — Make every change described in the plan. Follow existing code style. If the plan says to modify a file, read it first, then make the described changes. If the plan says to create a file, create it with the described contents.
4. **Test** — Run the test and type-check commands from FACTORY.md. Keep fixing until ALL pass. Do not give up. If a test fails and the fix isn't in the plan, use your judgment.
5. **Clean up** — Delete .plan.md from the repo. Update any docs (README, CHANGELOG, etc.) if the changes warrant it.
6. **Commit** — git add -A && git commit -m 'feat: <descriptive message>'
7. **Push** — git push origin HEAD --force-with-lease
8. **Update PR body** — Read the issue's acceptance criteria. Check off ONLY the criteria you actually completed. Leave unchecked items as [ ]. Use: gh pr edit <pr-number> --body '<updated body>'
9. **If ALL acceptance criteria are met and ALL tests pass** — mark ready: gh pr ready <pr-number>. If not, leave as draft — the next cycle will continue the work.

Print a short summary: what you completed, what's left (if anything)."

PRFIX_PROMPT="You are fixing PR #$NUMBER on branch $BRANCH.

1. **Context** — Read CLAUDE.md if it exists. Run: gh pr view $NUMBER --json title,body,url to get the PR spec. Run: gh api repos/{owner}/{repo}/pulls/$NUMBER/comments --jq '.[].body' for review comments. Read the linked issue for acceptance criteria.
2. **Read .plan.md** if it exists for additional context on what was intended.
3. **Plan** — Understand what's failing or what reviewers requested.
4. **Build** — Fix the issues following existing code style.
5. **Test** — Run the test and type-check commands from FACTORY.md. Keep fixing until ALL pass. Do not give up.
6. **Clean up** — If .plan.md still exists and all work is done, delete it.
7. **Commit** — git add -A && git commit -m 'fix: <descriptive message>'
8. **Push** — git push origin HEAD --force-with-lease
9. **Update PR body** — Update the checklist, checking off ONLY criteria you actually completed. Leave unchecked items as [ ]. Use: gh pr edit $NUMBER --body '<updated body>'
10. **If ALL acceptance criteria are met and ALL tests pass** — mark ready: gh pr ready $NUMBER. If not, leave as draft.

Print a short summary: what you fixed, what's left (if anything)."

# ── Check Claude Code budget ─────────────────────────────────────
BUDGET_SCRIPT=$(mktemp /tmp/claude-budget-XXXXXX.js)
cat > "$BUDGET_SCRIPT" << 'JSEOF'
const { execSync } = require('child_process');
try {
  execSync('claude -p "reply with OK" --model opus --output-format text', {
    timeout: 30000,
    env: { ...process.env, ANTHROPIC_LOG: 'debug' },
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe']
  });
  process.exit(0);
} catch(e) {
  const stderr = e.stderr || '';
  if (stderr.includes('rate') || stderr.includes('429') || stderr.includes('overloaded')) {
    console.error('RATE_LIMITED');
    process.exit(1);
  }
  process.exit(0);
}
JSEOF

BUDGET_CHECK=$(CI=1 timeout 30 node "$BUDGET_SCRIPT" 2>&1) || true
rm -f "$BUDGET_SCRIPT"

if echo "$BUDGET_CHECK" | grep -q "RATE_LIMITED"; then
  echo "ERROR: Rate limited — skipping this cycle" >&2
  exit 2
fi

# ── Execute ──────────────────────────────────────────────────────

if [ "$MODE" = "issue" ]; then
  # Phase 1: Opus plans
  run_claude "$PLAN_PROMPT" "opus" "Phase 1: Plan"

  echo ""
  echo "=== Phase 1 complete. Starting Phase 2: Implementation ==="
  echo ""

  # Phase 2: Sonnet implements
  run_claude "$IMPLEMENT_PROMPT" "sonnet" "Phase 2: Implement"

elif [ "$MODE" = "implement" ]; then
  run_claude "$IMPLEMENT_PROMPT" "sonnet" "Phase 2: Implement"

elif [ "$MODE" = "pr-fix" ]; then
  run_claude "$PRFIX_PROMPT" "sonnet" "PR Fix"
fi

echo ""
echo "CLAUDE_CODE_DONE"
