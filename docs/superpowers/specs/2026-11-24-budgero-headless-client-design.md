# Budgero headless client — design

Date: 24/11/2026. Status: draft v12, after review rounds 1–11 (twenty-two adversarial reviewers;
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
second time** before serving. Round 7 added the live-ordering check: a write that the
server orders behind a concurrent peer write (ack version ≠ expected) makes the local
DB diverge in row ids and absolute totals, exactly as it does in the web app; the
headless detects it from the ack version and rebuilds before the next write.

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
   the same upstream tag as the server, with its own in-container supervisor (Lazycat
   has no restart policy).

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
  (`offline-queue/storage.ts:40`). Plus a real upstream bug fix: `OfflineQueue.add` pushes
  into memory **before** `await storage.save` (`offline-queue.ts:67-69`), and both the
  resend sweep (`getStale`, `offline-queue.ts:141-147`, run every 20 s by
  `reconnection-service.ts:336-352`) and `replayQueueViaSync` (`:244-280`) can send an
  entry that is not yet durable, contradicting the "queued durably BEFORE any send"
  comment at `mutation-dispatch-service.ts:71-74`. U2 adds a `persisting` set to
  `OfflineQueue`: ids are added before the save and removed only when it **resolves** (a
  rejected save leaves the id in the set); a new `getSendable()` used by `getStale()`,
  `getUnsent()` and the replay skips them, while `getQueue()` stays unfiltered (reapply
  and `queuedCount` must see every entry). Without it, "`intent` ⇒ the server has nothing"
  (ledger rules) would be false.
- **U3 — hooks.**
  - `allowUpload?: () => boolean`, ANDed with the existing `DatabaseSyncDeps.canUploadSnapshot`
    (`runtime-context-factory.ts:173-174`), checked inside `doUpload` immediately before
    `uploadBlob` (`database-sync.ts:330`; the existing check at `:199` is skipped for
    out-of-band uploads, this one is not). The headless passes `() => false` **always**;
    when `allowUpload()` is false `doUpload` **returns** (no throw, so
    `replayQueueViaSync`, which calls `dbSync.upload()` on every reconnect,
    `reconnection-service.ts:302`, doesn't tag it `snapshot_upload_failed`,
    `:303-321`); the `uploadBlob` dependency is additionally a stub that throws, as a
    second fence that must never be reached.
  - `onRemoteApplyFailed?(mutation, error)`, called at the top of both catch blocks
    (catch-up `sync-transport.ts:1226-1244`, live `:1097-1107`) **before** any cursor move,
    quarantine or snapshot fallback.
  - `onMutationAck(mutationId, version)`: the existing dependency (`interfaces.ts:161`) is
    wired at `runtime-context-factory.ts:221` as `(id) => offlineQueue.ackMutation(id)` and
    drops the version; U3 passes it through, so the headless learns the **log position**
    the server gave each of its ops (needed for the ordering check). Dequeues are still
    observed in `QueueStorage` (implicit acks via catch-up never reach this handler,
    `runtime-lifecycle-service.ts:196-201`).
  - `onMutationNacked?(mutationId, code, reason)` from `handleMutationNack`
    (`sync-transport.ts:974`, id = `msg.id ?? msg.mutationId`, possibly empty for an
    unparseable frame, `client.go:149`).
  - `onDatabaseRestored?(queuedCount)` after `reapplyQueueAfterRestore` on every live
    restore (`runtime-context-factory.ts:178-192`, `runtime-coordinator.ts:656-676`).
  - `onFollowUpError?(op, error)` in the U6 pipeline where continuous-rules failures are
    swallowed today (`app-runtime.ts:875-903`): `AppRuntime` keeps logging, the headless
    rebuilds.
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

What survives a restart: `outbox.json`, `ledger.json`, `rebuilds.log`, `reason` (last exit
reason, served by the supervisor), config. Nothing else.

- **DB in memory** (`NodeSqlJsAdapter`, no `forceSave`), discarded on exit.
- **`storage.ts`** — in-memory `localStorage` shim, reset at every start (client session
  id, key version, flags). Never read across runs.
- **`queue-storage.ts`** — `QueueStorage` (U2) in `outbox.json`: temp + fsync + rename;
  `save` resolves after fsync (dispatch awaits it before sending,
  `mutation-dispatch-service.ts:76`). **One promise chain per file**, content snapshotted
  at call time, unique temp names (the web adapter serialises for the same reason,
  `web-adapter.ts:555-566`). The wrapper also notices ids that *disappear* from the queue
  between saves. In the headless the only place an entry leaves the queue is
  `OfflineQueue.ackMutation` (`offline-queue.ts:154-166`), reached both by `mutation_ack`
  and by the implicit ack when our own mutation comes back via catch-up/broadcast
  (`runtime-lifecycle-service.ts:196-201`); that observation is what the write path waits
  on. `clear()`/`setQueue()` exist (`offline-queue.ts:272-283`) but are reachable only
  from the app UI; the wrapper halts (`queue_cleared`) if `QueueStorage.clear` is called.
- **`ledger.ts`** — `ledger.json`, same write discipline, same chain rule (see Writes).

**Bootstrap invariant: `live` only with DB = snapshot + log in server order, own ops
included at their server position.**
1. Activation runs the stock path with `hasLocalDatabase: async () => false` and a fresh
   in-memory storage shim: snapshot download → `createDatabase` →
   `reapplyQueueAfterRestore` → connect → catch-up (`space-activation-service.ts:272-391`).
2. The `onSpaceActivated` report must have `ok === true` and path `server_snapshot`
   (`:95-123`); `fresh` is accepted only when `downloadBlob` returned null, i.e. the blob
   answered 404 (new space). Anything else (download error ⇒ upstream silently continues
   on an **empty** DB, `:310-322`; local fallback; decryption error; a swallowed
   `runMigrations` failure, `:351-364`, detected by wrapping the loader) ⇒ **halt**.
   Status `bootstrapping` until catch-up has settled.
3. If the outbox was non-empty at start, the reapplied entries were applied **before**
   catch-up, i.e. out of server order (`:363-377`). So: status `draining`, wait until the
   outbox drains (every entry acked, or finally nacked: see Nack), then **rebuild**.
4. **Every** live restore ⇒ `draining`, then rebuild, whatever `queuedCount` is, and the
   restore must **wait for a running write**: U3 adds `beforeRestore(): Promise<void>`,
   awaited at the top of `downloadAndRestore` and `notifyDatabaseRestored`
   (`database-sync.ts:423-449, 416`); the headless flips to `draining` synchronously and
   then waits for the global write lock (the request in flight finishes through dequeue
   or its 202 timeout). Otherwise a write that read absolute totals before the swap
   would apply them on the restored DB and send them to every device with the ordering
   check blind (an out-of-band blob is not in the log). Once a restore has started it
   always ends in a rebuild, even if the hook chain throws (`:442-449` swallows throws).
   Why every restore: `downloadAndRestore` does not wait for a running write (`database-sync.ts:423-449`,
   `beginOperation` only holds uploads, `:141-158`), so an op mid-apply at restore time is
   neither in the queue for reapply nor re-applied by catch-up (its echo is an implicit
   ack, `runtime-lifecycle-service.ts:196-201`), and an out-of-band blob is not in the log,
   so the ordering check can't see it. Restores are **not** rare: besides a peer import or
   DB restore, every offline→online transition downloads the latest blob when the
   server's version is newer and the headless has no local changes
   (`reconnection-service.ts:194-200`, `runtime-coordinator.ts:672-690`), i.e. after any
   connectivity blip that coincided with a phone upload. Restore-triggered rebuilds
   therefore have their own exit code and budget (see the table).
5. **Live ordering check, per request, in the dequeue observer.** A request issues `k ≥ 1`
   ops: its own (one per `/v1/ops`, n for a `PATCH`) plus the continuous-rules follow-ups
   the U6 pipeline issues with random ids right after the primary is sent
   (`app-runtime.ts:244-253, 873-890`). During a request the `QueueStorage` wrapper
   attributes **every new id that appears in the outbox** to that request (writes are
   serialised, so there is exactly one). Before the request, cursor `c` is read from
   `coordinator.getSyncDiagnostics()` (cursor, `catchUpInProgress`, `pendingCount`,
   `runtime-coordinator.ts:720-733`); the request is accepted only when
   `catchUpInProgress` is false and `pendingCount === 0`. **Base** = `max(cursor, highest
   version among own acks so far)`: the ack handler calls `onMutationAck` **before**
   `updateLocalVersion` (`sync-transport.ts:906-937`), and `ackMutation` empties the
   in-memory queue before its save (`offline-queue.ts:157-162`), so right after a
   request completes `pendingCount` is 0 while the cursor still lags by k; without the
   max, every back-to-back write would be a false `reordered`. The server assigns each
   op its position (`onMutationAck(id, v)`). The request's ops must be acked with
   versions exactly `base+1 … base+k` in send order. The verdict and the `draining`
   status flip happen **synchronously in `onMutationAck`** (U3), before any await, so a
   request that passed the gate after a 202 can't compute on a reordered DB. Any gap, or **a dequeue with no version** (implicit
   ack through catch-up after the ack frame was lost, `hub.go:537-548` is best-effort,
   `runtime-lifecycle-service.ts:196-201`) ⇒ `reordered`: a peer mutation was ordered
   between ours; locally ours ran first, so autoincrement row ids and absolute totals
   (`upsertAssignment`, move money, `updateColumn`) now differ from every other device
   (`id-reuse.ts:1-28`, `reconnection-service.ts:261`; the web app has the identical race
   and lives with it). The check runs in the observer, so it also covers ops acked after
   a 202. Response: 200 (the server has the ops, every device applies them) with
   `reordered: true` and, for creates, a note that the returned row ids are **not valid
   across devices** until the next read after rebuild; then `draining` → rebuild. Writes
   are 503 `pending` while `pendingCount > 0` (follow-ups included), never on a ledger
   flag.
6. Throws, by where they happen:
   - in the **primary's** `prepareMutationArgs` (before any apply, `app-runtime.ts:236-239`)
     ⇒ **422**, ledger `failed`, no rebuild;
   - in the **primary's** apply (op validation such as "accounts must differ" or a split
     sum, `transactions.ts:838-861, 618-666`) ⇒ **422**, ledger `failed`, rebuild (partial
     writes are in memory, `op-code-registry.ts:314-319`; nothing reached the server
     because `outbox.add` runs after apply, `mutation-dispatch-service.ts:48-79`);
   - in a **continuous-rules follow-up** (`onFollowUpError`, prepare or apply): the
     primary is already queued and sent (`app-runtime.ts:244-253`), so the request is
     **not** failed: wait for the primary's dequeue, answer **200** (or 202) with
     `rules_failed: true`, ledger primary `acked`, follow-up `failed`; then rebuild (exit
     76: a user-configured rule that throws on every add must not count as a storm). If
     the follow-up's error came from its own `outbox.add`, mark it `unknown` (the entry
     may still be written by a later save and drain). The outbound WS shim **holds every
     non-`hdl_` frame until the request's primary is acked**: otherwise a transient nack of
     the primary lets a follow-up `rules.execute` land first and run on every device
     before its transaction exists (`mutations.go:111-175`). The hook also covers the `listRules`
     catch and the `!services` return (`app-runtime.ts:851, 857`), outside the range
     `:875-903`.
     A 422 here would make a caller re-create the transaction under a new key: doubled
     on every device;
   - from `outbox.add` itself (the entry is already in the in-memory queue but, with the
     U2 `persisting` set, not sendable): ⇒ ledger `queued` if that write succeeded,
     response **202 `unknown`**, halt; the next start drains it.
   Caller-induced rebuilds (primary apply throws) exit with code **76**: the supervisor
   relaunches but does not count them toward the storm limit; the worker appends
   its record to `rebuilds.log` (shape in the exit-code table) before exiting and reads it at start,
   so **429** applies to writes when more than 5 caller rebuilds happened in the last 10
   minutes (the window survives the restart because it lives in the file).

**Rebuild** = `coordinator.halt()`, wait until both file chains are idle, verify the
outbox state on disk, then **`process.exit(75)`**. Lazycat ignores `services.*.restart`
(lzc-sdk 0.1 generates `RestartPolicy=no`; `ambrogio/deploy/lzc-manifest.template.yml:26-33`,
confirmed on the NAS for every lzcapp container), so the container's entrypoint (a child
of Lazycat's `lzcinit` when `setup_script` is used, as on `cloudlazycatapppostiz-elasticsearch-1`)
is a small **supervisor** (`entrypoint.sh`, same pattern as our cloudflared package; the image adds
`busybox-extras` for its tiny HTTP responder, as `lzc-cloudflared/docker/Dockerfile:4`
does): it relaunches the worker on exit codes **75** (system rebuild) and **76** (caller
rebuild), stays down on any other code (an uncaught exception exits 1), traps
`TERM`/`INT` and forwards them to the worker (`trap 'kill -TERM "$child"; wait "$child";
exit 143' TERM INT`, no relaunch on 137/143; whether `lzcinit` forwards TERM is a
milestone 3 check), and does not relaunch the **21st** code-75 exit within 24 h read from
`rebuilds.log` (`rebuild_storm`). After a storm or a non-rebuild exit the supervisor
serves `/healthz` and `/v1/status` itself (no bearer, no secrets:
`{state:"halted", reason}`), so callers get a reason rather than a refused connection; it
writes `exit:<code>` as the reason when the worker left none. An operator clears a storm
by deleting `rebuilds.log` and restarting the container. In-process re-activation is not used: re-activating the same space
keeps the old transport and socket alive (`runtime-lifecycle-service.ts:176-179`,
`active-space-session.ts:44-48`) and the shim already holds a cursor
(`sync-transport.ts:1629-1656`, `database-sync.ts:110`).

With that invariant, a startup "reconciliation" of the outbox against `mutation_history`
is unnecessary and is **not** done (`mutation_history` is capped at ~500/budget and
gated on a resolvable budget id, so it proves nothing). Double application of an
acked-but-not-dequeued entry during a bootstrap that will be discarded is harmless.

Why this is enough: nothing the headless does locally can reach another device except
through the mutations it sends; those are produced by the app's own pipeline (U6) from
guarded args against a DB that is either what every other device has, or known not to
be, in which case no further write happens until it is rebuilt. The residual: the
lost-update race between two devices editing the same absolute value at the same
time, which is Budgero's own semantics and identical in the web app.

### Platform pieces (packages/headless/src/platform)

- `storage.ts`, `queue-storage.ts`, `database.ts` (bare `NodeSqlJsAdapter`; it loads sql.js
  from `process.cwd()/node_modules/sql.js/dist` and ignores options,
  `node-sqljs-adapter.ts:45-47`, so the image keeps that layout; failure logs redacted) —
  see Durability.
- `http.ts` — port of the app's `blobApi` (download + `getDatabaseState` only; **no
  upload function in `http.ts`**; the coordinator's required `uploadBlob` dependency,
  `runtime-coordinator-types.ts:20`, is the throwing stub named in U3), `spacesApi`, `checkApiHealth` (`HEAD
  /api/v1/health`, `health.ts:9-20`; a required coordinator dependency used by
  `DatabaseSync.download`, `database-sync.ts:346-353`, and the connectivity monitor) and
  `getProfile` (`GET /profile`, called by `space-catalog-service.ts:112`), without
  Clerk/zustand/env:
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
  `hasLocalDatabase: async () => false`, `onSpaceActivated` (bootstrap invariant), `reloadApp`
  and key/password-change callbacks wired to Halting). Version check before activation.
- `execute.ts` — calls the U6 shared pipeline; nothing copied from the app. The op policy
  gates **REST entry only**: ops the pipeline issues itself (continuous-rules
  `rules.execute` after `transactions.add` / `addTransfer`, `app-runtime.ts:760-904`) are
  expected and not blocked.
- `writes.ts` — **one write at a time** (global async lock). Order per request: take the
  lock → look the `Idempotency-Key` up (under the lock, so two concurrent same-key
  requests can't both see "no record") → if the record needs no execution (`acked`,
  `failed`, `dropped`, or `queued` ops to wait for) answer from it, releasing the lock
  while waiting → otherwise (no record, or `intent`-only ops) pass the **status gate**:
  503 while status is not `live` (bootstrapping, draining, halted, `outbox_blocked`) or
  while `pendingCount > 0` — later writes must not be computed on a DB that contains an
  op the server may still refuse — then read a fresh `c` and execute. Flow per request:
  1. policy + argument guards (below);
  2. ledger record `intent` for **all n own ops** up front (so a retry can finish a request
     stopped at op k), with a fresh random **nonce**; cursor `c` recorded;
  3. `execute` with `spec.idempotencyKey = opId` (never `mutationId`): prepare → apply →
     `outbox.add` → send. Inside `outbox.add`, the `QueueStorage` wrapper writes the
     ledger op as `queued` **with the prepared payload** (`spec.payload` after prepare,
     what the queue stores, `mutation-dispatch-service.ts:61-69`) **before** the outbox
     temp → fsync → rename → fsync dir;
  4. wait for the dequeue of every op of the request, follow-ups included (timeout 30 s).
     All dequeued ⇒ ledger `acked` + results + versions ⇒ **200** (+ ordering check, rule
     5). Timeout ⇒ **202 `{status:"pending", mutationIds}`**, caller polls
     `GET /v1/mutations/{id}`; the observer completes the ledger when the acks arrive,
     with no request waiting. Nack: see Nack.
  The `acked` ledger write happens inside the `QueueStorage.save` that removes the id,
  **before** that save resolves. The rename order (ledger `queued` first, outbox second)
  means a crash in between leaves `queued` without an outbox entry: **at startup, before
  activation, every ledger op in `queued` state missing from `outbox.json` is put back**
  (same id, same payload; the server dedups by id), so it drains in the first bootstrap.
  "`queued` and not in the outbox ⇒ acked" is therefore valid only after that startup
  step has run.
- `ledger.ts` — `ledger.json`. Record per `Idempotency-Key`: `{key, bodyHash, nonce, c,
  generated: {transferId?}, ops: [{opId, own: bool, state:
  intent|queued|acked|nacked|failed|dropped|unknown, entry?: serialized MutationPayload,
  result?, version?}]}` (`entry` is the full queue
  entry as the wrapper sees it in `save()` — `id`, `op`, `args`, `v`, `timestamp`,
  `baseVersion`, `spaceId`, `interfaces.ts:77-86`, `storage.ts:40-54` — the whole object,
  so startup put-back can rebuild it).
  Op ids are `'hdl_' + sha256(nonce + '#' + i)`: never derived from the key alone (a key
  reused after the record expired would otherwise collide with an id the server already
  has, be acked as a no-op, and the write would be lost silently, `mutations.go:124-138`,
  `sync-transport.ts:1044`). One request may issue several ops (a `PATCH` of n fields = n
  `updateColumn` ops). On a request:
  - no record ⇒ proceed;
  - record with a different `bodyHash` ⇒ **422** (`bodyHash` = sha256 of method + path +
    canonical JSON of the parsed body: sorted keys, no whitespace; a re-serialised retry
    must not look like key reuse, or the caller would retry under a new key);
  **Retry decisions look at own ops only (`own: true`); follow-up states never decide
  the status code, they only set `rules_failed`/`rules_dropped` on the stored 200.**
  - all own ops `acked` ⇒ 200 with stored results (`result: null` for ops acked by a drain
    after a crash, with `mutationId` and `payload` so the caller can re-read); for a
    multi-op request where op k failed after ops 1..k-1 landed, 200 with per-op results
    and `partial: true` (`updateColumn` is idempotent, nothing doubles);
  - an op `queued` ⇒ in the outbox by construction (startup re-insertion): wait for its
    dequeue;
  - an op `intent` only (crash before the ledger `queued` write, which precedes the
    outbox write, so the server has nothing under that id) ⇒ execute again with the
    **same opId**; `prepare` runs again, which is correct;
  - an own op `unknown` (its `outbox.add` threw) ⇒ 202 `unknown` until startup resolves it
    (present in `outbox.json` → drains → `acked`; absent → `failed`);
  - first own op `failed` ⇒ 422 with the stored reason; an own op `nacked` ⇒ 202 `blocked`
    while it is still in the outbox (this branch answers from the record, before the
    gate), **409 only once `dropped`** (see Nack); an own op `dropped` ⇒ 409.
  `GET /v1/mutations/{id}` maps ledger `intent` → `pending`, `queued` → `pending`, the rest
  1:1; it and `/v1/status` are served in every state, including `halted` and
  `outbox_blocked`, so a caller holding a 202 can always learn the outcome.
  `mutation_history` is never used as evidence of anything. Records are kept 30 days;
  a key that expired is a new key (new nonce, new ids), which is safe because the ids
  differ. Known gap, documented: continuous-rules follow-ups have their own random ids;
  a crash between the primary op's `outbox.add` and the follow-ups' `outbox.add`
  (`app-runtime.ts:243-253`) means a retry returns the stored result and the rules don't
  run.
- Nack. Server codes (`client.go:18-29`): `storage_error` and `internal` are **transient**
  ("re-send after a short delay"), `invalid` is permanent. In every case upstream keeps
  the entry queued and the sweep resends it forever (`sync-transport.ts:974-993`,
  `reconnection-service.ts:336-365`), so **no nack is final until the entry has left the
  disk**: the write path never answers 409 for a nack. Transient ⇒ ledger stays `queued`,
  `/v1/status.last_nack` set, 202 after the timeout. `invalid` ⇒ ledger `nacked`,
  writes **and reads** 503 `outbox_blocked` (the DB holds a write the server refused,
  applied out of order: same state as a half-applied halt), `outbox_divergent: true`; the entry keeps
  being resent and nacked, and would be reapplied at every start, so **at startup, if the
  ledger says `nacked` for an entry still in `outbox.json`, the process stays up as
  `outbox_blocked` and does not drain or rebuild** (no activation at all: the entry would
  be reapplied and resent; the coordinator is not built, the admin drop works on the file
  directly). A nack on a follow-up id blocks writes the same way but never changes the
  request's status code (the primary landed). An empty-id nack (`client.go:149`) sets `last_nack`
  only. Operator action: `POST /v1/admin/outbox/{id}/drop` (role `admin`, see Config) performs `halt()` if a coordinator exists,
  waits for the file chains, writes ledger `dropped` **first**, then removes the entry from
  `outbox.json`, exits 75 for a rebuild (startup step 4 also removes from `outbox.json`
  any id the ledger marks `dropped`, closing the crash window between the two writes); the caller's next retry gets **409**. Dropping on a
  running queue is not possible (the in-memory queue rewrites the file on the next ack,
  `offline-queue.ts:154-166`).
- `GET /v1/mutations/{id}` — `pending|acked|nacked|failed|dropped|unknown`, with `version`
  and `reordered` when acked. Status codes used by writes: 200, 202, 403 (policy), 409
  (dropped), 422 (schema / failed), 429 (rebuild rate), 503 (not live / pending / blocked).

### Read-only is structural

`readOnly: true` (milestone 1, and the first days in production): the REST layer has no
write routes, the WebSocket shim rejects `mutation` frames, `allowUpload` is `() => false`
and `uploadBlob` is the rejecting stub. In write mode only the first two change. A
leftover outbox in read-only mode would be reapplied and resent at start, and the shim's
throw would close the socket in a loop (`sync-transport.ts:549-560`): read-only therefore
refuses to start with a non-empty `outbox.json` (exit 1, reason `outbox_in_readonly`; to
drain or drop it the operator sets `readOnly: false` first). A test sends
every frame type in read-only mode and expects a throw for all but `catch_up_request`.

### Halting

Triggers: `FormatTooNewError`, `UnknownOpCodeError`, HTTP 426, `onRemoteApplyFailed`, key
or password change, server version ≠ bundled version or `build_version`
`unknown`/unparsable (checked before activation and on every reconnect via
`GET /api/v1/version/latest`, compared to `package.json` of the pinned tag). Action:
`coordinator.halt(reason)` (U3); `/v1/status` → `{state:"halted", reason}`; **reads and writes
return 503** (the in-memory DB may be half-applied or stale, and there is no "last good
file" to fall back to). Restart only by operator action: a container restart rebuilds
from the server. Never auto-reload, never re-key.

Reads: 503 `bootstrapping` until the snapshot is restored, then 200 + `stale: true` until
catch-up has settled (only when the outbox was empty: with a non-empty outbox the state
is `draining`, not `bootstrapping`); **503 `draining`** in `draining` (the DB
is out of server order by definition) and 503 in `outbox_blocked`/`halted`. Reads are not
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
- the schema is a **closed accepted-key set per op**, written in `op-policy.ts` from the
  op's `execute`/`prepare` at the pin (e.g. `transactions.add`: `budgetId`, `accountId`,
  `categoryId`, `date`, `time`, `inflow`, `outflow`, `memo`, `payee`, `labelId`,
  `cleared`, `splits[]` with `categoryId`, `transferAccountId`, `memo`, `payee`, `inflow`,
  `outflow`, `receivedAmount`, `transactions.ts:586-667`; `saveSplits`: `transactionId`,
  `splits[]` closed to `category_id`, `transfer_account_id`, `memo`, `payee`, `inflow`,
  `outflow`, `amount`, `exactAmount` rejected); a test asserts every key the op reads is
  either accepted or explicitly rejected;
- always rejected: `mutationId`, `meta`, `idempotencyKey`, `opClock` (a caller clock
  backdates the op on every device, `op-code-registry.ts:222, 247-250`),
  `exchangeRateOverride`, `fromPush` (relaxes mirror checks), `mirror`/`Mirror` on any
  split line;
- create ops: caller `id` rejected (`transactions.add`, `categories.create`,
  `categoryGroups.create`, `accounts.create`, `recurring.create`'s `input.id`,
  `addTransfer`'s `source.id`/`destination.id`); `transactions.add` rejects a non-empty
  `transferId` (joins an existing transfer, `core/.../transactions/index.ts:490`) and
  `importIdentities` (returns an existing row, `transactions.ts:745-750`);
- `addTransfer`: `transferId` is required by the op (`transactions.ts:833`) and generated
  by the headless, stored in the idempotency record so a retry reuses it;
- **every** id reference validated against `budgetId`, target ids included: `id`/`ids`
  of `updateColumn`, `delete`, `setCleared` (`ids[]`, `transactions.ts:1592`),
  `saveSplits`' `transactionId` (`transactions.ts:1327-1342`), `categories.updateName`, `categoryGroups.update`, `accounts.update`/
  `setArchived`, `recurring.update`; `categories.create`'s `parentId`
  (`domains/categories.ts:222`); `moveToNewGroup`'s `categoryId`; recurring `toAccountId`
  and `splits[].categoryId/transferAccountId` (`recurring/types.ts:33-41, 84-115`);
  `accountId`, `categoryId`, `labelId`, `transactions.add`'s
  `splits[].categoryId`/`splits[].transferAccountId` (camelCase, `transactions.ts:620-667`), `saveSplits` lines (`category_id`,
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
  **`name` only**; `type` and `currency` are sent as `''` (core keeps the current value for
  an empty string, and copying the local value would revert a concurrent change on a peer
  and convert with per-device rates, `:418`); `metadata`,
  `onBudget`, `linked_category_id`, `cc_payment_category_id`, `debt_total`,
  `paid_so_far`, `currencyRates` (`accounts.ts:152`) are rejected;
- `payees.add`: `{budgetId, name}` (`domains/payees.ts:43`), `budgetId` forced.

All names above were checked against the registry at v1.22.1 (review rounds 4–5); the
policy test re-checks them on every upgrade.

### Config (files under `/lzcapp/var/headless`, no file ⇒ idle)

`config.json` (non-secret): `url` (`http://budgero.cloud.lazycat.app.budgero.lzcapp:3001`),
`user`, `spaceId`, `budgetId`, `readOnly`, `allowDestructive`, `port` (8787).
Secret files, mode 600, owned by uid 1001: `password`, `space.key` (raw base64, from
Settings → Push API → export), `tokens` (one bearer per consumer, one per line,
`name:role:token`; roles and the route matrix in Startup step 2).
With no `config.json` the service idles, `/v1/status` says `not_configured`, and it never
contacts the server. `TZ=Europe/Rome` and `BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}`
come from the manifest (the same value the server's `WEBSOCKET_ALLOWED_ORIGINS` uses).
These two are the **only** environment inputs in production; the bench passes
`--config-dir <path>` and `--bench` on the command line. `local.env` is not used (build-time
substitution, not runtime config).

### Startup and shutdown (ordered)

1. Parse `--config-dir` (default `/lzcapp/var/headless`), `--bench`, `--crash-at`. Read and
   validate `config.json` and the secret files; any error ⇒ write `reason` file
   (`config:<field>`), exit **1** (supervisor stays down and serves the reason).
2. Load `tokens` (`name:role:token`, roles `read|write|admin`; a malformed line is a config
   error). Role matrix: `read` → GET routes; `write` → `read` + write routes; `admin` →
   `write` + `/v1/admin/*`. A role mismatch is **403 `role`** (distinct from 403 `policy`).
   `GET /healthz` is unauthenticated (body `{state, reason}` only) and is what the manifest
   health check and Ambrogio's liveness probe use; `/v1/status` needs any valid bearer
   when served by the worker (the supervisor's copy needs none, same body as `/healthz`).
   HTTP codes: `/healthz` returns 200 in `live`, `bootstrapping`, `draining`,
   `not_configured`; 503 in `halted`, `outbox_blocked`, `shutting_down` (so Lazycat shows
   a halted headless as unhealthy; verifying what Lazycat does with an unhealthy
   secondary service is a milestone 3 check).
3. Read `rebuilds.log` (for `rebuilds_24h` and the 429 window).
4. Ledger reconciliation: every `queued` op missing from `outbox.json` is appended to it;
   every `dropped` id still present is removed.
5. Nacked check: a ledger `nacked` op still in `outbox.json` ⇒ state `outbox_blocked`,
   serve `/healthz`, `/v1/status`, `/v1/mutations/*`, `/v1/admin/*` only; **no activation**
   (runs before the read-only check so the admin drop is reachable).
6. Read-only check: `readOnly` and non-empty outbox ⇒ `reason=outbox_in_readonly`, exit 1.
7. Version check (`GET /version/latest`, unauthenticated, `routes.go:30`) ⇒ mismatch or
   `unknown` ⇒ halt `version_mismatch`.
8. Login.
9. Activate (bootstrap invariant). `bootstrapping` → `live`, or `draining` when the outbox
   was non-empty.

Shutdown on `TERM`/`INT` (forwarded by the supervisor): stop accepting requests (503
`shutting_down`), `coordinator.halt()`, wait for both file chains, exit **143**.

### Rebuild and exit codes

| Trigger | Exit | Counted for storm (20/24 h) | Counted for 429 (5/10 min) |
|---|---|---|---|
| `reordered` (ordering check) | 75 | yes | no |
| live restore (`beforeRestore`) | 77 | separate budget: 50/24 h | no |
| drain finished after non-empty outbox | 75 | yes | no |
| admin drop | 75 | yes | no |
| primary apply throw (422) | 76 | no | yes |
| follow-up failure (`rules_failed`) | 76 | no | yes |
| config error, `outbox_in_readonly`, uncaught exception | 1 | stays down | — |
| `TERM`/`INT` | 143 | stays down | — |

The worker appends `{ts, code, reason}` to `rebuilds.log` before exiting (and `{ts,
code:"halt", reason}` when it halts without exiting, so the milestone 3 "zero halts" gate
is checkable) and writes the last `reason` to the `reason` file; the supervisor relaunches
on 75/76/77 only.

### `/v1/status` schema

```json
{"state":"not_configured|bootstrapping|draining|live|outbox_blocked|halted|shutting_down",
 "reason": "version_mismatch|protocol_426|format_too_new|unknown_op|remote_apply_failed|key_changed|password_changed|bootstrap_failed:<download|local_fallback|decrypt|migrations>|outbox_write_failed|queue_cleared|rebuild_storm|outbox_in_readonly|config:<field>|exit:<code>|null",
 "stale": true, "cursor": 12345, "outbox_size": 0, "outbox_divergent": false,
 "last_nack": {"id":"hdl_…","code":"storage_error","at":"2026-11-24T10:00:00Z"},
 "rebuilds_24h": 1, "versions": {"server":"1.22.1","bundled":"1.22.1"}}
```
Write responses: 200 `{results:[…], mutationIds:[…], reordered?, rules_failed?, partial?}`;
202 `{status:"pending|blocked|unknown", mutationIds}`; errors `{error, reason}`.

### Image and manifest

- Build stage: clone `f-liva/budgero` at the **fork tag** `headless-v1.22.1-<n>` (branch
  `feat/headless-client` rebased on upstream `v1.22.1`; upstream's own tag has no
  `packages/headless`), `pnpm install --frozen-lockfile --prod=false` (sql.js is a
  **devDependency** of `core`, `core/package.json:52-62`, installed only with
  `--prod=false`) with `packages/headless` in the workspace and lockfile (`ws`, `esbuild`),
  then `esbuild` → `dist/headless.mjs` with `sql.js` left **external** and a
  `createRequire` banner (CommonJS deps such as `ws`/`debug` inside an ESM bundle).
- Runtime stage: `node:22-alpine` + `busybox-extras` (supervisor's HTTP responder) +
  `dist/` + the **whole** `sql.js` package copied dereferenced
  (`cp -rL packages/core/node_modules/sql.js /app/node_modules/sql.js`: the bare `import
  'sql.js'` in `node-sqljs-adapter.ts:1` needs its `package.json`, and the wasm is loaded
  from `process.cwd()/node_modules/sql.js/dist`, `:45-47`), worker `cwd=/app`. Runs as
  uid 1001; the manifest's `setup_script` chowns
  `/lzcapp/var/headless` to 1001 so mode-600 secrets are readable (Lazycat runs
  containers as root unless told otherwise).
- Manifest service:
  ```yaml
  headless:
    image: registry.lazycat.cloud/<mirror>/fliva/budgero-headless:1.22.1
    user: "1001:1001"
    binds:
      - /lzcapp/var/headless:/lzcapp/var/headless
    environment:
      - TZ=Europe/Rome
      - BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}
    setup_script: mkdir -p /lzcapp/var/headless && chown -R 1001:1001 /lzcapp/var/headless
    health_check:
      test: [CMD, wget, -qO-, http://localhost:8787/healthz]
      start_period: 120s
  ```
  (`user` + `setup_script` as in `lzc-postiz/postiz-lzc/lzc-manifest.yml:34-35`, live on the
  NAS.) The Dockerfile lives in **`lzc-budgero/docker/headless/Dockerfile`** and clones the
  fork tag above; it is a separate image from the server's, which is our thin wrapper
  `fliva/lzc-budgero` over the upstream release image (`lzc-budgero/docker/Dockerfile`).

### REST API (v1)

Bearer from `tokens`, constant-time compare; token never echoed. Amounts in integer
milliunits. Request bodies: `POST /v1/ops/{op}` takes the op's args object **directly**
(what the registry's `execute(args)` receives, minus the stripped keys); wrappers take the
flat fields named below. `Idempotency-Key`: 16–128 chars, `[A-Za-z0-9_-]`. Tokens are
generated by the operator (`openssl rand -base64 32`) and written to `tokens`. Logs: JSON
lines on stdout (`{ts, level, msg, state, mutationId?}`), through the redactor.

Example (Ambrogio adds an expense):
```http
POST /v1/transactions
Authorization: Bearer <write token>
Idempotency-Key: amb-2026-11-24-7f3a
{"accountId": 139, "categoryId": 163, "date": "2026-11-24", "outflow": 12500, "payee": "Esselunga", "memo": "spesa"}
→ 200 {"results":[{"id": 8631}], "mutationIds":["hdl_…"]}
```


- `GET /v1/status` — `not_configured|bootstrapping|draining|live|outbox_blocked|halted`
  (halted reasons include `rebuild_storm`), `last_nack`, `rebuilds_24h`,
  cursor, stale, outbox size, `outbox_divergent`, versions. No secrets.
- `GET /v1/accounts`, `/v1/category-groups`, `/v1/categories`, `/v1/payees`,
  `/v1/transactions?account=&category=&payee=&since=&until=&cleared=&limit=&offset=`,
  `/v1/transactions/{id}`, `/v1/months/{YYYY-MM}` (assigned/activity/available per
  category, Ready to Assign), `/v1/recurring` — via core services, scoped to `budgetId`.
- `GET /v1/ops` — op policy: name, tier, format version (from `KNOWN_OP_CODES` +
  `OP_CODE_FORMAT_VERSIONS`).
- `POST /v1/ops/{op}` — one op; guarded args → execute → ack → `{result, mutationId}`;
  `Idempotency-Key` required. 200 (`reordered`/`rules_failed` flags) / 202 pending|blocked
  |unknown / 403 policy|role / 409 dropped / 422 schema|failed|key reuse / 429 / 503; state list in the status schema (incl. `shutting_down`).
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
  `to`, as the app does); each entry's `budgetId` forced, ids validated; overspend check on
  the source; over-assign check only when `from` is `rta` (the app runs none for
  category→category, `useCategoryOperations.ts:405-447`). Allowed tier; the generic op
  stays destructive. The generic `POST /v1/ops/monthlyBudgets.upsertAssignment` applies
  the same checks as the `PUT` route.

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
   - crash harness (read-only points only): the worker accepts `--crash-at=<point>` (only
     with `--bench`) and calls `process.kill(process.pid, 'SIGKILL')` at that named point;
     the point list is an exported enum (`crash-points.ts`) the harness iterates:
     `snapshot_download`, `create_database`, `before_catchup_settled`, `ws_before_apply`,
     and in milestone 2 `after_ledger_intent`, `after_ledger_queued_before_rename`,
     `after_outbox_add_before_send`, `after_send_before_ack`, `in_dequeuing_save`.
     Headless as a child process run through `entrypoint.sh` (so 75/76/77 relaunch as in
     production, with `rebuilds.log` in the bench config dir), `SIGKILL` at point k for
     every k, then
     100 random kills. Oracle after each restart: status reaches `live`, and the headless
     DB equals the peer's under the upstream comparator `dumpDb(adapter, {sequences:
     true, crossDevice: true})`. `dumpDb` lives in the app's vitest harness
     (`fuzz/harness.ts:104-225`, imports `vi` and `@shared/*`), so **the crash harness
     runs inside the app's vitest**, spawning the headless as a child process; the
     headless exposes, only when started with `--bench`, `GET /v1/debug/db` returning
     `db.backup()` bytes, loaded into a `NodeSqlJsAdapter` for `dumpDb` (the comparator it already excludes
     `schema_migrations`, `sqlite_stat1`, `currency_rates`, `CreatedAt`/`UpdatedAt`/
     `applied_at`, device-local occurrence ids, `LastOccurrenceDate`, rule-run stamps,
     zero assignments, local sequences); `mutation_history` compared as a set of
     `MutationID`s;
   - fault injection for the bootstrap invariant: blob download forced to fail ⇒ halt
     (not an empty `live` DB); a remote mutation whose apply throws (the bench encrypts
     with `MutationEncryption` and sends a raw `mutation` frame with a **known** op that
     fails in apply, e.g. `transactions.updateColumn` with `columnName: 'cleared'`,
     delivered while the headless is down and **with the peer stopped** (a later peer
     write would upload a snapshot bound past the poison and activation would seed the
     cursor from it, `space-activation-service.ts:288-291`), so it arrives through
     catch-up; an unknown op
     would go to `haltForUpdate` instead, `sync-transport.ts:1219-1225`) ⇒ halt before any
     cursor move. The poison stays in that space's log forever: throwaway space only.
   Done when: a peer write appears in `GET /v1/transactions` within 5 s; a restart
   rebuilds from the server and reaches `live`; month numbers equal the peer's core
   figures for 3 months; every crash point and the random kills pass the oracle; an
   out-of-band upload from the peer converges on the headless; the two fault injections
   halt; header, WS URL and outbound-frame contract tests pass; every HTTP call the
   headless makes is in an **allowlist** (login, `GET /profile`, `GET /budget-spaces`,
   `HEAD /health`, `GET /database/blob`, `GET /database/state`, `GET /version/latest`,
   WS upgrade; the list is asserted both ways: every call seen is listed, every listed
   call is seen at least once; `GET /exchange-rates` is reached only from prepare/currency
   ops, `core/.../currency/index.ts:380-390`, so it joins the allowlist in milestone 2
   with a multi-currency write),
   recorded by a reverse proxy the bench puts at `url` (Node `fetch` and `ws` ignore
   `HTTP_PROXY`; the FX path is relative and must go through the same base URL) across
   the whole milestone run. Blob upload, blob history restore (`routes.go:139`) and
   `PUT …/encrypted-key(s)` (`:162-163`) are therefore proven never called.
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
   at each of: after ledger `intent`, after ledger `queued` before the outbox rename,
   after `outbox.add` before send, after send before ack, inside the dequeuing save;
   then retry with the same key ⇒ the server log grew by **exactly** the expected number
   of entries since the pre-test version (primary ops + rule follow-ups; `GET
   /sync/mutations?space_id&before&limit≤100`, newest first, `sync_service.go:31-42`,
   `handler/sync.go:485-535`) and their decrypted `{op, args}` equal the ledger payloads;
   the peer has one row; a write ordered behind a concurrent peer write returns
   `reordered: true` and triggers a rebuild, after which comparable tables equal the
   peer's — forced deterministically by the bench proxy, which is **WebSocket-aware**
   (frames are plaintext JSON with only `encryptedPayload` opaque, no compression,
   `websocket.go:96-114`, `sync-transport.ts:538-548`; headless ops are recognisable by the
   `hdl_` prefix, any other id on the headless socket is a follow-up; **both** clients
   connect through the proxy): it holds the headless's `mutation` frame until the peer's
   `mutation_ack` passes (the server orders by arrival); a throwing op (e.g. `addTransfer` with equal accounts) returns 422
   and triggers a rebuild; same `Idempotency-Key` twice concurrently ⇒ one mutation; a restart with a
   non-empty outbox performs drain-and-rebuild and reaches `live` with comparable tables
   equal to the peer's; a key change at the peer halts the headless with no further
   sends; a transient nack (the proxy swallows the first `mutation` frame and injects
   `{"type":"mutation_nack","mutationId":id,"code":"storage_error"}`, then forwards the
   resend; the stock server has no switch for it, `client.go:177-184`) keeps the op pending
   and it lands with **one** log entry; an injected `invalid` nack blocks writes, is
   visible in `/v1/status`, survives a restart as `outbox_blocked` without draining, and
   the admin drop clears it after the rebuild, after which the same key returns 409; a
   follow-up ordered behind a peer write (proxy holds only the follow-up frame) is
   detected as `reordered`; the supervisor relaunches on exit 75 and stays down on exit 1;
   21 forced rebuilds in the bench ⇒ `rebuild_storm`; every argument guard has a rejecting test (unknown key, foreign-budget id
   on every id path, `opClock`, `transferId`, `importIdentities`, `accounts.update` with
   anything but `name`, `from == to`, over-assign without the flag).
3. **Deploy.** NAS upgrade to v1.22.1 (blob + DB backup first). Headless image built as
   in §Image and manifest, mirrored to the Lazycat registry like the server image;
   `headless` service in the manifest bound to `/lzcapp/var/headless`; reachability from
   the Ambrogio container verified; confirm the NAS server doesn't set `APP_VERSION`;
   verify that `lzcinit` forwards TERM to the entrypoint and what Lazycat does with an
   unhealthy `headless` service.
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
- Restart cost: a full bootstrap each time, plus one rebuild after every reordered or
  failed write and every live restore; seconds each on LAN. Ambrogio writes a few times a
  day and Federico edits from the phone rarely at the same instant, so rebuilds should be
  rare; `/v1/status.rebuilds_24h` (from `rebuilds.log`) shows if that assumption is wrong.
- Availability: a halt makes reads 503 until the operator restarts; Ambrogio must handle
  503 gracefully (milestone 4).
- Upstream churn (weekly releases): pin to a tag; server and headless upgrade together;
  U1–U3 and U6 carried as a small patch stack until upstream takes them (issue #155).
- Version skew with phones/browsers on an older app: avoided by matching the server
  version, which the app's PWA also tracks.

## Left to the builder

- esbuild alias set; sql.js stays an external resolved from the image's `node_modules`.
- Exact JSON layout of `outbox.json` / `ledger.json`, as long as the write discipline
  holds.
- Read response field names (amounts stay milliunits).
- Router choice.
