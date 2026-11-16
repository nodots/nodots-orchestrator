# HANDOFF: I0.2 — the Agent-Assisted trailer, and a CI check that refuses AI identity

Attempt 3. Every item in the package is done. The PR is open as `[READY]: I0.2`.

## Done
- **Setting.** `attribution.commit`, documented at https://code.claude.com/docs/en/settings-reference.md#attribution-commit. Custom text replaces the default `Co-Authored-By` trailer. `.claude/settings.json:2-4` sets it to `Agent-Assisted: yes` (the coordinator made the commit, b842c0a, under decision I0.2-settings (a)). The permissions and hooks keys are unchanged.
- **Script.** `scripts/check-commit-identity.sh` checks each commit's author and committer, every trailer in git's trailer block, and any `Co-Authored-By:` line elsewhere in the message.
- **Tests.** `scripts/tests/check-commit-identity.test.sh` passes 55 of 55 checks. In attempt 2 they were written before the change, and 8 failed against attempt 1's script.
- **CI.** At `.github/workflows/ci.yml:22-27`, on `pull_request`, the script runs over the PR's base and head shas.
- **Doc.** `working-agreements.md` has the paragraph "Commits carry a human identity".
- **Fleet scope commit.** The scope commit was re-authored (3ceb214, Ken Riley) under decision I0.2-fleet-commit (a). `bash scripts/check-commit-identity.sh origin/development HEAD` prints `OK  9 commit(s) … carry no AI identity or trailer.`
- `bash scripts/test.sh` ends `ALL PASS`.

## Next
- Review and merge. A push after the VERIFIED stamp voids it, so re-run the checks and re-stamp.

## Plan check

Package issue still matches: yes
