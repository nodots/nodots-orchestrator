# HANDOFF: K0.1 — targets[].verify config, and workers told to finish at [VERIFY]

## Done

- `plugins/fleet/src/config.js`: `validateVerify` checks optional `targets[].verify`
  `{kind, url, suite}`. `kind` must be `lab-runner`. `url` must be http(s) on a loopback
  host (127.0.0.0/8, `localhost`, `::1`). `suite` must match `^[A-Za-z0-9_-]+$`.
  `ci.gate` must be `external`. Each refusal is a config error that names the field.
- `plugins/fleet/src/launch.js` `buildPrompt`: a target with `verify` gets the title
  `[VERIFY]: <id>` and three lines: do not run the verifier, do not claim its lock, do not
  post a VERIFIED stamp, and paste the selection (`ci.verifiedBy` says how). The prompt does
  not contain `[READY]`. Targets without `verify` get the same prompt as before, byte for byte.
- `plugins/fleet/tests/verify-config.test.sh`: 35 checks. Before the change, 22 failed.
  After it, all 35 pass.
- README.md and skills/fleet/SKILL.md document the field and what it changes for the worker.
- `bash scripts/test.sh` ends `ALL PASS`.

## Not done / next

- `fleet.config.example.json` is unchanged. The issue does not require an example `verify`.
- No queue consumes `[VERIFY]` PRs yet. That is outside this package.
- The `verify` block is not added to the session record or the dry-run report. The issue
  does not ask for it.

## Plan check

Package issue still matches: yes
