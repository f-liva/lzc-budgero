# Budgero headless client — design

Date: 24/11/2026. **APPROVED by Federico on 25/11/2026** (v29). Status: **v29**, after twenty-eight adversarial review rounds (56 reviewers; round 27–28
verdicts: mechanics clean, coherence "ready for a planner"; v29 applies their minors) every critical/important finding verified in code at the pin).
Upstream proposal: https://github.com/tombadilo-bombadilo/budgero/issues/155 (no answer yet).
Pin: upstream tag **v1.22.1 = `e40723e`**. `file:line` references are at that pin, relative to
`packages/` of the Budgero monorepo unless another repo is named.

## 1. Why

Budgero is end-to-end encrypted and local-first: the Go server stores only ciphertext (a
snapshot blob + an append-only mutation log); every client holds the space key, keeps a
decrypted SQLite and applies mutations itself. The only integration surface is the Push
API: write-only, transactions only, applied by a browser when someone opens the app.
Ambrogio works around it by decrypting the blob itself (`ambrogio/src/budgeting/budgero-sync.ts`):
read-only, stale, and it broke on 23/11/2026 when the blob outgrew one LZ4 block.

We want a client that is a peer of the web app, without a UI, exposing a REST API to read
everything and run the operations we allow. First consumer: Ambrogio.

## 2. The model

The headless runs the **web app's own code** (stock `RuntimeCoordinator`, op registry,
`@budgero/core`) in Node, with a few injection points added upstream. Its SQLite lives **in
memory only** and is rebuilt from the server (snapshot + log) at every start. It **never
uploads a snapshot**. A write is a real mutation in the server log, acknowledged to the
caller **only after the server acks it**. Whenever the local DB can no longer be proven to
equal "snapshot + log in server order", the process exits and an in-container supervisor
restarts it, which rebuilds. Durable local state: outbox, ledger and a few small logs (7.1).

Why: the runtime persists DB, cursor, applied ids and outbox in separate steps, and every
scheme to make a *persisted* local DB crash-safe kept leaving windows. Those windows only
matter if the headless *uploads* snapshots, because then a local glitch becomes every
device's data. Removing uploads and treating the DB as a rebuildable cache removes the
class. What remains is the mutation log, fed by the app's own pipeline from guarded args.

**Continuous rules are not run by the headless** (decision 24/11, Claude's call,
correctable: Federico's budget has `transaction_rules` = 0 rows in the 23/11 dump). Rules
follow-ups are separate mutations with random ids and *local row ids* in their args,
issued after the primary is sent, and were the root of every remaining ordering/drop/retry
hazard in rounds 7–14. The U6 pipeline takes `runContinuousRules: false`; **a request is
exactly its own ops**. Rules run only on the originating device (`app-runtime.ts:238, 253,
765`), so a headless add gets no rule applied anywhere, consistently. `/v1/status` reports
`rules_in_budget`; `rules.create`/`rules.update` reject `mode: 'continuous'`.

## 3. Goals, non-goals, anti-goals

Goals: live peer of one space, one budget, one user; REST reads of everything and writes
through an explicit op allowlist; 200 only after the server ack; nothing the headless does
locally reaches another device except through mutations the app's own pipeline produced;
optional second service of the `lzc-budgero` Lazycat package.

Non-goals: UI; SaaS/Clerk auth; master-password change, key rotation, sharing, imports,
bank sync, chat/LLM, continuous rules; public exposure; snapshot uploads; Push-API queue
processing (needs an atomic server-side claim first, U5).

Anti-goals: corrupting the space for other devices; reimplementing op logic; emitting a
mutation format different from the app's at the same tag; creating/uploading/rotating a key;
telling the caller "done" for a write the server never received, or "failed" for one it has;
handing the caller a row id that names a different row on other devices.

## 4. Approaches considered

| | What | Verdict |
|---|---|---|
| **A. Full client in the fork, cache-only** | stock coordinator + registry + core; in-memory DB; never uploads; rebuild on doubt | **Chosen** |
| A′. Same, with a persisted DB and uploads | v2–v5 | Rejected after 5 rounds: every persistence window becomes every device's problem |
| B. Snapshot read + Push API write | package what Ambrogio does as REST | Rejected: writes wait for a browser; transactions only |
| C. Hand-crafted mutations | build payloads ourselves | Rejected: first divergence from `prepareMutationArgs` corrupts the space |

Bypassing the coordinator was rejected: it handles out-of-band blobs, post-restore
migrations and catch-up correctly. Running continuous rules was rejected in v15 (§2).

## 5. Constraints verified in code

- Workspace-private packages, extensionless imports → **esbuild bundle**. Registry imports
  only `@budgero/core/browser`, `@budgero/runtime`, the Lingui macro, `@shared/runtime/global`;
  `withLegacyFormat` emits the **older** format if services are missing (`legacy-format.ts:266-272, 240`).
- `RuntimeCoordinator` builds its own `KeyVault` (`runtime-coordinator.ts:83`), requires the
  master password (`runtime-lifecycle-service.ts:61, 64, 92, 183`), and for an owner without
  a wrapped key **generates and uploads one** (`key-vault.ts:223-233`).
- Activation with no local DB/cursor: snapshot → `createDatabase` →
  `reapplyQueueAfterRestore` (skipped on the 404/fresh path) → connect → catch-up
  (`space-activation-service.ts:272-391`); a download error falls back **silently to an empty
  DB** and reports `local_after_download_failure` (`:109-114, 315-323`); migration failures
  are swallowed (`:351-364`); outcome in `onSpaceActivated` (`:95-123`).
- Mutation id = `spec.mutationId || spec.idempotencyKey || generate()`; a `mutationId` makes a
  receiver that never sends (`mutation-executor.ts:69-71`, `mutation-dispatch-service.ts:55-58`).
  Server dedups by id, keeps the first payload, acks with the existing version
  (`websocket/mutations.go:124-138`); versions are `MAX+1` per mutation (`:142-150`); the log
  is deleted only by `ResetSpace` (`:417-428`), whose callers also delete the space
  (`user_service.go:174-185`, `budget_spaces.go:110-121`) and close sockets with reason
  `space_reset` (`hub.go:20, 604-606`). Broadcasts exclude the sender (`hub.go:212, 565`).
- Dispatch: apply → `offlineQueue.add` (push into memory **before** `storage.save`,
  `offline-queue.ts:67-69`) → send (skipped when offline, `mutation-dispatch-service.ts:87`);
  ack → `onMutationAck(id, msg.version ?? 0)` → `ackMutation` (removes from memory before
  saving, `offline-queue.ts:157-162`) → `updateLocalVersion` (`sync-transport.ts:906-937`).
  Sweep and reconnect replay send **non-durable** entries (`offline-queue.ts:141-147`,
  `reconnection-service.ts:245, 336-352`). Own mutations returning via catch-up are an
  **implicit ack** that bypasses the ack handler (`runtime-lifecycle-service.ts:195-200`).
  The server's ack is best-effort (`hub.go:537-548`).
- `executeMutationOp` has no transaction (`op-code-registry.ts:314-319`).
- Apply catch blocks check `isUpdateRequiredError` first (`sync-transport.ts:1099-1101,
  1219-1224`); `haltForUpdate` calls `onUnknownOpCode` for an unknown op, else
  `onFormatTooNew` (`:1360-1385`; deps under `syncTransportPolicy`,
  `runtime-coordinator-types.ts:85-95`). Catch-up failure twice ⇒ quarantine (`:1226-1244,
  1397-1419`). Key/password change: `onEncryptionKeyChanged`, `setPasswordChangedReason`/
  `reloadApp` (`runtime-context-factory.ts:85-91`); handlers don't stop the transport.
- `downloadAndRestore` (`database-sync.ts:423-449`) does not wait for a running write and
  swallows hook throws; `download()` sets `blobVersion` before any restore (`:389-390`). On
  reconnect upstream downloads only with no recent download **and no local change since**
  (`reconnection-service.ts:194-200`; flag set by every local mutation,
  `runtime-coordinator.ts:353-356`); out-of-band uploads are noticed only while connected
  (`runtime-context-factory.ts:235-243`); in-band peer uploads only advance `blobVersion`
  (`:249`). Nack codes normalised to `invalid|format_too_new|storage_error|internal|other`
  (`sync-transport.ts:86, 981`); server sends `storage_error`/`internal` (transient) and
  `invalid` (`client.go:18-29`); upstream keeps a nacked entry queued and resends it.
- WebSocket: `Origin` must equal `WEBSOCKET_ALLOWED_ORIGINS` (`websocket.go:78-91`; manifest
  sets `https://${LAZYCAT_APP_DOMAIN}`); frames are plaintext JSON with only
  `encryptedPayload` opaque. `getSyncDiagnostics()`: cursor, `catchUpInProgress`,
  `pendingCount` (in-memory queue length), `connected`, `blobVersion`
  (`runtime-coordinator.ts:720-733`).
- Lazycat ignores `services.*.restart` (every lzcapp container has `RestartPolicy=no`);
  `user:` + `setup_script` work (`lzc-postiz/postiz-lzc/lzc-manifest.yml:34-35`);
  `health_check` becomes a Docker healthcheck. `sql.js` is a **devDependency** of `core`
  (`core/package.json:52-62`), not hoisted; `NodeSqlJsAdapter` imports `'sql.js'` and loads
  the wasm from `process.cwd()/node_modules/sql.js/dist` (`node-sqljs-adapter.ts:1, 45-47`).
- `GET /api/v1/version/latest` (unauthenticated) → `build_version`, may be `unknown`.

## 6. Upstream changes (fork `f-liva/budgero`, branch `feat/headless-client`, one commit each)

- **U1 — external space key.** `RuntimeCoordinatorDeps.spaceKeySource?: {spaceId, key}`:
  `KeyVault` returns that key for that space, throws for any other, never unwraps/generates/
  uploads (`uploadEncryptedKey` never passed); no master password; persistence cipher
  disabled at all three sites; `ensureSpaceKeys`/activation target that space only; key
  version from the shim-backed `MasterPasswordStore`.
- **U2 — queue storage + durability fix.** `deps.queueStorage` passed to `new
  OfflineQueue(spaceId, storage)` (`runtime-context-factory.ts:201`); export
  `deserializeMutation`. **Bug fix:** a `persisting` set (id added before `storage.save`,
  removed only on **resolve**); `getSendable()` used by `getStale()`, `getUnsent()` and the
  replay (`reconnection-service.ts:245`); `getQueue()` unfiltered.
- **U3 — hooks** (optional deps on `RuntimeCoordinatorDeps`, except `settledAfterRestore`,
  `receiveIdle` and `halt`, which are runtime API the coordinator exposes; `settledAfterRestore`
  has no timeout, `draining` lasts as long as the reconnect fails; "awaited" = the runtime waits
  for the promise before continuing):

  | Hook | Call site | Awaited | Headless effect |
  |---|---|---|---|
  | `allowUpload(): boolean` | top of `doUpload` (before `db.backup()` + encryption, `database-sync.ts:318-330`); when false `doUpload` returns | sync | always `false` |
  | `onMutationAck(id, version)` | factory handler, `runtime-context-factory.ts:221`, **before** `ackMutation`; version passed through | yes | record version for the ordering verdict |
  | `onMutationNacked(id, code)` | `handleMutationNack`, `sync-transport.ts:979` | no | 8.2 |
  | `onRemoteApplyFailed(mutation, error, path, precedingVersion, willQuarantine)` | both apply catch blocks after the `isUpdateRequiredError` branch (`:1099-1107` live, `:1219-1244` catch-up), before cursor move; on return the **live** path applies the catch-up rule (only when the hook is provided; the web app is unchanged): same `{version, precedingVersion}` already in the map ⇒ quarantine, else record it and run `handleCatchUpUnsafe('apply_failed')` | yes | persist `{key, version, precedingVersion}` to `failures.json` so the first failure survives an exit (8.4) |
  | `onQuarantined(mutation, error)` | `quarantineCatchUpMutation`, `sync-transport.ts:1397-1419`; key = `id || 'version:' + version` as `catchUpFailureKey` (`:1393-1395`) | no | 8.4 (idempotent per key) |
  | `skipMutationKeys(): ReadonlySet<string>` | in **both transport loops before `decodeMutationPayload`** (`sync-transport.ts:1080-1089` live, `:1210-1212` catch-up; a decode/normalise failure throws before `onRemoteMutation` is reached, `:1117-1137`), keyed `catchUpFailureKey(m)` (`:1393-1395`; on the **live** path the frame carries `msg.mutationId`, not `msg.id`, `types/messages.ts:8, 22`, so the key is built from `{id: msg.mutationId, version: msg.version}` and the same normalised pair is passed to every hook); a hit skips and advances the cursor as quarantine does (`:1414`) | sync | keys from `quarantine.json` not `covered` and not `tainted` (8.4); never touched by `resetForRestore` |
  | `onRemoteApplySucceeded(key)` | catch-up success next to the in-memory delete (`sync-transport.ts:1215`) and the live success path | sync | remove the key from `failures.json` |
  | `seedCatchUpFailures(): Map` | transport construction, into `catchUpApplyFailures` (`:194`) | sync | untainted entries of `failures.json`, so a mutation that failed once before an exit is quarantined on its next failure instead of restored again. |
  | `onRestoreCompleted()` | after `onCatchUpUnsafe` returns normally (`runtime-context-factory.ts:251-298`) | sync | clears `applyDirty`; unbound-blob check (7.4.10) ⇒ halt before the cursor is reseeded |
  | `beforeRestore({reason})` | `downloadAndRestore` after `download()` returned non-null, before `db.restore()` (`database-sync.ts:427-433`); `reason` threaded from its callers: `onCatchUpUnsafe` (`runtime-context-factory.ts:251-259`), out-of-band `downloadLatest` (`runtime-coordinator.ts:640-650`) | yes | restore table (7.5.4) |
  | `settledAfterRestore(): Promise<void>` | resolved at catch-up completion (`sync-transport.ts:1486-1489`, not on `catchUpInProgress = false`, which `handleCatchUpUnsafe` also clears at `:1497`) for the connection opened after a restore (`initialCatchUpSettled` is one-shot, `sync-transport.ts:1589-1591`, so a per-connection signal is added) | — | leaves `draining` |
  | `receiveIdle` in `getSyncDiagnostics()` | `receiveTail === null && catchUpMutationBuffer.length === 0`, `sync-transport.ts:179, 475, 488-497` | sync | gate condition |
  | `RuntimeCoordinator.halt(reason)` | new | — | stops sync, reconnection, connectivity, timers; sets the transport's `destroyed` flag (checked first by `handleCatchUpUnsafe`, `:1493`); `upload`/`downloadAndRestore` no-ops behind a halted flag checked before `beforeRestore` |

  Existing deps used as-is: `reconnectionPolicy.recentDownloadWindowMs = Number.MAX_SAFE_INTEGER`
  (`runtime-coordinator-types.ts:80-84`) so upstream never downloads on reconnect by itself
  (`reconnection-service.ts:193-200` would otherwise restore on **every** reconnect in a
  headless with no writes since start); `getSyncDiagnostics().initialCatchUpSettled`
  (`runtime-coordinator.ts:730`) is "initial catch-up has settled"; `onFormatTooNew`,
  `onUnknownOpCode`, `onEncryptionKeyChanged`, `setPasswordChangedReason`/`reloadApp`.
- **U4 — 409 restore = full restore** (upstream only; the headless never uploads).
- **U5 — atomic push claim** (server; not built here).
- **U6 — shared mutation pipeline** with `runContinuousRules` option: `executeMutation`'s
  pure parts (prepare, continuous rules, `recordHistory`, `resolveHistoryBudgetId`) move
  out of `AppRuntime` into a module without analytics/toast imports; the app passes `true`,
  the headless `false`. No app logic is copied into the headless.

## 7. Process and state

### 7.1 Files that survive a restart

`outbox.json`, `ledger.json`, `rebuilds.log` (written **only by the supervisor**), `halts.log`,
`exit-info` (worker → supervisor: `{reason, outbox_size, uptime_s}`), `quarantine.json`,
`failures.json`, `config.json` + secrets. DB and
`localStorage` shim are in memory. Every write of a JSON file: temp → fsync → rename → fsync dir; one promise chain per file,
content snapshotted at call time. `halts.log` and `rebuilds.log` are append-only (`O_APPEND` +
fsync).

### 7.2 Platform pieces (`packages/headless/src/platform`)

- `storage.ts`: in-memory `localStorage` shim, reset at each start.
- `database.ts`: `NodeSqlJsAdapter` with a **no-op `forceSave`** (so `persistDatabase` returns
  true: without it `onCatchUpUnsafe` throws "Failed to persist local database after catch-up
  recovery", `runtime-context-factory.ts:293-296`, and for a legacy blob with no bound the
  cursor would never be reseeded, `sync-transport.ts:1516-1551`); what it "persists" goes to
  the in-memory shim only. Failure logs redacted.
- `queue-storage.ts`: `QueueStorage` over `outbox.json`. The wrapper **observes** the queue
  it is handed on every save: ids that appear → ledger `queued` (full entry stored); ids that
  disappear → **dequeue**. A dequeue is an ack unless the wrapper itself caused it (admin
  drop). `ackMutation` is the only upstream dequeue path here; the wrapper halts
  (`queue_cleared`) if `clear()` is called. **The ordering verdict (7.5.5) is taken on the
  dequeue observation**, using the version recorded by `onMutationAck` for that id, or
  "none" if the id left the queue without one (implicit ack). The verdict applies to **every
  op whose ledger record has a `base`**, whether or not its HTTP request has already
  answered (a 202'd op acked after a reconnect is checked too); ops being drained at startup
  (op marked `drained`) are plain acks (`result: null` + `entry`).
- `ledger.ts`: `ledger.json` (8.3).
- `http.ts`: `blobApi` **download side only** (`downloadBlob`, null only on 404;
  `getDatabaseState`), `spacesApi`, `getProfile`, `checkApiHealth` (`HEAD /health`), login,
  version. No upload function; the coordinator's required `uploadBlob` is a throwing stub
  (never reached: `allowUpload` is false). Classifies every failure as **transport**
  (connection refused, timeout, 5xx, integrity check after a 200) vs **server** (a 4xx other
  than 401/404, with a body) before the runtime swallows it; "no tag recorded" counts as
  transport. Base URL also for core's relative FX path. Contract test vs `api-client.ts`.
- `websocket.ts`: `globalThis.WebSocket` shim (`ws`) with `Origin: $BUDGERO_ORIGIN`;
  `getWebSocketUrl` (`token`, `space_id`, `protocol=SYNC_PROTOCOL_VERSION`, `client_session`).
  Detects an HTTP 426 on the upgrade ⇒ halt `protocol_426`; a 404 upgrade or a close with
  reason `space_reset` ⇒ halt `space_reset`; a close with reason `member_removed`/`blocked`
  (`hub.go:21-25`) ⇒ halt `access_denied`; a 403 upgrade ⇒ halt `ws_forbidden` (Origin mismatch
  or access revoked); a 401 upgrade (`websocket.go:158-161`) ⇒ token refresh, then
  `auth_failed` if it repeats. **On every (re)connect** it runs the **blob
  check**: `getDatabaseState().version` vs `getSyncDiagnostics().blobVersion`; server newer ⇒
  `draining` + exit 77 (upstream would skip the download after a local write); check failed
  ⇒ gate closed, retry. An `out_of_band` `sync_state_changed` frame with a newer version
  flips to `draining` at once. **Outbound rules:** `catch_up_request` always; `mutation`
  frames only when `readOnly` is false and only with a **send window of 1 in queue order**
  (a frame is released when every entry ahead of it has been dequeued; implicit acks
  count); held frames deduplicated by id (the sweep re-sends held entries) and discarded on
  socket close; after a `reordered` verdict a process-wide **latch** releases no `mutation`
  frame until exit. Key/password frames never.
- `global.ts`: full `services()`, `mutationsRouter()`, `mutationHistory` id-reuse API;
  startup fails if any is missing. `lingui.ts`: stub for `@lingui/core/macro`.
- Logging: JSON lines on stdout `{ts, level, msg, state, mutationId?}` through a redactor.

### 7.3 States and routes

`not_configured` · `bootstrapping` · `draining` · `live` · `outbox_blocked` · `halted` ·
`shutting_down`.

| Route | not_configured | bootstrapping | draining | live | outbox_blocked | halted | shutting_down |
|---|---|---|---|---|---|---|---|
| `GET /healthz` (no auth) | 200 | 200 | 200 | 200 | 503 | 503 | 503 |
| `GET /v1/status` | 200 (no auth) | 200 | 200 | 200 | 200 | 200 | 200 |
| `GET /v1/mutations/{id}` | 404 | 200 | 200 | 200 | 200 | 200 | 200 |
| reads | 503 | 503 until the activation report is accepted, then 200 + `stale: true` | 503 | 200 | 503 | 503 | 503 |
| writes needing execution | 503 | 503 | 503 | gate (8.1) | 503 | 503 | 503 |
| writes answered from the ledger record | — | yes | yes | yes | yes¹ | yes | yes |
| `POST /v1/admin/quarantine/{key}/ack` | 404 | 200 | 200 | 200 | 200 | 200 | 503 |
| `POST /v1/admin/quarantine/{key}/retry` | 404 | 409 | 409 | 200 | 409 | 409 | 503 |
| `POST /v1/admin/outbox/{id}/drop` | 404 | 409 | 409 | 409 | 200 | 409 | 503 |

¹ `acked`/`dropped`/`failed`/`skipped` records answer normally; `queued`/`nacked`/`intent` ⇒
202 `blocked`; `unknown` ⇒ 202 `unknown`.

After an exit the supervisor serves `/healthz` (503) and `/v1/status` (`{state:"halted",
reason}`, no bearer) only, except on 143 where it exits too.

### 7.4 Startup (ordered) and shutdown

1. CLI: `--config-dir` (default `/lzcapp/var/headless`), `--bench`, `--crash-at`. Missing
   `config.json` ⇒ `not_configured`. Invalid config (`url` http(s), `user`/`spaceId` strings,
   integer `budgetId`, `port` 1–65535, booleans) or a secret missing / unreadable / not mode
   600 / not owned by the worker uid ⇒ `reason=config:<field>`, exit **1**. Operator
   procedure: `lzc-docker exec` as root, write the files, `chown 1001`, `chmod 600`.
2. `tokens` (`name:role:token`, roles `read|write|admin`; `read` → GET routes; `write` → +
   writes; `admin` → + `/v1/admin/*`; mismatch ⇒ **403 `role`**).
3. Read `rebuilds.log` (429 window, `last_exit`; budgets are the supervisor's).
4. Ledger reconciliation: `queued` ops missing from `outbox.json` are appended (same entry);
   `dropped` ids present are removed; `acked` ids present are removed; `unknown` ops become
   `queued` if present, `failed` otherwise (and later ops of that record `skipped`).
   `quarantine.json` keys (not `tainted`; `covered` is decided at step 10) are served to upstream through
   `skipMutationKeys()` (U3); `failures.json` (not `tainted`) seeds `catchUpApplyFailures`.
   **Tainted** = recorded while the outbox was non-empty (8.4); if the outbox is empty **after**
   this reconciliation, tainted entries are dropped.
5. Nacked check: a ledger `nacked` op still in `outbox.json` ⇒ `outbox_blocked` with
   `reason: nack_blocked` (not a `halts.log` entry), **no activation**; admin routes served
   (read-only mode included).
6. Read-only check: `readOnly` and non-empty outbox ⇒ `reason=outbox_in_readonly`, exit 1
   (set `readOnly: false` to drain it).
7. Version check: transport error ⇒ retry with backoff in `bootstrapping`; mismatch or
   `unknown` ⇒ halt `version_mismatch`.
8. Login: transport error ⇒ retry; 401 ⇒ halt `auth_failed`. Token refreshed on any later
   401 and before expiry (`SELF_HOST_JWT_TTL_HOURS`, 720 on the NAS); a 401 on re-login ⇒
   halt `auth_failed`.
9. Activate (7.5). A **transport** download failure ⇒ `halt()` first (catch-up from cursor 0
   is already running on the empty fallback DB, `space-activation-service.ts:385-391`), then
   exit **78** (`retry_bootstrap`) — the supervisor relaunches with exponential backoff (5 s →
   5 min) and serves `/healthz` 503 meanwhile; after **20 consecutive 78** it stays down with
   `bootstrap_retries_exhausted` (7.6). A **server** failure ⇒
   halt `bootstrap_failed:download` at once.

10. In `onSpaceActivated` with `ok` and path `server_snapshot` **or `fresh`** (on `fresh` `bound`
    is undefined: nothing covered, nothing pruned), **synchronously** (before
    yielding; `connect()` returns before `onopen`, `sync-transport.ts:370-470`, so no catch-up
    page can overwrite the key first): read `bound` as recorded by `http.ts` from the accepted blob response, recompute `covered` for
    every quarantine entry (8.4), prune `failures.json` entries with `version ≤ bound`, then
    open the quarantine part of the 8.1 gate (reads open on the accepted report). **A 200 blob
    with no `X-Mutation-Version` header ⇒ halt `bootstrap_failed:unbound_blob`** (upstream
    seeds the cursor at the server head, `space-activation-service.ts:291`,
    `runtime-context-factory.ts:271, 283-290`, so the whole log since that blob would be
    skipped at every rebuild; the web app survives it because it rarely restores, the
    headless rebuilds constantly). Same check in `onRestoreCompleted()`. Exception: no header and the last `getDatabaseState` body `http.ts` recorded (upstream fetches
    it before the download, `space-activation-service.ts:160`, and after a restore,
    `runtime-context-factory.ts:274`) has `mutation_version === 0` ⇒ bound 0, nothing skipped,
    continue; a body **missing** the field (`GetLatestVersion` failed, `sync.go:450-480`) is a
    transport failure (exit 78 at activation, exit 77 on the restore path), not a halt. Remedy: one write from the web app uploads a bound snapshot, then
    restart the container. Until then
    every entry counts as uncovered: step 4 loads entries with `covered` forced to false and
    `skipMutationKeys()` reads live state.

`exit-info` is written on **every** worker-initiated exit (1 included) and cleared first thing
at step 1, so the supervisor never serves a stale reason.

Shutdown on `TERM`/`INT`: `shutting_down`, wait for the apply-phase lock, `halt()`, wait for
the file chains, exit **143**.

### 7.5 Bootstrap invariant

**`live` only with DB = snapshot + log in server order, own ops at their server position.**

1. Activation uses `hasLocalDatabase: async () => false` and a fresh shim.
2. `onSpaceActivated` must report `ok === true` and path `server_snapshot` (`fresh` only when
   the blob answered 404). Decrypt error or swallowed migration failure (detected by wrapping
   the loader) ⇒ halt `bootstrap_failed:<decrypt|migrations>`. `bootstrapping` until
   `initialCatchUpSettled`.
3. Outbox non-empty at start ⇒ reapplied entries ran before catch-up (or, on the fresh path,
   were never reapplied) ⇒ `draining`: wait until the **drain ends**, then rebuild (exit
   75). Only the second bootstrap goes `live`.
4. **Restores.** `beforeRestore` flips to `draining` synchronously, waits for the
   **apply-phase lock** only (never for acks or the outbox: the catch-up-unsafe restore runs
   inside the transport's serialised receive chain, `runtime-context-factory.ts:251-259`,
   `sync-transport.ts:478-487, 1492-1510`, and the acks sit behind it), records
   `queuedAtRestore = getQueue().length` and `priorState`, then lets the restore proceed.
   Every restore reapplies the outbox before catch-up (`database-sync.ts:436-446`,
   `restore-invariant.ts:45-66`), so the DB is in server order afterwards **only if the
   queue was empty**. One table:

   | Trigger | Detected by | After the restore | Counted |
   |---|---|---|---|
   | blob check on reconnect (7.2) | WS shim; upstream downloads nothing | no restore: `draining` → exit **77** when the lock is free; leftovers drain next start | `rebuilds.log` 77, budget 50/24 h → `restore_storm` |
   | out-of-band `sync_state_changed` frame | WS shim (`draining` at once) + `beforeRestore({reason:'out_of_band'})` | exit **77** when the lock is free | same |
   | remote apply failure that upstream will **restore** (first failure) | `onRemoteApplyFailed` opens a **failure episode** (below) | in-process restore as the row **below**; if the restore never completes (download threw, `database-sync.ts:346-375`; `db.restore` threw — upstream only logs and reconnects, `sync-transport.ts:1537-1586`; a socket close during a restore that would have succeeded also exits 77, deliberately) the episode is still open at the next `onopen` or socket close ⇒ exit **77** | `halts.log` `restore_inproc`; `rebuilds.log` 77 only if unfinished |
   | catch-up-unsafe fallback (`apply_failed`, gap, bad page) | `beforeRestore({reason:'catchup_unsafe'})` | **completes in-process** (upstream quarantines a mutation only on its **second** failure at the same `precedingVersion`, `sync-transport.ts:194, 1231-1244`; exiting on the first would loop). `draining` until `settledAfterRestore()`; then **exit 77 iff `queuedAtRestore > 0`** (the reapplied outbox put the DB out of order), else back to `priorState` (`live`, `bootstrapping` or the startup `draining`): a restore with an empty queue is snapshot + log in server order whatever the state; a `beforeRestore` with no `reason` (other callers, `database-sync.ts:259`, `runtime-coordinator.ts:701`, unreachable here) follows the out-of-band row | `halts.log` `restore_inproc`; `/v1/status.restores_inproc_24h`; > 50 in 24 h (from `halts.log`, survives restarts) ⇒ halt `restore_loop`; recovery failure (`syncDisabled`, `SnapshotUnavailableError`, `:1538-1550`, observed through the sync-status listener as `syncError.code === 'snapshot_unavailable'`, `:642-650`) ⇒ halt `restore_failed` |

   **Failure episode** (one rule set for `onRemoteApplyFailed`, both paths; U3 passes
   `willQuarantine`, computed by upstream's own `previousFailure` match, so the headless never
   re-derives it): persist the failure (`tainted` = the outbox was non-empty at the moment of recording; the
   single definition used everywhere; recomputed on upsert). If
   `willQuarantine`, upstream will **quarantine** (no restore): do nothing more here;
   `onQuarantined` then, for an **untainted** entry, flips to `draining` synchronously and exits
   **77** after the apply-phase lock (the DB holds the failed apply's partial writes; the next
   start skips the key before decode, so no loop; counted in the 77 budget) and, for a
   tainted one, does nothing (the 77 after `settledAfterRestore` rebuilds anyway). Otherwise upstream will
   **restore**: open the episode `{priorState: the state at this first transition,
   applyDirty: true}` and flip to `draining`; `beforeRestore` records `queuedAtRestore` (the larger
   value if an episode is already open) and **never overwrites an open episode's `priorState`**;
   a failure while an episode is open keeps the first `priorState`; the startup drain is a
   separate `startupDrain` flag, not a value of `state`, so "return to the startup `draining`"
   is unambiguous; a **successful** restore (U3 `onRestoreCompleted()`, called where
   `onCatchUpUnsafe` returns normally, `runtime-context-factory.ts:251-296`) clears
   `applyDirty`; after `settledAfterRestore()` exit 77 iff `queuedAtRestore > 0`, else back to
   `episode.priorState`. `applyDirty` still set at the next `onopen` or at socket close ⇒
   exit 77. **Once any exit (75/76/77) is scheduled it is irrevocable**: no rule leaves `draining`, and
   `settledAfterRestore` and the episode return are ignored. Precedence: `halt` > 75 > 76 > 77 (78 and 1 never coincide with a write or an episode).
   `halt()` clears the flag and always wins (a terminal halt is never turned into a 77). A failure recorded while
   `queuedAtRestore > 0` is `tainted` (8.4) and is judged again by the next clean start.
   Restores during `bootstrapping` or the startup drain follow the same row (exit 77 only when
   `queuedAtRestore > 0`). On return to the startup `draining`, drain-end is re-checked
   (`getQueue().length === 0` ⇒ exit 75 at once). A drain-end 75 and a scheduled 77 are resolved by precedence (75 wins).
5. **Live ordering check, per request.** Gate (8.1) read under the apply-phase lock:
   `base = max(cursor, highest version among own acks)` (the ack handler calls
   `onMutationAck` before `updateLocalVersion`, so the cursor can lag one own ack). The
   request issues k ops (writes are serialised: every new outbox id during the request is
   its own). Each op must be acked with version exactly `base+i` (i = position among the ops issued by
   this execution), in send order. A gap, a
   version 0, or a **dequeue without a recorded version** (implicit ack after a lost ack
   frame, seen only by the queue-storage observer) ⇒ `reordered`: a peer mutation was
   ordered between ours; locally ours ran first, so autoincrement row ids and absolute
   totals now differ from every other device (the web app has the identical race,
   `reconnection-service.ts:261`). On the verdict, **synchronously**: `reordered` persisted on the
   ledger record, every create's `result` replaced by `null` + `requery: true` (its row id
   names another row elsewhere), the WS latch closed, state `draining`. Remaining ops of
   the request stay queued and drain at the next start (their args carry no locally derived
   values: `updateColumn` passes args through, a create is always the single op of its
   request; if a peer deleted the target row they are skipped on other devices). Rebuild
   (exit 75) after the apply-phase lock and the in-flight HTTP response (8.1 step 5).
6. Throws, by phase and index. In the same ledger write op i becomes `failed` and ops
   i+1..k become `skipped` (a retry never executes them). **i = 1** ⇒ **422** (nothing
   landed). **i > 1** ⇒ **200 `partial: true`** once ops 1..i-1 have dequeued, else 202 `pending`
   with per-op states (ops 1..i-1 are already sent). A throw in `prepareMutationArgs` needs no rebuild (nothing applied). A throw in
   apply leaves partial writes in memory (op i never reached `outbox.add`): state
   `draining` **synchronously** (reads 503, no new write passes the gate, the global write
   lock is kept until exit), sync stays alive until ops 1..i-1 have dequeued or 30 s passed,
   the response goes out, then rebuild (exit **76**). In `outbox.add` of op i ⇒ ledger
   `unknown`, **202 `unknown`**, halt `outbox_write_failed`.

**Drain rule** (startup drain, 7.5.3): a drain ends when the outbox is empty; ops present in
`outbox.json` at startup step 4 are marked `drained: true` **per op** so their dequeues take
no verdict (writes are 503 during a drain, so no live request exists); an op of the same
record re-executed later goes through the gate and is checked normally.
**Remote apply failures** are never decided by the headless (error classes are not
reliable: plain `Error` throws, `ValidationError` from a failed FX fetch,
`core/.../transactions/index.ts:1208-1216`). On any path the mutation is retried after an
in-process restore and, if it fails again, **quarantined by upstream exactly as on every
other device** (`sync-transport.ts:1226-1244, 1397-1419`). The headless persists it (8.4) and
serves its key to upstream through `skipMutationKeys()` (U3), so it is skipped at every start
and after every restore; it never touches the applied-id set. Writes are blocked until the
operator rules on each entry (ack, or retry after a code fix): a failure that happens only on
the headless would otherwise be quarantined here alone and diverge silently.
### 7.6 Locks, rebuild, supervisor, exit codes

**Apply-phase lock**: taken by a write before the gate, released in a `finally` when the
`executeMutation` chain has returned (or thrown) for every op of the request, which happens
after the send loop or after the offline-queue path; it never waits for an ack. Every exit
path (75, 76, 77, 78, 143) and `beforeRestore` wait for it.

**Rebuild**: wait for the apply-phase lock → (76 only: wait for dequeues of landed ops, 30
s) → **answer any request still in step 5 at once** (200 `reordered` if a verdict landed; on a 76, 200
`partial` only when ops 1..i-1 have dequeued; on 77 or a drop, and otherwise, 202 `pending`
with per-op states incl. `failed`/`skipped`; never 200 for an op the server has not acked; a
`reordered` verdict landing during a 76 wait ⇒ 75 wins) → `halt()` → wait for **all** file chains (outbox, ledger, quarantine, failures, halts) → write
`exit-info {reason, outbox_size, uptime_s}` → `process.exit(<code>)`. The global write lock is held
from the triggering request until exit. In-process re-activation is not used (re-activating
the same space keeps the old transport alive, `runtime-lifecycle-service.ts:176-179`).

**Supervisor** (`entrypoint.sh`, child of Lazycat's `lzcinit` because `setup_script` is
used): relaunches on 75/76/77/78 (78 with exponential backoff 5 s → 5 min, `--backoff-ms` override
for the bench; "consecutive" = no child with `uptime_s ≥ 600` in between; 20 consecutive ⇒
stays down `bootstrap_retries_exhausted`), stays down otherwise, traps `TERM`/`INT` and forwards them
(`trap 'kill -TERM "$child"; wait "$child"; exit 143' TERM INT`), is the **only writer** of
`rebuilds.log` (`{ts, code, reason, outbox_size}` for every child exit, reading `exit-info`),
enforces budgets, and after a storm or a non-rebuild exit serves `/healthz` 503 and
`/v1/status` via busybox httpd CGI. Operator clears a storm by **renaming**
`rebuilds.log` (kept as evidence) and restarting the container.

| Trigger | Exit | 24 h budget | 429 window |
|---|---|---|---|
| `reordered` (latch) | 75 | 20 → `rebuild_storm` (shared with drains and admin drops) | no |
| drain ended with the outbox empty | 75 | shared; not counted when the previous record has code 75/76/77 with `outbox_size > 0` (a reordered write costs one unit, not two) | no |
| admin drop | 75 | shared | no |
| blob check / out-of-band restore / in-process restore with `queuedAtRestore > 0` / untainted quarantine / unfinished episode at `onopen`/close / admin quarantine `retry` | 77 | 50 → `restore_storm` | no |
| transport failure during bootstrap download | 78 | not counted, backoff | no |
| apply throw (422 / `partial`) | 76 | not counted | 5 per 10 min ⇒ writes 429 |
| config error, `outbox_in_readonly`, uncaught exception | 1 | stays down | — |
| `TERM`/`INT`, SIGKILL | 143 / 137 | stays down (143: the supervisor exits too) | — |

### 7.7 Halting

Reasons: `version_mismatch` (also for a `format_too_new` nack: the entry is kept, the bundle is older than the server), `auth_failed`, `nack_blocked` (state `outbox_blocked`, no `halts.log` entry), `protocol_426`, `space_reset`, `ws_forbidden`, `format_too_new`
(`onFormatTooNew`), `unknown_op` (`onUnknownOpCode`), `key_changed` (`onEncryptionKeyChanged`), `password_changed`
(`setPasswordChangedReason`/`reloadApp`), `bootstrap_failed:<download|decrypt|migrations|unbound_blob>`,
`outbox_write_failed`, `queue_cleared`, `access_denied`, `restore_loop`, `restore_failed`.
Storms (`rebuild_storm`,
`restore_storm`) are detected and served by the supervisor alone, never by the worker. Action:
`coordinator.halt(reason)`, routes per 7.3, `halts.log` appended. Never auto-reload, never
re-key, never leave `halted` except by operator restart; the halted check precedes
`beforeRestore`.

### 7.8 Read-only

`readOnly: true`: no write routes (admin routes stay), the WS shim refuses `mutation`
frames, `allowUpload` false and `uploadBlob` the throwing stub (both also in write mode).
Step 6 refuses a non-empty outbox. A test sends every frame type and expects a throw for all
but `catch_up_request`.

## 8. Writes

### 8.1 Flow per request

1. Take the global write lock. Look the `Idempotency-Key` up. If the record answers by
   itself (8.3) → answer, releasing the lock while waiting on queued ops.
2. Take the apply-phase lock. **Gate**, evaluated under it: state `live`, `catchUpInProgress
   === false`, `pendingCount === 0`, `connected === true`, `receiveIdle === true`, blob check
   passed for the current connection, no untainted quarantine entry that is neither acked nor covered (else 503
   `quarantine_pending`); else 503 (`pending` when `pendingCount > 0`). 429 if the caller-rebuild window
   is exceeded. Read `base` here.
3. Policy + argument schema (9). Ledger record `intent` for **all k ops** up front, with a
   fresh random nonce, `bodyHash`, `base`.
4. For each op: `execute` via the U6 pipeline with `spec.idempotencyKey = opId` (never
   `mutationId`). Inside `outbox.add` the wrapper writes ledger `queued` with the full queue
   entry (`id, op, args, v, timestamp, baseVersion, spaceId`) **before** the outbox rename.
   The apply-phase lock is released in a `finally` when the chain has returned for every op.
   The global write lock is released after step 5 answers (or, on a rebuild, never).
5. Wait for the dequeue of every op (30 s). All dequeued and no `reordered` ⇒ ledger `acked`
   + results + versions ⇒ **200** (`partial` when an op failed). `reordered` ⇒ **200
   `reordered: true`** as soon as the verdict lands, with per-op states (`acked` with
   version, or `queued` for ops behind the latch) and `result: null, requery: true` for
   creates; the response is flushed before the rebuild exits. Timeout ⇒ **202
   `{status:"pending", mutationIds}`**; the observer completes the ledger later.

The ledger `acked` write happens inside the `QueueStorage.save` that removes the id, before
that save resolves. `queued` precedes the outbox rename, so a crash between them leaves
`queued` without an entry, which startup step 4 puts back.

### 8.2 Nack

`storage_error`/`internal` ⇒ ledger stays `queued`, `/v1/status.last_nack`, 202 after the
timeout; upstream resends. `format_too_new` ⇒ halt `version_mismatch` (entry kept, ledger stays `queued`). `invalid`, `other` ⇒ ledger `nacked`, state
`outbox_blocked`, `outbox_divergent: true`. **No nack is ever answered with 409 while the
entry is on disk** (upstream resends forever and the op can still land). An empty-id `invalid` nack (unparseable frame, `client.go:149`) is pinned on the single
outstanding `mutation` frame (send window of 1) and treated as a blocking nack; with no
`mutation` frame outstanding it is `last_nack` only; an empty-id
transient nack ⇒ `last_nack` only. Any **blocking** nack (`invalid`, `other`) while
running: `halt()` (stops the resend sweep, so nothing is on the wire), state
`outbox_blocked` in-process with `reason: nack_blocked`, routes per 7.3. Operator: `POST /v1/admin/outbox/{id}/drop`
(role `admin`) is accepted **only in `outbox_blocked` and only on a record with a `nacked`
op** (409 otherwise: anywhere else a `queued` op may already be on the wire; in
`outbox_blocked` the send window of 1 guarantees nothing behind the nacked op was sent); it
is **request-scoped**: take the **apply-phase lock** (an op of the same request may still be
mid-apply and its `outbox.add` would rewrite the dropped id back into `outbox.json`,
`offline-queue.ts:63-69`), re-read the record, make the queue-storage wrapper **reject every
`save`** until exit, wait for the file chains → mark `dropped` every op of the same ledger record
still in `outbox.json` in one ledger write → remove them from `outbox.json` (the wrapper
records this disappearance as a drop, not an ack) → exit 75. After a drop the key answers
**409**.

### 8.3 Ledger

`ledger.json`, record per `Idempotency-Key`: `{key, bodyHash, nonce, base, reordered,
partial, generated: {transferId?}, ops: [{opId, state, drained?, entry?, result?,
version?}]}`,
`state ∈ intent|queued|acked|nacked|failed|skipped|dropped|unknown`. `opId = 'hdl_' +
sha256(nonce + '#' + i)` (never from the key alone: a reused key after expiry would collide
with an id the server already has and be acked as a no-op). `bodyHash` = sha256 of method +
path + canonical JSON of the parsed body (sorted keys, no whitespace). Retention 30 days, **only** for records whose ops are all terminal
(`acked|failed|skipped|dropped`) and none of whose ids is in `outbox.json`.

Rules (a request's ops are all its own; evaluated **in this order**: `dropped` → `unknown` →
`nacked` → mixed/acked):
- no record ⇒ proceed; different `bodyHash` ⇒ **422** `key_reuse`;
- all `acked` ⇒ 200 with stored results and the stored `reordered`/`partial` flags
  (`result: null` + `entry` for ops acked by a drain; `result: null, requery: true` for
  creates of a reordered request);
- mixed states: `queued` ops wait for their dequeue (202 after 30 s); `intent` ops are
  re-executed with the same opId through the gate (the ledger `queued` write precedes the
  outbox write and the U2 `persisting` set keeps non-durable entries unsent, so the server
  has nothing under that id; `prepare` runs again, which is correct; the record's `base` is
  refreshed) — but **never when any op of the record is not `acked`** (`failed`, `skipped`, `dropped`,
  `nacked`, `unknown`); `failed`/`skipped`
  ops stay so ⇒ 200 `partial`; op 1 `failed` ⇒ 422;
- any `unknown` ⇒ 202 `unknown` until startup resolves it;
- any `nacked` ⇒ 202 `blocked` (from the record);
  any `dropped` ⇒ **409** with per-op states in the body.

`GET /v1/mutations/{id}`: `intent|queued → pending`, the rest 1:1, plus `version` and the
record's `reordered`.

### 8.4 Quarantine

`onQuarantined(mutation, error)` ⇒ upsert `{key, id, version, op, error: {name, message}, at,
acked: false, covered: false, tainted}` in `quarantine.json` (idempotent per key: an existing entry
keeps `acked` and resets `covered`), `halts.log` `quarantine`, `/v1/status.quarantined` (incl. `tainted`). **Writes answer 503
`quarantine_pending` while any untainted entry is neither acked nor covered** (reads stay 200; a retry
answered from the ledger record still answers). Keys follow `catchUpFailureKey`
(`sync-transport.ts:1393-1395`): `id`, or `version:N` for an id-less mutation; the hook
receives both id and version (U3 passes `m.version`), so either form is matched.

A quarantine is **not forever**:
- **covered**: recomputed at **every** start as `version ≤ bound`, where `bound` is `readSnapshotVersions(headers).mutationVersion`
  of the blob response `http.ts` returned last before `downloadSnapshot` succeeded (hash
  retries can produce several, `snapshot-download.ts:65-88`); so `http.ts` records whether the blob response
  carried an **`X-Mutation-Version` header** (`snapshot-download.ts:41-47`, sent only when the
  server has a bound, `handler/sync.go:126-128`; `0` is valid; `readSnapshotVersions` decides presence, not `headers.has`); an absent header ⇒ halt `bootstrap_failed:unbound_blob` (7.4.10); `bound` is undefined only on
  `fresh`. Unbound blobs come from rows with `mutation_version = 0` never re-published since
  migration 00021, or a history restore published at 0 with origin `restore`
  (`domain/space.go:47-52`, `blob_history.go:426`); a current client's upload is always bound. A covered entry leaves `skipMutationKeys()` and the gate: catch-up starts after
  `bound`, so the mutation is never replayed, and whatever the snapshot holds came from a peer.
  It can go back to false (a history restore may publish an older bound, `blob_history.go:360-363,
  426`), and `onQuarantined` on an existing key resets `covered` to false;
- **ack** (`POST /v1/admin/quarantine/{key}/ack`, role `admin`): the operator, reading `op`
  and `error`, accepts that the same mutation is quarantined on the phone too (Budgero's own
  semantics);
- **retry** (`POST /v1/admin/quarantine/{key}/retry`): after a code fix or a transient cause
  (e.g. an FX fetch that failed during apply, `core/.../transactions/index.ts:1208-1216`):
  removes the entry and exits 77; the next start replays the mutation, and a second failure
  quarantines it again.

**Tainted entries.** While reapplied outbox entries precede catch-up (startup outbox non-empty,
or `queuedAtRestore > 0`), our own ops run locally before peer mutations the server ordered
earlier, so a peer mutation can fail **here only** (e.g. a peer `updateColumn` on a row our
queued delete already removed, `core/.../transactions/index.ts:958-962`) and be quarantined
in-process (the ack that would end the drain sits behind the restore in the receive chain,
`sync-transport.ts:455-463, 475-497`). Failures and quarantines recorded while the outbox is non-empty (the 7.5.4 definition) are
marked `tainted: true`, never served to `skipMutationKeys()`, never block writes beyond the drain,
and are **dropped at step 4 of the next start whose outbox is empty**: the clean bootstrap
judges the mutation again (a genuine failure fails twice and is quarantined untainted).

`failures.json` lifecycle: an entry is removed when its key applies (U3
`onRemoteApplySucceeded(key)` next to the in-memory delete, `sync-transport.ts:1214-1215`) or is
quarantined, and pruned at step 10 for `version ≤ bound`; the file is in the exit wait list.

## 9. Op policy (Federico, 24/11: allowlist + key for destructive)

`api/op-policy.ts` lists exact registry names at the pin in three tiers; unlisted ⇒ 403
`policy`. A test fails if a listed name is not in `KNOWN_OP_CODES` and prints registry ops in
no tier.

- **allowed:** `transactions.add` (with/without `splits`), `transactions.addTransfer`,
  `transactions.updateColumn` (columns `outflowconverted`, `inflowconverted`, `categoryid`,
  `memo`, `date`, `payee`; not `cleared`), `transactions.delete`, `transactions.setCleared`
  (exactly one id), `transactions.saveSplits`; `monthlyBudgets.upsertAssignment`;
  `categories.create`, `categories.updateName`, `categoryGroups.create`,
  `categoryGroups.update`, `categories.moveToNewGroup`; `accounts.create`, `accounts.update`
  (guarded), `accounts.setArchived`; `payees.add`, `recurring.create`, `recurring.update`.
- **destructive** (`allowDestructive: true`): `budgets.delete`, `accounts.delete`,
  `transactions.deleteBatch`, `transactions.batchEdit`, `transactions.reassign`,
  `transactions.reconcile`, `transactions.deleteByRef`, `payees.rename` (merges),
  `payees.deleteMany`, `payees.removeUnused`, `categories.deleteAndReassign`,
  `categoryGroups.delete`, `categoryGroups.deleteAndReassign`,
  `monthlyBudgets.batchUpsertAssignments` (generic), `rules.create`, `rules.update` (nested
  ids applied with no budget check, `core/src/services/rules/index.ts:1657-1700`; `mode: 'continuous'`
  rejected), `rules.execute` (non-empty `options.transactionIds`, max 500).
- **closed:** `history.*`, `transactions.import`, `importHistory.*`, `bankSync.*`, `chat.*`,
  `llmSettings.*`, reorder ops, `transactions.moveToNewCategory/moveToNewAccount`, transfer
  edit/delete ops, `monthlyBudgets.updateAssignment`, `monthlyBudgets.reassignAssignment`
  (merges a category's whole assignment history), everything unlisted. Ops issued by an
  endpoint (`batchUpsertAssignments` from `/move`) bypass the tier: the endpoint is the guard.

**Per-op argument schema** (closed accepted-key set per op from its `execute`/`prepare` at
the pin; unknown keys ⇒ 422; a hand-written per-op list of the keys the op reads, checked against the schema, plus the
parity test):
- always rejected: `mutationId`, `meta`, `idempotencyKey`, `opClock` (backdates the op on
  every device), `exchangeRateOverride`, `fromPush`, `mirror`/`Mirror`, `importIdentities`,
  `currencyRates`;
- create ops reject a caller `id` (`transactions.add`, `categories.create`,
  `categoryGroups.create`, `accounts.create`, `recurring.create`'s `input.id`, `addTransfer`'s
  `source.id`/`destination.id`); `transactions.add` rejects a non-empty `transferId`;
  `addTransfer`'s `transferId` is generated and stored in `generated`;
- `transactions.add`: `budgetId, accountId, categoryId, date, time, inflow, outflow, memo,
  payee, labelId, cleared, splits[]{categoryId, transferAccountId, memo, payee, inflow,
  outflow, receivedAmount}`; `saveSplits`: `transactionId, amount{inflow, outflow, currency},
  splits[]{category_id, transfer_account_id, memo, payee, inflow, outflow}`
  (`transactions.ts:1327-1340`; `exactAmount`, `pair_id`, `PairID`, `inflow_original`,
  `outflow_original`, `order_index`, PascalCase ids rejected, `shared.ts:129-141`); `updateColumn`: `{id, columnName, newValue}`,
  `columnName` normalised like core, integer `newValue` on id columns; `payees.add`:
  `{budgetId, name}`; `recurring.create`: `{input}`; `recurring.update`: `{id, patch}`;
- **every** id reference validated against `budgetId`, targets included (`id`/`ids`,
  `transactionId`, `parentId`, `categoryId`, `newGroupId`, `accountId`, `labelId`,
  `source.accountId`/`destination.accountId`, `toAccountId`, split ids, recurring `input.*`/
  `patch.*` ids, `updateColumn`'s `newValue` on id columns); `budgetId` forced where the op
  carries one, nested paths included;
- `accounts.update`: **`name` only**; `type` and `currency` sent as `''` (core keeps the
  current value, `accounts/index.ts:447-449`); `metadata`, `onBudget`, `linked_category_id`,
  `cc_payment_category_id`, `debt_total`, `paid_so_far` rejected.

## 10. REST API (v1)

Bearer from `tokens`, constant-time compare, never echoed. Amounts in integer milliunits.
`POST /v1/ops/{op}` takes the op's args object directly; wrappers take flat fields.
`Idempotency-Key`: 16–128 chars `[A-Za-z0-9_-]`, required on writes. Codes: 200 (flags
`reordered`, `partial`, `requery` per create) · 202 `pending|blocked|unknown` · 403
`policy|role` · 409 `dropped` · 422 `schema|failed|key_reuse` · 429 · 503.

- `GET /healthz` — `{state, reason}`, no auth, codes per 7.3.
- `GET /v1/status` — `{state, reason, stale, cursor, outbox_size, outbox_divergent,
  last_nack: {id, code, at}|null, rebuilds_24h, restores_24h, live_since, last_exit: {code,
  reason, at}|null, rules_in_budget, restores_inproc_24h, quarantined: [{key, version, op,
  error, acked, covered, tainted}], rebuilds_24h/restores_24h = exits 75 / 77 in `rebuilds.log`,
  versions: {server, bundled}}`.
- Reads (scoped to `budgetId`, via core services): `/v1/accounts`, `/v1/category-groups`,
  `/v1/categories`, `/v1/payees`, `/v1/transactions?account=&category=&payee=&since=&until=
  &cleared=&limit=&offset=`, `/v1/transactions/{id}`, `/v1/months/{YYYY-MM}`
  (`getMonthlyBudget`, `getReadyToAssignBreakdown`, process TZ), `/v1/recurring`, `/v1/ops`.
- `POST /v1/ops/{op}` (one op); `GET /v1/mutations/{id}`.
- Wrappers (ops issued): `POST /v1/transactions` (1), `PATCH /v1/transactions/{id}` (one
  `updateColumn` per field; `cleared` → `setCleared`), `DELETE /v1/transactions/{id}` (1),
  `POST /v1/transfers` (1), `PUT /v1/months/{m}/categories/{id}/assigned {amount}` (1,
  `upsertAssignment` with the app's checks: over-assign against Ready to Assign rejected
  unless `allowOverAssign`; a decrease causing overspending per
  `monthlyBudgets.checkFutureOverspending` rejected unless `allowOverspend`).
- `POST /v1/months/{m}/move {from: id|"rta", to: id|"rta", amount}` — the app's move money
  (`useCategoryOperations.ts:380-447`): `amount > 0`, `from ≠ to`; from a category: available
  > 0, amount clamped, overspend check on the source; one `batchUpsertAssignments` with two
  entries of absolute totals read from the month rows (one when either side is `rta`; from
  `rta` = plain assignment); `budgetId` forced per entry; over-assign check only from `rta`.
  The generic `monthlyBudgets.upsertAssignment` op applies the `PUT`'s checks.
- `POST /v1/admin/outbox/{id}/drop` — 8.2 (409 outside `outbox_blocked`); `POST
  /v1/admin/quarantine/{key}/ack` and `/retry` — 8.4 (`retry` exits 77, counted in the 50 budget).

Example (Ambrogio adds an expense):
```http
POST /v1/transactions
Authorization: Bearer <write token>
Idempotency-Key: amb-2026-11-24-7f3a
{"accountId":139,"categoryId":163,"date":"2026-11-24","outflow":12500,"payee":"Esselunga","memo":"spesa"}
→ 200 {"results":[{"id":8631}],"mutationIds":["hdl_…"]}
```

## 11. Config, image, manifest

`config.json`: `url` (`http://budgero.cloud.lazycat.app.budgero.lzcapp:3001/api/v1`: the API base, not the origin), `user`,
`spaceId`, `budgetId`, `readOnly`, `allowDestructive`, `port` (8787, fixed in production).
Secrets, mode 600, uid 1001: `password`, `space.key` (raw base64 from Settings → Push API →
export), `tokens`. Environment in production: only `TZ=Europe/Rome` and
`BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}`.

Image (`lzc-budgero/docker/headless/Dockerfile`): clone `f-liva/budgero` at fork tag
`headless-v1.22.1-<n>`; `pnpm install --frozen-lockfile --prod=false`; esbuild →
`dist/headless.mjs` with `sql.js` external and a `createRequire` banner; runtime
`node:22-alpine` + `busybox-extras` + `dist/` + `cp -rL packages/core/node_modules/sql.js
/app/node_modules/sql.js`, worker `cwd=/app`, `entrypoint.sh`. Tag
`fliva/budgero-headless:1.22.1-<n>`, mirrored to the Lazycat registry (the server image stays
our thin wrapper over the upstream release).

```yaml
headless:
  image: registry.lazycat.cloud/<mirror>/fliva/budgero-headless:<hash>
  user: "1001:1001"
  setup_script: mkdir -p /lzcapp/var/headless && chown -R 1001:1001 /lzcapp/var/headless
  binds: [/lzcapp/var/headless:/lzcapp/var/headless]
  environment: [TZ=Europe/Rome, "BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}"]
  health_check: {test: [CMD, wget, -qO-, "http://localhost:8787/healthz"], start_period: 120s}
```
Ambrogio reaches `http://headless.cloud.lazycat.app.budgero.lzcapp:8787` (internal network).
The disk is trusted at NAS-root level; the JWT travels in the WS query string (upstream).

## 12. Milestones

1. **Read-only client + bench.** U1–U3, U6, platform pieces, reads, states, startup/shutdown,
   supervisor. Bench: `docker run budgero/budgero:v1.22.1` with `WEBSOCKET_ALLOWED_ORIGINS`;
   `bench/create-space.ts` (register, create space, generate/wrap/upload the key with the
   runtime's `KeyVault`, `budgets.create`); `bench/peer.ts` (second client **with** uploads);
   a **WebSocket-aware reverse proxy** at `url` used by both clients (records HTTP calls;
   holds, drops, injects frames; `hdl_` ids identify headless ops); headless via
   `entrypoint.sh` with `--config-dir`, `--bench` (`GET /v1/debug/db` = `db.backup()`),
   `--crash-at=<point>` (enum `crash-points.ts`: `snapshot_download`, `create_database`,
   `before_catchup_settled`, `ws_before_apply`, and the write points of milestone 2); the
   harness relaunches on 137 itself.
   **Done when:** peer write visible within 5 s; restart rebuilds to `live`; `/v1/months`
   equals the peer's for 3 months; every crash point and 100 random kills (recorded seed) end `live` with
   `dumpDb(adapter, {sequences: true, crossDevice: true})` (`fuzz/harness.ts:104-225`, run in
   the app's vitest which spawns the headless) equal to the peer's, `mutation_history` as a
   set of `MutationID`s; peer out-of-band upload ⇒ exit 77 then `live`; proxy answering the blob with **422 and a body** ⇒
   halt `bootstrap_failed:download`; server unreachable before activation ⇒ `bootstrapping`
   retries; proxy returning 500 on the blob ⇒ exit 78 with backoff, 20 consecutive ⇒ stays
   down; a WS drop with no newer blob ⇒ **no** restore
   (`recentDownloadWindowMs` policy); remote
   mutation whose apply throws (`updateColumn` on a deleted row, injected while the headless
   is down and the peer stopped, throwaway space) ⇒ in-process restore, retry, quarantine,
   `quarantined: [1 entry]` with `op`/`error`, **one** exit 77, then `live` with the key skipped; restart **and**
   a forced in-process restore ⇒ no new entry, mutation skipped; a peer snapshot bound past
   it ⇒ `covered` on the next start, an older history restore ⇒ uncovered again; `retry` ⇒
   exit 77, replay, re-quarantine; a quarantine caused by a **corrupted `encryptedPayload`**
   is skipped before decode at the next start; a blob served without `X-Mutation-Version` on an **empty** log ⇒ `live` with cursor 0; 51 forced in-process
   restores ⇒ halt `restore_loop`; unknown op code ⇒ halt `unknown_op`; header,
   WS URL and frame tests; a 2-op request whose op 1 is nacked `invalid` while op 2's apply is
   blocked, then admin drop ⇒ `outbox.json` empty and every op `dropped`; state never leaves `draining` between `onQuarantined` and the exit;
   a catch-up-unsafe restore served an unbound blob ⇒ halt before the cursor is reseeded; proxy saw **only** allowlisted calls (login, `GET /profile`, `GET
   /budget-spaces`, `HEAD /health`, `GET /database/blob`, `GET /database/state`, `GET
   /version/latest`, WS upgrade; `GET /exchange-rates` allowed but not required, a peer
   write in another currency triggers it during apply), each required one at least once; exits 75/76/77 relaunch, 1 stays down,
   21st 75 / 51st 77 in 24 h (bench stub worker) ⇒ storm with `/healthz` 503.
2. **Writes.** §8–10, drain rule, latch. **Done when:** REST ops appear at the peer and in its
   next snapshot; **parity test in the app's vitest** (harness `Device`s and a headless
   executor from the same template bytes, a seeded `randomUUID` stub (to be built: the
   harness has `setClock` only, `fuzz/harness.ts:26, 67`; needed so the generated `transferId`
   matches on both sides), `setClock`, FX stub, same op
   sequence ⇒ equal `{op, args}`, `v` via `mutationFormatVersion`, equal `dumpDb`); write
   crash points (`after_ledger_intent`, `after_ledger_queued_before_rename`,
   `after_outbox_add_before_send`, `after_send_before_ack`, `in_dequeuing_save`) then retry
   with the same key ⇒ the log grew by exactly k since the pre-test version (`GET
   /sync/mutations?space_id&before&limit≤100`) and the decrypted `{op, args}` equal the
   ledger entries; same key twice concurrently ⇒ one mutation; proxy holds the headless
   frame until a peer mutation is acked ⇒ 200 `reordered`, exit 75, `dumpDb` equal after,
   retry returns `reordered` and `id: null`; proxy **drops the ack frame** and the op returns
   via catch-up ⇒ `reordered` from the dequeue observer; out-of-band restore during a 2-op `PATCH` (no
   peer interleave) ⇒ the request answers 202 at once, exit 77 within 10 s, next start drains
   op 2; a 202'd op acked after a reconnect at a version ≠ `base+1` ⇒ `reordered` persisted
   and exit 75; peer out-of-band upload while the socket is down after a headless write ⇒
   exit 77 on reconnect; quarantine with writes: 503 `quarantine_pending`, admin ack ⇒
   writes open; outbox non-empty at start + injected catch-up failure ⇒ exit 77, never `live` while the
   outbox is non-empty at start; `checkApiHealth` false during an `apply_failed` ⇒ exit 77
   (open episode at reconnect), quarantine at the next start ⇒ one more 77 ⇒ `live`; a **live** peer failure (headless connected) ⇒ one
   restore then quarantine ⇒ exit 77 once, then `live` with the key skipped; a peer edit of a
   row our queued delete removed, met during the startup drain ⇒ quarantined **tainted**,
   exit 77 after `settledAfterRestore`, dropped at the next clean start, applied normally
   there; a transient apply failure (FX fetch failing once) ⇒ in-process restore, retry
   succeeds, back to `live` with **no** exit; a blob served without `X-Mutation-Version` ⇒
   halt `bootstrap_failed:unbound_blob`; admin drop outside `outbox_blocked` ⇒ 409; injected
   `storage_error` ⇒ 202 then one log entry; injected `invalid` ⇒ `outbox_blocked` across a
   restart, admin drop, then 409; write while the socket is down ⇒ 503; budget with one
   continuous rule ⇒ `transactions.add` lands with no `rules.execute` and `rules_in_budget:
   1`; `addTransfer` with equal accounts ⇒ 422, exit 76; 6 in 10 min ⇒ 429; 2-op `PATCH`
   whose op 2 throws in apply ⇒ `draining` at once, 200 `partial` after op 1's ack, exit 76,
   retry ⇒ same 200 `partial` and op 2 never executes; 2-op `PATCH` whose op 2 throws in
   prepare ⇒ 200 `partial`, no rebuild; short `SELF_HOST_JWT_TTL_HOURS` ⇒ token
   refreshed without a halt; `GET /exchange-rates` seen with a multi-currency write; every
   argument guard has a rejecting test.
3. **Deploy.** NAS upgrade to v1.22.1 (blob + DB backup first); image built and mirrored;
   manifest service; reachability from the Ambrogio container; `APP_VERSION` unset on the
   NAS; after the upgrade make one web-app write and confirm `GET /database/blob` carries
   `X-Mutation-Version` before starting the headless; checks (observations, not gates): `lzcinit` forwards TERM, `health_check.start_period`
   honoured, behaviour of an unhealthy secondary service. **Read-only until** 7 days in which
   `rebuilds.log` holds no code outside 75/76/77/78/143, `halts.log` holds only
   `quarantine`/`restore_inproc` entries, every quarantine is acked,
   `rebuilds_24h`/`restores_24h` stay under budget, and `/v1/months/{current}` matches the
   web app on 3 spot checks; then `readOnly: false`.
4. **Ambrogio adapter** — separate project in the Ambrogio repo (must handle 503, 202 polling,
   `requery`).

## 13. Risks

- Space corruption through the log: app's own pipeline (U6), payload parity, argument
  schemas, throwaway space, read-only first. Through snapshots: impossible (no upload path,
  proven by the proxy allowlist).
- Residual Budgero semantics: the lost-update race between two devices editing the same
  absolute value at the same instant; identical in the web app.
- Rebuild frequency: one per restore (reconnect that finds a newer blob, out-of-band
  upload), reordered write, failed write. `rebuilds_24h`/`restores_24h` show if the budgets are wrong.
- Availability: a halt or storm is 503 until the operator acts; `covered` is recomputed only at
  start, so a quarantine covered by an in-process restore unblocks writes at the next restart.
- Upstream churn: pin to a tag; server and headless upgrade together; U1–U4, U6 carried as a
  patch stack until upstream takes them (#155).

## 14. Left to the builder

esbuild alias set; exact JSON layout of `outbox.json`/`ledger.json`/`exit-info`; read
response field names (milliunits); router choice; supervisor script details beyond the
trap, budgets and CGI responder.

## 15. Amendments from the milestone-1 implementation (26/11/2026, to fold into v30)

Found by the task reviews and the bench while building M1 on fork branch `feat/headless-client`
(29 commits over `v1.22.1`); each is already implemented as described here.

- §6 U2: `getSendable()` is the **queue prefix** before the first entry whose save has not
  resolved; a resolved save releases every id it persisted (so one rejected save cannot hold
  the prefix forever). `deserializeMutation` and `readSnapshotVersions` are re-exported from
  the runtime index.
- §6 U3b: `onRemoteApplySucceeded`/`onQuarantined` are guarded observers (a throw is logged);
  a throw from the awaited `onRemoteApplyFailed` is **not** swallowed: the headless halts.
- §6 U3c / §7.4.10: `onRestoreCompleted` runs after the in-memory cursor is reseeded (the
  cursor lives only in the shim, nothing reaches disk); the halt destroys the transport before
  the reconnect, so no mutation is applied from the reseeded cursor. Wording "halt before the
  cursor is reseeded" → "halt before any mutation is applied after the restore".
- §7.2 `http.ts`: HTTP **429** is a transport (transient) failure, retried. `classifyFailure`
  returns `'auth'` for 401.
- §7.3: writes answer **503** in `not_configured` (the plan said 404; spec stands).
- §7.4.9: a space the user cannot open (`NoWorkspaceToActivateError`, `NoAcceptedSpacesError`,
  `ExternalKeyMismatchError`) ⇒ halt **`access_denied`**, never exit 78.
- §7.7: new reason **`durable_write_failed`** — a `quarantine.json`/`failures.json` write failed
  inside a hook. A halt landing while a rebuild is running cancels the exit (the process stays
  halted).
- §8.4: a blob-history restore published at bound 0 comes back **unbound** ⇒
  `bootstrap_failed:unbound_blob` (per §7.4.10); "uncovered again" applies to restores bound ≥ 1.
- §11: `BUNDLED_VERSION` = the root `package.json` version (what the server derives
  `build_version` from when `APP_VERSION` is unset); the fork tag goes only into the OCI label.
- §12.1: the bench proxy fronts the **headless only** (the peer talks to the server directly).
- M2 plan items raised by the final review: single-instance lock on the config dir
  (`worker.lock`, exit 1 `config:locked`); supervisor down-mode port must follow `config.port`;
  log retention for `rebuilds.log`/`halts.log`; redactor key match widened (`accessToken`,
  `apiKey`); bench scenario for a wrong `spaceId` ⇒ `access_denied`.

M2 amendments (26/11/2026), from the writes implementation (fork branch `feat/headless-client`):

- §10 `/move` accepts optional `allowOverAssign`/`allowOverspend`. This mirrors the app's confirm dialog.
- §12 bench: the scenario "2-op PATCH whose op 2 throws in prepare" is unreachable through validated ops (only `accountid` throws in prepare, and it is not an allowed column). It is covered by an engine unit test.
- §8.3: a ledger-answerable retry skips ownership and the services requirement. Shape validation always runs.
- §8.3: a reordered record with intent ops never re-executes. Its intent ops become `skipped`, and the answer is 200 `reordered` + `partial`.
- §12: the bench and the parity test live in `packages/headless/test`, not in the app's vitest.
- §7.6: exit 77 on the out-of-band `sync_state_changed` frame itself, without waiting for upstream's delayed download.
- §12 bench: scenario 24 (JWT refresh) needs the server minimum TTL of 1 h, so it is gated behind `HEADLESS_BENCH_JWT=1`.
- §7.2 logging: idempotency keys appear in logs only as `sha256(key)[:12]`.
- §7.7: a failing dequeue save halts `durable_write_failed` (before the save rejects, so our own echoed ack never becomes a remote apply failure).

M3 amendments (26/11/2026), deploy decisions (plan `docs/superpowers/plans/2026-11-26-budgero-headless-m3-deploy.md`):

- §3: the non-goal "public exposure" is replaced by "exposure only through the Cloudflare tunnel hostname `budgero-api.federicoliva.it`, behind a Cloudflare Access application with Service Auth (service token) and the bearer tokens; `/v1/admin/*` and `/v1/debug/*` blocked at the edge". Decided by Federico on 26/11/2026.
- Why: Lazycat isolates lzcapps. Measured on 26/11/2026 from the Ambrogio container: `budgero.cloud.lazycat.app.budgero.lzcapp` resolves (`fd03:…`) but every connect times out; `budgero.chronos.heiyu.space` answers 307 to the Lazycat login; the tunnel hostname answers 200. Inside the Budgero package the internal name works.
- Ambrogio sends `CF-Access-Client-Id` / `CF-Access-Client-Secret` plus `Authorization: Bearer <read token>`; the service token and the bearer token live only in Ambrogio's secret store.
- §11: "Ambrogio reaches `http://headless.cloud.lazycat.app.budgero.lzcapp:8787`" is superseded: the tunnel (`cloudflared` on the host network) reaches that internal name, Ambrogio reaches the tunnel hostname. Operator admin calls stay inside the NAS (`lzc-docker exec … wget localhost:8787`).
- Rejected: `lzc-docker network connect` of the Ambrogio container to the Budgero network (lost at every lpk upgrade of either app).
