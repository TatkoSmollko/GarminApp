# LT1 Test Garmin App

Garmin Connect IQ watch app for guided LT1 step testing using RR intervals and DFA a1.

The repository is split into two top-level parts:

- `watch-app/`: Garmin Connect IQ watch app
- `backend/`: Python processing/report tooling

The watch app should be treated as the main product unless a task explicitly targets the backend.

## Requirements

- Garmin Connect IQ SDK
- Garmin developer key (`.der`)
- `monkeyc` and `monkeydo` available in `PATH`
- Connect IQ Simulator for simulator runs

## Local Build

Build the watch app for Forerunner 955:

```sh
monkeyc -f watch-app/monkey.jungle -o /tmp/garminApp.prg -d fr955 -w -y ~/.garmin/developer_key.der
```

Export an `.iq` package:

```sh
monkeyc -f watch-app/monkey.jungle -o /tmp/garminApp.iq -e -d fr955 -y ~/.garmin/developer_key.der
```

## Local Run

Run in the Connect IQ simulator:

```sh
monkeydo /tmp/garminApp.prg fr955
```

Notes:

- the simulator must already be running
- simulator connectivity has been flaky in this repository, so manual device selection may still be required

## Tests

Connect IQ unit tests are in `watch-app/source/tests/LT1TestTests.mc`.

Intended test invocation:

```sh
monkeydo /tmp/garminApp.prg fr955 -t
```

Current state:

- test sources exist
- build is confirmed
- automated simulator test execution is not yet confirmed as reliable

## Main Directories

- `watch-app/source/`: Monkey C source files
- `watch-app/source/tests/`: Connect IQ unit tests
- `watch-app/resources/`: strings, drawables, layouts, settings
- `backend/report/`: reporting schema and notes
- `backend/pipeline/`: secondary Python report-processing tools

## Main Config Files

- `watch-app/manifest.xml`
- `watch-app/monkey.jungle`
- `watch-app/resources/settings/properties.xml`
- `watch-app/resources/settings/settings.xml`
- `backend/pipeline/requirements.txt`

## Current Project Gaps

- no automated Garmin build in GitHub Actions; watch builds stay local on purpose
- no confirmed automated simulator test flow
- some build warnings remain in the watch app
- repository still contains both watch app and backend code, so task boundaries must stay explicit

## Task Automation

Repository automation scaffolding is now available for:

- Trello intake into GitHub Issues
- automatic branch creation from labeled issues

See:

- [automation notes](/Users/tomasvago/garminApp/docs/automation.md)
- [Trello intake workflow](/Users/tomasvago/garminApp/.github/workflows/trello-intake.yml)
- [issue branch workflow](/Users/tomasvago/garminApp/.github/workflows/issue-branch.yml)

## Suggested Development Flow

1. Create a small branch for one task.
2. Change only the relevant slice of the repo.
3. Re-run the watch build.
4. If possible, verify in simulator or on-device.
5. Open a focused PR with verification notes.
