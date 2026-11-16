# BLOCKER: IV — the "fails when broken" demonstration cannot be run in this session

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** #181, acceptance criterion 2 ("Each fails when the behavior it checks is broken (shown once, by hand, in the PR)")
**Owner:** Ken Riley (coordinator)
**Un-blocks when:** someone with shell access runs the mutation check below and posts its output on the PR, or #181 drops criterion 2

## What was needed, and why

The suite `plugins/fleet/tests/gate-i-identity.test.sh` is written, and it passes
25/25 against the tree as it is (four scenarios, all asserted). Criterion 2 asks
for proof that each scenario fails when the behavior it checks is broken. That
means running the suite against a copy of the tree with `plugins/fleet/src/launch.js`
or `scripts/check-commit-identity.sh` broken on purpose. Both paths are in
`forbiddenPaths`.

This worker session has no approval surface. It denied every route to a
throwaway copy:

- `Write` to `/tmp/iv-mutate/run.sh`: "Path is outside allowed working directories".
- `mkdir -p /tmp/ivm/m1 && git archive HEAD | tar -x -C /tmp/ivm/m1`: needs approval, denied.
- The same with the sed edits inline: denied ("brace with quote character").

## Alternatives searched

- Mutate `launch.js` / `check-commit-identity.sh` in this worktree and revert — the
  paths are forbidden. A shell edit that gets around the lane hook is the failure
  the worker contract §1 names.
- A scratch `git worktree` inside this worktree, mutated with sed — this is still
  editing files outside `allowedPaths` through the shell to get around the hook, for
  the same reason.
- Have the gate suite build its own mutants under its `mktemp -d` when an env var
  is set. The suite can write to /tmp, but I can't. Using it to do what the
  permission layer just refused is getting around a permission control, and it
  would also put mutation machinery into a gate suite.
- Argue it from scenarios 2 and 3 (the check already fails on a fleet author and on
  AI trailers). That covers the check, not `fleet`'s own commit identity or the
  identity-missing refusal, and the criterion asks for a demonstration, not an
  argument.

## The ask

IV-1: Who runs the mutation check for criterion 2? Options: (a) a person runs the
script below from the repo root on `test/iv-identity-gate` and posts the output on
the PR; (b) re-dispatch with `/tmp` writable for the worker; (c) drop criterion 2
from #181. : recommend (a). It takes under two minutes, and each mutant must
print `exit 1` with at least one `FAIL` line. : decide-by the PR's review :
cost-of-waiting the program-I version bump, which this gate blocks.

```bash
D=$(mktemp -d); L=plugins/fleet/src/launch.js; C=scripts/check-commit-identity.sh
mk() { mkdir -p "$D/$1"; git archive HEAD | tar -x -C "$D/$1"; }
mk m1; sed -i "s|^function commitAs(identity) {|function commitAs(identity) { identity = { name: 'fleet', email: 'fleet@nodots.invalid' };|" "$D/m1/$L"
mk m2; sed -i '/= fleet \] \&\& reasons/d; /fleet@nodots.invalid) reasons/d' "$D/m2/$C"
mk m3a; sed -i "s/^AI_RE='claude|anthropic|/AI_RE='/" "$D/m3a/$C"
mk m3b; sed -i "s/^AI_RE='claude|/AI_RE='yes|claude|/" "$D/m3b/$C"
mk m4; sed -i "s/^  if (missing.length) return { ok: false, stage: 'identity-missing'.*/  if (missing.length) return { ok: true, name: 'fleet', email: 'fleet@nodots.invalid' };/" "$D/m4/$L"
for m in m1 m2 m3a m3b m4; do
  echo "=== $m"; diff "$L" "$D/$m/$L"; diff "$C" "$D/$m/$C"
  bash "$D/$m/plugins/fleet/tests/gate-i-identity.test.sh" > "$D/$m.out" 2>&1; echo "exit $?"
  grep -E '^  FAIL|---' "$D/$m.out"
done; rm -rf "$D"
```

What each mutant breaks, and the scenario that must catch it:

| Mutant | Breaks | Scenario |
|---|---|---|
| m1 | fleet's scope commit is made as `fleet` | 1 |
| m2 | the check ignores a `fleet` author or committer | 2 |
| m3a | the check ignores Claude/Anthropic trailers | 3 (Co-Authored-By, Agent-Assisted: claude) |
| m3b | the check rejects `Agent-Assisted: yes` | 3 (yes passes) |
| m4 | a clone with no identity falls back to `fleet` and launches | 4 |
