# HANDOFF: HV — gate suite for program H

## Done

- `scripts/tests/gate-h-hardening.test.sh` asserts the four scenarios in #187 (27 checks):
  1. **Secret.** A range that adds a runtime-built `ghp_` token in one commit and removes it in the next fails `scripts/check-secrets.sh`. The output names the adding commit and prints neither the token nor its body. A clean range passes.
  2. **Lane.** On `feat/hv-lane`, `allowedPaths` is `src/**`. An in-lane write draws nothing. After `echo x > outside.txt`:
     - `enforce-scope.js` (PostToolUse Bash) blocks, naming `outside.txt`;
     - `require-handoff.js` (Stop) blocks, naming it too, even with a valid HANDOFF.md.
  3. **Allow rules.** `Bash(docker *)` in a fixture target's settings draws a `fleet doctor` WARN that names the rule and the target. `Bash(docker ps:*)` and `Bash(git status:*)` draw none.
  4. **Race.** `CLAUDE_STUB_DELAY=3 bash plugins/fleet/tests/sv1-standards-gate.test.sh` ends `0 failed`.
- The worker wrote the suite. Its session could not run `git add` or `git commit`, or build broken copies of the tree, so it parked. Under decision HV-1 (#182), the coordinator:
  - ran the mutation check: a baseline plus 5 mutants, each failing its scenario (output on the PR);
  - committed the suite;
  - ran `bash scripts/test.sh`;
  - opened the PR.

## Next

- Program H's version bump, once this merges.

## Resume notes

- Scenario 1 needs the gitleaks archive or network. On the Ubuntu host, set `GITLEAKS_ARCHIVE=/srv/fleet-worktrees/cache/gitleaks_8.30.1_linux_x64.tar.gz`.

## Plan check

Package issue still matches: yes
