# BLOCKER: R0.3 — R0.1 is not merged, and the workflow does not give the check the base branch's manifest

**Bucket:** blocked on a merge
**Kind:** tracked-task
**Reference:** #174 (R0.1, itself blocked: `.agentic/cells/feat/r0-1-review-policy-and-stamp/BLOCKER.md` on `origin/feat/r0-1-review-policy-and-stamp` @ cb40fb6); #176
**Owner:** the coordinator
**Un-blocks when:** R0.1 merges into `development` with `currentReviews` and `reviewMet` exported from `stamp.js`, and the ask below (R0.3-input) is decided

## What was needed, and why

1. **The stamp API.** The issue says to call `reviewMet(policy, currentReviews(pr))`
   "from `stamp.js`". On `development` (0db1f65), `stamp.js` exports only
   `STAMP` and `currentStamp`
   (`plugins/agentic-work-packages/skills/agentic-work-packages/assets/scripts/stamp.js:18`).
   The functions exist only on the R0.1 branch (`stamp.js:22`, `:38`, `:44` at
   cb40fb6). That branch has no PR, and it is stopped on its own blocker: its
   `sync-cells.sh` read turns the fleet tests red (`bash scripts/test.sh` ends
   `FAILED` at b68ca39). `plugins/**` is in this lane's `forbiddenPaths`, so I
   cannot add the functions here, and `scripts/test.sh` cannot end `ALL PASS`
   until they land.

2. **The input.** The issue says to read `.claude/standards.json` "from the
   PR's base branch". The check gets only `{title, headSha, comments}`
   (`scripts/check-stamp.js:5`), built by `.github/workflows/stamp-check.yml`
   ("Collect title, head sha and comments"). That step does not fetch
   `baseRefName`. The check step has no `GH_TOKEN`. `actions/checkout@v4` is a
   depth-1 checkout of the merge ref on `pull_request`, so the base branch is
   not in the clone. The working tree is not a substitute. On `pull_request` it
   holds the PR's own `standards.json`, so a PR could delete the policy that
   gates it. `.github/**` is in `forbiddenPaths`.

## Alternatives searched
- Copy `currentReviews`/`reviewMet` into `check-stamp.js`. This makes a second
  definition of the review stamp. `check-stamp.test.sh:56` enforces one
  definition of the `VERIFIED` stamp for this reason, and the issue names
  `stamp.js` as the source.
- Build on top of `origin/feat/r0-1-review-policy-and-stamp`. This PR would
  then carry R0.1's unreviewed diff and its red `scripts/test.sh`, so it could
  not be `[READY]`.
- Read the manifest from the checked-out working tree. On `pull_request` that
  is the PR's own copy, not the base branch's, and a PR could switch off its
  own gate. This is a fallback that gives a different answer, which contract §4
  forbids.
- Call `gh api .../contents/.claude/standards.json?ref=<base>` from
  `check-stamp.js`. The check step has no token and no base ref, and both are
  set only in the forbidden workflow.
- Treat a missing manifest input as "no policy". This is the same forbidden
  fallback: a repo with a policy would pass CI unenforced.

## The ask
R0.3-input: how does the check get the base branch's manifest? Options:
(a) widen R0.3's issue and SCOPE.json to `.github/workflows/stamp-check.yml`.
The collect step adds `baseRefName`, then fetches
`gh api repos/$GITHUB_REPOSITORY/contents/.claude/standards.json?ref=<base>`
(raw; a 404 means no manifest), and writes it into `pr.json` as `manifest`
(`null` when absent). `check-stamp.js` stays a pure function of its input file,
as it is today, and the tests feed it fixtures.
(b) cut the workflow change as its own package, which R0.3 depends on.
(c) give `check-stamp.js` the job of fetching, which still needs the workflow
to pass a token and the base ref. :
recommend (a): keeping the check offline-testable is how `check-stamp.test.sh`
already works, and the workflow change is about five lines in one step. :
decide-by R0.1 merging :
cost-of-waiting R0.3 is stalled, and CI does not enforce any `review` policy
that a repo adopts.

R0.1-merge: nothing to decide here. R0.3 resumes once R0.1 is on
`development` and R0.3-input is decided.
