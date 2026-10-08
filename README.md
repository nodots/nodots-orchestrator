# nodots-orchestrator

Private. Everything Nodots uses to run programs of work with coordinated AI agents,
consolidated from `nodots/agentic-work-packages` and `nodots/nodots-ai-workflows` on 2026-09-06
with both histories preserved.

## Layout

| path | contents |
|---|---|
| `.claude-plugin/marketplace.json` | the `nodots-plugins` Claude Code marketplace; this repo is the marketplace |
| `.github/workflows/ci.yml` | CI: the fixture tests, and the byte-identical check on the hook copies |
| `plugins/agentic-work-packages/` | the plugin: skill, references, both hooks, scripts, fixture tests |
| `plugins/fleet/` | the coordinator runtime: `fleet cycle` syncs, promotes, assigns, launches local worker sessions in worktrees, reaps and reports; fixture tests |
| `docs/` | the long-form model docs: `agentic-work-packages.md`, `working-agreements.md` |
| `CLAUDE.md` | project instructions |

## Install the plugin

```bash
claude plugin marketplace add nodots/nodots-orchestrator
claude plugin install agentic-work-packages@nodots-plugins
```

## Working here

- Default branch is `development`. Never commit on it; open a PR from a feature branch.
- The plugin's `references/` are the single source for the model's rules. `docs/` is the
  long-form narrative and worked example; where the two state the same rule, the plugin copy
  governs and the doc must match it.
- Planning and evaluation documents are gitignored and stay local. Nothing engagement-derived
  is committed — see `.gitignore`.
- Every hook and script ships with its fixture test in the same PR, and CI runs them all. A
  gate that has never run is not a gate.
