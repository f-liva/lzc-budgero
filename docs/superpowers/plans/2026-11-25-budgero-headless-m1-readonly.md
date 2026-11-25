# Budgero Headless — Milestone 1 (read-only client + bench) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Node process that is a live, read-only peer of one Budgero space (in-memory DB rebuilt from the server at every start, never uploads), exposing `/healthz`, `/v1/status` and the read routes, supervised in-container, proven by a bench that drives it through every rebuild/halt path of spec §7.

**Architecture:** The headless bundles the web app's own `RuntimeCoordinator`, op registry and `@budgero/core` with esbuild and runs them against Node shims (`localStorage`, `WebSocket`, `sql.js`). Upstream gets four patches (U1 external key, U2 injectable queue storage, U3 hook table, U6 pipeline module) in the fork branch `feat/headless-client`; everything else lives in a new workspace package `packages/headless`. State is a small explicit machine (`not_configured … shutting_down`); any doubt about "DB = snapshot + log in server order" ends the process with a coded exit and `entrypoint.sh` relaunches it.

**Tech Stack:** TypeScript (ESM), Node 22, pnpm 11 workspace, vitest 4, esbuild, `ws`, `sql.js` (wasm), busybox httpd (supervisor CGI), Docker (`budgero/budgero:v1.22.1` server for the bench).

**Spec:** `/home/fede9/Progetti/lzc-budgero/docs/superpowers/specs/2026-11-24-budgero-headless-client-design.md` (v29, approved 25/11/2026). Section numbers below (§7.4, §8.3 …) are the spec's. `file:line` references are at tag `v1.22.1` (= commit `b144212d`), relative to `packages/` of the monorepo.

## Repositories

| What | Where |
|---|---|
| Upstream patches + `packages/headless` | fork `~/Progetti/budgero`, branch **`feat/headless-client`** cut from **`v1.22.1`** (remote `f-liva-fork`). Work in a worktree: `git worktree add -b feat/headless-client ../budgero-wt-headless v1.22.1`. |
| Image + manifest | `~/Progetti/lzc-budgero` (`docker/headless/`, `budgero-lzc/lzc-manifest.yml`) — milestone 3; this plan only adds the Dockerfile (Task 19). |
| Spec + plans | `~/Progetti/lzc-budgero/docs/superpowers/` |

Commit convention: upstream (`packages/runtime`, `packages/app`, `packages/core`) changes as `feat(runtime): U1 …`, one commit per U-item (U3 may land as three commits `U3a/b/c`, squashed into one before the upstream PR). Headless package as `feat(headless): …`. No AI attribution lines.

## Global Constraints

- Pin: upstream `v1.22.1` = `b144212d`; the fork tag for the image is `headless-v1.22.1-<n>`.
- The headless **never uploads**: `allowUpload()` returns `false`, `uploadBlob` throws; the bench proxy allowlist is the proof (§12.1).
- `live` only when DB = snapshot + log in server order (§7.5). Any doubt ⇒ exit 75/76/77/78 (§7.6), never in-process re-activation.
- Exit codes: 75 reordered/drain/drop, 76 apply throw, 77 restore, 78 bootstrap transport retry, 1 config/`outbox_in_readonly`/uncaught, 143 TERM. Precedence `halt > 75 > 76 > 77`; once scheduled an exit is irrevocable.
- Durable files (§7.1), all under `--config-dir`: `outbox.json`, `ledger.json`, `quarantine.json`, `failures.json`, `halts.log`, `rebuilds.log` (supervisor-only writer), `exit-info`, `config.json`, secrets `password`, `space.key`, `tokens`. JSON writes: temp → fsync → rename → fsync dir, one promise chain per file. Logs: `O_APPEND` + fsync.
- Secrets: mode `600`, owned by the worker uid (1001 in the image); otherwise exit 1 `config:<field>`.
- Config: `url` http(s), `user`/`spaceId` strings, integer `budgetId`, `port` 1–65535 (8787 in production), booleans `readOnly`, `allowDestructive`.
- Env in production: only `TZ=Europe/Rome`, `BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}`.
- Tokens: `name:role:token`, roles `read|write|admin`; bearer compared constant-time, never logged.
- Logging: JSON lines on stdout `{ts, level, msg, state, mutationId?}` through a redactor (no token, password, key, `encryptedPayload`, args).
- Continuous rules never run in the headless (U6 `runContinuousRules: false`).
- Milestone 1 is **read-only**: write routes exist only as 503/404 per §7.3; the write gate, ledger verdicts and latch are milestone 2. Ledger/outbox files are still read and reconciled at start (§7.4.4–6) because the bench injects them.

## Review Focus

Inputs the spec implies but no done-when test names; each line has its test pinned in the owning task.

1. **`config.json` with an unknown extra key or a `port` given as a string** — reject with `config:<field>`, exit 1, never start half-configured. → Task 12.
2. **`outbox.json`/`ledger.json`/`quarantine.json` present but truncated/invalid JSON** (crash mid-rename never produces this, but an operator edit can) — exit 1 `config:<file>` with the file named; never treat it as empty. → Task 9.
3. **`rebuilds.log` with a malformed line** — the supervisor must still count the valid lines and never crash the budget check. → Task 16.
4. **Catch-up frame carrying a mutation whose `version` is lower than the cursor** (server replay after reconnect) — upstream skips it; the headless must not open a failure episode or log a halt. → Task 11.
5. **Token file with a Windows line ending or a trailing empty line** — parsed tokens must match exactly; an empty line is ignored, `\r` is stripped. → Task 12.

---

## File structure (`packages/headless`)

```
packages/headless/
  package.json  tsconfig.json  vitest.config.ts  esbuild.mjs
  src/
    main.ts                 CLI + startup steps 1–10 + shutdown (§7.4)
    config.ts               config/secret/token loading + validation
    state.ts                HeadlessState machine, startupDrain flag, episode, exit scheduling
    exit-codes.ts           EXIT_* constants, HaltReason union
    crash-points.ts         CRASH_POINTS enum + crashAt(point)
    locks.ts                ApplyPhaseLock, GlobalWriteLock (promise mutex)
    rebuild.ts              rebuild sequence → exit-info → process.exit
    logging.ts              JSON-lines logger + redactor
    platform/
      files.ts              atomicWriteJson, appendLog, FileChain
      storage.ts            in-memory localStorage shim
      database.ts           createHeadlessDatabase (NodeSqlJsAdapter, no-op forceSave, loader wrap)
      queue-storage.ts      QueueStorage over outbox.json + dequeue observer
      ledger.ts             ledger.json records (read/reconcile; verdicts in M2)
      quarantine.ts         quarantine.json + failures.json + covered/tainted
      halts.ts              halts.log append + 24h counters
      http.ts               download-side blobApi, login, version, failure classification
      websocket.ts          ws shim: Origin, URL, upgrade-status halts, blob check, outbound filter
      global.ts             services()/mutationsRouter()/mutationHistory wiring for the registry
      lingui.ts             @lingui/core/macro stub
    runtime/
      coordinator.ts        buildCoordinator(deps) — wires U1/U2/U3 into RuntimeCoordinator
      restore-rules.ts      restore table + failure episode (§7.5.4)
    api/
      server.ts             node:http router, bearer auth, route-state table (§7.3)
      routes-read.ts        /v1/accounts … /v1/months/{m} via core services
      routes-status.ts      /healthz, /v1/status, /v1/mutations/{id}
      routes-admin.ts       quarantine ack/retry, outbox drop (M1 subset)
  bench/
    docker-server.ts  create-space.ts  peer.ts  proxy.ts  run-headless.ts
  test/                     vitest unit tests (one file per src module)
  scripts/entrypoint.sh     supervisor (also copied into the image)
  scripts/healthz.cgi  scripts/status.cgi
packages/app/src/shared/mutations/headless-bench/*.spec.ts   end-to-end scenarios (spawn the headless)
```

Upstream touched files: `runtime/src/key-vault/key-vault.ts`, `runtime/src/coordinator/{runtime-coordinator-types,runtime-coordinator,runtime-context-factory,runtime-lifecycle-service,space-activation-service,reconnection-service}.ts`, `runtime/src/offline-queue/{offline-queue,storage}.ts`, `runtime/src/database-sync/database-sync.ts`, `runtime/src/sync-transport/sync-transport.ts`, `app/src/shared/runtime/app-runtime.ts`, new `app/src/shared/mutations/pipeline.ts`.

---

### Task 1: Branch, worktree, package skeleton

**Files:**
- Create: `packages/headless/package.json`, `tsconfig.json`, `vitest.config.ts`, `esbuild.mjs`, `src/exit-codes.ts`, `src/crash-points.ts`
- Modify: `pnpm-workspace.yaml` (nothing: `packages/*` already matches), root `package.json` scripts `test:headless`, `build:headless`

**Interfaces:**
- Produces: `EXIT = {REORDERED_OR_DRAIN: 75, APPLY_THROW: 76, RESTORE: 77, RETRY_BOOTSTRAP: 78, CONFIG: 1, TERM: 143} as const`; `type HaltReason` = the §7.7 union (`'version_mismatch' | 'auth_failed' | 'nack_blocked' | 'protocol_426' | 'space_reset' | 'ws_forbidden' | 'format_too_new' | 'unknown_op' | 'key_changed' | 'password_changed' | 'bootstrap_failed:download' | 'bootstrap_failed:decrypt' | 'bootstrap_failed:migrations' | 'bootstrap_failed:unbound_blob' | 'outbox_write_failed' | 'queue_cleared' | 'access_denied' | 'restore_loop' | 'restore_failed'`); `CRASH_POINTS = ['snapshot_download','create_database','before_catchup_settled','ws_before_apply'] as const` (M2 appends its write points); `crashAt(point: CrashPoint): void` — `process.exit(137)` when `--crash-at` equals `point`, after writing `exit-info {reason:'crash_at:'+point}`.

- [ ] **Step 1: Cut the branch**

```bash
cd ~/Progetti/budgero && git fetch origin --tags && git worktree add -b feat/headless-client ../budgero-wt-headless v1.22.1 && cd ../budgero-wt-headless && pnpm install --frozen-lockfile
```
Expected: install succeeds; `git rev-parse --short HEAD` prints `b144212d`.

- [ ] **Step 2: Baseline tests** — `pnpm --filter @budgero/runtime test` and `pnpm run type-check:runtime`. Expected: green (record the counts; later tasks must not reduce them).

- [ ] **Step 3: Write the failing test** `packages/headless/test/exit-codes.test.ts`:
```ts
it('exit codes match the spec table', () => {
  expect(EXIT).toEqual({ REORDERED_OR_DRAIN: 75, APPLY_THROW: 76, RESTORE: 77, RETRY_BOOTSTRAP: 78, CONFIG: 1, TERM: 143 });
});
it('crashAt exits 137 only at the configured point', () => { /* stub process.exit, set crash point, assert called with 137 for the matching point and not for another */ });
```

- [ ] **Step 4: Create the package.** `package.json`: `"name": "@budgero/headless"`, `"type": "module"`, deps `ws`, `@budgero/core: workspace:*`, `@budgero/runtime: workspace:*`, devDeps `vitest`, `esbuild`, `typescript ~5.6.3`, `@types/ws`, `@types/node`, `sql.js` (the wasm comes from `core`'s devDependency; see Task 19). `vitest.config.ts`: `environment: 'node'`. `tsconfig.json`: extends none, `module: NodeNext`, `strict`, `paths` `@shared/*` → `../app/src/shared/*`. `esbuild.mjs`: entry `src/main.ts`, `platform: node`, `format: esm`, `target: node22`, `bundle: true`, `external: ['sql.js']`, `banner.js` = `import { createRequire } from 'node:module'; const require = createRequire(import.meta.url);`, alias `@lingui/core/macro` → `src/platform/lingui.ts`, `@shared/runtime/global` → `src/platform/global.ts`, `@shared/*` → `../app/src/shared/*`, `@budgero/core/browser` → `../core/src/browser.ts`, `@budgero/runtime` → `../runtime/src/index.ts`, outfile `dist/headless.mjs`. Implement `exit-codes.ts`, `crash-points.ts`.

- [ ] **Step 5: Run** `pnpm --filter @budgero/headless test`. Expected: PASS.

- [ ] **Step 6: Commit** — `chore(headless): package skeleton, exit codes, crash points`.

---

### Task 2: U2 — injectable queue storage + `persisting` durability fix

**Files:**
- Modify: `runtime/src/offline-queue/storage.ts` (export `deserializeMutation`), `runtime/src/offline-queue/offline-queue.ts`, `runtime/src/coordinator/runtime-coordinator-types.ts` (`queueStorage?: QueueStorage`), `runtime/src/coordinator/runtime-context-factory.ts:201`, `runtime/src/coordinator/reconnection-service.ts:245`
- Test: `runtime/src/offline-queue/offline-queue.persisting.test.ts`

**Interfaces:**
- Produces: `RuntimeCoordinatorDeps.queueStorage?: QueueStorage`; `OfflineQueue.getSendable(): MutationPayload[]` (queue minus ids in `persisting`); `getStale()`, `getUnsent()` and the reconnection replay read `getSendable()`; `getQueue()` unchanged (unfiltered); `export function deserializeMutation(m, spaceId): MutationPayload`.

- [ ] **Step 1: Failing tests**
```ts
it('an entry is not sendable until storage.save resolves', async () => {
  // storage.save returns a deferred promise; call queue.add(m) without awaiting;
  expect(queue.getSendable()).toEqual([]); expect(queue.getQueue()).toHaveLength(1);
  resolveSave(); await addPromise; expect(queue.getSendable()).toHaveLength(1);
});
it('a rejected save keeps the id in persisting', /* reject; getSendable stays [] */);
it('coordinator passes deps.queueStorage to new OfflineQueue', /* spy constructor via factory */);
```
- [ ] **Step 2: Run** `pnpm --filter @budgero/runtime test offline-queue.persisting`. Expected: FAIL (`getSendable is not a function`).
- [ ] **Step 3: Implement.** `private persisting = new Set<string>()`; in `add()` add before `storage.save`, delete only in the resolved branch. Thread `deps.queueStorage` through `runtime-context-factory.ts:201`. Replace the three sweep/replay reads (`offline-queue.ts:141-147`, `reconnection-service.ts:245, 336-352`) with `getSendable()`.
- [ ] **Step 4: Run** runtime suite + `type-check:runtime`. Expected: PASS, counts ≥ baseline.
- [ ] **Step 5: Commit** — `feat(runtime): U2 injectable queue storage; keep non-durable entries unsent`.

---

### Task 3: U1 — external space key

**Files:**
- Modify: `runtime/src/key-vault/key-vault.ts` (`:223-233` generation path), `runtime/src/coordinator/runtime-coordinator-types.ts`, `runtime/src/coordinator/runtime-coordinator.ts:83`, `runtime/src/coordinator/runtime-lifecycle-service.ts:61-183` (master-password requirement), `runtime/src/coordinator/space-activation-service.ts` (persistence cipher sites)
- Test: `runtime/src/key-vault/key-vault.external.test.ts`

**Interfaces:**
- Produces: `RuntimeCoordinatorDeps.spaceKeySource?: { spaceId: string; key: Uint8Array }`. With it set: `KeyVault.getSpaceKey(id)` returns `key` for `spaceId`, throws `ExternalKeyMismatchError` for any other id; `ensureSpaceKeys`/`uploadEncryptedKey` never called; no master password needed by `activateSpace`; `localPersistence` cipher undefined at all three `createDatabase` call sites; key version read from the shim-backed `MasterPasswordStore`.

- [ ] **Step 1: Failing tests**
```ts
it('returns the injected key for the configured space and throws for another', …);
it('never calls uploadEncryptedKey or generates a key when spaceKeySource is set', /* spy deps.uploadEncryptedKey; activate; expect not called */);
it('activation does not require a master password when spaceKeySource is set', …);
```
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (branch at the vault's constructor: `spaceKeySource ? new ExternalKeyVault(...) : new KeyVault(...)` sharing the interface is the smallest change). **Step 4: Run** runtime suite + type-check → PASS. **Step 5: Commit** — `feat(runtime): U1 external space key source`.

---

### Task 4: U3a — upload gate, ack/nack hooks, `halt()`, `receiveIdle`

**Files:**
- Modify: `runtime/src/database-sync/database-sync.ts:318-330` (`allowUpload`), `runtime/src/coordinator/runtime-context-factory.ts:221` (`onMutationAck` before `ackMutation`), `runtime/src/sync-transport/sync-transport.ts:979` (`onMutationNacked`), `:179, 475, 488-497` (`receiveIdle`), `runtime/src/coordinator/runtime-coordinator.ts:720-733` (`getSyncDiagnostics().receiveIdle`, new `halt(reason)`), `runtime-coordinator-types.ts`
- Test: `runtime/src/coordinator/headless-hooks.a.test.ts`

**Interfaces:**
- Produces on `RuntimeCoordinatorDeps`: `allowUpload?(): boolean`; `onMutationAck?(id: string, version: number): Promise<void> | void` (awaited); `onMutationNacked?(id: string, code: string): void`. On `RuntimeCoordinator`: `halt(reason: string): void` (stops sync, reconnection, connectivity, timers; sets transport `destroyed`; `upload`/`downloadAndRestore` become no-ops behind a `halted` flag checked **before** `beforeRestore`); `SyncDiagnostics.receiveIdle: boolean` (`receiveTail === null && catchUpMutationBuffer.length === 0`).

- [ ] **Step 1: Failing tests** — `allowUpload false ⇒ doUpload returns before db.backup()`; `onMutationAck receives (id, version) and resolves before ackMutation runs` (order spy); `onMutationNacked gets normalised code`; `halt() ⇒ handleCatchUpUnsafe is a no-op and a later downloadAndRestore does not call beforeRestore`; `receiveIdle false while a receive is in flight`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(runtime): U3a upload gate, ack/nack hooks, halt(), receiveIdle`.

---

### Task 5: U3b — remote apply failure hooks

**Files:**
- Modify: `runtime/src/sync-transport/sync-transport.ts` (`:1080-1089` live loop, `:1210-1212` catch-up loop before `decodeMutationPayload`; `:1099-1107` and `:1219-1244` catch blocks; `:1215` success; `:194` map seed; `:1397-1419` quarantine), `runtime-coordinator-types.ts`
- Test: `runtime/src/sync-transport/headless-hooks.b.test.ts`

**Interfaces:**
- Produces: `skipMutationKeys?(): ReadonlySet<string>` (checked **before decode** in both loops, keyed `catchUpFailureKey({id: msg.mutationId ?? m.id, version})`; a hit skips and advances the cursor as quarantine does); `onRemoteApplyFailed?(mutation: {id?: string; version?: number; op?: string}, error: unknown, path: 'live' | 'catch_up', precedingVersion: number, willQuarantine: boolean): Promise<void> | void` (awaited; on the **live** path, when the hook is provided, apply the catch-up rule: same `{version, precedingVersion}` already recorded ⇒ quarantine, else record and `handleCatchUpUnsafe('apply_failed')`); `onQuarantined?(mutation, error): void`; `onRemoteApplySucceeded?(key: string): void` (both success paths); `seedCatchUpFailures?(): Map<string, {version: number; precedingVersion: number}>` (read at transport construction into `catchUpApplyFailures`).

- [ ] **Step 1: Failing tests** — `a key in skipMutationKeys is skipped before decryptPayload is called and the cursor advances`; `live apply failure: first ⇒ onRemoteApplyFailed(willQuarantine=false) then handleCatchUpUnsafe('apply_failed'); second at the same precedingVersion ⇒ willQuarantine=true then onQuarantined`; `seedCatchUpFailures makes the first observed failure quarantine`; `onRemoteApplySucceeded fires with the catchUpFailureKey on success`; `without the hooks the web app behaviour is unchanged (live failure does not touch catchUpApplyFailures)`.
- [ ] **Step 2–5:** FAIL → implement → PASS (runtime suite, type-check) → commit `feat(runtime): U3b remote apply failure hooks (skip, failed, quarantined, succeeded, seed)`.

---

### Task 6: U3c — restore hooks

**Files:**
- Modify: `runtime/src/database-sync/database-sync.ts:423-449` (`beforeRestore` after non-null `download()`, before `db.restore()`; `reason` parameter threaded), `runtime/src/coordinator/runtime-context-factory.ts:251-298` (`onRestoreCompleted` after `onCatchUpUnsafe` returns normally; pass `reason: 'catchup_unsafe'`), `runtime/src/coordinator/runtime-coordinator.ts:640-650` (`reason: 'out_of_band'`), `runtime/src/sync-transport/sync-transport.ts:1486-1489, 1589-1591` (per-connection settled signal)
- Test: `runtime/src/coordinator/headless-hooks.c.test.ts`

**Interfaces:**
- Produces: `beforeRestore?(info: {reason?: 'catchup_unsafe' | 'out_of_band'}): Promise<void>` (awaited); `onRestoreCompleted?(): void`; `RuntimeCoordinator.settledAfterRestore(): Promise<void>` — resolves at catch-up completion of the connection opened after the most recent restore (not on `catchUpInProgress=false`), no timeout.

- [ ] **Step 1: Failing tests** — `beforeRestore is awaited between download() and db.restore() with reason 'catchup_unsafe' from onCatchUpUnsafe and 'out_of_band' from downloadLatest`; `beforeRestore not called when download() returns null`; `onRestoreCompleted fires only when onCatchUpUnsafe returns normally`; `settledAfterRestore resolves at catch-up completion of the next connection and not at handleCatchUpUnsafe's catchUpInProgress=false`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(runtime): U3c restore hooks (beforeRestore reason, onRestoreCompleted, settledAfterRestore)`. Then run the **whole** `pnpm --filter @budgero/runtime test` and `type-check:runtime` once more; also `pnpm --filter budgero-app test -- mutations` to be sure the web app still passes.

---

### Task 7: U6 — shared mutation pipeline with `runContinuousRules`

**Files:**
- Create: `app/src/shared/mutations/pipeline.ts`
- Modify: `app/src/shared/runtime/app-runtime.ts:232-253, 760-900`
- Test: `app/src/shared/mutations/pipeline.spec.ts`

**Interfaces:**
- Produces: `export async function runMutationPipeline<T>(spec: MutationSpec, deps: PipelineDeps): Promise<MutationResult<T>>` where `PipelineDeps = { coordinator: Pick<RuntimeCoordinator,'executeMutation'>; services: () => Services; runContinuousRules: boolean; runRules?: (budgetId: number, txIds: number[]) => Promise<void> }`; does prepare (`prepareMutationArgs`), `coordinator.executeMutation`, and the rules post-hook only when `runContinuousRules && runRules`. No import of `@shared/lib/analytics/*` or toasts in this module (a test greps the file). `AppRuntime.executeMutation` calls it with `runContinuousRules: true` and wraps analytics around it.

- [ ] **Step 1: Failing tests** — `with runContinuousRules:false transactions.add issues exactly one mutation (no rules.execute)` (harness `Device` with one continuous rule); `with true the rule follow-up is issued as before`; `pipeline.ts imports nothing from @shared/lib/analytics` (read file, regex).
- [ ] **Step 2–5:** FAIL → implement (move, don't copy: `app-runtime.ts` must call the module) → `pnpm --filter budgero-app test`, `type-check:app` PASS → commit `feat(app): U6 shared mutation pipeline with runContinuousRules option`.

---

### Task 8: Platform — files, storage shim, lingui stub, logging

**Files:**
- Create: `headless/src/platform/files.ts`, `storage.ts`, `lingui.ts`, `headless/src/logging.ts`
- Test: `headless/test/files.test.ts`, `storage.test.ts`, `logging.test.ts`

**Interfaces:**
- Produces: `class FileChain { constructor(path: string); write(json: unknown): Promise<void>; settled(): Promise<void> }` (temp → fsync → rename → fsync dir; serialised; content snapshotted at call time); `appendLog(path: string, line: object): Promise<void>` (`O_APPEND`, fsync, one JSON per line); `readJsonOrAbsent<T>(path): Promise<T | undefined>` — throws `ConfigError('config:<basename>')` on invalid JSON (Review Focus 2); `installLocalStorageShim(): void` (fresh `Map`-backed `globalThis.localStorage`, `getItem/setItem/removeItem/key/length/clear`); `lingui.ts` exports `t`, `msg`, `plural`, `select` returning the template as a string; `log(level, msg, fields?)` → stdout line `{ts, level, msg, state, mutationId?}` with `redact()` removing values under keys `token|password|key|encryptedPayload|args|authorization` (case-insensitive) and any `Bearer …` substring.

- [ ] **Step 1: Failing tests** — `write twice concurrently ⇒ file holds the second content and a temp file never remains`; `settled() resolves after the last write`; `readJsonOrAbsent rejects with config:outbox.json on "{"`; `shim is empty after installLocalStorageShim() even if a key was set before`; `redact hides token and encryptedPayload and keeps mutationId`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): atomic files, localStorage shim, lingui stub, redacted logger`.

---

### Task 9: Platform — queue storage, ledger (read side), quarantine/failures, halts

**Files:**
- Create: `headless/src/platform/queue-storage.ts`, `ledger.ts`, `quarantine.ts`, `halts.ts`
- Test: `headless/test/queue-storage.test.ts`, `ledger.test.ts`, `quarantine.test.ts`, `halts.test.ts`

**Interfaces:**
- Produces:
  - `class OutboxStorage implements QueueStorage { constructor(dir, hooks: {onEnqueued(entry: MutationPayload): void; onDequeued(id: string, cause: 'ack' | 'drop'): void; onClear(): void}); load(spaceId); save(spaceId, queue); clear(spaceId); rejectSaves(): void; dropIds(ids: string[]): Promise<void> }` — `save` diffs ids vs the last saved set and calls the hooks **before** the rename resolves; `clear()` calls `onClear` (the caller halts `queue_cleared`); `rejectSaves()` makes every later `save` reject (used by admin drop); `dropIds` removes entries and reports `cause: 'drop'`. Entry JSON is `MutationPayload` with `timestamp` ISO string (`deserializeMutation` from U2 on load).
  - `ledger.ts`: `type OpState = 'intent'|'queued'|'acked'|'nacked'|'failed'|'skipped'|'dropped'|'unknown'`; `interface LedgerRecord { key: string; bodyHash: string; nonce: string; base: number; reordered: boolean; partial: boolean; generated: {transferId?: string}; ops: Array<{opId: string; state: OpState; drained?: boolean; entry?: MutationPayload; result?: unknown; version?: number}> }`; `class Ledger { load(); byKey(key); byOpId(opId); upsert(record); setOpState(opId, patch); records(): LedgerRecord[]; prune(now: Date): void }` — `prune` removes records older than 30 days whose ops are all terminal and none of whose ids is in the outbox (`isInOutbox(id)` injected). `reconcile(outboxIds: Set<string>, outboxEntries): {append: MutationPayload[]; remove: string[]}` implementing §7.4.4 (`queued` missing ⇒ append entry; `dropped`/`acked` present ⇒ remove; `unknown` ⇒ `queued` if present else `failed` + later ops `skipped`).
  - `quarantine.ts`: `interface QuarantineEntry { key; id?; version?; op?; error: {name; message}; at: string; acked: boolean; covered: boolean; tainted: boolean }`; `interface FailureEntry { key; version; precedingVersion; tainted: boolean }`; `class Quarantine { load(); upsert(entry) /* keeps acked, resets covered */; ack(key); remove(key); recomputeCovered(bound: number | undefined); dropTainted(); skipKeys(): ReadonlySet<string> /* not covered, not tainted */; blocking(): boolean /* any untainted, !acked, !covered */; failures: { seed(): Map; upsert(FailureEntry); remove(key); pruneUpTo(bound) } }`.
  - `halts.ts`: `recordHalt(dir, reason: HaltReason | 'quarantine' | 'restore_inproc'): Promise<void>`; `countHalts(dir, reason, windowMs): Promise<number>`.

- [ ] **Step 1: Failing tests** — queue: `save with a new id ⇒ onEnqueued before the promise resolves`; `save without an id ⇒ onDequeued(id,'ack')`; `dropIds ⇒ onDequeued(id,'drop')`; `clear ⇒ onClear`; `after rejectSaves every save rejects and the file is untouched`; `load on a truncated file rejects config:outbox.json`. ledger: one test per reconcile rule (4), `prune keeps a 40-day record with a queued op`, `prune keeps an acked record whose id is still in the outbox`. quarantine: `upsert on an existing key keeps acked=true and resets covered=false`; `recomputeCovered(10) marks version 7 covered, 11 not, undefined ⇒ none`; `skipKeys excludes covered and tainted`; `blocking ignores tainted and acked`; `dropTainted removes only tainted entries and tainted failures`; `failures.pruneUpTo(bound)`. halts: `countHalts counts only lines inside the window`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): outbox storage with dequeue observer, ledger reconcile, quarantine/failures, halts log`.

---

### Task 10: Platform — `http.ts` (download side) with contract test

**Files:**
- Create: `headless/src/platform/http.ts`
- Test: `headless/test/http.contract.test.ts` (reads `app/src/shared/api/api-client.ts` paths), `headless/test/http.classify.test.ts`

**Interfaces:**
- Produces: `class HeadlessHttp { constructor(opts: {baseUrl: string; origin: string; getToken: () => string | null}); login(user, password): Promise<{token: string; expiresAt: number}>; getProfile(); listSpaces(); checkApiHealth(): Promise<boolean> /* HEAD /health */; getDatabaseState(spaceId): Promise<{version; mutation_version?; hash?} | null>; downloadBlob(spaceId): Promise<{data: Uint8Array; headers: Headers} | null> /* null only on 404 */; versionLatest(): Promise<{build_version: string}>; lastBlobBound(): {present: boolean; value?: number} /* from readSnapshotVersions(headers) of the last blob response that preceded a successful download */; lastDatabaseState(): {mutation_version?: number} | undefined }`; `classifyFailure(e: unknown): 'transport' | 'server'` — transport = connection refused / timeout / 5xx / integrity failure after 200 / missing tag; server = 4xx other than 401/404 with a body. `class ServerFailure extends Error { status: number; body: string }`, `class TransportFailure extends Error`. Base URL also installed for core's relative FX fetch (`globalThis.fetch` wrapper that resolves `/api/...` against `baseUrl`).

- [ ] **Step 1: Failing tests** — contract: for each of `/profile`, `/budget-spaces`, `/health`, `/database/blob`, `/database/state`, `/version/latest`, `/auth/login` assert the path string used by `HeadlessHttp` appears verbatim in `api-client.ts` at the pin (read the file; fail with the missing path). classify: `ECONNREFUSED ⇒ transport`, `503 ⇒ transport`, `422 with body ⇒ server`, `401 ⇒ neither (rethrown as AuthFailure)`, `404 on blob ⇒ null`. bound: `blob response with X-Mutation-Version: 0 ⇒ {present:true, value:0}`, `without header ⇒ {present:false}`, `two responses (hash retry) ⇒ the last one before success`.
- [ ] **Step 2–5:** FAIL → implement (`node:http`/`fetch` from Node 22; no upload function; `uploadBlob` stub exported as `throwingUploadBlob`) → PASS → commit `feat(headless): download-only HTTP client with failure classification and bound recording`.

---

### Task 11: Platform — `websocket.ts` shim

**Files:**
- Create: `headless/src/platform/websocket.ts`
- Test: `headless/test/websocket.test.ts` (uses a local `ws` server)

**Interfaces:**
- Produces: `installWebSocketShim(opts: {origin: string; readOnly: boolean; onUpgradeStatus(status: number): void; onCloseReason(reason: string): void; onFrameOut(frame: WsMessage): 'send' | 'hold' | 'refuse'; onFrameIn(frame: WsMessage): void}): void` — sets `globalThis.WebSocket` to a `ws`-backed class sending `Origin: origin`; upgrade 426 ⇒ `onUpgradeStatus(426)`, 404/403/401 likewise; close reasons `space_reset|member_removed|blocked` forwarded; outbound: `catch_up_request` always sent, `mutation` frames refused when `readOnly` (throw `ReadOnlyFrameError`), every other type (`key_*`, `password_*`) refused always; `onFrameIn` sees every parsed inbound frame (the blob check and `out_of_band` detection live in Task 14). `buildWebSocketUrl(baseUrl, spaceId, token, clientSession): string` with query `token`, `space_id`, `protocol=SYNC_PROTOCOL_VERSION`, `client_session`.
- Consumes: `SYNC_PROTOCOL_VERSION` from `@budgero/runtime`.

- [ ] **Step 1: Failing tests** — `Origin header equals origin on upgrade`; `URL has the four query params`; `426/404/403/401 reach onUpgradeStatus`; `close with reason space_reset reaches onCloseReason`; `read-only: sending every frame type throws except catch_up_request` (§7.8 test, one `it.each` over `['mutation','key_rotation','password_changed','catch_up_request']`); `an inbound frame is parsed and passed to onFrameIn`; Review Focus 4: `a catch-up frame with version < cursor is passed through unchanged (the shim never filters inbound)`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): WebSocket shim with Origin, upgrade-status and frame policy`.

---

### Task 12: Config, secrets, tokens

**Files:**
- Create: `headless/src/config.ts`
- Test: `headless/test/config.test.ts`

**Interfaces:**
- Produces: `interface HeadlessConfig { url: string; user: string; spaceId: string; budgetId: number; readOnly: boolean; allowDestructive: boolean; port: number }`; `loadConfig(dir, uid: number): Promise<{config: HeadlessConfig; secrets: {password: string; spaceKey: Uint8Array; tokens: Token[]}} | 'not_configured'>` — missing `config.json` ⇒ `'not_configured'`; any validation failure throws `ConfigError(reason: 'config:<field>')` where field ∈ config keys or `password|space.key|tokens`; secrets must be mode `0600` and owned by `uid`; `space.key` is raw base64 → `Uint8Array` (length 32 else `config:space.key`); `interface Token { name: string; role: 'read' | 'write' | 'admin'; token: string }` parsed from lines `name:role:token`, `\r` stripped, empty lines ignored. `roleAllows(role, need: 'read' | 'write' | 'admin'): boolean` (admin ⊇ write ⊇ read).

- [ ] **Step 1: Failing tests** — `missing config.json ⇒ 'not_configured'`; `port "8787" (string) ⇒ config:port`; `unknown key ⇒ config:<key>` (Review Focus 1); `url ftp:// ⇒ config:url`; `budgetId 1.5 ⇒ config:budgetId`; `password mode 0644 ⇒ config:password`; `password owned by another uid ⇒ config:password`; `space.key not base64 / wrong length ⇒ config:space.key`; `tokens with CRLF and trailing blank line parse to 2 tokens` (Review Focus 5); `token line with role "root" ⇒ config:tokens`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): config, secrets and token loading with strict validation`.

---

### Task 13: State machine, locks, exit scheduling, rebuild

**Files:**
- Create: `headless/src/state.ts`, `locks.ts`, `rebuild.ts`
- Test: `headless/test/state.test.ts`, `locks.test.ts`, `rebuild.test.ts`

**Interfaces:**
- Produces:
  - `type HeadlessState = 'not_configured'|'bootstrapping'|'draining'|'live'|'outbox_blocked'|'halted'|'shutting_down'`.
  - `class StateMachine { state: HeadlessState; reason?: string; startupDrain: boolean; episode: {priorState: HeadlessState; applyDirty: boolean; queuedAtRestore: number} | null; scheduled: {code: 75|76|77|78|1|143; reason: string} | null; set(state, reason?); scheduleExit(code, reason): boolean /* precedence halt>75>76>77: returns true if it became the scheduled exit; irrevocable once set; a halt clears it */; halt(reason: HaltReason) /* state halted, scheduled cleared, wins */; openEpisode(priorState); closeEpisodeTo(): HeadlessState; onStateChange(listener) }`.
  - `class Mutex { acquire(): Promise<() => void>; waitIdle(): Promise<void> }` used as `applyPhaseLock` and `globalWriteLock`.
  - `rebuild(ctx: {sm; applyPhaseLock; chains: FileChain[]; coordinator: {halt(r: string): void}; dir; startedAt: number; outboxSize(): number; answerInFlight(): Promise<void>}): Promise<never>` — order per §7.6: wait apply-phase lock → (76 only) wait dequeues of landed ops up to 30 s → `answerInFlight()` → `coordinator.halt()` → `Promise.all(chains.settled())` → write `exit-info {reason, outbox_size, uptime_s}` → `process.exit(code)`. `writeExitInfo(dir, info)`; `clearExitInfo(dir)`.

- [ ] **Step 1: Failing tests** — `scheduleExit(77) then scheduleExit(75) ⇒ scheduled code 75`; `scheduleExit(75) then (77) ⇒ stays 75`; `halt() after scheduleExit(75) ⇒ state halted, scheduled null`; `scheduleExit after halt ⇒ false, state stays halted`; `openEpisode keeps the first priorState across a second open`; `closeEpisodeTo returns priorState, or 'draining' when startupDrain`; `Mutex serialises two acquirers; waitIdle resolves when free`; rebuild (process.exit stubbed, chains spied): `order is lock → answer → halt → chains → exit-info → exit`; `exit-info content {reason, outbox_size, uptime_s}`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): state machine with exit precedence, locks, rebuild sequence`.

---

### Task 14: Coordinator wiring + restore rules

**Files:**
- Create: `headless/src/runtime/coordinator.ts`, `headless/src/runtime/restore-rules.ts`, `headless/src/platform/database.ts`, `headless/src/platform/global.ts`
- Test: `headless/test/restore-rules.test.ts`, `headless/test/database.test.ts`, `headless/test/coordinator-deps.test.ts`

**Interfaces:**
- Consumes: U1–U3 deps (Tasks 2–6), `OutboxStorage`, `Quarantine`, `Ledger`, `HeadlessHttp`, `StateMachine`, `Mutex`, `rebuild`.
- Produces:
  - `createHeadlessDatabase(data?: Uint8Array): Promise<WebDatabaseInstance>` — `NodeSqlJsAdapter.create(data)` wrapped so `forceSave` is a no-op returning `true` (persist goes to the shim only) and so a thrown migration/decrypt error is **captured** (`lastLoaderError`) instead of swallowed by activation (spec §7.5.2).
  - `global.ts`: `setHeadlessRuntime(rt: {services(): Services; mutationsRouter(); mutationHistory})`, `getRuntime()` compatible with `@shared/runtime/global` (the registry calls `getRuntime()`); startup throws `MissingServiceError` if any of the three is absent.
  - `buildCoordinator(ctx): {coordinator: RuntimeCoordinator; activate(): Promise<void>}` wiring: `spaceKeySource`, `queueStorage: OutboxStorage`, `allowUpload: () => false`, `uploadBlob: throwingUploadBlob`, `hasLocalDatabase: async () => false`, `reconnectionPolicy.recentDownloadWindowMs: Number.MAX_SAFE_INTEGER`, `onSpaceActivated` (§7.4.10 and §7.5.2: `ok && (path==='server_snapshot'||'fresh')` else halt `bootstrap_failed:<download|decrypt|migrations>`; bound check synchronous: `lastBlobBound().present===false` and `lastDatabaseState()?.mutation_version !== 0` ⇒ halt `bootstrap_failed:unbound_blob`; `mutation_version` **missing** ⇒ exit 78 (transport); then `quarantine.recomputeCovered(bound)`, `failures.pruneUpTo(bound)`), `skipMutationKeys: () => quarantine.skipKeys()`, `seedCatchUpFailures`, `onRemoteApplyFailed`/`onQuarantined`/`onRemoteApplySucceeded` → `restore-rules`, `beforeRestore`/`onRestoreCompleted` → `restore-rules`, `onFormatTooNew ⇒ halt('format_too_new')`, `onUnknownOpCode ⇒ halt('unknown_op')`, `onEncryptionKeyChanged ⇒ halt('key_changed')`, `setPasswordChangedReason/reloadApp ⇒ halt('password_changed')`, sync-status listener: `syncError.code==='snapshot_unavailable' ⇒ halt('restore_failed')`.
  - `restore-rules.ts`: `class RestoreRules { constructor(sm, applyPhaseLock, quarantine, halts, outboxSize: () => number); onRemoteApplyFailed(m, err, path, preceding, willQuarantine); onQuarantined(m, err); beforeRestore({reason}): Promise<void>; onRestoreCompleted(); onSettledAfterRestore(); onSocketOpenOrClose(); countInproc24h(): Promise<number> }` implementing the §7.5.4 table and failure-episode rules verbatim: `tainted = outboxSize() > 0` at recording; untainted quarantine ⇒ `draining` + exit 77 after the lock; `willQuarantine=false` ⇒ open episode `{priorState, applyDirty:true}` + `draining`; `beforeRestore` waits the apply-phase lock only, records `queuedAtRestore = max(existing, outbox)`; `out_of_band` or no reason ⇒ exit 77 when the lock is free; `catchup_unsafe` ⇒ in-process, `halts.log restore_inproc`, `> 50 in 24 h ⇒ halt restore_loop`; `onRestoreCompleted` clears `applyDirty` and re-runs the unbound-blob check; `onSettledAfterRestore`: exit 77 iff `queuedAtRestore > 0`, else `closeEpisodeTo()` and, if `startupDrain && outboxSize()===0`, exit 75; `onSocketOpenOrClose`: `applyDirty` still set ⇒ exit 77.

- [ ] **Step 1: Failing tests** — restore-rules, one `it` per table row and per episode rule: `first failure (willQuarantine=false) ⇒ state draining, episode open, no exit`; `second failure same preceding ⇒ no episode change; onQuarantined untainted ⇒ exit 77 scheduled`; `onQuarantined with outbox>0 ⇒ tainted, nothing scheduled`; `beforeRestore out_of_band ⇒ 77 scheduled after lock`; `beforeRestore catchup_unsafe + settled with queuedAtRestore 0 ⇒ back to priorState`; `… queuedAtRestore 2 ⇒ 77`; `priorState never overwritten by a second failure`; `settled during startupDrain with empty outbox ⇒ 75`; `75 scheduled then 77 ⇒ 75 stays`; `applyDirty at onopen ⇒ 77`; `51st inproc in 24h ⇒ halt restore_loop`; `halt wins over a scheduled 77`. database: `forceSave resolves true and writes nothing to disk`; `a migration throw is exposed in lastLoaderError`. coordinator-deps: `allowUpload() === false`, `uploadBlob rejects`, `recentDownloadWindowMs === MAX_SAFE_INTEGER`, `activation with path 'local' ⇒ halt bootstrap_failed:download`, `blob without bound and state.mutation_version 3 ⇒ halt unbound_blob`, `... mutation_version 0 ⇒ no halt, covered recomputed with 0`, `... mutation_version missing ⇒ exit 78 scheduled`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): coordinator wiring, in-memory database, restore rules and failure episodes`.

---

### Task 15: Startup sequence, blob check, shutdown (`main.ts`)

**Files:**
- Create: `headless/src/main.ts`
- Modify: `headless/src/platform/websocket.ts` (hook `onOpen` for the blob check)
- Test: `headless/test/main.startup.test.ts` (fakes for http/ws/coordinator)

**Interfaces:**
- Produces: `main(argv): Promise<void>` doing §7.4 steps 1–10 in order: parse `--config-dir` (default `/lzcapp/var/headless`), `--bench`, `--crash-at`, `--backoff-ms`; `clearExitInfo`; `loadConfig` (`'not_configured'` ⇒ state `not_configured`, API up, stop); tokens; read `rebuilds.log` for `last_exit`; `ledger.reconcile` + outbox fix-up, `quarantine.dropTainted()` if the outbox is empty after it; nacked check ⇒ `outbox_blocked` reason `nack_blocked`, admin routes only, **no activation**; `readOnly && outbox>0` ⇒ exit 1 `outbox_in_readonly`; version check (`versionLatest()`: transport ⇒ retry with backoff in `bootstrapping`; `unknown` or `≠ bundled` ⇒ halt `version_mismatch`; bundled version = `BUNDLED_VERSION` constant written by `esbuild.mjs` from the fork tag); login (transport ⇒ retry; 401 ⇒ halt `auth_failed`; refresh before `expiresAt` and on any later 401, second 401 ⇒ halt); activate (transport download failure ⇒ `coordinator.halt()` then exit 78 `retry_bootstrap`; server failure ⇒ halt `bootstrap_failed:download`); `bootstrapping` until `initialCatchUpSettled`; `outbox>0` at start ⇒ `startupDrain=true`, state `draining`, exit 75 when the outbox empties. **Blob check** on every WS open: `getDatabaseState().version > getSyncDiagnostics().blobVersion` ⇒ `draining` + exit 77; check failed ⇒ `blobCheckPassed=false` (gate input for M2), retry next open; inbound `sync_state_changed` with `out_of_band && version > blobVersion` ⇒ `draining` at once. Shutdown on `SIGTERM`/`SIGINT`: `shutting_down`, wait apply-phase lock, `halt()`, chains settled, exit 143. Uncaught exception ⇒ `exit-info` + exit 1. `exit-info` written on **every** worker exit.

- [ ] **Step 1: Failing tests** (fake http returning scripted responses; coordinator faked with an event emitter): `order of calls is version → login → activate`; `version transport error ⇒ state bootstrapping and a retry`; `version 'unknown' ⇒ halt version_mismatch`; `login 401 ⇒ halt auth_failed`; `download transport failure ⇒ coordinator.halt then exit 78`; `download 422 with body ⇒ halt bootstrap_failed:download`; `outbox non-empty ⇒ startupDrain and draining; outbox emptied ⇒ exit 75`; `ledger nacked op present in outbox ⇒ outbox_blocked and activate never called`; `readOnly + outbox ⇒ exit 1 outbox_in_readonly`; `blob check newer server version on open ⇒ exit 77`; `out_of_band frame ⇒ draining`; `SIGTERM ⇒ halt, chains settled, exit 143`; `exit-info exists after exit 1`; `crashAt('snapshot_download') exits 137 with exit-info reason crash_at:snapshot_download`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): startup sequence, blob check, shutdown`.

---

### Task 16: REST API — server, status, reads, admin (M1 subset)

**Files:**
- Create: `headless/src/api/server.ts`, `routes-status.ts`, `routes-read.ts`, `routes-admin.ts`
- Test: `headless/test/api.routes.test.ts` (route × state table), `api.reads.test.ts` (against a `NodeSqlJsAdapter` seeded through core services), `api.admin.test.ts`

**Interfaces:**
- Produces: `startApi(ctx: {port; tokens; sm; services: () => Services; budgetId; status: () => StatusBody; ledger; quarantine; outbox; triggerExit(code, reason)}): Promise<{close(): Promise<void>}>` on `node:http`, no framework. Auth: `Authorization: Bearer <t>` matched with `crypto.timingSafeEqual` against each token; missing/unknown ⇒ 401; role insufficient ⇒ 403 `{error:'role'}`. Route/state behaviour **exactly** the §7.3 table; reads in `bootstrapping` after the activation report is accepted ⇒ 200 + `stale: true`. Read routes (`budgetId` scoped, milliunits): `GET /v1/accounts`, `/v1/category-groups`, `/v1/categories`, `/v1/payees`, `/v1/transactions?account&category&payee&since&until&cleared&limit&offset` (`limit` default 100 max 1000), `/v1/transactions/{id}`, `/v1/months/{YYYY-MM}` (`getMonthlyBudget` + `getReadyToAssignBreakdown`, process TZ), `/v1/recurring`, `/v1/ops` (policy tiers; in M1 returns the static lists from Task 17's `op-policy.ts`). Status: `GET /healthz` `{state, reason}`; `GET /v1/status` with every §10 field (`rebuilds_24h`/`restores_24h` from `rebuilds.log` codes 75/77; `restores_inproc_24h` from `halts.log`; `versions: {server, bundled}`); `GET /v1/mutations/{id}` from the ledger (`intent|queued → pending`). Admin (role `admin`): `POST /v1/admin/quarantine/{key}/ack` (any state but `shutting_down`/`not_configured`); `POST /v1/admin/quarantine/{key}/retry` (200 only in `live`: remove entry, exit 77; else 409); `POST /v1/admin/outbox/{id}/drop` (200 only in `outbox_blocked` on a record with a `nacked` op: take apply-phase lock, `outbox.rejectSaves()`, chains settled, mark every op of the record still in the outbox `dropped` in one ledger write, `outbox.dropIds`, exit 75; else 409).
- Write routes in M1: registered, answer 503 in every state (`not_configured` included, per spec §7.3), so the route table test is complete now and M2 only replaces the `live` cell.

- [ ] **Step 1: Failing tests** — `it.each` over the §7.3 table (route × 7 states ⇒ expected code), `missing bearer ⇒ 401`, `read token on admin route ⇒ 403 role`, `token compared without echo in body or log`; reads: `/v1/accounts returns only budgetId's accounts`, `/v1/transactions?since=&until= filters inclusive`, `limit 5000 ⇒ clamped to 1000`, `/v1/months/2026-11 has ready_to_assign and per-category assigned/activity/available in milliunits`, `/v1/status has every field name from §10` (assert key set), `/v1/mutations/{unknown} ⇒ 404`; admin: `ack sets acked=true`, `retry in bootstrapping ⇒ 409`, `retry in live ⇒ entry removed and exit 77 scheduled`, `drop in live ⇒ 409`, `drop in outbox_blocked on nacked record ⇒ every op of the record dropped, outbox empty, saves rejected, exit 75`; Review Focus 3: `/v1/status counts rebuilds_24h ignoring a malformed rebuilds.log line`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): REST API — status, reads, admin routes, route/state table`.

---

### Task 17: Op policy tables (static, consumed by `/v1/ops` now and the gate in M2)

**Files:**
- Create: `headless/src/api/op-policy.ts`
- Test: `headless/test/op-policy.test.ts`

**Interfaces:**
- Produces: `OP_POLICY: { allowed: readonly string[]; destructive: readonly string[]; closed: readonly string[] }` with the exact §9 names; `tierOf(op): 'allowed'|'destructive'|'closed'`; unlisted ⇒ `'closed'`.

- [ ] **Step 1: Failing test** — `every listed op is in KNOWN_OP_CODES` (import the registry through the esbuild aliases; print names missing); `prints registry ops in no tier` (informational `console.info`, not a failure); `tierOf('history.applyOps') === 'closed'`; `tierOf('transactions.add') === 'allowed'`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat(headless): op policy tiers`.

---

### Task 18: Supervisor `entrypoint.sh` + CGI responders

**Files:**
- Create: `headless/scripts/entrypoint.sh`, `scripts/healthz.cgi`, `scripts/status.cgi`
- Test: `headless/scripts/entrypoint.test.sh` (bash; uses a **stub worker** `scripts/stub-worker.sh` that exits with a code taken from a queue file and writes `exit-info`), run by `pnpm --filter @budgero/headless test:sh`

**Interfaces:**
- Produces: `entrypoint.sh [--config-dir D] [--backoff-ms N] [--worker CMD]` (defaults `/lzcapp/var/headless`, `5000`, `node /app/dist/headless.mjs`): loop launching the worker with the same `--config-dir`/`--bench`/`--crash-at` args; after each exit read `exit-info`, append `{ts, code, reason, outbox_size}` to `rebuilds.log` (sole writer); relaunch on 75/76/77; on 78 relaunch with exponential backoff `--backoff-ms × 2^n` capped at 300000 ms, "consecutive" reset by a child with `uptime_s ≥ 600`, 20 consecutive ⇒ stay down `bootstrap_retries_exhausted`; budgets over the last 24 h of `rebuilds.log`: 21st code 75 ⇒ `rebuild_storm`, 51st code 77 ⇒ `restore_storm`; a 75 following a record with code 75/76/77 and `outbox_size > 0` is **not** counted; any other code ⇒ stay down. While down (storm, exhausted, exit 1, 137): run `busybox httpd -f -p 8787 -h /app/cgi` whose `healthz.cgi` answers 503 `{state:"halted", reason}` and `status.cgi` answers 200 `{state:"halted", reason}`; `trap 'kill -TERM "$child"; wait "$child"; exit 143' TERM INT`; on child 143 exit 143 too. Malformed `rebuilds.log` lines are skipped (Review Focus 3).

- [ ] **Step 1: Failing shell tests** (each: fresh dir, scripted exit codes, assert `rebuilds.log` lines and whether the worker was relaunched / httpd is serving): `75 ⇒ relaunch, log line {code:75}`; `1 ⇒ stays down, /healthz 503`; `20× 78 ⇒ bootstrap_retries_exhausted`; `78 ×3 with backoff-ms 10 ⇒ delays 10,20,40`; `21 × 75 within the file ⇒ rebuild_storm`; `75 after {code:75, outbox_size:1} not counted`; `51 × 77 ⇒ restore_storm`; `TERM to supervisor ⇒ child gets TERM, exit 143`; `renaming rebuilds.log and restarting clears the storm`; `a garbage line in rebuilds.log does not stop counting`.
- [ ] **Step 2–5:** FAIL → implement → PASS (`bash scripts/entrypoint.test.sh`) → commit `feat(headless): in-container supervisor with budgets, backoff and CGI status`.

---

### Task 19: esbuild bundle + image

**Files:**
- Modify: `headless/esbuild.mjs` (inject `BUNDLED_VERSION` from `git describe --tags`), `headless/package.json` (`build`)
- Create: `~/Progetti/lzc-budgero/docker/headless/Dockerfile`, `docker/headless/README.md`
- Test: `headless/test/bundle.smoke.test.ts` (spawns `node dist/headless.mjs --config-dir <empty>` and expects `/healthz` 200 `{state:"not_configured"}` within 5 s, then TERM ⇒ 143)

**Interfaces:**
- Produces: `dist/headless.mjs` (single ESM file, `sql.js` external); image `fliva/budgero-headless:1.22.1-<n>` built by a multi-stage Dockerfile: stage 1 `node:22-alpine` + `git` + `pnpm@11`: clone `https://github.com/f-liva/budgero` at `ARG FORK_TAG=headless-v1.22.1-<n>`, `pnpm install --frozen-lockfile --prod=false`, `pnpm --filter @budgero/headless build`; stage 2 `node:22-alpine` + `busybox-extras`, `COPY dist/ /app/dist/`, `cp -rL packages/core/node_modules/sql.js /app/node_modules/sql.js`, `COPY scripts/entrypoint.sh scripts/*.cgi`, `USER 1001`, `WORKDIR /app`, `ENTRYPOINT ["/app/entrypoint.sh"]`.

- [ ] **Step 1: Failing smoke test** as above. **Step 2:** `pnpm --filter @budgero/headless build` ⇒ `dist/headless.mjs` exists; run the test ⇒ PASS. **Step 3:** `docker build -t fliva/budgero-headless:dev --build-arg FORK_TAG=feat/headless-client ~/Progetti/lzc-budgero/docker/headless` then `docker run --rm -p 8787:8787 -v $(mktemp -d):/lzcapp/var/headless fliva/budgero-headless:dev` ⇒ `/healthz` answers `not_configured`; `docker stop` ⇒ exit 143. **Step 4:** Commit in both repos — `build(headless): esbuild bundle with bundled version` and `feat(docker): headless image`.

---

### Task 20: Bench infrastructure — server, space, peer, proxy

**Files:**
- Create: `headless/bench/docker-server.ts`, `create-space.ts`, `peer.ts`, `proxy.ts`, `run-headless.ts`
- Test: `headless/test/bench.proxy.test.ts`

**Interfaces:**
- Produces:
  - `startServer(): Promise<{url: string; stop(): Promise<void>}>` — `docker run --rm -d -p 0:3001 -e SELF_HOSTABLE=true -e WEBSOCKET_ALLOWED_ORIGINS=http://bench.local -e BUDGERO_ADMIN_USER=admin -e BUDGERO_ADMIN_PASSWORD=Admin1234 budgero/budgero:v1.22.1` (pull once; port read from `docker port`).
  - `createSpace(serverUrl): Promise<{user; password; spaceId; spaceKeyB64; budgetId}>` — register/login via the app's `api-client` paths, generate + wrap + upload the key with the runtime's own `KeyVault`, `budgets.create` through a peer `Device`.
  - `class Peer` — a second client **with uploads**: the runtime coordinator in Node with the browser-equivalent deps (same shims as the headless but `allowUpload` true and a real `uploadBlob`); `write(op, args)`, `uploadOutOfBand()`, `dumpDb(options)`, `months(n): Promise<unknown[]>`.
  - `class Proxy` — WebSocket-aware reverse proxy at `url` used by both clients: `log: Array<{method; path; status}>`; `holdFrames(pred: (frame) => boolean)` / `release()`; `dropFrames(pred)`; `inject(frame, direction)`; `respondOnce(path, {status, body, headers})`; `stripHeader(path, name)`; `allowlist` checker `onlyAllowed(paths: string[]): string[]` returning offenders.
  - `runHeadless(opts: {dir; configOverrides?; crashAt?; bench: true}): {proc; waitState(state, timeoutMs): Promise<void>; status(): Promise<StatusBody>; exitCode(): Promise<number>; debugDb(): Promise<Uint8Array> /* GET /v1/debug/db, --bench only */; kill(): void}` spawning `scripts/entrypoint.sh --worker "node dist/headless.mjs" --backoff-ms 50`; the harness itself relaunches on 137.

- [ ] **Step 1: Failing test** for the proxy alone: `HTTP pass-through records method/path/status`; `WS frames pass both ways`; `holdFrames holds a mutation frame until release`; `respondOnce replaces exactly one response`; `stripHeader removes X-Mutation-Version`.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `test(headless): bench server, space creator, peer, proxy, runner`.

---

### Task 21: Bench scenarios (spec §12.1 "Done when")

**Files:**
- Create: `app/src/shared/mutations/headless-bench/m1.spec.ts` (runs in the app's vitest so `dumpDb`, `Device` and `installFxStub` are importable; guarded by `process.env.HEADLESS_BENCH=1`, skipped otherwise), `headless/bench/README.md`

**Interfaces:**
- Consumes: Task 20 API; `dumpDb(adapter, {sequences: true, crossDevice: true})` from `fuzz/harness.ts:187`; `/v1/debug/db` to load the headless DB into a `NodeSqlJsAdapter` for dumping.

- [ ] **Step 1: Write the scenarios**, one `it` each, names and assertions:
  1. `peer write visible within 5 s` — `/v1/transactions` contains the id.
  2. `restart rebuilds to live` — TERM ⇒ 143, relaunch ⇒ `live`.
  3. `/v1/months equals the peer for 3 months`.
  4. `every crash point ends live with equal dumpDb` — `it.each(CRASH_POINTS)`; `mutation_history` compared as a set of `MutationID`s.
  5. `100 random kills (seeded) end live with equal dumpDb` — seed printed; kill at random delays.
  6. `peer out-of-band upload ⇒ exit 77 then live`.
  7. `blob 422 with body ⇒ halt bootstrap_failed:download` (`respondOnce`).
  8. `server unreachable before activation ⇒ bootstrapping retries` (proxy down then up).
  9. `blob 500 ⇒ exit 78 with backoff; 20 consecutive ⇒ stays down bootstrap_retries_exhausted`.
  10. `WS drop with no newer blob ⇒ no restore` (no `beforeRestore` in logs, no 77).
  11. `remote apply throw (updateColumn on a deleted row, injected while down) ⇒ in-process restore, retry, quarantine, one exit 77, live with key skipped` — assert `quarantined: [1]` with `op`/`error`, `rebuilds.log` has exactly one 77.
  12. `restart and forced in-process restore ⇒ no new quarantine entry`.
  13. `peer snapshot bound past it ⇒ covered on next start; older history restore ⇒ uncovered`.
  14. `retry ⇒ exit 77, replay, re-quarantine`.
  15. `corrupted encryptedPayload quarantine is skipped before decode at next start` (inject frame with garbage payload).
  16. `blob without X-Mutation-Version on an empty log ⇒ live with cursor 0` (`stripHeader`, fresh space).
  17. `51 forced in-process restores ⇒ halt restore_loop`.
  18. `unknown op code ⇒ halt unknown_op` (inject a mutation frame with op `nope.nope` encrypted with the space key).
  19. `read-only frame tests` — covered in Task 11; here only `WS URL has protocol and client_session and Origin equals BUDGERO_ORIGIN` from the proxy log.
  20. `2-op outbox with op 1 nacked invalid (injected ledger+outbox fixtures) then admin drop ⇒ outbox.json empty, every op dropped, exit 75`.
  21. `state never leaves draining between onQuarantined and the exit` (poll `/v1/status` at 20 ms).
  22. `catch-up-unsafe restore served an unbound blob ⇒ halt before cursor reseed` (`stripHeader` on the second blob fetch; assert `halts.log` `bootstrap_failed:unbound_blob` and the cursor in `/v1/status` unchanged).
  23. `proxy saw only allowlisted calls, each required one at least once` — allowlist: login, `GET /profile`, `GET /budget-spaces`, `HEAD /health`, `GET /database/blob`, `GET /database/state`, `GET /version/latest`, WS upgrade; `GET /exchange-rates` allowed, not required.
  24. `exits 75/76/77 relaunch, 1 stays down; 21st 75 / 51st 77 ⇒ storm with /healthz 503` (stub worker from Task 18 driven through `entrypoint.sh`).
- [ ] **Step 2: Run** `HEADLESS_BENCH=1 pnpm --filter budgero-app test headless-bench` — expected: everything red for scenarios whose behaviour is missing; fix in the owning module (Tasks 11–16), **adding the unit test there first**, until all 24 pass. Record wall time in `bench/README.md`.
- [ ] **Step 3: Commit** — `test(headless): milestone 1 bench scenarios`.

---

### Task 22: Fork tag, memory, handoff to M2

- [ ] **Step 1:** `git tag headless-v1.22.1-1 && git push f-liva-fork feat/headless-client --tags`. Rebuild the image with `FORK_TAG=headless-v1.22.1-1` (Task 19 Step 3) and confirm `/healthz`.
- [ ] **Step 2:** Update `~/.claude/projects/-home-fede9-Progetti-ambrogio/memory/budgero_headless_design.md` with what M1 taught (hook names that changed, bench timings, trappole) and add the M2 plan as the next step; Vikunja task for the M2 plan.
- [ ] **Step 3:** Commit the plan's checkboxes in `lzc-budgero`.

---

## Milestones 2–4 (separate plans, written after M1 lands)

- **M2 — writes** (§8–10, §12.2): global write lock + gate, U6 pipeline call with `spec.idempotencyKey = opId`, ledger verdicts on the dequeue observer, send window of 1 + latch in the WS shim, nack handling, per-op argument schemas, wrappers (`/v1/transactions`, `/transfers`, `/months/{m}/…/assigned`, `/months/{m}/move`), write crash points, parity test with the harness `Device` and a seeded `randomUUID` stub.
- **M3 — deploy** (§11, §12.3): NAS upgrade v1.21.5 → v1.22.1 with blob + DB backup, image mirror, manifest service, 7-day read-only observation.
- **M4 — Ambrogio adapter** (in the Ambrogio repo).

---

## Self-review notes

- Spec coverage: §5 constraints are embodied in Tasks 1, 10, 11, 14; §6 U1/U2/U3/U6 → Tasks 3, 2, 4–6, 7 (U4/U5 explicitly not built); §7.1 → 8/9; §7.2 → 8–11, 14; §7.3 → 16; §7.4 → 15 (+12 for step 1–2, 9 for step 4); §7.5 → 14–15; §7.6 → 13, 18; §7.7 → 1, 14, 15; §7.8 → 11, 15; §8 read side only (ledger records, admin drop) → 9, 16; §9 → 17 (schemas in M2); §10 reads/status/admin → 16; §11 image → 19 (manifest M3); §12.1 → 21.
- Deliberately deferred inside M1: the ledger verdict (`base`, `reordered`) and the write gate — the spec places them in §8/M2 and no M1 done-when needs them; the drain rule's `drained: true` marking is also M2 (no live request can exist in M1).
- Type names used across tasks: `HeadlessState`, `StateMachine`, `Mutex`, `OutboxStorage`, `Ledger`, `LedgerRecord`, `Quarantine`, `HeadlessHttp`, `RestoreRules`, `HaltReason`, `EXIT`, `CRASH_POINTS`, `Token`, `HeadlessConfig`, `OP_POLICY` — consistent above.
