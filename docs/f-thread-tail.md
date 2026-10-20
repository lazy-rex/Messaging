# F: bounded thread index (proposed)

Status: proposal, revision 2, 2026-10-19. Revision 1 (e9e7a33) was not approved: the reviewer
found three gaps (an empty tail after a freeze, `ui_recipients`, the alias migration rule). This
revision answers them. Nothing is implemented. Read README "Size limits" first.

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

- **The tail is never empty after the first message.** A freeze moves every ID except the newest
  one into the segment. So the readers that check `#ids > 0` (`declare_tabs`, `peers`,
  `observed_direct_peer`) and the tab revision `ids[#ids]` (the newest message ID) do not change.
  This also holds after a freeze whose send failed or did not run (a crash, a conflict, a
  definite refusal).
- The order of all IDs is: segment 0, ..., segment `seg - 1`, then the tail. It is the commit
  order of the messages, as today.
- The message count of a thread is `frozen + #ids`. The thread menu summary uses it.

### Freeze

- Limit: the encoded size of the tail's `{ids = ...}` (measured with `encoded_size`, the Go
  encoder rules of README "Size limits") must stay at or under `tail_limit` after the append.
- Before an append (agent send, view send, membership notice): if the tail with the new ID would
  be over `tail_limit`, a **freeze batch** runs first. It writes segment `seg` of the chain with
  every tail ID except the newest one (`if_rev = '0'`), and sets the tail to
  `{ids = {newest}, seg = seg + 1, chain, frozen = frozen + n}` (`if_rev` = the tail revision).
  Then the send batch appends to the small tail with the same `if_rev` guard as today.
- The freeze batch writes no message, mailbox or operation record. A crash between the two batches
  leaves a valid tail with one ID. A conflict in either batch retries from a new read, as today.
- No orphan segments: the segment and the tail change in one atomic batch. Two concurrent
  freezes of one tail both write segment `seg`; the second batch fails on its tail guard and
  commits nothing, then retries from a new read.
- **A legacy tail over the limit** (no `seg`, for example 60 KB of IDs): it is frozen in steps.
  Each step is one batch: one segment of at most `tail_limit` encoded bytes (the oldest IDs that
  are left), and the tail with those IDs removed (`if_rev` on the tail). Each step is a valid state.
  The last step leaves at most `tail_limit` bytes and at least the newest ID in the tail. Then the
  send appends. So a legacy thread that fails today accepts sends again.

### Readers

One helper reads IDs across the chain: `thread_chain(a, b)` returns the tail (key, revision,
value) and a function that gives older segments on demand, newest segment first. If a segment of
the tail's chain is missing (an alias migration replaced the chain between the two reads), the
helper reads the tail again, at most `attempts` times, then fails with `unavailable`.

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
  contributors (so it differs from the target's own chain). Segments of at most `tail_limit` bytes,
  each with `if_rev = '0'`, then the target tail with `seg`, `chain`, `frozen`, and at least the
  newest ID. The target tail keeps its `if_rev` guard (or `'0'` if absent).
- It deletes every segment of every contributor's old chain, and the legacy tails, in the same
  batch, each with `if_rev` (the revision it read).
- So no segment is written twice, and no partial migration is visible: the batch commits all or
  nothing. A revision conflict retries the whole migration, as today.
- Known limit, unchanged: the migration batch has no bound. A migration whose batch is over the
  request limit fails with `invalid_input` and commits nothing. Splitting it is a separate item.

### Tail limit

Proposed: `tail_limit` = 8192 encoded bytes (revision 1 said 16 KiB). Reason: a send batch carries
the body twice (up to 2 x 16384 bytes), the tail, the mailboxes and the `groups` record, under
64 KiB minus 1 KiB. A tail of 8 KiB leaves about 8 KiB more for mailboxes than 16 KiB does. Cost:
about 95 IDs for each segment instead of about 190, so a deep history page reads one more segment
record more often. A history page holds at most 50 messages, so it reads at most two segments.
The reviewer decides; the tests use the constant.

### Tests (proposed)

- Boundary: a tail at exactly `tail_limit` after the append does not freeze; one byte over does.
  Sizes measured with `encoded_size`, so IDs with `<`, `>` or `&` count as the hub counts them.
- An interrupted freeze (the send batch fails with an injected definite failure after the freeze
  batch committed): history (agent and view), observer visibility, the tab revision and the menu
  count are the same as before the freeze. Then a retry of the send succeeds.
- History and view history across 3 segments: newest first for `messaging.history` with exact
  `before`/`next_before`; oldest first for each `view.history` page with message-ID `before`.
- A legacy tail of about 60 KB: the first send freezes in steps and succeeds (today it fails).
- An injected revision conflict between the freeze and the send.
- `change_members` and `ui_recipients` against a concurrent freeze, and with old group messages
  without `recipients` in a frozen segment: the delivery snapshots are written.
- The observer scan does not list `thread-seg/`.
- A replay of a send key after a freeze returns the stored result.
- Alias migration: two contributors that both have segments; duplicates and order; two migrations
  one after the other; a revision conflict; a migration batch over the limit fails and commits
  nothing; a reader that meets a deleted segment reads the tail again.
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
