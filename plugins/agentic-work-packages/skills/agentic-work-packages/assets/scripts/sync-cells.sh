#!/usr/bin/env bash
# sync-cells.sh — derive each package's cell:* label from observable state.
#
# Labels are a projection of reality, never a baton passed between agents. A
# worker-written label is lost at the rate workers compact; a derived one is
# recomputed from the tracker, the branches and the PRs every cycle. A hand-set
# label is a hint that the next sync overwrites.
#
# Precedence, first match wins:
#   1. PR merged                              -> cell:merged
#   2. PR open with a current VERIFIED stamp   -> cell:awaiting-review
#   3. BLOCKER.md present on the branch        -> cell:blocked
#   4. branch exists, no PR                    -> cell:active
#   5. none of the above                       -> unchanged
#
# "Current" means the stamp's sha is the PR's head sha. A push after the stamp
# voids it: the evidence was produced by a tree that is no longer the one under
# review. See references/working-agreements.md §Evidence stamps.
#
# Usage:
#   sync-cells.sh --repo <owner/repo> [--target <owner/repo>] [--apply]
#   sync-cells.sh --state <file.json> [--apply]
#
#   --repo    the host repo holding the issue graph
#   --target  the repo holding the branches and PRs (default: --repo)
#   --state   read collected state from a file instead of calling gh; the gh
#             collector writes exactly this shape, so the derivation runs over
#             a fixture and over a live repo through one code path
#   --apply   write the labels. Without it, nothing is written.
#
# Dependencies: bash, node (builtins only), and gh — gh only when --state is
# absent.
set -uo pipefail

APPLY=0
STATE=""
REPO=""
TARGET=""

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --state) STATE="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) printf 'sync-cells: unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

if [ -z "$STATE" ] && [ -z "$REPO" ]; then
  printf 'sync-cells: one of --state or --repo is required.\n' >&2
  exit 64
fi
[ -n "$TARGET" ] || TARGET="$REPO"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- the derivation: one code path for fixtures and for live state ----------
cat > "$TMP/derive.js" <<'JS'
'use strict';
const fs = require('fs');

const STAMP = /^VERIFIED:\s*(\S.*?)\s+@\s+([0-9a-f]{40})\s*$/m;

// A stamp is current only when it names the PR's head sha. Any push after the
// stamp changes that sha and voids the evidence.
function currentStamp(pr) {
  if (!pr || !pr.headSha) return null;
  for (const body of pr.comments || []) {
    const m = STAMP.exec(String(body));
    if (m && m[2] === pr.headSha) return { suite: m[1], sha: m[2] };
  }
  return null;
}

function derive(issue) {
  const pr = issue.pr || null;
  if (pr && String(pr.state).toUpperCase() === 'MERGED') {
    return ['cell:merged', `PR #${pr.number} merged`];
  }
  if (pr && String(pr.state).toUpperCase() === 'OPEN') {
    const stamp = currentStamp(pr);
    if (stamp) {
      return ['cell:awaiting-review',
              `PR #${pr.number} open, VERIFIED ${stamp.suite} @ ${stamp.sha.slice(0, 7)}`];
    }
  }
  if (issue.blockerOnBranch) {
    return ['cell:blocked', `BLOCKER.md on ${issue.branch}`];
  }
  if (issue.branchExists && !pr) {
    return ['cell:active', `branch ${issue.branch} exists, no PR`];
  }
  return [null, 'no rule matched'];
}

const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const rows = [];
for (const issue of state.issues || []) {
  const from = issue.label || '';
  const [to, why] = derive(issue);
  const target = to || from;
  rows.push([issue.number, from, target, target === from ? 'keep' : 'change', why].join('\t'));
}
process.stdout.write(rows.join('\n') + (rows.length ? '\n' : ''));
JS

# --- collect live state into the fixture shape ------------------------------
# GH_BIN exists so the collector can be exercised against a stub in the fixture
# test. It defaults to the real gh and is not a user-facing option.
GH="${GH_BIN:-gh}"
PAGE_LIMIT="${SYNC_CELLS_PAGE_LIMIT:-1000}"

collect_state() {
  command -v "$GH" >/dev/null 2>&1 || {
    printf 'sync-cells: %s is not on PATH; use --state for an offline run.\n' "$GH" >&2
    exit 69
  }
  # --state all, NOT --state open. A package whose PR merged with "Closes #N"
  # has had its issue closed by GitHub, and that is exactly the package which
  # must be relabelled cell:merged. Querying only open issues makes the merged
  # rule unreachable in a live repo, which no fixture over the state file can
  # detect.
  "$GH" issue list --repo "$REPO" --state all --limit "$PAGE_LIMIT" \
     --json number,title,labels,state > "$TMP/issues.json" || exit 70
  "$GH" pr list --repo "$TARGET" --state all --limit "$PAGE_LIMIT" \
     --json number,title,body,state,headRefName,headRefOid > "$TMP/prs.json" || exit 70

  # A collection that exactly fills the page is indistinguishable from a
  # truncated one, and labels derived from half a backlog are worse than no
  # run at all: a package whose PR fell past the cut looks branch-only and gets
  # downgraded. Say so and stop, rather than reporting a confident partial.
  for f in issues prs; do
    n=$(node -e 'const a=require(process.argv[1]);process.stdout.write(String(a.length))' "$TMP/$f.json")
    if [ "$n" -ge "$PAGE_LIMIT" ]; then
      printf 'sync-cells: the %s query returned %s rows, filling the page limit of %s.\n' \
        "$f" "$n" "$PAGE_LIMIT" >&2
      printf '  The collection is truncated, so any label derived from it would be wrong.\n' >&2
      printf '  Raise the limit with SYNC_CELLS_PAGE_LIMIT and run again.\n' >&2
      exit 75
    fi
  done
  "$GH" api "repos/$TARGET/branches?per_page=100" --paginate \
     --jq '[.[].name]' > "$TMP/branches.json" 2>/dev/null || echo '[]' > "$TMP/branches.json"

  # One pass in node: match PRs to issues by the issue reference in the PR, and
  # branches to issues by the package id, which the numbering rules require to
  # appear in the issue title, the branch name and the PR title alike.
  node - "$TMP" "$REPO" "$TARGET" <<'JS' > "$TMP/state.json" || exit 70
'use strict';
const fs = require('fs'), path = require('path');
const [dir, repo, target] = process.argv.slice(2);
const read = f => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
const issues = read('issues.json');
const prs = read('prs.json');
const branches = read('branches.json');

const packageId = title => (String(title).trim().split(/\s+/)[0] || '').replace(/[^\w.\-]+$/, '');

// A branch carries the package id, but not necessarily its case or its dot:
// package M1.3 lives on feat/m1-3-validation as often as on feat/M1.3-....
// Match case-insensitively, treat . and - as the same separator, and require a
// boundary so M1.3 never claims M1.30's branch.
const idMatcher = id => {
  const esc = id.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const sep = esc.replace(/\\\./g, '[.\\-]');
  return new RegExp(`(^|[^a-z0-9])${sep}([^a-z0-9]|$)`, 'i');
};
const refsIssue = (pr, n) => new RegExp(`#${n}(?!\\d)`).test(`${pr.title || ''}\n${pr.body || ''}`);

const out = { repo, target, issues: [] };
for (const issue of issues) {
  const label = (issue.labels || []).map(l => l.name).find(n => /^cell:/.test(n));
  if (!label) continue;                       // not a package
  const id = packageId(issue.title);
  const pr = prs.find(p => refsIssue(p, issue.number))
          || (id && prs.find(p => String(p.title).includes(id)))
          || null;
  const branch = pr ? pr.headRefName
                    : (id ? branches.find(b => idMatcher(id).test(b)) : null) || null;
  out.issues.push({
    number: issue.number,
    title: issue.title,
    label,
    branch,
    branchExists: Boolean(branch && (branches.includes(branch) || pr)),
    blockerOnBranch: false,                   // filled in by the shell below
    pr: pr ? { number: pr.number, state: pr.state, headSha: pr.headRefOid, comments: [] } : null,
  });
}
process.stdout.write(JSON.stringify(out, null, 2));
JS

  # BLOCKER.md presence and the PR comment bodies need one call each; do them
  # here rather than in node so the whole script keeps to gh + node builtins.
  local numbers
  numbers=$(node -e '
    const s = require("'"$TMP"'/state.json");
    process.stdout.write(s.issues.map((i, k) => [k, i.branch || "", i.pr ? i.pr.number : ""].join("\t")).join("\n"));
  ')
  : > "$TMP/facts.tsv"
  while IFS=$'\t' read -r idx branch prnum; do
    [ -n "${idx:-}" ] || continue
    local blocker="false" comments="[]"
    if [ -n "$branch" ] && "$GH" api "repos/$TARGET/contents/BLOCKER.md?ref=$branch" \
         --silent >/dev/null 2>&1; then
      blocker="true"
    fi
    if [ -n "$prnum" ]; then
      comments=$("$GH" api "repos/$TARGET/issues/$prnum/comments" --paginate \
                   --jq '[.[].body]' 2>/dev/null || echo '[]')
    fi
    printf '%s\t%s\t%s\n' "$idx" "$blocker" "$comments" >> "$TMP/facts.tsv"
  done <<< "$numbers"

  node - "$TMP/state.json" "$TMP/facts.tsv" <<'JS' > "$TMP/state.final.json" || exit 70
'use strict';
const fs = require('fs');
const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
for (const line of fs.readFileSync(process.argv[3], 'utf8').split('\n')) {
  if (!line.trim()) continue;
  const [idx, blocker, comments] = line.split('\t');
  const issue = state.issues[Number(idx)];
  if (!issue) continue;
  issue.blockerOnBranch = blocker === 'true';
  if (issue.pr) { try { issue.pr.comments = JSON.parse(comments); } catch { issue.pr.comments = []; } }
}
process.stdout.write(JSON.stringify(state, null, 2));
JS
  mv "$TMP/state.final.json" "$TMP/state.json"
  STATE="$TMP/state.json"
}

[ -n "$STATE" ] || collect_state
[ -f "$STATE" ] || { printf 'sync-cells: no such state file: %s\n' "$STATE" >&2; exit 66; }

node "$TMP/derive.js" "$STATE" > "$TMP/rows.tsv" || exit 70

changes=0
while IFS=$'\t' read -r number from to action why; do
  [ -n "${number:-}" ] || continue
  if [ "$action" = "change" ]; then
    changes=$((changes + 1))
    printf '#%s  %s -> %s   (%s)\n' "$number" "${from:-none}" "$to" "$why"
    if [ "$APPLY" = "1" ]; then
      [ -n "$REPO" ] || { printf 'sync-cells: --apply needs --repo.\n' >&2; exit 64; }
      if [ -n "$from" ]; then
        "$GH" issue edit "$number" --repo "$REPO" --remove-label "$from" --add-label "$to" >/dev/null \
          || printf '  ! failed to relabel #%s\n' "$number" >&2
      else
        "$GH" issue edit "$number" --repo "$REPO" --add-label "$to" >/dev/null \
          || printf '  ! failed to label #%s\n' "$number" >&2
      fi
    fi
  else
    printf '#%s  %s   (unchanged: %s)\n' "$number" "${from:-none}" "$why"
  fi
done < <(sort -t"#" -k1 -n "$TMP/rows.tsv")

if [ "$APPLY" = "1" ]; then
  printf '\n%d label(s) written.\n' "$changes"
else
  printf '\n%d label(s) would change. Dry run; pass --apply to write.\n' "$changes"
fi
