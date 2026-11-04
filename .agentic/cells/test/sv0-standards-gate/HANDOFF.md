# HANDOFF: SV0 — standards gate (phase 0)

## Done
- `plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/sv0-standards-gate.test.sh`
  (written in attempt 1, commit 11359bd) asserts the five scope items of #123:
  1. valid fixture: validator exits 0; both `standards-preamble.js` copies print
     the heading, every check and the preamble, in order (lines 67-96);
  2. every `fixtures/standards/invalid-*.json`: exit 2, stderr names the defect
     from the fixture's `expect` (lines 98-111);
  3. this repo's `.claude/standards.json` validates with `--root <repo root>`, and
     `CLAUDE.md#rules` and `CLAUDE.md#where-intent-and-spec-live` resolve to
     headings (lines 113-145);
  4. the `git grep` over `plugins docs` outside tests and the `grep` over the
     contract asset print nothing, with exit 1 asserted so an erroring grep
     cannot pass (lines 147-156);
  5. `diff` of the contract asset against `.claude/worker-contract.md` is empty
     (lines 158-162).
- Attempt 2 ran the checks as decision SV0-run (on #123) specifies:
  - `bash plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/sv0-standards-gate.test.sh`
    printed `--- 69 checks, 0 failed`.
  - `bash scripts/test.sh` ended `ALL PASS`, exit 0; the gate is picked up as
    `PASS ... sv0-standards-gate.test.sh --- 69 checks, 0 failed`.

## Not done
- No mutation run proving each assertion can go red. Breaking an input means
  editing a fixture, hook, validator or contract, and all of them are forbidden
  paths for this package. The gate is a gate-verify over existing pieces, so
  there was no pre-change tree for it to fail against.

## Next
- Review and merge. Phase 1 (#124, #125, #126) is unblocked by this gate.

## Plan check

Package issue still matches: yes
