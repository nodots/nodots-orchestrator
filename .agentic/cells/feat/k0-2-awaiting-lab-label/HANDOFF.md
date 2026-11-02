# HANDOFF: K0.2 — cell:awaiting-lab derived from an open [VERIFY] PR

## Done

- `assets/tests/sync-cells.test.sh`: six `[VERIFY]` fixture cases (state file) and one collector case (gh stub). Written before the change; the four awaiting-lab cases failed against the pre-change script (79 checks, 4 failed).
- `assets/scripts/sync-cells.sh`:
  - `derive()` gains a rule after the current-stamp check: an open PR whose title matches `/^\[VERIFY\]:/` with no current stamp derives `cell:awaiting-lab`. Precedence is merged, awaiting-review, awaiting-lab, blocked, active.
  - The collector's `pr` object carries `title`, so the rule works on live state.
  - Header precedence comment updated.
- `assets/scripts/bootstrap-github-labels.sh`: creates `cell:awaiting-lab` (color `c2e0c6`).
- `references/adapter-github.md`: label table and derivation table updated.

## Verification

- `bash assets/tests/sync-cells.test.sh`: 79 checks, 0 failed.
- `bash scripts/test.sh`: ends `ALL PASS`, exit 0.

## Not done / outside lane

- `plugins/fleet/bin/fleet.js:149` and `plugins/fleet/tests/stubs/gh.js:71` list the label set and `plugins/fleet/src/cycle.js:38` counts `cell:*` labels. None of them know `cell:awaiting-lab`. All three are under `forbiddenPaths` (`plugins/fleet/**`), so they are untouched. A coordinator package is needed for fleet to count and report this label.
- `references/adapter-jira.md` and `references/epic.md` list the lifecycle without the lab state. Not in `allowedPaths`; untouched.

## Plan check

Package issue still matches: yes
