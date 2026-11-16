# HANDOFF: C0.2 — fleet merge stage

## Done

- `plugins/fleet/src/merge.js` (new): the merge stage. For each `autoMerge` target and
  each open package PR on it, read fresh with `gh pr view`:
  protected base → `merge-protected-refused`, nothing else read; base ≠
  `integrationBranch` → skipped; then the condition in order (stamp, `reviewMet`
  when exported, `gh pr checks` all green, `mergeable` `MERGEABLE`), first unmet
  one noted `held`; then `gh pr merge --merge --match-head-commit <checked head>`.
  A merge is movement `merged`, with the merge commit sha. A failure is `merge-failed`
  with gh's message and is not retried.
- `src/tracker.js`: `viewPull`, `prChecks` (reads the JSON on gh exit 1/8 as well),
  `mergePr`.
- `src/cycle.js`: stage 4d after review, before launch; skipped under
  `FLEET_ONLY_ISSUE` and when verify latched. `merge-protected-refused` is an
  alarm even beside movement (joins `VERIFY_FAULT`).
- `src/report.js`: **Merged** section (merged / would-merge) and a **Not merged** section
  (held / skipped / refused / failed, with the reason).
- `tests/merge-stage.test.sh` (67 checks), committed first as a failing suite
  (6ba536a; 41 of 67 failed before the change). `tests/stubs/gh.js` now handles
  `pr view`, `pr checks` (with `pushAfterChecks` to move a head after the read)
  and `pr merge` (honors `--match-head-commit`).
- A mutation check: with the protected and base checks disabled in merge.js,
  section C fails 16 checks.
- README and SKILL.md document the condition, the protected list,
  `--match-head-commit` and the branch-protection residual.

## Decisions a reviewer should know

- "None reported" from `gh pr checks` counts as not green. That is conservative.
  A target with no CI never auto-merges.
- Only PRs the sync matched to the epic's packages are considered, never other
  PRs on the target.
- A PR whose base is neither protected nor the integration branch is skipped
  with a note. It raises no alarm.

## Next

Nothing in this package. R0.1's `reviewMet` is already exported by `stamp.js` on
`development`, so the review check runs. The no-`reviewMet` path is covered by a
test with a stand-in `stamp.js`.

## Plan check

Package issue still matches: yes
