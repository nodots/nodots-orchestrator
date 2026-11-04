# HANDOFF: S1.5 — sync-cells matches a PR title by the bounded package ID

## Done

- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/scripts/sync-cells.sh:273`:
  the title fallback is now `idMatcher(id).test(String(p.title))`, the bounded
  matcher the branch rule uses (`sync-cells.sh:214-218`). No other rule changed.
- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/sync-cells.test.sh`:
  two stub runs after the "mention" cases.
  - S1.1 (#124, branch `feat/s1-1-fleet-standards-init`, no PR) and S1.1a
    (#137), with merged PR #139 titled `[READY]: S1.1a — The text invariant
    exempts the file that drafts a target's commands`, body `Closes #137`, head
    `feat/s1-1a-invariant-exempts-init`. Asserts #137 `cell:merged`, #124 not
    `cell:merged` and `cell:active`.
  - `M1.3` does not claim `[READY]: M1.30 — x`. `S1.1` claims
    `[READY]: S1.1 — x` with no closing keyword.
- The fixture was committed first (4af347e). Against the pre-change script it
  failed 4 of 85 checks, #124 coming out `cell:queued -> cell:merged (PR #139 merged)`
  and #152 (M1.3) `cell:queued -> cell:merged (PR #162 merged)`. After the change,
  85 checks pass, and `bash scripts/test.sh` ends `ALL PASS`.

## Next

Review and merge. Nothing is left in this package.

## Plan check

Package issue still matches: no

Updated #141. The issue said to run the fixture "through `--state` like the
existing cases". A `--state` file holds state that is already matched:
`sync-cells.sh:352` calls `collect_state`, where the matcher runs
(`sync-cells.sh:199-289`), only when `--state` is absent. So a `--state`
fixture cannot reach line 273. The fixture runs through the gh stub instead, the
same way the branch-matching and mention cases do (`sync-cells.test.sh:208-237`,
`:278-316`). The inputs and assertions are the ones the issue specifies.
