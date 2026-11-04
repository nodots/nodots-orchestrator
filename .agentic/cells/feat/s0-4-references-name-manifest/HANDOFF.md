# HANDOFF: S0.4 — References, SKILL.md and docs name the manifest

## Done

- Checklist closers now read `- [ ] Every check in \`.claude/standards.json\` passes`:
  `references/cell.md` (standing closers and template), `references/gate.md`
  (template), `references/epic.md` (Definition of done), `docs/agentic-work-packages.md`
  (worked package example).
- `references/merge-procedure.md` step 4 runs the changed package's manifest checks,
  then each dependent's, in manifest order; the record-keeping entry lists checks by
  their manifest names.
- `references/cross-repo.md` §2 and §6: each repo runs its own manifest checks, before
  commit and after the chain merges.
- `references/adapter-github.md` stamp example runs `<check command>`.
- `references/working-agreements.md` §Adding these to a plan and `docs/working-agreements.md`
  §13 carry the same new bullet, word for word: every target repo publishes
  `.claude/standards.json` and the planner reads its `rules[]` for a lane first.
- `SKILL.md` step 7 installs the manifest with the contract (`fleet standards init` or
  by hand, validated by `assets/scripts/check-standards.js`) and names the preamble
  hook `assets/hooks/standards-preamble.js`; the pre-dispatch checklist's last line
  requires a valid manifest; the files table has rows for `references/standards.md`,
  `assets/standards.schema.json`, `assets/scripts/check-standards.js`,
  `assets/hooks/standards-preamble.js`.
- `README.md`: one sentence under the skill description.

## Verified

- `git grep -n -E 'lint passes|npm run|npm test|TypeScript compiles' -- plugins docs ':!*/tests/*'`
  prints nothing.
- `bash scripts/test.sh`: see the VERIFIED stamp on the PR.

## Notes for the next session

- The four files the SKILL.md table and step 7 name are created by S0.1 (schema,
  reference, validator) and S0.2 (preamble hook). Until those merge, the table points
  at files not yet on `development`.
- `assets/worker-contract.md:121` still says "Tests, build/typecheck and lint pass".
  That file is S0.3's lane (forbidden here) and the acceptance grep does not match it.

## Plan check

Package issue still matches: yes
