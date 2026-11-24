# Budgero headless client — design

Date: 24/11/2026. Status: draft for approval (op policy decided by Federico 24/11).
Upstream proposal: https://github.com/tombadilo-bombadilo/budgero/issues/155 (no answer yet; we start anyway).

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
read everything and run **any** operation. First consumer: Ambrogio. Later: the native
Android app (separate project) may reuse the same pieces.

## Goals

1. Joins a space as a regular client: snapshot download, WebSocket catch-up and live
   mutation stream; local decrypted SQLite always current.
2. REST API, bearer-token protected:
   - read: accounts, category groups and categories, payees, transactions (filters:
     account, category, payee, date range, cleared, limit/offset), month budget
     (assigned / activity / available per category, Ready to Assign), recurring;
   - write: **every op in the app's registry** through one generic endpoint, plus typed
     convenience endpoints for the frequent ones (add/update/delete transaction,
     transfer, assign to category, move between categories);
   - meta: sync status (connected, cursor, last remote mutation, pending acks).
3. Writes are real mutations: other open clients see them immediately (no push queue).
4. Applies the Push API queue (poll), so pushed items no longer wait for a browser.
5. Survives restarts without a full re-download: cursor, applied ids, outbox and DB
   persisted on disk.
6. Ships as a second service of the `lzc-budgero` Lazycat package, built from the same
   upstream tag as the server.

## Non-goals

- No UI. No multi-space, multi-user: one process = one space, one user.
- No SaaS (my.budgero.app / Clerk auth): self-host local login only.
- No master-password change, key rotation, sharing/invites, imports from files, bank
  sync, chat/LLM features. If the server signals a key or password change, the client
  stops and says so; it never re-keys.
- No public exposure: the REST API listens on the Lazycat internal network only.
- Not an upstream PR yet: code is written so it *can* become one (issue #155), but we
  don't wait for the maintainer.

## Anti-goals (failure even if it "works")

- **Corrupting the space for other devices.** A headless writer uploads snapshots that
  phones and browsers restore. Any divergence from the app's op semantics (ids, clocks,
  mirror amounts, rules post-hook) poisons every device.
- Reimplementing op logic. We execute the app's own registry, never a copy.
- Silent version drift: an older client applying newer mutations wrong. It must halt,
  as the app does (`FormatTooNewError`, `UnknownOpCodeError`, HTTP 426).
- Holding the key anywhere but this process and its secret file.
- Creating or uploading a space key. `KeyVault.provisionSpaceKey` generates and uploads a new
  key for an owner with no wrapped key: the headless client loads the raw key directly and
  must never reach that path; if the key can't be loaded it stops.

## Constraints (from the code, upstream master at v1.22.1)

- `@budgero/core` (isomorphic, sql.js, `NodeSqlJsAdapter`) and `@budgero/runtime`
  (sync transport, crypto, key vault, offline queue, DB sync) are workspace-private,
  built with plain `tsc`; runtime uses extensionless imports with bundler resolution,
  so plain Node can't load it: **we bundle with esbuild**.
- The op registry (`packages/app/src/shared/mutations/op-code-registry*`, ~160 ops)
  imports only `@budgero/core/browser`, `@budgero/runtime`, the Lingui macro and the
  `@shared/runtime/global` singleton. No React, window or IndexedDB in it.
- `AppRuntime` and `runtime-bridge` pull in Clerk, posthog, `import.meta.env`, `window`:
  we **reimplement** the parts we need (`executeMutation` incl. continuous-rules
  post-hook, `processPushQueue`) instead of importing them.
- Runtime persists sync state in `localStorage` (cursor, blob version, key version,
  applied ids) and the outbox in IndexedDB (hardcoded in `runtime-context-factory.ts`).
- Existing headless harness to start from: `packages/app/src/shared/mutations/fuzz/harness.ts`
  (real sql.js + ServiceManager + AppRuntime.executeMutation + MutationExecutor + registry).
- Self-host JWT lifetime defaults to 24 h (`SELF_HOST_JWT_TTL_HOURS`): re-login needed.
- Snapshot upload is per-writer, debounced (20 mutations / 5 min), CAS on
  `X-Database-Version`, 409 → download/restore/retry. Server keeps
  `SNAPSHOT_HISTORY_KEEP=10` replaced snapshots (restore path if we break something).

## Approaches considered

| | What | Verdict |
|---|---|---|
| **A. Full client in the fork** | `packages/headless` bundles registry + runtime + core, small reimplemented `AppRuntime` subset, file-backed state | **Chosen** (Federico, 24/11). Same semantics as the app, any op, live sync; same shape as the upstream PR. Cost: version lock-step with the server |
| B. Snapshot read + Push API write | Package what Ambrogio does as REST | Rejected: writes stay queued until a browser opens, only transactions |
| C. Hand-crafted mutations | Build op payloads ourselves | Rejected: must replicate `prepareMutationArgs` exactly; first divergence corrupts the space |

## Design

### Where the code lives

- Fork `f-liva/budgero` (local `~/Progetti/budgero`, remotes `origin` = upstream,
  `f-liva-fork` = ours). Branch `feat/headless-client` from `origin/master`.
- New workspace package `packages/headless` (TypeScript, Node 22). Upstream code is
  touched only where an injection point is missing, each change small and upstreamable
  (see "Upstream changes").
- Deployment bits stay in `lzc-budgero` (Dockerfile stage, manifest service, docs).

### Process layout

```
packages/headless/src/
  main.ts            # config, boot, signal handling
  config.ts          # env + secret files, validated (zod or hand-rolled)
  platform/
    storage.ts       # localStorage shim backed by <state>/storage.json (atomic write)
    queue-storage.ts # file-backed QueueStorage for the outbox (<state>/outbox/)
    database.ts      # createDatabase(): NodeSqlJsAdapter + persist to <state>/space.sqlite
    fetch.ts         # fetch wrapper: base URL for relative paths (FX rates), auth header
    lingui.ts        # stub for '@lingui/core/macro' t``/msg`` (English source strings)
    global.ts        # replacement for '@shared/runtime/global'
  client/
    auth.ts          # POST /api/v1/auth/local/login, JWT cache, refresh before expiry / on 401
    runtime.ts       # builds RuntimeCoordinator deps; activates the one space
    execute.ts       # reimplemented AppRuntime.executeMutation (+ rules post-hook)
    push-queue.ts    # reimplemented AppRuntime.processPushQueue, polled
  api/
    server.ts        # node:http, no framework; JSON in/out; bearer check
    routes/*.ts      # read endpoints (via core services), ops, status
```

esbuild bundles `main.ts` with aliases: `@shared/*` → app sources, `@lingui/core/macro`
→ `platform/lingui.ts`, `@shared/runtime/global` → `platform/global.ts`. Output: one
`dist/headless.mjs` + `sql.js` wasm next to it.

### Secrets and config

| Env | Meaning |
|---|---|
| `BUDGERO_URL` | server base, e.g. `http://budgero.cloud.lazycat.app.budgero.lzcapp:3001` (the Go server directly, not the Lazycat sidecar) |
| `BUDGERO_USER` / `BUDGERO_PASSWORD_FILE` | self-host local login |
| `BUDGERO_SPACE_ID` | the space to join |
| `BUDGERO_BUDGET_ID` | the one budget the API serves (a space can hold several; Federico's has one, id 4). Startup fails if it doesn't exist |
| `BUDGERO_SPACE_KEY_FILE` | raw base64 space key (Settings → Push API → export). Used for both mutations and snapshot passphrase; master password never needed |
| `HEADLESS_TOKEN_FILE` | bearer token required on every REST call |
| `HEADLESS_STATE_DIR` | default `/data` |
| `HEADLESS_PORT` | default `8787` |
| `HEADLESS_READ_ONLY` | `true` in milestone 1; refuses every write and never uploads |
| `HEADLESS_PUSH_POLL_SECONDS` | default 60, `0` disables |
| `HEADLESS_ALLOW_DESTRUCTIVE` | default `false`; enables the `destructive` op tier |

Secret files mode 600; values never logged.

### Sync lifecycle

1. Login → JWT. List spaces, check `BUDGERO_SPACE_ID` exists and our role can write.
2. If `<state>/space.sqlite` and cursor exist: open them. Else: download snapshot,
   decrypt (BGE1 with `base64(spaceKey)`), LZ4, restore; cursor from `X-Mutation-Version`.
3. Open WebSocket (`deps.getWebSocketUrl` injected), catch-up from cursor, then live.
   Remote mutations go through the registry's executor exactly as in the app.
4. Persist DB to disk after each applied batch (debounced ~2 s) and on SIGTERM.
5. Snapshot upload only through runtime's `DatabaseSync` (same debounce, CAS, 409
   handling as the app), and only when not read-only.
6. `FormatTooNewError` / `UnknownOpCodeError` / 426 / key or password change: stop
   applying, mark status `halted:<reason>`, REST reads keep working on the last good
   state, writes return 503. Never auto-reload, never re-key.

### REST API (v1)

All JSON, `Authorization: Bearer <HEADLESS_TOKEN>`, amounts as integer milliunits (as
Budgero does internally) plus a formatted string where useful.

- `GET  /v1/status` — sync state, cursor, halted reason, app format versions.
- `GET  /v1/accounts`, `/v1/category-groups`, `/v1/categories`, `/v1/payees`
- `GET  /v1/transactions?account=&category=&payee=&since=&until=&cleared=&limit=&offset=`
- `GET  /v1/transactions/{id}`
- `GET  /v1/months/{YYYY-MM}` — per category assigned/activity/available, Ready to Assign
- `GET  /v1/recurring`
- `GET  /v1/ops` — op names with format versions (from `OP_CODE_FORMAT_VERSIONS`)
- `POST /v1/ops/{op}` — body = op args; runs `prepareMutationArgs` + execute + dispatch;
  returns the op result and the mutation id. Idempotency via `Idempotency-Key` header.
  **Op allowlist** (Federico, 24/11): only ops named in `api/op-policy.ts` pass; anything
  else, including ops a future upstream release adds, returns 403 until we list it.
  Three tiers in that file:
  - `allowed`: transactions (add/update/delete single, splits, transfers, cleared,
    reconcile), monthly assignments and moves, categories and groups (create/rename/
    reorder/hide), accounts (create/update/close), payees, recurring, rules;
  - `destructive`: `budgets.delete`, `accounts.delete`, `transactions.deleteBatch` and any
    other op that removes a budget, an account or many rows at once; they pass only with
    `HEADLESS_ALLOW_DESTRUCTIVE=true`, otherwise 403 with the reason;
  - everything else is closed, explicitly including `transactions.import`,
    `importHistory.*`, `bankSync.*`, `chat.*`, `llmSettings.*`.
  The exact op names come from the registry at the pinned tag; a test fails if the policy
  names an op the registry doesn't have, and lists registry ops not in any tier (so an
  upgrade shows what's new).
- Convenience (thin wrappers over `/v1/ops`): `POST /v1/transactions`,
  `PATCH /v1/transactions/{id}`, `DELETE /v1/transactions/{id}`, `POST /v1/transfers`,
  `PUT /v1/months/{YYYY-MM}/categories/{id}/assigned`.

Reads go straight to `@budgero/core` services (`ServiceManager`), the same calls the
app's pages make; no raw SQL in the API layer.

### Upstream changes (small, upstreamable)

1. `runtime-context-factory.ts`: accept an injected `QueueStorage` (today hardcoded
   IndexedDB `OfflineQueue`).
2. Possibly: a storage abstraction instead of direct `localStorage` in
   `utils/stored-version.ts` / offline-queue applied ids. Start with the shim; change
   upstream only if the shim proves fragile.

Each one is its own commit, so it can go to a separate upstream PR.

## Decisions settled during review (24/11, Claude's calls, correctable)

- **One budget**: `BUDGERO_BUDGET_ID`, every route and op scoped to it; no budget parameter.
- **Reachability**: Lazycat apps resolve each other's `*.lzcapp` service names (the
  cloudflared app already reaches every other app this way), so Ambrogio calls
  `http://headless.cloud.lazycat.app.budgero.lzcapp:8787` with no ingress route. No
  `public_path`, no tunnel hostname.
- **Store package**: `lzc-budgero` is published in the store, so the `headless` service is
  optional: with no `local.env` settings / secret files it idles, `/v1/status` says
  `not_configured`, and it never contacts the server. Configuration via `local.env` and files
  under `/lzcapp/var/headless`.
- **Version**: build against the latest upstream tag when work starts (v1.22.x); the NAS
  (v1.21.5 today) is upgraded to that tag in milestone 3, with a blob + DB backup first,
  because upstream DB migrations are one-way.

## Milestones

1. **Read-only client.** Boot, login, snapshot, live sync, persistence, all read
   endpoints, `/v1/status`. `HEADLESS_READ_ONLY=true`, no upload path reachable.
   Done when: against a throwaway space on a local `budgero serve`, a transaction added
   in the web app appears in `GET /v1/transactions` within 5 s; restart resumes from
   cursor without re-downloading the snapshot; month numbers equal the web app's for 3
   months.
2. **Writes.** `/v1/ops/{op}` + convenience endpoints, outbox persistence, snapshot
   upload, push-queue applier. Done when: on the throwaway space, ops run via REST show
   up in an open web app live; the fuzz/undo-integrity style parity check passes
   (same op sequence via headless and via the app harness ⇒ identical DB); killing the
   process mid-outbox and restarting delivers each mutation exactly once; a pushed item
   is applied within one poll interval with no browser open.
3. **Deploy.** `lzc-budgero` builds `fliva/budgero-headless:<budgero version>` from the
   same tag as the server image; manifest gets a `headless` service bound to
   `/lzcapp/var/headless`. Only after milestone 2 passes on the throwaway space do we
   point it at the real space, read-only first for a few days, then writes.
4. **Ambrogio adapter** — separate project in the Ambrogio repo (replace blob decoding
   and push queue with REST calls). Not designed here.

## Testing

- Unit: config, auth refresh, storage shim atomicity, routes (with an in-memory DB).
- Integration: local `budgero serve` (Go server from the same tag) + headless + the
  harness as a second client; throwaway space created by a setup script.
- Never run tests against the real space.

## Risks

- **Space corruption** (anti-goal 1): mitigated by executing the app's registry, the
  parity check, the throwaway space, read-only first in production, and the server's
  snapshot history as a restore path.
- **Upstream churn**: registry and runtime internals change often (v1.22.x weekly).
  Pin to a tag; the Lazycat package upgrade bumps server and headless together.
- **Lingui stub**: op errors/labels in English source text only; fine for an API.

## Left to the builder

- Exact esbuild alias set and how to load sql.js wasm from the bundle.
- File layout of the outbox and state files (atomic rename, fsync policy).
- Shape of read responses (field names), as long as amounts stay milliunits.
- Whether to use a tiny router or hand-rolled `node:http` dispatch.
