# BLOCKER: S1.1 — the package's required `npm run` / `npm test` text fails the SV0 text invariant

**Bucket:** blocked on a decision
**Kind:** human-decision
**Reference:** #124 (S1.1) vs `plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/sv0-standards-gate.test.sh:148` (SV0, #123)
**Owner:** the coordinator (Ken Riley)
**Un-blocks when:** a decision on the ask below is recorded on #124, and either the gate or #124 is edited to match it

## What was needed, and why

#124 requires `draftManifest` to emit the check `{ name, command: "npm run <name>" }` for `lint`, `typecheck` and `build`, and `npm test` for `test`. The README section has to describe that behavior. The SV0 gate's text invariant forbids that same text:

```
git grep -n -E 'lint passes|npm run|npm test|TypeScript compiles' -- plugins docs ':!*/tests/*'
```

That line must match nothing. `bash scripts/test.sh` at `c401814686c32f9f5a1e83048f81a57a9d835995` ends `FAILED`:

```
FAIL  plugins/agentic-work-packages/skills/agentic-work-packages/assets/tests/sv0-standards-gate.test.sh  --- 69 checks, 2 failed
  FAIL  text: git grep ran and matched nothing (exit 1)
  FAIL  text: no tool or command name in plugins or docs outside tests
```

The grep currently matches:

```
plugins/fleet/README.md:178:  become `npm run <name>`, and `test` becomes `npm test`, in that order. With
plugins/fleet/src/standards.js:18:  ['lint', 'npm run lint'],
plugins/fleet/src/standards.js:19:  ['typecheck', 'npm run typecheck'],
plugins/fleet/src/standards.js:20:  ['build', 'npm run build'],
plugins/fleet/src/standards.js:21:  ['test', 'npm test'],
```

Every other part of the package is done and committed. `plugins/fleet/tests/standards-init.test.sh` failed before the change (31 checks, 20 failed; commit `35e3819`) and passes after it (31 checks, 0 failed). Every other test file in `scripts/test.sh` passes.

## Alternatives searched

- Rephrase the README so it avoids the literal string. That fixes one of the five matches. `standards.js` still has to emit the commands #124 names.
- Build the strings so the regex cannot see them (`'npm' + ' run'`). That passes the grep without meeting its intent, which is routing around a check. I rejected it.
- Move the command table into a data file. It still ships under `plugins/`, and a new file there is outside `allowedPaths`.
- Exempt `plugins/fleet/src/standards.js` and `plugins/fleet/README.md` in the gate. The gate is under `plugins/agentic-work-packages/**`, which is in `forbiddenPaths`.

## The ask

S1.1-text: The SV0 text invariant and #124 conflict. Options:
(a) Amend the gate to exclude `plugins/fleet/src/standards.js` and `plugins/fleet/README.md`, or `plugins/fleet/**`, from the text grep. This is a change to SV0's lane.
(b) Amend #124 so the draft builds commands from data the invariant does not name, and so the README describes them without the literal text. This weakens the grep to a literal-text check that the code deliberately avoids.
(c) Narrow the gate's pathspec to the guidance text it protects (`references/`, `skills/`, `docs/`), which leaves runtime code that emits a target's own commands out of scope.
: recommend (a). The invariant keeps the plugin's guidance from naming tools. This command's whole job is to write down a target's real commands, so an explicit, named exemption keeps the check honest.
: decide-by the next fleet cycle that would relaunch S1.1
: cost-of-waiting S1.1 cannot go `[READY]`. S1.2's "no manifest, no launch" is workable only once producing a manifest is cheap, so it stays unusable in practice.
