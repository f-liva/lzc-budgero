# Budgero headless client — design

Date: 24/11/2026. Status: draft v6, after review rounds 1–5 (ten adversarial reviewers;
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
(U1–U4, U6).

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
  - `uploadVeto?: () => boolean`, ANDed with the existing `DatabaseSyncDeps.canUploadSnapshot`
    (`runtime-context-factory.ts:173-174`), checked inside `doUpload` right before
    `uploadBlob` (`database-sync.ts:196-199, 246`). The headless passes `() => true`
    **always**; `uploadBlob` itself is a stub that throws, as a second fence.
  - `onRemoteApplyFailed?(mutation, error)`, called at the top of both catch blocks
    (catch-up `sync-transport.ts:1226-1244`, live `:1097-1107`) **before** any cursor move,
    quarantine or snapshot fallback.
  - `onMutationAcked?(mutationId, version)` and `onMutationNacked?(mutationId, reason)`,
    from the ack/nack handlers (`sync-transport.ts:900-991`), so a REST write can wait for
    the server's answer.
  - `RuntimeCoordinator.halt(reason)`: stops sync, reconnection and connectivity, clears
    the coordinator timers (`remoteBlobRetryTimer`, `runtime-coordinator.ts:635-638`),
    makes `upload`/`downloadAndRestore` no-ops behind a halted flag. No flush: there is
    nothing to flush (in-memory DB).
- **U4 — stays listed for upstream, not used here.** 409 restore = full restore
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

What survives a restart: `outbox.json`, `idempotency.json`, config. Nothing else.

- **DB in memory** (`NodeSqlJsAdapter`, no `forceSave`), discarded on exit. At start the
  coordinator's activation path finds no local DB and no cursor, downloads the snapshot,
  runs `reapplyQueueAfterRestore` on the outbox (queued ids marked in-flight, so catch-up
  dedups them), connects, catches up. Cost per start on the NAS: a ~1.4 MB blob, decrypt,
  LZ4, open, catch-up; seconds.
- **`storage.ts`** — in-memory `localStorage` shim, reset at every start (client session
  id, key version, flags). Never read across runs.
- **`queue-storage.ts`** — `QueueStorage` (U2) in `outbox.json`: temp + fsync + rename;
  `save` resolves after fsync (dispatch awaits it before sending,
  `mutation-dispatch-service.ts:76`). **One promise chain per file**, content snapshotted
  at call time, unique temp names (the web adapter serialises for the same reason,
  `web-adapter.ts:555-566`).
- **`idempotency.ts`** — `idempotency.json`, same write discipline, same chain rule.
- **Startup outbox reconciliation** (before activation hands the queue to
  `reapplyQueueAfterRestore`): for each queued id, if the snapshot's `mutation_history`
  already has it (`mutationHistory.getByMutationId`, `core/.../mutation-history/index.ts:129`),
  drop it from the outbox (it was acked and included in a snapshot before we could
  dequeue it); otherwise keep it for reapply + resend (the server dedups by id). Residual
  window: acked, included in a snapshot, pruned from `mutation_history` (~500/budget),
  crash before dequeue ⇒ reapplied twice **locally**; it never reaches other devices (no
  upload), and the next restart rebuilds a correct DB. Documented in `/v1/status`
  (`outbox_reconciled: n`).

Why this is enough: every local inconsistency (doubled or half-applied row, cursor
mismatch) is confined to this process's memory and disappears at the next start. The
only state that can hurt other devices is a mutation in the server log, and that is
produced by the app's own pipeline from args the policy guarded.

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
  `Origin: $BUDGERO_ORIGIN`; `getWebSocketUrl` builds `token`, `space_id`,
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
  storage, `uploadVeto`, `onRemoteApplyFailed`, `onMutationAcked/Nacked`,
  `getWebSocketUrl`, `reloadApp` and key/password-change callbacks wired to Halting).
  Version check before activation (see Halting).
- `execute.ts` — calls the U6 shared pipeline; nothing copied from the app. The op policy
  gates **REST entry only**: ops the pipeline issues itself (continuous-rules
  `rules.execute` after `transactions.add` / `addTransfer`, `app-runtime.ts:760-904`) are
  expected and not blocked.
- `writes.ts` — **one write at a time** (global async lock); writes return 503 until the
  initial catch-up has settled and the outbox is drained. Flow per op:
  1. policy + argument guards (below);
  2. idempotency record written as `intent` (see `idempotency.ts`);
  3. `execute` with `spec.idempotencyKey = <op id>` (never `mutationId`), which goes through
     prepare → apply → `outbox.add` (fsync) → send;
  4. wait for `onMutationAcked(id)` (timeout 30 s). Ack ⇒ record `acked` + result ⇒ **200**.
     Timeout ⇒ record stays `intent`, **202 `{status:"pending", mutationId}`**; the caller
     polls `GET /v1/mutations/{id}`. Nack ⇒ record `nacked`, **409**, writes blocked
     (`outbox_blocked`) until the operator acts; the entry stays queued as upstream does
     (`sync-transport.ts:979-991`).
- `idempotency.ts` — `Idempotency-Key` required on every write. Record:
  `{key, bodyHash, opIds[], state: intent|acked|nacked, result}`. One request may issue
  several ops (a `PATCH` of n fields = n `updateColumn` ops): op `i` gets
  `'hdl_' + sha256(key + '#' + i)`, all ids in `opIds`. On a request:
  - no record ⇒ proceed;
  - record, different `bodyHash` ⇒ **422**;
  - `acked` ⇒ 200 with stored result;
  - `intent` ⇒ for each op id: in outbox → wait for ack; else in `mutation_history` →
    treat as acked (applied via catch-up); else (crash before `outbox.add`) → execute again
    with the same id. The server dedups by id and keeps the first, and `prepare` runs
    again only when the first never reached the outbox, i.e. never reached the server.
  Retention 30 days. Known gap, documented: continuous-rules follow-ups have their own
  random ids; a crash between the primary op's ack and the follow-ups means a retry
  returns the stored result and the rules don't run.
- `GET /v1/mutations/{id}` — `pending|acked|nacked|unknown` from the ledger + outbox.

### Read-only is structural

`readOnly: true` (milestone 1, and the first days in production): the REST layer has no
write routes, the WebSocket shim rejects `mutation` frames, `uploadVeto` is `() => true`
and there is no upload function. In write mode only the first two change. A test sends
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
- id references validated against `budgetId` (direct and nested): `accountId`,
  `categoryId`, `transactions.add`'s `splits[].categoryId`/`splits[].transferAccountId`
  (camelCase, `transactions.ts:620-667`), `saveSplits` lines (`category_id`,
  `transfer_account_id`, snake_case, `shared.ts:125-146`; `mirror`/`Mirror`/`pair_id`/
  `PairID` rejected), `addTransfer`'s `source.accountId`/`destination.accountId`,
  `moveToNewGroup`'s `newGroupId`, recurring `input.*`/`patch.*` ids, `updateColumn`'s
  `newValue` when the column is `categoryid` (normalised like core, integer required,
  `core/.../transactions/index.ts:2440, 2503`);
- `budgetId` forced on the ops whose args carry one, nested paths included
  (`recurring.create` → `input.budgetId`, each `batchUpsertAssignments` entry);
- `accounts.update` replaces the whole row (`core/.../accounts/index.ts:447-503`): the
  guard fills `name`/`type`/`currency`/`onBudget`/`metadata` from the current row, accepts
  changes only to `name`, `metadata.notes` and `metadata.icon`, rejects `currency`, `type`,
  `onBudget`, `linked_category_id`, `cc_payment_category_id`, `debt_total`,
  `paid_so_far`, `currencyRates` (`accounts.ts:152`);
- `payees.add`: `name` only.

All names above were checked against the registry at v1.22.1 (review rounds 4–5); the
policy test re-checks them on every upgrade.

### Config (files under `/lzcapp/var/headless`, no file ⇒ idle)

`config.json` (non-secret): `url` (`http://budgero.cloud.lazycat.app.budgero.lzcapp:3001`),
`user`, `spaceId`, `budgetId`, `readOnly`, `allowDestructive`, `port` (8787).
Secret files, mode 600: `password`, `space.key` (raw base64, from Settings → Push API →
export), `tokens` (one bearer per consumer, one per line, `name:token`).
With no `config.json` the service idles, `/v1/status` says `not_configured`, and it never
contacts the server. `TZ=Europe/Rome` and `BUDGERO_ORIGIN=https://${LAZYCAT_BOX_DOMAIN}`
come from the manifest (the same value the server's `WEBSOCKET_ALLOWED_ORIGINS` uses).
These two are the **only** environment inputs. `local.env` is not used (build-time
substitution, not runtime config).

### REST API (v1)

Bearer from `tokens`, constant-time compare; token never echoed. Amounts in integer
milliunits.

- `GET /v1/status` — `not_configured|bootstrapping|live|halted`, halted reason, cursor,
  stale, outbox size, `outbox_reconciled`, versions. No secrets.
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
- `POST /v1/months/{YYYY-MM}/move {from, to | "rta", amount}` — the app's move money
  (`useCategoryOperations.ts:380-447`): `amount > 0`, `from ≠ to`, source's available > 0,
  amount clamped to it, one `batchUpsertAssignments` with two entries (one when `to` is
  `rta`), each entry's `budgetId` forced, both ids validated. Moving **from** Ready to
  Assign is `upsertAssignment` on the target (as in the app). Overspending that the app
  would ask to confirm is rejected unless `allowOverspend: true`.

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
   Halting, plus the bench:
   - local server `docker run budgero/budgero:v1.22.1` with `WEBSOCKET_ALLOWED_ORIGINS`
     set (otherwise self-host accepts any origin and the Origin contract is never
     exercised); `POST /api/v1/auth/local/register`;
   - `bench/create-space.ts`: test-only Node script: register, `POST /budget-spaces`,
     generate/wrap/upload the key with the runtime's `KeyVault`
     (`PUT /budget-spaces/:id/members/me/encrypted-key`), run `budgets.create`, write the
     raw key and budget id for the headless. The headless itself never creates keys;
   - `bench/peer.ts`: a second client (stock coordinator + same platform pieces, **with**
     uploads, standing in for the web app) writing through the real server;
   - crash harness: named fault points (around `outbox.json` / `idempotency.json` writes;
     WS message received before apply; after `outbox.add` before send; after send before
     ack). Headless as a child process, `SIGKILL` at point k for every k, then 200 random
     kills. Oracle after each restart: the headless DB equals a fresh peer bootstrapped
     from the server, on user tables (every table, `mutation_history`'s `user_id`/
     timestamps excluded); the server log contains each headless mutation exactly once.
   Done when: a peer write appears in `GET /v1/transactions` within 5 s; a restart
   rebuilds from the server and `/v1/status` reaches `live`; month numbers equal the
   peer's core figures for 3 months; every crash point and the random kills pass the
   oracle; an out-of-band upload from the peer converges on the headless; a quarantine-
   triggering remote mutation (test hook) halts before any cursor move; header, WS URL and
   outbound-frame contract tests pass; **no upload function exists** (grep + contract
   test on the HTTP port: no `POST /database/blob`).
2. **Writes.** `writes.ts`, `idempotency.ts`, op policy + argument schemas, write routes,
   move endpoint.
   Done when, on the bench: REST ops appear at the peer and the peer's next snapshot
   includes them; **parity test in the app's vitest** (the fuzz harness uses
   `vi.stubGlobal` and a mocked `@shared/runtime/global`, so it can't run against the
   esbuild bundle; headless sources aliased in): harness `Device`s and a headless executor
   from the same template bytes, `globalThis.crypto.randomUUID` stubbed with the same
   seeded sequence, `setClock`, FX stub; same op sequence (including a continuous rule) ⇒
   equal `{op, args}`, `v` computed with `mutationFormatVersion` on both sides (the
   harness emits a constant), equal user tables; same `Idempotency-Key` twice, also
   concurrently and across a restart ⇒ one mutation in the server log and one row at the
   peer; kill at every write-path fault point then retry ⇒ one mutation in the log; a key
   change at the peer halts the headless with no further sends; a nack blocks writes and
   is visible in `/v1/status`; every argument guard has a rejecting test (unknown key,
   foreign-budget id, `opClock`, `transferId`, `importIdentities`, currency change,
   `from == to`).
3. **Deploy.** NAS upgrade to v1.22.1 (blob + DB backup first). Headless image built from
   the fork's pnpm workspace (stage 1 of `selfhost.Dockerfile` extended with
   `packages/headless`), mirrored to the Lazycat registry like the server image;
   `headless` service in the manifest bound to `/lzcapp/var/headless`; reachability from
   the Ambrogio container verified; confirm the NAS server doesn't set `APP_VERSION`.
   Real space **read-only until**: 7 days of `live` with `GET /v1/months/{current}`
   matching the web app's figures on 3 spot checks and zero halts; then `readOnly: false`.
4. **Ambrogio adapter** — separate project in the Ambrogio repo. Not designed here.

## Security

- Disk is trusted: the raw space key, `outbox.json` (prepared args in plaintext) and
  `idempotency.json` sit together in `/lzcapp/var/headless`; the decrypted DB is in
  memory only. Same trust level as the NAS root.
- JWT travels in the WebSocket query string (upstream design, internal network).
- REST on plain HTTP inside Lazycat's internal network, reachable by every app on the
  box: one bearer per consumer, constant-time compare, no token in logs/status/errors.

## Testing

- Unit: config/idle, serialised file writes, idempotency ledger (intent/acked/nacked,
  body hash, multi-op keys), ack wait/timeout, auth refresh, op-policy coverage, argument
  schemas, header / WS URL / outbound-frame contracts, "no upload function" contract.
- Bench (milestone 1): local server at the pin, `create-space`, `peer`, crash harness;
  parity test in the app's vitest (milestone 2).
- Never against the real space.

## Risks

- Space corruption through the log: mitigated by the app's own pipeline (U6), payload
  parity, argument schemas, the throwaway space, read-only first in production. Snapshot
  corruption: impossible by construction (no upload path).
- Restart cost: a full bootstrap each time; acceptable (seconds, LAN). If the NAS reboots
  nightly, that is one bootstrap per day.
- Availability: a halt makes reads 503 until the operator restarts; Ambrogio must handle
  503 gracefully (milestone 4).
- Upstream churn (weekly releases): pin to a tag; server and headless upgrade together;
  U1–U4 and U6 carried as a small patch stack until upstream takes them (issue #155).
- Version skew with phones/browsers on an older app: avoided by matching the server
  version, which the app's PWA also tracks.

## Left to the builder

- esbuild alias set and sql.js wasm loading.
- Exact JSON layout of `outbox.json` / `idempotency.json`, as long as the write
  discipline holds.
- Read response field names (amounts stay milliunits).
- Router choice.
