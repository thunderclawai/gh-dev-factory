---
name: gh-dev-factory
description: "Autonomous development factory that uses GitHub Issues and PRs as a self-driving work loop. Runs on OpenClaw cron (recommended) or heartbeat, or manual trigger. Scaffolds repos, builds features, deploys previews, ships releases — budget-aware across both API and subscription billing. Trigger: factory run, factory scan, factory init, factory new, factory release, factory deploy, factory status. Requires gh CLI authenticated."
license: MIT
metadata:
  {"openclaw":{"emoji":"🏭","requires":{"bins":["gh","git"]},"install":[{"id":"brew","kind":"brew","formula":"gh","bins":["gh"],"label":"Install GitHub CLI (brew)"}]}}
---

# gh-dev-factory

Autonomous dev loop. Runs on cron, heartbeat, or manual trigger. Scaffolds repos, builds features, deploys previews, ships releases. Budget-aware across API keys and subscriptions.

## How It Runs

The factory has three modes. factory init helps you choose the right one.

**Cron mode (recommended)** — An isolated cron job wakes the factory on a schedule. Runs in its own session, so factory history doesn't bloat your main assistant context. Supports per-job model overrides — use Sonnet for the scan, Opus only when acting. This is the best default for most users.

```
openclaw cron add \
  --name "factory-cycle" \
  --every "2h" \
  --tz "America/New_York" \
  --session isolated \
  --message "Run one factory cycle on owner/repo. Read FACTORY.md, scan for work, act on highest priority if within budget. If nothing actionable or budget exhausted, reply HEARTBEAT_OK." \
  --model sonnet \
  --announce
```

**Heartbeat mode** — The factory scan is a line item in HEARTBEAT.md. Runs in the main session, so the agent has full conversational context. Better if you want the factory to be aware of what you've been discussing. Worse for token costs — every heartbeat re-sends the entire main session context.

```
# HEARTBEAT.md
- [ ] Factory: scan owner/repo for actionable work. If within budget, do one cycle. Otherwise HEARTBEAT_OK.
```

**Manual mode** — You say factory run and the factory does one cycle immediately. Use for debugging, demos, or when you want to push work through faster.

### Choosing: Cron vs Heartbeat

During factory init, the factory asks which mode you prefer. The decision tree:

- Does the factory need to know about your recent conversations? Usually no → cron.
- Do you want factory runs isolated from your personal assistant? Yes → cron. Factory history won't accumulate in your main session.
- Are you on a subscription with tight rate limits? Cron with a longer interval (4h) and Sonnet model avoids burning your 5-hour rolling window on factory scans.
- Do you have many HEARTBEAT.md items already? Heartbeat batches all checks into one agent turn — cheaper than separate cron jobs for each. But if the factory is your only periodic task, cron is cleaner.

### TOOLS.md Guidance

The factory writes tool guidance during setup:

```
# TOOLS.md (relevant section)

## gh-dev-factory

- Uses `gh` CLI for all GitHub operations
- Reads FACTORY.md from target repos for per-repo config
- Reads CLAUDE.md for code style and conventions
- Branch naming: factory/<issue>-<slug>
- Never self-approves PRs
- State persisted in workspace memory/factory-state.md

## Commands
- factory run — run one cycle now (manual override, respects budget)
- factory run owner/repo — run on a specific repo
- factory scan — scan only, report what the factory would do, don't act
- factory init — interactive setup: creates FACTORY.md, configures cron/heartbeat, writes TOOLS.md
- factory new owner/repo — scaffold a new repo from scratch (interactive)
- factory release — tag, changelog, and GitHub Release
- factory deploy — deploy to production using FACTORY.md config
- factory status — report budget usage, recent cycles, and current queue

Set GH_REPO=owner/repo as an alternative to passing the repo argument.
```

## Budget Awareness

Every factory run burns tokens. The cost varies dramatically depending on your billing model and configuration. The factory must be smart about spending regardless of how you pay.

### Two Billing Models

The factory needs to handle both:

**API keys (pay-per-token):** You pay for every token. A single heartbeat on Opus with 120k context costs ~$0.75. An active factory cycle with planning, coding, and tool calls can cost $2–5. The constraint is dollars.

**Subscriptions (setup-token):** Claude Pro ($20/mo), Max ($100/mo), Max 20x ($200/mo). No per-token cost, but Anthropic enforces a 5-hour rolling window and weekly usage caps. The constraint is rate limits — burn through your window on factory scans and you can't use Claude for anything else.

FACTORY.md declares which model the user is on so the factory can adapt:

```
## Budget
- Billing: subscription  # or "api" — changes how factory paces itself
- Max cycles per day: 10
- Max open PRs: 2
- Scan model: sonnet     # cheap model for scanning, reading labels/states
- Act model: opus        # expensive model for planning, coding, reviewing
```

### Model Routing — The #1 Cost Lever

Not every factory action needs the same model. Using Opus to check "any open PRs?" is like hiring a lawyer to check your mailbox.

**Scan phase (cheap):** Read labels, PR states, check budget file. This is gh CLI calls and simple JSON parsing. Sonnet or Haiku handles this perfectly. On API billing, this costs 60x less than Opus. On subscription, this barely dents your rate limit window.

**Act phase (expensive):** Planning implementations, writing code, reviewing PRs. This is where Opus earns its keep. The factory only escalates to the act model when there's actual work to do.

The factory implements this by:

1. **Cron mode:** configure `--model sonnet` for the cron job. When the scan finds actionable work, the factory uses the configured act model before starting the act phase.
1. **Heartbeat mode:** the heartbeat config supports a model field for the scan. The factory switches models mid-turn when acting.

### Cache Alignment (API users)

Anthropic's prompt cache has a TTL (default ~5 minutes for API, longer for some tiers). If your factory runs every 2h, the cache is cold every time — you pay full price for the ~10k+ token system prompt on every run.

Options:
- **Accept cold starts.** For 2h intervals with Sonnet scan, the cost per cold start is small (~$0.03). This is fine for most users.
- **Align with cache TTL.** If you run another heartbeat task (personal assistant check-ins), the shared session keeps the cache warm for free. Factory piggybacks on the warm cache.
- **Use cron (isolated).** Isolated sessions start fresh — no accumulated context from prior runs. This is actually cheaper per-run than a heartbeat in a long main session because the input token count is smaller.

### State Persistence

Between runs, the factory has no persistent process. State is tracked in a workspace memory file that the agent reads at the start of each run:

```markdown
<!-- {workspace}/memory/factory-state.md -->
# Factory State
- **Date:** 2026-02-07
- **Cycles today:** 3
- **Last cycle:** 14:30 UTC — PR #42, pushed review fixes
- **Open PRs:** 2
- **Queue depth:** 5
```

Why Markdown instead of JSON: the agent reads workspace files as part of its bootstrap context. A small Markdown file is human-readable in the dashboard, easy to edit manually, and costs fewer tokens to parse than a structured format the agent would need to reason about.

On each run:
1. Read factory-state.md from workspace memory
1. If date changed → reset cycles to 0
1. If cycles_today >= max → respond "budget exhausted" and stop (HEARTBEAT_OK for cron/heartbeat)
1. If open_prs >= max → only work on existing PRs
1. Run one cycle → update state file

### Subscription Pacing

On subscription billing, the factory should be conservative:

- **Default to longer intervals.** 4h instead of 2h. OpenClaw already defaults to 1h heartbeats for setup-token auth — the factory should respect this signal.
- **Prefer Sonnet for everything except coding.** Planning, reviewing, and scanning all work well on Sonnet. Reserve Opus for implementation cycles where code quality matters most.
- **Monitor for rate limit signals.**

If the provider returns a rate limit error, the factory logs it in the state file and backs off — doubling the interval for the rest of the day.

## Before Every Cycle

1. Determine the target repo (argument > GH_REPO env > git remote).
1. Read factory-state.md — check budget.
1. Read FACTORY.md from the repo root. Also read CLAUDE.md / AGENTS.md.
1. If FACTORY.md doesn't exist, use defaults: branch naming factory/<issue>-<slug>, squash merge, no boundaries, no previews.
1. Follow all rules from both files.

---

## factory new — Scaffold a Repo

When the user says factory new, start a conversation to scaffold a new project. Debate tech choices — don't just accept whatever the user says.

**Step 1 — Understand the goal.** What are they building? Who's it for? Weekend project or production SaaS?

**Step 2 — Recommend a stack.** Be opinionated. Propose one stack with reasoning. Push back on bad fits.

**Step 3 — Scaffold.** Create minimum viable structure:

```bash
gh repo create {owner}/{repo} --public --clone && cd {repo}
```

Generate: README.md, CLAUDE.md, FACTORY.md, .gitignore, test harness, entry point, CI workflow, labels.

```bash
mkdir -p .github/workflows
gh label create planned --description "Has implementation plan" --color "0E8A16"
gh label create blocked --description "Blocked, skip during scan" --color "D93F0B"
git add -A && git commit -m "Initial scaffold via factory new" && git push origin main
```

**Step 4 — Configure workspace.** Offer to set up cron job (recommended) or HEARTBEAT.md entry. Write TOOLS.md guidance. Create initial factory-state.md in workspace memory.

Report: "Repo live at github.com/{owner}/{repo}. CI, labels, FACTORY.md configured. Factory cron job added — first scan in {interval}. Tell the PM what you want to build."

## factory init — Interactive Setup

Walk through creating FACTORY.md for an existing repo.

**Step 1 — Detect context:**

```bash
gh api repos/{owner}/{repo}/languages
gh api repos/{owner}/{repo}/contents/CLAUDE.md --jq .name 2>/dev/null
gh label list --repo {owner}/{repo} --limit 50
gh api repos/{owner}/{repo} --jq '{allow_squash: .allow_squash_merge, allow_merge: .allow_merge_commit}'
gh api repos/{owner}/{repo}/contents/vercel.json --jq .name 2>/dev/null
gh api repos/{owner}/{repo}/contents/fly.toml --jq .name 2>/dev/null
```

Also detect billing model: check if current auth is setup-token/OAuth (subscription) or API key.

**Step 2 — Walk through sections (one at a time):**

1. Test command — infer from language, confirm
1. Merge strategy — check repo settings, adapt
1. Branch naming — default factory/<issue>-<slug>
1. Boundaries — always suggest .github/, LICENSE
1. Labels — check existing, create missing
1. Human checkpoints — auto-merge? mark ready?
1. Previews — detect platform, offer PR previews
1. Releases — versioning, deploy command, health check
1. Budget — billing model, max cycles/day, max open PRs, scan/act models. For subscription users, recommend conservative defaults (4h interval, Sonnet for scan+plan, Opus for implementation only). For API users, recommend 2h interval with Sonnet scan.
1. Scheduling — cron vs heartbeat. Explain tradeoffs. Default recommendation: cron (isolated).

**Step 3 — Generate and confirm FACTORY.md draft.**

**Step 4 — Commit via PR or direct.**

**Step 5 — Workspace integration:**
- Add cron job or HEARTBEAT.md entry (based on user's choice)
- Write TOOLS.md guidance
- Create initial factory-state.md in workspace memory
- Show the estimated cost: "At {interval} with Sonnet scan, expect ~{n} scan runs/day at ~$0.03 each = ~$0.20/day idle. Active cycles with Opus: ~$2–5 each."

---

## The Cycle

Run `python3 {baseDir}/scripts/scan.py` to get the highest-priority actionable item as JSON.

If empty: "factory idle — nothing actionable." Stop. (In cron/heartbeat mode: HEARTBEAT_OK. Keep response minimal — this is the cheap path.)

Otherwise, take the first item only and do the one thing that moves it forward. If an act model is configured and different from the current model, switch to it before acting.

### Issue — needs_plan

Read the issue. Comment implementation plan: approach, files, test strategy. Add planned label. Stop.

### Issue — planned (no PR yet)

If open_prs >= max_open_prs, skip — work on existing PRs instead. Otherwise: create branch, implement, open draft PR with Closes #N. Push and stop.

### PR — draft

Run tests if configured. Fix failures. If previews enabled, verify deploy and comment URL. Mark ready for review. Stop.

### PR — needs_review

Review for correctness, tests, rule adherence. Never approve a PR you authored in a recent cycle. Request changes or approve. Stop.

### PR — changes_requested

Read review comments. Fix what was asked. Push. Stop.

### PR — approved

Merge using configured strategy. Respect checkpoint rules. Verify linked issue closed. Update state file. Stop.

---

## Preview Deploys

Every PR gets a live preview URL when configured.

**Platform-native (Vercel, Netlify):** Auto-deploy. Factory comments URL on PR.

**Custom (Fly, Docker):** Factory runs preview command. Comments URL. Tears down on merge.

The feedback loop: PR opened → preview deploys → URL on PR → PM reviews live → feedback as comments → factory fixes → preview updates

## factory release

1. Find most recent tag
1. List merged PRs since that tag
1. Categorize: features, fixes, breaking, docs, chores (by label)
1. Suggest semver bump
1. Draft changelog, confirm with user
1. `gh release create v{version} --title "v{version}" --notes "{changelog}"`
1. If deploy configured: "Release tagged. Deploy to production now?"

Releases are always manual. The factory never auto-releases.

## factory deploy

1. **Pre-flight:** CI green? Any blocker issues? Stop if not.
1. **Deploy:** Run command from FACTORY.md
1. **Verify:** Poll health check if configured
1. **Rollback:** If failed, rollback + create Issue with bug,blocker labels
1. **Report:** "v{version} is live. Health check green."

## factory status

Report current state without running a cycle:

- **Budget:** "3/10 cycles used today, 7 remaining"
- **Billing:** "subscription (Sonnet scan, Opus act)" or "API ($0.45 estimated today)"
- **Queue:** "5 items (2 PRs in review, 1 planned, 2 unplanned)"
- **Open PRs:** "2/2 max — finishing existing before starting new"
- **Last cycle:** "2h ago — pushed review fixes on PR #42"
- **Schedule:** "cron every 2h, next run in 45 minutes"

---

## Rules

- **One item per cycle.** Do not chain actions.
- **Never self-approve.** If you authored it, you cannot approve it.
- **Small PRs.** If too large, break into sub-issues first.
- **FACTORY.md is law.** Follow its rules, boundaries, and checkpoints.
- **CLAUDE.md is context.** Follow its code style and conventions.
- **Respect human checkpoints.** Never auto-merge if config says no.
- **Releases are deliberate.** Never auto-tag or auto-release.
- **Respect the budget.** Never exceed cycle limits. When exhausted, stop.
- **Cheap when idle.** Minimal response when nothing to do. Don't burn tokens on empty queues.
- **Right model for the job.** Scan on the cheap model. Act on the capable one.

## Scan Output Format

scan.py returns JSON sorted by priority:

```json
[{"type": "issue|pr", "number": 42, "title": "...", "state": "...", "priority": 1}]
```

States: needs_plan, planned, draft, needs_review, changes_requested, approved.

Priority: changes_requested > approved > needs_review > draft > planned > needs_plan.

Finish in-progress work before starting new work.
