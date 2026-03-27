# Codex Workflow Notes

## Branch Naming

- `codex/<topic>-<slug>`
- `codex/trello-<card-id>-<slug>` when the task comes from Trello

Examples:

- `codex/ui-round-layout`
- `codex/trello-ab12c3-fix-stop-flow`

## Commit Naming

- `fix(watch): stabilize stop flow`
- `feat(watch): add stage target footer`
- `docs(repo): add agent workflow docs`
- `chore(repo): add CI build workflow`

## Task Prompt Template

Use this structure for future Codex tasks:

1. Context
2. Goal
3. Constraints
4. Files or modules likely involved
5. Verification expectations
6. Definition of done

Example:

```text
Context:
- Garmin Connect IQ watch app for LT1 testing
- Primary scope is `watch-app/` only

Goal:
- Fix the completion screen on round displays

Constraints:
- No pipeline changes
- Keep the change small
- Re-run watch build

Verification:
- Build with monkeyc
- Describe manual simulator expectation
```

## Trello Ticket Requirements

A Trello ticket should contain at least:

- short problem statement
- expected outcome
- scope boundaries
- acceptance criteria
- screenshots or device context if UI is involved
- whether pipeline changes are allowed or forbidden

## PR Minimum

Each PR should include:

- one focused goal
- build result
- manual verification note
- open risks or follow-ups
