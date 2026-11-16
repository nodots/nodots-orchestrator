# BLOCKER: H0.1 — the worker session cannot reach the network, so no pinned checksum, no gitleaks run

**Bucket:** on a missing capability
**Kind:** human-decision
**Reference:** issue #184; the permission policy of the fleet worker session for `feat/h0-1-secret-scanner`
**Owner:** coordinator (Ken Riley)
**Un-blocks when:** a worker session for H0.1 can run `curl`/`gh api` against `github.com` and run a downloaded `gitleaks` binary without an approval prompt, or someone gives the pinned version and SHA-256 from the release's `checksums.txt` and runs the full-history scan on a host with network access

## What was needed, and why

Package #184 needs three things that only the network can provide:

1. **A pinned version and SHA-256, taken from the source.** The script has to
   hold the archive's SHA-256 "against a value written in the script", and its
   header has to say where the checksum came from. The only honest source is the
   `gitleaks_<ver>_checksums.txt` asset on the GitHub release. The contract
   (`.claude/worker-contract.md` §3) says to check an external fact at its
   source. Writing in a checksum from memory would be a fallback that gives a
   plausible wrong answer (§4).
2. **The full-history scan.** Acceptance criterion 4 is "This repo's full
   history is scanned once and the result is reported in the PR". That needs a
   gitleaks binary to run.
3. **A test that can fail.** `scripts/tests/check-secrets.test.sh` downloads
   gitleaks. On this host it would always take the "no network" skip, so the
   test-first step (fail before, pass after) could not be observed.

In this session every network command and every probe for a local binary was
auto-denied: "requires approval, and this session has no approval surface". That
covered `curl -sI https://github.com`,
`gh api repos/gitleaks/gitleaks/releases/latest` and `command -v gitleaks`.

## Alternatives searched

- Use `WebFetch` to read the release's `checksums.txt`. It fails: `WebFetch` passes the
  page through a summarizing model, so a 64-hex digest it returns is not a value
  read at the source. It also can't download or run the binary, so criteria 2–4
  stay unmet.
- Use a gitleaks already on the host. It fails: I couldn't probe for one
  (`command -v gitleaks` was denied). Either way, the package pins and
  downloads one exact version, not whatever happens to be installed.
- Ship the script with a placeholder checksum and let CI fill it in. It fails:
  that's the substituted-answer fallback the contract forbids, and the
  mismatch check would be untested against a real archive.
- Write the script and tests now, then open `[READY]` with the network tests
  skipped. It fails: criterion 4 (full-history scan reported in the PR) and the
  failing-test-first criterion can't be shown, so the stamp would not
  describe a finished package.

## The ask

H0.1-net: How should H0.1 get network access? Options: (a) re-dispatch H0.1 to a
worker session whose permissions allow `curl`, `gh api` and running the
downloaded binary; (b) a person runs
`gh release view --repo gitleaks/gitleaks --json tagName,assets`, fetches
`checksums.txt`, posts the version and the linux_x64 SHA-256 on #184, and runs
`gitleaks git` over the full history once, posting the findings; the worker then
writes the script and tests from those values, and CI provides the network for
the scan. : recommend (a). The package needs a scan to be run and observed,
not just values supplied. : decide-by the next coordinator cycle :
cost-of-waiting: H0.1 stalls, and `scripts/check-credentials.sh` stays the only
secret check in CI, so a secret added and then removed inside a PR still gets
through.
