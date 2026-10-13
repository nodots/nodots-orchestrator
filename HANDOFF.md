# HANDOFF: G1.3 approval enforcement config

## Done
- `approvalEnforcement` (`off` | `branch-protection` | `ruleset`), default `off`: `plugins/fleet/src/config.js` (DEFAULTS, validate), `plugins/fleet/fleet.config.example.json`.
- `approvalGate(config, pr)` returns `{blocked, mechanism, reason}`; `approvalPayload(config)` returns the GitHub API body for each mechanism.
- README section "Approval enforcement" in `plugins/fleet/README.md`, with how to turn it on and where each mechanism is unavailable.
- Tests: `scripts/tests/approval-config.test.sh` (new, 16 checks); two added cases at the end of `plugins/fleet/tests/config.test.sh`, existing assertions untouched. Written first and run red (14 of 16 failed) before the change.

## Exploration: where project config lives
Chose `plugins/fleet/fleet.config.example.json` and `src/config.js`. They are the only config this repo ships with a loader and validator (`src/config.js:59-118`). `.claude/project.json` is referenced in `plugins/agentic-work-packages/agents/cell-worker.md` but has no loader or tracked file here, so a setting there would have no code to read it.

## Not verified
- Which GitHub plans offer branch protection and rulesets for private repos is not checked at source here. The README points to GitHub's plan table instead of asserting it. Only evidence: branch protection returned 403 on this repo (per the issue). Rulesets were not tried.
- Neither payload was sent to the GitHub API; fleet does not call these endpoints.
- `approvalGate` models the rule; GitHub does the actual blocking.

## Next
Review, merge. No enforcement is turned on for this repository.

## Plan check

Package issue still matches: yes
