# F: bounded thread index (proposed)

Status: proposal, revision 3, 2026-10-19. Revision 1 (e9e7a33) was not approved: the reviewer
found three gaps (an empty tail after a freeze, `ui_recipients`, the alias migration rule).
Revision 2 (aa30c23) answered them; the reviewer accepted 8192 bytes as the packing target and
asked for recovery rules (resume by size, oversized IDs, a restart of the whole read). This
revision adds them. Read README "Size limits" first.

Implementation: F1 is built in four commits (readers, writers, alias migration, growth test), with
the tests of "Tests" below. F2 and F3 are not implemented.

## Problem

- A send rewrites the whole thread record (`thread/<pair>`, `{ids}`). Each message adds
  `len(id) + 3` bytes; a live ID is about 80 B, so about 83 B for each message (inferred from the
  record format).
- So the thread record alone reaches 64 KiB at about 780 messages. The real point is earlier: the
  recipients' mailboxes are in the same batch (`len(id) + 8` bytes for each unread message, for each
  member).
- The largest live thread on 2026-10-19 had 195 messages, about 15.5 KB of index (the
  coordinator's read-only count).
- Since the read-size work (D), a batch that can never fit is a definite `invalid_input`. Before D
  it was a retryable `unavailable` that never succeeded.
- A thread record never shrinks. A mailbox shrinks when its owner acknowledges.

## F1. Bounded thread tail (proposed for implementation)

### Records

- The key `thread/<pair>` stays. It becomes the **tail**: `{ids, seg, chain, frozen}`.
  - `ids`: the newest message IDs, oldest first, as today.
  - `seg`: the number of frozen segments in the chain. Absent means 0 (a record from before F1).
  - `chain`: the chain number, a decimal string. Absent means `'0'`.
  - `frozen`: the number of IDs in the segments. Absent means 0.
- A **segment** is `thread-seg/<suffix>/<chain>/<k>`, `k` from 0 to `seg - 1`, value `{ids}`,
  oldest first. `<suffix>` is the tail key without `thread/`. Segment 0 holds the oldest IDs.
- Segment `k` of chain `c` is written once, with `if_rev = '0'`. Nothing writes it again. The alias
  migration does not rewrite it: it writes a new chain and deletes the old one (see "Alias
  migration").
- A scan of the prefix `thread/` does not match `thread-seg/`, so the observer scan sees tails
  only.

### Invariants

- **The tail is never empty after the first message.** A freeze step never moves the newest ID
  (see "Freeze"). So the readers that check `#ids > 0` (`declare_tabs`, `peers`,
  `observed_direct_peer`) and the tab revision `ids[#ids]` (the newest message ID) do not change.
  This also holds after a freeze whose send failed or did not run (a crash, a conflict, a
  definite refusal).
- The order of all IDs is: segment 0, ..., segment `seg - 1`, then the tail. It is the commit
  order of the messages, as today.
- The message count of a thread is `frozen + #ids`. The thread menu summary uses it.

### Freeze

- `tail_limit` is a packing target, not a rejection limit. Sizes are encoded sizes of `{ids = ...}`
  (`encoded_size`, the Go encoder rules of README "Size limits"). The only rejection stays the
  existing one: a hub request that cannot fit the request limit (64 KiB minus 1 KiB) is
  `invalid_input` with its size, and commits nothing.
- **One step rule, for every tail.** A freeze step is one batch. It takes the longest prefix of the
  tail's oldest IDs whose encoded `{ids}` is at or under `tail_limit`, but at least one ID, and
  never the newest ID. It writes that prefix as segment `seg` of the chain (`if_rev = '0'`), and
  sets the tail to the rest: `{ids = rest, seg = seg + 1, chain, frozen = frozen + n}` (`if_rev` =
  the tail revision).
  - An ID that alone is over `tail_limit` (a stored legacy ID) is a prefix of one ID: its segment
    is over the target. That is allowed, and the record stays readable.
  - Each step moves at least one ID and never the newest ID. So the steps end, and the tail is
    never empty.
- **When to step.** Before an append (agent send, view send, membership notice), the writer reads
  the tail. While the tail has more than one ID and the tail with the new ID is over `tail_limit`,
  it runs one step and reads the tail again. The decision uses the size only, never `seg`: a tail
  that a crash left over the target after some steps (`seg > 0`) continues with the same steps.
- **The append.** Then the send batch appends to the tail with the same `if_rev` guard as today.
  If the tail is only the newest ID and the tail with the new ID is still over `tail_limit` (large
  IDs), the append goes ahead: the tail is over the target, and the existing request check
  decides. The outcome is deterministic: the batch fits and commits, or it is `invalid_input` and
  commits nothing. No loop, and no ID is dropped.
- A normal thread (tail at or under the target before the append) needs one step: the prefix is
  every ID except the newest.
- A legacy tail over the target (for example the planned 60 KB fixture) needs several steps. Each
  step is a valid state. A crash or a failure between steps leaves a valid chain; the next append
  continues.
- A step batch is measured against the request limit. It carries the new segment and the whole
  remaining tail, so the first step of a large legacy tail is about as large as the tail itself.
  A step that cannot fit is `invalid_input`, and the thread accepts no more appends, as today. A
  tail of many ordinary IDs near the request limit can do this, not only one large ID. The 60 KB
  case is a planned fixture until its test passes; it is not a guarantee for every legacy record.
- The step batches write no message, mailbox or operation record. A conflict in a step or in the
  send batch retries from a new read, as today, within the existing `attempts` bound for the whole
  send.
- No orphan segments: the segment and the tail change in one atomic batch. Two concurrent steps on
  one tail both write segment `seg`; the second batch fails on its tail guard and commits nothing,
  then retries from a new read.

### Readers

One helper reads IDs across the chain: `thread_chain(a, b)` returns the tail (key, revision,
value) and a function that gives older segments on demand, newest segment first.

**A missing segment restarts the whole logical read.** If a segment of the tail's chain is missing
(an alias migration replaced the chain after the tail read), the caller discards every ID and
message that it collected, and every guard revision that it computed, and starts again from a new
tail read. The bound is on the whole operation: at most `attempts` starts, then `unavailable`. A
reader never continues a walk on a new tail: that could repeat or skip IDs.
Each user of `thread()` today:

| Caller | Today | With F1 |
| --- | --- | --- |
| `messaging.history` (agent) | `before` is a revision cursor (a message record revision). Newest first, `next_before`. | The same contract. It walks the tail, then segments `seg - 1` to 0, and stops when the page is full. |
| `history_page` (view tree and `view.history`) | `before` is a message ID. Each page is oldest first. | The same contract. It finds `before` in the tail, then in older segments, then returns the page before it, oldest first. An unknown `before` is still `invalid_input`. |
| `declare_tabs` | `#ids > 0`, revision `ids[#ids]` | Unchanged (invariant). |
| `peers`, `observed_direct_peer` | `#record.value.ids > 0` | Unchanged (invariant). |
| thread menu summary | `#ids` messages | `frozen + #ids` |
| `change_members` | Backfills delivery snapshots for old group messages without `recipients`, from all IDs; guards the tail with `if_rev`. | Reads all segments and the tail. The tail guard stays: segments of a chain never change, and a new chain changes the tail too. |
| `ui_recipients` (the user joins a group by a view send) | The same backfill, from the tail only today. | The same as `change_members`: all segments and the tail, the same guards (tail, `groups`) and retry. |
| send, view send, membership notice | Append to the tail. | Freeze first if needed, then append. |
| `migrate_aliases` | Merges thread records. | See below. |

### Alias migration

- The migration already reads every record (`hub.store.scan`) and writes one batch.
- For a target thread, the contributors are the target's own tail (if any) and the legacy tails.
  For each contributor it reads the whole chain: segments, then the tail.
- It merges the IDs as today: no duplicates, sorted by message record revision.
- It writes a **new chain** under the target: chain number = 1 + the largest chain number of the
  contributors (so it differs from the target's own chain). If no contributor has segments, no
  reader can hold a segment of an old chain: the number stays the largest contributor chain
  number, and a migration of tails without segments writes `{ids}` as before. It packs the segments with the step
  rule of "Freeze" (longest prefix at or under `tail_limit`, at least one ID, never the newest),
  each with `if_rev = '0'`, then writes the target tail with `seg`, `chain`, `frozen`, and the rest
  (at least the newest ID). The target tail keeps its `if_rev` guard (or `'0'` if absent).
- It deletes every segment of every contributor's old chain, and the legacy tails, in the same
  batch, each with `if_rev` (the revision it read).
- So no segment is written twice, and no partial migration is visible: the batch commits all or
  nothing. A revision conflict retries the whole migration, as today.
- Known limit, unchanged: the migration batch has no bound. A migration whose batch is over the
  request limit fails with `invalid_input` and commits nothing. Splitting it is a separate item.

### Tail limit

Proposed: `tail_limit` = 8192 encoded bytes (revision 1 said 16 KiB). Reason: a send batch carries
the body twice (up to 2 x 16384 bytes), the tail, the mailboxes and the `groups` record, under
64 KiB minus 1 KiB. A tail of 8 KiB leaves about 8 KiB more for mailboxes than 16 KiB does. The
reviewer accepted 8192 as the packing target (revision 2 review). The tests use the constant.

Cost: the number of IDs in a segment depends on the ID lengths. With live IDs of about 80 bytes,
a segment holds about 95 IDs; long IDs give fewer, and an oversized ID fills a segment alone. A
history page holds at most 50 messages, but a page with an old `before` cursor (an agent revision
cursor or a view message ID) first walks back through every newer segment to find its position:
one segment read for each segment. This is accepted for F1; a position index is not proposed.

### Tests (proposed)

- Boundary: a tail at exactly `tail_limit` after the append does not freeze; one byte over does.
  Sizes measured with `encoded_size`, so IDs with `<`, `>` or `&` count as the hub counts them.
- An interrupted freeze (the send batch fails with an injected definite failure after the freeze
  batch committed): history (agent and view), observer visibility, the tab revision and the menu
  count are the same as before the freeze. Then a retry of the send succeeds.
- History and view history across 3 segments: newest first for `messaging.history` with exact
  `before`/`next_before`; oldest first for each `view.history` page with message-ID `before`.
- A legacy tail of about 60 KB (a planned fixture, not a guarantee): the first send freezes in steps and
  succeeds (today it fails).
- A failure between legacy steps (an injected definite failure of the second step batch): the
  chain is valid (one segment, the tail still over the target, `seg = 1`); history is complete; a
  retry continues with bounded steps (every new segment at or under the target), then appends.
- Oversized IDs: a stored legacy ID over `tail_limit` in the tail goes into a segment alone and
  reads back in history. A tail whose newest ID and the new ID together are over the target: the
  append commits when the request fits, and no step runs on a one-ID tail (no loop).
- An injected revision conflict between the freeze and the send.
- `change_members` and `ui_recipients` against a concurrent freeze, and with old group messages
  without `recipients` in a frozen segment: the delivery snapshots are written.
- The observer scan does not list `thread-seg/`.
- A replay of a send key after a freeze returns the stored result.
- Alias migration: two contributors that both have segments; duplicates and order; two migrations
  one after the other; a revision conflict; a migration batch over the limit fails and commits
  nothing.
- A reader that meets a deleted segment restarts the whole read: the deletion comes after the
  reader consumed one older segment, and the result has no repeated and no missing ID. A deletion
  on every start ends with `unavailable` after `attempts` starts. Open: the harness injects writes
  only before a `hub.store.batch` (docs/testing.md), not between two reads. Before implementation
  I check for a read hook; if none exists, I ask the coordinator for one (a hub change) or propose
  a plugin test seam for review.
- Growth: a thread grows to 2000 messages, the recipients acknowledge as it grows (so the mailboxes
  stay small: mailbox growth is F2), and every send request stays under the request limit.

## F2. Mailboxes (can wait)

- Risk: a member that never reads (for example a dead agent in a group). Its mailbox grows until
  group sends to that group fail, now with a definite `invalid_input`.
- Possible fix: one record for each unread message, `unread/<agent>/<id>` (`hub.store.scan` with a
  prefix), plus a small counter record for each agent. The counter keeps the `if_rev`
  serialization of the pending notice and gives unread counts. It changes read, ack, unread
  counts, notices and alias migration, so it is larger than F1.

## F3. Bodies over 16 KiB (deferred)

The send fingerprint repeats the body. Larger bodies need a digest of the body in a new
fingerprint version, from a hub digest action, not a Lua hash (coordinator decision, 2026-10-19).
