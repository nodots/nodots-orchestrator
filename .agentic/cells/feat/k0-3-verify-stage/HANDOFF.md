# HANDOFF: K0.3, the verify stage

## Done

- `plugins/fleet/src/verify.js`: the stage. `cycle.js` calls it after reap and before launch, and appends its re-dispatch requests (`next: 'verify-failed'`) to reap's requests.
- `cycle.js`: handles `verify-failed` requests at the same tier, counted toward `maxEscalations`, and raises `escalation-cap` at the cap. When the stage latches, every request is held as `retry` and nothing launches. A run in flight keeps the streak from rising. Every `verify-*` alarm except `verify-stale` forces outcome `alarm`. `counts()` adds `awaitingLab` and `verifying` only when a verify target exists.
- `report.js`: the counts and summary additions only when those counts exist, plus a `**Verify**` section when `r.verify` is non-empty.
- `tracker.js`: `prComment` (`gh pr comment --repo <target>`) and `editPrTitle` (`gh pr edit --title`).
- Stubs: `gh.js` stores comments under `<repo>#<n>`, logs `comment <repo> <n>`, handles `pr comment` and `pr edit --title`. `claude.sh` titles a PR from the prompt and adds mode `pr-update`, with an optional `CLAUDE_STUB_GATE` file wait. `verifier.js` is new.
- `tests/verify-stage.test.sh`: 90 checks. It was committed first (c5bd025), when 50 of 82 checks failed. With the stage call disabled in `cycle.js`, 50 of 82 checks fail.
- `bash scripts/test.sh` ends `ALL PASS`.

## Decisions the package did not spell out

- `fleet launch <issue>` (`FLEET_ONLY_ISSUE`) runs no verify stage. It launches only, and still counts recorded runs as live.
- Candidates come from the sync's derived rows (`to === 'cell:awaiting-lab'`), so dry runs and applied runs pick the same PR.
- A PR acted on in a cycle (stale, refused, finished, retitled) is not posted again in that cycle. That is why "the next cycle posts the same PR again" holds.
- `verify.reverted` other than `true`, including a missing value, counts as not reverted.
- A pass with a malformed `verify.headSha` records `bad-sha` at the posted head, so the PR is not re-run at that head. A fail with a malformed sha is still commented and re-dispatched.
- Alarm codes added beyond the package: `verify-post-failed` (POST answered something other than 202 or 409, such as 423 or 404, or 202 without `run.id`), `verify-write-failed`, `verify-redispatch-failed` (no closed session on this machine), and `verify-pr-missing`. All of them force `alarm`.
- When `pulls-failed` is raised for a target, the stage skips that target and keeps its record.
- A `[VERIFY]:` PR with a current stamp is retitled `[READY]:`. This recovers from a failed retitle and from a sync comment read that came back empty.

## Known, not fixed

- A POST that times out (20 s), or a 202 without `run.id`, may start a run that fleet never records. The PR is posted again after that run finishes. It cannot be stamped wrongly.
- A GET answering non-200 (for example 404 after the runner loses its runs) raises `verify-unreachable` every cycle until someone clears `state.verify.<repo>.inFlight` by hand.

## Next

- Review the PR and run the package issue's verifier restatement.

## Plan check

Package issue still matches: yes
