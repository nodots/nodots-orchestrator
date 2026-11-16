# HANDOFF: R0.1 review policy, the REVIEWED stamp, cell:awaiting-reviewer

## Done
- Attempt 1: failing tests first (ae63682), then the families version of the
  policy (b68ca39). Blocked on the fleet gh stub; decisions R-families-dropped
  and R0.1-stub recorded on #173, lane re-cut on #174 (a3a8e80, de3fbcc).
- Attempt 2, tests first (7711b9e): the tests rewritten to the amended spec.
  Against the families code, `check-standards.test.sh` failed 5 of 94 and
  `sync-cells.test.sh` 10 of 116.
- Attempt 2, implementation (7674ac5):
  - `assets/scripts/check-standards.js`: `review` has one key, `passes`
    (integer >= 1). `families` is now `review.families: unknown key`. Absent or
    `null` normalizes to `review: null`. `validateReview` stays exported for
    the sync.
  - `assets/scripts/stamp.js`: `REVIEW_STAMP` is the issue's regex
    (`REVIEWED: <reviewer> @ <sha>`); `currentReviews` returns
    `{ reviewer, sha }`, head only, first stamp per reviewer name;
    `reviewMet` is `reviews.length >= passes`, a `null` policy met.
  - `assets/scripts/sync-cells.sh`: the reason reads
    `REVIEWED <names|none>; needs N reviews[, missing K reviews]`; the
    collected policy is `{ passes }`.
  - `references/standards.md` and `references/working-agreements.md`
    ("The review stamp"): families removed.
  - `plugins/fleet/tests/stubs/gh.js`: one case answers
    `repos/<repo>/contents/.claude/standards.json` from the remote's `HEAD`,
    else `gh: Not Found (HTTP 404)` and exit 1.

## Outside this lane, for the coordinator
- `assets/standards.schema.json` has `additionalProperties: false`, so it
  rejects a manifest with `review` that the validator accepts. No test reads it.
- `references/adapter-github.md` (label table near line 37, derivation table
  near line 120) and `docs/developer-guide.md` (near line 140) do not list
  `cell:awaiting-reviewer`.
- `plugins/fleet` (cycle/report) has no case for the new label (R0.2/R0.3?).
- The repo-root `HANDOFF.md` is G2.4's, not this package's; left untouched.

## Next
- `bash scripts/test.sh` at the head, then the `[READY]: R0.1` PR against
  `development` ("Closes #174") and the VERIFIED stamp. If the PR is open,
  check its stamp names the current head; re-run and re-stamp if not.
- After merge: R0.2, R0.3 and RV depend on this.

## Plan check

Package issue still matches: yes
