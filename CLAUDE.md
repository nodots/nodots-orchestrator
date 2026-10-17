# Project instructions

Use American spelling: color, center, organize.

## Test

One command runs everything CI runs, including the node tests under `evals/`. It exits non-zero on any failure, and on a test glob that matches nothing:

```
bash scripts/test.sh
```

Healthy output ends like this (tail of a real run; one `PASS` line per test file):

```
PASS  scripts/tests/test-sh.test.sh  --- 22 checks, 0 failed
=== eval tests (node, no model calls) ===
PASS  evals/tests/contract-option.test.js  --- 13 checks, 0 failed
PASS  evals/gates/v2-degraded-contract.test.js  --- 15 checks, 0 failed
ALL PASS
```

## Rules

- **Branch.** The default branch is `development`. Never commit on it; work on a feature branch and open a PR.
- **Hook copies.** `plugins/agentic-work-packages/hooks/*.js` and `plugins/agentic-work-packages/skills/agentic-work-packages/assets/hooks/*.js` stay byte-identical. `scripts/test.sh` checks it.
- **Plugin references govern docs.** The plugin `references/` govern `docs/`.

## Where intent and spec live

The playbook's Plan and Design stages commit an `intent.md` and a `spec.md` to version control. This repo keeps those artifacts in the tracker.

- The epic is the intent artifact: Context, Success criteria, Out of scope.
- Each package issue is the spec and the plan: goal, scope of work, `SCOPE.json`, acceptance criteria, dependencies.
- The tracker issue is the single source of truth. No `intent.md` or `spec.md` is kept in git.
- An intent or spec restated in a file in git is a copy, and the issue governs.
- A change of scope is an edit to the package issue, not to a file.
