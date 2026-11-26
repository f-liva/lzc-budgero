# Budgero Headless — Milestone 2 (writes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the M1 read-only peer into a writing peer: REST writes through the op allowlist, each answered 200 only after the server ack, with the ledger, gate, ordering verdict, send window, nack handling and argument schemas of spec §8–10; plus the M1 follow-ups (§15), the upstream U2 diff, and the NAS upgrade to v1.22.1 that M3 needs.

**Architecture:** Everything new lives in `packages/headless/src/writes/` and `src/api/routes-write.ts`; the upstream patches U1–U3/U6 already expose every hook M2 needs (`onMutationAck`, `onMutationNacked`, `getSendable`, `runMutationPipeline`), so **no new upstream change** is planned. A request goes: global write lock → ledger lookup → apply-phase lock → gate → schema → ledger `intent` → U6 pipeline per op (`spec.idempotencyKey = opId`) → wait for dequeues → answer. The verdict is taken by the queue-storage observer on each dequeue, from the version `onMutationAck` recorded.

**Tech Stack:** as M1 — TypeScript (ESM), Node 22, pnpm 11, vitest 4, esbuild, `ws`, `sql.js`, busybox httpd, Docker `budgero/budgero:v1.22.1` for the bench.

**Spec:** `/home/fede9/Progetti/lzc-budgero/docs/superpowers/specs/2026-11-24-budgero-headless-client-design.md` (v29 + §15 amendments). Section numbers (§8.1 …) are the spec's. `file:line` at tag `v1.22.1` unless a fork path under `packages/headless` is given.

**M1 plan (format, file map, type names):** `/home/fede9/Progetti/lzc-budgero/docs/superpowers/plans/2026-11-25-budgero-headless-m1-readonly.md`.

## Repositories and state at plan time (26/11/2026)

| What | Where |
|---|---|
| Fork code | worktree `~/Progetti/budgero-wt-headless`, branch `feat/headless-client` = `ad9c64c8`, tag `headless-v1.22.1-1`, pushed to `f-liva-fork`. M2 continues on the same branch. |
| Image, manifest, NAS server image | `~/Progetti/lzc-budgero` (`docker/headless/`, `docker/Dockerfile` = `FROM budgero/budgero:v1.21.5`, `budgero-lzc/` package 1.0.20) |
| Upstream | `origin` = `tombadilo-bombadilo/budgero`; proposal issue #155 |

Commit convention as M1: `feat(headless): …`, `fix(headless): …`, `test(headless): …`; upstream-only work as `feat(runtime): …`. **No AI attribution lines** in any commit (Federico's instruction; overrides the harness default). **No push to any remote** (`f-liva-fork`, `origin`, Docker Hub, Lazycat registry) and no NAS change without Federico's explicit go for that step.

## Where the spec and the code diverge (decide before executing)

1. **#155 is an issue, not a PR.** The maintainer answered on 24/11 (1. a separate package in the repo is fine; 2. *"I would move the ops into a separate package, not into runtime or core"*; 3–4 yes). U6 put the pipeline in `app/src/shared/mutations/pipeline.ts`, which is neither runtime nor core, but the op registry itself still lives in the app. Task 6 prepares a **new** PR that references #155 and carries U2 only; the "ops package" move is out of scope and flagged in the PR text.
2. **Bench location.** Spec §12.1–2 says the scenarios and the parity test run "in the app's vitest". M1 put them in `packages/headless/test/` (vitest there aliases `@shared` and imports `fuzz/harness.ts`). M2 follows M1: `test/bench.m2.test.ts`, `test/parity.test.ts`.
3. **NAS upgrade.** Spec §12.3 puts it in M3; Federico asks for it before the headless deploy. Task 20 does it as the last M2 task (gated), so M3 only adds the service.
4. **`crashAt` writes `outbox_size: 0`** (`src/crash-points.ts:16`). Harmless in M1, wrong for write crash points: Task 15 passes the real size, because the supervisor's "75 after a record with `outbox_size > 0` is not counted" rule reads it.
5. **Redactor already hides any field named `key`** (`src/logging.ts:3`), so quarantine keys never reached the logs in M1. Task 4 keeps that behaviour (suffix match still covers `key`); log the quarantine key under `quarantineKey` where it is useful.

## Global Constraints

- Everything in the M1 plan's Global Constraints still holds (pin `v1.22.1`, never upload, exit codes, durable files, secrets, logging redaction, no continuous rules).
- 200 only after the server ack; 202 `pending|blocked|unknown` otherwise; never 200 for an op the server has not acked; never 409 for a nack while the entry is on disk (§8.2).
- `opId = 'hdl_' + sha256hex(nonce + '#' + i)`, `i` 1-based position in the record; `nonce` = 32 random bytes hex, fresh per record (§8.3).
- `bodyHash = sha256hex(method + ' ' + path + ' ' + canonicalJson(parsedBody))`, canonical = sorted keys, no whitespace (§8.3).
- `Idempotency-Key`: required on writes, `/^[A-Za-z0-9_-]{16,128}$/` (§10).
- Ledger retention 30 days, only records whose ops are all `acked|failed|skipped|dropped` and none in `outbox.json` (already `Ledger.prune`).
- Wait for dequeues: 30 s, then 202 (§8.1.5). 76 waits for landed dequeues 30 s (§7.6).
- 429: more than 5 exits 76 in the last 10 min of `rebuilds.log` ⇒ writes 429 (§7.6 table).
- Writes are serialised: one request executes at a time (global write lock); every outbox id that appears during a request is that request's (§7.5.5).
- `spec.idempotencyKey = opId`, **never** `spec.mutationId` (§8.1.4).
- Send window 1 in queue order; latch after `reordered` until exit; `catch_up_request` always; key/password frames never (§7.2).
- Codes: 200 (`reordered`, `partial`, per-create `requery`) · 202 · 403 `policy|role` · 409 `dropped` · 422 `schema|failed|key_reuse` · 429 · 503 (`pending`, `quarantine_pending`, `not_ready`) (§10).
- Amounts are integer milliunits everywhere in the API.

## Review Focus

Inputs the spec implies but no task's done-when names; each has its test in the owning task.

1. **Same `Idempotency-Key`, same body with different key order or whitespace** — must hash equal and answer from the record, never `key_reuse`. → Task 7.
2. **Write body that is not JSON, is an array, or exceeds 64 KiB** — `422 schema` (413-size ⇒ `422 schema` with `field: "body"`), and **no ledger record is written** (a later valid retry with the same key must proceed). → Task 13.
3. **Amount as float (`12.5`), numeric string (`"12500"`), negative `outflow`, or `> Number.MAX_SAFE_INTEGER`** — `422 schema` naming the field; never coerced. → Task 8.
4. **HTTP client disconnects during the 30 s dequeue wait** — the op still completes, the ledger reaches `acked`, and a retry with the same key answers 200 with the stored result. → Task 11.
5. **`PATCH /v1/transactions/{id}` with an empty body or only unknown fields** (k = 0 ops) — `422 schema`, no ledger record, no lock left held. → Task 14.

---

## File structure (new or changed in `packages/headless`)

```
src/
  single-instance.ts        worker.lock acquire/heartbeat/release            (Task 1)
  logging.ts                suffix-match redactor                            (Task 4)
  crash-points.ts           + 5 write points, real outbox_size               (Task 15)
  writes/
    canonical.ts            canonicalJson, bodyHash, opIdFor, newNonce       (Task 7)
    ledger-rules.ts         decide(record, bodyHash) → Decision              (Task 7)
    schemas.ts              per-op accepted keys, always-rejected keys       (Task 8)
    ownership.ts            id references validated against budgetId         (Task 8)
    verdict.ts              ack versions, dequeue verdict, drained ops       (Task 9)
    send-window.ts          frame policy, latch, nack pinning, last_nack     (Task 10)
    engine.ts               WriteEngine: gate, intent, execute, wait, answer (Task 11)
    wrappers.ts             REST wrappers → op lists (+ assigned/move checks) (Task 14)
  api/
    body.ts                 readJsonBody (64 KiB), Idempotency-Key check     (Task 13)
    routes-write.ts         POST /v1/ops/{op} + wrappers                     (Tasks 13–14)
    server.ts               write cell of §7.3 → routes-write                (Task 13)
    routes-status.ts        last_nack, outbox_divergent                      (Task 10)
  runtime/coordinator.ts    onMutationAck/onMutationNacked, answerInFlight   (Tasks 9–11)
  startup.ts                lock, drained marking, gate inputs               (Tasks 1, 9, 11)
  platform/queue-storage.ts hook promises awaited before the outbox rename   (Task 9)
  platform/halts.ts         retention trim                                   (Task 3)
scripts/entrypoint.sh       port from config.json, rebuilds.log trim         (Tasks 2–3)
docs/api.md                 M2 routes                                        (Task 14)
test/                       one file per new module; bench.m2.test.ts; parity.test.ts
bench/proxy.ts              closeClient(code, reason)                        (Task 5)
test/bench.helpers.ts       api() takes body + idempotencyKey                (Task 17)
```

Type names reused from M1 (do not rename): `StateMachine`, `Mutex`, `OutboxStorage`, `Ledger`, `LedgerRecord`, `LedgerOp`, `OpState`, `Quarantine`, `HeadlessHttp`, `RestoreRules`, `HaltReason`, `ApiCtx`, `Result`, `Route`, `OP_POLICY`, `tierOf`, `UPDATE_COLUMN_ALLOWED`.

---

## Phase A — M1 follow-ups (spec §15 last bullet + Federico's list)

### Task 1: Single-instance lock on the config dir

**Files:**
- Create: `src/single-instance.ts`
- Modify: `src/startup.ts` (step 1, right after `clearExitInfo` and before `loadConfig`), `src/startup.ts` `shutdown()`/`exitNow()` (release)
- Test: `test/single-instance.test.ts`

**Interfaces:**
- Produces: `acquireWorkerLock(dir: string, me: {hostname: string; pid: number; now(): number; isAlive(pid: number): boolean}): Promise<{release(): void; stopHeartbeat(): void}>` — file `worker.lock` = `{hostname, pid, heartbeatAt}`; acquired when absent, or same `hostname` and `!isAlive(pid)`, or `now() - heartbeatAt > 60_000`; otherwise throws `ConfigError('config:locked')`. Heartbeat rewrites the file every 15 s (`FileChain`), `unref`'d. `release()` removes the file only if it still holds our `{hostname, pid}`.
- Why hostname: two containers on the same bind have independent pid namespaces; the hostname differs per container, the pid alone would lie.

- [ ] **Step 1: Failing tests** — `absent ⇒ acquired, file has our hostname/pid`; `same hostname, dead pid ⇒ acquired`; `same hostname, live pid ≠ ours ⇒ config:locked`; `other hostname, heartbeat 10 s old ⇒ config:locked`; `other hostname, heartbeat 61 s old ⇒ acquired`; `release leaves a file another worker took over`; `startup: lock held ⇒ exit 1 with exit-info reason config:locked`.
- [ ] **Step 2: Run** `pnpm --filter @budgero/headless exec vitest run test/single-instance.test.ts` → FAIL.
- [ ] **Step 3: Implement**, wire in `startup.ts` (`ConfigError` path already exits 1 with the reason).
- [ ] **Step 4: Run** the package suite (`pnpm --filter @budgero/headless test`) and `type-check` → PASS.
- [ ] **Step 5: Commit** — `feat(headless): single-instance lock on the config dir (config:locked)`.

### Task 2: Supervisor down-mode port follows `config.port`

**Files:**
- Modify: `scripts/entrypoint.sh` (`PORT` default resolution, line ~10–23)
- Test: `scripts/entrypoint.test.sh`

**Interfaces:**
- Produces: when `--port` is not given, `PORT` = `config.json`'s `port` read with `node -e` (the image has node; no `jq`), falling back to `8787` if the file is missing or the value is not an integer 1–65535. `--port` still wins (bench).

- [ ] **Step 1: Failing shell tests** — `config.json port 9123, worker exits 1 ⇒ httpd answers /healthz on 9123`; `config.json missing ⇒ 8787`; `port "abc" ⇒ 8787`; `--port 9000 overrides config`. (When busybox is absent, assert the port written into `httpd.conf`, as M1 does.)
- [ ] **Step 2–5:** FAIL → implement → `pnpm --filter @budgero/headless test:sh` PASS → commit `fix(headless): supervisor down-mode listens on config.port`.

### Task 3: Retention of `rebuilds.log` and `halts.log`

**Files:**
- Modify: `scripts/entrypoint.sh` (trim before each launch), `src/platform/halts.ts` (`trimHalts`), `src/startup.ts` (call at step 3)
- Test: `scripts/entrypoint.test.sh`, `test/halts.test.ts`

**Interfaces:**
- Produces: keep lines whose `ts` is within **30 days** (decision: 30 d ≫ every 24 h budget and the 7-day observation window of M3); malformed lines are dropped by the trim (they are already skipped by every reader). Rewrite = temp file in the same dir → `fsync` → `rename`. `rebuilds.log` is trimmed only by the supervisor (sole writer), before launching a worker; `halts.log` only by the worker at step 3, before any append (`trimHalts(dir, now): Promise<void>`). Trim is skipped when nothing would be removed (no rewrite).

- [ ] **Step 1: Failing tests** — shell: `a 31-day-old line is gone after the next launch, a 29-day-old one stays, a 75 storm count is unchanged`; ts: `trimHalts removes 31-day lines, keeps the rest byte-identical`, `no rewrite (same inode) when nothing to remove`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): 30-day retention for rebuilds.log and halts.log`.

### Task 4: Redactor suffix match

**Files:**
- Modify: `src/logging.ts:3`
- Test: `test/logging.test.ts`

**Interfaces:**
- Produces: `SECRET_KEY = /(token|password|secret|key|authorization|encryptedpayload|args|cookie)$/i` (suffix, case-insensitive): covers `accessToken`, `refreshToken`, `apiKey`, `spaceKey`, `idempotencyKey`, `x-api-key`. The `Bearer …` string rule stays.

- [ ] **Step 1: Failing tests** — `accessToken, apiKey, spaceKey, refresh_token, Cookie redacted`; `mutationId, opId, version kept`; `nested {headers:{authorization}} redacted`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `fix(headless): redact any field whose name ends in a secret word`.

### Task 5: Bench scenarios for `access_denied`

**Files:**
- Modify: `bench/proxy.ts` (`closeClient(code: number, reason: string): void` — closes every client-side socket with that close frame), `test/bench.proxy.test.ts`, `test/bench.m1.test.ts` (two scenarios appended after 24)

**Interfaces:**
- Consumes: `startHeadless(s, url, {configOverrides})`, `rawSpace()`, `waitUntil`, `api` from `test/bench.helpers.ts`.

- [ ] **Step 1: Proxy unit test** — `closeClient(4000,'member_removed') ⇒ client sees close code 4000 and reason member_removed` → FAIL → implement → PASS.
- [ ] **Step 2: Scenarios** —
  `25. wrong spaceId ⇒ halt access_denied, never 78`: config `spaceId` = a random UUID with the real user; assert `/v1/status` `{state:'halted', reason:'access_denied'}`, `halts.log` has `access_denied`, `rebuilds.log` has no 78.
  `26. WS close member_removed / blocked ⇒ halt access_denied`: live headless, `proxy.closeClient(4000,'member_removed')` (then a second run with `blocked`) ⇒ halted `access_denied`, no exit.
- [ ] **Step 3: Run** `HEADLESS_BENCH=1 pnpm --filter @budgero/headless exec vitest run test/bench.m1.test.ts -t "access_denied"` → PASS.
- [ ] **Step 4: Commit** — `test(headless): bench scenarios for access_denied (wrong spaceId, member removed)`.

### Task 6: Upstream U2 diff for the PR referencing #155

**Files (fork repo, new local branch, nothing pushed):**
- Branch `upstream/u2-queue-durability` from `origin/main` (fetch first; if `main` has moved past `v1.22.1`, rebase onto it and resolve)
- Squash of `d660e9eb` (U2) + `ceb98351` (resolved save releases every id it persisted = review "U2 Important 2")
- Create in `lzc-budgero`: `docs/upstream/u2-queue-durability.md` (PR title + body draft) and `docs/upstream/u2-queue-durability.patch` (`git format-patch -1 --stdout`)

**Interfaces:**
- Produces: one commit `fix(runtime): keep non-durable offline-queue entries unsent; injectable queue storage` touching only `runtime/src/offline-queue/{offline-queue,storage,index}.ts`, `runtime/src/coordinator/{runtime-coordinator-types,runtime-context-factory,reconnection-service}.ts` (+ `reconnection-service.test.ts`), `offline-queue.persisting.test.ts`. No headless code, no other U-item.

- [ ] **Step 1:** `cd ~/Progetti/budgero && git fetch origin && git switch -c upstream/u2-queue-durability origin/main && git cherry-pick d660e9eb ceb98351` then `git reset --soft HEAD~2 && git commit` with the message above. Resolve conflicts by keeping upstream's code plus the `persisting` logic.
- [ ] **Step 2:** `pnpm install --frozen-lockfile && pnpm --filter @budgero/runtime test && pnpm run type-check:runtime` → PASS, counts ≥ `origin/main` baseline (record both).
- [ ] **Step 3:** Write the PR body: the bug (an entry pushed to the in-memory queue is sendable before `storage.save` resolves; a crash between send and save loses it locally while the server has it, or a failed save resends a mutation that was never durable), the fix (queue prefix before the first non-durable entry; a resolved save releases every id it wrote), the tests, "Refs #155", and one line on point 2 of the maintainer's answer (ops package not in this PR). **Text for a human: pass it through `Skill(no-ai-slop)` then `Skill(sepia-refactor)` before showing it.**
- [ ] **Step 4:** Commit the two docs in `lzc-budgero` — `docs(upstream): U2 queue durability diff and PR draft for #155`. Stop: pushing the branch and opening the PR need Federico's go.

---

## Phase B — Writes (spec §8–10)

### Task 7: Canonical hashing and ledger decision rules

**Files:**
- Create: `src/writes/canonical.ts`, `src/writes/ledger-rules.ts`
- Test: `test/canonical.test.ts`, `test/ledger-rules.test.ts`

**Interfaces:**
- Produces:
  - `canonicalJson(v: unknown): string`; `bodyHash(method: string, path: string, body: unknown): string`; `newNonce(): string` (32 random bytes hex); `opIdFor(nonce: string, i: number): string` (`'hdl_' + sha256hex(nonce + '#' + i)`, `i` 1-based).
  - `type Decision = {kind: 'proceed'} | {kind: 'key_reuse'} | {kind: 'answer'; status: 200 | 202 | 409 | 422; body: WriteAnswer} | {kind: 'wait'; opIds: string[]} | {kind: 'reexecute'; fromIndex: number}`; `decide(rec: LedgerRecord | undefined, bodyHash: string): Decision` — rules in **this order** (§8.3): no record ⇒ proceed; hash differs ⇒ key_reuse; any `dropped` ⇒ 409 with per-op states; any `unknown` ⇒ 202 `unknown`; any `nacked` ⇒ 202 `blocked`; op 1 `failed` ⇒ 422 `failed`; all `acked` ⇒ 200 with stored results and `reordered`/`partial` flags (`result: null` + `entry` for `drained` ops; `result: null, requery: true` for creates of a reordered record); some `failed`/`skipped` after acked ops ⇒ 200 `partial`; `queued` ops ⇒ wait; `intent` ops with every other op `acked` ⇒ reexecute from the first `intent` (never when any op is `failed|skipped|dropped|nacked|unknown`).
  - `interface WriteAnswer { status?: 'pending'|'blocked'|'unknown'; results?: unknown[]; mutationIds: string[]; ops: Array<{id: string; state: string; version: number | null; result?: unknown; requery?: true}>; reordered?: true; partial?: true; error?: string }` — shared by every write answer.

- [ ] **Step 1: Failing tests** — canonical: `{b:1,a:[{d:1,c:2}]} ⇒ '{"a":[{"c":2,"d":1}],"b":1}'`; **Review Focus 1:** `bodyHash equal for the same body with reordered keys and whitespace`; `bodyHash differs for POST vs PATCH on the same path`; `opIdFor(n,1) ≠ opIdFor(n,2)`, deterministic, prefix `hdl_`; ledger-rules: one `it` per rule above, plus `dropped and unknown together ⇒ 409 (dropped first)`, `intent next to failed ⇒ 200 partial, never reexecute`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): canonical body hash, opIds and ledger decision rules`.

### Task 8: Per-op argument schemas and budget ownership

**Files:**
- Create: `src/writes/schemas.ts`, `src/writes/ownership.ts`
- Test: `test/schemas.test.ts`, `test/ownership.test.ts`

**Interfaces:**
- Produces:
  - `class SchemaError extends Error { field: string }`.
  - `validateArgs(op: string, args: unknown, ctx: {budgetId: number}): Record<string, unknown>` — returns a **copy** with `budgetId` forced where the op carries one (nested included). Rejects: non-object args; any key outside the op's accepted set; at any depth `mutationId, meta, idempotencyKey, opClock, exchangeRateOverride, fromPush, mirror, Mirror, importIdentities, currencyRates`; a caller `id` on create ops (`transactions.add`, `categories.create`, `categoryGroups.create`, `accounts.create`, `recurring.create` `input.id`, `addTransfer` `source.id`/`destination.id`); non-empty `transferId` on `transactions.add`; any `transferId` on `addTransfer`; amounts (`inflow`, `outflow`, `amount.*`, split amounts, `receivedAmount`, `newValue` on `outflowconverted|inflowconverted`) not a safe integer ≥ 0; `date` not `YYYY-MM-DD`.
  - Accepted key sets copied **verbatim from spec §9** (`transactions.add`, `saveSplits`, `updateColumn`, `payees.add`, `recurring.create`, `recurring.update`); for every other allowed/destructive op the set is the keys its `execute`/`prepare` reads at the pin — the implementer reads each op in `app/src/shared/mutations/op-code-registry/domains/*` and writes the list in `schemas.ts` with a `// <file>:<line>` comment per op. `updateColumn`: `columnName` normalised like core (lower-case, the core mapping), must be in `UPDATE_COLUMN_ALLOWED`; integer `newValue` on `categoryid`. `accounts.update`: only `id` + `name`; the copy sends `type: ''`, `currency: ''`. `transactions.setCleared`: exactly one id. `rules.create`/`rules.update`: `mode: 'continuous'` rejected. `rules.execute`: `options.transactionIds` non-empty, ≤ 500.
  - `assertOwnership(op: string, args: Record<string, unknown>, services: Services, budgetId: number): void` — every id reference (`id`/`ids`, `transactionId`, `parentId`, `categoryId`, `newGroupId`, `accountId`, `labelId`, `source.accountId`, `destination.accountId`, `toAccountId`, split ids, recurring `input.*`/`patch.*` ids, `updateColumn` `newValue` when `columnName = categoryid`) must exist **in `budgetId`** (looked up through core services on the live DB); else `SchemaError(field)`.
  - Coverage guard: a test iterates `OP_POLICY.allowed ∪ OP_POLICY.destructive` and fails if an op has no schema entry.

- [ ] **Step 1: Failing tests** — `it.each` over every always-rejected key at top level and nested; `create ops reject id` (each op); `addTransfer with transferId ⇒ schema`; `updateColumn columnName 'cleared' ⇒ schema`; `updateColumn 'CategoryID' normalised and accepted`; `accounts.update with type ⇒ schema; copy has type '' and currency ''`; `setCleared with two ids ⇒ schema`; `rules.create continuous ⇒ schema`; `rules.execute 501 ids ⇒ schema`; **Review Focus 3:** `outflow 12.5 / "12500" / -1 / 2**53 ⇒ schema naming outflow`; `budgetId forced on nested splits`; ownership (DB seeded with two budgets through core services): `categoryId of the other budget ⇒ schema categoryId`, `addTransfer destination account of the other budget ⇒ schema`, `updateColumn newValue category of the other budget ⇒ schema`; coverage guard.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): per-op argument schemas and budget ownership checks`.

### Task 9: Ack versions, dequeue verdict, drained ops

**Files:**
- Create: `src/writes/verdict.ts`
- Modify: `src/platform/queue-storage.ts` (hooks may return a promise; `write()` awaits them **before** the outbox rename), `src/runtime/coordinator.ts` (wire `onMutationAck`), `src/startup.ts` (step 4: mark every op present in `outbox.json` `drained: true`; startup-drain dequeues go through the same observer)
- Test: `test/verdict.test.ts`, `test/queue-storage.test.ts`

**Interfaces:**
- Consumes: `Ledger.setOpState`, `OutboxHooks`, `StateMachine`.
- Produces: `class Verdicts { constructor(d: {ledger: Ledger; sm: StateMachine; onReordered(key: string): void}); onMutationAck(id: string, version: number): void /* records version */; onEnqueued(entry: MutationPayload): Promise<void> /* ledger op → queued with entry; precedes the rename */; onDequeued(id: string, cause: 'ack'|'drop'): Promise<void>; expect(key: string, base: number, opIds: string[]): void /* the ops this execution issued, in order */; waitDequeued(opIds: string[], ms: number): Promise<'all' | 'timeout' | 'reordered'> }`.
  - `onDequeued` with cause `ack`, for an op whose record has a `base`: expected version `base + i` (`i` = 1-based position among `expect`'d ops of this execution); recorded version ≠ expected, `0`, or **absent** (implicit ack) ⇒ `reordered`: synchronously set `record.reordered = true`, replace every create's `result` with `null` + `requery: true`, call `onReordered(key)` (closes the latch, Task 10; schedules exit 75 after the in-flight answer, Task 11). Otherwise ledger `acked` + `version`. A `drained` op ⇒ plain `acked` (`result: null`, `entry` kept), no verdict. A 202'd op acked after a reconnect is judged the same way (its record still has `base`).
  - `OutboxHooks.onEnqueued/onDequeued` return `Promise<void> | void`; `OutboxStorage.write` does `await Promise.all(hookResults)` then the outbox `chain.write` (so `queued` precedes the rename and `acked` lands before the save resolves, §8.1).

- [ ] **Step 1: Failing tests** — `ack versions base+1, base+2 in order ⇒ both acked, no verdict`; `version gap ⇒ reordered persisted, create result null+requery, onReordered called once`; `version 0 ⇒ reordered`; `dequeue with no recorded version ⇒ reordered`; `drained op dequeued ⇒ acked with result null and entry kept, no verdict`; `202'd op acked later at base+2 instead of base+1 ⇒ reordered`; `waitDequeued resolves 'reordered' as soon as the verdict lands`; queue-storage: `onEnqueued promise resolves before the outbox file is renamed (spy on chain.write order)`; `a rejecting hook makes save reject and the outbox file is untouched`; startup: `ops present at step 4 are marked drained`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): ledger verdict on dequeue from recorded ack versions; drained ops`.

### Task 10: Send window, latch, nacks

**Files:**
- Create: `src/writes/send-window.ts`
- Modify: `src/startup.ts` (`wsOptions.onFrameOut` → send window; dequeue ⇒ `releaseHeldFrames`), `src/runtime/coordinator.ts` (wire `onMutationNacked`), `src/api/routes-status.ts` (`last_nack`, `outbox_divergent`)
- Test: `test/send-window.test.ts`, `test/api.routes.test.ts` (status fields)

**Interfaces:**
- Produces: `class SendWindow { constructor(d: {queueOrder(): string[] /* outbox ids in queue order */; readOnly: boolean}); onFrameOut(frame: WsMessage): 'send' | 'hold' | 'refuse'; closeLatch(): void; onDequeued(): void /* releaseHeldFrames(head-only) */; outstanding(): string | undefined; onNack(id: string, code: string): NackAction }`; `type NackAction = 'ignore' | {kind: 'last_nack'} | {kind: 'block'; id: string} | {kind: 'version_mismatch'}`.
  - `mutation` frame: `send` iff not read-only, latch open, and its id is the **head** of `queueOrder()` (every entry ahead dequeued; implicit acks count because they remove the id); else `hold` (the shim dedups by id and drops held frames on close, already in M1).
  - Nack (§8.2): `storage_error|internal` ⇒ `last_nack` (ledger stays `queued`); `format_too_new` ⇒ `version_mismatch` (halt, entry kept); `invalid|other` ⇒ `block`; empty id + `invalid` ⇒ pinned on `outstanding()` and blocks, or `last_nack` if none outstanding; empty id + transient ⇒ `last_nack`. On `block`: ledger op `nacked`, `coordinator.halt('nack_blocked')` (stops the resend sweep), `sm.set('outbox_blocked','nack_blocked')` (no `halts.log` entry), `outbox_divergent = true`.
  - `/v1/status`: `last_nack: {id, code, at} | null`, `outbox_divergent: boolean` (true from a blocking nack, and at startup step 5).

- [ ] **Step 1: Failing tests** — `second queued frame held until the first dequeues, then sent`; `frame for a non-head id held`; `after closeLatch nothing is sent, even the head`; `read-only refuses mutation frames (unchanged)`; `catch_up_request always sent`; `nack storage_error ⇒ last_nack, state unchanged`; `nack invalid ⇒ outbox_blocked, ledger nacked, coordinator halted, no halts.log line`; `empty-id invalid with one outstanding frame ⇒ blocks that id`; `empty-id invalid with none outstanding ⇒ last_nack only`; `format_too_new ⇒ halt version_mismatch, entry kept`; status body has the two fields with live values.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): send window of 1, reordered latch, nack handling`.

### Task 11: Write engine (gate, intent, execution, wait, answers, rebuild hand-off)

**Files:**
- Create: `src/writes/engine.ts`
- Modify: `src/runtime/coordinator.ts` (`answerInFlight`, `waitLandedDequeues` in `rebuildCtx`; expose `executeMutation` via U6 `runMutationPipeline` with `runContinuousRules: false`), `src/startup.ts` (`ApiCtx.writes`), `src/platform/queue-storage.ts` (`OutboxWriteError` wrapping a failed `chain.write`), `src/rebuild.ts` (unchanged API; now fed real callbacks)
- Test: `test/engine.test.ts` (coordinator, ledger, outbox faked; real `StateMachine`/`Mutex`/`Verdicts`)

**Interfaces:**
- Consumes: Tasks 7–10; `runMutationPipeline(spec, {coordinator, services, runContinuousRules: false, onPrepared})` from `@shared/mutations/pipeline`.
- Produces: `class WriteEngine { constructor(d: EngineDeps); execute(req: {key: string; method: string; path: string; body: unknown; ops: Array<{op: string; args: Record<string, unknown>; create: boolean}>; generated?: {transferId?: string}}): Promise<Result>; answerInFlight(): Promise<void>; waitLandedDequeues(ms: number): Promise<void> }`.
  - Order (§8.1): `globalWriteLock` → `decide()` (answer/wait handled without the apply-phase lock) → `applyPhaseLock` → gate: `sm.state === 'live'`, diagnostics `catchUpInProgress === false`, `pendingCount === 0`, `connected`, `receiveIdle`, `blobCheckPassed()`, `!quarantine.blocking()` ⇒ else 503 (`pending` if `pendingCount > 0`, `quarantine_pending` if blocking, else `not_ready`); 429 if > 5 code-76 lines in the last 10 min of `rebuilds.log`; `base = max(cursor, highest own ack version)` → ledger `intent` for all k ops (new nonce, `bodyHash`, `base`) → per op `runMutationPipeline({op, payload: args, idempotencyKey: opId})`, releasing the apply-phase lock in a `finally` once every op's chain returned → `waitDequeued(opIds, 30_000)` → answer.
  - Throws by phase (§7.5.6): before `onPrepared` = **prepare** ⇒ no rebuild; after `onPrepared`, error not an `OutboxWriteError` = **apply** ⇒ `sm.set('draining','apply_throw')` synchronously, keep the global write lock until exit, exit 76 via `rebuild` (waits landed dequeues 30 s); `OutboxWriteError` (`OutboxStorage` wraps a failed chain write in it) = **outbox.add** ⇒ op `unknown`, 202 `unknown`, halt `outbox_write_failed`. Op i fails ⇒ in one ledger write op i `failed`, ops i+1..k `skipped`; i = 1 ⇒ 422 `failed`; i > 1 ⇒ 200 `partial` once ops 1..i-1 dequeued, else 202 `pending` with per-op states.
  - Answers: all acked, no verdict ⇒ 200 `{results, mutationIds, ops}`; `reordered` ⇒ 200 `reordered: true` at once, creates `result: null, requery: true`, then exit 75 after the response is flushed; timeout ⇒ 202 `{status:'pending', mutationIds, ops}`.
  - `answerInFlight()`: answers any request still in the wait at once — 200 `reordered` if a verdict landed; on 76, 200 `partial` only if ops 1..i-1 dequeued; otherwise 202 `pending` with per-op states incl. `failed`/`skipped`.

- [ ] **Step 1: Failing tests** — `gate closed in each failing condition ⇒ the right 503 error, no ledger record`; `6th 76 in 10 min ⇒ 429`; `happy path: intent then queued then acked; 200 with result`; `op passed to the pipeline carries idempotencyKey=opId and no mutationId`; `prepare throw on op 2 of 2 ⇒ op 2 failed, 200 partial after op 1 acks, no exit`; `apply throw on op 1 ⇒ 422 failed, draining at once, exit 76 scheduled, write lock never released`; `apply throw on op 2 ⇒ 200 partial after op 1 ack, exit 76`; `outbox write failure ⇒ 202 unknown, halt outbox_write_failed`; `reordered ⇒ 200 reordered with requery, exit 75 scheduled, latch closed`; `timeout ⇒ 202 pending, ledger completed later by the observer`; `same key twice concurrently ⇒ second waits on the lock and is answered from the record, one execution`; `retry of a reordered record ⇒ 200 reordered, id null`; **Review Focus 4:** `client socket closed during the wait ⇒ op acked in ledger; retry ⇒ 200 stored result`; `answerInFlight during a 77 ⇒ 202 pending with per-op states`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): write engine — gate, ledger intent, U6 execution, dequeue wait, answers`.

### Task 12: Startup re-execution and reconciliation with writes

**Files:**
- Modify: `src/startup.ts` (steps 4–5 with M2 ledger states), `src/writes/engine.ts` (`reexecute` path)
- Test: `test/main.startup.test.ts`, `test/engine.test.ts`

**Interfaces:**
- Produces: a retry whose record has `intent` ops and every other op `acked` re-executes those ops with the **same opIds** through the gate, refreshing the record's `base` (§8.3); startup step 5 sets `outbox_divergent: true` when it enters `outbox_blocked`; startup step 4 reconciliation is unchanged (M1) but now also keeps `drained` marks.

- [ ] **Step 1: Failing tests** — `record [acked, intent] retried ⇒ only op 2 executed, same opId, new base`; `record [failed, intent] retried ⇒ 200 partial, nothing executed`; `crash after intent (no outbox entry) ⇒ retry executes op 1 with the same opId`; `startup with a nacked op ⇒ outbox_blocked, outbox_divergent true`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): re-execute intent ops on retry; nacked startup marks divergence`.

### Task 13: `POST /v1/ops/{op}`, body reading, write routing

**Files:**
- Create: `src/api/body.ts`, `src/api/routes-write.ts`
- Modify: `src/api/server.ts` (the `kind === 'write'` branch: route to `routes-write`; `req.resume()` only for non-write routes), `src/api/result.ts` (`Kind` gains `'write'`)
- Test: `test/api.writes.test.ts`, `test/api.routes.test.ts` (live cell now hits the gate)

**Interfaces:**
- Produces: `readJsonBody(req, limit = 65_536): Promise<unknown>` (throws `SchemaError('body')` on > limit, invalid JSON, or a non-object top level); `idempotencyKey(req): string` (throws `SchemaError('Idempotency-Key')`). `POST /v1/ops/{op}`: role `write`; `tierOf(op)` — `closed` ⇒ 403 `policy`; `destructive` and `!config.allowDestructive` ⇒ 403 `policy`; `validateArgs` + `assertOwnership` (Task 8) ⇒ 422 `schema` with `field`; then `engine.execute` with one op (`create` true for the create ops of §9). §7.3 states unchanged for every non-`live` cell (M1 table test keeps passing); in `live` the gate decides. Writes answered from the ledger record work in every state the table marks "yes" — so `decide()` runs **before** the state check for those (Task 11 order).

- [ ] **Step 1: Failing tests** — `closed op ⇒ 403 policy`; `destructive with allowDestructive false ⇒ 403 policy, true ⇒ executes`; `missing Idempotency-Key ⇒ 422 schema`; `key of 15 chars or with '.' ⇒ 422`; **Review Focus 2:** `invalid JSON / array / 70 KiB body ⇒ 422 schema field body, ledger untouched, a valid retry with the same key proceeds`; `read token ⇒ 403 role`; `outbox_blocked + retry of an acked key ⇒ 200 from the record`; `draining + new key ⇒ 503`; table test still green.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): POST /v1/ops/{op} with policy, schemas and idempotency`.

### Task 14: REST wrappers

**Files:**
- Create: `src/writes/wrappers.ts`
- Modify: `src/api/routes-write.ts`, `docs/api.md` (M2 routes, codes, answer shape)
- Test: `test/wrappers.test.ts` (DB seeded through core services)

**Interfaces:**
- Produces (each returns `{ops, generated?}` for `engine.execute`, or throws `SchemaError`):
  - `POST /v1/transactions` ⇒ 1 × `transactions.add` (flat fields = its args).
  - `PATCH /v1/transactions/{id}` ⇒ one `transactions.updateColumn` per field in `memo, payee, date, categoryId→categoryid, outflow→outflowconverted, inflow→inflowconverted`, plus `cleared` ⇒ `transactions.setCleared`; fixed field order (as listed) so retries hash and issue identically; zero fields ⇒ `SchemaError('body')`.
  - `DELETE /v1/transactions/{id}` ⇒ 1 × `transactions.delete`.
  - `POST /v1/transfers` ⇒ 1 × `transactions.addTransfer`; `transferId` generated (`randomUUID`) and stored in `generated`; equal accounts pass the schema (the op throws in apply ⇒ 422 + 76, per §12.2).
  - `PUT /v1/months/{m}/categories/{id}/assigned {amount, allowOverAssign?, allowOverspend?}` ⇒ 1 × `monthlyBudgets.upsertAssignment`; over-assign vs Ready to Assign rejected unless `allowOverAssign`; a decrease that `monthlyBudgets.checkFutureOverspending` (core `services/monthly-budgets/index.ts:510`) flags rejected unless `allowOverspend`. The generic `POST /v1/ops/monthlyBudgets.upsertAssignment` applies the same checks.
  - `POST /v1/months/{m}/move {from: id|'rta', to: id|'rta', amount}` — mirrors `app/src/features/budget-planning/ui/budget-table/useCategoryOperations.ts:380-447`: `amount > 0`, `from ≠ to`; from a category: available > 0, amount clamped to it, overspend check on the source; one `monthlyBudgets.batchUpsertAssignments` with two entries of absolute totals read from the month rows (one entry when either side is `rta`); `budgetId` forced per entry; over-assign check only from `rta`. Issued by the endpoint, so it bypasses the destructive tier.
  - `m` must be `YYYY-MM`; ids validated by `assertOwnership`.

- [ ] **Step 1: Failing tests** — `PATCH with memo+cleared ⇒ [updateColumn memo, setCleared] in that order`; **Review Focus 5:** `PATCH {} and PATCH {foo:1} ⇒ 422 schema, no record, lock released`; `POST /v1/transfers stores generated.transferId and passes it in args`; `assigned over RTA ⇒ 422 unless allowOverAssign`; `assigned decrease causing future overspend ⇒ 422 unless allowOverspend`; `move cat→cat clamps to available and issues two absolute totals`; `move from rta ⇒ one entry, over-assign checked`; `move from == to ⇒ 422`; `move amount 0 ⇒ 422`; `month 2026-13 ⇒ 422`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): REST write wrappers (transactions, transfers, assigned, move)`.

### Task 15: Write crash points

**Files:**
- Modify: `src/crash-points.ts` (append `after_ledger_intent`, `after_ledger_queued_before_rename`, `after_outbox_add_before_send`, `after_send_before_ack`, `in_dequeuing_save`; `crashAt(point, outboxSize = 0)` writes the real size), call sites in `engine.ts`, `queue-storage.ts`, `send-window.ts`
- Test: `test/exit-codes.test.ts` (enum), `test/engine.test.ts` (each point reached once on the happy path, `process.exit` stubbed)

- [ ] **Step 1–5:** failing tests (`CRASH_POINTS` has the 9 names in order; each write point fires exactly once on a 1-op write; exit-info `outbox_size` equals the outbox at the crash) → implement → PASS → commit `feat(headless): write crash points`.

### Task 16: Payload parity test (headless executor vs harness `Device`)

**Files:**
- Create: `test/parity.test.ts`, `test/seeded-uuid.ts`

**Interfaces:**
- Consumes: `Device`, `setClock`, `installFxStub`, `dumpDb` from `@shared/mutations/fuzz/harness` (`fuzz/harness.ts:26, 67, 85, 187, 288`); the headless execution path of Task 11 run in-process against a `createHeadlessDatabase` built from the **same template bytes** as the Device.
- Produces: `installSeededUuid(seed: number): () => void` — replaces `globalThis.crypto.randomUUID` (used by `op-code-registry/shared.ts:428` for generated ids such as `transferId`) with a seeded generator; returns the restore function.

- [ ] **Step 1: Write the test** — one fixed op sequence covering every `allowed` op (and `move`/`assigned` wrappers), same seed and clock on both sides ⇒ for each op equal `{op, args}`, equal `v` via `mutationFormatVersion`, and equal `dumpDb(…, {sequences: true, crossDevice: true})` at the end. Run → FAIL where the headless path differs; fix in the owning module (unit test first). → PASS.
- [ ] **Step 2: Commit** — `test(headless): payload parity with the app pipeline`.

### Task 17: Bench scenarios (spec §12.2 "Done when")

**Files:**
- Create: `test/bench.m2.test.ts` (same skeleton as `bench.m1.test.ts`: `describe.skipIf(!HEADLESS_BENCH).sequential`, `timed`, per-test proxy with `spreadClientIps`)
- Modify: `test/bench.helpers.ts` (`api(h, path, {method, role, body, idempotencyKey})`; `serverLog(serverUrl, token, spaceId, before?): Promise<Array<{id; version; op; args}>>` decrypting `GET /sync/mutations?space_id&before&limit≤100` with the space key), `bench/README.md` (M2 command, wall time)

- [ ] **Step 1: Write the scenarios**, one `timed` each (numbering continues the spec list; every name states its assertion):
  1. `REST ops appear at the peer and in its next snapshot`.
  2. `each write crash point then retry with the same key ⇒ log grew by exactly k, decrypted {op,args} equal the ledger entries` (`it.each` over the 5 points).
  3. `same key twice concurrently ⇒ one mutation in the log`.
  4. `proxy holds the headless frame until a peer mutation is acked ⇒ 200 reordered, exit 75, dumpDb equal after, retry ⇒ reordered with id null`.
  5. `proxy drops the ack frame, op returns via catch-up ⇒ reordered from the dequeue observer`.
  6. `out-of-band restore during a 2-op PATCH ⇒ 202 at once, exit 77 within 10 s, next start drains op 2`.
  7. `202'd op acked after a reconnect at version ≠ base+1 ⇒ reordered persisted, exit 75`.
  8. `peer out-of-band upload while the socket is down after a headless write ⇒ exit 77 on reconnect`.
  9. `quarantine with writes: 503 quarantine_pending, admin ack ⇒ writes open`.
  10. `outbox non-empty at start + injected catch-up failure ⇒ exit 77, never live while the startup outbox is non-empty`.
  11. `checkApiHealth false during apply_failed ⇒ exit 77 (open episode at reconnect); quarantine at next start ⇒ one more 77 ⇒ live`.
  12. `live peer failure while connected ⇒ one restore, quarantine, exit 77 once, live with key skipped`.
  13. `peer edit of a row our queued delete removed, met during the startup drain ⇒ quarantined tainted, exit 77 after settledAfterRestore, dropped at the next clean start, applied there`.
  14. `transient apply failure (FX fetch failing once) ⇒ in-process restore, retry succeeds, live with no exit`.
  15. `blob without X-Mutation-Version (non-empty log) ⇒ halt bootstrap_failed:unbound_blob`.
  16. `admin drop outside outbox_blocked ⇒ 409`.
  17. `injected storage_error nack ⇒ 202 then exactly one log entry`.
  18. `injected invalid nack ⇒ outbox_blocked across a restart, admin drop, then 409 on the key`.
  19. `write while the socket is down ⇒ 503`.
  20. `budget with one continuous rule ⇒ transactions.add lands with no rules.execute, rules_in_budget 1`.
  21. `addTransfer with equal accounts ⇒ 422, exit 76; 6 in 10 min ⇒ 429`.
  22. `2-op PATCH whose op 2 throws in apply ⇒ draining at once, 200 partial after op 1 ack, exit 76; retry ⇒ same 200 partial, op 2 never executes`.
  23. `2-op PATCH whose op 2 throws in prepare ⇒ 200 partial, no rebuild`.
  24. `short SELF_HOST_JWT_TTL_HOURS ⇒ token refreshed without a halt` (server container started with the env override).
  25. `multi-currency write ⇒ GET /exchange-rates seen`.
  26. `proxy saw only allowlisted calls` (M1 list + `GET /sync/mutations` is the **bench's** call, made directly to the server, not through the proxy).
- [ ] **Step 2: Run** `HEADLESS_BENCH=1 pnpm --filter @budgero/headless exec vitest run test/bench.m2.test.ts` — fix failures in the owning module, unit test first, until green. Then the full bench (`test/bench.m1.test.ts` + `bench.m2`) once more: both green. Record wall times in `bench/README.md`.
- [ ] **Step 3: Commit** — `test(headless): milestone 2 bench scenarios`.

### Task 18: Argument-guard completeness check

**Files:**
- Test: `test/schemas.test.ts` (extend)

- [ ] **Step 1:** a table-driven test asserting **every** guard named in §9 (always-rejected keys, create ids, `transferId`, `updateColumn` column/values, `accounts.update` fields, `setCleared` arity, rules `mode`, `rules.execute` bounds, ownership per reference kind) has at least one rejecting case — spec §12.2 "every argument guard has a rejecting test". Fill any gap in Task 8's module. → PASS → commit `test(headless): one rejecting case per argument guard`.

---

## Phase C — Release artefacts

### Task 19: Fork tag and image (local; push gated)

- [ ] **Step 1:** full suites: `pnpm --filter @budgero/runtime test`, `pnpm --filter budgero-app test -- mutations`, `pnpm --filter @budgero/headless test`, `test:sh`, `type-check` (runtime, app, headless), both benches. All green; record counts.
- [ ] **Step 2:** `git tag headless-v1.22.1-2` (local). Build the image in local-source mode (`~/Progetti/lzc-budgero/docker/headless/build-local.sh`, tag `fliva/budgero-headless:1.22.1-2`), smoke: `/healthz` `not_configured`, `docker stop` ⇒ 143.
- [ ] **Step 3:** update `packages/headless/README.md` and the plan checkboxes; commit in `lzc-budgero` — `docs: M2 execution status`.
- [ ] **Step 4: Stop and ask Federico** for the go on `git push f-liva-fork feat/headless-client --tags` and the clone-mode rebuild + Docker Hub push.

## Phase D — NAS server upgrade to v1.22.1 (prerequisite for M3; gated)

### Task 20: lzc-budgero 1.0.21 on budgero v1.22.1

**Files (lzc-budgero):**
- Modify: `docker/Dockerfile` (`FROM budgero/budgero:v1.22.1`), `budgero-lzc/package.yml` (`version: 1.0.21`), `budgero-lzc/lzc-manifest.yml` (`image:` after the mirror), `README.md` (version notes)
- Test: `docker/tests/entrypoint.test.sh`

- [ ] **Step 1: Read the upstream changes** `v1.21.5..v1.22.1` (`git -C ~/Progetti/budgero log --oneline v1.21.5..v1.22.1 -- server/`, release notes): list server migrations and env changes; if a migration is not reversible, say so in the go request.
- [ ] **Step 2:** bump `FROM`, `docker build -t fliva/lzc-budgero:1.0.21 docker/`, `bash docker/tests/entrypoint.test.sh` → PASS; run the image locally with an empty `/data` and check `GET /api/v1/version/latest` = `1.22.1` (`APP_VERSION` unset).
- [ ] **Step 3: Stop and ask Federico for the go** (outward: Docker Hub push, Lazycat mirror, NAS install). Give him the migration list from Step 1.
- [ ] **Step 4 (after the go): backup on the NAS** — copy `/lzcapp/var/data/budgero.db` (with `sqlite3 .backup`, not `cp`, while the server runs) and the current blob (`GET /database/blob` with the web-app token, or the `blobs` table) to a dated directory outside the app data; record sizes and `sha256sum`.
- [ ] **Step 5: Deploy** with the `lazycat-redeploy` skill (push, `copy-image` from Windows lzc-cli, manifest `image:` bump, `.lpk` build, install). Verify: `lzc-docker exec <container> /app/budgero --version` (or `/version/latest`) = `1.22.1`; web app opens and syncs.
- [ ] **Step 6: Bound check** — make one write from the web app, then `curl -sI` the blob with that session token and confirm the `X-Mutation-Version` header is present (spec §12.3). Absent ⇒ stop: the headless would halt `unbound_blob`.
- [ ] **Step 7:** commit `lzc-budgero` (`feat: budgero v1.22.1 (lzc-budgero 1.0.21)`), update the PMB lesson on the NAS version, close/adjust the Vikunja task, Vikunja task for the M3 plan.

---

## Self-review notes

- **Spec coverage (M2 scope):** §7.2 send window/latch/nacks → T10; §7.5.5 ordering check → T9/T11; §7.5.6 throws by phase → T11; drain rule `drained` → T9; §7.6 rebuild `answerInFlight`/landed dequeues, 76 window → T11; §8.1 → T11/T13; §8.2 → T10 (+ M1 admin drop, bench T17.16/18); §8.3 → T7/T12; §8.4 writes blocked by quarantine → T11 gate, T17.9; §9 policy (M1) + schemas/ownership → T8/T13/T18; §10 write routes, wrappers, codes → T13/T14; §12.2 every done-when line → T16/T17 (parity = T16; write crash points = T15 + T17.2); §15 follow-ups → T1–T5; Federico's extra items → T5 (access_denied), T6 (U2 upstream), T20 (NAS).
- **Not in M2:** manifest service and 7-day read-only observation (M3); Ambrogio adapter (M4); U4/U5; the "ops package" refactor asked by the maintainer (flagged in T6's PR text).
- **Interfaces across tasks:** `Verdicts.expect/waitDequeued/onReordered` (T9) used by `WriteEngine` (T11); `SendWindow.closeLatch/onNack` (T10) called from `Verdicts.onReordered` wiring and the coordinator's `onMutationNacked` (T10/T11); `SchemaError` (T8) thrown by `body.ts` (T13) and `wrappers.ts` (T14); `WriteAnswer` (T7) is the body of every write `Result`; `OutboxWriteError` defined in `queue-storage.ts` (T11) next to `OutboxRejectedError`.
- **Proportion:** the plan states signatures, rules and test names; bodies are left to the implementer except where the spec fixes values (opId, hash, timings, budgets).

## Status (26/11/2026)

Fork `budgero-wt-headless`, branch `feat/headless-client`, HEAD `f72fbc55` (nothing pushed).

- **Tasks 1-18: done**, each reviewed. Phase A follow-ups (single-instance lock, down-mode port, log retention, redactor suffix, `access_denied` bench, U2 upstream diff and PR draft for #155) and Phase B writes (hashing and ledger rules, schemas and ownership, verdicts, send window and latch, write engine, startup re-execution, `/v1/ops/{op}`, REST wrappers, write crash points, payload parity, bench scenarios, argument-guard check).
- **Residual fix from the final review** (`484e457c`, controller Ruling 6): a retry that hit a `reordered` record with ops still `queued` answered 200 at once, with an unacked op. The immediate reordered 200 is now only for the request that executed the ops (§8.1.5); a retry waits for the queued ops and answers 202 `pending` after 30 s or from `answerInFlight` (§8.3). It also removes the flakiness of the engine test "reordered [acked, queued, intent]".
- **Task 19**: Step 1 run except the Docker benches, which the controller runs (runtime 437, app mutations subset 418, headless 748 + 63 skipped + 1 todo, `test:sh` all green, type-check runtime/app/headless clean). Step 2: image built in local mode at `f72fbc55` and tagged `fliva/budgero-headless:1.22.1-2` locally; smoke `/healthz` = `not_configured`, `docker stop` ⇒ 143. The tag `headless-v1.22.1-2` is created by the controller after the benches. Step 3: `packages/headless/README.md` has the M2 status (`f72fbc55`).
- **Pending Federico's go**: Task 19 Step 4 (push `f-liva-fork feat/headless-client --tags`, clone-mode rebuild, Docker Hub push) and Task 20 (NAS server on v1.22.1).
- Note: the full app suite has 6 failures under `LANG=it_IT.UTF-8` (`ExchangeRateCell.test.tsx`, `YnabCreditPaymentMatching.test.tsx`, number formatting); they pass with `LANG=en_US.UTF-8` and the branch does not touch those files.
