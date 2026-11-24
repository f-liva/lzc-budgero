# Budgero headless client — design

Date: 24/11/2026. Status: draft v4, after review rounds 1–3 (six adversarial reviewers;
every critical/important finding verified in code and folded in below). Round 3 showed
that ordering rules on top of the runtime's multi-step persistence keep leaving crash
windows; v4 replaces them with one transactional mechanism (U7).
Upstream proposal: https://github.com/tombadilo-bombadilo/budgero/issues/155 (no answer yet; we start anyway).
Code references and the pin: upstream tag **v1.22.1 = `e40723e`** (also master HEAD on 24/11).

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

1. Joins one space as a regular client: snapshot, WebSocket catch-up, live mutation
   stream; local decrypted SQLite always current.
2. REST API, bearer-token protected: reads of everything; writes through an explicit op
   allowlist (see Op policy); sync status.
3. Writes are real mutations: other open clients see them immediately.
4. Survives crashes and restarts with no mutation applied twice or skipped.
5. Ships as an optional second service of the `lzc-budgero` Lazycat package, built from
   the same upstream tag as the server.

## Non-goals

- No UI. One process = one space, one budget, one user.
- No SaaS (Clerk auth): self-host local login only.
- No master-password change, key rotation, sharing/invites, file imports, bank sync,
  chat/LLM. A key or password change stops the client (see Halting).
- No public exposure: Lazycat internal network only.
- **Push API queue processing is out of scope until upstream has an atomic claim**
  (see Upstream changes U5). The browser keeps doing it.

## Anti-goals (failure even if it "works")

- **Corrupting the space for other devices.** Whatever the headless puts in a snapshot or
  sends as a mutation, every device ends up with. Any divergence from the app (op
  semantics, emitted format, a skipped or doubled mutation) spreads.
- Reimplementing op logic. We execute the app's own registry.
- Silent version drift: emitting or applying mutations under a different format than
  the app at the same tag.
- Creating, uploading or rotating a space key; holding the key outside this process and
  its secret file.

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
  persistence cipher from it (`:64`), runs `ensureSpaceKeys` on every accepted space and,
  for an owner without a wrapped key, **generates and uploads a new key**
  (`key-vault.ts:223-233`); it activates `primary_space_id`, not a configured one.
- Stock coordinator is also what handles out-of-band uploads, post-restore migrations
  and catch-up correctly (`runtime-coordinator.ts:540-635, 656-712`); the 409 path in
  `DatabaseSync` restores **without** migrations/catch-up (`database-sync.ts:259`).
- Durability ordering the runtime assumes: DB persisted, then applied ids
  (`runtime-context-factory.ts:380-383`), then cursor (`sync-transport.ts:1677-1693`);
  `localStorage.setItem` synchronous and durable. `persistDatabase` returns `false` for
  `NodeSqlJsAdapter` (no `forceSave`), which disables cursor/applied-id persistence
  (`persist-database.ts:8-18`, `sync-transport.ts:1683-1689`). `NodeSqlJsAdapter.restore`
  does not persist. Ops are not idempotent (`transactions.add` = autoincrement INSERT).
- Catch-up failure twice ⇒ mutation **quarantined**, cursor moves past it
  (`sync-transport.ts:1226-1240, 1400-1419`).
- Key/password change handlers don't stop the transport (`sync-transport.ts:1011-1031,
  1733-1762`); the outbox stores plaintext args, encrypted at send time.
- Blob HTTP headers are load-bearing (`server/.../handler/sync.go`): without
  `X-Mutation-Version` the blob is bound to the latest log position (skipped mutations
  for restoring devices); without `X-Database-Version` no CAS; without
  `X-Budgero-Protocol` 426; without `X-Data-Format-Version` rejected as downgrade.
- WebSocket: `WEBSOCKET_ALLOWED_ORIGINS` is set in our manifest, so `Origin` must match
  exactly (`websocket.go:79-92`); URL needs `token`, `space_id`, `protocol`,
  `client_session` (`sync-transport.ts:1785-1792`, `websocket.go:186-197`).
- Push queue on the server: plain SELECT of pending + unconditional status UPDATE, no
  claim (`queries/push.sql`).
- Month figures come from core (`monthlyBudgets.getMonthlyBudget`,
  `getReadyToAssignBreakdown`, same as the app's `useMonthlyBudget`) and use the process
  time zone.
- Self-host JWT TTL: manifest sets `SELF_HOST_JWT_TTL_HOURS=720`.

## Approaches considered

| | What | Verdict |
|---|---|---|
| **A. Full client in the fork** | `packages/headless` runs the stock coordinator + registry + core, with injected platform pieces and a few small upstream changes | **Chosen** (Federico, 24/11) |
| B. Snapshot read + Push API write | Package what Ambrogio does as REST | Rejected: writes wait for a browser, transactions only |
| C. Hand-crafted mutations | Build op payloads ourselves | Rejected: first divergence from `prepareMutationArgs` corrupts the space |

Within A, driving `SpaceActivationService`/`RuntimeContextFactory` by hand (bypassing the
coordinator) was considered and rejected: it would re-implement out-of-band handling,
post-restore migrations and catch-up, which is exactly where review round 1 found the
coordinator doing things right. We keep the stock coordinator and add the missing
injection points upstream (U1–U4, U6, U7).

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
  any other; never unwraps, never generates, never uploads a key (`uploadEncryptedKey`
  never passed); lifecycle doesn't require the master password and the local persistence
  cipher is disabled in **all three** lifecycle sites (`runtime-lifecycle-service.ts:64, 94,
  183`); `ensureSpaceKeys` runs only for that space and activation targets it instead of
  `primary_space_id`.
- **U2 — injected queue storage.** `runtime-context-factory.ts:201` passes a
  `QueueStorage` from deps to `new OfflineQueue(spaceId, storage)` (constructor already
  accepts it, `offline-queue.ts:56`); export `deserializeMutation`
  (`offline-queue/storage.ts:40`, module-private today) so the headless reuses it.
- **U3 — halt and veto hooks.**
  - `uploadVeto?: () => boolean`, ANDed with the existing `DatabaseSyncDeps.canUploadSnapshot`
    (catch-up guard, `runtime-context-factory.ts:173-174`), checked inside `doUpload`
    right before `uploadBlob` and before `downloadAndRestore` in the 409 branch
    (`database-sync.ts:196-199, 246, 259-279`), so out-of-band and retry uploads are covered.
  - `onRemoteApplyFailed?(mutation, error)`, called at the top of both catch blocks
    (catch-up `sync-transport.ts:1226-1244`, live `:1097-1107`) **before** any cursor move,
    quarantine or snapshot fallback, routing into the existing `haltForUpdate` path.
  - `RuntimeCoordinator.halt(reason)`: stops sync, reconnection and connectivity, clears
    the coordinator timers (`remoteBlobRetryTimer`, `runtime-coordinator.ts:635-638`),
    makes `upload` and `downloadAndRestore` no-ops behind a halted flag, **flushes** local
    persistence instead of disposing it, keeps the DB open for reads.
- **U4 — 409 restore = full restore.** `DatabaseSync` gets a post-restore dependency so the
  conflict restore runs the coordinator's path (migrations + `reconcileSpaceScope` +
  `requestCatchUp`).
- **U5 — atomic push claim** (server): `UPDATE push_queue SET status='processing' WHERE
  id=? AND status='pending'`, rows affected = 1, plus the app using it. Prerequisite for
  any future headless push processing; not built in this project.
- **U6 — shared mutation pipeline.** Move `executeMutation`'s pure parts out of
  `AppRuntime` (`app-runtime.ts:72-82, 136-151, 232-270, 760-904, 906-1155`: prepare,
  continuous-rules post-hook, `recordHistory`, `resolveHistoryBudgetId`) into a module
  without analytics/toast imports, used by both `AppRuntime` and the headless. No copy of
  app logic lives in `packages/headless`. Analytics/first-steps calls stay in `AppRuntime`
  as hooks.
- **U7 — transactional sync state ("single-file mode").** Opt-in dep
  `syncStateStore`. When set, the runtime keeps its durable sync state in tables of the
  space DB instead of localStorage/IndexedDB: mutation cursor, blob/key versions, applied
  ids, the outbox, and (for the headless) the idempotency map. The executor runs **op +
  applied id + cursor advance + outbox insert in one SQL transaction**; failure rolls it
  all back (no half-applied op, `executeMutationOp` has no transaction today,
  `op-code-registry.ts:314-319`). Restore builds the new DB in memory, carries the sync
  tables over (outbox and idempotency map kept, cursor reseeded to the bound version,
  applied set rebuilt from the outbox), re-applies the outbox, and only then becomes the
  live DB: one swap. Sync tables are stripped from snapshot uploads. With it, a single
  atomic file write of the DB is always self-consistent; the multi-step orderings
  (`runtime-context-factory.ts:380-383`, `sync-transport.ts:1628-1700`,
  `restore-invariant.ts:45-69`, `space-activation-service.ts:272-284`) no longer matter.
  Feasibility gate: see Spike S1.

### Platform pieces (packages/headless/src/platform)

- `database.ts` — `NodeSqlJsAdapter` wrapped so that:
  - `transaction()` nests via `SAVEPOINT` when already inside one (core services open their
    own `BEGIN`, which doesn't nest, `categories/index.ts:266`);
  - persistence = `adapter.backup()` (keeps `createFunction` registrations) → temp file →
    fsync → rename over `space.sqlite` → fsync dir, **only between transactions** (export
    is deferred while a transaction is open) and resolved only after fsync;
  - `forceSave`, `create(data)`, `restore`, `restoreAndMigrate` all go through it, so
    `persistDatabase` returns `true`;
  - sql.js wasm resolved by explicit path (the adapter defaults to `process.cwd()`).
- `sync-state-store.ts` — U7 implementation on tables of the same DB (cursor, versions,
  applied ids, outbox, idempotency map). Because they live in the DB file, one file write
  is the only commit point: no generations, no `storage.json`, no startup reconciliation.
- `storage.ts` — `localStorage` shim for the few remaining non-sync keys (client session
  id, flags): write-through file, nothing correctness-critical.
- `http.ts` — port of the app's `blobApi` / `spacesApi` (no Clerk/zustand/env): every
  header the app sends (`X-Data-Format-Version`, `X-Budgero-Protocol`,
  `X-Database-Version`, `X-Encryption-Key-Version`, `X-Mutation-Version`, optional
  `X-Out-Of-Band`, `X-Client-Session`, bearer); `downloadBlob` null only on 404; 409 errors
  expose `status` and `response.error` for `getConflictDetails`; `getDatabaseState`
  provided (without it every start downloads a snapshot, `space-activation-service.ts:479`).
  Base URL also for core's relative FX path. Contract test against the app's
  `api-client.ts` at the pin.
- `websocket.ts` — `globalThis.WebSocket` shim (`ws` package) sending
  `Origin: $BUDGERO_ORIGIN`; `getWebSocketUrl` builds `token`, `space_id`,
  `protocol=SYNC_PROTOCOL_VERSION`, `client_session` (same id as HTTP). In read-only mode
  the only outbound frame type allowed is `catch_up_request` (the client sends only
  `mutation`, `increment_encryption_key_version`, `master_password_changed`,
  `catch_up_request`, `sync-transport.ts:539, 587, 1001, 1433`; `ws` protocol pings are
  not frames). Tests assert URL and allowlist.
- `global.ts` — replacement for `@shared/runtime/global` exposing **full**
  `services()`, `mutationsRouter()` and the `mutationHistory` id-reuse API; startup fails if
  any is missing (prevents `withLegacyFormat` silently downgrading formats).
- `lingui.ts` — stub for `@lingui/core/macro` (`t`/`msg` → interpolated English source).
- Logging: core/runtime logs through a redactor (no args/params, no tokens); the
  `NodeSqlJsAdapter` failure logs (params) are redacted.

### Client pieces (packages/headless/src/client)

- `auth.ts` — `POST /api/v1/auth/local/login`; re-login before expiry and on 401.
- `runtime.ts` — stock `RuntimeCoordinator` with U1–U4 + U7 deps (`spaceKeySource`, queue
  storage, `syncStateStore`, `uploadVeto`, `onRemoteApplyFailed`, `getWebSocketUrl`,
  `reloadApp` and key/password-change callbacks wired to Halting). Bootstrap (snapshot vs
  catch-up) is the coordinator's own activation path; we never seed the cursor by hand.
  A gap over 200 mutations makes activation take the snapshot path
  (`space-activation-service.ts:71, 175-182`).
- `execute.ts` — calls the U6 shared pipeline; nothing copied from the app. The op policy
  gates **REST entry only**: ops the pipeline issues itself (continuous-rules
  `rules.execute` after `transactions.add` / `addTransfer`, `app-runtime.ts:760-904`) are
  expected and not blocked.
- `writes.ts` — **one write at a time** (global async lock). Writes return 503 until the
  initial catch-up has settled.
- `idempotency.ts` — `Idempotency-Key` (required on writes) → `spec.idempotencyKey =
  'hdl_' + sha256(key)`; **never `mutationId`**, which makes the executor a receiver that
  never queues or sends (`mutation-executor.ts:69-71`, `mutation-dispatch-service.ts:55-58`)
  and skips `prepareMutationArgs` (`app-runtime.ts:236-239`). The server accepts any id
  (TEXT, no format check). The key → {mutation id, result} row is written **in the same
  transaction as the op** (U7), and restores keep it, so a key present ⇒ never re-execute,
  return the stored result. Retained 30 days. Known gap, documented in the API: if the
  primary op committed but its continuous-rules follow-ups didn't (crash in between), a
  retry returns the stored result and the rules don't run.
- Nack: a `mutation_nack` for a headless-originated mutation stops writes (503
  `outbox_blocked`) and shows in `/v1/status`; the mutation stays queued as upstream does
  (`sync-transport.ts:979-991`) until the operator acts.

### Read-only is structural

`readOnly: true` (milestone 1, and the first days in production): `uploadBlob` and
`uploadEncryptedKey` are stubs that throw, `uploadVeto = () => true`, the WebSocket shim
allows only `catch_up_request`, and the REST layer has no write routes. No code path can
write to the server; a test sends every other frame type and expects a throw.

### Halting

Triggers: `FormatTooNewError`, `UnknownOpCodeError`, HTTP 426, `onRemoteApplyFailed`, key
or password change, server version ≠ bundled version (startup and every reconnect,
`GET /api/v1/version/latest` → `build_version`, compared to `package.json` of the pinned
tag). Action: `coordinator.halt(reason)` (U3): no more sync, timers, uploads, downloads or
outbox sends; local persistence flushed (safe: with U7 a failed op has already rolled
back, so the flushed DB never holds a half-applied op); DB stays open. Writes return 503; reads keep
serving the last good state with `stale: true`. Restart only by operator action. Never
auto-reload, never re-key.

Reads also report `stale: true` while a post-restore catch-up is in progress.

### Op policy (Federico, 24/11: allowlist + key for destructive)

`api/op-policy.ts` lists **exact registry op names** at the pinned tag in three tiers;
everything not listed returns 403, including ops a future release adds. A test fails if
a listed name isn't in `KNOWN_OP_CODES` and prints registry ops not in any tier.

- `allowed` (single-row, budget-scoped): transaction add/split add/transfer add,
  `transactions.updateColumn` and per-field edits of one row, single delete, cleared
  toggle; `monthlyBudgets.upsertAssignment` and single move between categories;
  category/group create, rename, reorder, hide (their `*.update*` op); `accounts.create`,
  `accounts.update` **without currency change**, `accounts.setArchived`; payee create /
  rename; recurring create/update. `transactions.setCleared` only with exactly one id.
  Move between categories = `monthlyBudgets.reassignAssignment`; split add =
  `transactions.saveSplits` (final check against the registry in the plan).
- `destructive` (only with `allowDestructive: true` in `config.json`): `budgets.delete`,
  `accounts.delete`, `transactions.deleteBatch`, `transactions.batchEdit`,
  `transactions.reassign`, `transactions.reconcile`, `transactions.deleteByRef`,
  `payees.deleteMany`, `payees.removeUnused`, `categories.deleteAndReassign`,
  `categoryGroups.delete`, `categoryGroups.deleteAndReassign`,
  `monthlyBudgets.batchUpsertAssignments`, `rules.create`, `rules.update` (their actions
  carry nested `categoryId`/`accountId` applied with no budget check,
  `core/src/services/rules/index.ts:1657-1700`, and continuous rules then run on every
  add), `rules.execute` (only with non-empty `options.transactionIds`, max 500).
- closed: `history.applyOps`, `history.redoWithIds`, `history.restoreRows` (they wrap
  arbitrary ops/rows), `transactions.import`, `importHistory.*`, `bankSync.*`, `chat.*`,
  `llmSettings.*`, and anything unlisted.

Argument guards in the REST layer, before `prepareMutationArgs`: strip caller-supplied
generated ids, `mutationId`, `meta`, `idempotencyKey`, **`opClock`** (a caller clock is kept
as is and backdates the op on every device, `op-code-registry.ts:222, 247-250`); set
`budgetId` only on ops whose
args carry one (adding it elsewhere changes the emitted payload); validate **every
referenced id** against the budget: the target row and `accountId`, `categoryId`,
`payeeId`, `labelId`, `transferAccountId`, and `updateColumn`'s `newValue` on id columns
(`moveTransactionToNewCategory` has no budget check, `core/src/services/transactions/index.ts:1698-1708`);
`accounts.update` rejects a currency change.

The final names are fixed in the plan from the registry at the pinned tag (the review
found `transactions.update` and `accounts.close` don't exist).

### Config (files under `/lzcapp/var/headless`, no file ⇒ idle)

`config.json` (non-secret): `url` (`http://budgero.cloud.lazycat.app.budgero.lzcapp:3001`),
`user`,
`spaceId`, `budgetId`, `readOnly`, `allowDestructive`, `port` (8787).
Secret files, mode 600: `password`, `space.key` (raw base64, from Settings → Push API →
export), `tokens` (one bearer per consumer, one per line, `name:token`).
With no `config.json` the service idles, `/v1/status` says `not_configured`, and it never
contacts the server. `TZ=Europe/Rome` and `BUDGERO_ORIGIN=https://${LAZYCAT_APP_DOMAIN}` come
from the manifest (the same value the server's `WEBSOCKET_ALLOWED_ORIGINS` uses). These
two are the **only** environment inputs; everything else is `config.json` + secret files. `local.env` is not used (it is a
build-time manifest substitution, not runtime config).

### REST API (v1)

Bearer from `tokens`, constant-time compare; token never echoed. Amounts in integer
milliunits.

- `GET /v1/status` — state (`not_configured|syncing|live|halted`), halted reason, cursor,
  stale, versions. No secrets.
- `GET /v1/accounts`, `/v1/category-groups`, `/v1/categories`, `/v1/payees`,
  `/v1/transactions?account=&category=&payee=&since=&until=&cleared=&limit=&offset=`,
  `/v1/transactions/{id}`, `/v1/months/{YYYY-MM}` (assigned/activity/available per
  category, Ready to Assign), `/v1/recurring` — via core services, scoped to `budgetId`.
- `GET /v1/ops` — op policy: name, tier, format version (from `KNOWN_OP_CODES` +
  `OP_CODE_FORMAT_VERSIONS`).
- `POST /v1/ops/{op}` — guarded args → execute → result + mutation id; `Idempotency-Key`
  required.
- Convenience wrappers over `/v1/ops`: `POST /v1/transactions`, `PATCH
  /v1/transactions/{id}`, `DELETE /v1/transactions/{id}`, `POST /v1/transfers`,
  `PUT /v1/months/{YYYY-MM}/categories/{id}/assigned`.

## Decisions settled during review (Claude's calls, correctable)

- **One budget** via `budgetId`; every route and op forced to it.
- **Reachability**: Ambrogio calls `http://headless.cloud.lazycat.app.budgero.lzcapp:8787`
  over the Lazycat internal network (cloudflared, another app, already reaches other apps'
  `*.lzcapp` names); no ingress, no tunnel. To verify in milestone 3.
- **Store package**: service optional, idle without config.
- **Version**: pin v1.22.1 = `e40723e`; NAS (v1.21.5) upgraded to that
  tag in milestone 3 after a blob + DB backup (one-way migrations). Headless refuses to
  run against a different server version.
- **Push queue**: not processed by the headless (needs U5).

## Milestones

0. **Spike S1 — transactional apply on sql.js (go/no-go, throwaway).** Prove in the app's
   vitest that: an op through the registry inside an outer transaction works with core's
   own `transaction()` calls nested as savepoints; async ops don't interleave other SQL into
   the open transaction (executor serialisation); export is deferred while a transaction is
   open; a thrown op rolls back cleanly. **If it fails**, fall back to plan B: write-through
   localStorage shim + DB persist as today; crash goal becomes "no worse than the web app"
   (the same microtask windows upstream accepts, `local-persist-scheduler.ts:20-37`), and
   the crash test measures against that. Federico is told before plan B is adopted.
1. **Read-only client + test bench.** U1, U2, U3, U4, U6, U7 + platform pieces + read
   routes + Halting, plus the bench:
   - local server `docker run budgero/budgero:v1.22.1` with `WEBSOCKET_ALLOWED_ORIGINS` set
     (otherwise self-host accepts any origin and the Origin contract is never exercised);
     `POST /api/v1/auth/local/register`;
   - `bench/create-space.ts`: test-only Node script: register, `POST /budget-spaces`,
     generate/wrap/upload the key with the runtime's `KeyVault`
     (`PUT /budget-spaces/:id/members/me/encrypted-key`), run `budgets.create`, write the
     raw key and budget id for the headless. The headless itself never creates keys;
   - `bench/peer.ts`: a second client (stock coordinator + same platform pieces) writing
     through the real server, standing in for the web app;
   - crash harness: named fault points in our platform layer (before/after the DB temp
     write, after fsync, after rename; WS message received before apply; inside the apply
     transaction). Headless as a child process, `SIGKILL` at point k for every k, then
     200 random kills. Oracle: a fresh headless bootstrapped from an empty dir, compared on
     user tables and the server log.
   Done when: a peer write appears in `GET /v1/transactions` within 5 s; restart resumes
   from cursor without a snapshot download (gap ≤ 200); month numbers equal the peer's
   core figures for 3 months; every crash point and the random kills leave no doubled or
   missing row; an out-of-band upload from the peer converges on the headless; **forced
   409 convergence tested on `peer.ts`** (the read-only headless never uploads, so it can't
   reach that path); header, WS URL and outbound-frame contract tests pass.
2. **Writes.** Execute/idempotency + op policy + write routes.
   Done when, on the bench: REST ops appear at the peer; forced 409 convergence on the
   headless; **parity test in the app's vitest** (the fuzz harness uses `vi.stubGlobal`
   and a mocked `@shared/runtime/global`, so it can't run against the esbuild bundle;
   headless sources aliased in): harness `Device`s and a headless executor from the same
   template bytes, `globalThis.crypto.randomUUID` stubbed with the same seeded sequence,
   `setClock`, FX stub; same op sequence (including a continuous rule) ⇒ equal `{op,
   args}`, `v` computed with `mutationFormatVersion` on both sides (the harness emits a
   constant), equal user tables (excluding `user_id` and timestamps in
   `mutation_history`); same `Idempotency-Key` twice, also concurrently and across a forced
   restore ⇒ one row; crash points around execute/queue/send/ack deliver each mutation
   exactly once and locally present; a key change at the peer halts the headless with no
   further sends; a remote mutation forced to fail halts before any cursor move.
3. **Deploy.** NAS upgrade to v1.22.1 (blob + DB backup first). Headless image built from
   the fork's pnpm workspace (stage 1 of `selfhost.Dockerfile` extended with
   `packages/headless`), mirrored to the Lazycat registry like the server image; `headless`
   service in the manifest bound to `/lzcapp/var/headless`; reachability from the Ambrogio
   container verified; confirm the NAS server doesn't set `APP_VERSION` (it would break
   the version check). Real space read-only for a few days, then writes.
4. **Ambrogio adapter** — separate project in the Ambrogio repo. Not designed here.

## Security

- Disk is trusted: the decrypted SQLite, outbox and the raw space key sit together in
  `/lzcapp/var/headless` (the app encrypts its local copy; we don't, U1 disables the
  cipher). Same trust level as the NAS root.
- JWT travels in the WebSocket query string (upstream design, internal network).
- REST on plain HTTP inside Lazycat's internal network, reachable by every app on the
  box: one bearer per consumer, constant-time compare, no token in logs/status/errors.

## Testing

- Unit: config/idle, savepoint nesting and deferred export, sync-state tables across
  restore, auth refresh, op-policy coverage, argument guards (incl. `opClock`), header / WS
  URL / outbound-frame contracts, idempotency retention.
- Bench (milestone 1): local server at the pinned tag, `create-space`, `peer`, crash
  harness; parity test in-process (milestone 2).
- Never against the real space.

## Risks

- Space corruption: mitigated by the stock coordinator, structural read-only, durability
  transactional sync state (U7), halting on failed apply/key change, payload parity, throwaway space, read-only
  first in production, server snapshot history (`SNAPSHOT_HISTORY_KEEP=10`) as restore path.
- Upstream churn (weekly releases): pin to a tag; server and headless upgrade together;
  U1–U4, U6, U7 carried as a patch stack until upstream takes them (issue #155); U7 is the
  biggest and also hardens the browser, which is the argument for upstreaming it.
- Version skew with phones/browsers on an older app: a newer headless can migrate the
  blob and lock older clients out (`DatabaseNewerThanAppError`); avoided by matching the
  server version, which the app's PWA also tracks.

## Left to the builder

- esbuild alias set and sql.js wasm loading.
- Sync-state table schema, as long as every sync-state write shares the op's transaction.
- Read response field names (amounts stay milliunits).
- Router choice.
