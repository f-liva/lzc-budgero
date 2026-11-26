#!/usr/bin/env bash
# Read-only week verdict for the headless (spec §12.3, M3 plan Task 7).
#   observe.sh --nas [--since ISO]      fetch the logs from the NAS (root@192.168.8.115) and judge them
#   observe.sh --dir D [--since ISO]    judge rebuilds.log, halts.log, quarantine.json in D
# Criteria: (1) rebuilds.log codes only 75 76 77 78 143; (2) halts.log only quarantine/restore_inproc;
# (3) every quarantine acked; (4) every 24 h window: 75 <= 20 (a 75 right after a 75/76/77 record with
# outbox_size > 0 not counted, as the supervisor does), 77 <= 50. Exit 0 only if all four pass.
set -euo pipefail
dir= since= nas=0
NAS_DIR=/lzcsys/data/appvar/cloud.lazycat.app.budgero/headless
while [ $# -gt 0 ]; do
  case $1 in
    --dir) dir=$2; shift 2 ;;
    --since) since=$2; shift 2 ;;
    --nas) nas=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [ "$nas" = 1 ]; then
  dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
  for f in rebuilds.log halts.log quarantine.json; do
    scp -q -o BatchMode=yes "root@192.168.8.115:$NAS_DIR/$f" "$dir/" 2>/dev/null || true
  done
fi
[ -n "$dir" ] || { echo "need --dir or --nas" >&2; exit 2; }
python3 - "$dir" "$since" <<'EOF'
import json, os, sys
from datetime import datetime, timedelta, timezone
d, since = sys.argv[1], sys.argv[2]
def when(s): return datetime.fromisoformat(s.replace("Z", "+00:00"))
t0 = when(since) if since else datetime.min.replace(tzinfo=timezone.utc)
bad_lines = 0
def lines(name):
    global bad_lines
    p = os.path.join(d, name)
    if not os.path.exists(p): return []
    out = []
    for raw in open(p, encoding="utf-8", errors="replace"):
        if not raw.strip(): continue
        try:
            e = json.loads(raw); t = when(e["ts"])
        except Exception:
            bad_lines += 1; continue
        if t >= t0: out.append((t, e))
    return sorted(out, key=lambda x: x[0])
rebuilds, halts = lines("rebuilds.log"), lines("halts.log")
res = []
odd = sorted({e.get("code") for _, e in rebuilds} - {75, 76, 77, 78, 143}, key=str)
res.append((1, not odd, f"rebuilds.log codes outside 75/76/77/78/143: {odd or 'none'}"))
hodd = sorted({e.get("reason") for _, e in halts} - {"quarantine", "restore_inproc"}, key=str)
res.append((2, not hodd, f"halts.log reasons other than quarantine/restore_inproc: {hodd or 'none'}"))
q = []
qp = os.path.join(d, "quarantine.json")
if os.path.exists(qp):
    try: q = json.load(open(qp)).get("entries", [])
    except Exception: bad_lines += 1
unacked = [e.get("key") for e in q if not e.get("acked")]
res.append((3, not unacked, f"quarantine entries not acked: {unacked or 'none'}"))
counted75, t77, prev = [], [], None
for t, e in rebuilds:
    c = e.get("code")
    if c == 75 and not (prev and prev.get("code") in (75, 76, 77) and (prev.get("outbox_size") or 0) > 0):
        counted75.append(t)
    if c == 77: t77.append(t)
    prev = e
def peak(ts):
    best = 0
    for i, a in enumerate(ts):
        best = max(best, sum(1 for b in ts[i:] if b - a < timedelta(hours=24)))
    return best
p75, p77 = peak(counted75), peak(t77)
res.append((4, p75 <= 20 and p77 <= 50, f"peak per 24 h: 75 = {p75} (max 20), 77 = {p77} (max 50)"))
for n, good, msg in res: print(f"{'PASS' if good else 'FAIL'} {n} {msg}")
passed = sum(1 for _, g, _ in res if g)
print(f"malformed: {bad_lines}")
print(f"{passed}/4 criteria PASS" + (f" since {since}" if since else ""))
sys.exit(0 if passed == 4 else 1)
EOF
