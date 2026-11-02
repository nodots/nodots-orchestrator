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
#   3. PR open, title [VERIFY]:, no current stamp -> cell:awaiting-lab
#   4. BLOCKER.md present on the branch        -> cell:blocked
#   5. branch exists, no PR                    -> cell:active
#   6. none of the above                       -> unchanged
#
# "Current" means the stamp's sha is the PR's head sha. A push after the stamp
# voids it: the evidence was produced by a tree that is no longer the one under
# review. See references/working-agreements.md §Evidence stamps.
#
# Usage:
#   sync-cells.sh --repo <owner/repo> [--target <owner/repo>]... [--epic <n>] [--apply]
#   sync-cells.sh --state <file.json> [--epic <n>] [--apply]
#
#   --repo    the host repo holding the issue graph
#   --target  a repo holding branches and PRs. Repeatable: pass one per target
#             repo in the program. Defaults to --repo for a single-repo setup.
#             Each package names its own repo on its header line
#             (**Repo:** `owner/repo`), and a package naming a repo that was
#             not passed fails the run rather than being reported unchanged.
#   --state   read collected state from a file instead of calling gh; the gh
#             collector writes exactly this shape, so the derivation runs over
#             a fixture and over a live repo through one code path
#   --epic    derive only the packages of epic #<n>: those whose header line
#             says **Part of** #<n>. The per-package BLOCKER.md and PR-comment
#             calls are made for those packages only, so a host repo with a
#             long history of other programs syncs in seconds, and a package of
#             another program that names an uncollected repo does not fail the
#             run. Each collected package records its epic as `partOf`.
#   --apply   write the labels. Without it, nothing is written.
#   --emit-state <file>
#             after collecting (or reading --state), write the state JSON the
#             derivation ran over to <file>. A runtime that drives this script
#             reads its decisions from that file rather than parsing the rows,
#             so there is one derivation and one shape.
#
# Dependencies: bash, node (builtins only), and gh — gh only when --state is
# absent.
set -uo pipefail

APPLY=0
STATE=""
REPO=""
EMIT=""
EPIC=""
TARGETS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --state) STATE="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --target) TARGETS+=("${2:-}"); shift 2 ;;
    --emit-state) EMIT="${2:-}"; shift 2 ;;
    --epic) EPIC="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,44p' "$0"; exit 0 ;;
    *) printf 'sync-cells: unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

if [ -z "$STATE" ] && [ -z "$REPO" ]; then
  printf 'sync-cells: one of --state or --repo is required.\n' >&2
  exit 64
fi
if [ -n "$EPIC" ] && ! [[ "$EPIC" =~ ^[0-9]+$ ]]; then
  printf 'sync-cells: --epic needs an issue number, got: %s\n' "$EPIC" >&2
  exit 64
fi
[ ${#TARGETS[@]} -gt 0 ] || TARGETS=("$REPO")

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- the derivation: one code path for fixtures and for live state ----------
cat > "$TMP/derive.js" <<'JS'
'use strict';
const fs = require('fs');

// The stamp pattern and the current-stamp rule live in stamp.js, beside this
// script. This file runs from a temp directory, so the path is passed in.
const { currentStamp } = require(process.env.SYNC_CELLS_STAMP_MODULE);

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
    // A [VERIFY]: PR is the verifier's queue. Without a current stamp it is
    // waiting on the lab, not on a worker, so it must not read as active.
    if (/^\[VERIFY\]:/.test(String(pr.title || ''))) {
      return ['cell:awaiting-lab', `PR #${pr.number} open, [VERIFY] awaiting the lab`];
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
  # body is needed: each package names its target repo in its header line, and
  # that is what routes it to the right repo's branches and PRs.
  "$GH" issue list --repo "$REPO" --state all --limit "$PAGE_LIMIT" \
     --json number,title,body,labels,state > "$TMP/issues.json" || exit 70

  # One collection per target repo, each row tagged with the repo it came from.
  printf '[]' > "$TMP/prs.json"
  printf '[]' > "$TMP/branches.json"
  for t in "${TARGETS[@]}"; do
    "$GH" pr list --repo "$t" --state all --limit "$PAGE_LIMIT" \
       --json number,title,body,state,headRefName,headRefOid > "$TMP/prs.one.json" || exit 70
    n=$(node -e 'const a=require(process.argv[1]);process.stdout.write(String(a.length))' "$TMP/prs.one.json")
    if [ "$n" -ge "$PAGE_LIMIT" ]; then
      printf 'sync-cells: the pr query for %s returned %s rows, filling the page limit of %s.\n' \
        "$t" "$n" "$PAGE_LIMIT" >&2
      printf '  The collection is truncated, so any label derived from it would be wrong.\n' >&2
      printf '  Raise the limit with SYNC_CELLS_PAGE_LIMIT and run again.\n' >&2
      exit 75
    fi
    # One name per line, reassembled in node: --paginate with a --jq array emits
    # one array PER PAGE, so a repo past 100 branches produced two arrays in one
    # file and JSON.parse failed. Lines survive pagination; arrays do not.
    "$GH" api "repos/$t/branches?per_page=100" --paginate --jq '.[].name' 2>/dev/null \
      | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s.split("\n").filter(Boolean))))' \
      > "$TMP/branches.one.json" || printf '[]' > "$TMP/branches.one.json"
    node - "$TMP" "$t" <<'JS' || exit 70
'use strict';
const fs = require('fs'), path = require('path');
const [dir, repo] = process.argv.slice(2);
const rd = f => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
const prs = rd('prs.json').concat(rd('prs.one.json').map(p => ({ ...p, repo })));
const br = rd('branches.json').concat(rd('branches.one.json').map(name => ({ name, repo })));
fs.writeFileSync(path.join(dir, 'prs.json'), JSON.stringify(prs));
fs.writeFileSync(path.join(dir, 'branches.json'), JSON.stringify(br));
JS
  done

  # A collection that exactly fills the page is indistinguishable from a
  # truncated one, and labels derived from half a backlog are worse than no
  # run at all: a package whose PR fell past the cut looks branch-only and gets
  # downgraded. Say so and stop, rather than reporting a confident partial.
  n=$(node -e 'const a=require(process.argv[1]);process.stdout.write(String(a.length))' "$TMP/issues.json")
  if [ "$n" -ge "$PAGE_LIMIT" ]; then
    printf 'sync-cells: the issues query returned %s rows, filling the page limit of %s.\n' \
      "$n" "$PAGE_LIMIT" >&2
    printf '  The collection is truncated, so any label derived from it would be wrong.\n' >&2
    printf '  Raise the limit with SYNC_CELLS_PAGE_LIMIT and run again.\n' >&2
    exit 75
  fi

  # One pass in node: match PRs to issues by the issue reference in the PR, and
  # branches to issues by the package id, which the numbering rules require to
  # appear in the issue title, the branch name and the PR title alike.
  SYNC_CELLS_EPIC="$EPIC" node - "$TMP" "$REPO" "${TARGETS[@]}" <<'JS' > "$TMP/state.json" || exit 70
'use strict';
const fs = require('fs'), path = require('path');
const [dir, repo, ...targets] = process.argv.slice(2);
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
// A PR belongs to an issue when its title carries the reference or its body
// closes it (GitHub's closing keywords). A bare mention in the body does not
// count: "skips two routes (T5.1d, #363, must delete the list)" is a note
// about #363, not #363's PR, and matching it would relabel a package merged
// on the strength of someone else's PR.
const CLOSES = 'close[sd]?|fix(?:e[sd])?|resolve[sd]?';
const refsIssue = (pr, n) =>
  new RegExp(`#${n}(?!\\d)`).test(pr.title || '') ||
  new RegExp(`\\b(?:${CLOSES})\\s*:?\\s+(?:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?#${n}(?!\\d)`, 'i').test(pr.body || '');

// Each package names its target repo on its header line:
//   **Part of** #1 · **Phase 1 · name** · **Repo:** `owner/repo`
// A bare name is qualified with the host's owner, so `backgammon-core` and
// `nodots/backgammon-core` mean the same thing.
const owner = String(repo).split('/')[0];
const qualify = r => (r.includes('/') ? r : `${owner}/${r}`);
const declaredRepo = body => {
  const m = /\*\*Repo:\*\*\s*`?([A-Za-z0-9_.\-]+(?:\/[A-Za-z0-9_.\-]+)?)`?/.exec(String(body || ''));
  return m ? qualify(m[1]) : null;
};

// The epic a package belongs to, from the same header line: **Part of** #<n>.
const partOf = body => {
  const m = /\*\*Part of\*\*\s*#(\d+)(?!\d)/.exec(String(body || ''));
  return m ? Number(m[1]) : null;
};
const epic = process.env.SYNC_CELLS_EPIC ? Number(process.env.SYNC_CELLS_EPIC) : null;

const out = { repo, targets, issues: [] };
const uncovered = [];
for (const issue of issues) {
  const label = (issue.labels || []).map(l => l.name).find(n => /^cell:/.test(n));
  if (!label) continue;                       // not a package
  const parent = partOf(issue.body);
  // Filter before anything else, so another program's package costs no
  // per-package call and its repo need not be collected.
  if (epic !== null && parent !== epic) continue;
  const id = packageId(issue.title);
  const declared = declaredRepo(issue.body);

  // A package that names a repo nobody collected cannot be judged. Record it;
  // the run fails rather than reporting it as "unchanged", which is
  // indistinguishable from a package that genuinely has nothing.
  if (declared && !targets.includes(declared)) {
    uncovered.push({ number: issue.number, id: id || String(issue.number), repo: declared });
    continue;
  }

  // Search only the package's own repo when it names one.
  const inScope = x => !declared || x.repo === undefined || x.repo === declared;
  const prPool = prs.filter(inScope);
  const brPool = branches.filter(inScope);

  const pr = prPool.find(p => refsIssue(p, issue.number))
          || (id && prPool.find(p => String(p.title).includes(id)))
          || null;
  const brMatch = pr ? null : (id ? brPool.find(b => idMatcher(id).test(b.name)) : null);
  const branch = pr ? pr.headRefName : (brMatch ? brMatch.name : null);

  out.issues.push({
    number: issue.number,
    title: issue.title,
    label,
    partOf: parent,
    repo: declared || (pr && pr.repo) || (brMatch && brMatch.repo) || targets[0],
    branch,
    branchExists: Boolean(branch && (brMatch || pr)),
    blockerOnBranch: false,                   // filled in by the shell below
    pr: pr ? { number: pr.number, title: pr.title, state: pr.state, headSha: pr.headRefOid, comments: [] } : null,
  });
}
if (uncovered.length) {
  const repos = [...new Set(uncovered.map(u => u.repo))];
  process.stderr.write(
    `sync-cells: ${uncovered.length} package(s) name a target repo that was not collected.\n` +
    uncovered.map(u => `  #${u.number} ${u.id} -> ${u.repo}\n`).join('') +
    `  Nothing was derived for them, and a partial run would report them as\n` +
    `  unchanged, which is indistinguishable from having nothing to do.\n` +
    `  Add: ${repos.map(r => `--target ${r}`).join(' ')}\n`);
  process.exit(76);
}
process.stdout.write(JSON.stringify(out, null, 2));
JS

  # BLOCKER.md presence and the PR comment bodies need one call each; do them
  # here rather than in node so the whole script keeps to gh + node builtins.
  local numbers
  # Each row carries its own repo, so a blocker or an evidence stamp is looked
  # up where that package actually lives.
  numbers=$(node -e '
    const s = require("'"$TMP"'/state.json");
    process.stdout.write(s.issues.map((i, k) => [k, i.repo || "", i.branch || "", i.pr ? i.pr.number : ""].join("\t")).join("\n"));
  ')
  : > "$TMP/facts.tsv"
  while IFS=$'\t' read -r idx irepo branch prnum; do
    [ -n "${idx:-}" ] || continue
    local blocker="false" comments="[]"
    # BLOCKER.md lives at the repo root or in the branch's cell directory,
    # the same three places the hooks and the worker contract allow.
    if [ -n "$branch" ]; then
      for bp in "BLOCKER.md" ".agentic/cells/$branch/BLOCKER.md" ".auto-shop/cells/$branch/BLOCKER.md"; do
        if "$GH" api "repos/$irepo/contents/$bp?ref=$branch" --silent >/dev/null 2>&1; then
          blocker="true"; break
        fi
      done
    fi
    if [ -n "$prnum" ]; then
      # Same pagination rule as the branches: one JSON-encoded body per line.
      comments=$("$GH" api "repos/$irepo/issues/$prnum/comments" --paginate --jq '.[].body | @json' 2>/dev/null \
        | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=[];for(const l of s.split("\n")){if(!l.trim())continue;try{o.push(JSON.parse(l))}catch{}}process.stdout.write(JSON.stringify(o))})' \
        || echo '[]')
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

# The same filter over a state file, so --state and the collector agree on what
# --epic means and --emit-state holds only the epic's packages.
if [ -n "$EPIC" ]; then
  node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    s.issues = (s.issues || []).filter(i => i.partOf === Number(process.argv[2]));
    process.stdout.write(JSON.stringify(s, null, 2));
  ' "$STATE" "$EPIC" > "$TMP/state.epic.json" || exit 70
  STATE="$TMP/state.epic.json"
fi

if [ -n "$EMIT" ]; then
  # Write to a sibling and rename, so a reader never sees a half-written file.
  cp "$STATE" "$EMIT.tmp" && mv "$EMIT.tmp" "$EMIT" \
    || { printf 'sync-cells: could not write --emit-state %s\n' "$EMIT" >&2; exit 70; }
fi

SYNC_CELLS_STAMP_MODULE="$(cd "$(dirname "$0")" && pwd -P)/stamp.js" \
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
