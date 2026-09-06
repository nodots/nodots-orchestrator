# Adapter: Jira

The model maps cleanly onto Jira, with two caveats: corporate Jira projects
often restrict issue types and workflow transitions, and Jira's description
editor is not Markdown. Check what the project actually permits before designing
around it.

## Tier mapping

| Model tier | Jira | Notes |
|---|---|---|
| Program doc | Confluence page | `createConfluencePage`; link it from the Epic |
| Epic | Epic issue type | If Epics are governed by a PMO, use a Story as the epic and link children with `is parent of` |
| Package | Story or Task, `parent` = the Epic | Sub-task type also works, but sub-tasks cannot be assigned across boards or sprints in some configurations |
| Gate | Story or Task, `parent` = the Epic, labelled `gate` | Gate blocks the next phase with an issue link |

Jira renders children under an Epic automatically, so the epic's manual checkbox
list is redundant. Replace it with a **phase table** — phase, package key, one
line each — so the ordering and the gates stay visible in one place.

## Dependencies

Jira expresses these as issue links, not text. Fetch the link type names first —
they are site-configured and `Blocks` / `Depends on` are not guaranteed to exist:

- `getIssueLinkTypes` — list what this site actually has
- `createIssueLink` — gate `is blocked by` each package in its phase

Keep all three declarations in sync as always: the issue link, the
`SCOPE.json.dependsOn` branch list, and the phase ordering in the epic.

## Status lifecycle

Prefer **workflow statuses** over labels when the board allows it — the board
then shows the fleet's state without a filter. Map:

```
queued -> active -> awaiting-review -> merged/done
blocked -> a status or a flag, whichever the workflow supports
```

Where the workflow is locked down, fall back to labels. Jira labels cannot
contain spaces; use `cell-queued`, `cell-active`, `cell-awaiting-review`,
`cell-blocked`, `agent-ready`.

Transitions go through `transitionJiraIssue`, and the available transitions
depend on the current status — read them with `getTransitionsForJiraIssue`
rather than assuming an ID.

## Fields

Before creating anything, read what the project requires:

- `getVisibleJiraProjects` — find the project and its key
- `getJiraProjectIssueTypesMetadata` — which issue types exist
- `getJiraIssueTypeMetaWithFields` — which fields are required on create

Mandatory custom fields are the usual reason a create call fails on a corporate
site. Read the metadata rather than retrying with guesses.

## Description content

The description is ADF, not Markdown. The `SCOPE.json` block still belongs in
the description — put it in a code block. Acceptance criteria go in a checklist
where the site supports one, otherwise a bullet list with `[ ]` prefixes, which
survives the round trip.

If the description editor mangles the JSON, attach `SCOPE.json` to the issue
instead and say in the description that the scope is attached. The agent needs
the file on disk, not the rendering.

## MCP tools

With the Atlassian MCP connected, the relevant tools are `getVisibleJiraProjects`,
`getJiraProjectIssueTypesMetadata`, `getJiraIssueTypeMetaWithFields`,
`createJiraIssue`, `editJiraIssue`, `getIssueLinkTypes`, `createIssueLink`,
`getTransitionsForJiraIssue`, `transitionJiraIssue`, `searchJiraIssuesUsingJql`
and `addCommentToJiraIssue`. Their schemas load on demand — fetch them with
ToolSearch before calling.

## Queue views

```
# dispatchable now
project = ABC AND labels = agent-ready AND status = "Queued" ORDER BY key ASC

# what the fleet is on
project = ABC AND status = "Active"

# blocked
project = ABC AND (status = "Blocked" OR labels = cell-blocked)

# a phase's packages and its gate
project = ABC AND parent = ABC-100 AND summary ~ "H0."
```

## Logs

Jira has no append-only body convention, and editing a description destroys its
history. Put the **decisions log and progress log in comments** on the epic, one
comment per entry, dated. Comments are ordered and preserved; that is the whole
requirement.
