# HANDOFF: C0.3 — records: merged-into-integration counts as merged

## Done

- **`assets/scripts/sync-cells.sh`.** A PR merged into any base was already
  `cell:merged`, because `derive` never read the base. The tests now pin that.
  The reason now ends ` (into <base>)` when the base is not the repo's default
  branch (`mergedReason`, called from `derive`).
  - The collector asks `gh pr list` for `baseRefName` and records it as `pr.base`.
  - For each repo with a merged PR that names a base, it reads
    `gh api repos/<r> --jq .default_branch` once and records the result under
    `state.defaultBranches`.
  - A failed read, or one that returns an empty value, exits 70 and names the
    repo.
  - A state file that has `pr.base` but no default branch for that repo also
    exits 70. The script never guesses the default branch.
  - Older states with no `base` keep the plain reason.
  - `--help` now covers the two longer header lines (`sed -n '2,64p'`).
- **`assets/tests/sync-cells.test.sh`.** Adds a new section at the end, "a merge
  into an integration branch is a merge (C0.3)". It covers:
  - the state-file fixture, with and without the suffix;
  - a missing default branch;
  - `promote.js` `mergedBranches`, read in place and not changed;
  - the collector stub: the base is collected, the default branch is read once,
    and a 500 or an empty value fails the run.

  These tests were written first. Against the old script, 15 checks failed;
  one of them was a wrong path in the test itself, fixed before the
  implementation. Now: 135 checks, 0 failed.
- **`references/merge-procedure.md` §The two-level merge.** Covers:
  - the levels and who merges each;
  - the protected list;
  - why `--match-head-commit` is used;
  - the person's PR from `collection/<epic>` into `development`, reviewed as a
    whole.
- **`references/coordination.md` §Closing package issues.** Covers:
  - the default-branch closing rule;
  - the label, not the issue, carries the state;
  - checkboxes are ticked when the merge is reported;
  - the integration PR lists `Closes #N` for every package. A level-1 merge
    commit carries the PR title, not its body, so the package PRs' keywords
    never reach the default branch.

## Next

- C0.2 (#191) writes `merge.js`. The docs here describe the
  `gh pr merge --merge --match-head-commit` call that package adds.
- R0.1 (#174) also touches `sync-cells.sh`. Whichever PR lands later rebases.

## Plan check

Package issue still matches: yes
