# Running a worker remotely

Use this when a worker runs as a Claude Code cloud session (`claude --cloud`)
on a hosted virtual machine instead of on the operator's machine. That offloads
compute and avoids contention with local services such as Docker. The VM clones
the repository's GitHub remote at the current branch, so the package branch and
its scope commit must be pushed first; it starts with no dependencies installed.
This file covers the prerequisites, the session-start dependency install, and a
checklist to run before launching.

Facts below marked "(docs)" come from the Claude Code documentation,
`code.claude.com/docs/en/claude-code-on-the-web`, read 2026-10-07. Facts
marked "(unverified)" have not been confirmed against a live cloud session and
must be before a runtime depends on them.

## Prerequisites

### 1. Claude Code version

`--remote` is a deprecated alias for `--cloud` (docs). Use `--cloud`. Check the
installed version before relying on any flag named here:

```bash
claude --version
npm install -g @anthropic-ai/claude-code@latest   # if older
```

### 2. GitHub access for the cloud session

Cloud sessions reach GitHub through one of two connections (docs):

- **The Claude GitHub App**, installed on the repositories the packages
  target. An organization owner installs it once from Claude.ai (Settings,
  Integrations, GitHub) or from the GitHub App page, choosing the
  organization and the repositories.
- **`/web-setup`**, run in a local terminal session, which sends the local
  `gh` token to the Claude account. Sessions can then reach any repository
  that token can, whether or not the App is installed.

In Anthropic-hosted environments the credential never enters the VM: git and
`gh` operations go through a GitHub proxy that attaches it server side (docs).
There is no `GH_TOKEN` to set, and nothing to paste into an environment
variable. Earlier versions of this guidance said otherwise; they were wrong
for current cloud sessions.

Whether `gh` is preinstalled on the VM, and whether a worker's `gh issue view`
and `gh pr create` work through the proxy without further setup, is
(unverified). If `gh` is absent, the cloud environment's setup script can
install it; keep that script in the environment settings, not in the repo.

### 3. Cloud environment

Every cloud session runs in a saved cloud environment that sets network
access, environment variables and a setup script (docs). The default
environment is created at onboarding. A program that needs a particular
network level or a build toolchain gets its own environment.

## Launching

From a checkout of the target repository, on the package branch, after the
scope commit is pushed:

```bash
claude --cloud "Execute work package <ID>: follow .claude/worker-contract.md; read the package with gh issue view <n> --repo <host>"
```

The VM clones the current directory's GitHub remote at the current branch
(docs), not the local checkout, so an unpushed commit is invisible to it.
Each `--cloud` call creates its own independent session, so a fleet is several
calls (docs). Whether the command returns as soon as the session is created or
stays attached while it provisions is (unverified); the CLI shows a setup
checklist while the container starts (docs).

A follow-up message to a running cloud session, from any machine logged into
the same account:

```bash
claude -p "<message>" --cloud <session-id> --output-format json   # {ok, session_id, url}
```

It queues the message and exits without waiting (docs). There is no documented
CLI to list or stop cloud sessions; progress is observed on claude.ai/code, or
through the tracker: the branch, the PR and `BLOCKER.md` (`coordination.md`).

## Session start: dependency installation

A remote VM starts with a freshly checked-out workspace. Dependencies are not
installed. A `SessionStart` hook that runs `npm install` installs the
JavaScript or TypeScript dependencies and compiles native Node.js addons
(through `node-gyp`) against the VM's Node.js version. A repo with a native
addon needs the install to finish before the worker writes any code.

The plugin does not register a session-start hook. Its registered hooks are
`enforce-scope.js` (`PreToolUse`) and `require-handoff.js` (`Stop`), described
in `SKILL.md` §Procedure step 7. An opt-in script,
`assets/hooks/session-start-install-deps.sh`, is wired by hand from
`assets/settings-snippet-optional.json`. It runs `npm install --prefer-offline`
in the repo root (or the first `package.json` one directory down). It also
compares `origin` with the `repo` field of `.claude/project.json` and, on a
mismatch, tells the worker on stdout to stop and write `BLOCKER.md`.

`SessionStart` cannot abort a session: per the Claude Code hooks documentation,
a non-zero exit shows an error notice and the session proceeds. So neither a
failed install nor a repository mismatch stops the worker by itself. The first
shows up later as build or test errors, and the second depends on the worker
following the instruction the hook injects.

### Getting the hooks onto the VM

Commit `.claude/` (the settings and hook scripts) to the target repo's default
branch, so every session, local or remote, picks it up. Do this from a branch
and a pull request, as for any change to the default branch, then merge:

```bash
git checkout -b chore/worker-infrastructure
git add .claude/
git commit -m "Add Claude Code worker infrastructure (remote-ready)"
git push -u origin chore/worker-infrastructure
```

For the plugin's two hooks, the manual install in `SKILL.md` §Procedure step 7
produces that committed `.claude/` content. Cloud sessions read the
repository's committed `.claude/settings.json` and `.claude/agents/` (docs);
the documentation does not say that a plugin installed on the operator's
machine is present on the VM, so do not rely on it: commit the manual install.
That the committed hooks fire inside a cloud session as they do locally is
(unverified).

## Validation checklist

Before launching a cloud session:

- [ ] `claude --version` is current and `--cloud` is accepted
- [ ] The Claude GitHub App is installed on the target repo, or `/web-setup`
      has been run from a terminal logged into the same account
- [ ] The cloud environment has the network access and setup script the repo
      needs
- [ ] `.claude/settings.json` in the target repo has the `PreToolUse` and
      `Stop` hooks, plus a `SessionStart` entry if the repo needs one, and
      the hook scripts and `.claude/worker-contract.md` are committed
- [ ] `SCOPE.json` exists for the package's branch (resolution order in
      `scope-contract.md` §Resolution order for `SCOPE.json`) and the branch
      with its scope commit is pushed

## Checking native compilation

For a repo with a native addon, verify the VM can build it:

```bash
git checkout <feature-branch>
claude --cloud "Run the session-start install, then list <addon-dir>/build/Release and report whether the compiled addon exists"
```

If compilation fails, check that the VM has the system build tools. The repo's
own `package.json` `install` script handles the rest.

## Troubleshooting

### The repository is not accessible from the VM

The Claude GitHub Application is not installed for the organization, or does
not include the target repo. Repeat the application setup above and include the
right repositories.

### `npm install` failed in the session-start hook

The session proceeds after a failed install (see §Session start), so a missing
install can surface later as build or test errors in the worker.

1. Read the full npm output in the session log for the cause.
2. If system build tools are missing (`node-gyp` needs `python3`, `make` and a
   C++ compiler): VMs are provisioned by Anthropic and system packages cannot
   be installed directly. The options are:
   - open a support request with Anthropic to learn which build tools the VMs
     have;
   - add a pre-built binary path, or an `.npmrc` or `optionalDependencies`
     fallback in `package.json`, so `npm install` succeeds without compiling;
   - write `BLOCKER.md` with the exact npm error and stop, so the coordinator
     can evaluate alternatives (`coordination.md` §`BLOCKER.md`).
3. If the cause is a network or registry failure, retry the session; a
   transient failure may clear.

### `claude --cloud` is refused

The documented causes (docs): the CLI is signed in with an API key rather than
a claude.ai account (`claude auth login`), Claude Code is configured for a
third-party provider such as Bedrock, or the organization's
`allow_remote_sessions` policy is off. An old CLI that knows only `--remote`
still works, since `--remote` is the deprecated alias, but update it.
