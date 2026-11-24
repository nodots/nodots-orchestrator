# HANDOFF: X0.4 fleet doctor label provenance

## Done
- `plugins/fleet/bin/fleet.js`: doctor section after the label checks (attempt 1, commit 2b3a134): WARN when `coordinators` unset (no timeline read), FAIL when fleet's gh login is not a coordinator, one FAIL per foreign `agent-ready`/`cell:*`/`worker:*` label on every open host-repo issue with ` (outside epic #<n>)`, a FAIL per unreadable timeline, else the `ok` line. Header line lists "label provenance".
- `plugins/fleet/tests/doctor-provenance.test.sh`: 27 checks. Failed against the pre-change tree (25 checks, 15 failed, attempt 1). Attempt 2 replaced a vacuous assertion (`"timeline acme/host 1$"` was matched as a literal substring) with `grep -x`.
- `plugins/fleet/tests/doctor-allow-rules.test.sh` (X0.4-D1): `"coordinators": ["coordinator"]` in the fixture config. It also needs a `timeline.json` fixture recording that `coordinator` applied #10's labels. Without it, X0.3's cycle holds #10 as labeled by an unknown account, and section D ("the dry run still launches") fails. Assertions unchanged. Before: 26 checks, 4 failed; config only: 1 failed (D); both: 0 failed.
- Independent review: no correctness defects found beyond the vacuous assertion.
- Known nit, left as is: when the issue list cannot be read and coordinators is set, doctor prints two FAIL lines for one cause (provenance "not checked" plus the existing `issue list` FAIL).

## Next
- Blocked: see BLOCKER.md. `bash scripts/test.sh` fails only on the gitleaks tests (linux_x64 binary on a darwin arm64 host, owned by X-B1). Once that is cleared: re-run `bash scripts/test.sh`, open the `[READY]: X0.4` PR (body `Closes #246`), and post the VERIFIED stamp for the head sha.

## Plan check

Package issue still matches: yes
