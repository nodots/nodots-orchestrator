# HANDOFF: H0.3 — no interpreter wildcards; doctor reports broad allow rules

## Done
- `.claude/settings.json`: `Bash(node:*)` replaced by `Bash(node plugins/*)`,
  `Bash(node scripts/*)`, `Bash(node evals/*)`. Committed by the coordinator
  (a880aeb, decision H0.3-settings (a)), because the worker session cannot
  write a protected settings file. `hooks` key unchanged.
- `plugins/fleet/bin/fleet.js:55-78`: `BROAD_BINS`, `BROAD_RULE`,
  `broadAllowRules()` read `.claude/settings.json` from
  `origin/<defaultBranch>` (not the working tree).
  `plugins/fleet/bin/fleet.js:243-246`: one `WARN` line per broad rule; a
  `WARN` does not increment `bad`, so doctor's exit code is unchanged.
- `plugins/fleet/tests/doctor-allow-rules.test.sh`: 26 checks (narrow rules,
  the package fixture, both wildcard forms, near misses, launch not refused,
  missing and unreadable settings). Written first in attempt 1 (b7b587b).
- Docs: `plugins/fleet/README.md` "Allow rules"; `references/scope-contract.md`
  "Scope allow rules to the package's commands".
- Attempt 2: ran `bash scripts/test.sh` in this unattended session under the
  narrowed settings with no permission prompt; opened the `[READY]` PR and
  stamped it.

## Learned
- A compound shell command (`bash scripts/test.sh > log; echo $?`) does not
  match `Bash(bash scripts/*)` and is denied unattended. Run the check alone.

## Next
- Review and merge. Then the settings PR to the other target repo (issue #186,
  Dependencies).

## Plan check

Package issue still matches: yes
