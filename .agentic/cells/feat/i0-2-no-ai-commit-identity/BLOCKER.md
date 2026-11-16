# BLOCKER: I0.2 — held by the coordinator: agent provenance is undecided

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** #180; epic #178
**Owner:** Ken Riley
**Un-blocks when:** #180 is re-cut with the decision on how a commit records that an agent wrote it, and this file is removed

## What was needed, and why
Ken held I0.2 on 2026-11-16 while it was running.

As filed, I0.2 removes every AI trailer and records nothing in its place, so history would show only a human for work an agent wrote. AIQT `integ-commit-identity` requires a human as the accountable author.

Open question: can provenance still be recorded, for example with a `Fleet-Session: <id> (#<issue>)` trailer? Ken will settle this with Jeff Posluns before the package continues.

## Work kept
The worker was stopped mid-run. Its uncommitted files are committed on this branch as they stood, untested:
- `scripts/check-commit-identity.sh`
- `scripts/tests/check-commit-identity.test.sh`
- `.github/workflows/ci.yml`
- `references/working-agreements.md`

## The ask
I0.2-provenance:
- (a) A human author, plus a provenance trailer that names no model or vendor.
- (b) A human author, with no provenance in git; provenance goes in the PR and the epic only.
- (c) Agents commit as agents, and the AIQT rule is not adopted.

Recommendation: (a). Decide after Ken and Jeff talk. Cost of waiting: new commits keep their AI trailers.
