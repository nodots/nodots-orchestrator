# HANDOFF: I0.2 — the Agent-Assisted trailer, and a CI check that refuses AI identity

Attempt 2. Stopped on `BLOCKER.md` in this directory: two open items need the coordinator.

## Done
- **Setting found.** The setting is `attribution.commit`. Its doc is https://code.claude.com/docs/en/settings-reference.md#attribution-commit. Custom text replaces the default `Co-Authored-By` trailer, and an empty string hides it. `includeCoAuthoredBy` is deprecated and is ignored once `attribution.commit` is set.
- **Tests first.** `scripts/tests/check-commit-identity.test.sh` adds these cases: `Agent-Assisted: yes` passes, a key-like body line outside the trailer block passes, `Agent-Assisted: claude` fails, and four more trailers under other keys fail (`Generated-By:`, `Assisted-By:`, `Agent-Assisted: cursor`, `Tool:`). It also asserts that `.claude/settings.json` sets `attribution.commit` and keeps its permissions and hooks. Against attempt 1's script, 8 of 55 checks failed.
- **Script.** `scripts/check-commit-identity.sh` now checks every trailer in git's trailer block (`%(trailers:only,unfold)`), plus any `Co-Authored-By:` line elsewhere in the message, against the AI name list. After the change, 54 of 55 checks pass. The one failure is the settings assertion.
- **Doc.** The `working-agreements.md` paragraph "Commits carry a human identity" covers the human author, `Agent-Assisted: yes` and why it names no model or vendor, the setting, and the check.
- **CI.** The `ci.yml` step from attempt 1 is unchanged: on `pull_request` it runs the script over the base and head shas.

## Not done (see BLOCKER.md)
- The harness denied the write to `.claude/settings.json`: it is a settings file, and this session has no approval surface. The four-line change is quoted in BLOCKER.md.
- `d0ee464 I0.2: scope` is a `fleet` commit, so this PR's range fails its own check.
- `bash scripts/test.sh` ends `FAILED`, with two reds from that one cause. `check-commit-identity.test.sh` fails 1 of 55 checks, the settings assertion. `v0-gate.test.sh` fails 2 of 11 ("clean copy: test.sh exits 0" and "prints ALL PASS") because it re-runs `test.sh` on a copy of the tree and hits the same assertion. Every other file passes.
- No PR has been opened. `[READY]` would be false while `bash scripts/test.sh` is red on the settings assertion.

## Next
1. Apply the settings change and remove `BLOCKER.md`.
2. Run `bash scripts/test.sh` and expect `ALL PASS`.
3. Make a commit through Claude Code, and show `git log --format=%B -1` carrying `Agent-Assisted: yes`.
4. Run `bash scripts/check-commit-identity.sh origin/development HEAD`. It is clean once `d0ee464` is resolved.
5. Open the PR `[READY]: I0.2 …` against `development` with `Closes #180`. Name the setting and the doc URL in the body, then stamp `VERIFIED`.

## Plan check

Package issue still matches: yes
