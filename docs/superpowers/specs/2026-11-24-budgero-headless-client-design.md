# Budgero headless client — design

Date: 24/11/2026. Status: **v14** (v13 clean rewrite + round-13 fixes), after thirteen adversarial
review rounds (26 reviewers; every critical/important finding verified in code at the pin and folded in).
Upstream proposal: https://github.com/tombadilo-bombadilo/budgero/issues/155 (no answer yet).
Pin: upstream tag **v1.22.1 = `e40723e`**. Every `file:line` below is at that pin; paths are
relative to `packages/` of the Budgero monorepo unless they name another repo.

## 1. Why

Budgero is end-to-end encrypted and local-first: the Go server stores only ciphertext (a
snapshot blob + an append-only mutation log), every client holds the space key, keeps a
decrypted SQLite and applies mutations itself. The only integration surface today is the
Push API: write-only, transactions only, applied by a browser *when someone opens the app*.
Ambrogio works around it by decrypting the blob itself (`ambrogio/src/budgeting/budgero-sync.ts`):
read-only, stale, and it broke on 23/11/2026 when the blob outgrew one LZ4 block.

We want a client that is a peer of the web app, without a UI, exposing a REST API to read
everything and run the operations we allow. First consumer: Ambrogio.

## 2. The model in one paragraph

The headless runs the **web app's own code** (stock `RuntimeCoordinator`, op registry,
`@budgero/core`) in Node, with a few injection points added upstream. Its SQLite lives **in
memory only** and is rebuilt from the server (snapshot + log) at every start. It **never
uploads a snapshot**. A write is a real mutation in the server log, acknowledged to the
caller **only after the server acks it**. Whenever the local DB can no longer be proven to
equal "snapshot + log in server order", the process exits and a supervisor restarts it,
which rebuilds. The only durable local state is two small files: the outbox and a ledger.

Why this shape, after twelve rounds: the runtime persists DB, cursor, applied ids and
outbox in separate steps, and every scheme to make a *persisted* local DB crash-safe (own
ordering rules, transactional sync state, "reproduce the browser") kept leaving windows.
Those windows only matter if the headless *uploads* snapshots, because then a local glitch
becomes every device's data. Removing uploads and treating the DB as a rebuildable cache
removes the whole class. What remains is the mutation log, fed by the app's own pipeline.

## 3. Goals, non-goals, anti-goals

Goals: (1) live peer of one space, one budget, one user; (2) REST reads of everything and
writes through an explicit op allowlist; (3) 200 only after the server ack; (4) nothing the
headless does locally can reach another device except through mutations the app's own
pipeline produced; (5) optional second service of the `lzc-budgero` Lazycat package.

Non-goals: UI; SaaS/Clerk auth; master-password change, key rotation, sharing, file
imports, bank sync, chat/LLM; public exposure; snapshot uploads; Push-API queue processing
(needs an atomic server-side claim first, U5).

Anti-goals: corrupting the space for other devices; reimplementing op logic; emitting a
mutation format different from the app's at the same tag; creating/uploading/rotating a
key; telling the caller "done" for a write the server never received; telling it "failed"
for one the server has.

## 4. Approaches considered

| | What | Verdict |
|---|---|---|
| **A. Full client in the fork, cache-only** | stock coordinator + registry + core; in-memory DB; never uploads; rebuild on doubt | **Chosen** |
| A′. Same, with a persisted DB and uploads | v2–v5 | Rejected after 5 rounds: every persistence window becomes every device's problem |
| B. Snapshot read + Push API write | package what Ambrogio does as REST | Rejected: writes wait for a browser; transactions only |
| C. Hand-crafted mutations | build payloads ourselves | Rejected: first divergence from `prepareMutationArgs` corrupts the space |

Within A, bypassing the coordinator was rejected: it is what handles out-of-band blobs,
post-restore migrations and catch-up correctly.

## 5. Constraints verified in code

- `@budgero/core` and `@budgero/runtime` are workspace-private; runtime uses extensionless
  imports → **esbuild bundle**. Op registry (`app/src/shared/mutations/op-code-registry*`)
  imports only `@budgero/core/browser`, `@budgero/runtime`, the Lingui macro and
  `@shared/runtime/global`; `withLegacyFormat` emits the **older** format if services are
  missing (`legacy-format.ts:266-272, 240`).
- `RuntimeCoordinator` builds its own `KeyVault` (`runtime-coordinator.ts:83`), requires the
  master password (`runtime-lifecycle-service.ts:61, 64, 94, 183`), and for an owner with no
  wrapped key **generates and uploads one** (`key-vault.ts:223-233`); activates
  `primary_space_id`.
- Activation with no local DB/cursor: snapshot → `createDatabase` →
  `reapplyQueueAfterRestore` (queued ids marked in-flight) → connect → catch-up
  (`space-activation-service.ts:272-391`); a download error falls back **silently to an
  empty DB** (`:310-322`); migration failures are swallowed (`:351-364`); outcome report in
  `onSpaceActivated` (`:95-123`).
- Mutation id = `spec.mutationId || spec.idempotencyKey || generate()`; a `mutationId` makes
  the executor a receiver that never sends (`mutation-executor.ts:69-71`,
  `mutation-dispatch-service.ts:55-58`). Server dedups by id, keeps the first payload, acks
  with the existing version (`websocket/mutations.go:124-138`); versions are `MAX+1` per
  mutation (`:142-150`); the log is deleted only by an admin user purge / space reset
  (`ResetSpace`, `:417-428`), never pruned.
- Dispatch: apply → `offlineQueue.add` (push into memory **before** `storage.save`,
  `offline-queue.ts:67-69`) → send; ack → `onMutationAck` → `ackMutation` (removes from
  memory before saving, `:157-162`) → `updateLocalVersion` (`sync-transport.ts:906-937`).
  Resend sweep and reconnect replay send **non-durable** entries too
  (`offline-queue.ts:141-147`, `reconnection-service.ts:245, 336-352`). Own mutations
  returning via catch-up are an **implicit ack** that never reaches the ack handler
  (`runtime-lifecycle-service.ts:196-201`). The server's ack is best-effort
  (`hub.go:537-548`).
- `executeMutationOp` has no transaction (`op-code-registry.ts:314-319`). Continuous-rules
  follow-ups are separate mutations with random ids, issued **after** the primary is sent
  and awaited one by one; their failures are swallowed (`app-runtime.ts:244-253, 851-903`).
- Apply catch blocks first check `isUpdateRequiredError` → `haltForUpdate`
  (`sync-transport.ts:1099-1101, 1219-1224`), then on catch-up fail twice ⇒ quarantine
  (`:1226-1240, 1400-1419`); existing `onFormatTooNew` dependency (`:1385`); key/
  password-change handlers don't stop the transport (`:1011-1031, 1733-1762`).
- `DatabaseSync.downloadAndRestore` (`database-sync.ts:423-449`) does not wait for a running
  write and swallows hook throws. On reconnect the runtime downloads the latest blob only
  if there was no recent download **and no local change since the last download**
  (`reconnection-service.ts:194-200`; the flag is set by every synced/queued local
  mutation, `runtime-coordinator.ts:353-356`), and on out-of-band `sync_state_changed`
  only while connected (`runtime-context-factory.ts:235`). So after one headless write, a
  peer's out-of-band blob uploaded during a disconnect is **never** noticed by upstream.
- Nack codes (`client.go:18-29`): `storage_error`, `internal` transient; `invalid` permanent;
  in every case upstream keeps the entry queued and resends it.
- WebSocket: `Origin` must equal `WEBSOCKET_ALLOWED_ORIGINS` exactly (`websocket.go:78-91`;
  manifest sets `https://${LAZYCAT_APP_DOMAIN}`); frames are plaintext JSON with only
  `encryptedPayload` opaque; client-sent types: `mutation`, `catch_up_request`,
  `increment_encryption_key_version`, `master_password_changed`.
- `getSyncDiagnostics()` exposes cursor, `catchUpInProgress`, `pendingCount` (= in-memory
  queue length) (`runtime-coordinator.ts:720-733`).
- Lazycat ignores `services.*.restart` (every lzcapp container has `RestartPolicy=no`);
  `user:` + `setup_script` work (`lzc-postiz/postiz-lzc/lzc-manifest.yml:34-35`);
  `health_check` becomes a Docker healthcheck.
- `sql.js` is a **devDependency** of `core` (`core/package.json:52-62`), not hoisted under
  pnpm; `NodeSqlJsAdapter` imports `'sql.js'` and loads the wasm from
  `process.cwd()/node_modules/sql.js/dist` (`node-sqljs-adapter.ts:1, 45-47`).
- Server version: `GET /api/v1/version/latest` (unauthenticated) → `build_version`, may be
  `unknown` (`appmeta/version.go:68-105`).

## 6. Upstream changes (fork `f-liva/budgero`, branch `feat/headless-client`, one commit each)

- **U1 — external space key.** `RuntimeCoordinatorDeps.spaceKeySource?: {spaceId, key}`:
  `KeyVault` returns that key for that space and throws for any other; never unwraps,
  generates or uploads (`uploadEncryptedKey` never passed); no master password; local
  persistence cipher disabled at all three sites; `ensureSpaceKeys` and activation target
  that space only; key version read from the shim-backed `MasterPasswordStore`.
- **U2 — queue storage + durability fix.** `runtime-context-factory.ts:201` passes
  `deps.queueStorage` to `new OfflineQueue(spaceId, storage)`; export `deserializeMutation`.
  **Bug fix:** a `persisting` set in `OfflineQueue` (id added before `storage.save`, removed
  only when it **resolves**); new `getSendable()` used by `getStale()`, `getUnsent()` and the
  reconnect replay (`reconnection-service.ts:245`); `getQueue()` stays unfiltered (reapply
  and `pendingCount` must see every entry).
- **U3 — hooks.** `allowUpload(): boolean` checked in `doUpload` right before `uploadBlob`
  (`database-sync.ts:330`); when false `doUpload` **returns** (so the reconnect replay
  doesn't log `snapshot_upload_failed`). `onMutationAck(id, version)` passes the version
  through (today dropped at `runtime-context-factory.ts:221`). `onMutationNacked(id, code)`
  from `handleMutationNack` (`sync-transport.ts:974`). `onRemoteApplyFailed(mutation, error)`
  in both apply catch blocks (`:1226-1244, 1097-1107`) **after** the `isUpdateRequiredError`
  branch (so `format_too_new`/`unknown_op` keep their own reasons via the existing
  `onFormatTooNew`), before any cursor move.
  `beforeRestore(): Promise<void>` awaited in `downloadAndRestore` **after** `download()`
  returned non-null and immediately before `db.restore()` (`:427-433`; not in
  `notifyDatabaseRestored`, which runs after an external swap and only on the app's
  password-change path). `onFollowUpError(op, error)` at every swallowed continuous-rules failure
  (`app-runtime.ts:851, 857, 875-903`). `RuntimeCoordinator.halt(reason)`: stops sync,
  reconnection, connectivity and the coordinator timers; `upload`/`downloadAndRestore`
  become no-ops behind a halted flag checked **before** `beforeRestore`.
- **U4 — 409 restore = full restore** (upstream only; the headless never uploads).
- **U5 — atomic push claim** (server; prerequisite for any future push processing; not
  built here).
- **U6 — shared mutation pipeline.** `executeMutation`'s pure parts (prepare, continuous
  rules, `recordHistory`, `resolveHistoryBudgetId`) move out of `AppRuntime` into a module
  without analytics/toast imports, used by both; no app logic is copied into the headless.

## 7. Process and state

### 7.1 Files that survive a restart

`outbox.json` (the `QueueStorage`), `ledger.json`, `rebuilds.log`, `halts.log`, `reason`,
`config.json` + secret files. Nothing else: DB and the `localStorage` shim are in memory.
Every file write: temp → fsync → rename → fsync dir; **one promise chain per file**, content
snapshotted at call time.

### 7.2 Platform pieces (`packages/headless/src/platform`)

- `storage.ts`: in-memory `localStorage` shim, reset at each start.
- `database.ts`: bare `NodeSqlJsAdapter`, failure logs redacted. No `forceSave`, so
  `persistDatabase` returns false and the runtime never persists cursor/applied ids
  (intended).
- `queue-storage.ts`: `QueueStorage` over `outbox.json`. The wrapper **observes**: ids that
  appear in a save (→ ledger `queued`, see 8.3) and ids that disappear (→ dequeue = ack,
  whether from `mutation_ack` or an implicit catch-up ack). `ackMutation` is the only
  dequeue path in the headless; the wrapper halts (`queue_cleared`) if `clear()` is called.
- `ledger.ts`: `ledger.json`, see 8.3.
- `http.ts`: port of `blobApi` **download side only** (`downloadBlob`, null only on 404;
  `getDatabaseState`), `spacesApi`, `getProfile` (`GET /profile`), `checkApiHealth` (`HEAD
  /health`), login, version. No upload function; the coordinator's required `uploadBlob`
  dependency is a stub that throws (never reached because `allowUpload` is false). Base URL
  also for core's relative FX path. Contract test against the app's `api-client.ts`.
- `websocket.ts`: `globalThis.WebSocket` shim (`ws`) sending `Origin: $BUDGERO_ORIGIN`;
  `getWebSocketUrl` with `token`, `space_id`, `protocol=SYNC_PROTOCOL_VERSION`,
  `client_session`; detects an HTTP 426 on the upgrade (`ws` `unexpected-response`) ⇒ halt
  `protocol_426`; on every (re)connect compares `getDatabaseState().version` with the blob
  version the headless knows: server newer ⇒ `draining` + exit 77 (upstream would skip the
  download after a local write, §5). **Outbound rules:** `catch_up_request` always; `mutation` frames only
  when `readOnly` is false and only with a **send window of 1 in queue order**: a `mutation`
  frame is released when every entry ahead of it in the in-memory queue has been dequeued
  (released on the dequeue observation, so implicit acks count). This holds for live
  requests, the post-202 tail, the startup drain and reconnects alike, and keeps a
  continuous-rules follow-up from landing before its primary when the primary gets a
  transient nack. Key/password frames never. A duplicate ack for an id no longer pending is
  ignored by the ordering check.
- `global.ts`: full `services()`, `mutationsRouter()` and `mutationHistory` id-reuse API;
  startup fails if any is missing.
- `lingui.ts`: stub for `@lingui/core/macro`.
- Logging: JSON lines on stdout `{ts, level, msg, state, mutationId?}` through a redactor
  (no args, no tokens, no keys).

### 7.3 States

`not_configured` · `bootstrapping` · `draining` · `live` · `outbox_blocked` · `halted` ·
`shutting_down`.

| Route | not_configured | bootstrapping | draining | live | outbox_blocked | halted | shutting_down |
|---|---|---|---|---|---|---|---|
| `GET /healthz` (no auth) | 200 | 200 | 200 | 200 | 503 | 503 | 503 |
| `GET /v1/status` | 200¹ | 200 | 200 | 200 | 200 | 200 | 200 |
| `GET /v1/mutations/{id}` | 404 | 200 | 200 | 200 | 200 | 200 | 200 |
| reads | 503 | 503 until snapshot restored, then 200 + `stale: true` | 503 | 200 | 503 | 503 | 503 |
| writes | 503 | 503 | 503 | see 8 | 503 | 503 | 503 |
| `POST /v1/admin/*` | 404 | 503 | 503 | 200 | 200 | 200 | 503 |

¹ served without a bearer (the `tokens` file may not exist yet). Writes: a request whose
`Idempotency-Key` record answers by itself (8.3) gets that answer in any state where
`/v1/mutations` is served; the 503 applies to requests that need execution. After a non-rebuild exit the
supervisor serves `/healthz` and `/v1/status` only (no bearer; body `{state:"halted",
reason}`), everything else is connection refused. Reads become 200 only once the
`onSpaceActivated` report has been accepted (a DB created from a fallback is never served).

### 7.4 Startup (ordered) and shutdown

1. Parse CLI: `--config-dir` (default `/lzcapp/var/headless`), `--bench`, `--crash-at`.
   Missing `config.json` ⇒ state `not_configured` (idle, never contacts the server).
   Invalid config (`url` http(s) URL, `user` string, `spaceId` string, `budgetId` integer,
   `port` 1–65535, booleans) or a secret file missing, unreadable, not mode 600 or not
   owned by the worker uid ⇒ `reason=config:<field>`, exit **1**. Operator procedure to
   create them: `lzc-docker exec` into the container as root, write the files, `chown 1001`,
   `chmod 600`.
2. Load `tokens` (`name:role:token`, roles `read|write|admin`; malformed line = config
   error). Role matrix: `read` → GET routes; `write` → `read` + writes; `admin` → `write` +
   `/v1/admin/*`. Mismatch ⇒ **403 `role`**. Clear the `reason` file.
3. Read `rebuilds.log` (storm budgets, 429 window).
4. Ledger reconciliation: `queued` ops missing from `outbox.json` are appended (same id,
   same entry); `dropped` ids still present are removed; `unknown` ops become `queued` if
   present in `outbox.json`, `failed` otherwise.
5. Nacked check: a ledger `nacked` own op still in `outbox.json` ⇒ state `outbox_blocked`,
   **no activation** (the entry would be reapplied and resent); serve the routes of 7.3.
   `/v1/admin/*` is served in read-only mode too, for exactly this case.
6. Read-only check: `readOnly` and non-empty outbox ⇒ `reason=outbox_in_readonly`, exit 1
   (a leftover outbox would be resent; set `readOnly: false` to drain it).
7. Version check: transport error ⇒ retry with backoff, state `bootstrapping`; a real answer
   that mismatches `package.json` of the pin or is `unknown` ⇒ halt `version_mismatch`.
8. Login: transport error ⇒ retry; 401 ⇒ **halt** `auth_failed` (in-process, routes per 7.3).
   The token is refreshed on any later 401 and before its expiry (`SELF_HOST_JWT_TTL_HOURS`,
   720 on the NAS); a 401 on re-login ⇒ halt `auth_failed`.
9. Activate (bootstrap invariant, 7.5). Transport errors during download ⇒ the coordinator
   is torn down and step 7 retried with backoff; only a download that failed with the
   server reachable is `bootstrap_failed:download`.

Shutdown on `TERM`/`INT` (forwarded by the supervisor): state `shutting_down`,
`coordinator.halt()`, wait for both file chains, exit **143**.

### 7.5 Bootstrap invariant

**`live` only with DB = snapshot + log in server order, own ops at their server position.**

1. Activation uses `hasLocalDatabase: async () => false` and a fresh shim.
2. `onSpaceActivated` must report `ok === true` and path `server_snapshot`; `fresh` only
   when the blob answered 404. Anything else (local fallback, decrypt error, swallowed
   migration failure detected by wrapping the loader) ⇒ halt `bootstrap_failed:<kind>`.
   State `bootstrapping` until catch-up has settled.
3. Outbox non-empty at start ⇒ the reapplied entries ran **before** catch-up, out of server
   order (on the 404/fresh path they are not reapplied at all and come back via catch-up:
   same conclusion) ⇒ state `draining`: wait until the outbox is empty (every entry acked), then
   **rebuild** (exit 75). Only the second bootstrap goes `live`.
4. **Every live restore** ⇒ `draining`, then rebuild (exit **77**), whatever `queuedCount`:
   `beforeRestore` (U3, after the download succeeded) flips to `draining` synchronously and
   waits for the **apply-phase lock** (taken **before** the status gate and released once
   every op of the request, follow-ups included, has passed `outbox.add` and
   `sync.send()` has returned, i.e. the shim has buffered the frame; it never waits for an
   ack, so `beforeRestore` can't deadlock a reconnect whose resend is paused). A request
   that acquires the lock re-checks the gate under it (a restore may have flipped the state
   to `draining` meanwhile ⇒ 503). Without it a write could read absolute totals before the
   swap and apply them to the restored DB with the ordering check blind (an out-of-band
   blob is not in the log). A restore that started always ends in a rebuild. Restores are
   not rare: every reconnect after a phone upload triggers one.
5. **Live ordering check, per request.** Before a request: `base = max(cursor, highest
   version among own acks)` (the ack handler calls `onMutationAck` before
   `updateLocalVersion`, so the cursor can lag the last own ack by one); accepted only when
   `catchUpInProgress` is false and `pendingCount === 0`. The request issues k ops (own +
   continuous-rules follow-ups; writes are serialised, so every new outbox id during the
   request belongs to it). Acks must carry versions exactly `base+1 … base+k` in send order.
   Any gap, or a dequeue with no version (implicit ack after a lost ack frame) ⇒
   `reordered`: a peer mutation was ordered between ours; locally ours ran first, so
   autoincrement row ids and absolute totals (`upsertAssignment`, move money,
   `updateColumn`) now differ from every other device (the web app has the identical race,
   `id-reuse.ts:1-28`). The verdict and the flip to `draining` happen **synchronously in
   `onMutationAck`**. Follow-ups of that request not yet sent are **dropped** (ledger
   `dropped`, removed from `outbox.json`, held frame discarded): their `transactionIds` are
   local row ids that now name a different row on other devices. Response 200 with
   `reordered: true` and `rules_dropped: true` when any was dropped (for creates: the
   returned ids are not valid across devices); rebuild (exit 75) before any further write.
6. Throws, by where they happen: primary `prepareMutationArgs` ⇒ 422, ledger `failed`, no
   rebuild. Primary apply ⇒ 422, ledger `failed`, rebuild (exit **76**; nothing reached the
   server because `outbox.add` runs after apply). Continuous-rules follow-up
   (`onFollowUpError`) ⇒ the primary is already sent: **200** (or 202) with
   `rules_failed: true`, follow-up `failed` (or `unknown` if its own `outbox.add` threw),
   rebuild (exit 76). `outbox.add` of the primary throws ⇒ ledger `unknown`, **202
   `unknown`**, halt `outbox_write_failed` (the next start resolves it, step 4).

### 7.6 Rebuild, supervisor, exit codes

Rebuild = `coordinator.halt()`, wait for both file chains, append to `rebuilds.log`, write
`reason`, `process.exit(<code>)`. The container entrypoint (a child of Lazycat's `lzcinit`
because `setup_script` is used) is a small shell **supervisor** that relaunches on 75/76/77,
stays down otherwise, traps `TERM`/`INT` and forwards them (`trap 'kill -TERM "$child";
wait "$child"; exit 143' TERM INT`), and enforces budgets from `rebuilds.log`.

| Trigger | Exit | Budget (24 h) | 429 window |
|---|---|---|---|
| `reordered` | 75 | 20 → `rebuild_storm` | no |
| drain finished (outbox was non-empty) | 75 | shares the 20 budget, not counted when the previous record has code 76/77 and `outbox_size > 0` | no |
| admin drop | 75 | 20 | no |
| live restore | 77 | 50 → `restore_storm` | no |
| primary apply throw (422) | 76 | not counted | 5 per 10 min ⇒ writes 429 |
| follow-up failure (`rules_failed`) | 76 | not counted | 5 per 10 min |
| config error, `outbox_in_readonly`, uncaught exception | 1 | stays down | — |
| `TERM`/`INT` | 143 | stays down | — |

`rebuilds.log` records `{ts, code, reason, outbox_size}`; `reordered`, drains and admin drops
share the 20/24 h budget; `halts.log` records `{ts, reason}` for halts
that don't exit (milestone 3 gate). After a storm the supervisor serves `/healthz` 503 and
`/v1/status {state:"halted", reason:"rebuild_storm|restore_storm"}` (busybox httpd CGI, so
the HTTP code is settable); it writes `exit:<code>` as the reason when the worker left none
(the worker clears `reason` at step 2). The operator clears a storm by deleting
`rebuilds.log` and restarting the container.

### 7.7 Halting

Triggers and reasons: `version_mismatch`, `auth_failed`, `protocol_426`, `format_too_new`,
`unknown_op`, `remote_apply_failed` (from `onRemoteApplyFailed`, before any cursor move),
`key_changed`, `password_changed`, `bootstrap_failed:<download|local_fallback|decrypt|migrations>`,
`outbox_write_failed`, `queue_cleared`, `rebuild_storm`, `restore_storm`, `exit:<code>`. `format_too_new`/`unknown_op` come from the existing
`onFormatTooNew`/`UnknownOpCodeError` path, `protocol_426` from the WS shim.
Action: `coordinator.halt(reason)`; routes per 7.3; `halts.log` appended. Never auto-reload,
never re-key, never leave `halted` except by operator restart. The halted check runs before
`beforeRestore`, so a halt is never turned into `draining`.

### 7.8 Read-only

`readOnly: true`: no write routes (admin routes stay), the WS shim refuses `mutation`
frames, `allowUpload` is false and `uploadBlob` is the throwing stub (both are true in write
mode too). Step 6 refuses to start with a non-empty outbox. A test sends every frame type
and expects a throw for all but `catch_up_request`.

## 8. Writes

### 8.1 Flow per request

1. Take the global write lock. Look the `Idempotency-Key` up (under the lock). If the record
   answers by itself (8.3) → answer, releasing the lock while waiting on queued ops.
2. Take the apply-phase lock, then the status gate under it: 503 unless `live`,
   `catchUpInProgress === false`, `pendingCount === 0`; 429 if the caller-rebuild window is
   exceeded. `base` is read here, under the lock.
3. Policy + argument schema (9). Ledger record `intent` for **all n own ops** up front, with a
   fresh random nonce, `bodyHash` and `base`.
4. For each own op: `execute` via the U6 pipeline with
   `spec.idempotencyKey = opId` (never `mutationId`). Inside `outbox.add` the wrapper writes
   ledger `queued` with the full queue entry (`id, op, args, v, timestamp, baseVersion,
   spaceId`) **before** the outbox rename. Release the apply-phase lock when every op,
   follow-ups included, has passed `outbox.add` and `sync.send()` returned (frame buffered
   in the shim; the send window may still hold it).
5. Wait for the dequeue of every op of the request (30 s). All dequeued ⇒ ledger `acked` +
   results + versions ⇒ **200** (with `reordered`/`rules_failed`/`partial` flags). Timeout ⇒
   **202 `{status:"pending", mutationIds}`**; the observer completes the ledger later; the
   gate's `pendingCount === 0` keeps further writes at 503 `pending` meanwhile.

The ledger `acked` write happens inside the `QueueStorage.save` that removes the id, before
that save resolves. Because `queued` is written before the outbox rename, a crash between
them leaves `queued` without an entry, which step 4 of startup puts back.

### 8.2 Nack

Transient (`storage_error`, `internal`) ⇒ ledger stays `queued`, `/v1/status.last_nack`,
202 after the timeout; upstream resends. `invalid` ⇒ ledger `nacked`, state `outbox_blocked`
(7.3), `outbox_divergent: true`. **No nack is ever answered with 409** while the entry is on
disk: upstream resends forever and the op can still land. A nack on a follow-up blocks the
same way but never changes the request's status code. Empty-id nack ⇒ `last_nack` only.
Operator: `POST /v1/admin/outbox/{id}/drop` (role `admin`) is **request-scoped**: it marks
`dropped` every op of the same ledger record still in `outbox.json` (follow-ups included,
their `transactionIds` are local row ids that mean a different row on other devices) in one
ledger write, then removes them from `outbox.json`, then exits 75. A follow-up cannot be
dropped alone while its primary is queued. After a drop the key answers 409 when an own op
was dropped, 200 `rules_dropped: true` when only follow-ups were.

### 8.3 Ledger

`ledger.json`, record per `Idempotency-Key`:
`{key, bodyHash, nonce, base, generated: {transferId?}, ops: [{opId, own, state, entry?,
result?, version?}]}`, `state ∈ intent|queued|acked|nacked|failed|dropped|unknown`.
`opId = 'hdl_' + sha256(nonce + '#' + i)` (never derived from the key alone: a reused key
after expiry would collide with an id the server already has and be acked as a no-op).
`bodyHash` = sha256 of method + path + canonical JSON of the parsed body (sorted keys, no
whitespace). Retention 30 days; an expired key is a new key.

Decisions use **own ops only**; follow-up states only set `rules_failed`/`rules_dropped`:
- no record ⇒ proceed;
- different `bodyHash` ⇒ **422**;
- all own `acked` ⇒ 200 with stored results (`result: null` + `payload` for ops acked by a
  drain); a request whose op k failed after 1..k-1 landed ⇒ 200 `partial: true` with per-op
  results, both live and on retry (`updateColumn` is idempotent);
- own `queued` ⇒ in the outbox by construction (startup put-back): wait for its dequeue
  (202 after 30 s);
- own `intent` only ⇒ the ledger `queued` write precedes the outbox write and the U2
  `persisting` set keeps non-durable entries unsent, so the server has nothing under that
  id: re-execute with the same opId through the gate (fresh `base`);
- mixed own states (a multi-op `PATCH` interrupted): decide per op — `queued` ops wait for
  their dequeue, `intent` ops are re-executed with the same opId through the gate
  (`updateColumn` is idempotent), `failed` ops stay failed ⇒ 200 `partial` if any failed;
- own `unknown` ⇒ 202 `unknown` until startup resolves it;
- first own `failed` ⇒ 422 with the stored reason;
- own `nacked` ⇒ 202 `blocked` (from the record, before the gate; in `outbox_blocked` state
  this is the only write answer); own `dropped` ⇒ **409**.

Known gap, documented: continuous-rules follow-ups have their own ids; a crash between the
primary's `outbox.add` and the follow-ups' means a retry returns the stored 200 and the rules
don't run.

`GET /v1/mutations/{id}` maps `intent|queued → pending`, the rest 1:1, and returns
`version` and `reordered` when acked.

## 9. Op policy (Federico, 24/11: allowlist + key for destructive)

`api/op-policy.ts` lists exact registry names at the pin in three tiers; unlisted ⇒ 403
`policy` (future ops included). A test fails if a listed name is not in `KNOWN_OP_CODES` and
prints registry ops in no tier.

- **allowed:** `transactions.add` (with/without `splits`), `transactions.addTransfer`,
  `transactions.updateColumn` (columns `outflowconverted`, `inflowconverted`, `categoryid`,
  `memo`, `date`, `payee`; not `cleared`, core rejects it), `transactions.delete`,
  `transactions.setCleared` (exactly one id), `transactions.saveSplits`;
  `monthlyBudgets.upsertAssignment`; `categories.create`, `categories.updateName`,
  `categoryGroups.create`, `categoryGroups.update`, `categories.moveToNewGroup`;
  `accounts.create`, `accounts.update` (guarded), `accounts.setArchived`; `payees.add`,
  `recurring.create`, `recurring.update`. Moving money goes only through the endpoint in 10.
- **destructive** (`allowDestructive: true`): `budgets.delete`, `accounts.delete`,
  `transactions.deleteBatch`, `transactions.batchEdit`, `transactions.reassign`,
  `transactions.reconcile`, `transactions.deleteByRef`, `payees.rename` (merges payees),
  `payees.deleteMany`, `payees.removeUnused`, `categories.deleteAndReassign`,
  `categoryGroups.delete`, `categoryGroups.deleteAndReassign`,
  `monthlyBudgets.batchUpsertAssignments` (generic), `rules.create`, `rules.update` (nested
  ids applied with no budget check, `rules/index.ts:1657-1700`), `rules.execute` (non-empty
  `options.transactionIds`, max 500).
- **closed:** `history.applyOps`, `history.redoWithIds`, `history.restoreRows`,
  `transactions.import`, `importHistory.*`, `bankSync.*`, `chat.*`, `llmSettings.*`, reorder
  ops, `transactions.moveToNewCategory/moveToNewAccount`, transfer edit/delete ops,
  `monthlyBudgets.updateAssignment`, `monthlyBudgets.reassignAssignment` (merges a category's
  whole assignment history), everything unlisted.

**Per-op argument schema** (closed accepted-key set per op, from the op's `execute`/`prepare`
at the pin; unknown keys ⇒ 422; a test asserts every key the op reads is accepted or
explicitly rejected):
- always rejected: `mutationId`, `meta`, `idempotencyKey`, `opClock` (backdates the op on
  every device), `exchangeRateOverride`, `fromPush`, `mirror`/`Mirror` on any split line,
  `importIdentities`, `currencyRates`;
- create ops: caller `id` rejected (`transactions.add`, `categories.create`,
  `categoryGroups.create`, `accounts.create`, `recurring.create`'s `input.id`,
  `addTransfer`'s `source.id`/`destination.id`); `transactions.add` rejects a non-empty
  `transferId`; `addTransfer`'s `transferId` is generated by the headless and stored in
  `generated`;
- `transactions.add` keys: `budgetId`, `accountId`, `categoryId`, `date`, `time`, `inflow`,
  `outflow`, `memo`, `payee`, `labelId`, `cleared`, `splits[]{categoryId,
  transferAccountId, memo, payee, inflow, outflow, receivedAmount}`; `saveSplits`:
  `transactionId`, `splits[]{category_id, transfer_account_id, memo, payee, inflow, outflow,
  amount}` (`exactAmount`, `pair_id`, `PairID`, PascalCase ids rejected); `updateColumn`:
  `{id, columnName, newValue}`, `columnName` normalised like core (lowercase, `_` stripped,
  legacy `inflow`/`outflow`), integer `newValue` on id columns; `payees.add`: `{budgetId,
  name}`; `recurring.create`: `{input}`, `recurring.update`: `{id, patch}`;
- **every** id reference validated against `budgetId`, target ids included (`id`/`ids`,
  `transactionId`, `parentId`, `categoryId`, `newGroupId`, `accountId`, `labelId`,
  `source.accountId`/`destination.accountId`, `toAccountId`, split ids, recurring `input.*`/
  `patch.*` ids, `updateColumn`'s `newValue` on id columns); `budgetId` forced on ops whose
  args carry one, nested paths included (`input.budgetId`, each `batchUpsertAssignments`
  entry);
- `accounts.update`: **`name` only**; `type` and `currency` sent as `''` (core keeps the
  current value, `accounts/index.ts:447-449`; copying the local value would revert a
  concurrent peer change and convert with per-device rates); `metadata`, `onBudget`,
  `linked_category_id`, `cc_payment_category_id`, `debt_total`, `paid_so_far` rejected.

## 10. REST API (v1)

Bearer from `tokens` (constant-time compare, never echoed). Amounts in integer milliunits.
`POST /v1/ops/{op}` takes the op's args object directly; wrappers take flat fields.
`Idempotency-Key`: 16–128 chars `[A-Za-z0-9_-]`, required on every write. Status codes:
200 (`reordered`, `rules_failed`, `rules_dropped`, `partial` flags) · 202 `pending|blocked|
unknown` · 403 `policy|role` · 409 `dropped` · 422 `schema|failed|key_reuse` · 429 · 503.

- `GET /healthz` — `{state, reason}`, no auth, codes per 7.3.
- `GET /v1/status` — `{state, reason, stale, cursor, outbox_size, outbox_divergent,
  last_nack: {id, code, at} | null, rebuilds_24h, restores_24h, live_since, last_exit:
  {code, reason, at} | null, versions: {server, bundled}}`.
- `GET /v1/accounts`, `/v1/category-groups`, `/v1/categories`, `/v1/payees`,
  `/v1/transactions?account=&category=&payee=&since=&until=&cleared=&limit=&offset=`,
  `/v1/transactions/{id}`, `/v1/months/{YYYY-MM}` (assigned/activity/available per category,
  Ready to Assign; core's `getMonthlyBudget` / `getReadyToAssignBreakdown`, process TZ),
  `/v1/recurring` — via core services, scoped to `budgetId`.
- `GET /v1/ops` — policy: name, tier, format version.
- `POST /v1/ops/{op}` — one op.
- `GET /v1/mutations/{id}`.
- Wrappers (ops issued): `POST /v1/transactions` (1), `PATCH /v1/transactions/{id}` (one
  `updateColumn` per field; `cleared` → `setCleared`), `DELETE /v1/transactions/{id}` (1),
  `POST /v1/transfers` (1), `PUT /v1/months/{m}/categories/{id}/assigned {amount}` (1,
  `upsertAssignment` with the app's checks: over-assign against Ready to Assign rejected
  unless `allowOverAssign`, a decrease causing overspending per
  `monthlyBudgets.checkFutureOverspending` rejected unless `allowOverspend`).
- `POST /v1/months/{m}/move {from: id|"rta", to: id|"rta", amount}` — the app's move money
  (`useCategoryOperations.ts:380-447`): `amount > 0`, `from ≠ to`; from a category: its
  available > 0, amount clamped to it, overspend check on the source; one
  `batchUpsertAssignments` with two entries (absolute totals read from the month rows; one
  entry when either side is `rta`; from `rta` = plain assignment to `to`); `budgetId` forced
  on each entry; over-assign check only when `from` is `rta` (the app runs none for
  category→category). The generic `POST /v1/ops/monthlyBudgets.upsertAssignment` applies the
  same checks as the `PUT`. Ops issued by an endpoint (`batchUpsertAssignments` from
  `/move`) bypass the tier check: the endpoint is the guard.
- `POST /v1/admin/outbox/{id}/drop` — 8.2.

Example (Ambrogio adds an expense):
```http
POST /v1/transactions
Authorization: Bearer <write token>
Idempotency-Key: amb-2026-11-24-7f3a
{"accountId":139,"categoryId":163,"date":"2026-11-24","outflow":12500,"payee":"Esselunga","memo":"spesa"}
→ 200 {"results":[{"id":8631}],"mutationIds":["hdl_…"]}
```

## 11. Config, image, manifest

`config.json` (non-secret): `url` (`http://budgero.cloud.lazycat.app.budgero.lzcapp:3001`),
`user`, `spaceId`, `budgetId`, `readOnly`, `allowDestructive`, `port` (8787). Secret files,
mode 600, owned by uid 1001: `password`, `space.key` (raw base64 from Settings → Push API →
export), `tokens` (`name:role:token`, generated with `openssl rand -base64 32`). Only
environment inputs in production: `TZ=Europe/Rome`, `BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}`.

Image (`lzc-budgero/docker/headless/Dockerfile`): clone `f-liva/budgero` at fork tag
`headless-v1.22.1-<n>` (branch rebased on upstream `v1.22.1`); `pnpm install
--frozen-lockfile --prod=false` (sql.js is a devDependency); esbuild → `dist/headless.mjs`
with `sql.js` external and a `createRequire` banner; runtime `node:22-alpine` +
`busybox-extras` + `dist/` + `cp -rL packages/core/node_modules/sql.js
/app/node_modules/sql.js` (whole package: the bare import needs its `package.json`), worker
`cwd=/app`, `entrypoint.sh` supervisor. Tag `fliva/budgero-headless:1.22.1-<n>`, mirrored to
the Lazycat registry like the server image (which stays our thin wrapper over the upstream
release).

```yaml
headless:
  image: registry.lazycat.cloud/<mirror>/fliva/budgero-headless:<hash>
  user: "1001:1001"
  setup_script: mkdir -p /lzcapp/var/headless && chown -R 1001:1001 /lzcapp/var/headless
  binds: [/lzcapp/var/headless:/lzcapp/var/headless]
  environment: [TZ=Europe/Rome, "BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}"]
  health_check: {test: [CMD, wget, -qO-, "http://localhost:8787/healthz"], start_period: 120s}
  # port 8787 is fixed in production (config `port` exists for the bench); whether
  # `health_check.start_period` is honoured by Lazycat is a milestone 3 check
```
Ambrogio reaches it at `http://headless.cloud.lazycat.app.budgero.lzcapp:8787` (Lazycat
internal network; no ingress). Secrets, outbox and ledger sit on a disk trusted at NAS-root
level; the JWT travels in the WS query string (upstream design, internal network).

## 12. Milestones

1. **Read-only client + bench.** U1, U2, U3, U6, platform pieces, read routes, states,
   startup/shutdown, supervisor. Bench: `docker run budgero/budgero:v1.22.1` with
   `WEBSOCKET_ALLOWED_ORIGINS` set; `bench/create-space.ts` (register, `POST
   /budget-spaces`, generate/wrap/upload the key with the runtime's `KeyVault`,
   `budgets.create`, write raw key + budget id); `bench/peer.ts` (second client **with**
   uploads, standing in for the web app); a **WebSocket-aware reverse proxy** at `url` that
   both clients use (records every HTTP call; can hold, drop or inject frames; frames are
   plaintext JSON, headless ops recognisable by the `hdl_` prefix); the headless runs via
   `entrypoint.sh` with `--config-dir`, `--bench` (enables `GET /v1/debug/db` = `db.backup()`
   bytes), `--crash-at=<point>` (SIGKILL at a named point of the exported enum
   `crash-points.ts`: `snapshot_download`, `create_database`, `before_catchup_settled`,
   `ws_before_apply`, plus the write points below).
   **Done when:** a peer write appears in `GET /v1/transactions` within 5 s; a restart
   rebuilds and reaches `live`; `/v1/months` equals the peer's core figures for 3 months;
   every crash point and 100 random kills end with `live` and `dumpDb(adapter, {sequences:
   true, crossDevice: true})` (upstream comparator, `fuzz/harness.ts:104-225`, run inside the
   app's vitest which spawns the headless) equal to the peer's, `mutation_history` compared
   as a set of `MutationID`s; an out-of-band upload from the peer ⇒ exit 77 and `live` again, **also** when it happens
   while the headless socket is down after a headless write (reconnect check);
   a forced blob-download failure ⇒ halt `bootstrap_failed:download`, a server unreachable
   ⇒ `bootstrapping` with retries, not a halt; a remote mutation whose apply throws
   (`updateColumn` with `columnName: 'cleared'`, injected while the headless is down and the
   peer stopped, throwaway space) ⇒ halt `remote_apply_failed` before any cursor move; header,
   WS URL and frame tests; the proxy saw **only** allowlisted calls (login, `GET /profile`,
   `GET /budget-spaces`, `HEAD /health`, `GET /database/blob`, `GET /database/state`, `GET
   /version/latest`, WS upgrade), each at least once; exit 75/76/77 relaunch, exit 1 stays
   down, the 21st exit 75 / 51st exit 77 in 24 h ⇒ storm and the supervisor's `/healthz`
   503.
2. **Writes.** 8, 9, 10, drain-and-rebuild. **Done when:** REST ops appear at the peer and
   in its next snapshot; **parity test in the app's vitest**: harness `Device`s and a
   headless executor from the same template bytes, seeded `randomUUID`, `setClock`, FX
   stub, same op sequence incl. a continuous rule ⇒ equal `{op, args}`, `v` via
   `mutationFormatVersion` on both sides, equal `dumpDb`; write crash points
   (`after_ledger_intent`, `after_ledger_queued_before_rename`,
   `after_outbox_add_before_send`, `after_send_before_ack`, `in_dequeuing_save`) then retry
   with the same key ⇒ the server log grew by exactly the expected entries since the
   pre-test version (`GET /sync/mutations?space_id&before&limit≤100`) and their decrypted
   `{op, args}` equal the ledger entries; same key twice concurrently ⇒ one mutation; proxy
   holds the headless's frame until a peer mutation is acked ⇒ `reordered: true`, exit 75,
   `dumpDb` equal after; proxy holds only a follow-up ⇒ `reordered`; proxy injects
   `storage_error` nack ⇒ 202 then one log entry; injected `invalid` nack ⇒
   `outbox_blocked` across a restart, admin drop removes primary **and** follow-ups, then
   409; a `rules.execute` that throws ⇒ 200 `rules_failed`, retry ⇒ 200, log grew by 1; a
   throwing primary (`addTransfer` with equal accounts) ⇒ 422 and exit 76; 6 such in 10 min
   ⇒ 429; `GET /exchange-rates` joins the allowlist with a multi-currency write; a bench server
   with a short `SELF_HOST_JWT_TTL_HOURS` ⇒ the token is refreshed without a halt; every
   argument guard has a rejecting test.
3. **Deploy.** NAS upgrade to v1.22.1 (blob + DB backup first); image built and mirrored;
   manifest service; reachability from the Ambrogio container; `APP_VERSION` not set on the
   NAS; verify `lzcinit` forwards TERM, that `health_check.start_period` is honoured, and
   what Lazycat does with an unhealthy secondary service. Real space **read-only until** 7
   days in which `rebuilds.log` holds no code outside 75/76/77, `halts.log` is empty,
   `rebuilds_24h`/`restores_24h` stay under budget, and `/v1/months/{current}` matches the
   web app on 3 spot checks; then `readOnly: false`.
4. **Ambrogio adapter** — separate project in the Ambrogio repo.

## 13. Risks

- Space corruption through the log: mitigated by the app's own pipeline (U6), payload
  parity, argument schemas, the throwaway space, read-only first. Through snapshots:
  impossible (no upload path, proven by the proxy allowlist).
- Residual Budgero semantics: the lost-update race between two devices editing the same
  absolute value at the same time; identical in the web app.
- Rebuild frequency: one per restore (every reconnect after a phone upload), per reordered
  write, per failed write. Ambrogio writes a few times a day; `rebuilds_24h`/`restores_24h`
  show if the budgets are wrong.
- Availability: a halt or storm makes the headless 503 until the operator acts; Ambrogio
  must handle 503 (milestone 4).
- Upstream churn: pin to a tag; server and headless upgrade together; U1–U4, U6 carried as
  a patch stack until upstream takes them (#155).

## 14. Left to the builder

esbuild alias set; exact JSON layout of `outbox.json`/`ledger.json`; read response field
names (milliunits); router choice; supervisor script details beyond the trap and budgets.
