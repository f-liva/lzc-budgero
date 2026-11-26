# fix(runtime): keep non-durable offline-queue entries unsent; injectable queue storage

Refs #155

## Problem

`OfflineQueue.push` adds the mutation to the in-memory queue and then awaits `storage.save`. Until that save resolves, the entry is already visible to `getUnsent`, `getStale` and the reconnection replay, so it can be sent before it is on disk.

Two failures follow:

- The app crashes after the send and before the save lands. The server has applied the mutation and the local queue has no record of it.
- The save rejects. The entry stays in memory, gets sent, and is resent later as a mutation that was never durable.

## Fix

- `OfflineQueue` tracks the ids whose save has not resolved (`persisting`). A new `getSendable()` returns the queue prefix up to the first such entry. Nothing behind a non-durable entry is sendable, so a later mutation cannot overtake it.
- `getUnsent`, `getStale` and the replay in `ReconnectionService.replayQueueViaSync` read from `getSendable()`.
- A resolved save releases every id it wrote, not only the one that triggered it. The ids are captured before the await, so entries pushed meanwhile stay held. A rejected save releases nothing, and a later successful save releases those entries too.
- `clear()` and `setQueue()` reset the set.
- `queueStorage` is now injectable through `RuntimeCoordinator` deps and `RuntimeContextFactory`, so the queue can be tested against a storage whose `save` we control.

## Tests

- `offline-queue.persisting.test.ts` (new): an entry is not sendable until its save resolves; nothing behind a held entry is sendable; a rejected save keeps the entry held; a later resolved save releases the ids it wrote, including the earlier rejected one; a save does not release an id pushed after its snapshot; `clear` and `setQueue` empty the set.
- `reconnection-service.test.ts`: the coordinator passes `deps.queueStorage` to the new `OfflineQueue`.

`pnpm --filter @budgero/runtime test`: 414 passed (407 on current master). `pnpm run type-check:runtime` is clean.

This PR covers the queue fix only; it leaves out the ops package discussed in point 2 of your reply on #155.
