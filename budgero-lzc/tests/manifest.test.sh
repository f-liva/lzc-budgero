#!/usr/bin/env bash
# Checks the headless service in lzc-manifest.yml (spec §11 + M3 plan Task 2).
# Usage: bash budgero-lzc/tests/manifest.test.sh   (from the repo root or anywhere)
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
repo=$(cd "$here/.." && pwd)
# The budgero service must stay exactly as deployed in 1.0.21 (dfe406a).
baseline=$(git -C "$repo" show dfe406a:budgero-lzc/lzc-manifest.yml)
BASELINE="$baseline" python3 - "$here/lzc-manifest.yml" <<'EOF'
import os, sys, yaml
m = yaml.safe_load(open(sys.argv[1]))
base = yaml.safe_load(os.environ["BASELINE"])
fails = []
def check(cond, msg):
    if not cond: fails.append(msg)

h = m.get("services", {}).get("headless")
check(h is not None, "service headless missing")
if h:
    img = h.get("image", "")
    check(img.startswith("registry.lazycat.cloud/") and ":latest" not in img and "@" not in img.split("/")[0],
          f"image must be a registry.lazycat.cloud tag, got {img!r}")
    check("budgero-headless" in img, f"image must be the headless image, got {img!r}")
    check(str(h.get("user")) == "1001:1001", f"user must be 1001:1001, got {h.get('user')!r}")
    # setup_script makes /lzcinit pid 1, and lzcinit does not forward TERM: the supervisor would never
    # see a stop (measured 26/11/2026, plan M3 I-4). provision.sh chowns the dir instead.
    check("setup_script" not in h, "setup_script must be absent: lzcinit swallows TERM")
    check(h.get("binds") == ["/lzcapp/var/headless:/lzcapp/var/headless"], f"binds differ: {h.get('binds')!r}")
    check(h.get("environment") == ["TZ=Europe/Rome", "BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}"],
          f"environment must be exactly TZ + BUDGERO_ORIGIN, got {h.get('environment')!r}")
    hc = h.get("health_check") or {}
    check(hc.get("test") == ["CMD", "wget", "-qO-", "http://localhost:8787/healthz"], f"health_check.test differs: {hc.get('test')!r}")
    check(str(hc.get("start_period")) == "120s", f"start_period must be 120s, got {hc.get('start_period')!r}")
    check("restart" not in h, "restart is ignored by Lazycat: do not declare it")

routes = m.get("application", {}).get("routes", [])
check(not any("headless" in r for r in routes), f"headless must not be routed on the Lazycat subdomain: {routes!r}")
check(m["services"].get("budgero") == base["services"]["budgero"], "budgero service changed vs 1.0.21")
check(m.get("application") == base.get("application"), "application section changed vs 1.0.21")

if fails:
    print("FAIL:\n  " + "\n  ".join(fails)); sys.exit(1)
print("PASS: manifest headless service")
EOF
grep -q '^version: 1.0.25$' "$here/package.yml" || { echo "FAIL: package.yml version must be 1.0.25"; exit 1; }
echo "PASS: package.yml 1.0.25"
