Rules for this repository, from `CLAUDE.md`, which governs:

- Use American spelling: color, center, organize.
- `bash scripts/test.sh` runs everything CI runs. It must end `ALL PASS`.
- The default branch is `development`. Never commit on it; work on a feature branch and open a PR.
- `plugins/agentic-work-packages/hooks/*.js` and their copies under `assets/hooks/` stay byte-identical.
- The plugin `references/` govern `docs/`.
- The tracker issue is the single source of truth for intent and spec. No `intent.md` or `spec.md` in git.
