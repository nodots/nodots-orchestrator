# Running a worker remotely

Use this when a worker runs with `claude --remote` on a hosted virtual machine
instead of on the operator's machine. That offloads compute and avoids
contention with local services such as Docker. The worker, its `SCOPE.json` and
its hooks behave as they do locally (unverified here: confirm that
repository-committed hooks run on the VM before relying on them); what differs
is that the VM starts from a fresh checkout with
no dependencies installed and no `gh` login. This file covers the prerequisites,
the session-start dependency install, and a checklist to run before launching.

## Prerequisites

### 1. Claude Code version

Remote execution needs a recent Claude Code. This guidance was written against
v2.1.63 as the minimum; confirm the current minimum in the Claude Code
documentation.

```bash
claude --version
npm install -g @anthropic-ai/claude-code@latest   # if older
```

### 2. GitHub CLI authentication

Remote VMs have no `gh auth login`. The `gh` CLI, and a worker's `curl`
fallback, read a `GH_TOKEN` environment variable.

One-time setup:

1. Create a GitHub personal access token with read and write access to the
   repos the packages target. Prefer a short expiration; 90 days was used
   in practice. Use a fine-grained token scoped to those repos where GitHub
   offers one for your organization, and check which permissions it needs for
   issues and pull requests.
2. Add `GH_TOKEN=<token>` as an environment variable in the cloud environment
   settings on Claude.ai.
3. If `gh` is not pre-installed on the VM, add its installation to the cloud
   environment setup script. For a Debian-based VM:

   ```bash
   type -p curl >/dev/null || (sudo apt update && sudo apt install curl -y)
   curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
   echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
   sudo apt update && sudo apt install gh -y
   ```

Without `GH_TOKEN` and `gh`, a worker cannot read issues or open PRs. Do not
paste the token into a transcript, an issue or a file in the repo.

### 3. The Claude GitHub Application

The VM needs read access to the repo to check out the code. An organization
owner installs the Claude GitHub Application once:

1. Open Claude.ai, Settings, Integrations, GitHub, and choose Connect GitHub.
2. Select the organization (not a personal account).
3. Under repository access, choose all repositories or only the repos the
   packages target.
4. Install.

After that, a `claude --remote` session targeting a repo in that organization
can clone it.

## Launching

Replace the local invocation with the remote one:

```bash
claude            # local
claude --remote   # on a hosted VM
```

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
produces that committed `.claude/` content. Whether a plugin-level install is
present on a remote VM is unverified, so do not rely on it: confirm it, or
commit the manual install.

## Validation checklist

Before launching a remote session:

- [ ] `claude --version` reports v2.1.63 or later
- [ ] The Claude GitHub Application is installed with access to the target repo
- [ ] `GH_TOKEN` is set in the cloud environment settings
- [ ] `gh` is available on the VM, or the worker can use `curl` with `GH_TOKEN`
- [ ] `.claude/settings.json` in the target repo has the `PreToolUse` and
      `Stop` hooks, plus a `SessionStart` entry if the repo needs one, and
      the hook scripts are committed
- [ ] `SCOPE.json` exists for the package's branch (resolution order in
      `scope-contract.md` §Resolution order for `SCOPE.json`)

## Checking native compilation

For a repo with a native addon, verify the VM can build it:

```bash
git checkout <feature-branch>
claude --remote

# Inside the remote session, after the session-start install:
ls <addon-dir>/build/Release/*.node    # the compiled addon should exist
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

### `claude --remote` is not recognized

The CLI is older than v2.1.63. Update it as in the prerequisites.
