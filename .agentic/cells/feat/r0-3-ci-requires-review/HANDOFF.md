# HANDOFF: R0.3 CI stamp check requires the review stamps the manifest asks for

## Done
- `scripts/tests/check-stamp.test.sh`: review-policy cases written first. Against the old `check-stamp.js` they ran 32 checks, 11 failed: policy short, same reviewer twice, review at an old head, invalid manifest, invalid policy, and the missing-stamp messages.
- `scripts/check-stamp.js`: reads `manifest` (the raw text of the base branch's `.claude/standards.json`, or null) from its input file. It judges `review` with `validateReview` from `check-standards.js`, the same as `sync-cells.sh`. With a policy it requires `reviewMet(policy, currentReviews(pr))` from `stamp.js` as well as the VERIFIED stamp. On failure it prints `REVIEWED <found|none> @ <head>; the review policy needs N reviews, missing M`. A manifest that is not JSON, or a policy that fails validation, fails the check; it does not pass it. When `manifest` is absent or null, the check behaves as before.
- `.github/workflows/stamp-check.yml`: the collect step adds `baseRefName`, fetches the manifest at the base ref (a 404 means no manifest, and any other error stops the step), and writes `manifest` into `pr.json`. The header and the 404 detection match `sync-cells.sh:403-406`. The job name is unchanged.

## Not verified
- The live `gh api` fetch could not be exercised in the worker session (approval denied). The first CI run on the PR exercises it.

## Next
- Review and merge. This repo does not adopt a `review` policy in this package (issue #176, Dependencies).

## Plan check

Package issue still matches: yes
