# BLOCKER: H0.4 — six suites outside the lane read stub files without waiting

**Bucket:** on a decision
**Kind:** human-decision
**Reference:** #183 (scope of work, last bullet), #182
**Owner:** the coordinator
**Un-blocks when:** a package exists whose `allowedPaths` cover the six suites below, or #183's lane is widened to cover them

The in-lane work is done: the stub delay, the two helpers and the waits in the
four lane suites are on this branch. This blocker covers only what #183 says to
do when an out-of-lane suite has the race: record it here.

## What was needed, and why

Each site below reads a file the claude stub writes, straight after a
`fleet cycle --apply` that spawned the stub detached. Nothing in between waits
for the file. It is the same race H0.4 fixes in the four lane suites, so these
suites fail on a slow host or under `CLAUDE_STUB_DELAY`:

- `plugins/fleet/tests/ci-preconditions.test.sh:169`: `cat T1.1.*.argv` after the launch at :167
- `plugins/fleet/tests/instructions-leak.test.sh:135`: `cat T1.5.*.argv` after the launch at :133
- `plugins/fleet/tests/instructions-leak.test.sh:147`: `cat T1.6.*.argv` after the launch at :145
- `plugins/fleet/tests/verify-config.test.sh:101-102`: `cat V1.1.*.argv` and `V1.2.*.argv` after the launch at :98
- `plugins/fleet/tests/verify-stage.test.sh:195-196`: `assert_file` and `cat T1.2.2.argv` after the cycle at :190. The first `wait_exit 12-2` is later, at :207.
- `plugins/fleet/tests/v4-gate.test.sh:93`: `started` (from `ls claude-log`) after the launch at :87
- `plugins/fleet/tests/cycle.test.sh:165`: `cat T1.1.1.argv` and `T1.1.1.env`. The first `wait_exit 10-1` is later, at :184.

The fix at each site is one line: `wait_for_file <glob>` before the read, or
`wait_for_count "$TMP/claude-log" '*.argv' 2` for v4-gate:93. The helpers are
in `plugins/fleet/tests/lib.sh` on this branch. None of these suites is in
`allowedPaths`.

## Alternatives searched

- Edit the six suites in this package: they are outside `allowedPaths`, and the contract forbids widening the lane.
- Have the stub write its argv file before the fleet returns: the fleet spawns it detached. The ordering lives in `plugins/fleet/src/**`, which is forbidden here, and it would fix the tests by changing the product.
- Leave them as they are: they fail under `CLAUDE_STUB_DELAY=3` and on slow hosts, which is the defect #183 records.

## The ask

H0.4-B1: How should the six suites above get the waits? (a) a follow-up package whose lane is those six files; (b) widen #183's lane and re-dispatch : (a), because the change is mechanical and the helpers merge with this PR : decide-by this PR's merge : cost-of-waiting `bash scripts/test.sh` can still fail on macOS through these suites, so #182's Phase 0 goal stays unmet
