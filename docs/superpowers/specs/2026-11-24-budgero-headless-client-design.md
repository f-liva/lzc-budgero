# Budgero headless client — design

Date: 24/11/2026. Status: draft v7, after review rounds 1–6 (twelve adversarial reviewers;
every critical/important finding verified in code and folded in below).
Upstream proposal: https://github.com/tombadilo-bombadilo/budgero/issues/155 (no answer yet; we start anyway).
Code references and the pin: upstream tag **v1.22.1 = `e40723e`** (also master HEAD on 24/11).

**What changed in v6 and why.** Rounds 1–5 kept finding crash windows in which the
headless's local SQLite could end up with a doubled, missing or half-applied row. Three
schemes to close them failed (own ordering rules in v3, transactional sync state in v4,
"reproduce the browser exactly" in v5): the runtime persists DB, cursor, applied ids and
outbox in separate steps, and any Node client inherits every one of those windows. They
only matter because of one thing: **the headless would upload snapshots**, turning a
local glitch into every device's data. v6 removes that: the headless **never uploads a
snapshot**, keeps its DB **in memory only** and rebuilds it from the server at every
start. The server's mutation log is never pruned (`mutations.go:420-427`: only an explicit
space reset deletes it), so a fresh bootstrap is always possible. Writes are
acknowledged to the caller **only after the server acks the mutation**. Local durability
is reduced to two small files, the outbox and the idempotency ledger.

Round 6 added the last piece: a wrong in-memory DB can still reach other devices
**through the arguments of the next write** (move money and `upsertAssignment` send
absolute totals computed locally). So the headless must never be `live` with a DB that
is not exactly snapshot + log in server order: it accepts only a clean server bootstrap,
and whenever it had to replay its own outbox it drains the outbox and **bootstraps a
second time** before serving.

## Why

Budgero is end-to-end encrypted and local-first: the Go server stores only ciphertext
(snapshot blob + mutation log), every real client (the web app) holds the space key,
keeps a decrypted SQLite and applies mutations itself. The only integration surface
today is the Push API: write-only, transactions only, and applied by a browser *when
someone opens the app* (`AppRuntime.processPushQueue`, run at startup or by hand).

Ambrogio works around it by downloading the blob, decrypting it and decoding LZ4 by
hand (`ambrogio/src/budgeting/budgero-sync.ts`). That is read-only, as stale as the
last snapshot upload, and broke on 23/11/2026 when the snapshot outgrew one LZ4 block.

We want a client that is a peer of the web app, without a UI, exposing a REST API to
read everything and run the operations we allow. First consumer: Ambrogio. Later: the
native Android app (separate project) may reuse the same pieces.

## Goals

1. Joins one space as a regular client: snapshot + catch-up at start, then the live
   mutation stream; in-memory decrypted SQLite always current.
2. REST API, bearer-token protected: reads of everything; writes through an explicit op
   allowlist (see Op policy); sync status.
3. Writes are real mutations in the server log: other open clients see them immediately;
   the caller gets 200 only once the server has acked.
4. Crash-safe in the only way that matters: **nothing the headless does locally can reach
   another device**, because it never uploads a snapshot; its own state is rebuilt from
   the server at every start.
5. Ships as an optional second service of the `lzc-budgero` Lazycat package, built from
   the same upstream tag as the server.

## Non-goals

- No UI. One process = one space, one budget, one user.
- No SaaS (Clerk auth): self-host local login only.
- No master-password change, key rotation, sharing/invites, file imports, bank sync,
  chat/LLM. A key or password change stops the client (see Halting).
- No public exposure: Lazycat internal network only.
- **No snapshot uploads, ever.** The browser/phone clients keep uploading them.
- **Push API queue processing is out of scope until upstream has an atomic claim**
  (see U5). The browser keeps doing it.

## Anti-goals (failure even if it "works")

- **Corrupting the space for other devices.** The only channel left is the mutation log:
  a mutation the headless sends must be exactly what the app would have sent (same op
  semantics, same emitted format).
- Reimplementing op logic. We execute the app's own registry through the app's own
  pipeline (U6).
- Silent version drift: emitting or applying mutations under a different format than
  the app at the same tag.
- Creating, uploading or rotating a space key; holding the key outside this process and
  its secret file.
- Telling the caller "done" for a write the server never received.

## Constraints (verified in code)

- `@budgero/core` and `@budgero/runtime` are workspace-private, plain `tsc`; runtime uses
  extensionless imports with bundler resolution → **we bundle with esbuild**.
- Op registry: `packages/app/src/shared/mutations/op-code-registry*`. Non-test imports:
  `@budgero/core/browser`, `@budgero/runtime`, Lingui macro, `@shared/runtime/global`.
  `S()` is `getRuntime()!.services()` (`op-code-registry/shared.ts:277`);
  `withLegacyFormat` reads services through a try/catch that turns failure into `null`
  and then emits the **older** format (`legacy-format.ts:266-272`, `:240`).
- `RuntimeCoordinator` builds its own `KeyVault` (`runtime-coordinator.ts:83`); startup
  requires the master password (`runtime-lifecycle-service.ts:61`), derives the local
  persistence cipher from it (`:64, 94, 183`), runs `ensureSpaceKeys` on every accepted
  space and, for an owner without a wrapped key, **generates and uploads a new key**
  (`key-vault.ts:223-233`); it activates `primary_space_id`, not a configured one.
- The stock coordinator handles out-of-band uploads, post-restore migrations and
  catch-up correctly (`runtime-coordinator.ts:540-635, 656-712`); the 409 path in
  `DatabaseSync` restores without migrations/catch-up (`database-sync.ts:259`), which we
  never reach (no uploads ⇒ no 409).
- Activation with no stored cursor/DB takes the snapshot path, then
  `reapplyQueueAfterRestore` (marks queued ids in-flight, so catch-up skips them), then
  connects and catches up (`space-activation-service.ts:272-391`).
- `persistDatabase` returns `false` for an adapter without `forceSave`, which disables
  cursor/applied-id persistence to localStorage (`persist-database.ts:8-18`,
  `sync-transport.ts:1683-1689`); in-memory `localVersion` still advances. That is the
  behaviour we want.
- Mutation ids: `spec.mutationId || spec.idempotencyKey || generate()`; a `mutationId`
  makes the executor a *receiver* that never queues/sends and skips `prepareMutationArgs`
  (`mutation-executor.ts:69-71`, `mutation-dispatch-service.ts:55-58`,
  `app-runtime.ts:236-239`). The server dedups by id and keeps the first
  (`websocket/mutations.go:124-138`); the id is TEXT with no format check.
- Dispatch: execute → `offlineQueue.add` (durable) → send → ack dequeues → cursor
  advances (`mutation-dispatch-service.ts:48-114`, `sync-transport.ts:900-937`).
- `executeMutationOp` has no transaction (`op-code-registry.ts:314-319`): a throwing op
  leaves partial writes in memory.
- Catch-up failure twice ⇒ quarantine, cursor moves past it (`sync-transport.ts:1226-1240,
  1400-1419`); first failure triggers a snapshot fallback (`:1244`).
- Key/password change handlers don't stop the transport (`sync-transport.ts:1011-1031,
  1733-1762`); the outbox stores prepared args in plaintext, encrypted at send time.
- Blob download headers are load-bearing: without `X-Budgero-Protocol` 426
  (`sync.go:568`); `X-Mutation-Version` on the response is the bound cursor.
- WebSocket: `WEBSOCKET_ALLOWED_ORIGINS` is set in our manifest, so `Origin` must match
  exactly (`websocket.go:79-92`); URL needs `token`, `space_id`, `protocol`,
  `client_session` (`sync-transport.ts:1785-1792`, `websocket.go:186-197`). Client-sent
  frame types: `mutation`, `increment_encryption_key_version`,
  `master_password_changed`, `catch_up_request` (`:539, 587, 1001, 1433`).
- Push queue on the server: plain SELECT of pending + unconditional status UPDATE, no
  claim (`queries/push.sql`).
- Month figures come from core (`monthlyBudgets.getMonthlyBudget`,
  `getReadyToAssignBreakdown`, same as the app's `useMonthlyBudget`) and use the process
  time zone.
- Server version: `GET /api/v1/version/latest` → `build_version` (`APP_VERSION` env, else
  `package.json`, else embedded `version.txt`; can be `unknown`, `appmeta/version.go:68-105`).
- Self-host JWT TTL: manifest sets `SELF_HOST_JWT_TTL_HOURS=720`.
- Server mutation log is never pruned (`mutations.go:420-427`, only `ResetSpace`).

## Approaches considered

| | What | Verdict |
|---|---|---|
| **A. Full client in the fork, cache-only** | `packages/headless` runs the stock coordinator + registry + core; DB in memory, rebuilt from the server at every start; never uploads | **Chosen** (v6) |
| A′. Full client with persisted DB and snapshot uploads | v2–v5 | Rejected after 5 review rounds: every multi-step persistence window becomes every device's problem |
| B. Snapshot read + Push API write | Package what Ambrogio does as REST | Rejected: writes wait for a browser, transactions only |
| C. Hand-crafted mutations | Build op payloads ourselves | Rejected: first divergence from `prepareMutationArgs` corrupts the space |

Within A, bypassing the coordinator was rejected (it is what handles out-of-band blobs,
post-restore migrations and catch-up correctly); we keep it and add injection points
(U1–U3, U6).

## Design

### Where the code lives

- Fork `f-liva/budgero` (`~/Progetti/budgero`; remotes `origin` = upstream,
  `f-liva-fork` = ours). Branch `feat/headless-client` from the pinned tag.
- `packages/headless` (TypeScript, Node 22). Upstream changes are separate commits, each
  upstreamable on its own.
- Deployment in `lzc-budgero` (Docker stage, manifest service, docs).

### Upstream changes (in the fork, one commit each)

- **U1 — external space key.** `RuntimeCoordinatorDeps.spaceKeySource?: { spaceId, key }`.
  When set: the coordinator's `KeyVault` returns that key for that space and throws for
  any other; never unwraps, never generates, never uploads (`uploadEncryptedKey` is never
  passed, in any mode); lifecycle doesn't require the master password and the local
  persistence cipher is disabled at all three sites (`runtime-lifecycle-service.ts:64, 94,
  183`); key version read from the shim-backed `MasterPasswordStore`
  (`master-password-store.ts:184-199`); `ensureSpaceKeys` runs only for that space and
  activation targets it instead of `primary_space_id`.
- **U2 — injected queue storage.** `runtime-context-factory.ts:201` passes a
  `QueueStorage` from deps to `new OfflineQueue(spaceId, storage)` (constructor already
  accepts it, `offline-queue.ts:56`); export `deserializeMutation`
  (`offline-queue/storage.ts:40`).
- **U3 — hooks.**
  - `allowUpload?: () => boolean`, ANDed with the existing `DatabaseSyncDeps.canUploadSnapshot`
    (`runtime-context-factory.ts:173-174`), checked inside `doUpload` immediately before
    `uploadBlob` (`database-sync.ts:330`; the existing check at `:199` is skipped for
    out-of-band uploads, this one is not). The headless passes `() => false` **always**;
    the `uploadBlob` dependency is a stub that rejects with a typed `UploadDisabledError`
    handled as a no-op (not surfaced as `snapshot_upload_failed`), as a second fence;
    `replayQueueViaSync` calls `dbSync.upload()` on every reconnect
    (`reconnection-service.ts:~313`), so both fences are exercised.
  - `onRemoteApplyFailed?(mutation, error)`, called at the top of both catch blocks
    (catch-up `sync-transport.ts:1226-1244`, live `:1097-1107`) **before** any cursor move,
    quarantine or snapshot fallback.
  - `onMutationNacked?(mutationId, reason)` from `handleMutationNack`
    (`sync-transport.ts:974`, id = `msg.id ?? msg.mutationId`). Acks need no hook: the
    headless's `QueueStorage` observes dequeues (see Durability); the existing
    `onMutationAck` dependency (`interfaces.ts:161`) is already wired to `ackMutation`.
  - `RuntimeCoordinator.halt(reason)`: stops sync, reconnection and connectivity, clears
    the coordinator timers (`remoteBlobRetryTimer`, `runtime-coordinator.ts:635-638`),
    makes `upload`/`downloadAndRestore` no-ops behind a halted flag. No flush: there is
    nothing to flush (in-memory DB).
- **U4 — listed for upstream only, not used here.** 409 restore = full restore
  (`DatabaseSync` conflict path runs migrations + `reconcileSpaceScope` + `requestCatchUp`).
  The headless never uploads, so it never hits 409; the change is still worth sending
  upstream with #155.
- **U5 — atomic push claim** (server): `UPDATE push_queue SET status='processing' WHERE
  id=? AND status='pending'`, rows affected = 1, plus the app using it. Prerequisite for
  any future headless push processing; not built in this project.
- **U6 — shared mutation pipeline.** Move `executeMutation`'s pure parts out of
  `AppRuntime` (`app-runtime.ts:72-82, 136-151, 232-270, 760-904, 906-1155`: prepare,
  continuous-rules post-hook, `recordHistory`, `resolveHistoryBudgetId`) into a module
  without analytics/toast imports, used by both `AppRuntime` and the headless.
  Analytics/first-steps calls stay in `AppRuntime` as hooks. No copy of app logic lives
  in `packages/headless`.

### Durability (cache-only model)

What survives a restart: `outbox.json`, `ledger.json`, config. Nothing else.

- **DB in memory** (`NodeSqlJsAdapter`, no `forceSave`), discarded on exit.
- **`storage.ts`** — in-memory `localStorage` shim, reset at every start (client session
  id, key version, flags). Never read across runs.
- **`queue-storage.ts`** — `QueueStorage` (U2) in `outbox.json`: temp + fsync + rename;
  `save` resolves after fsync (dispatch awaits it before sending,
  `mutation-dispatch-service.ts:76`). **One promise chain per file**, content snapshotted
  at call time, unique temp names (the web adapter serialises for the same reason,
  `web-adapter.ts:555-566`). The wrapper also notices ids that *disappear* from the queue
  between saves: that is the only place an entry leaves the queue
  (`OfflineQueue.ackMutation`, `offline-queue.ts:154-166`), reached both by `mutation_ack`
  and by the implicit ack when our own mutation comes back via catch-up/broadcast
  (`runtime-lifecycle-service.ts:196-201`), and it is what the write path waits on.
- **`ledger.ts`** — `ledger.json`, same write discipline, same chain rule (see Writes).

**Bootstrap invariant: `live` only with DB = snapshot + log in server order.**
1. Activation runs the stock path with `hasLocalDatabase: async () => false` and no stored
   cursor: snapshot download → `createDatabase` → `reapplyQueueAfterRestore` → connect →
   catch-up (`space-activation-service.ts:272-391`).
2. The `onActivated` outcome (`:95-115`) must be `server_snapshot`; `fresh` is accepted
   only when the blob download answered 404 (new space). Anything else (download error ⇒
   upstream silently continues on an **empty** DB, `:310-322`; local fallback; decryption
   error) ⇒ **halt**. Status `bootstrapping` until catch-up has settled.
3. If the outbox was non-empty at start, the reapplied entries were applied **before**
   catch-up, i.e. out of server order (`:363-377`); the DB may differ from every other
   device. So: wait until the outbox drains (every entry acked or nacked), then **discard
   the DB and bootstrap again** with an empty outbox. Only the second bootstrap goes
   `live`. A nacked entry never drains: see Nack.
4. Any live restore (catch-up fallback, out-of-band blob) followed by an outbox reapply
   triggers the same drain-and-rebuild before writes are accepted again.
5. A local `execute` that throws leaves partial writes (`op-code-registry.ts:314-319`) ⇒
   **halt** (the DB is no longer snapshot + log).

With that invariant, a startup "reconciliation" of the outbox against `mutation_history`
is unnecessary and is **not** done (there is no hook before `reapplyQueueAfterRestore`
anyway, and `mutation_history` is capped at ~500/budget and gated on a resolvable
budget id, so it proves nothing). Double application of an acked-but-not-dequeued entry
during the first bootstrap is harmless: that DB is thrown away.

Why this is enough: nothing the headless does locally can reach another device except
through the mutations it sends; those are produced by the app's own pipeline (U6) from
guarded args against a DB that is, by construction, what every other device has.

### Platform pieces (packages/headless/src/platform)

- `storage.ts`, `queue-storage.ts`, `database.ts` (bare `NodeSqlJsAdapter`, wasm by
  explicit path, failure logs redacted) — see Durability.
- `http.ts` — port of the app's `blobApi` (download + `getDatabaseState` only; **no
  upload function exists in the headless**) and `spacesApi`, without Clerk/zustand/env:
  headers `X-Budgero-Protocol`, `X-Client-Session`, bearer; reads `X-Mutation-Version`,
  `X-Encryption-Key-Version`, `X-Data-Format-Version` from the download; `downloadBlob`
  null only on 404. Base URL also for core's relative FX path. Contract test against the
  app's `api-client.ts` at the pin.
- `websocket.ts` — `globalThis.WebSocket` shim (`ws` package) sending
  `Origin: $BUDGERO_ORIGIN` (must equal the server's `WEBSOCKET_ALLOWED_ORIGINS`, which the
  manifest sets to `https://${LAZYCAT_APP_DOMAIN}`, `lzc-manifest.yml:44`; exact compare,
  `websocket.go:78-91`); `getWebSocketUrl` builds `token`, `space_id`,
  `protocol=SYNC_PROTOCOL_VERSION`, `client_session`. **Outbound frame allowlist**:
  `catch_up_request` always; `mutation` only when `readOnly` is false; the two key/password
  frames never. Tests assert URL and allowlist.
- `global.ts` — replacement for `@shared/runtime/global` exposing **full** `services()`,
  `mutationsRouter()` and the `mutationHistory` id-reuse API; startup fails if any is
  missing (prevents `withLegacyFormat` silently downgrading formats).
- `lingui.ts` — stub for `@lingui/core/macro` (`t`/`msg` → interpolated English source).
- Logging through a redactor (no args/params, no tokens).

### Client pieces (packages/headless/src/client)

- `auth.ts` — `POST /api/v1/auth/local/login`; re-login before expiry and on 401.
- `runtime.ts` — stock `RuntimeCoordinator` with U1–U3 deps (`spaceKeySource`, queue
  storage, `allowUpload`, `onRemoteApplyFailed`, `onMutationNacked`, `getWebSocketUrl`,
  `hasLocalDatabase: async () => false`, `onActivated` (bootstrap invariant), `reloadApp`
  and key/password-change callbacks wired to Halting). Version check before activation.
- `execute.ts` — calls the U6 shared pipeline; nothing copied from the app. The op policy
  gates **REST entry only**: ops the pipeline issues itself (continuous-rules
  `rules.execute` after `transactions.add` / `addTransfer`, `app-runtime.ts:760-904`) are
  expected and not blocked.
- `writes.ts` — **one write at a time** (global async lock); writes return 503 while
  status is not `live` (bootstrapping, draining, halted) or while the outbox holds a
  nacked entry. Flow per op:
  1. policy + argument guards (below);
  2. ledger record `intent` (see `ledger.ts`), with a fresh random **nonce**;
  3. `execute` with `spec.idempotencyKey = opId` (never `mutationId`): prepare → apply →
     `outbox.add` (fsync) → send; the `QueueStorage` wrapper records `queued` with the
     prepared payload when the id first appears in a save;
  4. wait for the dequeue of `opId` (timeout 30 s). Dequeue ⇒ ledger `acked` + result ⇒
     **200**. Timeout ⇒ **202 `{status:"pending", mutationId}`**, caller polls
     `GET /v1/mutations/{id}`. Nack ⇒ ledger `nacked`, **409**, writes blocked.
  The `acked` ledger write happens inside the `QueueStorage.save` that removes the id,
  **before** that save resolves, so a crash can't leave "dequeued but not acked" on disk.
- `ledger.ts` — `ledger.json`. Record per `Idempotency-Key`: `{key, bodyHash, nonce,
  ops: [{opId, state: intent|queued|acked|nacked, payload?, result?}]}`. Op ids are
  `'hdl_' + sha256(nonce + '#' + i)`: never derived from the key alone (a key reused after
  the record expired would otherwise collide with an id the server already has, be acked
  as a no-op, and the write would be lost silently, `mutations.go:124-138`,
  `sync-transport.ts:1044`). One request may issue several ops (a `PATCH` of n fields = n
  `updateColumn` ops). On a request:
  - no record ⇒ proceed;
  - record with a different `bodyHash` ⇒ **422**;
  - all ops `acked` ⇒ 200 with stored results;
  - an op `queued` (payload stored) ⇒ it is in the outbox or was dequeued without the
    ledger write (impossible by the ordering above, but handled): if in the outbox, wait
    for its dequeue; if not, treat as acked;
  - an op `intent` only (crash before `outbox.add`) ⇒ it never reached the server:
    execute again with the **same opId**; `prepare` runs again, which is correct because
    the server has nothing under that id;
  - a `nacked` op ⇒ 409.
  `mutation_history` is never used as evidence of anything. Records are kept 30 days;
  a key that expired is a new key (new nonce, new ids), which is safe because the ids
  differ. Known gap, documented: continuous-rules follow-ups have their own random ids;
  a crash between the primary op's `outbox.add` and the follow-ups' `outbox.add`
  (`app-runtime.ts:243-253`) means a retry returns the stored result and the rules don't
  run.
- Nack: `onMutationNacked` ⇒ ledger `nacked`, writes 503 `outbox_blocked`, reads `stale`,
  `/v1/status.outbox_divergent = true`. Upstream keeps the entry queued and resends it
  every 20 s (`getStale` + `resendSweep`), so it would be re-executed locally at every
  start. Operator action: `POST /v1/admin/outbox/{id}/drop` (bearer with `admin` role in
  `tokens`) removes it from `outbox.json`; the next restart rebuilds a clean DB.
- `GET /v1/mutations/{id}` — `pending|acked|nacked|unknown` from the ledger + outbox.

### Read-only is structural

`readOnly: true` (milestone 1, and the first days in production): the REST layer has no
write routes, the WebSocket shim rejects `mutation` frames, `allowUpload` is `() => false`
and `uploadBlob` is the rejecting stub. In write mode only the first two change. A
leftover outbox in read-only mode would be reapplied and resent at start, and the shim's
throw would close the socket in a loop (`sync-transport.ts:549-560`): read-only therefore
refuses to start with a non-empty `outbox.json` (status `halted:outbox_in_readonly`). A test sends
every frame type in read-only mode and expects a throw for all but `catch_up_request`.

### Halting

Triggers: `FormatTooNewError`, `UnknownOpCodeError`, HTTP 426, `onRemoteApplyFailed`, key
or password change, server version ≠ bundled version or `build_version`
`unknown`/unparsable (checked before activation and on every reconnect via
`GET /api/v1/version/latest`, compared to `package.json` of the pinned tag). Action:
`coordinator.halt(reason)` (U3); `/v1/status` = `halted:<reason>`; **reads and writes
return 503** (the in-memory DB may be half-applied or stale, and there is no "last good
file" to fall back to). Restart only by operator action: a container restart rebuilds
from the server. Never auto-reload, never re-key.

Reads report `stale: true` until the initial catch-up has settled. Reads are not
serialised with remote applies: a read can observe an op mid-apply; acceptable for
Ambrogio, stated in the API docs.

### Op policy (Federico, 24/11: allowlist + key for destructive)

`api/op-policy.ts` lists **exact registry op names** at the pinned tag in three tiers;
everything not listed returns 403, including ops a future release adds. A test fails if
a listed name isn't in `KNOWN_OP_CODES` and prints registry ops not in any tier.

- `allowed`, exact names at v1.22.1:
  - transactions: `transactions.add` (with or without `splits`), `transactions.addTransfer`,
    `transactions.updateColumn` (columns `outflowconverted`, `inflowconverted`,
    `categoryid`, `memo`, `date`, `payee`; **not** `cleared`, which core rejects,
    `core/.../transactions/index.ts:2645`), `transactions.delete`,
    `transactions.setCleared` (exactly one id), `transactions.saveSplits`;
  - money: `monthlyBudgets.upsertAssignment` (one category, one month); moving money
    goes through `POST /v1/months/{m}/move` (below), never through a generic op;
  - categories: `categories.create`, `categories.updateName`, `categoryGroups.create`,
    `categoryGroups.update`, `categories.moveToNewGroup`;
  - accounts: `accounts.create`, `accounts.update` (guarded, see below),
    `accounts.setArchived`;
  - payees and recurring: `payees.add`, `recurring.create`, `recurring.update`.
  Decided closed (not needed by Ambrogio, revisit on request): reorder ops (whole ordered
  id list), `transactions.moveToNewCategory`/`moveToNewAccount`, transfer edit/delete
  ops, `monthlyBudgets.updateAssignment`, `monthlyBudgets.reassignAssignment` (a legacy
  category-delete step that merges a category's whole assignment history into another,
  `core/.../monthly-budgets/queries.ts:285-310`).
- `destructive` (only with `allowDestructive: true`): `budgets.delete`, `accounts.delete`,
  `transactions.deleteBatch`, `transactions.batchEdit`, `transactions.reassign`,
  `transactions.reconcile`, `transactions.deleteByRef`, `payees.rename` (renames every row
  and **merges** into an existing payee, `payees.ts:56-72`), `payees.deleteMany`,
  `payees.removeUnused`, `categories.deleteAndReassign`, `categoryGroups.delete`,
  `categoryGroups.deleteAndReassign`, `monthlyBudgets.batchUpsertAssignments` (generic),
  `rules.create`, `rules.update` (actions carry nested `categoryId`/`accountId` applied with
  no budget check, `core/src/services/rules/index.ts:1657-1700`, then run on every add),
  `rules.execute` (only with non-empty `options.transactionIds`, max 500).
- closed: `history.applyOps`, `history.redoWithIds`, `history.restoreRows` (they wrap
  arbitrary ops/rows), `transactions.import`, `importHistory.*`, `bankSync.*`, `chat.*`,
  `llmSettings.*`, and anything unlisted.

**Per-op argument schema** in `op-policy.ts` (unknown keys rejected), with the real key
names of each op at the pin:
- always rejected: `mutationId`, `meta`, `idempotencyKey`, `opClock` (a caller clock
  backdates the op on every device, `op-code-registry.ts:222, 247-250`);
- create ops: caller `id` rejected (`transactions.add`, `categories.create`,
  `categoryGroups.create`, `accounts.create`, `recurring.create`'s `input.id`,
  `addTransfer`'s `source.id`/`destination.id`); `transactions.add` rejects a non-empty
  `transferId` (joins an existing transfer, `core/.../transactions/index.ts:490`) and
  `importIdentities` (returns an existing row, `transactions.ts:745-750`);
- `addTransfer`: `transferId` is required by the op (`transactions.ts:833`) and generated
  by the headless, stored in the idempotency record so a retry reuses it;
- **every** id reference validated against `budgetId`, target ids included: `id`/`ids`
  of `updateColumn`, `delete`, `setCleared` (`ids[]`, `transactions.ts:1592`),
  `saveSplits`, `categories.updateName`, `categoryGroups.update`, `accounts.update`/
  `setArchived`, `recurring.update`; `categories.create`'s `parentId`
  (`domains/categories.ts:222`); `moveToNewGroup`'s `categoryId`; recurring `toAccountId`
  and `splits[].categoryId/transferAccountId` (`recurring/types.ts:33-41, 84-115`);
  `accountId`, `categoryId`, `transactions.add`'s `splits[].categoryId`/`splits[].transferAccountId`
  (camelCase, `transactions.ts:620-667`), `saveSplits` lines (`category_id`,
  `transfer_account_id`, snake_case, `shared.ts:125-146`; `mirror`/`Mirror`/`pair_id`/
  `PairID` rejected; PascalCase `CategoryID`/`TransferAccountID` also accepted by core,
  `shared.ts:129-141`, so the line schema is closed), `addTransfer`'s `source.accountId`/`destination.accountId`,
  `moveToNewGroup`'s `newGroupId`, recurring `input.*`/`patch.*` ids, `updateColumn`'s
  `newValue` when the column is `categoryid`; `updateColumn` args are `{id, columnName,
  newValue}` (`exchangeRateOverride` rejected), `columnName` normalised like core
  (lowercase, `_` stripped, legacy `inflow`/`outflow` accepted,
  `core/.../transactions/index.ts:2440-2465`), integer `newValue` required on id columns;
- `budgetId` forced on the ops whose args carry one, nested paths included
  (`recurring.create` → `input.budgetId`, each `batchUpsertAssignments` entry);
- `accounts.update`: core keeps current values for empty `name`/`type`/`currency` and
  leaves `metadata`/`onBudget` alone when undefined, preserving system keys
  (`core/.../accounts/index.ts:447-449, 484-498`, `queries.ts:150-158`). The guard accepts
  **`name` only**; `type` and `currency` are sent from the current row; `metadata`,
  `onBudget`, `linked_category_id`, `cc_payment_category_id`, `debt_total`,
  `paid_so_far`, `currencyRates` (`accounts.ts:152`) are rejected;
- `payees.add`: `{budgetId, name}` (`domains/payees.ts:43`), `budgetId` forced.

All names above were checked against the registry at v1.22.1 (review rounds 4–5); the
policy test re-checks them on every upgrade.

### Config (files under `/lzcapp/var/headless`, no file ⇒ idle)

`config.json` (non-secret): `url` (`http://budgero.cloud.lazycat.app.budgero.lzcapp:3001`),
`user`, `spaceId`, `budgetId`, `readOnly`, `allowDestructive`, `port` (8787).
Secret files, mode 600: `password`, `space.key` (raw base64, from Settings → Push API →
export), `tokens` (one bearer per consumer, one per line, `name:token`).
With no `config.json` the service idles, `/v1/status` says `not_configured`, and it never
contacts the server. `TZ=Europe/Rome` and `BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}`
come from the manifest (the same value the server's `WEBSOCKET_ALLOWED_ORIGINS` uses).
These two are the **only** environment inputs. `local.env` is not used (build-time
substitution, not runtime config).

### REST API (v1)

Bearer from `tokens`, constant-time compare; token never echoed. Amounts in integer
milliunits.

- `GET /v1/status` — `not_configured|bootstrapping|draining|live|halted`, halted reason,
  cursor, stale, outbox size, `outbox_divergent`, versions. No secrets.
- `GET /v1/accounts`, `/v1/category-groups`, `/v1/categories`, `/v1/payees`,
  `/v1/transactions?account=&category=&payee=&since=&until=&cleared=&limit=&offset=`,
  `/v1/transactions/{id}`, `/v1/months/{YYYY-MM}` (assigned/activity/available per
  category, Ready to Assign), `/v1/recurring` — via core services, scoped to `budgetId`.
- `GET /v1/ops` — op policy: name, tier, format version (from `KNOWN_OP_CODES` +
  `OP_CODE_FORMAT_VERSIONS`).
- `POST /v1/ops/{op}` — one op; guarded args → execute → ack → `{result, mutationId}`;
  `Idempotency-Key` required. 200 / 202 pending / 409 nacked / 422 key reuse.
- `GET /v1/mutations/{id}` — ledger state of a mutation.
- Convenience wrappers (each documents how many ops it issues): `POST /v1/transactions`
  (1), `PATCH /v1/transactions/{id}` (one `updateColumn` per field; `cleared` →
  `setCleared`), `DELETE /v1/transactions/{id}` (1), `POST /v1/transfers` (1,
  `transferId` generated), `PUT /v1/months/{YYYY-MM}/categories/{id}/assigned` (1).
- `PUT /v1/months/{YYYY-MM}/categories/{id}/assigned {amount}` → `upsertAssignment`, with
  the app's checks (`useCategoryOperations.ts:304-352`): over-assign against
  `getReadyToAssign` rejected unless `allowOverAssign: true`; a decrease that causes
  overspending (`monthlyBudgets.checkFutureOverspending`,
  `core/.../monthly-budgets/index.ts:510`) rejected unless `allowOverspend: true`.
- `POST /v1/months/{YYYY-MM}/move {from: id | "rta", to: id | "rta", amount}` — the app's
  move money (`useCategoryOperations.ts:380-447`): `amount > 0`, `from ≠ to`; `from` a
  category ⇒ its available must be > 0 and the amount is clamped to it; one
  `batchUpsertAssignments` with two entries (`from` and `to` absolute totals read from the
  month rows), one entry when either side is `rta` (from `rta` = plain assignment to
  `to`, as the app does); each entry's `budgetId` forced, ids validated; same
  over-assign/overspend checks as above. Allowed tier; the generic op stays destructive.

## Decisions settled during review (Claude's calls, correctable)

- **One budget** via `budgetId`; every route and op forced to it.
- **Reachability**: Ambrogio calls `http://headless.cloud.lazycat.app.budgero.lzcapp:8787`
  over the Lazycat internal network (cloudflared, another app, already reaches other apps'
  `*.lzcapp` names); no ingress, no tunnel. To verify in milestone 3.
- **Store package**: service optional, idle without config.
- **Version**: pin v1.22.1 = `e40723e`; NAS (v1.21.5) upgraded to that tag in milestone 3
  after a blob + DB backup (one-way migrations). Headless refuses to run against a
  different server version.
- **Push queue**: not processed by the headless (needs U5).
- **Never upload**: the headless is a consumer of snapshots, never a producer. If one day
  it is the only writer for a long time, other devices' catch-up grows (gap > 200 ⇒ they
  take the snapshot path + catch-up from the blob bound), which is slower but correct; the
  log is never pruned.

## Milestones

1. **Read-only client + test bench.** U1, U2, U3, U6 + platform pieces + read routes +
   bootstrap invariant + Halting, plus the bench:
   - local server `docker run budgero/budgero:v1.22.1` with `WEBSOCKET_ALLOWED_ORIGINS`
     set (otherwise self-host accepts any origin and the Origin contract is never
     exercised); `POST /api/v1/auth/local/register`;
   - `bench/create-space.ts`: test-only Node script: register, `POST /budget-spaces`,
     generate/wrap/upload the key with the runtime's `KeyVault`
     (`PUT /budget-spaces/:id/members/me/encrypted-key`), run `budgets.create`, write the
     raw key and budget id for the headless. The headless itself never creates keys;
   - `bench/peer.ts`: a second client (stock coordinator + same platform pieces, **with**
     uploads, standing in for the web app) writing through the real server;
   - crash harness (read-only points only): kill during snapshot download, during
     `createDatabase`, between activation and catch-up settled, on WS message received
     before apply. Headless as a child process, `SIGKILL` at point k for every k, then
     100 random kills. Oracle after each restart: status reaches `live`, and the headless
     DB equals the peer's on **comparable tables**: every table except
     `mutation_history` (compared as a set of `MutationID`s) and except columns stamped
     with `datetime('now')` at apply time (`recurring.UpdatedAt/ReadyAt/NotifiedAt`,
     `currency_rates.CreatedAt`, transaction label `UpdatedAt`; the exact list is produced
     by a grep for `datetime('now')` in core at the pin and kept in the test);
   - fault injection for the bootstrap invariant: blob download forced to fail ⇒ halt
     (not an empty `live` DB); a quarantine-triggering remote mutation (test hook on
     `onRemoteApplyFailed`'s input: a crafted encrypted mutation with an op the registry
     rejects) ⇒ halt before any cursor move.
   Done when: a peer write appears in `GET /v1/transactions` within 5 s; a restart
   rebuilds from the server and reaches `live`; month numbers equal the peer's core
   figures for 3 months; every crash point and the random kills pass the oracle; an
   out-of-band upload from the peer converges on the headless; the two fault injections
   halt; header, WS URL and outbound-frame contract tests pass; **no HTTP call to
   `POST /database/blob`** ever leaves the headless (recorded by a proxy in the bench
   across the whole milestone run).
2. **Writes.** `writes.ts`, `ledger.ts`, op policy + argument schemas, write routes,
   money endpoints, drain-and-rebuild.
   Done when, on the bench: REST ops appear at the peer and the peer's next snapshot
   includes them; **parity test in the app's vitest** (the fuzz harness uses
   `vi.stubGlobal` and a mocked `@shared/runtime/global`, so it can't run against the
   esbuild bundle; headless sources aliased in): harness `Device`s and a headless executor
   from the same template bytes, `globalThis.crypto.randomUUID` stubbed with the same
   seeded sequence, `setClock`, FX stub; same op sequence (including a continuous rule) ⇒
   equal `{op, args}`, `v` computed with `mutationFormatVersion` on both sides (the
   harness emits a constant), equal comparable tables; **write-path crash harness**: kill
   at each of: after ledger `intent`, after `outbox.add` before send, after send before
   ack, inside the dequeuing save; then retry with the same key ⇒ the server log holds
   **exactly one** mutation per op id (checked via `GET /sync/mutations`) and the peer has
   one row; same `Idempotency-Key` twice concurrently ⇒ one mutation; a restart with a
   non-empty outbox performs drain-and-rebuild and reaches `live` with comparable tables
   equal to the peer's; a key change at the peer halts the headless with no further
   sends; a nack blocks writes, is visible in `/v1/status`, and the admin drop + restart
   clears it; every argument guard has a rejecting test (unknown key, foreign-budget id
   on every id path, `opClock`, `transferId`, `importIdentities`, `accounts.update` with
   anything but `name`, `from == to`, over-assign without the flag).
3. **Deploy.** NAS upgrade to v1.22.1 (blob + DB backup first). Headless image built from
   the fork's pnpm workspace (stage 1 of `selfhost.Dockerfile` extended with
   `packages/headless`), mirrored to the Lazycat registry like the server image;
   `headless` service in the manifest bound to `/lzcapp/var/headless`; reachability from
   the Ambrogio container verified; confirm the NAS server doesn't set `APP_VERSION`.
   Real space **read-only until**: 7 days of `live` with `GET /v1/months/{current}`
   matching the web app's figures on 3 spot checks and zero halts; then `readOnly: false`.
4. **Ambrogio adapter** — separate project in the Ambrogio repo. Not designed here.

## Security

- Disk is trusted: the raw space key, `outbox.json` and `ledger.json` (prepared args in
  plaintext) sit together in `/lzcapp/var/headless`; the decrypted DB is in
  memory only. Same trust level as the NAS root.
- JWT travels in the WebSocket query string (upstream design, internal network).
- REST on plain HTTP inside Lazycat's internal network, reachable by every app on the
  box: one bearer per consumer, constant-time compare, no token in logs/status/errors.

## Testing

- Unit: config/idle, serialised file writes, ledger states (intent/queued/acked/nacked,
  body hash, nonce-derived ids, multi-op keys), dequeue observation and timeout,
  bootstrap invariant (outcome paths), drain-and-rebuild trigger, auth refresh, op-policy coverage, argument
  schemas, header / WS URL / outbound-frame contracts.
- Bench (milestone 1): local server at the pin, `create-space`, `peer`, crash harness;
  parity test in the app's vitest (milestone 2).
- Never against the real space.

## Risks

- Space corruption through the log: mitigated by the app's own pipeline (U6), payload
  parity, argument schemas, the throwaway space, read-only first in production. Snapshot
  corruption: impossible by construction (no upload path).
- Restart cost: a full bootstrap each time, two when the outbox was non-empty; acceptable
  (seconds, LAN). If the NAS reboots nightly, that is one bootstrap per day.
- Availability: a halt makes reads 503 until the operator restarts; Ambrogio must handle
  503 gracefully (milestone 4).
- Upstream churn (weekly releases): pin to a tag; server and headless upgrade together;
  U1–U3 and U6 carried as a small patch stack until upstream takes them (issue #155).
- Version skew with phones/browsers on an older app: avoided by matching the server
  version, which the app's PWA also tracks.

## Left to the builder

- esbuild alias set and sql.js wasm loading.
- Exact JSON layout of `outbox.json` / `ledger.json`, as long as the write discipline
  holds.
- Read response field names (amounts stay milliunits).
- Router choice.
