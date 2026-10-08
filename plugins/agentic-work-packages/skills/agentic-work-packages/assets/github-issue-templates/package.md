---
name: Work package
about: One bounded change for one worker agent: one branch, one SCOPE.json, one PR
labels: ''
---

**Part of** #<epic> · **Phase <n> · <name>** · **Repo:** <repo>

## Goal
<!-- Which gap this closes, and the failure it prevents. One paragraph. -->

## Scope of work
<!-- Files, functions and line ranges, e.g. src/routes/x.ts:192-300.
     Include constraints that are not visible from the code. -->

## SCOPE.json
```json
{
  "package": "<ID>",
  "branch": "<branch>",
  "allowedPaths": [],
  "forbiddenPaths": [],
  "dependsOn": []
}
```

## Acceptance criteria
<!-- Name the failing test that must exist first. About six items at most. -->
- [ ]
- [ ]

## Depends on
<!-- Issue numbers. Must agree with SCOPE.json dependsOn and the phase order. -->
- None

<!-- The coordinator, not the author, applies agent-ready and cell:* labels. -->
