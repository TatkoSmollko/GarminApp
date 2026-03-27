#!/usr/bin/env python3
"""
Sync Trello cards into GitHub issues for Codex intake.

Environment:
- TRELLO_API_KEY
- TRELLO_API_TOKEN
- TRELLO_LIST_ID
- GITHUB_TOKEN
- GITHUB_REPOSITORY  (owner/repo)

Optional:
- TRELLO_LABEL_NAME   default: codex-task
- TRELLO_CARD_PREFIX  default: [Trello]
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any


TRELLO_BASE = "https://api.trello.com/1"
GITHUB_BASE = "https://api.github.com"


def _env(name: str, required: bool = True, default: str | None = None) -> str:
    value = os.getenv(name, default)
    if required and not value:
        raise SystemExit(f"Missing required env var: {name}")
    return value or ""


def _request_json(url: str, *, method: str = "GET", headers: dict[str, str] | None = None,
                  body: dict[str, Any] | None = None) -> Any:
    req_headers = headers or {}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        req_headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, method=method, headers=req_headers, data=data)
    with urllib.request.urlopen(req) as response:
        return json.loads(response.read().decode("utf-8"))


def _trello_url(path: str, **params: str) -> str:
    query = {
        "key": _env("TRELLO_API_KEY"),
        "token": _env("TRELLO_API_TOKEN"),
    }
    query.update(params)
    return f"{TRELLO_BASE}{path}?{urllib.parse.urlencode(query)}"


def _github_headers() -> dict[str, str]:
    return {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {_env('GITHUB_TOKEN')}",
        "X-GitHub-Api-Version": "2022-11-28",
    }


@dataclass
class TrelloCard:
    card_id: str
    name: str
    desc: str
    url: str


def fetch_cards() -> list[TrelloCard]:
    list_id = _env("TRELLO_LIST_ID")
    data = _request_json(
        _trello_url(
            f"/lists/{list_id}/cards",
            fields="id,name,desc,url,closed",
            filter="open",
        )
    )

    cards: list[TrelloCard] = []
    for item in data:
        if item.get("closed"):
            continue
        cards.append(
            TrelloCard(
                card_id=item["id"],
                name=item["name"].strip(),
                desc=(item.get("desc") or "").strip(),
                url=item["url"],
            )
        )
    return cards


def fetch_open_issues() -> list[dict[str, Any]]:
    repo = _env("GITHUB_REPOSITORY")
    return _request_json(
        f"{GITHUB_BASE}/repos/{repo}/issues?state=open&per_page=100",
        headers=_github_headers(),
    )


def issue_for_card(card_id: str, issues: list[dict[str, Any]]) -> dict[str, Any] | None:
    marker = f"<!-- trello-card-id:{card_id} -->"
    for issue in issues:
        if marker in (issue.get("body") or ""):
            return issue
    return None


def normalize_body(card: TrelloCard) -> str:
    branch_slug = slugify(card.name)[:40]
    branch_name = f"codex/trello-{card.card_id[:8]}-{branch_slug}" if branch_slug else f"codex/trello-{card.card_id[:8]}"

    parts = [
        f"<!-- trello-card-id:{card.card_id} -->",
        "## Source",
        f"- Trello: {card.url}",
        "",
        "## Suggested Branch",
        f"- `{branch_name}`",
        "",
        "## Task",
        card.desc if card.desc else "_No card description provided._",
        "",
        "## Codex Notes",
        "- Keep the change small and isolated.",
        "- Re-run the watch build after code changes.",
        "- If backend changes are not explicitly required, default to `watch-app/` only.",
    ]
    return "\n".join(parts)


def slugify(value: str) -> str:
    value = value.lower().strip()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    return re.sub(r"-{2,}", "-", value).strip("-")


def create_issue(card: TrelloCard) -> None:
    repo = _env("GITHUB_REPOSITORY")
    prefix = os.getenv("TRELLO_CARD_PREFIX", "[Trello]")
    label = os.getenv("TRELLO_LABEL_NAME", "codex-task")

    body = {
        "title": f"{prefix} {card.name}",
        "body": normalize_body(card),
        "labels": [label],
    }

    _request_json(
        f"{GITHUB_BASE}/repos/{repo}/issues",
        method="POST",
        headers=_github_headers(),
        body=body,
    )


def main() -> int:
    cards = fetch_cards()
    issues = fetch_open_issues()

    created = 0
    skipped = 0

    for card in cards:
        if issue_for_card(card.card_id, issues):
            skipped += 1
            continue
        create_issue(card)
        created += 1

    print(json.dumps({"cards": len(cards), "created": created, "skipped": skipped}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
