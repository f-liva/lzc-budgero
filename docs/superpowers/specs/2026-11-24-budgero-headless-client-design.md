# Budgero headless client — design

Date: 24/11/2026. Status: draft v5, after review rounds 1–4 (eight adversarial reviewers;
every critical/important finding verified in code and folded in below). Rounds 3–4
established the durability approach: own ordering schemes (v3) and transactional sync
state (v4, would rewrite the whole sync layer) both fail; v5 reproduces the web app's
persistence model faithfully and accepts exactly the crash window upstream accepts.
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
4. Survives crashes and restarts **with the same guarantees as the web app**: the runtime's
   own persistence ordering on durable storage (see Durability), nothing weaker.
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
injection points upstream (U1–U4, U6).

## Design

### Where the code lives

- Fork `f-liva/budgero` (`~/Progetti/budgero`; remotes `origin` = upstream,
  `f-liva-fork` = ours). Branch `feat/headless-client` from the pinned tag.
- `packages/headless` (TypeScript, Node 22). Upstream changes are separate commits, each
  upstreamable on its own.
- Deployment in `lzc-budgero` (Docker stage, manifest service, docs).

### Upstream changes (in the fork, one commit each)

- **U1 — external space key.** Also covers the key version (`MasterPasswordStore` keeps it
  in localStorage, `master-password-store.ts:184-199`; the shim persists it). `RuntimeCoordinatorDeps.spaceKeySource?: { spaceId, key }`.
  When set: the coordinator's `KeyVault` returns that key for that space and throws for
  any other; never unwraps, never generates, never uploads a key (`uploadEncryptedKey`
  is never passed, in any mode); lifecycle doesn't require the master password and the local persistence
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

### Durability (= the web app's model, on durable Node storage)

Upstream's invariant: "no durable record ever runs ahead of the file"
(`local-persist-scheduler.ts:18-37`): the outbox entry is durable before send, the DB is
written, then applied ids and cursor are written for what that write contains. It holds
when localStorage writes are durable and the DB write is atomic. The headless provides
exactly that and changes none of the orderings:

- `storage.ts` — `localStorage` shim, **write-through**: every `setItem`/`removeItem`
  rewrites `storage.json` synchronously (temp + `fsyncSync` + rename). Sync, so it keeps
  the browser's "returns ⇒ visible" semantics; durable, which the browser's localStorage
  only approximates.
- `database.ts` — `NodeSqlJsAdapter` wrapped with `forceSave()` = `adapter.backup()` (keeps
  `createFunction` registrations) → temp file → fsync → rename over `space.sqlite` → fsync
  dir, resolving after fsync; `create(data)`, `restore`, `restoreAndMigrate` persist the
  same way before returning, like the web adapter. So `persistDatabase` returns `true` and
  the runtime's cursor/applied-id persistence is active. Core's `transaction()` is
  synchronous, so an export can't land inside one. sql.js wasm by explicit path.
- `queue-storage.ts` — `QueueStorage` (U2) in `outbox.json`, same write discipline, `save`
  resolves after fsync (dispatch awaits it before sending).

**Accepted window, same as upstream:** a kill between the DB rename and the applied-id /
cursor write that follows it (one continuation, sub-millisecond to a few ms) can re-apply
the last batch on restart. Upstream documents and accepts this for the browser
(`local-persist-scheduler.ts:20-37`). The crash test injects a fault exactly there to
**demonstrate** it (expected: possible duplicate of that batch) and asserts no doubled or
missing row at every other point. Closing it needs a sync-layer change upstream, which is
for issue #155, not this project.

### Platform pieces (packages/headless/src/platform)

- `storage.ts`, `database.ts`, `queue-storage.ts` — see Durability.
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
- `runtime.ts` — stock `RuntimeCoordinator` with U1–U4 deps (`spaceKeySource`, queue
  storage, `uploadVeto`, `onRemoteApplyFailed`, `getWebSocketUrl`,
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
  (TEXT, no format check). Flow:
  1. if the key has no intent record yet, write `key → mutationId` to `idempotency.json`
     (write-through) **before** executing;
  2. if it already has one, check whether the mutation is in the local DB
     (`isApplied(id)` or `mutationHistory.getByMutationId(id)`,
     `core/src/services/mutation-history/index.ts:129`) or in the outbox: if yes, don't
     execute, return the stored result or `200 {status:"applied", result:null,
     mutationId}`; if in none (crash before execute or before the outbox write), execute
     with the same id;
  3. after execute, store the result, then `forceSave()`, and **only then** answer 200.
  This covers the crash where the server got `hdl_x` but the local file didn't: after
  restart catch-up applies it as remote, and the retry finds it applied. Retention 30
  days. Known gap, documented in the API: if the primary op committed but its
  continuous-rules follow-ups didn't, a retry returns the stored result and the rules
  don't run.
- Nack: a `mutation_nack` for a headless-originated mutation stops writes (503
  `outbox_blocked`) and shows in `/v1/status`; the mutation stays queued as upstream does
  (`sync-transport.ts:979-991`) until the operator acts.

### Read-only is structural

`readOnly: true` (milestone 1, and the first days in production): `uploadBlob` is a stub that
throws (`uploadEncryptedKey` is never passed), `uploadVeto = () => true`, the WebSocket shim
allows only `catch_up_request`, and the REST layer has no write routes. No code path can
write to the server; a test sends every other frame type and expects a throw.

### Halting

Triggers: `FormatTooNewError`, `UnknownOpCodeError`, HTTP 426, `onRemoteApplyFailed`, key
or password change, server version ≠ bundled version, or `build_version` is `unknown`/unparsable (startup and
every reconnect, `GET /api/v1/version/latest` → `build_version`, compared to
`package.json` of the pinned tag). Action: `coordinator.halt(reason)` (U3): no more sync, timers, uploads, downloads or
outbox sends. Persistence depends on the reason: after `onRemoteApplyFailed` the in-memory
DB may hold a half-applied op (`executeMutationOp` has no transaction,
`op-code-registry.ts:314-319`), so it is **discarded without flushing** and reads are
served from the last persisted `space.sqlite`, reopened; for every other reason local
persistence is flushed and the DB stays open. Writes return 503; reads keep
serving the last good state with `stale: true`. Restart only by operator action. Never
auto-reload, never re-key.

Reads also report `stale: true` while a post-restore catch-up is in progress. Reads are
not serialised with remote applies: a read can observe an op mid-apply; acceptable for
Ambrogio, stated in the API docs.

### Op policy (Federico, 24/11: allowlist + key for destructive)

`api/op-policy.ts` lists **exact registry op names** at the pinned tag in three tiers;
everything not listed returns 403, including ops a future release adds. A test fails if
a listed name isn't in `KNOWN_OP_CODES` and prints registry ops not in any tier.

- `allowed` (single-row, budget-scoped), exact names at v1.22.1:
  - transactions: `transactions.add` (with or without `splits`), `transactions.addTransfer`,
    `transactions.updateColumn` (columns `outflowconverted`, `inflowconverted`,
    `categoryid`, `memo`, `date`, `payee`, `cleared`), `transactions.delete`,
    `transactions.setCleared` (exactly one id), `transactions.saveSplits`;
  - money: `monthlyBudgets.upsertAssignment` (assign to one category in one month); moving
    money goes through `POST /v1/months/{m}/move` (below), never through a generic op;
  - categories: `categories.create`, `categories.updateName`, `categoryGroups.create`,
    `categoryGroups.update`, `categories.moveToNewGroup`;
  - accounts: `accounts.create`, `accounts.update` (guarded), `accounts.setArchived`;
  - payees and recurring: `payees.add`, `payees.rename`, `recurring.create`,
    `recurring.update`.
  Decided closed (not needed by Ambrogio, revisit on request): reorder ops (they take the
  whole ordered id list), `transactions.moveToNewCategory`/`moveToNewAccount`, transfer
  edit/delete ops, `monthlyBudgets.updateAssignment`, `monthlyBudgets.reassignAssignment`
  (a legacy category-delete step that merges a category's whole assignment history into
  another, `core/.../monthly-budgets/queries.ts:285-310`).
- `destructive` (only with `allowDestructive: true` in `config.json`): `budgets.delete`,
  `accounts.delete`, `transactions.deleteBatch`, `transactions.batchEdit`,
  `transactions.reassign`, `transactions.reconcile`, `transactions.deleteByRef`,
  `payees.deleteMany`, `payees.removeUnused`, `categories.deleteAndReassign`,
  `categoryGroups.delete`, `categoryGroups.deleteAndReassign`,
  `monthlyBudgets.batchUpsertAssignments` (generic), `rules.create`, `rules.update` (their actions
  carry nested `categoryId`/`accountId` applied with no budget check,
  `core/src/services/rules/index.ts:1657-1700`, and continuous rules then run on every
  add), `rules.execute` (only with non-empty `options.transactionIds`, max 500).
- closed: `history.applyOps`, `history.redoWithIds`, `history.restoreRows` (they wrap
  arbitrary ops/rows), `transactions.import`, `importHistory.*`, `bankSync.*`, `chat.*`,
  `llmSettings.*`, and anything unlisted.

Argument guards: `op-policy.ts` carries a **per-op argument schema**: allowed keys (unknown
keys rejected), which keys are id references including nested paths (`source`/
`destination` in `addTransfer`, `splits[].categoryId`/`transferAccountId`, recurring
`input`/`patch`, `updateColumn`'s `newValue` on id columns), each validated against
`budgetId` (`moveTransactionToNewCategory` has no budget check,
`core/src/services/transactions/index.ts:1698-1708`). Always stripped: generated ids,
`mutationId`, `meta`, `idempotencyKey`, `opClock` (a caller clock backdates the op on every
device, `op-code-registry.ts:222, 247-250`), `currencyRates` (`accounts.ts:152`),
`importIdentities` (makes `transactions.add` return an existing row,
`transactions.ts:745-750`). `budgetId` set only on ops whose args carry one.
`accounts.update` rejects changes to currency, `onBudget` and `type`.

All names above were checked against the registry at v1.22.1 (review round 4); the
policy test re-checks them on every upgrade.

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
- `POST /v1/months/{YYYY-MM}/move {from, to | "rta", amount}` — the app's move money:
  reads the current assigned values and issues one `monthlyBudgets.batchUpsertAssignments`
  with one or two entries for that month (as `useCategoryOperations.ts:380-403` does), both
  category ids validated. Allowed tier; the generic op stays destructive.

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

1. **Read-only client + test bench.** U1, U2, U3, U4, U6 + platform pieces + read
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
     write, after fsync, after rename, around every `storage.json` / `outbox.json` write;
     WS message received before apply). Headless as a child process, `SIGKILL` at point k for every k, then
     200 random kills. Oracle: a fresh headless bootstrapped from an empty dir, compared on
     user tables and the server log.
   Done when: a peer write appears in `GET /v1/transactions` within 5 s; restart resumes
   from cursor without a snapshot download (gap ≤ 200); month numbers equal the peer's
   core figures for 3 months; every crash point except the documented accepted window
   leaves no doubled or missing **user-table** row (user tables = every table, with
   `mutation_history`'s `user_id`/timestamps excluded), and the accepted-window point
   behaves as documented; an out-of-band upload from the peer converges on the headless; **forced
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
   restore ⇒ one row; a kill after send and before `forceSave`, then a retry ⇒ one row
   (catch-up brings it back as remote); crash points around execute/queue/send/ack, other
   than the accepted window, deliver each mutation once and locally present; a key change at the peer halts the headless with no
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

- Unit: config/idle, write-through storage and atomic DB write, idempotency flow (intent
  before execute, answer after `forceSave`), auth refresh, op-policy coverage, argument guards (incl. `opClock`), header / WS
  URL / outbound-frame contracts, idempotency retention.
- Bench (milestone 1): local server at the pinned tag, `create-space`, `peer`, crash
  harness; parity test in-process (milestone 2).
- Never against the real space.

## Risks

- Space corruption: mitigated by the stock coordinator, structural read-only, durability
  the web app's persistence model on durable storage, halting on failed apply/key change, payload parity, throwaway space, read-only
  first in production, server snapshot history (`SNAPSHOT_HISTORY_KEEP=10`) as restore path.
- Upstream churn (weekly releases): pin to a tag; server and headless upgrade together;
  U1–U4 and U6 carried as a small patch stack until upstream takes them (issue #155).
- Version skew with phones/browsers on an older app: a newer headless can migrate the
  blob and lock older clients out (`DatabaseNewerThanAppError`); avoided by matching the
  server version, which the app's PWA also tracks.

## Left to the builder

- esbuild alias set and sql.js wasm loading.
- File layout under the state dir, as long as the write discipline above holds.
- Read response field names (amounts stay milliunits).
- Router choice.
