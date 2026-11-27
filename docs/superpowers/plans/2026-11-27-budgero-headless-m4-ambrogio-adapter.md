# M4 — Ambrogio adapter for the Budgero headless — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a budgeting provider `budgero_headless` in Ambrogio that reads and writes Budgero through the headless
REST API, falls back to today's `budgero` provider (Push API, snapshot) when the headless cannot serve, and
keeps the six neutral tools unchanged.

**Architecture:** a thin HTTP client classifies every outcome (answered / not sent / ambiguous); a health
module keeps a synchronous "headless live" flag refreshed every 30 s and after every call; a write executor
maps each headless answer to done / fallback / error; the new provider composes them with today's guards and
registry, and delegates to `BudgeroProvider` on fallback. Prompt text switches on `canRead`, tool
descriptions become neutral.

**Tech Stack:** TypeScript (Node, ESM), vitest, better-sqlite3 + drizzle (migrations in `src/db/migrations`),
`fetch`.

**Spec:** `/home/fede9/Progetti/lzc-budgero/docs/superpowers/specs/2026-11-27-budgero-headless-m4-ambrogio-adapter-design.md`
(approved 27/11/2026). Headless API: `.../specs/2026-11-24-budgero-headless-client-design.md` §8.1, §10.

**Where the work happens:** the Ambrogio repo is bare (`~/Progetti/ambrogio`, its local `master` is stale).
Create the worktree from `origin/master`:
`git -C ~/Progetti/ambrogio fetch origin && git -C ~/Progetti/ambrogio worktree add ~/Progetti/ambrogio-wt-budgero-headless -b claude/budgero-headless origin/master`.
Read Ambrogio's `CLAUDE.md`/`AGENTS.md` there first: its commit, test and deploy rules apply. All paths below are
relative to that worktree. Tests: `npx vitest run <file>`; full gate `npm test && npm run lint`.

> **Status 27/11/2026:** Tasks 1–9 done (Ambrogio `claude/budgero-headless`, 15 commits `d0432308..4d22b137`, subagent-driven, every task reviewed, final whole-branch review + one fix wave), merged into Ambrogio's **local** `master` by fast-forward, **not pushed** (a push to Ambrogio master deploys). Full suite 18,872 passed. Rulings and deferred minors: `2026-11-27-budgero-headless-m4-ambrogio-adapter.ledger.md`. **Task 10 (gated) open.**

## Global Constraints

- The six tool names and argument schemas in `src/tools/budget-transactions.ts` do not change.
- YNAB behaviour does not change; provider `budgero` changes only as Task 3 says.
- Headless base URL default `http://172.18.0.1:8787`; bearer = the `operator` token (role `write`, which also reads).
- `Idempotency-Key`: 16–128 chars `[A-Za-z0-9_-]`, one per tool call, reused on every retry inside that call.
- Amounts: euro → milli with `Math.round(eur * 1000)`; sign → `outflow`/`inflow`, both ≥ 0.
- Fallback to the Push API **only** when the request certainly did not execute: not sent (connect refused,
  DNS, connect timeout), `503`, `403 read_only`. Never after a `202`, a post-send timeout or a reset.
- No token, password or key in logs, tool results or panel responses.
- New user/model-facing texts are Italian, in the register of the existing ones.

## Review Focus

1. Headless goes down between the health refresh and a write: one fallback push, and the result says "in coda
   Push, visibile alla prossima apertura" (test in Task 5).
2. Payee matching: the headless `payee` filter is exact; the duplicate guard and `list_transactions` must
   normalise client-side as `payeeNorm` does today (test in Task 6: "Esselunga " vs "esselunga").
3. A split line with `transferAccountId` goes through the headless unchanged (test in Task 5).
4. `update_transaction`/`delete_transaction` on a pre-M4 Push message id (`<uuid>` or `tr:<uuid>`) is routed to
   provider `budgero`, also in mode headless (test in Task 5).
5. Two concurrent `create_transaction` calls for the same expense: the second sees the first as a duplicate
   (serialised chain, test in Task 5).

---

### Task 1: Headless HTTP client

**Files:**
- Create: `src/budgeting/headless-client.ts`
- Test: `tests/budgeting/headless-client.test.ts`

**Interfaces:**
- Produces:
  ```ts
  export type HeadlessOutcome =
    | { kind: 'answered'; status: number; body: unknown }
    | { kind: 'not_sent'; reason: string }      // certainly not executed
    | { kind: 'ambiguous'; reason: string };    // may have executed
  export interface HeadlessConfig { baseUrl: string; token: string }
  export function headlessConfig(): HeadlessConfig | null;  // secrets BUDGERO_HEADLESS_URL (default) + BUDGERO_HEADLESS_TOKEN; null if no token
  export class HeadlessClient {
    constructor(cfg: HeadlessConfig, fetchImpl?: typeof fetch);
    get(path: string, query?: Record<string, string | number | undefined>, timeoutMs?: number): Promise<HeadlessOutcome>;
    write(method: 'POST' | 'PATCH' | 'DELETE', path: string, body: unknown | undefined, idemKey: string, timeoutMs?: number): Promise<HeadlessOutcome>;
  }
  ```

- [ ] **Step 1: Write the failing tests** — fake `fetchImpl`:
  - `answered` carries status and parsed JSON for 200, 202, 422, 503;
  - a rejection whose `cause.code` is `ECONNREFUSED`, `ENOTFOUND`, `EHOSTUNREACH` or `UND_ERR_CONNECT_TIMEOUT` ⇒ `not_sent`;
  - `UND_ERR_SOCKET`, `UND_ERR_HEADERS_TIMEOUT`, or an abort after the timeout ⇒ `ambiguous`;
  - `write` sends `Authorization: Bearer <token>`, `Idempotency-Key`, and a JSON body;
  - a non-JSON 2xx body ⇒ `ambiguous` (the headless only answers JSON);
  - neither `reason` nor any thrown message contains the token.
- [ ] **Step 2:** `npx vitest run tests/budgeting/headless-client.test.ts` — Expected: FAIL (module missing).
- [ ] **Step 3: Implement** with `fetch` + `AbortSignal.timeout` (default 15 s for writes, 5 s for reads). Classify by `err.cause?.code`.
- [ ] **Step 4:** same command — Expected: PASS.
- [ ] **Step 5: Commit** `feat(budgeting): headless HTTP client with sent/not-sent/ambiguous outcomes`.

### Task 2: Headless health flag

**Files:**
- Create: `src/budgeting/headless-health.ts`
- Modify: `src/index.ts` (start the refresher next to `configureBudgeroDb`, `:817`)
- Test: `tests/budgeting/headless-health.test.ts`

**Interfaces:**
- Consumes: `HeadlessClient` (Task 1).
- Produces:
  ```ts
  export function headlessLive(): boolean;                 // last known state, sync; false before the first probe
  export function noteHeadlessOutcome(o: HeadlessOutcome): void; // answered 2xx/4xx ⇒ live, not_sent/503 ⇒ down
  export function refreshHeadlessHealth(client?: HeadlessClient): Promise<boolean>; // GET /v1/status, 1 s
  export function startHeadlessHealth(intervalMs?: number): () => void; // default 30_000; returns stop; unref'd timer
  ```
- *Ruling (plan, 27/11/2026):* the spec's "probe where the prompt is built" becomes this cached flag, because
  `buildContext` (`src/llm/prompt.ts:1865`) and `budgetingDedupClause` (`src/scheduler/engine.ts:3143`) are
  synchronous. The cost is at most 30 s of a stale flag. Calls fall back by themselves (spec 5.1), and they
  correct the flag on the spot.

- [ ] **Step 1: Write the failing tests:**
  - `/v1/status` answered 200 with `state:"live"` ⇒ `headlessLive()` true;
  - `state:"bootstrapping"`, a 503, `not_sent` or a 1 s timeout ⇒ false;
  - `noteHeadlessOutcome` of a `not_sent` flips it to false at once, of an answered 422 to true;
  - no token configured ⇒ false and no request made.
- [ ] **Step 2:** run — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** run — Expected: PASS.
- [ ] **Step 5: Commit** `feat(budgeting): cached headless health flag`.

### Task 3: Registry columns and the old provider's filter

**Files:**
- Create: `src/db/migrations/<next free number>_budgero_push_log_headless.sql` (0141 at `d0432308`; check the
  free number at rebase)
- Modify: `src/db/schema.ts:386-408` (`budgeroPushLog`), `src/budgeting/budgero.ts` (`listTransactions` `:864`, the
  dedup guard `:377-401`), `src/budgeting/budgero-read.ts` (`codaNonApplicata` `:402-417` input)
- Test: `tests/budgeting/budgero.test.ts`, `tests/budgeting/budgero-read.test.ts`, `tests/scheduler/migration.test.ts`
  (count 141 → 142), a new `tests/db/budgero-push-log-headless-migration.test.ts`

**Interfaces:**
- Produces: columns `mode TEXT NOT NULL DEFAULT 'push'` (`'push' | 'headless'`), `headless_id INTEGER NULL`,
  `idem_key TEXT NULL`, `mutation_ids TEXT NULL` (JSON array), `state TEXT NULL` (`'sending' | 'acked' | 'pending' |
  'unknown'`, headless rows only). For headless rows `message_id` = `hdl:<idem_key>`; `category_id` stays NOT NULL
  (the Uncategorized id for splits, as today).

- [ ] **Step 1: Write the failing tests:**
  - migration: existing rows read back with `mode = 'push'`, the new columns present;
  - provider `budgero` `listTransactions` returns only `mode = 'push'` rows;
  - `readBudget`'s pending merge ignores `mode = 'headless'` rows;
  - its duplicate guard **does** count a `mode = 'headless'` row (same payee, amount, date ⇒ `duplicate: true`).
- [ ] **Step 2:** `npx vitest run tests/budgeting/budgero.test.ts tests/budgeting/budgero-read.test.ts tests/scheduler/migration.test.ts tests/db` — Expected: the new cases FAIL.
- [ ] **Step 3: Implement** the migration, the schema fields, and the `mode = 'push'` filters (list, merge) with no filter on the guard.
- [ ] **Step 4:** same command — Expected: PASS, every existing case included.
- [ ] **Step 5: Commit** `feat(budgeting): push log records headless writes; budgero provider lists only its pushes`.

### Task 4: Write executor (the answer table)

**Files:**
- Create: `src/budgeting/headless-writes.ts`
- Test: `tests/budgeting/headless-writes.test.ts`

**Interfaces:**
- Consumes: `HeadlessClient`, `HeadlessOutcome` (Task 1), `noteHeadlessOutcome` (Task 2).
- Produces:
  ```ts
  export type WriteVerdict =
    | { kind: 'acked'; ids: (number | null)[]; mutationIds: string[]; requery: boolean }
    | { kind: 'pending'; mutationIds: string[]; status: 'pending' | 'blocked' | 'unknown' }
    | { kind: 'fallback'; reason: string }
    | { kind: 'error'; message: string; field?: string; uncertain?: boolean };
  export function executeHeadlessWrite(client: HeadlessClient, req: { method: 'POST' | 'PATCH' | 'DELETE'; path: string; body?: unknown; idemKey: string },
    opts?: { sleep?: (ms: number) => Promise<void>; pollMs?: number[]; ambiguousRetries?: number }): Promise<WriteVerdict>;
  ```
  Defaults: `pollMs = [1000, 2000, 4000, 8000]` (15 s), `ambiguousRetries = 3`.

- [ ] **Step 1: Write the failing tests**, one per row of spec 5.2:

  | Headless answer | Verdict |
  |---|---|
  | 200 `{results:[{id:5}]}` | `acked`, ids `[5]` |
  | 200 with `partial` | `error` naming the ops that did not land |
  | 200 `reordered` + `requery` | `acked`, `requery: true`, id `null` |
  | 202 `pending`, then `/v1/mutations/x` acked | `acked` |
  | 202 for longer than every poll | `pending` |
  | 202 `blocked` / `unknown` | `pending` with that status |
  | 422 `{error:"schema",field:"date"}` | `error` with `field` |
  | 403 `read_only` | `fallback` |
  | other 403, 409 | `error` |
  | 429 | `error`, retry later |
  | 503 | `fallback` |
  | `not_sent` | `fallback` |
  | `ambiguous` ×1, then 200 with the same `Idempotency-Key` | `acked` |
  | `ambiguous` ×4 | `error`, `uncertain: true` |

  - **Anti-goal test:** for every row, record the requests made. A `fallback` verdict only ever follows `not_sent`, 503 or `403 read_only`, and never follows a request that got a 2xx/202, or an `ambiguous` that was not followed by a 503.
- [ ] **Step 2:** run — Expected: FAIL.
- [ ] **Step 3: Implement.** Retries reuse `req.idemKey` verbatim; every outcome goes through `noteHeadlessOutcome`.
- [ ] **Step 4:** run — Expected: PASS.
- [ ] **Step 5: Commit** `feat(budgeting): headless write executor (ack, poll, fallback only when not executed)`.

### Task 5: `BudgeroHeadlessProvider` — writes

**Files:**
- Create: `src/budgeting/budgero-headless.ts`
- Modify: `src/budgeting/budgero.ts` — export the guards it already has, unchanged:
  - `findDuplicatePush(...)` (today `:377-401`)
  - `findInstallmentCluster(...)` (today `:448-496`)
  - the serialising chain `runSerialized<T>(fn: () => Promise<T>): Promise<T>` (today `:244-252`), shared by both providers.
- Test: `tests/budgeting/budgero-headless.test.ts`

**Interfaces:**
- Consumes: Tasks 1–4; `BudgeroProvider` (fallback target); `resolveMapped` (`budgero.ts:189`).
- Produces: `export class BudgeroHeadlessProvider implements BudgetingProvider` with `name = 'budgero_headless'`,
  `get canRead(): boolean { return headlessLive(); }`, `constructor(fallback: BudgeroProvider, client?: () => HeadlessClient | null)`;
  methods `createTransaction`, `createTransfer`, `updateTransaction`, `deleteTransaction` (reads in Task 6).

- [ ] **Step 1: Write the failing tests** (fake client, real in-memory DB as the existing budgero tests do):
  - `create_transaction` −12.50 € on account "Gnosis" by name ⇒ `POST /v1/transactions` with `outflow: 12500`, the resolved id, `payee` by name, and an `Idempotency-Key` matching the pattern. The registry row has `mode = 'headless'`, `state = 'acked'` and `headless_id`. Result: `success: true`, `transactionId: "<id>"`, wording "registrata e confermata".
  - Split with one `categoryId` line and one `transferAccountId` line ⇒ both lines in `splits`, unchanged (Review Focus 3).
  - No category ⇒ the Uncategorized id.
  - Duplicate: the live budget (fake `/v1/transactions` over ±3 days) has "esselunga", same amount, date −2 days ⇒ `duplicate: true`, no write; `force: true` ⇒ write.
  - Two concurrent creates of the same expense ⇒ the second returns `duplicate: true` (Review Focus 5).
  - Instalment guard fed by the registry rows of both modes ⇒ `installments: true`.
  - `fallback` verdict ⇒ exactly one call to `BudgeroProvider.createTransaction`; its result is returned with "headless non raggiungibile: registrata in coda Push, visibile alla prossima apertura dell'app" (Review Focus 1).
  - `pending` ⇒ `success: true, status: "pending"`, registry `state = 'pending'` with `mutation_ids`.
  - `error` with `field` ⇒ `isError`, `field` in the payload, no registry row.
  - `create_transfer` between two EUR accounts ⇒ `POST /v1/transfers` with equal `outflow`/`inflow`. Accounts with different currencies ⇒ error, no request. The account currency comes from `/v1/accounts`.
  - `update_transaction` on a numeric id ⇒ `PATCH` with `outflow`/`inflow` both set on an amount change. With `accountId` ⇒ error "cambiare conto non si può: cancella e ricrea".
  - `delete_transaction` on a numeric id ⇒ `DELETE`.
  - Both of them on `<uuid>`, `push:<uuid>` or `tr:<uuid>` ⇒ delegated to `BudgeroProvider` (Review Focus 4).
  - Both of them on a numeric id with a `fallback` verdict ⇒ error "headless non raggiungibile, riprova più tardi", no push.
- [ ] **Step 2:** `npx vitest run tests/budgeting/budgero-headless.test.ts tests/budgeting/budgero.test.ts` — Expected: new FAIL, budgero tests PASS.
- [ ] **Step 3: Implement.** The registry row (`state = 'sending'`) is written before the request. Write and guards run inside `runSerialized`.
- [ ] **Step 4:** same command — Expected: PASS.
- [ ] **Step 5: Commit** `feat(budgeting): budgero_headless provider writes through the headless, falls back to Push`.

### Task 6: `BudgeroHeadlessProvider` — reads, maps, lazy close

**Files:**
- Modify: `src/budgeting/budgero-headless.ts`, `src/budgeting/budgero-read.ts`
  - from `budgero-read.ts`, export unchanged the shaping helpers the headless rows reuse: transfer collapsing (`:194-235`), filters `tieneRiga` (`:238-273`), row and character caps (`:610-639`);
- Test: `tests/budgeting/budgero-headless-read.test.ts`

**Interfaces:**
- Produces: `listTransactions`, `readBudget` on `BudgeroHeadlessProvider`;
  `resolveHeadlessIds(): Promise<{ accounts: Record<string, number>; categories: Record<string, number>; uncategorizedId: number | null }>`
  (cached per 60 s, rewrites `budgero_account_map` / `budgero_category_map` / `budgero_uncategorized_id` in `agent_settings`).

- [ ] **Step 1: Write the failing tests:**
  - `list_transactions` with `payeeNameContains: "esselunga"` matches "Esselunga " (Review Focus 2). Rows carry `id` = headless `ID`, and there is no "solo transazioni registrate da Ambrogio" note.
  - Fallback pushes not yet applied are appended with `pending_sync: true`.
  - `read_budget` `balances` ← `/v1/accounts`: `BalanceConverted` in milli → euro, archived excluded and counted.
  - `read_budget` `transactions`: split lines and transfer collapsing as in `budgero-read.test.ts`.
  - `read_budget` `category_totals`: aggregated from `/v1/transactions`, transfers excluded.
  - `as_of` = now, no `staleness_warning`, caps 50/500 rows and 20,000 characters.
  - The read is `not_sent` or 503 ⇒ `BudgeroProvider.readBudget` / `listTransactions` result returned.
  - A registry row `sending`/`pending`/`unknown` with `mutation_ids` is set to `acked` with its id after a read, using `/v1/mutations/{id}`; a `dropped`/`failed` one is deleted. A row without `mutation_ids` that is not found in `/v1/transactions` after 10 min is deleted.
  - Maps are refreshed from `/v1/accounts` and `/v1/categories` into `agent_settings`.
- [ ] **Step 2:** run — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** `npx vitest run tests/budgeting` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(budgeting): budgero_headless reads, live maps, registry close-out`.

### Task 7: Provider choice, secrets, panel

**Files:**
- Modify: `src/budgeting/provider.ts` (`BUDGETING_PROVIDER_NAMES` += `'budgero_headless'`), `src/budgeting/registry.ts`, `src/secrets/catalog.ts` (two entries after the `BUDGERO_*` block, `:108-163`), `src/auth/budgeting-ui.ts`
- Test: `tests/secrets/catalog.test.ts` (pin 6 → 8 Budgero secrets), `tests/auth/budgeting-ui.test.ts`, `tests/tools/budget-transactions.test.ts`

**Interfaces:**
- Consumes: `BudgeroHeadlessProvider` (Tasks 5–6), `refreshHeadlessHealth` (Task 2).
- Produces:
  - secrets `BUDGERO_HEADLESS_URL` (label "Budgero headless — URL", default in code `http://172.18.0.1:8787`) and `BUDGERO_HEADLESS_TOKEN` (label "Budgero headless — token operator"), both group `finance`, feature `ynab`, `bootEnv: false`;
  - panel option "Budgero (headless)";
  - `GET /auth/budgeting/state` gains `headless: { configured: boolean, live: boolean, state: string | null }`.

- [ ] **Step 1: Write the failing tests:**
  - the registry returns `BudgeroHeadlessProvider` for `budgero_headless`;
  - an unknown value still falls back to YNAB;
  - `/set` to `budgero_headless` without `BUDGERO_HEADLESS_TOKEN`, or with today's Budgero prerequisites missing ⇒ `400 budgero_not_ready` listing what is missing;
  - `/state` never contains the token value;
  - the tool handlers resolve the new provider per call.
- [ ] **Step 2:** run — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** run — Expected: PASS.
- [ ] **Step 5: Commit** `feat(budgeting): select budgero_headless in the panel; headless secrets`.

### Task 8: What the model reads

**Files:**
- Modify: `src/tools/budget-transactions.ts` (descriptions `:78-83, 117, 140, 168, 191-201, 230-231`), `src/llm/prompt.ts:2249-2293`, `src/scheduler/engine.ts:3143-3169`, `src/agents/ambrogio/persona/POLICY.md` (§16 `:575-590`, `:619`)
- Test: `tests/guards/prompt-budgero-correzioni-possibili.test.ts`, `tests/guards/read-budget-non-e-il-dedup.test.ts`, `tests/guards/rate-non-sono-un-secondo-acquisto.test.ts`, `tests/tools/budget-transactions.test.ts`

**Interfaces:**
- Consumes: `canRead` of the active provider (getter, Task 5).

- [ ] **Step 1: Write the failing tests:**
  - **Tool descriptions:** none of them contains "prossima apertura", "SOLO le transazioni registrate da Ambrogio" or "write-only". All of them still name `duplicate`, `installments` and `force`.
  - **Prompt, `budgero_headless` with `canRead` true:** no `<budgeting_provider ... write_only>` block.
  - **Prompt, `budgero_headless` with `canRead` false:** the block is there with today's text, `name="budgero_headless"`.
  - **Prompt, provider `budgero`:** today's text, unchanged.
  - **`budgetingDedupClause`:** the YNAB-style clause when `canRead` is true, today's otherwise.
  - **POLICY §16:** provider-neutral. The dated-budget and "solo le righe di Ambrogio" lines move into the per-turn block.
- [ ] **Step 2:** run the four guard files — Expected: the new cases FAIL.
- [ ] **Step 3: Implement.** The moved POLICY lines go into the fallback block, word for word, so the fallback stays what the model reads today.
- [ ] **Step 4:** `npm test && npm run lint` — Expected: PASS.
- [ ] **Step 5: Commit** `feat(budgeting): neutral tool texts; write-only prompt block only when the headless is down`.

### Task 9: Contract check against a real headless

**Files:**
- Create: `tests/budgeting/budgero-headless.contract.test.ts` — `describe.skipIf(!process.env.BUDGERO_HEADLESS_CONTRACT_URL)`

- [ ] **Step 1: Write the test.** Against `BUDGERO_HEADLESS_CONTRACT_URL` + `BUDGERO_HEADLESS_CONTRACT_TOKEN`, in this order:
  - create an expense ⇒ its id, then read it back in `list_transactions`;
  - `create_transfer` between two same-currency accounts;
  - `update_transaction` amount and memo ⇒ changed in a read;
  - `read_budget` balances;
  - `create_transaction` without `date` sent raw through the client ⇒ 422 `date`;
  - delete everything it created, transfer included. Check whether deleting one leg removes both, and record the answer in the test name (spec §7).
- [ ] **Step 2: Run it against a bench headless, never production:** the standalone bench of the headless repo (server v1.22.1 in Docker, throwaway space, headless `readOnly: false`) as used for the Android M2 checks. `BUDGERO_HEADLESS_CONTRACT_URL=http://localhost:<port> BUDGERO_HEADLESS_CONTRACT_TOKEN=<bench operator token> npx vitest run tests/budgeting/budgero-headless.contract.test.ts` — Expected: PASS. Without the env: skipped.
- [ ] **Step 3: Commit** `test(budgeting): headless contract check (bench only)`.

### Task 10: Trial in production (gated: Federico)

- [ ] **Step 1:** merge and deploy Ambrogio following its repo rules (`CLAUDE.md`), with Federico's go.
- [ ] **Step 2:** Federico enters `BUDGERO_HEADLESS_TOKEN` (the NAS `tokens` file, `operator:write:` line) in the Ambrogio secrets panel himself; it never passes through chat. `/auth/budgeting/state` shows `headless.live: true`. He switches the provider to "Budgero (headless)".
- [ ] **Step 3:** first check: one real expense through Ambrogio ⇒ visible at once in the web app, the tool result says "confermata", and its id matches `list_transactions`.
- [ ] **Step 4:** a Vikunja task in project **4** (Budgero) for the week's review (+7 days):
  - no duplicate;
  - every write acked or visibly pending;
  - `read_budget` balances equal to the web app;
  - fallback episodes listed from the logs;
  - the decision on retiring provider `budgero` is a separate one.
- [ ] **Step 5:** update the headless runbook (BookStack Chronos page 193): Ambrogio uses the `operator` token, and what a fallback episode looks like.

---

## Self-review notes

- **Spec coverage:**
  - 5.1 → Tasks 2, 5, 8.
  - 5.2 → Tasks 4, 5.
  - 5.3 → Task 6.
  - 5.4 → Tasks 3, 5, 6.
  - 5.5 → Task 6.
  - 5.6 → Task 7.
  - 5.7 → Task 8.
  - §6 → the tests of Tasks 4–8, Task 9 (bench), Task 10 (trial).
  - §7's open points → Tasks 3 (migration number), 8 (wording), 9 (transfer leg delete).
- **Deviation from the spec, ruled in Task 2:** a cached health flag instead of a per-turn probe, because the prompt builders are synchronous.
- **Gated:** Task 10 (deploy, secrets, provider switch: Federico).
