# M4 — Ambrogio adapter for the Budgero headless client

Date: 27/11/2026. Status: draft for Federico's approval. Milestone 4 of
`2026-11-24-budgero-headless-client-design.md` §12 ("Ambrogio adapter — separate project in the Ambrogio
repo; must handle 503, 202 polling, `requery`"). Code lands in the Ambrogio repo
(`~/Progetti/ambrogio`, bare; read at `origin/master` = `d0432308`, 25/11/2026). Paths below are in that repo.

## 1. Intent

Ambrogio records Federico's expenses in Budgero today through two indirect paths:

- **Writes** go to the encrypted Push API: they sit in a queue until the web app is opened, Ambrogio gets
  no confirmation and cannot read them back.
- **Reads** decrypt the synced snapshot (`src/budgeting/budgero-read.ts`): it can be days old, and the
  pushes not yet applied are merged in from Ambrogio's own registry (`budgero_push_log`).

The headless client (M1–M3, live on the NAS since 26/11/2026) is a peer of the space with a local REST API:
reads are current to the second, and a write answers only after the server has acknowledged it. M4 makes
Ambrogio use it, so Ambrogio reads the real budget (including what Federico enters by hand) and confirms what
it writes. This is issue #155's problem stated from the bot's side.

## 2. Goals, non-goals, anti-goals

**Goals**
- The six neutral tools keep their names and arguments: `create_transaction`, `create_transfer`,
  `update_transaction`, `delete_transaction`, `list_transactions`, `read_budget`
  (`src/tools/budget-transactions.ts`).
- Through the headless: writes acked by the server, ids of real rows, `list_transactions` and the duplicate
  guard over the whole budget, balances and category totals that are current.
- When the headless cannot take a write or serve a read, Ambrogio still works exactly as today
  (Push API, snapshot).
- Switching back to today's behaviour is one click in `/auth/budgeting`.

**Non-goals** (Federico, 27/11/2026: "solo sostituzione")
- No new capabilities: no assignments, no move money, no Ready to Assign, no recurring, no rules.
- YNAB untouched.
- Removing today's Budgero adapter: a later decision, after the new one has held.

**Anti-goals** (it works but it is a failure)
- The same expense registered twice: once through the headless and once through the Push API fallback.
- The prompt telling the model the budget is readable and current in a turn where the headless is down.
- Any token or password in logs, tool results or panel responses.
- A YNAB regression.

## 3. Constraints

- Headless API (spec §10, deployed `1.22.1-9`): base `http://172.18.0.1:8787` (Forward rule on the
  `lzc_docker` bridge, reachable only from NAS containers); `Authorization: Bearer <token>`; amounts in
  integer milliunits; writes need `Idempotency-Key` (16–128 chars `[A-Za-z0-9_-]`).
- Roles: `read` < `write` < `admin` (`packages/headless/src/config.ts:23`). The `operator` token (role
  `write`) reads too: Ambrogio needs that one token only. Today Ambrogio holds the `ambrogio:read` token.
- Write answers (spec §8.1, §10): `200 {results:[{id}], mutationIds}` (flags `partial`, `reordered`, and
  `result:null, requery:true` for a create whose id is no longer valid); `202 {status:"pending"|"blocked"|
  "unknown", mutationIds}`; `GET /v1/mutations/{id}` → `{id, state, version, reordered}`; `403
  policy|role|read_only`; `409 dropped`; `422 schema|failed|key_reuse` (`field` names the argument); `429`;
  `503` (gate closed or not live: **nothing executed**).
- The headless refuses before executing (422) what core would reject or silently change (27/11/2026 rules:
  `date`/`accountId` required, split lines name a category or a transfer account, transfer legs balanced in
  one currency, …). The adapter passes the refusal to the model, it does not pre-validate.
- What the headless does not do: change a transaction's account (`PATCH` columns are
  `outflowconverted, inflowconverted, categoryid, memo, date, payee`, plus `cleared`), and it never drains the
  Push API queue (only the web app does, `AppRuntime.processPushQueue`). A fallback push therefore waits for
  the web app, as today, and the headless does not see it until then.
- Read rows are core's PascalCase rows: transactions carry `ID, Date, Time, AccountID, Account, CategoryID,
  Category, Payee, Memo, InflowConverted, OutflowConverted, InflowNative, OutflowNative, TransferID,
  TransferAccountName, Cleared, SplitPayees, …`; accounts `ID, Name, Currency, OnBudget, Archived,
  BalanceConverted, BalanceNative, …`; `/v1/months/{m}` per-category `Assigned, Activity, Available`.
  Reads answer `{data, stale}`.

## 4. Approaches considered

1. **New provider "Budgero (headless)" beside today's, falling back to it** — chosen by Federico on
   27/11/2026. One more entry in the panel selector; the new adapter calls the old one when the headless
   cannot serve. Rollback is a click, today's tests stay as they are, a trial period is possible. Cost: two
   Budgero adapters until the old one is retired.
2. Rewrite today's adapter in place — one adapter in the end, but no side-by-side trial, no quick rollback,
   and ~3,000 lines of tests rewritten together with the code they pin.
3. New adapter with no automatic fallback — simplest, but when the headless is down Ambrogio stops
   recording expenses until Federico switches provider by hand.

Also decided: writes go through the headless too (option A of 27/11/2026, not reads only), with the Push
API and the snapshot as fallback.

## 5. Design

### 5.1 Provider and mode per turn

- `BUDGETING_PROVIDER_NAMES` gains `budgero_headless` (`src/budgeting/provider.ts`); the registry builds it
  with a reference to today's `budgero` provider (`src/budgeting/registry.ts`).
- **Mode**, resolved where a turn's prompt text is built (the chat prompt builder, and the scheduler's
  `budgetingDedupClause` for email and webhook turns): `GET /v1/status`, 1 s timeout. `state == "live"` ⇒
  mode **headless**; anything else (timeout, refused, non-200, another state) ⇒ mode **fallback**.
- In mode headless the provider reports `canRead = true` and the prompt takes the read+write branch (the
  YNAB-style clauses: `list_transactions` sees the whole budget and is the duplicate check). In mode fallback
  it reports `canRead = false` and the prompt is exactly what provider `budgero` produces today.
- *Builder's call (27/11/2026, from the builder check):* the mode changes **only the prompt text**, not the
  tools. A chat's tool server outlives the turn (warm pool, `composedKeyFor` in `src/llm/session-pool.ts`
  does not include the provider), so tool descriptions per mode would force a session rebuild on every
  headless up/down. The descriptions become **neutral** and true in both modes (5.7), and the **handlers
  decide per call**: every call tries the headless first and falls back on its own (5.2, 5.3). A turn that
  probed as fallback but finds the headless up writes through it; the result says the write was confirmed,
  which is only better than what the prompt promised. The opposite case (probed live, headless down at the
  call) is the call-level fallback, and its result says so in words ("headless non raggiungibile: registrata
  in coda Push, visibile alla prossima apertura dell'app").

### 5.2 Writes

| Tool | Headless call | Notes |
|---|---|---|
| `create_transaction` | `POST /v1/transactions` | euro → milli as today (`Math.round(eur*1000)`, sign → `outflow`/`inflow`); account and category by id or name (5.5); no category ⇒ the Uncategorized id, as today; splits → `splits[{categoryId \| transferAccountId, inflow \| outflow, memo, payee}]`; payee by name |
| `create_transfer` | `POST /v1/transfers` | source `outflow`, destination `inflow`, same milli amount; accounts in different currencies ⇒ refused with a clear error (the neutral tool has one amount) |
| `update_transaction` | `PATCH /v1/transactions/{id}` | amount → both `outflow` and `inflow` (the old direction is zeroed), date, payee, memo, categoryId, cleared; a change of `accountId` ⇒ clear error "cambiare conto non si può: cancella e ricrea" |
| `delete_transaction` | `DELETE /v1/transactions/{id}` | |

- **Idempotency.** One key per logical write, generated when the tool call starts and reused on every
  retry inside that call; it is written to the local registry (5.4), state `sending`, before the request goes
  out. *Builder's call:* there is no replay at startup. A restart kills the call; the row stays `sending`,
  counts for the duplicate guard (5.4), and the next headless read closes it (5.4). The model's new call after
  a restart is a new write, and the duplicate guard is what stops it from registering the same expense
  twice.
- **Answers:**
  - `200` ⇒ success with the row id (`transactionId` = the headless id). `partial` ⇒ error naming what
    did not land. `reordered` with `requery:true` ⇒ the write landed but its id is unknown: query
    `/v1/transactions` (same date, account, payee, amount) for the id; none or several ⇒ success with
    `transactionId: null` and the text "registrata; id da rileggere con list_transactions".
  - `202 pending` ⇒ poll `GET /v1/mutations/{mutationId}` (1 s, then 2 s…, up to 15 s); acked ⇒ as
    `200`; still pending ⇒ success with `status: "pending"` and the text "accettata dall'headless, in
    attesa di conferma dal server". `202 blocked|unknown` ⇒ the same, worded as "in attesa".
    **Never a fallback after a 202.**
  - `422` ⇒ error to the model with `field` (the model corrects the argument; no fallback).
  - `403 read_only` ⇒ fallback (the headless is in read-only mode: it executes nothing). Other `403`,
    `409` ⇒ error.
  - `429` ⇒ error "troppe scritture fallite di fila, riprova fra qualche minuto" (no fallback: the headless
    is up, it is protecting itself).
  - `503`, connection refused, DNS failure, timeout **before** the request was sent ⇒ fallback (nothing
    executed).
  - Timeout **after** the request was sent, or a reset mid-response ⇒ ambiguous: retry the headless with
    the same key (3 attempts over ~10 s); still no answer ⇒ error "esito incerto, non ritentare con altri
    strumenti", and the registry row stays `unknown`. Never a fallback, because the headless may have
    executed it.
- **Fallback for writes:** `create_transaction` and `create_transfer` call provider `budgero` (Push API).
  `update_transaction` and `delete_transaction` on a headless id cannot fall back (the Push API addresses
  only its own pushes): error "headless non raggiungibile, riprova più tardi". On an id that is a Push
  message id (a row written by today's adapter or by a fallback), they go to provider `budgero` as today.

### 5.3 Reads

- **`list_transactions`**: `GET /v1/transactions?since=&limit=` (filters on payee, account and category
  substrings applied client side, after normalisation as today); same output fields as today plus `id` =
  headless id. Rows Ambrogio pushed through the fallback and not yet applied are appended with
  `pending_sync: true`, as `read_budget` does today. They are recognised as applied when the snapshot's
  `import_provenance` says so, which is today's test (`budgero-read.ts:367-417`); this reading of the
  snapshot happens only when the registry holds such rows. The note "solo transazioni registrate da
  Ambrogio" disappears in mode headless.
- **`read_budget`**: same three views and the same output shape as today (`budgero-read.ts`).
  - `balances` ← `/v1/accounts` (`BalanceConverted`, native balance when the currency differs, archived
    excluded and counted);
  - `transactions` ← `/v1/transactions` (split lines and transfer collapsing as today);
  - `category_totals` ← aggregated from `/v1/transactions`.
  - `as_of` = the time of the read, no `staleness_warning`, and rows carry ids. The limits and caps of today
    (50/500 rows, 20,000 characters) stay.
- **Fallback for reads:** connection failure, timeout, `503` ⇒ provider `budgero` (snapshot), whose answer
  already carries `as_of` and `staleness_warning`.

### 5.4 Duplicate guard, instalment guard, registry

- `budgero_push_log` stays, and records every write of the new adapter too, with new columns: `mode`
  (`headless` | `push`, today's rows `push`), `headless_id`, `idem_key`, `mutation_ids`, `state` (for
  headless rows: `sending`, `acked`, `pending`, `unknown`).
- *Builder's call:* rows in `sending`, `pending` or `unknown` are closed **lazily**: on the next headless read
  or write, each one with `mutation_ids` is checked with `GET /v1/mutations/{id}` (acked ⇒ `acked` with its
  id; dropped or failed ⇒ the row is deleted); one without `mutation_ids` (never answered) is matched against
  `/v1/transactions` by date, account, payee and amount, and deleted when absent after 10 minutes. No
  background job.
- *Builder's call:* today's provider `budgero` reads the table with `mode = 'push'` for `listTransactions`
  and for the `pending_sync` merge in `readBudget` (a headless row never has Push provenance and would stay
  pending forever), and with **every** row for its duplicate guard (a fallback write right after a headless
  one must see it). This is the only change to the old adapter, with its tests.
- **Duplicate guard** (same normalised payee, same amount, date within ±3 days): in mode headless it looks
  at the budget (`/v1/transactions` over the window) plus the registry's not-yet-applied pushes. So it also
  catches an expense Federico entered by hand. The result stays `{success:false, duplicate:true, …}`, and
  `force:true` skips it.
- **Instalment guard** (`budgero.ts:448-496`): it reasons on when Ambrogio sent the pushes, so it keeps
  reading the registry, now fed by both modes.
- Both guards and the write stay serialised in the same in-process chain as today (`budgero.ts:244-252`).

### 5.5 Name → id maps

In mode headless, accounts and categories are resolved from `/v1/accounts` and `/v1/categories`, cached for
the turn, with the same matching rules as `resolveMapped` (`budgero.ts:189-208`: id as is, literal, normalised,
unique prefix; ambiguous or missing ⇒ error listing the names). The resolution also rewrites the
`agent_settings` maps that the fallback uses, so the panel's "sync" button stops being needed. The button
stays, for the fallback.

### 5.6 Secrets and panel

- New secrets in `src/secrets/catalog.ts` (group `finance`, feature `ynab`, `bootEnv: false`):
  - `BUDGERO_HEADLESS_URL`, default `http://172.18.0.1:8787`;
  - `BUDGERO_HEADLESS_TOKEN`, the `operator` token, entered by Federico in the panel and never shown back.
- The `/auth/budgeting` selector gains "Budgero (headless)". Switching to it requires the headless secrets
  plus today's Budgero prerequisites, because the fallback needs them; otherwise `400 budgero_not_ready` as
  today. The panel shows the result of the status probe: live / unreachable / state.

### 5.7 What the model reads

- `src/llm/prompt.ts:2255-2293` (the `<budgeting_provider write_only>` block) and
  `src/scheduler/engine.ts:3143-3169` (`budgetingDedupClause`) already switch on `canRead`. Mode headless
  takes the `canRead = true` branch, mode fallback today's.
- The tool descriptions in `budget-transactions.ts` hard-code Budgero's write-only behaviour (lines 78-83, 117,
  140, 168, 191-201, 230-231). They become neutral: true for YNAB, `budgero` and both modes of
  `budgero_headless`, with the behaviour that differs (queue vs confirmed, `as_of`, `pending_sync`, which
  rows `list_transactions` sees) moved to the per-turn `<budgeting_provider>` block and to the tool results,
  which always say what happened. They stay static, so the warm pool is untouched.
- `POLICY.md` §16 lines 575-590 and 619 speak of a dated budget and of `list_transactions` seeing only
  Ambrogio's rows. `POLICY.md` is static and cached, so those lines move into the per-turn
  `<budgeting_provider>` block (fallback wording) and POLICY keeps the provider-neutral rule.

## 6. Verification

- Unit tests with a fake headless (HTTP stub):
  - every answer of 5.2: `200`, `partial`, `reordered`+`requery`, `202` → poll → acked or pending, `422`
    with `field`, `403 read_only`, `409`, `429`, `503`;
  - pre-send failure ⇒ fallback;
  - post-send timeout ⇒ retry with the same key, never fallback;
  - mode resolution on probe timeout and on a non-live state.
- **The anti-goal pinned:** no sequence of answers leads to both a headless write and a Push API write for
  one tool call. A test drives every answer and asserts at most one of the two.
- Prompt and tool-text guards: mode headless gets the read+write wording, mode fallback today's
  `<budgeting_provider>` block. Today's guard tests are updated where they pin text that moves (tool
  descriptions, POLICY §16) and keep passing for provider `budgero`.
- Registry: a `sending`/`pending`/`unknown` row is closed by the next read; it counts for the duplicate
  guard while open; provider `budgero` lists only `mode = 'push'` rows.
- Contract check against the real headless on the bench (`packages/headless` bench, server v1.22.1): one
  create, one transfer, one update, one delete, a list, a `read_budget`, a `422`.
- Trial in production: provider switched in the panel, a week of Federico's normal use. Success means:
  - no duplicate;
  - every write either acked or visibly pending;
  - `read_budget` balances match the web app;
  - any fallback episode reported in the tool result and in the logs.

## 7. Left to the builder

- Exact poll schedule and retry counts (the bounds above are the intent).
- How the per-turn mode is threaded to the tool handlers and the prompt builder: following today's provider
  snapshot pattern.
- Migration for the three registry columns (the migration count is pinned in
  `tests/scheduler/migration.test.ts`).
- Wording of the new model-facing texts, through the project's prompt-guard tests.
- Whether `delete` of one transfer leg removes both on the headless (core `transactions.delete` on a
  transfer): verify on the bench and word the tool result accordingly.
