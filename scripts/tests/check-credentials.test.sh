#!/usr/bin/env bash
# Fixture test for scripts/check-credentials.sh: exits non-zero when a file
# changed against the base ref holds a private-key header or a token prefix, and
# names the file but never the secret. Every seeded secret is built at runtime
# from fragments, so this file holds no literal that trips the scan.
set -uo pipefail
cd "$(dirname "$0")"
. ../../plugins/fleet/tests/lib.sh

SCRIPT="$(cd .. && pwd -P)/check-credentials.sh"
assert_file "$SCRIPT" "scripts/check-credentials.sh exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

# Secret fragments, joined only at runtime.
KEY_HEADER="-----BEG""IN RSA PRIV""ATE KEY-----"
AWS_ID="AK""IA""$(printf 'A1B2C3D4E5F6G7H8')"
GH_TOKEN="gh""p_$(printf 'a%.0s' $(seq 1 36))"
SLACK_TOKEN="xo""xb-1234567890-abcdefghij"

# repo <name> — a git repo with branch "base" holding one clean file, HEAD on "work".
repo() {
  local d="$TMP/$1"
  mkdir -p "$d"
  (
    cd "$d" || exit 1
    git init -q -b base .
    git config user.email t@example.com
    git config user.name t
    echo 'clean' > clean.txt
    git add clean.txt
    git commit -q -m base
    git checkout -q -b work
  )
  echo "$d"
}

run_in() { OUT=$(REPO_ROOT="$1" BASE_REF=base bash "$SCRIPT" 2>&1); RC=$?; }

T=$(repo clean)
echo 'more clean text' > "$T/new.txt"
run_in "$T"
assert_eq "0" "$RC" "a clean change exits 0"

T=$(repo key-untracked)
printf '%s\nabc\n' "$KEY_HEADER" > "$T/leak.pem"
run_in "$T"
assert_ne "0" "$RC" "an untracked file with a private-key header exits non-zero"
assert_contains "$OUT" "leak.pem" "the offending file is named"
assert_not_contains "$OUT" "PRIV""ATE KEY" "the key header is not echoed"

T=$(repo key-committed)
printf '%s\nabc\n' "$KEY_HEADER" > "$T/leak2.pem"
(cd "$T" && git add leak2.pem && git commit -q -m leak)
run_in "$T"
assert_ne "0" "$RC" "a committed file with a private-key header exits non-zero"
assert_contains "$OUT" "leak2.pem" "the committed offending file is named"

T=$(repo aws)
echo "id=$AWS_ID" > "$T/aws.env"
run_in "$T"
assert_ne "0" "$RC" "an AWS access key id exits non-zero"
assert_not_contains "$OUT" "$AWS_ID" "the AWS key is not echoed"

T=$(repo github)
echo "t=$GH_TOKEN" > "$T/gh.env"
run_in "$T"
assert_ne "0" "$RC" "a GitHub token exits non-zero"
assert_not_contains "$OUT" "$GH_TOKEN" "the GitHub token is not echoed"

T=$(repo slack)
echo "t=$SLACK_TOKEN" > "$T/slack.env"
run_in "$T"
assert_ne "0" "$RC" "a Slack token exits non-zero"

T=$(repo unchanged-secret)
printf '%s\n' "$KEY_HEADER" > "$T/old.pem"
(cd "$T" && git add old.pem && git commit -q -m old && git branch -f base HEAD)
run_in "$T"
assert_eq "0" "$RC" "a secret already in the base ref is not a changed file"

T=$(repo bad-base)
run_in "$T"
OUT=$(REPO_ROOT="$T" BASE_REF=no-such-ref bash "$SCRIPT" 2>&1); RC=$?
assert_ne "0" "$RC" "an unresolvable base ref fails closed"
assert_contains "$OUT" "no-such-ref" "the unresolvable ref is named"

finish
