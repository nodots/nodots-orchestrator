# HANDOFF: R0.1 review policy, the REVIEWED stamp, cell:awaiting-reviewer

## Done
- Failing tests first, committed alone (ae63682). Against the pre-change tree,
  `check-standards.test.sh` failed 7 of 94 and `sync-cells.test.sh` 19 of 116.
- `assets/scripts/check-standards.js`: optional top-level `review`
  (`passes` ≥ 1, 1 ≤ `families` ≤ `passes`). `null` is the same as absent, and
  absent normalizes to `review: null`. This had to be so, because the existing
  check "a normalized manifest is itself valid" re-validates the output.
  `validateReview(review)` is exported so the sync judges the key by the same
  rules without a tracked file list.
- `assets/scripts/stamp.js`: `REVIEW_STAMP`, `currentReviews(pr)` (head sha
  only, first stamp per reviewer name wins), `reviewMet(policy, reviews)`.
- `assets/scripts/sync-cells.sh`: rule 2 now splits on the policy. The collector
  reads `.claude/standards.json` from the default branch (no `ref`), and only for
  repos with an open PR that carries a current VERIFIED stamp, so other runs make
  no extra call. A 404 means no policy. Any other read error exits 70. A policy
  with a defect, or an unparsable manifest, exits 78 and names the repo and the
  defect. The policies are recorded in the state as `reviewPolicies`, keyed by
  repo.
- `bootstrap-github-labels.sh`: `cell:awaiting-reviewer`.
- `references/standards.md`: the key, its validation rules, the reader row and
  the normalized order. `references/working-agreements.md`: a new subsection,
  "The review stamp", under §Evidence is stamped to a sha. The issue calls that
  section "§Evidence stamps".

## Outside this lane, for the coordinator
- `assets/standards.schema.json` has `additionalProperties: false`, so it now
  rejects a manifest that the validator accepts. No test reads the schema.
  standards.md says this file governs, so the schema is a defect until a
  package adds `review` to it.
- `references/adapter-github.md` (label table, line 37 and the derivation table
  near line 120) and `docs/developer-guide.md` (around line 140) do not list
  `cell:awaiting-reviewer` yet.
- `plugins/fleet` (cycle/report) has no case for the new label yet. That is
  presumably R0.2 or R0.3.

## Next
- **Blocked**: see `BLOCKER.md` beside this file. `bash scripts/test.sh` at
  b68ca39 ends `FAILED`. The fleet gh stub answers the new manifest read with
  `[]`, and 32 fleet verify checks and 2 v0-gate checks fail. The stub fix is in
  `plugins/fleet/**`, which this lane forbids.
- Once the stub answers `contents/.claude/standards.json`, re-run
  `bash scripts/test.sh`, then open the `[READY]: R0.1` PR against `development`
  with "Closes #174" in the body, and stamp it. No PR is open yet.
- After merge: R0.2, R0.3 and RV depend on this.

## Plan check

Package issue still matches: yes
