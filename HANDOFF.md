# HANDOFF: G0.2 (issue #27)

## Done
- `scripts/check-syntax.sh`: `node --check` on every `.js` and `bash -n` on every `.sh` under `plugins/`. Fails on a parse error or when nothing matches.
- `scripts/check-credentials.sh`: scans files changed against `origin/development` (merge base, staged, unstaged, untracked) for private-key headers and token prefixes (AWS, GitHub, Slack, Anthropic, Google). Output names the file, never the match. An unresolvable `BASE_REF` fails. A non-git tree scans every file.
- `scripts/test.sh` runs both (scripts/test.sh, "syntax" and "credentials" sections) and sets `status=1` on failure. Both are called from the directory of `test.sh`, so the `REPO_ROOT` fixtures in `test-sh.test.sh` keep working.
- `scripts/tests/check-syntax.test.sh` (8 checks) and `scripts/tests/check-credentials.test.sh` (15 checks). Both failed before the scripts existed (script-missing errors, 5 and 6 failed checks). Seeded secrets are joined from fragments at runtime; no secret-shaped literal is committed.

## Limits
- The syntax check is a parse check only. It is not a style linter and gives no lint coverage.
- The credential check matches the listed patterns only. It is not a general secret scanner.
- The `test.sh` wiring (a seeded bad file makes `test.sh` itself exit non-zero) was not exercised end to end: `scripts/tests/test-sh.test.sh` is outside `allowedPaths`, and an ad-hoc seeded run was denied in this session. Each script's non-zero exit is covered by its own test; the wiring is `if ! ...; then status=1`.

## Next
Review and merge.

## Plan check

Package issue still matches: yes
