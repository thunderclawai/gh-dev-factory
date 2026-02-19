#!/bin/bash
# Factory build worker: delegates ALL implementation to Claude Code.
#
# Usage: run-claude.sh <repo-dir> <number> <branch-name> <mode>
#   mode: "issue"  — implement a planned issue from scratch
#         "pr-fix" — fix CI failures or review comments on an existing PR
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
elif [ "$MODE" = "pr-fix" ]; then
  git checkout "$BRANCH"
  git pull origin "$BRANCH" 2>/dev/null || true
else
  echo "ERROR: unknown mode '$MODE'" >&2
  exit 1
fi

# ── Build prompt ─────────────────────────────────────────────────
if [ "$MODE" = "issue" ]; then
  PROMPT="You are implementing issue #$NUMBER on branch $BRANCH. Your loop:

1. **Context** — Read CLAUDE.md if it exists. Run: gh issue view $NUMBER --json title,body to get the spec. Read referenced issues/PRs if any. Read relevant source files.
2. **Plan** — Understand what needs to change. List files to create/modify.
3. **Build** — Implement the changes following existing code style.
4. **Test** — Run the test and type-check commands from FACTORY.md. Keep fixing until ALL pass. Do not give up.
5. **Commit** — git add -A && git commit -m 'feat: <descriptive message>'
6. **Push** — git push origin HEAD --force-with-lease
7. **Open PR as draft** — gh pr create --draft --title '<issue title>' --body 'Closes #$NUMBER' --head $BRANCH
8. **Update PR body** — Read the issue's acceptance criteria. Build a checklist in the PR body. Check off ONLY the criteria you actually completed. Leave unchecked items as [ ]. Use: gh pr edit <pr-number> --body '<updated body>'
9. **If ALL acceptance criteria are met and ALL tests pass** — mark ready: gh pr ready <pr-number>. If not, leave as draft — the next cycle will continue the work.

Print a short summary: what you completed, what's left (if anything)."

elif [ "$MODE" = "pr-fix" ]; then
  PROMPT="You are fixing PR #$NUMBER on branch $BRANCH. Your loop:

1. **Context** — Read CLAUDE.md if it exists. Run: gh pr view $NUMBER --json title,body,url to get the PR spec. Run: gh api repos/{owner}/{repo}/pulls/$NUMBER/comments --jq '.[].body' for review comments. Read the linked issue for acceptance criteria.
2. **Plan** — Understand what's failing or what reviewers requested.
3. **Build** — Fix the issues following existing code style.
4. **Test** — Run the test and type-check commands from FACTORY.md. Keep fixing until ALL pass. Do not give up.
5. **Commit** — git add -A && git commit -m 'fix: <descriptive message>'
6. **Push** — git push origin HEAD --force-with-lease
7. **Update PR body** — Update the checklist, checking off ONLY criteria you actually completed. Leave unchecked items as [ ]. Use: gh pr edit $NUMBER --body '<updated body>'
8. **If ALL acceptance criteria are met and ALL tests pass** — mark ready: gh pr ready $NUMBER. If not, leave as draft.

Print a short summary: what you fixed, what's left (if anything)."
fi

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

# ── Run Claude Code ──────────────────────────────────────────────
echo ">>> run-claude.sh: mode=$MODE number=$NUMBER branch=$BRANCH"

PROMPT_FILE=$(mktemp)
printf '%s' "$PROMPT" > "$PROMPT_FILE"

WRAPPER_SCRIPT=$(mktemp /tmp/claude-wrapper-XXXXXX.js)
cat > "$WRAPPER_SCRIPT" << 'JSEOF'
const { execFileSync } = require('child_process');
const fs = require('fs');
const promptFile = process.argv[2];
const repoDir = process.argv[3];
const prompt = fs.readFileSync(promptFile, 'utf8');
try {
  const out = execFileSync('claude', [
    '-p', prompt,
    '--model', 'opus',
    '--allowedTools', 'Bash,Read,Write,Edit,Glob,Grep',
    '--output-format', 'text'
  ], {
    timeout: 900000,
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

OUTPUT=$(CI=1 node "$WRAPPER_SCRIPT" "$PROMPT_FILE" "$REPO_DIR" 2>&1) || true

rm -f "$PROMPT_FILE" "$WRAPPER_SCRIPT"
echo "$OUTPUT"

echo ""
echo "CLAUDE_CODE_DONE"
