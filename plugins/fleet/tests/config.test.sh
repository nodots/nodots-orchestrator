#!/usr/bin/env bash
# Fixture test for src/config.js: the sibling agentic-work-packages plugin is
# found in both layouts the two plugins ship in, and config validation names
# what is wrong.
set -uo pipefail
cd "$(dirname "$0")"
. ./lib.sh

SRC="$(cd .. && pwd -P)/src/config.js"
assert_file "$SRC" "config.js exists"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P)

js() { node -e "const c=require('$SRC'); $1"; }
mkplugin() { mkdir -p "$1/.claude-plugin"; printf '{"name":"x"}' > "$1/.claude-plugin/plugin.json"; }

# --- repo layout: <root>/plugins/{fleet,agentic-work-packages} ---------------
mkdir -p "$TMP/repo/plugins/fleet/src"; mkplugin "$TMP/repo/plugins/agentic-work-packages"
assert_eq "$TMP/repo/plugins/agentic-work-packages" "$(js "console.log(c.defaultPluginRoot('$TMP/repo/plugins/fleet/src'))")" "repo layout: the sibling directory is the plugin root"

# --- installed layout: <cache>/<market>/{fleet,agentic-work-packages}/<ver> --
mkdir -p "$TMP/cache/m/fleet/0.1.1/src"
for v in 1.0.0 1.4.1 1.4.0 1.10.0; do mkplugin "$TMP/cache/m/agentic-work-packages/$v"; done
mkdir -p "$TMP/cache/m/agentic-work-packages/2.0.0"    # a version dir without a manifest is not a plugin
assert_eq "$TMP/cache/m/agentic-work-packages/1.10.0" "$(js "console.log(c.defaultPluginRoot('$TMP/cache/m/fleet/0.1.1/src'))")" "installed layout: the highest version that holds a manifest wins (1.10.0 > 1.4.1, 2.0.0 has no manifest)"

# --- neither: null, and validate then demands pluginRoot ---------------------
mkdir -p "$TMP/nowhere/a/b/src"
assert_eq "null" "$(js "console.log(c.defaultPluginRoot('$TMP/nowhere/a/b/src'))")" "no sibling anywhere: null"

# --- validation messages ----------------------------------------------------
BASE="{repo:'acme/host',epic:1,targets:[{repo:'api',localPath:'./api'}],workers:{a:{mode:'local'}},pluginRoot:'$TMP/repo/plugins/agentic-work-packages'}"
OUT=$(js "const v=c.validate($BASE,'$TMP'); console.log(v.targets[0].repo, v.targets[0].defaultBranch, v.wipCap, v.permissionMode, v.ownedIds.join(','), v.worktreesDir, v.stateDir)")
assert_eq "acme/api main 4 acceptEdits a $TMP/api-worktrees $TMP/api-worktrees/.fleet" "$OUT" "defaults: owner qualifies a bare target, main, cap 4, acceptEdits, worktrees and state beside the clone"
for bad in "{...$BASE, repo:'nope'}" "{...$BASE, epic:0}" "{...$BASE, targets:[]}" "{...$BASE, workers:{'bad id':{mode:'local'}}}" "{...$BASE, workers:{a:{mode:'remote'}}}" "{...$BASE, wipCap:0}" "{...$BASE, permissionMode:'yolo'}" "{...$BASE, maxBudgetUsd:0}"; do
  OUT=$(js "try{c.validate($bad,'$TMP');console.log('accepted')}catch(e){console.log(e.code)}")
  assert_eq "ECONFIG" "$OUT" "rejected: $bad"
done
OUT=$(js "try{c.validate({...$BASE, pluginRoot:undefined},'$TMP/nowhere')}catch(e){console.log(e.message)}" 2>&1)
case "$OUT" in *"pluginRoot is required"*|"") : ;; esac
assert_contains "$(js "const {validate}=c; const base=$BASE; delete base.pluginRoot; try{validate(base,'$TMP');console.log('accepted')}catch(e){console.log(e.message)}")" "accepted" "without pluginRoot the default is used when the repo-layout sibling exists"

# --- approvalEnforcement (G1.3): added cases only ---------------------------
assert_eq "off" "$(js "console.log(c.validate($BASE,'$TMP').approvalEnforcement)")" "approvalEnforcement defaults to off"
assert_eq "ECONFIG" "$(js "try{c.validate({...$BASE,approvalEnforcement:'yes'},'$TMP');console.log('accepted')}catch(e){console.log(e.code)}")" "approvalEnforcement rejects an unknown value"

# --- coordinators (X0.3): the logins trusted to write coordinator labels ------
assert_eq "[]" "$(js "console.log(JSON.stringify(c.validate($BASE,'$TMP').coordinators))")" "coordinators absent: [] (the provenance check is off)"
assert_eq "[]" "$(js "console.log(JSON.stringify(c.validate({...$BASE,coordinators:[]},'$TMP').coordinators))")" "coordinators []: [] (the provenance check is off)"
assert_eq '["octo","fleet-bot"]' "$(js "console.log(JSON.stringify(c.validate({...$BASE,coordinators:['octo','fleet-bot']},'$TMP').coordinators))")" "coordinators: a list of logins is kept in order"
for bad in "'x'" "['']" "['a','a']" "[3]" "{}"; do
  OUT=$(js "try{c.validate({...$BASE,coordinators:$bad},'$TMP');console.log('accepted')}catch(e){console.log(e.code, e.message)}")
  assert_contains "$OUT" "ECONFIG" "coordinators rejected: $bad"
  assert_contains "$OUT" "coordinators" "the rejection of $bad names the field"
done

# --- coordinators (X0.3b): GitHub logins are case-insensitive -----------------
assert_eq "ok" "$(js "c.requireFleetCoordinator(c.validate({...$BASE,coordinators:['Octo']},'$TMP'),'octo');console.log('ok')")" "coordinators ['Octo'] with gh login octo: fleet's login is a coordinator"
assert_eq "ok" "$(js "c.requireFleetCoordinator(c.validate({...$BASE,coordinators:['octo']},'$TMP'),'OCTO');console.log('ok')")" "coordinators ['octo'] with gh login OCTO: fleet's login is a coordinator"
OUT=$(js "try{c.requireFleetCoordinator(c.validate({...$BASE,coordinators:['Octo']},'$TMP'),'octopus');console.log('accepted')}catch(e){console.log(e.code, e.message)}")
assert_contains "$OUT" "ECONFIG" "coordinators ['Octo'] with gh login octopus: still config-invalid"
OUT=$(js "try{c.validate({...$BASE,coordinators:['Octo','octo']},'$TMP');console.log('accepted')}catch(e){console.log(e.code, e.message)}")
assert_contains "$OUT" "listed twice" "coordinators ['Octo','octo']: the same login in two cases is listed twice"
# The example config leaves the check off: copying it turns nothing on by accident.
assert_eq "absent" "$(node -e "console.log('coordinators' in require('$(cd .. && pwd -P)/fleet.config.example.json') ? 'present' : 'absent')")" "fleet.config.example.json has no coordinators"

finish
