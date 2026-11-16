# BLOCKER: I0.2 — the worker cannot write `.claude/settings.json`, and the branch carries a `fleet` commit

**Bucket:** blocked on a missing capability
**Kind:** human-decision
**Reference:** #180; epic #178; commit `d0ee464` on `feat/i0-2-no-ai-commit-identity`
**Owner:** Ken Riley (coordinator)
**Un-blocks when:** `.claude/settings.json` on this branch sets `"attribution": {"commit": "Agent-Assisted: yes"}`, `d0ee464` is no longer in `development..feat/i0-2-no-ai-commit-identity` with a `fleet` identity, and this file is removed

## What was needed, and why

Everything else in the package is done and tested on this branch (see `HANDOFF.md`). Two acceptance criteria are still open, and neither can be closed from inside the lane.

1. **The setting.** The Claude Code setting is `attribution.commit`. Evidence: https://code.claude.com/docs/en/settings-reference.md#attribution-commit says "Set the attribution text Claude Code adds to git commits, including any trailers", with a default of `Co-Authored-By: <name> <noreply@anthropic.com>`. The deprecated `includeCoAuthoredBy` is ignored once `attribution.commit` is set. `.claude/settings.json` is in `allowedPaths`, but the harness denied the `Edit`: "Claude requested permissions to write to .../.claude/settings.json, but you haven't granted it yet". This session has no approval surface. Writing the file through a shell redirect would route around a permission denial, which the contract (§1) forbids. The change is one key, with every existing key kept:

   ```json
   "attribution": {
     "commit": "Agent-Assisted: yes"
   },
   ```

   It goes at the top of the object, before `"permissions"`. Until it lands, the check `.claude/settings.json sets attribution.commit to Agent-Assisted: yes` in `scripts/tests/check-commit-identity.test.sh` fails (1 of 55 checks), so `bash scripts/test.sh` cannot end `ALL PASS`. The test is right and the tree is not.

2. **This PR's own commits.** `d0ee464 I0.2: scope` was authored and committed as `fleet <fleet@nodots.invalid>`. Per #180 the new CI step fails it, so the acceptance criterion "This PR's own commits pass the check" cannot hold while that commit sits in the PR's range. Removing it means rewriting a coordinator commit on a pushed, shared branch and force-pushing, which this package does not authorize.

## Alternatives searched
- Write `.claude/settings.json` with `node`/`cat >` from Bash — routes around the harness denial; forbidden by the worker contract §1.
- Put the setting in `.claude/settings.local.json` — outside `allowedPaths`, not committed, so it would not reach other workers.
- Relax the test to skip the settings assertion — relaxes an assertion until it holds; forbidden by §5.
- Exempt `fleet` commits made by the coordinator from the check — contradicts #180's first failure rule, and is a design decision the package does not make.
- Rebase `d0ee464` under the human identity and force-push — rewrites shared history without authorization.

## The ask
I0.2-settings: apply the one-key change above to `.claude/settings.json` on this branch, either (a) by hand, or (b) by re-dispatching with write approval for that file : recommend (a), it is four lines : decide-by the next coordinator cycle : cost-of-waiting worker commits keep the `Co-Authored-By` trailer, and #180 cannot go `[READY]`.

I0.2-fleet-commit: how should the PR's range lose the `fleet` scope commit? (a) Re-author `d0ee464` as the human and force-push the branch. (b) Squash-merge, and run the check over the squash commit instead of the PR's commits. (c) Accept this one PR red on that commit, and re-cut the AC to "commits this package's worker adds". : recommend (a), and have the coordinator commit SCOPE.json under the human identity from now on, as I0.1 intends : decide-by the next coordinator cycle : cost-of-waiting the CI step stays red on this PR.
