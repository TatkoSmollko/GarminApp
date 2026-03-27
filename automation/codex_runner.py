#!/usr/bin/env python3
"""
Run Codex locally for GitHub issues labeled as ready.

This runner is intended to run on the developer's machine. It polls GitHub
issues, claims one ready issue at a time, checks out the matching branch, runs
Codex non-interactively, and then pushes any resulting commit.

Required environment:
- GITHUB_TOKEN
- GITHUB_REPOSITORY   (owner/repo)

Optional environment:
- CODEX_REPO_DIR            default: current working directory
- CODEX_POLL_SECONDS        default: 120
- CODEX_READY_LABEL         default: codex-ready
- CODEX_RUNNING_LABEL       default: codex-running
- CODEX_DONE_LABEL          default: codex-done
- CODEX_FAILED_LABEL        default: codex-failed
- CODEX_MODEL               optional Codex model override
- CODEX_DRY_RUN             default: false
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any


GITHUB_BASE = "https://api.github.com"


def _env(name: str, required: bool = True, default: str | None = None) -> str:
    value = os.getenv(name, default)
    if required and not value:
        raise SystemExit(f"Missing required env var: {name}")
    return value or ""


def _bool_env(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def _github_headers() -> dict[str, str]:
    return {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {_env('GITHUB_TOKEN')}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "garminapp-codex-runner",
    }


def _request_json(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
) -> Any:
    req_headers = headers or {}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        req_headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, method=method, headers=req_headers, data=data)
    with urllib.request.urlopen(req) as response:
        raw = response.read().decode("utf-8")
        return json.loads(raw) if raw else None


@dataclass
class Issue:
    number: int
    title: str
    body: str
    labels: list[str]
    html_url: str


def slugify(value: str) -> str:
    value = value.lower().strip()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = re.sub(r"-{2,}", "-", value).strip("-")
    return value[:40]


def branch_name_for_issue(issue: Issue) -> str:
    return f"codex/issue-{issue.number}-{slugify(issue.title)}"


def fetch_open_issues() -> list[Issue]:
    repo = _env("GITHUB_REPOSITORY")
    data = _request_json(
        f"{GITHUB_BASE}/repos/{repo}/issues?state=open&per_page=100",
        headers=_github_headers(),
    )
    issues: list[Issue] = []
    for item in data:
        if "pull_request" in item:
            continue
        issues.append(
            Issue(
                number=item["number"],
                title=item["title"],
                body=item.get("body") or "",
                labels=[label["name"] for label in item.get("labels", [])],
                html_url=item["html_url"],
            )
        )
    return issues


def add_labels(issue_number: int, labels: list[str]) -> None:
    repo = _env("GITHUB_REPOSITORY")
    _request_json(
        f"{GITHUB_BASE}/repos/{repo}/issues/{issue_number}/labels",
        method="POST",
        headers=_github_headers(),
        body={"labels": labels},
    )


def remove_label(issue_number: int, label: str) -> None:
    repo = _env("GITHUB_REPOSITORY")
    try:
        _request_json(
            f"{GITHUB_BASE}/repos/{repo}/issues/{issue_number}/labels/{urllib.parse.quote(label)}",
            method="DELETE",
            headers=_github_headers(),
        )
    except urllib.error.HTTPError as err:
        if err.code != 404:
            raise


def comment(issue_number: int, body: str) -> None:
    repo = _env("GITHUB_REPOSITORY")
    _request_json(
        f"{GITHUB_BASE}/repos/{repo}/issues/{issue_number}/comments",
        method="POST",
        headers=_github_headers(),
        body={"body": body},
    )


def run(cmd: list[str], *, cwd: Path, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd),
        check=False,
        text=True,
        capture_output=capture,
    )


def ensure_clean_checkout(repo_dir: Path) -> None:
    status = run(["git", "status", "--porcelain"], cwd=repo_dir, capture=True)
    if status.returncode != 0:
        raise RuntimeError(status.stderr.strip() or "git status failed")
    if status.stdout.strip():
        raise RuntimeError("working tree is not clean; refusing to start automated Codex task")


def checkout_branch(repo_dir: Path, branch_name: str) -> None:
    run(["git", "fetch", "origin"], cwd=repo_dir)
    exists = run(["git", "ls-remote", "--exit-code", "--heads", "origin", branch_name], cwd=repo_dir)
    if exists.returncode != 0:
        raise RuntimeError(f"remote branch does not exist: {branch_name}")

    local_exists = run(["git", "show-ref", "--verify", f"refs/heads/{branch_name}"], cwd=repo_dir)
    if local_exists.returncode == 0:
        result = run(["git", "checkout", branch_name], cwd=repo_dir, capture=True)
    else:
        result = run(["git", "checkout", "-b", branch_name, f"origin/{branch_name}"], cwd=repo_dir, capture=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"failed to checkout {branch_name}")

    reset = run(["git", "reset", "--hard", f"origin/{branch_name}"], cwd=repo_dir, capture=True)
    if reset.returncode != 0:
        raise RuntimeError(reset.stderr.strip() or f"failed to sync {branch_name}")


def build_prompt(issue: Issue, branch_name: str) -> str:
    return "\n".join(
        [
            f"Work on GitHub issue #{issue.number} in repository {_env('GITHUB_REPOSITORY')}.",
            f"Target branch: `{branch_name}`.",
            "",
            "Requirements:",
            "- Follow AGENTS.md in the repository.",
            "- Keep the change small and isolated.",
            "- Default to `watch-app/` unless the issue explicitly requires `backend/`.",
            "- After code changes, run the relevant local verification that is realistically available.",
            "- Do not open interactive prompts.",
            "- Leave a concise final summary suitable for a PR description.",
            "",
            f"Issue title: {issue.title}",
            "",
            "Issue body:",
            issue.body or "_No issue body provided._",
        ]
    )


def run_codex(repo_dir: Path, issue: Issue, branch_name: str) -> tuple[int, str]:
    prompt = build_prompt(issue, branch_name)
    with tempfile.NamedTemporaryFile("w+", suffix=".txt", delete=False) as output_file:
        output_path = output_file.name

    cmd = [
        "codex",
        "exec",
        "--full-auto",
        "--cd",
        str(repo_dir),
        "--output-last-message",
        output_path,
    ]

    model = os.getenv("CODEX_MODEL")
    if model:
        cmd.extend(["--model", model])
    cmd.append(prompt)

    result = run(cmd, cwd=repo_dir, capture=True)
    final_message = ""
    try:
        final_message = Path(output_path).read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        final_message = ""
    finally:
        try:
            Path(output_path).unlink()
        except FileNotFoundError:
            pass

    if result.returncode != 0 and result.stderr:
        final_message = f"{final_message}\n\nstderr:\n{result.stderr.strip()}".strip()

    return result.returncode, final_message


def commit_and_push(repo_dir: Path, issue: Issue, branch_name: str) -> str:
    status = run(["git", "status", "--porcelain"], cwd=repo_dir, capture=True)
    if status.returncode != 0:
        raise RuntimeError(status.stderr.strip() or "git status failed")
    if not status.stdout.strip():
        return "No file changes were produced."

    add = run(["git", "add", "-A"], cwd=repo_dir, capture=True)
    if add.returncode != 0:
        raise RuntimeError(add.stderr.strip() or "git add failed")

    commit = run(
        ["git", "commit", "-m", f"codex: resolve issue #{issue.number}"],
        cwd=repo_dir,
        capture=True,
    )
    if commit.returncode != 0:
        raise RuntimeError(commit.stderr.strip() or commit.stdout.strip() or "git commit failed")

    push = run(["git", "push", "origin", branch_name], cwd=repo_dir, capture=True)
    if push.returncode != 0:
        raise RuntimeError(push.stderr.strip() or "git push failed")

    return "Committed and pushed changes."


def classify_failure(message: str) -> str:
    lower = message.lower()
    if any(token in lower for token in ["usage limit", "quota", "rate limit", "insufficient_quota"]):
        return "quota"
    return "failure"


def process_issue(repo_dir: Path, issue: Issue, dry_run: bool) -> None:
    ready_label = os.getenv("CODEX_READY_LABEL", "codex-ready")
    running_label = os.getenv("CODEX_RUNNING_LABEL", "codex-running")
    done_label = os.getenv("CODEX_DONE_LABEL", "codex-done")
    failed_label = os.getenv("CODEX_FAILED_LABEL", "codex-failed")

    branch_name = branch_name_for_issue(issue)

    if dry_run:
        print(json.dumps({"mode": "dry-run", "issue": issue.number, "branch": branch_name}))
        return

    add_labels(issue.number, [running_label])
    remove_label(issue.number, ready_label)
    comment(issue.number, f"Codex runner claimed this task and will work on `{branch_name}`.")

    try:
        ensure_clean_checkout(repo_dir)
        checkout_branch(repo_dir, branch_name)
        exit_code, final_message = run_codex(repo_dir, issue, branch_name)
        if exit_code != 0:
            failure_kind = classify_failure(final_message)
            add_labels(issue.number, [failed_label])
            remove_label(issue.number, running_label)
            if failure_kind == "quota":
                comment(issue.number, "Codex runner stopped because usage limits were reached. It can be retried later.")
            else:
                comment(issue.number, f"Codex runner failed.\n\n```\n{final_message[:3000]}\n```")
            return

        push_summary = commit_and_push(repo_dir, issue, branch_name)
        add_labels(issue.number, [done_label])
        remove_label(issue.number, running_label)
        comment(
            issue.number,
            "\n".join(
                [
                    f"Codex runner finished work on `{branch_name}`.",
                    push_summary,
                    "",
                    "Final summary:",
                    final_message or "_No final summary captured._",
                ]
            ),
        )
    except Exception as err:
        add_labels(issue.number, [failed_label])
        remove_label(issue.number, running_label)
        comment(issue.number, f"Codex runner failed before completion: `{err}`")


def pick_issue(issues: list[Issue]) -> Issue | None:
    ready_label = os.getenv("CODEX_READY_LABEL", "codex-ready")
    running_label = os.getenv("CODEX_RUNNING_LABEL", "codex-running")
    done_label = os.getenv("CODEX_DONE_LABEL", "codex-done")
    failed_label = os.getenv("CODEX_FAILED_LABEL", "codex-failed")

    for issue in issues:
        labels = set(issue.labels)
        if ready_label not in labels:
            continue
        if running_label in labels or done_label in labels:
            continue
        if failed_label in labels:
            continue
        return issue
    return None


def run_once() -> int:
    repo_dir = Path(_env("CODEX_REPO_DIR", required=False, default=os.getcwd())).resolve()
    dry_run = _bool_env("CODEX_DRY_RUN", default=False)
    issues = fetch_open_issues()
    issue = pick_issue(issues)
    if not issue:
        print(json.dumps({"status": "idle", "issues": len(issues)}))
        return 0

    process_issue(repo_dir, issue, dry_run)
    return 0


def main() -> int:
    if "--once" in sys.argv:
        return run_once()

    poll_seconds = int(os.getenv("CODEX_POLL_SECONDS", "120"))
    while True:
        try:
            run_once()
        except Exception as err:
            print(json.dumps({"status": "error", "error": str(err)}))
        time.sleep(poll_seconds)


if __name__ == "__main__":
    sys.exit(main())
