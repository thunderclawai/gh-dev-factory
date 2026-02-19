#!/usr/bin/env python3
"""Scan a GitHub repo for actionable work. Outputs ranked JSON to stdout."""

import json
import os
import re
import subprocess
import sys


def gh(args: list) -> str:
    result = subprocess.run(
        ["gh"] + args, capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"gh error: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def parse_json(raw: str) -> list:
    """Safely parse JSON from gh CLI output."""
    if not raw:
        return []
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"JSON parse error: {e}", file=sys.stderr)
        return []


def get_repo() -> str:
    # 1. Positional argument
    if len(sys.argv) > 1:
        return sys.argv[1]
    # 2. Environment variable
    repo = os.environ.get("GH_REPO", "")
    if repo:
        return repo
    # 3. Git remote
    try:
        url = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True, text=True
        ).stdout.strip()
        match = re.search(r"github\.com[:/](.+?)(?:\.git)?$", url)
        if match:
            return match.group(1)
    except Exception:
        pass
    print("Cannot determine repo. Pass owner/repo as argument, set GH_REPO, or run from a checkout.", file=sys.stderr)
    sys.exit(1)


PRIORITY = {
    "changes_requested": 1,
    "approved": 2,
    "needs_review": 3,
    "draft": 4,
    "planned": 5,
    "needs_plan": 6,
}


def scan_prs(repo: str) -> tuple:
    """Scan open PRs. Returns (items, prs_raw) — prs_raw reused by scan_issues."""
    items = []
    raw = gh([
        "pr", "list", "--repo", repo, "--state", "open",
        "--json", "number,title,isDraft,reviewDecision,labels,body,createdAt",
        "--limit", "50"
    ])
    prs = parse_json(raw)

    for pr in prs:
        decision = pr.get("reviewDecision", "")
        is_draft = pr.get("isDraft", False)
        label_names = [l["name"] for l in pr.get("labels", [])]

        if "blocked" in label_names:
            continue

        if decision == "CHANGES_REQUESTED":
            state = "changes_requested"
        elif decision == "APPROVED":
            state = "approved"
        elif not is_draft:
            state = "needs_review"
        else:
            state = "draft"

        items.append({
            "type": "pr",
            "number": pr["number"],
            "title": pr["title"],
            "state": state,
            "priority": PRIORITY[state],
            "created": pr.get("createdAt", ""),
        })

    return items, prs


def scan_issues(repo: str, prs: list) -> list:
    """Scan open issues. Accepts PR data to avoid duplicate API call."""
    items = []
    raw = gh([
        "issue", "list", "--repo", repo, "--state", "open",
        "--json", "number,title,labels,createdAt",
        "--limit", "50"
    ])
    issues = parse_json(raw)

    # Find issues already linked to open PRs (reuse PR data)
    linked_issues = set()
    for pr in prs:
        body = pr.get("body", "") or ""
        linked_issues.update(
            int(m) for m in re.findall(
                r"(?:closes|fixes|resolves)\s+#(\d+)", body, re.IGNORECASE
            )
        )

    for issue in issues:
        label_names = [l["name"] for l in issue.get("labels", [])]
        if "blocked" in label_names or "epic" in label_names:
            continue
        if issue["number"] in linked_issues:
            continue

        state = "planned" if "planned" in label_names else "needs_plan"
        items.append({
            "type": "issue",
            "number": issue["number"],
            "title": issue["title"],
            "state": state,
            "priority": PRIORITY[state],
            "created": issue.get("createdAt", ""),
        })

    return items


def update_epic(repo: str):
    """Find issues labeled 'epic' and sync their checklists with actual issue states."""
    raw = gh([
        "issue", "list", "--repo", repo, "--state", "open",
        "--label", "epic",
        "--json", "number,body",
        "--limit", "10"
    ])
    epics = parse_json(raw)
    if not epics:
        return

    # Get all issues (open + closed) referenced in epics
    for epic in epics:
        body = epic.get("body", "") or ""
        if not body:
            continue

        # Find all issue refs like #11, #12 etc in checkbox lines
        refs = set(int(m) for m in re.findall(r"- \[[ x]\] #(\d+)", body))
        if not refs:
            continue

        # Check state of each referenced issue
        closed_issues = set()
        open_issues = set()
        for num in refs:
            try:
                state_raw = gh([
                    "issue", "view", str(num), "--repo", repo,
                    "--json", "state", "--jq", ".state"
                ])
                if state_raw == "CLOSED":
                    closed_issues.add(num)
                else:
                    open_issues.add(num)
            except Exception:
                pass

        # Also find issues that reference this epic but aren't in the checklist yet
        # Search for issues mentioning the epic number
        search_raw = gh([
            "issue", "list", "--repo", repo, "--state", "all",
            "--json", "number,title,state,labels",
            "--limit", "100"
        ])
        all_issues = parse_json(search_raw)

        # Build map of existing issues for title lookup
        issue_map = {i["number"]: i for i in all_issues}

        # Find issues not in checklist (exclude the epic itself and other epics)
        missing = []
        for issue in all_issues:
            num = issue["number"]
            if num == epic["number"] or num in refs:
                continue
            labels = [l["name"] for l in issue.get("labels", [])]
            if "epic" in labels:
                continue
            missing.append(issue)

        # Update existing checkboxes
        new_body = body
        for num in refs:
            if num in closed_issues:
                new_body = re.sub(
                    rf"- \[ \] #{num}\b",
                    f"- [x] #{num}",
                    new_body
                )
            elif num in open_issues:
                new_body = re.sub(
                    rf"- \[x\] #{num}\b",
                    f"- [ ] #{num}",
                    new_body
                )

        # Add missing issues to appropriate sections
        if missing:
            # Group by state
            closed_missing = [i for i in missing if i["state"] == "CLOSED"]
            open_missing = [i for i in missing if i["state"] != "CLOSED"]

            # Build new lines
            new_lines = []
            for i in closed_missing:
                new_lines.append(f"- [x] #{i['number']} — {i['title']}")
            for i in open_missing:
                new_lines.append(f"- [ ] #{i['number']} — {i['title']}")

            if new_lines:
                # Append to the end of the checklist section or before "Future Ideas"
                addition = "\n" + "\n".join(new_lines)
                # Try to insert before "Future Ideas" or similar section
                future_match = re.search(r"\n(###?\s+🎯\s+Future)", new_body)
                if future_match:
                    new_body = new_body[:future_match.start()] + addition + new_body[future_match.start():]
                else:
                    new_body += addition

        if new_body != body:
            # Update the epic issue
            try:
                subprocess.run(
                    ["gh", "issue", "edit", str(epic["number"]),
                     "--repo", repo, "--body", new_body],
                    capture_output=True, text=True
                )
                print(f"Updated epic #{epic['number']} checklist", file=sys.stderr)
            except Exception as e:
                print(f"Failed to update epic #{epic['number']}: {e}", file=sys.stderr)


def main():
    repo = get_repo()
    pr_items, prs = scan_prs(repo)
    items = pr_items + scan_issues(repo, prs)
    items.sort(key=lambda x: (x["priority"], x.get("created", "")))

    # Sync epic checklists
    update_epic(repo)

    output = [
        {"type": i["type"], "number": i["number"], "title": i["title"],
         "state": i["state"], "priority": rank + 1}
        for rank, i in enumerate(items)
    ]

    print(json.dumps(output, indent=2) if output else "[]")


if __name__ == "__main__":
    main()
