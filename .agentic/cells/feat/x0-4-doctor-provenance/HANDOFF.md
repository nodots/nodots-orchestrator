# HANDOFF: X0.4 fleet doctor label provenance

## Done
- `plugins/fleet/bin/fleet.js`: doctor section after the label checks (attempt 1, commit 2b3a134): WARN when `coordinators` unset (no timeline read), FAIL when fleet's gh login is not a coordinator, one FAIL per foreign `agent-ready`/`cell:*`/`worker:*` label on every open host-repo issue with ` (outside epic #<n>)`, a FAIL per unreadable timeline, else the `ok` line. Header line lists "label provenance".
- `plugins/fleet/tests/doctor-provenance.test.sh`: 27 checks. Failed against the pre-change tree (25 checks, 15 failed, attempt 1). Attempt 2 replaced a vacuous assertion (`"timeline acme/host 1$"` was matched as a literal substring) with `grep -x`.
- `plugins/fleet/tests/doctor-allow-rules.test.sh` (X0.4-D1): `"coordinators": ["coordinator"]` in the fixture config. It also needs a `timeline.json` fixture recording that `coordinator` applied #10's labels. Without it, X0.3's cycle holds #10 as labeled by an unknown account, and section D ("the dry run still launches") fails. Assertions unchanged. Before: 26 checks, 4 failed; config only: 1 failed (D); both: 0 failed.
- Independent review: no correctness defects found beyond the vacuous assertion.
- Known nit, left as is: when the issue list cannot be read and coordinators is set, doctor prints two FAIL lines for one cause (provenance "not checked" plus the existing `issue list` FAIL).

- Rework after coordinator review on PR #263 (attempt 3): doctor's login check (`plugins/fleet/bin/fleet.js`, the `fleet's gh login ... is not in coordinators` line) compares lowercased on both sides, as X0.3b (#262) does; it does not depend on #262. Test first: `coordinators: ["Coordinator"]` with stub login `coordinator` failed before the fix (33 checks, 1 failed), passes after (33 checks, 0 failed). `provenance.foreign` in `plugins/fleet/src/` is still case-sensitive on this branch; that is #262's, and `src/` is outside this lane.
- Minor test additions: unreadable login (a gh wrapper failing only `gh api user`) is a FAIL with the error and a non-zero exit; C2 and D assert a non-zero exit; E with `coordinators: []` asserts no timeline is read.

## Next
- Nothing beyond review and merge. Per X-B1 on #242, the gitleaks failures on darwin arm64 are not a blocker; CI `Fixture tests` is the full-suite evidence. PR #263 carries the VERIFIED: ci-pending stamp for the head.

## Plan check

Package issue still matches: yes
