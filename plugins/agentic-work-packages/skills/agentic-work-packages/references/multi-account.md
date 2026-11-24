# Multiple accounts: one coordinates, the others implement

Use this when more than one Claude account is available and one of them should
run the coordinator role while the rest do the implementing. The coordinator
rules in `coordination.md` are unchanged. This file adds how work reaches a
worker that is on a different account.

## The tracker is the bus

**No account launches, signals or reads another account's session.** The
coordinator account writes to the tracker; each worker account reads the
tracker. Nothing else passes between them.

This is the same principle as derived labels: state that lives in the tracker
and the PRs survives a compaction, a usage limit, a closed laptop and a worker
that never comes back. State that lives in one session's memory, or in a
process one account holds a handle on, does not.

| Role | Does | Never does |
|---|---|---|
| Coordinator account | runs `sync-cells.sh`, promotes packages to `cell:queued`, runs `assign-cells.sh`, logs the wave, resolves `BLOCKER.md` | writes feature code, as in `coordination.md` §The coordinator |
| Worker account `<id>` | works only packages labeled `worker:<id>`, one worktree and one PR each | assigns itself work, files an issue, changes any `cell:*` or `worker:*` label; `require-coordinator.js` refuses these when `FLEET_WORKER_ID` is set |

## The `worker:<id>` label

`worker:<id>` says which account owns a package. `<id>` is a short name the
operator picks (`a`, `b`, `kenr`) and is the suffix of the label.

- **Only the coordinator writes it**, through `assets/scripts/assign-cells.sh`.
  A worker that labels its own package has self-promoted, which the GitHub
  adapter already forbids for `cell:*`.
- **A package has at most one.** Two worker labels on one package is two owners,
  which is how two accounts end up on one branch. `assign-cells.sh` flags it and
  assigns nothing to it until a person resolves it.
- Create the labels once per repo:
  `assets/scripts/bootstrap-github-labels.sh <owner>/<repo> <program-label> a b`.

## The coordinator cycle

Added to the cycle in `coordination.md`, after the labels are synced and
dependencies promoted:

```bash
# what would be assigned
assets/scripts/assign-cells.sh --repo <owner>/<host-repo> --workers a,b

# write it
assets/scripts/assign-cells.sh --repo <owner>/<host-repo> --workers a,b --apply
```

Dry run is the default. `--state <file.json>` runs the same derivation over a
saved state file, which is how the fixture test covers every rule offline.

Candidates are open packages that are `agent-ready`, `cell:queued` and
unassigned. They are taken in issue-number order and each goes to the worker
with the lowest load, ties to the worker listed first in `--workers`.

**Load is what is in flight**: `cell:active`, or `cell:queued` with a worker
label already on it. The second half is deliberate. An assigned package whose
worker has not started yet still holds a slot; leaving it out hands the same
slot to someone else on the next cycle.

**`--wip-cap` bounds the fleet, not each account.** Four in flight across all
workers by default, for the reason `coordination.md` §Waves and the WIP cap
gives: it is about what one reviewer can hold, not about compute.

Holds, all reported with their reason rather than dropped:

- the fleet is at the cap;
- a `cell:contract-change` package is in flight, so nothing else is assigned;
- a `cell:contract-change` candidate is next and the fleet is not empty. It and
  everything after it are held so the fleet drains, because otherwise a steady
  supply of small packages starves it forever;
- a `cell:contract-change` candidate is next and the fleet is empty. It is
  assigned alone.

Log the wave as before: which packages went to which worker, and which
dependency clearing let them go.

## The worker cycle

A worker session is told its id when it is launched. Then:

```bash
gh issue list --repo <owner>/<host-repo> \
  --label worker:<id> --label cell:queued --state open
```

1. Take the lowest-numbered package from that list. If the list is empty, report
   exhaustion with the counts that prove it, as the cycle contract in
   `coordination.md` requires, and stop.
2. Before creating anything, confirm no one owns the branch. `git worktree list`
   covers this machine only, and the accounts may not share one. The remote is
   the shared fact: list the remote branches and match the package id the way
   `sync-cells.sh` does, case-insensitively with `.` and `-` alike and bounded
   (`git ls-remote --heads origin | grep -iE '[^a-z0-9]m1[.-]3([^a-z0-9]|$)'` for
   package `M1.3`). A branch that already exists belongs to someone, and the
   answer is to stop and tell the coordinator.
3. Work it under the worker contract: one worktree, one `SCOPE.json`, one PR.
4. Do not touch a package carrying another account's label, even if it looks
   idle.

The claim is the pushed branch. On the next `sync-cells.sh` run it reads as
`cell:active`, which the coordinator, not the worker, writes.

## Reassignment

A package is reassigned by removing its `worker:*` label and letting the next
`assign-cells.sh` run place it, or by setting the label by hand.

- **Branch does not exist yet:** reassign freely. Nothing has been spent.
- **Branch exists:** this is an escalation, not an edit. Treat it as the
  re-dispatch in `coordination.md` §The coordinator. Log the reassignment in the
  progress log with the reason, and do not hand the branch to the new account
  until the old one is confirmed stopped. A worker that is merely out of usage
  has not stopped; it will resume. The takeover rules in
  `coordination.md` §Isolation (detached worktree, explicit
  `--force-with-lease`) apply unchanged.

An account that hits its usage limit produces no movement, which the cycle
contract already covers: three consecutive cycles with none, stop and report.

## What this does not enforce

| Field | Value |
|---|---|
| **Default** | convention: a worker acts only on packages with its own label |
| **Fail posture** | `assign-cells.sh` refuses to assign from a truncated collection and exits non-zero when a label write fails |
| **Residue** | nothing stops a worker from working a package labeled for another account; nothing verifies that a session launched as worker `a` is actually logged into the account the operator means by `a`; a worker's `Edit`/`Write` scope is still enforced only by `enforce-scope.js` |

The residue is why the reviewer reads the PR against the label at review time,
the same way the scope hook's residue is read against `allowedPaths`. Binding
an id to an account is the operator's job at launch.

## Measuring

Judge the arrangement per merged package and per passed gate, per account, never
per day. A second account makes cost per day rise whenever it is used at all.
No spend or token numbers belong in `SCOPE.json` or in the labels.
