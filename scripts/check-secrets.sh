#!/usr/bin/env bash
# Secret scan over every commit in a range: bash scripts/check-secrets.sh <base> <head>
#
# Runs gitleaks over each commit in <base>..<head>, so a secret added in one
# commit and removed in a later one is still found. CI runs it on every pull
# request with the PR's base and head. scripts/check-credentials.sh stays the
# fast local check; it reads only the files changed in the working tree.
#
# Pinned: gitleaks 8.30.1, archive gitleaks_8.30.1_linux_x64.tar.gz. The SHA-256
# below is the one in the release asset gitleaks_8.30.1_checksums.txt, read at
# the source by the coordinator on 2026-11-16 (decision H0.1-net on #182). A
# mismatch is a hard failure and nothing in the archive runs. To move the pin,
# change the version and the checksum together, both read from the release.
#
# What gitleaks does not catch: a secret with no rule in .gitleaks.toml or the
# gitleaks defaults, including a password or key with no known prefix and too
# little entropy to pass a generic rule; a secret in a commit message, since
# only the diffs are scanned; a secret in a binary file; and a secret that is
# already in <base>, which is outside the range.
#
# Output names each finding's commit, file and rule, never the secret. Exits 1
# on any finding and on any failure to scan.
#
# GITLEAKS_ARCHIVE  a local copy of the archive to use instead of downloading.
#                   The SHA-256 check applies to it the same way. A path that
#                   does not exist fails; it does not fall back to a download.
# REPO_ROOT         the repository to scan (default: the current directory).
set -uo pipefail

PINNED_VERSION=8.30.1
PINNED_ARCHIVE="gitleaks_${PINNED_VERSION}_linux_x64.tar.gz"
PINNED_SHA256=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
URL="https://github.com/gitleaks/gitleaks/releases/download/v$PINNED_VERSION/$PINNED_ARCHIVE"

SELF_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CONFIG="$SELF_DIR/../.gitleaks.toml"

if [ $# -ne 2 ]; then
  echo "usage: bash scripts/check-secrets.sh <base> <head>" >&2
  exit 1
fi
base_ref=$1
head_ref=$2

[ -n "${REPO_ROOT:-}" ] && { cd "$REPO_ROOT" || exit 1; }
for ref in "$base_ref" "$head_ref"; do
  if ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    echo "FAIL  Cannot resolve '$ref' to a commit in $(pwd -P)."
    exit 1
  fi
done
if [ ! -f "$CONFIG" ]; then
  echo "FAIL  No gitleaks config at $CONFIG."
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -n "${GITLEAKS_ARCHIVE:-}" ]; then
  if [ ! -f "$GITLEAKS_ARCHIVE" ]; then
    echo "FAIL  GITLEAKS_ARCHIVE=$GITLEAKS_ARCHIVE does not exist."
    exit 1
  fi
  archive=$GITLEAKS_ARCHIVE
else
  if [ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]; then
    echo "FAIL  The pinned archive is $PINNED_ARCHIVE; this host is $(uname -s)-$(uname -m). Set GITLEAKS_ARCHIVE."
    exit 1
  fi
  archive="$TMP/$PINNED_ARCHIVE"
  if ! curl -fsSL --max-time 120 -o "$archive" "$URL"; then
    echo "FAIL  Could not download $URL."
    exit 1
  fi
fi

actual=$(sha256sum "$archive" | cut -d' ' -f1)
if [ "$actual" != "$PINNED_SHA256" ]; then
  echo "FAIL  SHA-256 mismatch for $archive: expected $PINNED_SHA256, got $actual. Not scanning."
  exit 1
fi

if ! tar -xzf "$archive" -C "$TMP" gitleaks; then
  echo "FAIL  Could not extract gitleaks from $archive."
  exit 1
fi

commits=$(git rev-list --count "$base_ref..$head_ref")
echo "scanning $commits commit(s) in $base_ref..$head_ref with gitleaks $PINNED_VERSION"

report="$TMP/report.json"
"$TMP/gitleaks" git --no-banner --redact --config "$CONFIG" \
  --log-opts="$base_ref..$head_ref" \
  --report-format json --report-path "$report" --exit-code 1 . > "$TMP/gitleaks.log" 2>&1
rc=$?

if [ $rc -ne 0 ] && [ $rc -ne 1 ]; then
  echo "FAIL  gitleaks exited $rc:"
  sed 's/^/      /' "$TMP/gitleaks.log"
  exit 1
fi
if [ ! -f "$report" ]; then
  echo "FAIL  gitleaks exited $rc and wrote no report."
  exit 1
fi

# Print commit, file and rule only. The Secret and Match fields are never read.
if ! findings=$(node -e '
  const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")) || [];
  for (const f of r) console.log(`FAIL  commit ${f.Commit} file ${f.File} rule ${f.RuleID}`);
' "$report"); then
  echo "FAIL  Could not read the gitleaks report."
  exit 1
fi

if [ -n "$findings" ]; then
  printf '%s\n' "$findings"
  echo "FAIL  $(printf '%s\n' "$findings" | wc -l | tr -d ' ') finding(s) in $base_ref..$head_ref"
  exit 1
fi
if [ $rc -ne 0 ]; then
  echo "FAIL  gitleaks exited $rc with an empty report:"
  sed 's/^/      /' "$TMP/gitleaks.log"
  exit 1
fi
echo "PASS  no secrets in $base_ref..$head_ref"
