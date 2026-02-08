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
    repo = os.environ.get("GH_REPO", "")
    if repo:
        return repo
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
    print("Cannot determine repo. Set GH_REPO or run from a checkout.", file=sys.stderr)
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
        if "blocked" in label_names:
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


def main():
    repo = get_repo()
    pr_items, prs = scan_prs(repo)
    items = pr_items + scan_issues(repo, prs)
    items.sort(key=lambda x: (x["priority"], x.get("created", "")))

    output = [
        {"type": i["type"], "number": i["number"], "title": i["title"],
         "state": i["state"], "priority": rank + 1}
        for rank, i in enumerate(items)
    ]

    print(json.dumps(output, indent=2) if output else "[]")


if __name__ == "__main__":
    main()
