# Retrospective: [Package ID and title]

**Package:** `[package id]`
**Branch:** `feat/[feature-name]`
**Coordinator:** [Name]
**Issue:** #[issue number]
**Date completed:** [Date]
**Duration:** [X days / Y hours]

---

## Quick summary

[One sentence: what the package did and the outcome]

---

## What went well

- [Thing that worked smoothly]
- [Thing that worked smoothly]
- [Tool or process that helped]

---

## What was hard

- [Pain point or difficulty]
- [Unexpected challenge]
- [Tool that could be better]

---

## Scope accuracy

**Was `SCOPE.json` complete and correct?**

- [ ] Yes, no change was needed
- [ ] Mostly correct, minor problems
- [ ] Several violations or overreach
- [ ] Wrong (describe below)

**Details:**

```
If scope violations or blockers about scope occurred:
- Path: [why it needed to be changed]
- Path: [why it needed to be changed]

If none, write: "No violations. Scope was accurate."
```

**Lesson for next time:**
[What should change in how lanes are designed?]

---

## Stopping conditions

**Did the worker stop at the right times?**

- [ ] Yes, clear stopping points
- [ ] Mostly, with one surprise
- [ ] No, it was ambiguous when to stop
- [ ] Not applicable (no blockers)

**Details:**

```
If the worker hit a blocker:
- Blocker: [description]
- Kind: [tracked-task | human-decision | external | foreign-lease | not-before]
- Resolution: [how it was cleared]

If there were no blockers, write: "No blockers."
```

**Lesson for next time:**
[What should be clearer in the worker contract or the package?]

---

## Tool feedback

### Scope hook
**Easy to understand? Useful?**

- [ ] Yes, clear and useful
- [ ] Mostly, but the error messages could be better
- [ ] No, confusing or wrong

Comments:

```
Example: "Hook rejected an out-of-lane file. The message was clear."
or
"Hook rejected an in-lane file matching a glob. It took time to debug."
```

### Handoff hook
**Did it catch missing state? Was it in the way?**

- [ ] Yes, it worked as intended
- [ ] Mostly, with minor friction
- [ ] No, it blocked or missed something

Comments:

```
[What happened]
```

### Package issue
**Was the package clear enough to finish without questions?**

- [ ] Yes, clear and complete
- [ ] Mostly, a few parts were unclear
- [ ] No, it was not enough

Comments:

```
Example: "The scope of work named the files I needed."
or
"The goal did not say which behavior to preserve."
```

### HANDOFF.md
**Was it clear what to write?**

- [ ] Yes, very clear
- [ ] Mostly, examples would help
- [ ] No, it was confusing

Comments:

```
[What was clear or unclear]
```

---

## Timeline

- **Branch created:** [Date]
- **`SCOPE.json` written:** [Date]
- **Worker session started:** [Date]
- **Work completed:** [Date]
- **`[READY]` PR opened:** [Date]
- **PR approved and merged:** [Date]

**Total duration:** [X days / Y hours]

**Expected vs. actual:**

```
- Expected (estimatedScope): [value]
- Actual duration: [X days]
- If different, why: [reason]
```

---

## Dependencies and interactions

**Did this package's dependencies affect the timeline?**

- [ ] No dependencies
- [ ] Dependencies completed on time
- [ ] Had to wait for a dependency
- [ ] Blocked on a dependency

Details:

```
Example: "Depended on feat/shared-types. Waited one day for it to merge."
```

**Did this package block any other package?**

- [ ] No, independent
- [ ] Yes: [which packages]

If yes, for how long, and did they resume quickly after the merge?

---

## Blocker analysis

**If blockers occurred:**

1. **Blocker 1: [Name]**
   - **When:** [Date]
   - **Cause:** [Root cause]
   - **Resolution:** [How it was cleared]
   - **Time cost:** [Hours or days lost]
   - **Preventable?** Yes / No
   - **If yes, how?** [Better `SCOPE.json`? Earlier contract change?]

2. **Blocker 2: [Name]**
   - [Same fields as above]

---

## Code quality

**How was the implementation quality?**

- [ ] Excellent
- [ ] Good
- [ ] Acceptable
- [ ] Needs improvement

**Any technical debt or shortcuts?**

```
Example: "Skipped some error handling to stay in scope. To address in a follow-up package."
```

**Any architectural decisions that surprised you?**

```
Example: "The worker chose approach A over approach B. Reason: [reason]."
```

---

## Process observations

**What should we do more of?**

- [ ] Detailed acceptance criteria
- [ ] Earlier contract-change identification
- [ ] [Other]

**What should we do less of?**

- [ ] Too-broad `allowedPaths`
- [ ] Vague acceptance criteria
- [ ] Merging without a current evidence stamp
- [ ] [Other]

**What should we change?**

- [ ] [Process change 1]
- [ ] [Process change 2]
- [ ] [Template change]

---

## Learning for the next package

**Key takeaway:**

[One sentence that applies to future packages]

**Example:** "Shared type changes need their own contract-change package; the worker should not edit contracts."

---

## Files created or modified

```
feat/[feature-name] modified:
- [path] (new)
- [path] (modified)
- [test path] (new)

Total lines: +[n], -[n]
Tests added: [n]
```

---

## Follow-up actions

**Should any issues or improvements be filed?**

- [ ] No
- [ ] Yes:
  - Issue: [Improvement or bug found]
  - Issue: [Improvement or bug found]

---

## Coordinator notes

[Any additional observations from the coordinator's perspective]

---

## Metrics (optional)

| Metric | Value | Target | Met |
|--------|-------|--------|-----|
| Duration | | | |
| Scope violations | | | |
| Blockers | | | |
| Tests added | | | |
| Merge conflicts | | | |
| Merge duration | | | |

---

## Sign-off

**Completed by:** [Name]
**Date:** [Date]

---

## Next steps

1. File any follow-up issues.
2. Update templates and `SCOPE.json` defaults based on the lessons above.
3. Record patterns that repeat across packages where the team keeps them.
