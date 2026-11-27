# U2 upstream PR — verification plan

**Goal:** open the U2 pull request on `tombadilo-bombadilo/budgero` only with evidence that it fixes a real
bug and breaks nothing, in the web app as well as in the headless client.

**Patch:** fork worktree `~/Progetti/budgero-wt-upstream-u2`, branch `upstream/u2-queue-durability`,
commit `c2575b2b` (copy in `docs/upstream/u2-queue-durability.patch`). The same change runs in the headless
(fork commits `d660e9eb` + `ceb98351`, in every image tag since `headless-v1.22.1-1`; the
`offline-queue.ts` of `c2575b2b` and of `headless-v1.22.1-9` are identical).

**Context (27/11/2026):**
- Issue #155 is the headless proposal (opened by Federico); the maintainer agreed on 24/11 to a separate
  package, with ops outside runtime and core. U2 is the runtime change the headless needs, and it stands on
  its own as a bug fix: CONTRIBUTING allows a bug fix as a direct PR.
- Upstream `master` is at v1.23.0, 56 commits past the patch base (`e61ce1c8`), 10 runtime files changed.
  `git merge-tree origin/master c2575b2b` reports no conflict.
- The headless ran U2 read-only until 27/11 11:43 UTC; its offline queue has been in use only since then.
- Not yet true: the full upstream CI suite on a rebase, the web app with the patch, a demonstration that
  the bug exists on `master`.

**Constraint:** nothing is pushed to `f-liva/budgero` for the PR, and no PR is opened, without Federico's go.

---

### Gate 1 — the bug exists on master (the patch's tests fail without it)

Prove the tests are about a real defect, not about the new code.

1. In the U2 worktree, keep the patch's tests and put back `master`'s runtime sources:
   `git checkout e61ce1c8 -- packages/runtime/src/offline-queue/offline-queue.ts packages/runtime/src/offline-queue/storage.ts packages/runtime/src/coordinator`
   (restore with `git checkout c2575b2b -- packages/runtime/src` afterwards).
2. `pnpm --dir packages/runtime exec vitest run src/offline-queue/offline-queue.persisting.test.ts`
   Expected: FAIL on "an entry is not sendable until storage.save resolves" and on the FIFO case
   ("nothing behind a held entry is sendable"). "coordinator passes deps.queueStorage" fails too, but that
   one tests the new injection, not the bug. If the file compiles only with the injectable storage, write
   the failing case against the public queue API instead.
3. Restore the patch; same command. Expected: PASS.

Evidence for the PR: the failing test name and its assertion on `master`.

> **Done 27/11/2026.** With `master`'s sources the patch's 7 tests fail for the wrong reason
> (`queue.getSendable is not a function`: they test the new API). Added
> `packages/runtime/src/offline-queue/offline-queue.durability.test.ts` (U2 branch commit after `c2575b2b`),
> which uses only `getUnsent()` / `getStale()`, the methods the send path reads on `master`
> (`mutation-dispatch-service.ts:95`, `reconnection-service.ts:342`). On `master`'s sources both cases fail
> with `expected [ 'm1' ] to deeply equal []` (the entry is sendable while `storage.save` is pending); with
> the patch they pass, with the 7 persisting tests, and the runtime suite is green (52 files, 416 tests).
> Upstream v1.23.0 has not touched `offline-queue/`, `mutation-dispatch-service.ts` or
> `reconnection-service.ts` since the base: the bug is still there.

### Gate 2 — rebase and the upstream CI, locally

1. `git rebase origin/master` on a new branch `upstream/u2-queue-durability-v1.23`.
2. Baseline first, on `origin/master` itself, then on the rebased branch — the same commands as
   `.github/workflows/ci.yml`:
   ```bash
   pnpm install --frozen-lockfile
   pnpm run build:core && pnpm run build:runtime
   pnpm run type-check:all
   pnpm run lint:core && pnpm run lint:runtime && pnpm run lint:app
   pnpm run i18n:check && pnpm run i18n:sweep
   pnpm run test:core && pnpm --dir packages/runtime run test && pnpm run test:app
   pnpm run test:tz
   pnpm run build:app
   ```
   Expected: the rebased branch fails nothing that passes on the baseline. A failure on both is
   pre-existing and goes in the PR text as such, not fixed in this PR.
3. Docker networking on the Windows host must work (the 27/11 ephemeral-port exhaustion broke it):
   check first with `docker run --rm node:22-alpine wget -q -T 10 -O /dev/null https://github.com`.

### Gate 3 — the web app with the patch

The patch changes the app's own queue, so the app is tested, not only the headless.

1. Local bench: upstream server image at the rebased version, a throwaway space, the app built from the
   rebased branch (`pnpm run build:app`), two browser profiles on the same space.
2. Scenarios, each checked on the second profile and in the server's mutation log:
   - online: add, edit, delete a transaction → each arrives once;
   - offline (DevTools "Offline"): add three transactions, reload the page while still offline, go
     online → the three arrive once each, in order, none lost after the reload;
   - two tabs on one profile, writing alternately → no duplicate and no lost entry;
   - undo of an offline add before reconnecting → nothing reaches the server.
3. The crash between "sent" and "saved" cannot be timed by hand in a browser; Gate 1's test covers it.

Evidence for the PR: the scenario list with the result of each.

### Gate 4 — crash points on the headless bench

The headless bench drives a real server and a real worker process with forced exits.

1. `pnpm --dir packages/headless exec vitest run test/bench.m2.test.ts` with the bench server up
   (the M2 bench setup, server v1.22.1 Docker). It covers `after_outbox_add_before_send`,
   `after_send_before_ack`, `in_dequeuing_save`, `after_ledger_intent`, `after_ledger_queued_before_rename`.
   Expected: every point ends with each mutation on the server exactly once and an empty outbox.
2. Record the run (date, commit, pass count) in the PR text.

### Gate 5 — production soak with writes

1. From the 28/11 deploy (`headless-v1.22.1-9`) count 7 days of writes.
2. Each day: `/v1/status` has `outbox_divergent: false`, `last_nack: null`, `quarantined: []`;
   `observe.sh --nas --since <deploy time>` passes 4/4; at least one write per day from the Android app
   (its sends go through the queue, so `outbox_size > 0` happens on every write).
3. At the end: every Android pending entry is acked and present in the web app.

### Gate 6 — the PR

Only after Gates 1–5, and with Federico's go:

1. Push `upstream/u2-queue-durability-v1.23` to `f-liva-fork`.
2. PR to `tombadilo-bombadilo/budgero:master`, filled from `.github/PULL_REQUEST_TEMPLATE.md`: summary
   (the bug, the fix, why the queue storage becomes injectable), "Refs #155", the checklist with the
   commands of Gate 2, and the evidence of Gates 1, 3, 4, 5.
3. Texts pass no-ai-slop, then sepia, before Federico reads them.

### Out of scope

- The headless package itself (a later PR, after U2, per the maintainer's answer on #155).
- Moving the NAS to upstream v1.23: the headless must be rebased and rebuilt for the same server version
  (it halts on `version_mismatch` otherwise); a separate task when v1.23 is deployed.
