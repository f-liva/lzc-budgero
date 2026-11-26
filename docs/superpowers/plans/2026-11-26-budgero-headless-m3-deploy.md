# Budgero Headless — Milestone 3 (deploy, read-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The headless runs on the NAS as a second service of the `lzc-budgero` package, read-only, reachable by Ambrogio through a public tunnel hostname behind Cloudflare Access + bearer token, and is observed for 7 days against the spec §12.3 criteria before writes are enabled.

**Architecture:** Service `headless` added to `budgero-lzc/lzc-manifest.yml` (spec §11), talking to the server on the package's internal network (`http://budgero.cloud.lazycat.app.budgero.lzcapp:3001`, Origin `https://${LAZYCAT_APP_DOMAIN}`). Ambrogio is a different lzcapp and Lazycat isolates apps (verified 26/11/2026: from the Ambrogio container the internal name resolves to `fd03:…` and every connect times out; the `heiyu.space` domain answers 307 to the Lazycat login). Federico chose (26/11/2026) to reach the headless through the existing Cloudflare tunnel (`cloudflared` runs on the host network and already reaches `*.lzcapp` names) on a new public hostname, protected at the edge by a Cloudflare Access **service token** and in the app by the bearer tokens.

**Tech Stack:** Lazycat lpk (`lzc-cli`, `lpk-manager`), Docker image `fliva/budgero-headless:1.22.1-2` (Docker Hub, sha256 `11f60894…`), Cloudflare One (tunnel public hostname + Access application), busybox sh.

**Spec:** `/home/fede9/Progetti/lzc-budgero/docs/superpowers/specs/2026-11-24-budgero-headless-client-design.md` (§3, §7.4.1, §11, §12.3, §15). This plan **amends §3** (non-goal "public exposure"): Task 1 records the amendment.

## Repositories and state at plan time (26/11/2026)

| What | Where / state |
|---|---|
| Headless code | f-liva/budgero `feat/headless-client` = `f72fbc55`, tag `headless-v1.22.1-2` (pushed) |
| Image | `fliva/budgero-headless:1.22.1-2` on Docker Hub; not yet mirrored to `registry.lazycat.cloud` |
| NAS server | budgero v1.22.1, lzc-budgero 1.0.21 (`dfe406a`); current blob bound (sync_version 83, mutation_version 774) |
| Pre-upgrade backup | `/lzcsys/var/backups/budgero-data-20261126-153134.tar.gz` (sha256 `398e82aa…467d`) |
| Bench scenario 24 (JWT refresh, ~65 min) | running at plan time; **must be green before Task 4** |

Commits in `lzc-budgero` (branch `main`), no AI attribution. Anything that leaves the machine (registry mirror, NAS install, Cloudflare change, push) needs Federico's go at that step.

## Global Constraints

- Production env of the headless: only `TZ=Europe/Rome` and `BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}` (§11).
- `config.json`: `url` = `http://budgero.cloud.lazycat.app.budgero.lzcapp:3001/api/v1`, `port` = `8787`, `readOnly: true`, `allowDestructive: false` for the whole M3.
- Secrets `password`, `space.key`, `tokens`: mode `600`, owner uid `1001`, in `/lzcapp/var/headless` (= `/lzcsys/data/appvar/cloud.lazycat.app.budgero/headless` on the host). Never in chat, logs, repo, Vikunja or BookStack.
- Server and headless are pinned together (`version_mismatch` otherwise): any future lzc-budgero server bump ships a headless image built at the same upstream tag in the same release.
- `services.*.restart` is ignored by Lazycat (RestartPolicy=no): the in-container supervisor is the only restarter (§5).
- NAS rules (`/AGENTS.md`): no recursive scans of `/`, `/data`, `/lzcsys/data`; read `/lzcsys/data/README` before locating data.
- `/v1/admin/*` must never be reachable from the internet (edge rule, Task 5); operator admin calls go through `lzc-docker exec … wget localhost:8787`.

## Review Focus

1. **NAS nightly power-off 02:00→07:00 and the boot DNS race** (resolver not ready for ~30 s after boot): the headless must come back `live` by itself every morning; 78 retries must not exhaust (20 consecutive) during the DNS window. → Task 6 (reboot check).
2. **Tunnel down in the morning** (known, lzc-cloudflared): Ambrogio sees Cloudflare 5xx; the headless itself is unaffected (internal URL). → Task 6 asserts the headless does not depend on the tunnel.
3. **Container restart after a config change** loses nothing: config/secrets on the bind mount survive `lpk-manager` upgrade of the package. → Task 4 (upgrade 1.0.22 → 1.0.22+1 dry run is out of scope; assert files survive one app restart and one reinstall of the same lpk).
4. **Wrong `budgetId` or wrong `space.key` typed at provisioning**: must end `halted access_denied` / `bootstrap_failed:decrypt`, never a loop, and the operator must see the reason in `/v1/status`. → Task 4.
5. **Access misconfiguration** (service token missing, path rule wrong): a request without the Access headers must never reach the headless. → Task 5 tests from outside with and without headers.

## Considered and rejected

- `lzc-docker network connect` of the Ambrogio container to the Budgero network (works without public exposure — used for Fatturo→Paperless) — rejected because it is lost at every lpk upgrade of either app (Vikunja 547 precedent).
- Headless inside the Ambrogio package — rejected by Federico (26/11/2026).

---

### Task 1: Spec amendment for the public route

**Files:**
- Modify: `docs/superpowers/specs/2026-11-24-budgero-headless-client-design.md` (§15, new sub-list "M3 amendments (26/11/2026)")

- [ ] **Step 1:** Add, one line each: (a) §3 non-goal "public exposure" is replaced by "exposure only through the Cloudflare tunnel hostname `budgero-api.federicoliva.it`, behind a Cloudflare Access application with Service Auth (service token) and the bearer tokens; `/v1/admin/*` and `/v1/debug/*` blocked at the edge"; (b) the reason (Lazycat isolates lzcapps; measurement above); (c) Ambrogio sends `CF-Access-Client-Id`/`CF-Access-Client-Secret` plus `Authorization: Bearer <read token>`; (d) §11 "Ambrogio reaches `http://headless.cloud.lazycat.app.budgero.lzcapp:8787`" is superseded.
- [ ] **Step 2:** Commit — `docs(spec): §15 M3 amendment — public tunnel route behind Cloudflare Access`.

### Task 2: Manifest service `headless` and image mirror

**Files:**
- Modify: `budgero-lzc/lzc-manifest.yml` (new service per §11), `budgero-lzc/package.yml` (`version: 1.0.22`), `README.md` (section "Client headless")
- Create: `budgero-lzc/tests/manifest.test.sh`

**Interfaces:**
- Produces: service `headless` with `image: registry.lazycat.cloud/u30562882/fliva/budgero-headless:<tag printed by copy-image>`, `user: "1001:1001"`, `setup_script: mkdir -p /lzcapp/var/headless && chown -R 1001:1001 /lzcapp/var/headless`, `binds: [/lzcapp/var/headless:/lzcapp/var/headless]`, `environment: [TZ=Europe/Rome, "BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}"]`, `health_check: {test: [CMD, wget, -qO-, "http://localhost:8787/healthz"], start_period: 120s}`. No `application.routes` entry for it (it is not served on the Lazycat subdomain).

- [ ] **Step 1: Failing test** `budgero-lzc/tests/manifest.test.sh` (python3 + yaml): asserts the service exists with exactly the fields above, the image is a `registry.lazycat.cloud/...` reference (not docker.io, not `:latest`), env has exactly the two variables, `routes` has no `headless` entry, and the `budgero` service is unchanged except nothing. Run → FAIL.
- [ ] **Step 2 (gated: Federico's go for the mirror):** `powershell.exe -NoProfile -Command "lzc-cli appstore copy-image fliva/budgero-headless:1.22.1-2"` from WSL (absolute path `/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`); record the printed tag.
- [ ] **Step 3:** Edit the manifest with that tag, bump `package.yml`, document in README (what the service is, where config lives, "server and headless upgrade together"). Run the test → PASS; `cd budgero-lzc && lzc-cli project build` → `.lpk` produced (then delete it; `install-local.sh` rebuilds).
- [ ] **Step 4:** Commit — `feat: headless service in the lzc-budgero package (1.0.22, read-only by config)`.

### Task 3: Provisioning script (config + secrets on the NAS)

**Files:**
- Create: `docker/headless/provision.sh`, `docker/headless/tests/provision.test.sh`

**Interfaces:**
- Produces: `provision.sh --dir D --user U --space-id S --budget-id N [--uid 1001]` — writes `D/config.json` (`url`, `user`, `spaceId`, `budgetId`, `readOnly: true`, `allowDestructive: false`, `port: 8787`) atomically; prompts with `read -s` for the Budgero password and for `space.key` (raw base64 from Settings → Push API → export), never echoing them; validates `space.key` decodes to 32 bytes (else exit 2, nothing written); generates `tokens` with three lines `ambrogio:read:<hex64>`, `operator:write:<hex64>`, `admin:admin:<hex64>` (`openssl rand -hex 32`, fallback `head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'`); `chown <uid>` and `chmod 600` on the three secret files; prints the **read** token once on stdout with a warning to store it in Ambrogio's secret store, and never prints the others. Refuses to overwrite existing secrets unless `--force`.

- [ ] **Step 1: Failing tests** (temp dir, `--uid $(id -u)`, secrets piped on stdin): `config.json has readOnly true and the five fields`; `secrets are mode 600`; `space.key of 31 bytes ⇒ exit 2, no file written`; `tokens has 3 lines with roles read/write/admin, 64 hex chars each`; `stdout contains the read token and not the write/admin ones`; `existing secrets without --force ⇒ exit 3`; `the password never appears in stdout/stderr`. Run → FAIL.
- [ ] **Step 2:** Implement (busybox-sh compatible: it runs on the NAS host, which has bash, but keep POSIX sh). Run → PASS.
- [ ] **Step 3:** Commit — `feat(headless): provisioning script for config and secrets`.

### Task 4: Install on the NAS and provision (gated)

- [ ] **Step 0:** Bench scenario 24 green (log in the session scratchpad, or rerun per Vikunja 896). If red: stop, it means the token refresh is broken.
- [ ] **Step 1 (go):** `cd budgero-lzc && bash install-local.sh` — it stops the app, backs up `/lzcsys/data/appvar/cloud.lazycat.app.budgero/data` to `/lzcsys/var/backups/`, installs, starts. Verify: `lzc-docker ps` shows `cloudlazycatappbudgero-headless-1` running; `lzc-docker exec cloudlazycatappbudgero-headless-1 wget -qO- localhost:8787/healthz` ⇒ `{"state":"not_configured",…}`; the `budgero` service still answers `/version/latest` 1.22.1.
- [ ] **Step 2:** Federico reads `spaceId`/`budgetId` (I fetch them read-only: `spaceId` from `budget_space_blobs` as in the 26/11 check; `budgetId` from the web app URL) and runs **himself** the provisioning in an interactive SSH session: `scp docker/headless/provision.sh root@192.168.8.115:/root/` then `ssh -t root@192.168.8.115 'sh /root/provision.sh --dir /lzcsys/data/appvar/cloud.lazycat.app.budgero/headless --user <user> --space-id <id> --budget-id <n>'`. He stores the printed read token for Ambrogio (M4).
- [ ] **Step 3:** Restart the headless container (`lzc-docker restart cloudlazycatappbudgero-headless-1`; config is on the bind mount). Verify within 3 min: `/v1/status` (with the read token, via `lzc-docker exec … wget --header`) shows `state: live`, `versions.server == versions.bundled == "1.22.1"`, `quarantined: []`, `outbox_size: 0`; `GET /v1/accounts` returns the real accounts.
- [ ] **Step 4 (Review Focus 3):** `lzc-docker restart` again ⇒ back to `live`; `ls -l` of the dir shows the three secrets at mode 600, owner 1001. Review Focus 4 (wrong ids/key) is not reproduced on production: it is covered by M1 bench scenario 25 (wrong spaceId ⇒ `halted access_denied` in `/v1/status`) and by `bootstrap_failed:decrypt` in M1; if Step 3 does not reach `live`, read `reason` in `/v1/status` and re-run provisioning with `--force`.
- [ ] **Step 5:** Commit nothing (no repo change); record in Vikunja/PMB.

### Task 5: Public hostname behind Cloudflare Access (gated, Federico in the dashboard)

- [ ] **Step 1:** Cloudflare One → Networks → Tunnels → the NAS tunnel → Public hostname: `budgero-api.federicoliva.it` → `http://headless.cloud.lazycat.app.budgero.lzcapp:8787`. (Checked first from the `cloudflared` container: `wget -qO- http://headless.cloud.lazycat.app.budgero.lzcapp:8787/healthz` answers.)
- [ ] **Step 2:** Access → Applications → self-hosted `budgero-api.federicoliva.it`, policy **Service Auth** with a new service token "ambrogio-headless" (Client ID/Secret stored only in Ambrogio's secret store); a second application on path `budgero-api.federicoliva.it/v1/admin` and `/v1/debug` with policy **Block** (or a WAF custom rule blocking those paths).
- [ ] **Step 3: Verification from outside (WSL) and from the Ambrogio container** (Review Focus 5): no Access headers ⇒ 403 from Cloudflare (never the headless JSON); Access headers + no bearer ⇒ 401 `unauthorized`; Access headers + read bearer ⇒ 200 `/v1/status` with `state: live`; Access headers + admin bearer on `/v1/admin/quarantine/x/ack` ⇒ blocked at the edge (403 Cloudflare page, not the headless 404). Record the four status codes.

### Task 6: Spec §12.3 checks (observations, not gates)

- [ ] **Step 1: TERM forwarding:** `lpk-manager stop cloud.lazycat.app.budgero` then start ⇒ `rebuilds.log` last line `code 143` before the stop (supervisor got TERM through `lzcinit`). If it shows 137, note it (SIGKILL path; acceptable, recorded).
- [ ] **Step 2: health_check:** `lzc-docker inspect cloudlazycatappbudgero-headless-1 --format '{{json .State.Health}}'` ⇒ `healthy` after start; `start_period` honoured (no `unhealthy` in the first 120 s while `bootstrapping`).
- [ ] **Step 3: unhealthy secondary service (observation only, nothing provoked):** during Task 4 Step 1 the headless sits in `not_configured` (200) and during bootstrap in `bootstrapping` (200); the first natural 503 will be a halt or a storm. When one happens during the week, record from `lzc-docker ps`/`inspect` whether Lazycat leaves the `budgero` service and the app running while `headless` is `unhealthy`. Note the result in the runbook.
- [ ] **Step 4: Morning boot (Review Focus 1–2):** after the next 07:00 power-on, `rebuilds.log` shows at most a few `78` (DNS window) then a `live` worker; `halts.log` has no new halt; the headless is `live` even if the tunnel is down (check `/v1/status` via `lzc-docker exec`).
- [ ] **Step 5: First spot check:** `/v1/months/<current>` vs the web app (Ready to Assign and 3 category `available` values), recorded.

### Task 7: Observation tooling, runbook, reminders

**Files:**
- Create: `docker/headless/observe.sh`, `docker/headless/tests/observe.test.sh`
- Publish: BookStack Chronos page "Budgero headless — runbook operatore" (doc privata, `bks`)

**Interfaces:**
- Produces: `observe.sh [--dir D] [--since ISO]` — reads `D/rebuilds.log`, `D/halts.log`, `D/quarantine.json` and prints one verdict per §12.3 criterion: (1) no `rebuilds.log` code outside `75 76 77 78 143`; (2) `halts.log` only `quarantine`/`restore_inproc`; (3) every quarantine `acked`; (4) `rebuilds_24h` (75) ≤ 20 and `restores_24h` (77) ≤ 50 for every 24 h window since `--since`; exit 0 only if all four pass. Malformed lines counted and reported, not fatal.

- [ ] **Step 1: Failing tests** with fixture logs: a clean week ⇒ exit 0; a `code 1` line ⇒ criterion 1 FAIL; an `auth_failed` halt ⇒ criterion 2 FAIL; an unacked quarantine ⇒ criterion 3 FAIL; 21 code-75 lines in one day ⇒ criterion 4 FAIL; a garbage line ⇒ reported, exit 0 if the rest passes. Run → FAIL → implement → PASS.
- [ ] **Step 2:** Runbook page: where things live, how to read `/v1/status` from the NAS, provisioning, rotating tokens, the edge (hostname, Access app, service token), the 7-day criteria and `observe.sh`, the upgrade rule (server + headless together), how to enable writes. Commands verbatim; secrets never.
- [ ] **Step 3:** Vikunja (project 2): day 3 and day 7 reminders with the exact `observe.sh` command and the three spot checks; commit `feat(headless): observation script for the read-only week`.

### Task 8: Enable writes (gated, after 7 clean days)

- [ ] **Step 1:** `observe.sh --since <live date>` exits 0 and 3 spot checks matched. Federico's go.
- [ ] **Step 2:** Set `readOnly: false` in `config.json` (operator edit as root, keep mode/owner), restart the container, `/v1/status` `live`, one `POST /v1/transactions` test expense with a fresh `Idempotency-Key` from the NAS (admin side), visible in the web app, then deleted via `DELETE /v1/transactions/{id}`. Update runbook + spec §15 status. M4 (Ambrogio adapter) starts.

---

## Self-review notes

- Spec §12.3 coverage: NAS upgrade (done before this plan), image mirror (T2), manifest service (T2), reachability from Ambrogio (T5, via the amended route), `APP_VERSION` unset (verified 26/11), bound blob before start (verified 26/11), the three observations (T6), 7-day read-only criteria (T6–T7), `readOnly:false` (T8).
- Gated steps: T2.2, T4.1–4.3, T5, T6 (touches the NAS), T8.
- Not here: Ambrogio adapter (M4); deferred minors from M2 marked "before any token that creates accounts" (none issued in M3: the write token stays unused until T8).
