#!/usr/bin/env bash
# Tests for docker/headless/observe.sh. Usage: bash docker/headless/tests/observe.test.sh
set -uo pipefail
O="$(cd "$(dirname "$0")/.." && pwd)/observe.sh"
pass=0; fail=0
ok() { pass=$((pass+1)); echo "ok   $1"; }
ko() { fail=$((fail+1)); echo "FAIL $1"; }
ts() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }
SINCE=$(ts '-7 days')
clean() { # a clean week: a few 143 (nightly power-off), 78 at boot, one 77, one acked quarantine
  local d; d=$(mktemp -d)
  for i in 6 5 4 3 2 1; do
    printf '{"ts":"%s","code":143,"reason":"term","outbox_size":0}\n' "$(ts "-$i days")" >> "$d/rebuilds.log"
    printf '{"ts":"%s","code":78,"reason":"retry_bootstrap","outbox_size":0}\n' "$(ts "-$i days +5 hours")" >> "$d/rebuilds.log"
  done
  printf '{"ts":"%s","code":77,"reason":"quarantine","outbox_size":0}\n' "$(ts '-2 days')" >> "$d/rebuilds.log"
  printf '{"ts":"%s","reason":"quarantine"}\n{"ts":"%s","reason":"restore_inproc"}\n' "$(ts '-2 days')" "$(ts '-2 days')" > "$d/halts.log"
  printf '{"entries":[{"key":"m1","version":3,"op":"x.y","error":{"name":"E","message":"m"},"at":"%s","acked":true,"covered":false,"tainted":false}]}\n' "$(ts '-2 days')" > "$d/quarantine.json"
  echo "$d"
}
expect() { # name, dir, want_rc, grep pattern
  local out rc; out=$(bash "$O" --dir "$2" --since "$SINCE" 2>&1); rc=$?
  if [ "$rc" -eq "$3" ] && echo "$out" | grep -q -- "$4"; then ok "$1"; else ko "$1 (rc=$rc): $out"; fi
}

d=$(clean); expect "clean week ⇒ exit 0, all PASS" "$d" 0 "4/4 criteria PASS"
d=$(clean); printf '{"ts":"%s","code":1,"reason":"config:tokens","outbox_size":0}\n' "$(ts '-1 days')" >> "$d/rebuilds.log"
expect "code 1 ⇒ criterion 1 FAIL" "$d" 1 "FAIL 1 "
d=$(clean); printf '{"ts":"%s","reason":"auth_failed"}\n' "$(ts '-1 days')" >> "$d/halts.log"
expect "auth_failed halt ⇒ criterion 2 FAIL" "$d" 1 "FAIL 2 "
d=$(clean); sed -i 's/"acked":true/"acked":false/' "$d/quarantine.json"
expect "unacked quarantine ⇒ criterion 3 FAIL" "$d" 1 "FAIL 3 "
d=$(clean); for i in $(seq 1 21); do printf '{"ts":"%s","code":75,"reason":"drain","outbox_size":0}\n' "$(ts "-1 days +$i minutes")" >> "$d/rebuilds.log"; done
expect "21 × 75 in one day ⇒ criterion 4 FAIL" "$d" 1 "FAIL 4 "
d=$(clean); for i in $(seq 1 10); do printf '{"ts":"%s","code":75,"reason":"r","outbox_size":1}\n{"ts":"%s","code":75,"reason":"drain","outbox_size":0}\n' "$(ts "-1 days +$i minutes")" "$(ts "-1 days +$i minutes +10 seconds")" >> "$d/rebuilds.log"; done
expect "a 75 after a 75 with outbox_size>0 is not counted (10+10 ⇒ 10)" "$d" 0 "4/4 criteria PASS"
d=$(clean); for i in $(seq 1 51); do printf '{"ts":"%s","code":77,"reason":"blob_newer","outbox_size":0}\n' "$(ts "-3 days +$i minutes")" >> "$d/rebuilds.log"; done
expect "51 × 77 in one day ⇒ criterion 4 FAIL" "$d" 1 "FAIL 4 "
d=$(clean); echo 'garbage{' >> "$d/rebuilds.log"
expect "garbage line reported, still exit 0" "$d" 0 "malformed: 1"
d=$(clean); printf '{"ts":"%s","code":1,"reason":"old","outbox_size":0}\n' "$(ts '-20 days')" >> "$d/rebuilds.log"
expect "lines before --since ignored" "$d" 0 "4/4 criteria PASS"
d=$(mktemp -d); expect "empty dir (no logs yet) ⇒ exit 0" "$d" 0 "4/4 criteria PASS"

out=$(OBSERVE_NAS=root@nas.invalid bash "$O" --nas --since "$SINCE" 2>&1); rc=$?
if [ "$rc" -eq 2 ] && ! echo "$out" | grep -q "criteria PASS"; then ok "NAS unreachable ⇒ exit 2, no verdict"; else ko "NAS unreachable (rc=$rc): $out"; fi

echo "$pass passed, $fail failed"; [ $fail -eq 0 ]
