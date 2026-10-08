# Context management

Use this when a worker's session runs long enough that its context may compact,
or when deciding what a worker must write to a file rather than keep in
conversation. Context is session-scoped; files are not. The rules here keep a
package's decisions and findings in files, so they survive compaction and
reach the next session and the coordinator.

Where `coordination.md` §After a compaction, re-derive before acting covers the
coordinator's side, this file covers the worker's. For how the context window
enters a package's cost, see `coordination.md` §The context window is part of
the profile.

## Compaction and file-based artifacts

When the window fills, earlier parts of the conversation are compacted, and
anything held only in conversation may be summarized or lost. The mitigation is
to write important decisions and findings to files.

**Write to files, not only to conversation:**

- Architectural decisions and their rationale: code comments, `HANDOFF.md`.
- API shapes and interface contracts: type definitions, `HANDOFF.md`.
- Debugging findings that took significant effort to reach: code comments.
- Test descriptions that say why a test exists, not only what it tests.

**Fine to keep in conversation only:**

- Exploratory questions and intermediate reasoning.
- Build output and error messages, which are transient.
- File contents already read, which can be read again.

## HANDOFF.md stays required

A large context window does not remove the need for `HANDOFF.md`, which does
four jobs that in-session context cannot:

- It bridges sessions. Context belongs to one session.
- It communicates with the coordinator, who is not in the session.
- It records the final state for PR review.
- It gives the next session its instructions if the work is incomplete.

The completion protocol and the Stop hook that enforces it are in
`assets/worker-contract.md` §Completion protocol. `HANDOFF.md` is context for
the next worker, never the routing signal; see `coordination.md` §Labels are
derived each cycle.

## Practical guidelines

1. **Do not rely on conversation memory for early decisions in a long
   session.** If a key choice was made many turns ago, write it down.
2. **Re-read files rather than trusting conversation summaries.** After
   compaction, file contents carried in the conversation may be stale
   summaries. Read the file again for current content.
3. **`HANDOFF.md` is the canonical session output.** Even if the conversation
   is still available, `HANDOFF.md` is what the coordinator and the next
   session read.
