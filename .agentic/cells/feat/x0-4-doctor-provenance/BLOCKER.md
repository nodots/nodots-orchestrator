# BLOCKER: X0.4 — the required coordinators WARN breaks doctor-allow-rules.test.sh, which must pass unchanged

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** #246 (acceptance criteria 5 and 6)
**Owner:** the coordinator
**Un-blocks when:** #246 records which of the options below to take

## What was needed, and why

The doctor section is implemented and its test passes
(`bash plugins/fleet/tests/doctor-provenance.test.sh`: `--- 27 checks, 0 failed`;
against the pre-change tree it was `--- 25 checks, 15 failed`).

Two acceptance criteria conflict:

- AC5: "Without `coordinators`, doctor prints the `WARN` line", text
  `WARN  coordinators: not set; fleet trusts agent-ready, cell:* and worker:* from any account`.
- AC6: "`plugins/fleet/tests/doctor-allow-rules.test.sh` passes unchanged".

`doctor-allow-rules.test.sh` writes a config with no `coordinators`
(`plugins/fleet/tests/doctor-allow-rules.test.sh:64-72`) and counts every stdout line
matching `^WARN` exactly (`:79`, `:86`, `:101`, `:115`). Doctor's `warn()` writes to
stdout (`plugins/fleet/bin/fleet.js:218`). With the new line, `bash scripts/test.sh`
reports:

```
FAIL  plugins/fleet/tests/doctor-allow-rules.test.sh  --- 26 checks, 4 failed
  FAIL  A: narrow rules draw no WARN line
        expected empty, got [WARN  coordinators: not set; fleet trusts agent-ready, cell:* and worker:* from any account]
  FAIL  B: two WARN lines   expected [2], got [3]
  FAIL  C: five WARN lines  expected [5], got [6]
  FAIL  E: no settings file on the branch draws no WARN line  (same line)
```

The test file is outside `allowedPaths`, and AC6 says it does not change.

## Alternatives searched

- Write the coordinators WARN to stderr. That test runs `fleet doctor 2>/dev/null`, so it
  would pass unchanged. But every other doctor line goes to stdout, so an operator piping
  doctor would lose this one. It changes the channel to get around a test, and the
  package doesn't decide that.
- Change the WARN text so it doesn't start with `WARN`. That breaks AC5's exact text.
- Leave the WARN out when there are no coordinators. That breaks AC5.
- Edit `doctor-allow-rules.test.sh` (add `"coordinators": ["coordinator"]` to its config,
  or count only allow-rule WARN lines). The file is outside `allowedPaths`, and AC6 says
  it stays unchanged.

## Separate, environmental (not caused by this change)

`scripts/tests/check-secrets.test.sh` (4 failed) and `scripts/tests/gate-h-hardening.test.sh`
(3 failed) fail on this darwin host. `scripts/check-secrets.sh:31` pins
`gitleaks_8.30.1_linux_x64`, and on Darwin it exits `126: Exec format error`. These tests
don't touch `fleet.js` doctor, and they will pass on the Linux CI runner. They still stop
`bash scripts/test.sh` from ending `ALL PASS` on this host.

## The ask

X0.4-D1: How do AC5 and AC6 both hold? Options: (a) widen the lane to
`plugins/fleet/tests/doctor-allow-rules.test.sh` and change AC6 to "passes with
`coordinators` set in its fixture config"; (b) send the coordinators WARN to stderr;
(c) drop the WARN when `coordinators` is unset. : recommend (a). The allow-rules test
counts every WARN line, and any new doctor WARN will collide with it. Setting
`coordinators` in its fixture is a one-line change that keeps its intent. : decide-by
before X0.4 is redispatched : cost-of-waiting X0.4 (#246) does not merge.
