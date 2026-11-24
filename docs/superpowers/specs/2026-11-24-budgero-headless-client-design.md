# Budgero headless client — design

Date: 24/11/2026. Status: draft v2, after review round 1 (two adversarial reviewers, 7
critical + 10 important findings, all verified in code and folded in below).
Upstream proposal: https://github.com/tombadilo-bombadilo/budgero/issues/155 (no answer yet; we start anyway).
Code references are to upstream master `e40723e` (v1.22.1 + v1.22.2 release merge).

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
injection points upstream (U1–U4).

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
  unused); lifecycle doesn't require the master password; local persistence cipher is
  disabled (plaintext at rest, see Security); `ensureSpaceKeys` runs only for that space
  and activation targets it instead of `primary_space_id`.
- **U2 — injected queue storage.** `runtime-context-factory.ts:201` passes a
  `QueueStorage` from deps to `new OfflineQueue(spaceId, storage)` (constructor already
  accepts it, `offline-queue.ts:56`).
- **U3 — upload veto.** `canUploadSnapshot?: () => boolean` in deps, checked by
  `DatabaseSync` before every upload (incl. out-of-band); and a `onMutationQuarantined`
  callback.
- **U4 — 409 restore = full restore.** `DatabaseSync`'s conflict restore goes through the
  same post-restore path as the coordinator (migrations + `reconcileSpaceScope` +
  `requestCatchUp`).
- **U5 — atomic push claim** (server): `UPDATE push_queue SET status='processing' WHERE
  id=? AND status='pending'`, rows affected = 1, plus the app using it. Prerequisite for
  any future headless push processing; not built in this project.

### Platform pieces (packages/headless/src/platform)

- `state-store.ts` — **one durable container** for DB + key/value state. The localStorage
  shim buffers `setItem` in memory; the buffer is committed atomically **together with**
  the next DB persist (write temp dir with `space.sqlite` + `storage.json`, fsync files,
  rename over the live dir, fsync parent). State can therefore never lead the DB.
  `getItem` reads the buffered value.
- `database.ts` — `createDatabase()` = `NodeSqlJsAdapter` wrapped with `forceSave()` (calls
  `state-store.commit()`, resolves after fsync) and a `restore()` that commits before
  returning, like the web adapter. This makes `persistDatabase` return `true`, enabling the
  runtime's own cursor/applied-id ordering.
- `queue-storage.ts` — file-backed `QueueStorage` (U2); `save` resolves after fsync.
- `http.ts` — port of the app's `blobApi` / `spacesApi` (no Clerk/zustand/env): every
  header the app sends (`X-Data-Format-Version`, `X-Budgero-Protocol`,
  `X-Database-Version`, `X-Encryption-Key-Version`, `X-Mutation-Version`, optional
  `X-Out-Of-Band`, `X-Client-Session`, bearer); `downloadBlob` null only on 404; 409 errors
  expose `status` and `response.error` for `getConflictDetails`. Base URL also for the
  core's relative FX path. A contract test asserts headers against the app's
  `api-client.ts` at the pinned tag.
- `websocket.ts` — `globalThis.WebSocket` shim (`ws` package) sending
  `Origin: <BUDGERO_ORIGIN>`; `getWebSocketUrl` builds `token`, `space_id`,
  `protocol=SYNC_PROTOCOL_VERSION`, `client_session` (same id as HTTP). Test asserts the URL.
- `global.ts` — replacement for `@shared/runtime/global` exposing **full**
  `services()`, `mutationsRouter()` and the `mutationHistory` id-reuse API; startup fails if
  any is missing (prevents `withLegacyFormat` silently downgrading formats).
- `lingui.ts` — stub for `@lingui/core/macro` (`t`/`msg` → interpolated English source).
- Logging: core/runtime logs routed through a redactor (no args/params, no tokens); the
  `NodeSqlJsAdapter` failure logs (params) are redacted.

### Client pieces (packages/headless/src/client)

- `auth.ts` — `POST /api/v1/auth/local/login`; re-login before expiry and on 401.
- `runtime.ts` — stock `RuntimeCoordinator` with U1–U4 deps: `spaceKeySource`, queue
  storage, `canUploadSnapshot`, quarantine callback, `getWebSocketUrl`, `reloadApp` and
  key/password-change callbacks wired to Halting. Bootstrap (snapshot vs catch-up) is the
  coordinator's own activation path; we never seed the cursor by hand.
- `execute.ts` — port of `AppRuntime.executeMutation`: `prepareMutationArgs` → coordinator
  `executeMutation` → continuous-rules post-hook; plus `recordHistory` and
  `resolveHistoryBudgetId` (`app-runtime.ts:131-151, 906-1155`), so `mutation_history` in
  our snapshots matches the app's.
- `idempotency.ts` — REST `Idempotency-Key` → mutation id `hdl_<sha256(key)>`; before
  executing, check `isMutationApplied`/outbox; on a hit return the stored result. The
  key→result map lives in `storage.json`, so it commits with the DB.

### Read-only is structural

`HEADLESS_READ_ONLY=true` (milestone 1, and the first days in production) builds the
coordinator with `uploadBlob`, `uploadEncryptedKey` and the mutation send path replaced
by stubs that throw, `canUploadSnapshot = () => false`, and the REST layer without write
routes. No code path can write to the server.

### Halting

Any of: `FormatTooNewError`, `UnknownOpCodeError`, HTTP 426, a quarantined or failed
remote mutation, key or password change, server version ≠ bundled version (checked at
startup via `appmeta`). Then: `destroy()` transport and context, freeze the outbox (no
resend), `canUploadSnapshot` false, writes return 503, reads keep serving the last good
state with `stale: true`. Restart only by operator action (container restart after the
cause is fixed). Never auto-reload, never re-key.

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
  rename; recurring create/update/pause; rules create/update (not execute).
- `destructive` (only with `HEADLESS_ALLOW_DESTRUCTIVE=true`): `budgets.delete`,
  `accounts.delete`, `transactions.deleteBatch`, `transactions.batchEdit`,
  `transactions.reassign`, `transactions.reconcile`, `transactions.deleteByRef`,
  `payees.deleteMany`, `payees.removeUnused`, `categories.deleteAndReassign`,
  `categoryGroups.delete`, `categoryGroups.deleteAndReassign`,
  `monthlyBudgets.batchUpsertAssignments`, `rules.execute` (and only with non-empty
  `transactionIds`, max 500).
- closed: `history.applyOps`, `history.redoWithIds`, `history.restoreRows` (they wrap
  arbitrary ops/rows), `transactions.import`, `importHistory.*`, `bankSync.*`, `chat.*`,
  `llmSettings.*`, and anything unlisted.

Argument guards in the REST layer, before `prepareMutationArgs`: strip caller-supplied
generated ids, `mutationId`, `meta`, `idempotencyKey`; force `budgetId =
BUDGERO_BUDGET_ID`; for ops addressed by row id, load the row and reject if it belongs
to another budget; `accounts.update` rejects a currency change.

The final names are fixed in the plan from the registry at the pinned tag (the review
found `transactions.update` and `accounts.close` don't exist).

### Config (files under `/lzcapp/var/headless`, no file ⇒ idle)

`config.json` (non-secret): `url` (`http://budgero.cloud.lazycat.app.budgero.lzcapp:3001`),
`origin` (the app's public origin, must be in `WEBSOCKET_ALLOWED_ORIGINS`), `user`,
`spaceId`, `budgetId`, `readOnly`, `allowDestructive`, `port` (8787).
Secret files, mode 600: `password`, `space.key` (raw base64, from Settings → Push API →
export), `tokens` (one bearer per consumer, one per line, `name:token`).
With no `config.json` the service idles, `/v1/status` says `not_configured`, and it never
contacts the server. `TZ=Europe/Rome` in the container. `local.env` is not used (it is a
build-time manifest substitution, not runtime config).

### REST API (v1)

Bearer from `tokens`, constant-time compare; token never echoed. Amounts in integer
milliunits.

- `GET /v1/status` — state (`not_configured|syncing|live|halted`), halted reason, cursor,
  stale, versions. No secrets.
- `GET /v1/accounts`, `/v1/category-groups`, `/v1/categories`, `/v1/payees`,
  `/v1/transactions?account=&category=&payee=&since=&until=&cleared=&limit=&offset=`,
  `/v1/transactions/{id}`, `/v1/months/{YYYY-MM}` (assigned/activity/available per
  category, Ready to Assign), `/v1/recurring` — via core services, budget `BUDGERO_BUDGET_ID`.
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
- **Version**: build on the latest upstream tag at start; NAS (v1.21.5) upgraded to that
  tag in milestone 3 after a blob + DB backup (one-way migrations). Headless refuses to
  run against a different server version.
- **Push queue**: not processed by the headless (needs U5).

## Milestones

1. **Read-only client.** U1, U2, U4 + platform pieces + read routes + Halting.
   Done when, against a throwaway space on a local `budgero serve` at the pinned tag:
   a transaction added in the web app appears in `GET /v1/transactions` within 5 s;
   restart resumes from cursor without re-downloading; month numbers equal the web app's
   for 3 months; **kill-at-every-await crash test** (kill during catch-up apply, during
   restore, during commit) never yields a doubled or missing row after restart; a forced
   409 restore and an out-of-band upload from the web app both converge; header and WS URL
   contract tests pass.
2. **Writes.** U3 + execute/idempotency + op policy + write routes.
   Done when, on the throwaway space: ops via REST appear live in an open web app;
   **parity**: the same op sequence through headless and through the app's fuzz harness
   yields identical DB **and byte-identical emitted payloads `{op, args, v}`**; retrying a
   request with the same `Idempotency-Key` never adds a row; killing mid-outbox delivers
   each mutation exactly once; a key change from the web app halts the headless with no
   further sends; a remote mutation made to fail (test hook) halts instead of quarantining.
3. **Deploy.** NAS upgrade (backup first), `fliva/budgero-headless:<budgero version>` built
   from the same tag as the server image, `headless` service in the manifest bound to
   `/lzcapp/var/headless`, reachability from the Ambrogio container verified. Real space
   read-only for a few days, then writes.
4. **Ambrogio adapter** — separate project in the Ambrogio repo. Not designed here.

## Security

- Disk is trusted: the decrypted SQLite, outbox and the raw space key sit together in
  `/lzcapp/var/headless` (the app encrypts its local copy; we don't, U1 disables the
  cipher). Same trust level as the NAS root.
- JWT travels in the WebSocket query string (upstream design, internal network).
- REST on plain HTTP inside Lazycat's internal network, reachable by every app on the
  box: one bearer per consumer, constant-time compare, no token in logs/status/errors.

## Testing

- Unit: config/idle, state-store atomicity, auth refresh, op-policy coverage, argument
  guards, header and WS URL contracts.
- Integration: local `budgero serve` at the pinned tag + headless + app harness as second
  client, throwaway space from a setup script; crash and parity tests above.
- Never against the real space.

## Risks

- Space corruption: mitigated by the stock coordinator, structural read-only, durability
  container, halting on quarantine/key change, payload parity, throwaway space, read-only
  first in production, server snapshot history (`SNAPSHOT_HISTORY_KEEP=10`) as restore path.
- Upstream churn (weekly releases): pin to a tag; server and headless upgrade together;
  U1–U4 carried as a small patch stack until upstream takes them (issue #155).
- Version skew with phones/browsers on an older app: a newer headless can migrate the
  blob and lock older clients out (`DatabaseNewerThanAppError`); avoided by matching the
  server version, which the app's PWA also tracks.

## Left to the builder

- esbuild alias set and sql.js wasm loading.
- State-store directory layout details, as long as the atomic-commit invariant holds.
- Read response field names (amounts stay milliunits).
- Router choice.
