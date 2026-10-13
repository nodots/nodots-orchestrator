# Review rules

What a reviewer checks on a pull request in this repository, how findings are
reported, and how to run a review. The package issue and the worker contract
(`plugins/agentic-work-packages/skills/agentic-work-packages/assets/worker-contract.md`)
govern; this file governs the review.

## Passes

Review the diff in three passes, in this order. Each pass is a separate read.

1. **Bugs and logic errors.** Behavior that does not do what the code and the
   package issue say it does: wrong conditions, unhandled failure paths, broken
   edge cases, tests that cannot fail, a fallback that substitutes a different
   answer where the intended one cannot be produced.
2. **Security.** Leaked data or credentials, a secret value in the diff,
   unvalidated input reaching a shell, a path or a query, permissions widened,
   an unsafe default, a new network or credential dependency.
3. **Compliance with the package issue and the worker contract.** Every
   acceptance criterion in the package issue is met and observable. Every
   changed path is inside `allowedPaths` and outside `forbiddenPaths` in
   `SCOPE.json`, and `SCOPE.json` itself is unchanged. The failing test came
   first. The `VERIFIED:` stamp matches the head sha. `HANDOFF.md` carries a
   `Plan check` section. The repository rules in `CLAUDE.md` hold.

## Finding format

Each finding names its pass with a tag, then the location, then the problem:

```
[bugs] path/to/file:42 - what is wrong, and the input or state that shows it
[security] path/to/file:7 - what is exposed, and to whom
[compliance] path/to/file:1 - which criterion or contract clause is not met
```

A finding with no file and line is a guess. Cite the line or drop the finding.

## Severity

- **Important:** breaks behavior, leaks data, or breaches policy (the package
  issue, the worker contract, or a repository rule). Mark it `Important:` after
  the tag.
- **Nit:** everything else. Style, naming, wording, and preference are nits.

Report at most 5 nits. Summarize the rest as a count on one line, for example
`7 further nits not listed`. List every Important finding; the cap does not
apply to them.

## Excluded paths

Do not review, and do not report findings in:

- `.agentic/cells/**` (generated `SCOPE.json` lanes)
- lockfiles (`package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`)
- generated or vendored files, and files marked as generated in their header
- the byte-identical hook copies under
  `plugins/agentic-work-packages/skills/agentic-work-packages/assets/hooks/`;
  review the originals in `plugins/agentic-work-packages/hooks/`, and let
  `bash scripts/test.sh` check the copies

## Findings never approve or block

Findings never approve or block a PR alone. A review with no findings is not an
approval, and a review with Important findings is not a block. The merge
decision belongs to a person or the coordinator, who reads the findings and the
`VERIFIED:` stamp.

## How to run a review

A person or the coordinator runs the review locally. There is no workflow, no
secret, and no automation.

1. Open a Claude Code session in this repository, under the logged-in account.
2. Read the PR: `gh pr view <number>` for the description and linked package
   issue, then `gh pr diff <number>` for the change.
3. Read the package issue named in the PR body and the `SCOPE.json` for the
   branch.
4. Review the diff against the three passes above, skipping the excluded paths.
5. Post the findings as one PR comment with `gh pr comment <number>`. Tag each
   finding by pass, as in the finding format. Put Important findings first,
   then up to 5 nits, then the nit count.

Do not approve or request changes through `gh pr review` on the strength of the
findings alone.
