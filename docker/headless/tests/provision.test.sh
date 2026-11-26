#!/usr/bin/env bash
# Tests for docker/headless/provision.sh. Usage: bash docker/headless/tests/provision.test.sh
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
P="$here/provision.sh"
uid=$(id -u)
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; }
KEY32=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
KEY31=$(head -c 31 /dev/urandom | base64 | tr -d '\n')
PW='S3cret-Pw-do-not-print'
run() { # dir, key, extra args...; feeds password + key on stdin
  local d=$1 k=$2; shift 2
  printf '%s\n%s\n' "$PW" "$k" | sh "$P" --dir "$d" --user me@example.test --space-id sp-1 --budget-id 7 --uid "$uid" "$@" >"$d.out" 2>"$d.err"
}
mode() { stat -c %a "$1"; }

d=$(mktemp -d); run "$d" "$KEY32"; rc=$?
[ $rc -eq 0 ] && ok "exit 0 on valid input" || ko "exit 0 on valid input (rc=$rc: $(cat "$d.err"))"
python3 - "$d/config.json" <<'EOF' && ok "config.json has the expected fields, readOnly true" || ko "config.json fields"
import json, sys
c = json.load(open(sys.argv[1]))
assert c == {"url": "http://budgero.cloud.lazycat.app.budgero.lzcapp:3001/api/v1", "user": "me@example.test",
             "spaceId": "sp-1", "budgetId": 7, "readOnly": True, "allowDestructive": False, "port": 8787}, c
EOF
m="$(mode "$d/password") $(mode "$d/space.key") $(mode "$d/tokens")"
[ "$m" = "600 600 600" ] && ok "secrets are mode 600" || ko "secrets are mode 600 (got $m)"
[ "$(cat "$d/password")" = "$PW" ] && ok "password stored verbatim" || ko "password stored verbatim"
[ "$(tr -d '\n' < "$d/space.key")" = "$KEY32" ] && ok "space.key stored verbatim" || ko "space.key stored verbatim"
if grep -Eq '^ambrogio:read:[0-9a-f]{64}$' "$d/tokens" && grep -Eq '^operator:write:[0-9a-f]{64}$' "$d/tokens" \
   && grep -Eq '^admin:admin:[0-9a-f]{64}$' "$d/tokens" && [ "$(grep -c . "$d/tokens")" -eq 3 ]; then
  ok "tokens: 3 lines read/write/admin, 64 hex"; else ko "tokens format: $(sed 's/:[0-9a-f]*$/:<hex>/' "$d/tokens")"; fi
rt=$(sed -n 's/^ambrogio:read://p' "$d/tokens"); wt=$(sed -n 's/^operator:write://p' "$d/tokens"); at=$(sed -n 's/^admin:admin://p' "$d/tokens")
grep -q "$rt" "$d.out" && ok "stdout shows the read token" || ko "stdout shows the read token"
if grep -q "$wt" "$d.out" "$d.err" || grep -q "$at" "$d.out" "$d.err"; then ko "write/admin tokens leaked"; else ok "write/admin tokens never printed"; fi
if grep -q "$PW" "$d.out" "$d.err" || grep -q "$KEY32" "$d.out" "$d.err"; then ko "password or key leaked"; else ok "password and key never printed"; fi

run "$d" "$KEY32"; rc=$?
[ $rc -eq 3 ] && ok "existing secrets without --force ⇒ exit 3" || ko "existing secrets without --force ⇒ exit 3 (rc=$rc)"
[ "$(sed -n 's/^ambrogio:read://p' "$d/tokens")" = "$rt" ] && ok "refused run left tokens untouched" || ko "refused run changed tokens"
run "$d" "$KEY32" --force; rc=$?
[ $rc -eq 0 ] && [ "$(sed -n 's/^ambrogio:read://p' "$d/tokens")" != "$rt" ] && ok "--force regenerates" || ko "--force regenerates (rc=$rc)"

e=$(mktemp -d); run "$e" "$KEY31"; rc=$?
[ $rc -eq 2 ] && ok "31-byte space.key ⇒ exit 2" || ko "31-byte space.key ⇒ exit 2 (rc=$rc)"
[ -z "$(ls -A "$e")" ] && ok "nothing written on a bad key" || ko "files written on a bad key: $(ls "$e")"
f=$(mktemp -d); run "$f" "not base64 !!"; rc=$?
[ $rc -eq 2 ] && [ -z "$(ls -A "$f")" ] && ok "non-base64 space.key ⇒ exit 2, nothing written" || ko "non-base64 key (rc=$rc)"
g=$(mktemp -d); printf '\n%s\n' "$KEY32" | sh "$P" --dir "$g" --user u --space-id s --budget-id 7 --uid "$uid" >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && [ -z "$(ls -A "$g")" ] && ok "empty password ⇒ exit 2" || ko "empty password (rc=$rc)"
h=$(mktemp -d); printf '%s\n%s\n' "$PW" "$KEY32" | sh "$P" --dir "$h" --user u --space-id s --budget-id 1.5 --uid "$uid" >/dev/null 2>&1; rc=$?
[ $rc -eq 2 ] && ok "non-integer budget id ⇒ exit 2" || ko "non-integer budget id (rc=$rc)"

rm -rf "$d" "$e" "$f" "$g" "$h" "$d".out "$d".err "$e".out "$e".err "$f".out "$f".err
echo "$pass passed, $fail failed"; [ $fail -eq 0 ]
