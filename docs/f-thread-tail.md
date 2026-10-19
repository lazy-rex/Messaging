# F: bounded thread index (proposed, not reviewed)

Status: proposal, 2026-10-19. Nobody reviewed it yet. It was parked when the harness team took
another task; the Messaging team owns it now. Read README "Size limits" first.

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

- The key `thread/<pair>` stays and becomes the tail. Readers of the key keep working: the
  observer scan of `thread/`, `thread-meta` suffixes, tab checks of `#ids > 0`.
- The tail value is `{ids = [...], seg = k}`. `k` is the number of frozen segments
  `thread-seg/<suffix>/<0..k-1>`, each `{ids}`, never written again. A scan of `thread/` does not
  match `thread-seg/`.
- Append (send, view send, membership notice): when the tail's encoded ids would pass 16 KiB, a
  freeze batch runs first: it writes `thread-seg/<suffix>/<k>` (`if_rev '0'`) with the tail's ids
  and sets the tail to `{ids = {}, seg = k+1}` (`if_rev` on the tail). Then the send batch appends
  to the small tail with the same `if_rev` guard as today. A conflict in either batch retries as
  today. The freeze batch writes no message, mailbox or operation result, so a crash between the
  two leaves a valid, empty tail.
- Legacy: a tail without `seg` over 16 KiB is frozen the same way as segment 0. Its ids travel once
  in a batch with no other records, so a legacy thread that fails today (about 60 KB of ids plus
  mailboxes) accepts sends again.
- Concurrency: `change_members` keeps its `if_rev` guard on the tail, so the membership snapshot
  rule is unchanged. A freeze changes the tail revision, so a concurrent send or membership change
  retries.
- Readers that need older IDs use one helper, `thread_ids(a, b, before)`: newest first across the
  tail, then segments `k-1..0`, read on demand. Users: `messaging.history` (before/next_before
  unchanged), the view's `history_page`, `change_members` (its legacy delivery backfill reads all
  segments), and the other users of `thread()` (check each).
- Alias migration (`migrate_aliases`) merges thread records in one batch with every renamed record
  today. That is already an unbounded batch before F (known limit). With F1, a merged thread is
  rewritten as a new chain under the target (segments of at most 16 KiB plus the tail) in the same
  batch. A migration of threads over about 60 KB in total still fails as `invalid_input`.
  Splitting the migration batch is a separate item.
- Tests: freeze at the boundary (one byte under: no freeze; over: freeze); history and view history
  across 3 segments, newest first, exact before/next_before; a legacy 60 KB tail: the first send
  freezes and succeeds (today it fails); an injected revision conflict between freeze and send;
  `change_members` against a concurrent freeze; the observer scan does not list `thread-seg/`; a
  replay of a send key after a freeze returns the stored result; alias migration of a segmented
  thread; every send batch stays bounded as a thread grows to 2000 messages.
- Open question: the tail size (16 KiB). Smaller means more segment reads in history; larger means
  larger send batches.

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
