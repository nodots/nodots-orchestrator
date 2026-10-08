#!/usr/bin/env bash
# Fixture test for src/store.js: atomic state writes, and a cycle lock that a
# live cycle holds, a dead one loses, and a different boot invalidates.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SRC="$(cd .. && pwd -P)/src/store.js"
assert_file "$SRC" "store.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

js() { node -e "const {Store,bootId}=require('$SRC'); const s=new Store('$TMP/state'); $1"; }

# --- empty state, save, reload -----------------------------------------------
OUT=$(js "const st=s.load(); st.streak=2; st.sessions[7]={issue:7,status:'running'}; s.save(st); const back=s.load(); console.log(back.streak, back.sessions[7].status, Object.keys(back).sort().join(','))")
assert_eq "2 running dispatches,lastCycleId,latched,sessions,streak,unposted,version" "$OUT" "state round-trips and the shape is complete"
[ -e "$TMP/state/state.json.tmp" ] && _fail "no .tmp residue after save" "state.json.tmp exists" || _pass "no .tmp residue after save"
# node, not stat: `stat -f` means "filesystem" on GNU and "format" on BSD.
perm=$(node -e "console.log((require('fs').statSync('$TMP/state/state.json').mode & 0o777).toString(8))")
assert_eq "600" "$perm" "state.json is 0600"

# --- a half-written tmp file never replaces the state ------------------------
printf '{"streak": 9' > "$TMP/state/state.json.tmp"
OUT=$(js "console.log(s.load().streak)")
assert_eq "2" "$OUT" "a stale .tmp beside the state is ignored"

# --- lock: acquire, refuse while held by a live pid, release ----------------
OUT=$(js "const r=s.lock(60000); console.log(r.ok); const r2=s.lock(60000); console.log(r2.ok, r2.reason.includes('holds the lock')); s.unlock(); console.log(require('fs').existsSync(s.lockFile))")
assert_eq $'true\nfalse true\nfalse' "$OUT" "lock acquires, refuses a second acquire by a live pid, and unlock removes it"

# A lock held by a different live process is refused.
sleep 300 & SLEEPER=$!
node -e "
const fs=require('fs'); const {bootId}=require('$SRC');
fs.writeFileSync('$TMP/state/cycle.lock', JSON.stringify({pid:$SLEEPER, host:require('os').hostname(), bootId:bootId(), startedAt:new Date().toISOString()}));"
OUT=$(js "const r=s.lock(60000); console.log(r.ok)")
assert_eq "false" "$OUT" "a lock held by another live process on this host is respected"
kill $SLEEPER 2>/dev/null; wait $SLEEPER 2>/dev/null

# --- stale: dead pid on this host is taken over ------------------------------
node -e "
const fs=require('fs'); const {bootId}=require('$SRC');
fs.writeFileSync('$TMP/state/cycle.lock', JSON.stringify({pid:$SLEEPER, host:require('os').hostname(), bootId:bootId(), startedAt:new Date().toISOString()}));"
OUT=$(js "const r=s.lock(60000); console.log(r.ok, s.staleTakeover && s.staleTakeover.reason); s.unlock()")
assert_eq "true pid dead" "$OUT" "a lock whose pid is dead is taken over and the reason is pid dead"
ls "$TMP/state"/cycle.lock.stale-* >/dev/null 2>&1 && _pass "the stale lock is kept beside the new one" || _fail "the stale lock is kept beside the new one" "no cycle.lock.stale-* file"

# --- stale: a different boot id is taken over even if the pid is alive -------
node -e "
const fs=require('fs');
fs.writeFileSync('$TMP/state/cycle.lock', JSON.stringify({pid:process.ppid, host:require('os').hostname(), bootId:'some-other-boot', startedAt:new Date().toISOString()}));"
OUT=$(js "const r=s.lock(60000); console.log(r.ok, s.staleTakeover && s.staleTakeover.reason); s.unlock()")
assert_eq "true different boot" "$OUT" "a lock from a previous boot is taken over"

# --- stale: too old on another host is taken over; fresh on another host is not
node -e "
const fs=require('fs');
fs.writeFileSync('$TMP/state/cycle.lock', JSON.stringify({pid:1, host:'elsewhere', bootId:'x', startedAt:new Date(Date.now()-7200000).toISOString()}));"
OUT=$(js "const r=s.lock(60000); console.log(r.ok, s.staleTakeover && s.staleTakeover.reason); s.unlock()")
assert_eq "true too old" "$OUT" "an over-age lock from another host is taken over"
node -e "
const fs=require('fs');
fs.writeFileSync('$TMP/state/cycle.lock', JSON.stringify({pid:1, host:'elsewhere', bootId:'x', startedAt:new Date().toISOString()}));"
OUT=$(js "const r=s.lock(60000); console.log(r.ok)")
assert_eq "false" "$OUT" "a fresh lock from another host is respected (the local lock cannot see its pid)"
rm -f "$TMP/state/cycle.lock"

# --- unlock never removes a lock that is not ours ----------------------------
printf '{"pid": 1, "host": "elsewhere"}' > "$TMP/state/cycle.lock"
js "s.unlock()"
assert_file "$TMP/state/cycle.lock" "unlock leaves a lock held by someone else"

finish
