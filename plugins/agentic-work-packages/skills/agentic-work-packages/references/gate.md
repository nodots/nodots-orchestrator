# Writing a gate

A gate is a package whose product is proof. It is **blocking**: no package in a
later phase dispatches until the gate merges.

Gates exist because a phase of individually-green packages routinely fails as a
whole. Each agent proved its own unit; nobody proved the seam.

## Rules

- **Title:** `V<phase> gate — <what it proves>`.
- **`dependsOn` lists every package branch in the phase.** No exceptions; a gate
  that skips one is not a gate for that phase.
- **`allowedPaths` are tests only.** Implementation paths go in
  `forbiddenPaths`. A gate that can edit the code it validates will fix rather
  than fail, and the failure will surface in production instead.
- **Acceptance criteria assert end-to-end behaviour, including the negative
  cases.** "Two users complete a session" is half a gate; "the off-turn user's
  mutations are rejected at multiple points" is the other half.
- **Close with the consequence:** `**Blocking gate for:** Phase 2 (#N).`
- **The verifier restates the criteria before the phase's workers build.** A
  `gate-verify` package's verifier writes down the exact commands and
  assertions that will constitute the proof, and it does so early enough that
  the phase's packages can be built against it. Disagreement between the
  restatement and the gate's criteria is a defect in the plan, filed before
  code, not a negotiation at review time.

## Gates held for a human

Anything requiring a real browser against a deployed environment, a judgement
call about product behaviour, or production credentials is a human gate. Say so
in the title — `V1 gate — two-browser session (held for <name>)` — and do not
mark it agent-ready. A human gate that is mislabelled will be picked up by an
agent that then reports success it cannot have verified.

## Template

````markdown
## V0 gate — <what it proves> (blocking validation gate for Phase 0)

**Part of** <epic link> · **Phase 0 · <name>** · **Repo:** `<repo>`

### Goal
Prove <property> end-to-end before later phases build on it. This is a blocking
gate: Phase 1 packages do not dispatch until it passes.

### Scope of work
- <the test to write, and the existing suite whose structure it mirrors>

### SCOPE.json
```json
{
  "feature": "<kebab-feature>",
  "project": "<project>",
  "branch": "test/<kebab-feature>",
  "allowedPaths": ["<e2e test glob>", "<test utils>"],
  "forbiddenPaths": ["<all implementation paths>", "<migrations>", "<manifests>"],
  "dependsOn": ["<every package branch in the phase>"],
  "estimatedScope": "<one line>",
  "execution": {
    "model": "strongest available",
    "pattern": "gate-verify",
    "window": "<context window, or the autocompact setting>",
    "agents": []
  }
}
```

### Verifier restatement
_(the exact commands and assertions this gate will run, written before the
phase's packages are built)_
- Commands: `<exact command>`
- Assertions: `<what each one proves>`

### Acceptance criteria
- [ ] <positive end-to-end assertion>
- [ ] <negative assertion — what must be refused, asserted at more than one point>
- [ ] <existing suites remain green>
- [ ] Tests pass · build/typecheck passes · lint passes
- [ ] `[READY]:` PR opened, linked to this gate

### Dependencies
- **Depends on:** #N, #N, #N · **Blocking gate for:** Phase 1 (#N).
````
