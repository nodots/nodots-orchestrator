#!/usr/bin/env bash
# SessionStart hook (opt-in): prepare a freshly checked-out workspace, and
# refuse to proceed in the wrong repository.
#
# For remote sessions (`claude --remote`), where the workspace starts without
# node_modules. The plugin does not register this hook: running `npm install`
# at the start of every session in every repository is not a default anyone
# should inherit. Wire it by hand from assets/settings-snippet-optional.json.
#
# Control header
# --------------
# Default: install, then verify. It runs `npm install --prefer-offline` in the
#   repo root, or in the first package.json found one directory down, and skips
#   quietly when there is no package.json.
# Exit status: SessionStart never aborts a session. A non-zero exit shows an
#   error notice to the user, and the session proceeds regardless. So this hook
#   cannot enforce the repository check by exiting non-zero. On a mismatch it
#   prints an instruction on stdout, which SessionStart adds to the model's
#   context, and it also writes the mismatch to stderr. It exits 0 on a
#   mismatch for that reason: stdout reaches the model only on exit 0.
# Residue — what this hook does not judge: it does not stop the session, so a
#   worker that ignores the instruction can still run commands in the wrong
#   repository. It reads `.claude/project.json` with grep and sed, so a repo
#   field split across lines is not seen. It checks `origin` only.
#
# Repo root: $CLAUDE_PROJECT_DIR when set, otherwise two directories above this
# file, which is right for a manual `.claude/hooks/` install.
#
# Wire it up in .claude/settings.json:
#   { "hooks": { "SessionStart": [ { "hooks": [ { "type": "command",
#       "command": "bash .claude/hooks/session-start-install-deps.sh" } ] } ] } }

HOOK="session-start-install-deps"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

say() { echo "$HOOK: $*" >&2; }

# --- dependencies ------------------------------------------------------------
INSTALL_DIR="$GIT_ROOT"
if [ ! -f "$GIT_ROOT/package.json" ]; then
  FOUND=$(find "$GIT_ROOT" -maxdepth 2 -name package.json \
    -not -path '*/node_modules/*' | head -1)
  if [ -z "$FOUND" ]; then
    say "no package.json found, skipping npm install"
    INSTALL_DIR=""
  else
    INSTALL_DIR="$(dirname "$FOUND")"
  fi
fi

if [ -n "$INSTALL_DIR" ]; then
  say "running npm install in $INSTALL_DIR"
  if ! (cd "$INSTALL_DIR" && npm install --prefer-offline >&2); then
    say "npm install failed"
    exit 1
  fi
  say "dependencies ready"
fi

# --- GitHub access, reported and never fatal ---------------------------------
if command -v gh >/dev/null 2>&1; then
  if [ -n "${GH_TOKEN:-}" ]; then
    say "gh CLI available, GH_TOKEN set"
  else
    say "gh CLI available but GH_TOKEN is not set; gh operations may fail in remote sessions"
  fi
elif [ -n "${GH_TOKEN:-}" ]; then
  say "gh CLI not installed but GH_TOKEN is set; use the REST API with curl"
else
  say "gh CLI not installed and GH_TOKEN not set; issue reads and PR creation will fail"
fi

# --- repository identity -----------------------------------------------------
PROJECT_JSON="$GIT_ROOT/.claude/project.json"
if [ -f "$PROJECT_JSON" ]; then
  EXPECTED=$(grep '"repo"' "$PROJECT_JSON" | head -1 \
    | sed 's/.*"repo"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  ORIGIN=$(git -C "$GIT_ROOT" remote get-url origin 2>/dev/null || true)
  if [ -n "$EXPECTED" ] && [ -n "$ORIGIN" ]; then
    ACTUAL=$(echo "$ORIGIN" | sed -E 's#(https?://github\.com/|git@github\.com:)##; s/\.git$//')
    if [ "$ACTUAL" = "$EXPECTED" ]; then
      say "repository identity verified ($EXPECTED)"
    else
      say "REPOSITORY MISMATCH: .claude/project.json expects $EXPECTED, origin is $ACTUAL"
      echo "REPOSITORY MISMATCH: .claude/project.json expects $EXPECTED but this checkout's origin is $ACTUAL."
      echo "Do not run git or gh write operations here. Stop, write BLOCKER.md naming both repositories, and wait for the coordinator."
    fi
  fi
fi

exit 0
