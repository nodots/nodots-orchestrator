# HANDOFF: H0.6 — test.sh checks the installed hooks and contract

## Done

- `scripts/test.sh`: new section "installed worker hooks and contract match the
  plugin copies", right after "hook copies are byte-identical". For each
  `plugins/agentic-work-packages/hooks/*.js`, a copy in `.claude/hooks/` must be
  byte-identical. `enforce-scope.js` and `require-handoff.js` must be installed,
  matching the list in `.github/workflows/ci.yml`'s step. Any other installed
  plugin hook (today `standards-preamble.js`) is compared too.
  `.claude/worker-contract.md` must exist and match `assets/worker-contract.md`.
  Each file gets one `PASS` or `FAIL` line. The header list is renumbered 1–6.
- `scripts/tests/test-sh.test.sh`: the fixture now installs both worker hooks
  and the contract. New cases cover a healthy tree, a differing and a missing
  installed hook, a differing installed non-required hook, and a differing and a
  missing contract. The "no hooks" case now removes every plugin hook and checks
  for the empty-glob message.
- Failing tests came first: before `test.sh` changed, the fixture test ran
  36 checks with 14 failed, all of them the new cases.

## Next

- Follow-up (not this package): once I0.2 (#180) merges, remove the
  "Installed worker hooks and contract match the plugin copies" step from
  `ci.yml`, because `test.sh` now covers it.

## Resume notes

- Full `bash scripts/test.sh` takes more than 10 minutes on this host. Run it
  in the background.

## Plan check

Package issue still matches: yes
