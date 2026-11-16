#!/usr/bin/env bash
# sync-cells.sh — derive each package's cell:* label from observable state.
#
# Labels are a projection of reality, never a baton passed between agents. A
# worker-written label is lost at the rate workers compact; a derived one is
# recomputed from the tracker, the branches and the PRs every cycle. A hand-set
# label is a hint that the next sync overwrites.
#
# Precedence, first match wins:
#   1. PR merged, into any base               -> cell:merged
#      the reason ends " (into <base>)" when the base is not the repo's
#      default branch, such as an epic's integration branch
#   2. PR open with a current VERIFIED stamp, and the review policy met
#                                              -> cell:awaiting-review
#      ... and the review policy not met       -> cell:awaiting-reviewer
#   3. PR open, title [VERIFY]:, no current stamp -> cell:awaiting-lab
#   4. BLOCKER.md present on the branch        -> cell:blocked
#   5. branch exists, no PR                    -> cell:active
#   6. none of the above                       -> unchanged
#
# "Current" means the stamp's sha is the PR's head sha. A push after the stamp
# voids it: the evidence was produced by a tree that is no longer the one under
# review. The same holds for a REVIEWED stamp. See
# references/working-agreements.md §Evidence is stamped to a sha.
#
# The review policy is the `review` key of the target repo's
# .claude/standards.json on its default branch (references/standards.md). It
# is read only for a repo with a verified open PR. A repo without the key, or
# without the file, has no policy and rule 2 is awaiting-review as before. A
# policy with a defect, or a manifest that cannot be read, fails the run.
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
#             so there is one derivation and one shape. The collector records
#             each policy it read under reviewPolicies, keyed by repo, and
#             each default branch it read under defaultBranches.
#
# Exit 78 when a target's review policy has a defect, naming the repo and the
# defect.
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
    -h|--help) sed -n '2,64p' "$0"; exit 0 ;;
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

# The stamp rules and the review-policy rules live beside this script; the node
# steps run from the temp directory, so the paths are passed in.
HERE="$(cd "$(dirname "$0")" && pwd -P)"
export SYNC_CELLS_STAMP_MODULE="$HERE/stamp.js"
export SYNC_CELLS_STANDARDS_MODULE="$HERE/check-standards.js"

# --- the derivation: one code path for fixtures and for live state ----------
cat > "$TMP/derive.js" <<'JS'
'use strict';
const fs = require('fs');

const { currentStamp, currentReviews, reviewMet } = require(process.env.SYNC_CELLS_STAMP_MODULE);

const count = (n, one, many) => `${n} ${n === 1 ? one : many}`;

// The reviews found at the head and, when the policy is not met, what is short.
function reviewReason(policy, reviews) {
  const found = reviews.length ? reviews.map(r => r.reviewer).join(', ') : 'none';
  const short = policy.passes - reviews.length;
  return `REVIEWED ${found}; needs ${count(policy.passes, 'review', 'reviews')}` +
         (short > 0 ? `, missing ${count(short, 'review', 'reviews')}` : '');
}

// A merge into an integration branch is a merge: the package is done at the
// first level, and a person merges the branch into the default branch later.
// The reason names the base when it is not the default branch, so the report
// shows where the package landed. The comparison needs the repo's default
// branch, and a state without it fails rather than guessing.
function mergedReason(issue, pr, defaults) {
  const plain = `PR #${pr.number} merged`;
  if (!pr.base) return plain;
  const dflt = defaults[issue.repo];
  if (!dflt) {
    throw new Error(`#${issue.number}: PR #${pr.number} merged into ${pr.base}, but the default branch ` +
                    `of ${issue.repo || '(no repo)'} is not recorded under defaultBranches`);
  }
  return pr.base === dflt ? plain : `${plain} (into ${pr.base})`;
}

function derive(issue, policies, defaults) {
  const pr = issue.pr || null;
  if (pr && String(pr.state).toUpperCase() === 'MERGED') {
    return ['cell:merged', mergedReason(issue, pr, defaults)];
  }
  if (pr && String(pr.state).toUpperCase() === 'OPEN') {
    const stamp = currentStamp(pr);
    if (stamp) {
      const verified = `PR #${pr.number} open, VERIFIED ${stamp.suite} @ ${stamp.sha.slice(0, 7)}`;
      const policy = policies[issue.repo] || null;
      if (!policy) return ['cell:awaiting-review', verified];
      // A verified PR short of its repo's review policy waits on reviewers,
      // not on the person who merges. Reviewer names are free text, so the
      // reason is kept to one line for the tab-separated row.
      const reviews = currentReviews(pr);
      const why = `${verified}, ${reviewReason(policy, reviews)}`.replace(/\s+/g, ' ');
      return [reviewMet(policy, reviews) ? 'cell:awaiting-review' : 'cell:awaiting-reviewer', why];
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
const policies = state.reviewPolicies || {};
const defaults = state.defaultBranches || {};
const rows = [];
for (const issue of state.issues || []) {
  const from = issue.label || '';
  let to, why;
  try { [to, why] = derive(issue, policies, defaults); }
  catch (e) { process.stderr.write(`sync-cells: ${e.message}\n`); process.exit(70); }
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
       --json number,title,body,state,baseRefName,headRefName,headRefOid > "$TMP/prs.one.json" || exit 70
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
// A bare name is qualified with the host's owner, so `acme-core` and
// `acme/acme-core` mean the same thing.
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
          || (id && prPool.find(p => idMatcher(id).test(String(p.title))))
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
    pr: pr ? { number: pr.number, title: pr.title, state: pr.state, base: pr.baseRefName,
               headSha: pr.headRefOid, comments: [] } : null,
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

  # The review policy decides rule 2 only, so read it only for a repo with an
  # open PR carrying a current VERIFIED stamp. No ref: the default branch is
  # the repo's policy; a PR branch could rewrite its own.
  node - "$TMP/state.json" <<'JS' > "$TMP/policy-repos.txt" || exit 70
'use strict';
const fs = require('fs');
const { currentStamp } = require(process.env.SYNC_CELLS_STAMP_MODULE);
const s = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const repos = new Set(s.issues
  .filter(i => i.pr && String(i.pr.state).toUpperCase() === 'OPEN' && currentStamp(i.pr))
  .map(i => i.repo));
process.stdout.write([...repos].map(r => `${r}\n`).join(''));
JS
  : > "$TMP/policies.tsv"
  local k=0 prepo
  while IFS= read -r prepo; do
    [ -n "$prepo" ] || continue
    k=$((k + 1))
    if "$GH" api "repos/$prepo/contents/.claude/standards.json" -H 'Accept: application/vnd.github.raw+json' \
         > "$TMP/manifest.$k" 2> "$TMP/manifest.$k.err"; then
      printf '%s\t%s\n' "$prepo" "$TMP/manifest.$k" >> "$TMP/policies.tsv"
    elif grep -q 'HTTP 404' "$TMP/manifest.$k.err"; then
      printf '%s\t\n' "$prepo" >> "$TMP/policies.tsv"   # no manifest, no policy
    else
      printf 'sync-cells: could not read .claude/standards.json from %s: %s\n' \
        "$prepo" "$(tr '\n' ' ' < "$TMP/manifest.$k.err")" >&2
      exit 70
    fi
  done < "$TMP/policy-repos.txt"

  node - "$TMP/state.json" "$TMP/policies.tsv" <<'JS' > "$TMP/state.policy.json"
'use strict';
const fs = require('fs');
const { validateReview } = require(process.env.SYNC_CELLS_STANDARDS_MODULE);
const state = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const policies = {};
const defects = [];
for (const line of fs.readFileSync(process.argv[3], 'utf8').split('\n')) {
  if (!line) continue;
  const [repo, file] = line.split('\t');
  if (!file) { policies[repo] = null; continue; }
  const at = `${repo}: .claude/standards.json`;
  let m;
  try { m = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (e) { defects.push(`${at}: not valid JSON: ${e.message}`); continue; }
  if (m === null || typeof m !== 'object' || Array.isArray(m)) { defects.push(`${at}: manifest: must be a JSON object`); continue; }
  const review = Object.prototype.hasOwnProperty.call(m, 'review') ? m.review : null;
  const found = validateReview(review);
  if (found.length) { defects.push(...found.map(d => `${at}: ${d}`)); continue; }
  policies[repo] = review === null ? null : { passes: review.passes };
}
if (defects.length) {
  process.stderr.write(defects.map(d => `sync-cells: ${d}\n`).join('') +
    '  The review policy decides which verified PRs wait on reviewers, so\n' +
    '  nothing was derived. Fix the manifest on the default branch.\n');
  process.exit(78);
}
state.reviewPolicies = policies;
process.stdout.write(JSON.stringify(state, null, 2));
JS
  local rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  mv "$TMP/state.policy.json" "$TMP/state.json"

  # The default branch decides only the merged reason's (into <base>) suffix,
  # so read it only for a repo with a merged PR that names its base.
  node -e '
    const s = require(process.argv[1]);
    const repos = new Set(s.issues
      .filter(i => i.pr && String(i.pr.state).toUpperCase() === "MERGED" && i.pr.base)
      .map(i => i.repo));
    process.stdout.write([...repos].map(r => `${r}\n`).join(""));
  ' "$TMP/state.json" > "$TMP/default-repos.txt" || exit 70
  : > "$TMP/defaults.tsv"
  local drepo dflt
  while IFS= read -r drepo; do
    [ -n "$drepo" ] || continue
    if ! dflt=$("$GH" api "repos/$drepo" --jq .default_branch 2> "$TMP/default.err"); then
      printf 'sync-cells: could not read the default branch of %s: %s\n' \
        "$drepo" "$(tr '\n' ' ' < "$TMP/default.err")" >&2
      exit 70
    fi
    if ! [[ "$dflt" =~ ^[^[:space:]]+$ ]]; then
      printf 'sync-cells: the default branch of %s read as [%s], not a branch name.\n' "$drepo" "$dflt" >&2
      exit 70
    fi
    printf '%s\t%s\n' "$drepo" "$dflt" >> "$TMP/defaults.tsv"
  done < "$TMP/default-repos.txt"

  node -e '
    const fs = require("fs");
    const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    s.defaultBranches = {};
    for (const line of fs.readFileSync(process.argv[2], "utf8").split("\n")) {
      if (!line) continue;
      const [repo, branch] = line.split("\t");
      s.defaultBranches[repo] = branch;
    }
    process.stdout.write(JSON.stringify(s, null, 2));
  ' "$TMP/state.json" "$TMP/defaults.tsv" > "$TMP/state.defaults.json" || exit 70
  mv "$TMP/state.defaults.json" "$TMP/state.json"
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
