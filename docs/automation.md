# Automation Flow

## Target Flow

Trello card -> GitHub issue -> branch -> Codex work -> PR

## Current Repository Automation

### 1. Trello intake

Workflow: `.github/workflows/trello-intake.yml`

What it does:

- polls a Trello list every 15 minutes
- creates a GitHub issue for each new open card
- prevents duplicate issues by embedding the Trello card ID in the issue body

Required GitHub repository secrets:

- `TRELLO_API_KEY`
- `TRELLO_API_TOKEN`
- `TRELLO_LIST_ID`

Recommended Trello setup:

- one list dedicated to ready-to-implement Codex tasks
- cards should contain:
  - problem statement
  - desired outcome
  - scope
  - acceptance criteria

### 2. Branch creation

Workflow: `.github/workflows/issue-branch.yml`

What it does:

- when a GitHub issue gets the label `codex-ready`
- creates a branch named:
  - `codex/issue-<number>-<slug>`
- comments the branch name back onto the issue

### 3. Watch build

Watch app builds are intentionally kept local.

Why:

- the local Garmin SDK setup is already known to work
- GitHub-hosted Garmin builds were unreliable for this repository
- a failing hosted build was adding noise instead of improving PR safety

Current rule:

- build and simulator/device verification for `watch-app/` are manual local steps
- GitHub Actions in this repository are used only for task automation, not Garmin packaging

## Manual Step Still Needed

This repository is now prepared for automation, but one step is still external:

- Codex execution itself is not yet triggered automatically by GitHub Actions from this repository alone

Practical current use:

1. Trello creates the issue automatically
2. add the label `codex-ready`
3. branch is created automatically
4. run Codex against that issue/task
5. open a PR
6. run the Garmin build locally before merge

## Next Step If You Want Fuller Automation

The next layer would be a task runner that:

- reads newly created GitHub issues
- invokes Codex with the issue body as the task prompt
- pushes commits to the generated branch
- opens a PR automatically

That requires a secure Codex execution environment and credentials outside ordinary repository files.
