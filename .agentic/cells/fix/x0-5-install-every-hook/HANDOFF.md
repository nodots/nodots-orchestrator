# HANDOFF: X0.5 (#266)

## Done

- `plugins/fleet/src/install.js:25`: `COPIES` now includes
  `['.claude/hooks/require-coordinator.js', 'hooks/require-coordinator.js']`,
  so `plan`, `apply` and `doctor` cover the hook that `settings-snippet.json`
  registers under `PreToolUse` / `Bash`.
- `plugins/fleet/tests/install.test.sh`: the header names four hooks. `FILES`
  includes require-coordinator.js. Counts: A 6 add, E 10 ok (6 files and 4
  registrations), E 6 same, F 5 same. New C checks: a bare target gets
  require-coordinator.js byte-identical to `$PLUGIN/hooks/require-coordinator.js`,
  and every `.claude/hooks/*.js` named in the snippet is on the install branch.
  This guards against the next hook added to the snippet without a COPIES entry.
- `plugins/fleet/tests/doctor-provenance.test.sh:34-45`: the fixture copies every
  `install.COPIES` file from `$PLUGIN` and copies `settings-snippet.json` as
  `.claude/settings.json`, so doctor's install checks pass.

## Evidence

- Before the fix: install.test.sh failed 8 checks (the require-coordinator
  add/doctor/byte checks and the E count), and doctor-provenance.test.sh failed
  5 of 33.
- After the fix: install.test.sh 68 checks, 0 failed. doctor-provenance.test.sh
  33 checks, 0 failed. Every `plugins/fleet/tests/*` suite PASS in `bash scripts/test.sh`.
- Local `scripts/tests/check-secrets.test.sh` and `gate-h-hardening.test.sh`
  fail with `gitleaks exited 126`. The pinned gitleaks is linux_x64
  (`scripts/check-secrets.sh:31`) and this host is Darwin. X-B1 on #242
  excuses that red, and the stamp names the CI `Fixture tests` run.

## Next

- CI `Fixture tests` and `standards` at the PR head, then coordinator review and merge.

## Plan check

Package issue still matches: yes
