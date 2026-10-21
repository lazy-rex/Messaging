# Messaging storage on hub.sql (proposed)

Status: proposal, revision 2, 2026-10-21. Not implemented. It depends on the `hub.sql` contract,
which the hub lead writes now. Where this plan needs a `hub.sql` feature, it says "needs H<n>" (see
"What Messaging needs from hub.sql"). H1-H10 are dependencies, not capabilities that exist. F2
(docs/f2-unread.md) is cancelled; this plan replaces it.

Revision 0 (d82d47d): the reviewer's early review asked for eight changes. Revision 1 has: a source
fence and source-revision records for the import; chunked import of large bodies; a notice version
for every unread change; rows and the final cursor from one statement; the `team` audience; a
set-based alias migration (thread and peer keys become columns); a proof that the clock is above
every issued value; rollback after the cutover is not supported.

Revision 1 (4b7c6c2): the reviewer asked for six lifecycle changes. Revision 2 has: start-up
states read before any key-value access, a guarded fence reset and a two-commit cutover; a clock
bump for every revision, with an exhaustion error; an outbox timer and terminal-refusal rule; a
two-step read for oversized rows; staged alias merges; an ack that changes nothing writes nothing.
Revision 2 is targeted; the next full revision follows the hub contract.

Open for revision 3 (reviewer, on 19838cb):

- The first-fence crash: the key-value fence `{state = 'importing'}` exists, but the SQL `import`
  row was never committed (an orphan fence). Recover it explicitly, with a defined alias set, and
  test it. The SQL `done` state takes precedence over any key-value state.
- The selection query of an oversized read: 1 KiB prefixes do not make `LIMIT` rows fit one reply.
  Keep byte-aware sizing and reduction for it too. Only `body` and `id` are immutable: the SQL
  alias migration changes `sender`, `recipient` and the thread columns, so the fill must handle
  that change (or fence it) and not assume the same bytes.

Hub contract draft 1 (LazyRex docs/sql.md, db1e004, and fa8e1f7), for revision 3. Revision 3
waits for draft 2, which comes with a prototype:

- Notices: the hub owns the outbox (`hub.sql.batch` `notices: [{agent, pending}]`, applied in
  commit order). If draft 2 keeps it with a durable receipt, Messaging drops `notice_outbox`, the
  timer and the notice versions. Until then, the plugin outbox above stays the plan.
- Every guard stays inside the transaction (`expect_changes`; an assertion as a guarded no-op write
  or `expect_rows` if the hub adds it). Serial hub calls do not make a read and a later batch
  atomic (hub reviewers, 2026-10-21); Messaging does not rely on it.
- The hub `key` is a bounded retry cache for a byte-identical batch. Messaging keeps its own
  permanent `operations` table: a retried send has a new `at` and possibly a new canonical sender.
- Rex Lua is Lua 5.1 (hub lead, observed on 0.0.1792158932-g88fd41): integers above 2^53 travel as
  decimal text. Messaging reads revisions with `CAST(x AS TEXT)` and passes them as `{"int": "..."}`.
- `hub.sql.query` returns whole rows up to `max_bytes` with `complete = false`, and `too_large`
  `{row = 0, bytes}` for a first row that does not fit: the read uses both (byte-aware selection,
  then the two-step fill).
- Rows with NULL decode in Lua with holes: index rows by column number, never `ipairs`.
- Ordering of `hub.sql.*` with `hub.store.*` (the import reads key-value and writes SQL) is not in
  draft 1; the import does not depend on it beyond the fence and the source check.

Decision (user, 2026-10-21): each plugin gets its own SQLite database, run by the hub, through hub
actions. Messaging keeps its current semantics exactly:

- An agent acknowledges each message on its own (per-ID ack). There is no read watermark.
- The audience of a message is fixed when it is sent. A later membership change does not change it.
- A removed member keeps the mail that it received, and can read it with `messaging.read {thread}`.

## Why the key-value store is replaced

Every limit of the current store comes from one rule: a change is a batch of whole records, each
guarded by its revision. So a send rewrites the whole mailbox of each recipient and the whole
`groups` record (the live 64628-byte failure, 2026-10-21); a thread needs a chain of segments (F1);
an unread count reads every unread message (the get storm). In SQL, each of these is a row. The SQL
text and the parameters of a send do not depend on mailbox, group or thread size. (The row work
does: a 100-member send writes 100 delivery rows and 100 outbox rows. See "Sizes and costs".)

## Tables

All IDs are TEXT, as today. Revisions and cursors are INTEGER in SQL and decimal strings in Lua and
JSON (see "Exact integers").

Thread and peer keys are columns, not today's length-prefixed strings, so an alias migration is a
set-based UPDATE:

- A **thread** is `(thread_kind, thread_a, thread_b)`. `direct`: the canonical pair, `thread_a <
  thread_b` (a self thread has `thread_a = thread_b`). `group`: `thread_a = ''`, `thread_b` = the
  group ID (`team` or `g-...`).
- A **peer** (what a viewer sees in its thread list) is `(peer_kind, peer_a, peer_b)`. `agent`:
  `peer_a` = the agent, `peer_b = ''`. `group`: `peer_a` = the group ID, `peer_b = ''`. `observed`
  (the user's view of an agent-to-agent direct thread, today's `d-<hex>` ID): the canonical pair,
  `peer_a < peer_b`. The plugin computes the `d-<hex>` ID for routes and replies, as today.

```sql
-- One counter for every revision that the plugin gives out: message cursors, draft revisions,
-- set_rev of titles and homes, notice versions. The cutover sets it (see "Migration").
CREATE TABLE clock (one INTEGER PRIMARY KEY CHECK (one = 1), n INTEGER NOT NULL);

-- Plugin state: import progress, the source fence, the cutover marker.
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE messages (
  seq            INTEGER PRIMARY KEY,     -- the cursor (today: the message record revision)
  id             TEXT NOT NULL UNIQUE,    -- send/<part(from)><part(key)>, member-notice/...
  sender         TEXT NOT NULL,           -- canonical
  recipient      TEXT NOT NULL,           -- canonical agent ID, team, or g-...
  thread_kind    TEXT NOT NULL, thread_a TEXT NOT NULL, thread_b TEXT NOT NULL,
  body           TEXT NOT NULL,
  reply_to       TEXT,
  reply_expected INTEGER,                 -- NULL (absent) or 0 (FYI), as today
  at             TEXT NOT NULL
);
CREATE INDEX messages_thread ON messages (thread_kind, thread_a, thread_b, seq);

-- The audience, fixed at send: one row per recipient. acked = 0 is unread.
CREATE TABLE deliveries (
  agent TEXT NOT NULL,
  seq   INTEGER NOT NULL REFERENCES messages (seq),
  acked INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (agent, seq)
) WITHOUT ROWID;
CREATE INDEX deliveries_unread ON deliveries (agent, seq) WHERE acked = 0;

-- Created groups. The built-in team has no rows: its members are the live roster.
CREATE TABLE groups (gid TEXT PRIMARY KEY, name TEXT NOT NULL);
-- pos keeps today's member order. current = 0 is a past member (past_members today).
CREATE TABLE group_members (
  gid TEXT NOT NULL REFERENCES groups (gid), agent TEXT NOT NULL,
  pos INTEGER NOT NULL, current INTEGER NOT NULL,
  PRIMARY KEY (gid, agent)
) WITHOUT ROWID;

CREATE TABLE thread_homes (thread_kind TEXT NOT NULL, thread_a TEXT NOT NULL, thread_b TEXT NOT NULL,
  home_session TEXT NOT NULL, moved INTEGER NOT NULL DEFAULT 0, set_rev INTEGER NOT NULL,
  PRIMARY KEY (thread_kind, thread_a, thread_b)) WITHOUT ROWID;
-- Per viewer and peer. A draft row can have empty text: its rev is still the draft revision.
CREATE TABLE thread_titles (viewer TEXT NOT NULL, peer_kind TEXT NOT NULL, peer_a TEXT NOT NULL,
  peer_b TEXT NOT NULL, title TEXT NOT NULL, set_rev INTEGER NOT NULL,
  PRIMARY KEY (viewer, peer_kind, peer_a, peer_b)) WITHOUT ROWID;
CREATE TABLE thread_opened (viewer TEXT NOT NULL, peer_kind TEXT NOT NULL, peer_a TEXT NOT NULL,
  peer_b TEXT NOT NULL, PRIMARY KEY (viewer, peer_kind, peer_a, peer_b)) WITHOUT ROWID;
CREATE TABLE thread_archived (viewer TEXT NOT NULL, peer_kind TEXT NOT NULL, peer_a TEXT NOT NULL,
  peer_b TEXT NOT NULL, PRIMARY KEY (viewer, peer_kind, peer_a, peer_b)) WITHOUT ROWID;
CREATE TABLE drafts (viewer TEXT NOT NULL, peer_kind TEXT NOT NULL, peer_a TEXT NOT NULL,
  peer_b TEXT NOT NULL, text TEXT NOT NULL, rev INTEGER NOT NULL,
  PRIMARY KEY (viewer, peer_kind, peer_a, peer_b)) WITHOUT ROWID;

-- Idempotent operations: today's hub.store.op records, in the same transaction as their effect.
-- owner is the agent part of the key, so an alias migration can find them (prior_operation).
CREATE TABLE operations (key TEXT PRIMARY KEY, owner TEXT NOT NULL, fingerprint TEXT NOT NULL,
  result TEXT NOT NULL);

-- Identity aliases that this database has applied (today: identity-migrated/<alias>).
CREATE TABLE aliases_applied (alias TEXT PRIMARY KEY, identity TEXT NOT NULL);

-- Notice outbox (see "Notices"). version is the clock value of the last unread change.
CREATE TABLE notice_outbox (agent TEXT PRIMARY KEY, version INTEGER NOT NULL);

-- Gallery state (gallery/state, gallery/history, gallery/draft), as JSON values with a revision.
CREATE TABLE gallery (key TEXT PRIMARY KEY, value TEXT NOT NULL, rev INTEGER NOT NULL);

-- Import only (see "Migration"): the key and revision of each source record that the import
-- applied, and bodies that arrive in chunks. Dropped by a later cleanup commit.
CREATE TABLE import_source (key TEXT PRIMARY KEY, rev TEXT NOT NULL, complete INTEGER NOT NULL);
CREATE TABLE import_body (key TEXT PRIMARY KEY, body BLOB NOT NULL);
```

Schema version: `PRAGMA user_version` (needs H7). Version 1 is this schema. The plugin applies each
migration in one transaction that also sets the version. Foreign keys: on (needs H7).

## Exact integers

Lua numbers lose precision above 2^53. The plugin never passes a revision as a Lua number:

- In SQL text, a revision parameter is `CAST(? AS INTEGER)` with a decimal string, and a revision
  result is `CAST(x AS TEXT)`. (Or the typed encoding of H1, if the contract gives one.)
- In Lua, revisions are compared with `later()` (length, then bytes), as today.
- The clock and seq are SQLite INTEGER (64-bit). A key-value revision above 2^63 - 1 stops the
  import with `migration_conflict` (not observed; today's live revisions are about 10^5).

## Operations

Each operation is one `hub.sql.batch` (one transaction). "Bump" is an assertion `SELECT 1 FROM
clock WHERE n < 9223372036854775807` (expected 1 row, else the batch fails with `clock_exhausted`;
an increment past 2^63 - 1 would make the value REAL), then `UPDATE clock SET n = n + 1`. A later
statement of the same batch uses `(SELECT n FROM clock)` as "clock".

**Every batch that gives out a new revision bumps the clock** and uses the new value: a message
`seq`, a draft `rev`, a title or home `set_rev`, a gallery `rev`, a notice version. So two writes
never share a revision, and an `UPDATE ... WHERE rev = <base>` fails for the second of two saves
from one base, even with no message between them. A guarded statement has
an expected change count; a different count rolls the whole batch back with `conflict` and the
statement index (needs H2). An **assertion** is a query with an expected row count (needs H2). On
`conflict` the plugin reads again and retries, at most `attempts` times, as today.

**Every batch that changes unread state** (a delivery insert, an ack, a union) bumps the clock and
writes `notice_outbox(agent, clock)` for each agent whose unread state it can change (see
"Notices"). So two such batches never share a version.

### Send (`messaging.send`, view send, member notice)

1. Validation in Lua, as today: arguments, limits, the operation key (`operations`, then the
   fallback), `resolve_recipient`, and the reply target. `reply_to` keeps today's whole rule: the
   message exists, it is addressed to the agent (a delivery row for the agent), and it is from the
   recipient or in the same group (`message.from == to`, or `to` is a group and `message.to ==
   to`). A delivery row alone does not validate it.
2. The batch: bump; insert the message (`seq` = clock); insert the deliveries; clear the reply
   target (`UPDATE deliveries SET acked = 1 WHERE agent = sender AND seq = <reply_to seq>`, no
   expected count: an acked or absent row is not an error, as today); insert the operation; write
   the outbox for the recipients and, with reply_to, the sender.
3. The audience, by recipient kind:
   - **Direct**: one delivery for `to` (also when `to` is the sender: today's self mailbox).
   - **Created group**: the message insert is `INSERT ... SELECT ... WHERE EXISTS (SELECT 1 FROM
     group_members WHERE gid = ? AND agent = sender AND current = 1)`, expected 1 (a refused
     sender changes nothing). The deliveries are `INSERT INTO deliveries SELECT agent, clock, 0 FROM
     group_members WHERE gid = ? AND current = 1 AND agent <> sender`. The audience and the
     membership check read the same transaction, so a membership change cannot fall between them.
   - **team**: the members are the live roster (`hub.agents`), as today; the hub owns it, so it is
     not in this database. The plugin reads the roster in the same action (`refresh_participants`),
     checks that the sender is in it, and passes the other members as one JSON array parameter:
     `INSERT INTO deliveries SELECT value, clock, 0 FROM json_each(?)`. This is today's rule: today's
     team send guards no record either. A roster change between the read and the commit gives the
     audience that the read saw, as today.
   - **User join** (view send to an observed group): the same batch inserts the user's
     `group_members` row (`current = 1`, next `pos`) before the deliveries. No backfill.
4. `messages.recipients` today is the audience list. It is now the delivery rows of the message.

### Read (`messaging.read`)

One read action is **one SQL statement**, so its rows and its final cursor are one snapshot:

```sql
SELECT CAST(m.seq AS TEXT), m.id, m.sender, m.recipient, m.body, m.reply_to, m.reply_expected, m.at,
       CAST(c.n AS TEXT) AS high
FROM clock c LEFT JOIN (
  SELECT m.* FROM deliveries d JOIN messages m ON m.seq = d.seq
  WHERE d.agent = ? AND d.acked = 0 AND d.seq > CAST(? AS INTEGER) [AND thread = ?]
  ORDER BY d.seq LIMIT ?) m
ORDER BY m.seq;
```

- The plugin fits the rows into the 48 KiB agent reply, as today (`fit_page`, `shrink`).
- `next_cursor`: if the statement returned fewer than `LIMIT` rows and they all fit the page, it is
  `high` (the clock of the same snapshot). Else it is the cursor of the last item on the page.
- Why it is safe: every message committed after the snapshot has `seq` > `high`. A separate clock
  query could return a clock above a message that the rows query did not see; this plan has none.
- This needs H4 to return one statement's result from one snapshot, inside one reply, or a typed
  error. If the result does not fit, the plugin repeats with a smaller `LIMIT` (at least 1).
- **Oversized rows.** The statement above fails before it returns any row if one row is larger
  than a hub.sql reply. So the read has two steps:
  1. **Selection** (one statement, the snapshot of the read): the same query, but with bounded
     columns only: `seq`, `high`, and for each text column its byte length
     (`length(CAST(x AS BLOB))`) and a prefix `substr(CAST(x AS BLOB), 1, 1024)`. This result is
     small for every row, so it fits one reply for `LIMIT` rows.
  2. **Fill**: for each selected row whose full size fits the agent page, the plugin reads its
     columns by `seq` (messages are immutable, so a later statement returns the same bytes). For a
     row that does not fit, it reads only the bytes that the page needs (`substr` on the BLOB cast,
     so offsets are bytes, not characters; the cut is made UTF-8-safe in Lua with `utf8_cut`).
  - The page and its continuation come from the selection: `next_cursor` is `high` of the
    selection, or the last item's `seq`. A concurrent ack between the steps does not remove a
    selected message from this page (the fill reads `messages`, not `deliveries`); the next read
    does not return it again. A selected message is never dropped or skipped.
  - Today's markers stay: a body too large gives a prefix with `truncated` and `body_bytes`;
    metadata too large gives `metadata_too_large` and `bytes`; an ID too large gives `id_prefix`
    and `id_bytes` (`shrink`, unchanged). The byte lengths come from the selection.
- A concurrent ack removes rows from later reads, as today. An alias migration changes `agent`
  but not `seq`, so a cursor stays valid.

### Other actions

| Action | hub.sql |
| --- | --- |
| `messaging.ack` | Validate the whole request first, in Lua, as today: the argument shape, then each ID has a delivery row for the agent (today's `addressed`), else `refused` and no effect. An empty list, or a list with no unread delivery (one query), is a no-op: no batch, no bump, no notice (send.lua tests that an ack writes nothing then). Else the batch: bump; `UPDATE deliveries SET acked = 1 WHERE agent = ? AND acked = 0 AND seq IN (SELECT seq FROM messages WHERE id IN (SELECT value FROM json_each(?)))` (needs H6), expected at least 1, else `conflict` and a new read (a concurrent ack: then the no-op); outbox. No statement sets `acked = 0`. |
| `view.seen` | The same no-op rule. Else the batch: bump; one `UPDATE deliveries SET acked = 1` with today's filter (group: `recipient = peer`; direct: `recipient = user AND sender = peer`); outbox. The reply `acked` is its change count (needs H2). |
| `messaging.history` | `SELECT ... WHERE thread = ? AND seq < CAST(? AS INTEGER) ORDER BY seq DESC LIMIT ?`, one statement, fitted as today. Group history needs current membership (team: the roster). |
| unread counts, tabs, thread list | `GROUP BY` over the agent's unread deliveries; homes, titles, opened, archived: one query each. |
| `thread_members` | Batch: update `group_members` (current, pos); insert the member notice and its deliveries (`added` only); bump and outbox. No backfill (every message has its rows). |
| draft save | Bump; `UPDATE drafts SET text = ?, rev = clock ... WHERE rev = CAST(? AS INTEGER)` expected 1, or `INSERT` (expected 1, no conflict) when the base is `0`. The operation result gets the new revision with `json_set(?, '$.draft_revision', CAST((SELECT n FROM clock) AS TEXT))`. |
| view send | Send, plus the draft clear: `UPDATE drafts SET text = '', rev = clock ... WHERE rev = ?` expected 1, else `draft_conflict`. |
| create, archive, rename, move | One row each + the operation row, in one batch. A title or a home gets `set_rev` = clock after a bump. |

Operation keys and fingerprints stay exactly as today, and so does `normalized_fingerprint`.

### Lost replies

A `hub.sql.batch` whose reply is lost has an unknown outcome. The plugin ends the action with
`unavailable`. The agent retries with the same key; the retry finds the `operations` row (the batch
committed) or does not (it did not commit). The operation row commits with its effect, so a replay
never sends twice and never sets an acked delivery to unread. `messaging.ack` and `view.seen` have
no key: setting `acked = 1` again is the same state. Needs H3: a batch commits completely or not at
all, and a timeout never leaves it half-applied or still running.

## Notices

Today the `notify` op is inside the key-value batch. The SQL file is separate from the hub's
notices, so this plan makes no claim of atomicity across them. It uses an outbox:

1. Each batch that changes an agent's unread state writes `notice_outbox(agent, version = clock)`.
2. After the commit, the plugin flushes the outbox: one statement reads, for a page of rows,
   `agent, version, EXISTS (unread delivery) AS pending` (one snapshot). For each row it calls the
   hub notice with `pending` and `version`, and then deletes the row `WHERE agent = ? AND version =
   ?`. A newer change has a higher version, so its row stays and is flushed again.
3. Stale clear: the hub notice must ignore a version lower than the last one it applied for that
   agent (needs H5). Without H5, two flushes (two actions of one instance, or an old and a new
   instance) can apply `false` after a newer `true`. This plan does not claim that one instance
   flushes serially; it depends on H5, and on H8 for the old instance.
4. **Retry without traffic.** A flush runs after each committed batch, and also from a timer
   (`rex.every`; observed in the reviewer lab, 2026-10-20, docs/rex-protocol.md "Plugin timers"),
   so a failed notice is retried even if nobody acts. The timer is armed at start; it flushes only
   when the outbox has rows, with a backoff from 1 s to 60 s per failing agent (kept in Lua; reset
   after a success). Rex runs handlers one at a time, so a timer flush and an action flush do not
   run at the same time in one instance; the version guard (H5) covers the rest. The start-up
   flush is paged and runs after the plugin starts to serve calls. A failed flush never stops the
   plugin.
   - A transient error: the row stays; the timer tries again.
   - The hub refuses the agent: the row is deleted only if the agent is an alias (`alias_of` in
     `hub.agents`, immutable). An alias's unread state moves to its identity in the alias
     migration, which writes the identity's outbox row. Any other refusal (an agent that is absent
     now and can come back) keeps the row: the timer retries it with the longest backoff, and a
     roster change (`hub.changed agents`) retries it at once.
5. A batch of 100 recipients makes 100 outbox rows, so 100 notice calls. A batched notice call
   (a list of `{agent, pending, version}`) is proposed for H5.

Render: the plugin declares its tabs after the commit, from committed rows, as today. A
rolled-back batch declares nothing.

## Identity aliases

One batch for each alias, with set-based statements only: the SQL text is constant per alias, and
several aliases are several batches, in sorted order (one alias per batch keeps the request bounded;
each batch is atomic and leaves a valid state). The row work is bounded by the hub's statement time
limit (H2/H3).

**Order inside the batch.** A direct `UPDATE` of a key column fails on the first collision with an
existing key, before any `ON CONFLICT` clause can apply. So each keyed table is merged in three
steps, never with an `UPDATE` of its key:

1. Stage: `INSERT INTO <table> (<target key>, <values>) SELECT <canonical key>, <values> FROM
   <table> WHERE <key names x> ON CONFLICT (<key>) DO UPDATE SET <the winner rule>`. The canonical
   key is computed in the SELECT: `y` for `x` in each column, and a pair sorted with
   `min(a', b')`, `max(a', b')`. If several source rows map to one target, SQLite applies them
   one at a time, and the winner rule decides each one, so the result does not depend on the order.
2. Delete the source rows: `DELETE FROM <table> WHERE <key names x>`. (A source row whose key does
   not change has no `x` in it, so it is not deleted.)
3. `messages` has no keyed thread columns, so it is a plain `UPDATE` (no collision is possible).

For each alias `x` of identity `y` (SQL parameters):

- `messages`: `UPDATE ... SET sender = y WHERE sender = x`; the same for `recipient`.
- Threads in `messages`: `UPDATE` the pair to `min(a', b'), max(a', b')` where `a' = (CASE a WHEN
  x THEN y ELSE a END)` (the same for `b'`), `WHERE thread_kind = 'direct' AND (thread_a = x OR
  thread_b = x)`. One statement; SQLite reads the old row for every expression.
- `thread_homes`: stage and delete. The winner rule is today's: a `moved` row with the newest
  `set_rev` wins; else the row with the oldest `set_rev` wins. `set_rev` moves with the value.
- Peers (titles, opened, archived, drafts): stage and delete, with the canonical `viewer`,
  `peer_a`, `peer_b` (an `agent` peer, and an `observed` pair re-sorted). Titles: the newest
  `set_rev` wins. Opened and archived: the union (`DO NOTHING`). Drafts: first an assertion,
  expected 0 rows: two rows that map to one target, both with non-empty text, and different text;
  a row means `migration_conflict`, and the batch rolls back (today's rule). Else the non-empty
  text wins (with its `rev`).
- `deliveries`: stage and delete. `INSERT INTO deliveries SELECT y, seq, acked FROM deliveries
  WHERE agent = x ON CONFLICT (agent, seq) DO UPDATE SET acked = min(acked, excluded.acked)`, then
  delete the `x` rows. A message unread under either name stays unread (today: the mailbox union).
- `group_members`: stage and delete: one row for `y`, `pos` = the lower one (today keeps the first
  occurrence), `current` = the higher one. Past members are canonical too.
- `operations.owner` stays: `prior_operation` searches the owners of the identity and its aliases,
  as today, in `operations` and then in the key-value fallback.
- `aliases_applied (x, y)`; bump; outbox rows for `x` and `y`.

A batch fails as a whole; the next call runs it again. Today's `identity-migrate/` operation key
is not needed: `aliases_applied` commits in the same batch.

## Migration from the key-value store (one time)

### States at start

The plugin reads its state **before** it touches the key-value store. The state comes from two
records: the SQL `meta` row `import` and the key-value fence record `sql-import` (below).

| State | How the plugin knows | What it does at start |
| --- | --- | --- |
| fresh | no SQL `import` row, no fence | `refresh_participants`; today's key-value `migrate_aliases` (unchanged code), so the source is canonical; write the fence (f0); save `{state = importing, f0, aliases = A0}` in SQL; import. |
| importing | SQL `importing` | Source check (below). Unchanged: continue from the progress. Changed: reset. No key-value `migrate_aliases` (it would change the source). |
| verified | SQL `verified` | Source check again; then write the cutover fence (f1, below). |
| fence written | fence `{state = 'cutover'}`, SQL not `done` | f1 = the fence record's own revision (read it; it is not lost in a crash). Source check against f1 (every source revision below f1, equal to `import_source`); then the SQL `done` batch. |
| done | SQL `done` | SQL only. No key-value access, except the read-only operation fallback. A key-value alias limit or a stale key-value record cannot block a start. |

- A0 is the alias set at the fence. The import canonicalizes with A0 only. An alias that appears
  during the import is not applied to the source: its records import under the old name, and the
  SQL alias migration merges them after `done` (it has no `aliases_applied` row).
- A key that is not canonical under A0, or two source records with one canonical key, stops the
  import with `migration_conflict` and the keys.
- Reset (the source changed): first the plugin rewrites the fence with `if_rev` = the fence's
  current revision (never `if_rev = 0` against an existing record); its new revision is the new
  f0. Then one SQL batch deletes every imported row and sets `{state = importing, f0 = new f0,
  progress = start}`. A crash between the two leaves SQL with the old f0 and the old rows; the
  next start finds the same change and resets again. The fence is not a source record, so its
  rewrite alone never counts as a change.
- After `done`, new aliases go through the SQL alias migration.

### The source fence

The key-value store gives each written record a revision from one global counter (hub store.go,
`nextRev`). The import uses that:

- **Fence**: at the first import step, the plugin writes the key-value record `sql-import` `{state
  = 'importing'}` (if_rev `0`) and saves its revision `f0` in `meta`. Every key-value write after it
  has a revision above `f0`.
- Messaging code from this release onward refuses to write messaging families while `sql-import`
  exists (it reads SQL instead). An older release does not know the fence; a rollback to it during
  the import is the case the next point detects.
- **Source records**: each imported key-value record adds `import_source (key, rev, complete)` in
  the same batch as its rows.
- **Resume**: before it continues, the import checks that the source did not change: every
  `import_source` row still has its revision and no family record has a revision above `f0`. A
  change (an old release wrote, or a record was deleted) is a reset (see "States at start"). A
  deleted record that the import has not reached yet is found by the verification. `INSERT OR IGNORE` is not used: every insert is a plain insert, so a duplicate
  is an error, never a silent "equal".
- **Verification** (before the cutover) is a full scan of the families: the set of keys and
  revisions equals `import_source`, and every revision is at or below `f0`. Then the content checks
  below.

### Import steps

Each step is one batch: its rows, its `import_source` rows, and the progress `{family, after}` in
`meta`. A crash continues from the progress, after the resume check.

- `message/` -> `messages`, `seq` = the record revision, sender and recipient canonical, the thread
  columns from today's `thread_key(from, to)`.
  - **Large records**: a record that is larger than one hub.sql request is imported in chunks: the
    body goes into `import_body` in parts (UTF-8-safe cuts, one part per batch), each batch checks
    the stored length first (`length(body) = ?`, expected 1) and moves the progress to `{key,
    offset}`; the last batch moves the row into `messages` and sets `complete = 1`. A resumed
    import continues at `offset`. A record that the hub cannot return at all (`record_too_large`
    today) stops the import with `migration_conflict` and the key; the source stays as it is, and
    nothing is truncated or dropped.
- The audience -> `deliveries` (`acked = 1` at first): the message's `recipients`, else
  `delivery/<id>`, else today's fallback (the current members of the group, or the roster for
  `team`, without the sender). The fallback is evaluated once, at the import; today it is
  evaluated at each read, and a membership change snapshots it first. So it differs only for a
  legacy `team` message whose roster changes after the import. README states it.
- `mailbox/<agent>` -> `acked = 0` for each ID. An ID without a message or without a delivery row
  for the agent stops the import with `migration_conflict` (today it is `internal` at read time).
- `groups` -> `groups`, `group_members` (members in order, then `past_members` not in members,
  `current = 0`).
- `thread-meta/` -> `thread_homes`; `thread-title/`, `thread-open/`, `thread-archive/` (one row
  per ID), `draft/` -> their tables. `set_rev` = the stored `set_rev`, else the record revision.
  A draft record with empty text is a row with empty text and its revision; a missing draft is no
  row (rev `0`), as today.
- `identity-migrated/` -> `aliases_applied`. `gallery/*` -> `gallery`.
- `thread/`, `thread-seg/`: not imported (derived); used in the verification.
- `thread-page/`: not imported. No code reads it today (only the alias migration lists it).

### Verification (before the cutover)

After the source check above:

- each thread chain (tail and segments, in order) equals `SELECT id ... WHERE thread = ... ORDER
  BY seq`;
- for each message, the delivery rows equal its audience (recipients, delivery snapshot, or
  fallback);
- for each agent, the unread deliveries equal its mailbox, and every other delivery is acked. So a
  message that was acked stays acked.

A mismatch stops the start with `migration_conflict` and the key; nothing is cut over.

### Cutover

Two commits in two stores, in this order. A crash between them is the state "fence written".

1. **Key-value**: the plugin rewrites the fence record (`sql-import` `{state = 'cutover'}`,
   `if_rev` = its revision). Its new revision is f1. Every value that Messaging gave out before
   (read `next_cursor` = a mailbox or message revision, history `before`/`next_before` = message
   revisions, `draft_revision`, `set_rev`) is a key-value revision that the global counter gave
   out before f1. So every one is below f1.
2. **SQL**, one batch: `clock.n = f1`; the meta row `import = done`; outbox rows for every agent
   with an unread delivery.

After step 2 the plugin reads and writes SQL only. The fence record stays, so a later start of
this release never writes the key-value families.

### Old operation keys

`hub.store.op` cannot list its records, so they are not imported. A lookup that misses in
`operations` falls back to `hub.store.op` (read only), for the identity and its aliases (today's
`prior_operation`), so a retry from before the cutover replays its first result.

### Rollback and backup

- **Rollback to a key-value release after the cutover is not supported.** The key-value records
  stay as they were at the cutover. A release that reads them does not see new messages, and it
  shows acked messages as unread again. A rollback needs an explicit recovery decision (an export
  from SQL back to key-value is not in this plan).
- A rollback during the import (before the cutover) is safe: the key-value records are the source
  of truth, and the next import start detects the change and starts again.
- Backup: the hub's backup path must include the SQL file (H9). Keep the key-value backup from the
  cutover. After the cutover, the SQL file is the source of truth.

## Sizes and costs

- A send's request holds the body twice (the message and the fingerprint in `operations`), the
  recipient, fixed SQL text and, for `team`, the roster as one JSON array. It does not depend on
  mailbox, group or thread size.
- Row work of a send to a group of n: n delivery rows, n outbox rows, n notice calls after the
  commit (one call with H5's list form). For n = 100: measured in the size test, not estimated.
- The body limit (16384 encoded bytes) and the page rule (one message fits one read page) stay:
  they bound replies, not storage.

## What Messaging needs from hub.sql

Sent to the coordinator and the Hub thread 2026-10-21; aligned with the reviewer's gates 1-8.

- **H1 Parameters.** Bound parameters only; TEXT, INTEGER, NULL, BLOB. 64-bit integers stay exact
  through JSON (decimal strings or a typed encoding, never a float).
- **H2 Batch.** `hub.sql.batch` applies all statements in one transaction. A statement can carry
  an expected change count (writes) or an expected row count (queries, as assertions); a mismatch
  rolls back with `conflict` and the index. The reply has each statement's change count and rows,
  in order.
- **H3 Outcome.** A batch commits completely or not at all. A timeout or a cancel gives a defined
  outcome (rolled back, or committed and reported); never "still running".
- **H4 Results.** One statement's result is one snapshot, returned in one reply, inside the reply
  limit by encoded bytes; a result that does not fit is a typed error (not a partial result).
  One oversized cell: a typed error.
- **H5 Notices.** A hub notice call that takes a version and ignores an older one, in a list form
  for many agents. The plugin owns the outbox.
- **H6 SQL features.** SQLite with `json_each`, `json_set`, `ON CONFLICT ... DO UPDATE`, partial
  indexes, `WITHOUT ROWID`, `substr` and `length` on BLOB, multi-argument `min`/`max`, allowed by
  the authorizer.
- **H7 Schema.** `PRAGMA user_version` read and set, `PRAGMA foreign_keys = ON` per connection.
- **H8 Fencing.** A retired plugin instance cannot write after its replacement starts (SQL and
  key-value).
- **H9 Lifecycle.** The file belongs to the plugin entry: kept across restart, replace and prune;
  in the hub backup.
- **H10 Harness.** `lazyrex-hub test` gives each run a fresh database; `hub.test.calls` records
  SQL calls with their SQL and parameters, and reports dropped records; a fault hook can fail a
  batch at a given statement and can drop a reply after commit.

## Tests (proposed)

- The behaviour tests stay and must pass unchanged where they use agent and view actions only
  (send, read, ack, history, threads, members, homes, menus).
- Tests that write key-value records before the plugin starts become import tests (the fixture is
  the old data).
- Tests that inject key-value records during a run test machinery that goes away (chains, `if_rev`
  races). Before any is retired, a coverage map (each test, the behaviour that it proves, the SQL
  test that proves it after) goes to the reviewer.
- New: the live case (a short send to a 9-member group whose members have hundreds of unread
  messages) commits; a 100-member group send (sizes and costs measured); a lost reply after commit
  replays the result; a batch that fails at its last statement leaves nothing; an ack and a send
  race; a read race (a send commits between two reads; the second read returns it); the outbox
  after a crash between commit and notice, a refused agent, a transient failure, and a stale clear
  (with H5); an alias union where a message is unread under one name only, colliding homes,
  titles and drafts, and an observed pair; import: a crash at each phase and resume, a source
  change during the import (an old release writes), a chunked large body with a crash between
  chunks, a `record_too_large` source, a verification mismatch, acked messages stay acked, a crash
  before the f1 fence write and a crash after it (before SQL `done`), a restart in `done` with a
  stale key-value alias state; `since`, `before` and `draft_revision` values from before the
  cutover; integers above 2^53; two draft saves from one base with no send between them (the
  second is `draft_conflict`); a repeated and an empty ack write nothing; a notice that fails once
  with no later action (the timer delivers it); an oversized row in a read with a concurrent ack.

## Order of commits (proposed)

1. Schema, clock, the storage layer (a small module that wraps `hub.sql`), and the outbox.
2. Send, read, ack, history, view.seen on SQL, with the tests.
3. Threads, groups, members, homes, titles, drafts, gallery.
4. Identity aliases on SQL.
5. The import: fence, source records, chunks, verification, cutover; the operation-key fallback.
6. Retire the key-value code paths (chains, mailboxes, M1 scans) and the tests of them, after the
   reviewer accepts the coverage map.

Each commit keeps the suite green against a hub with `hub.sql`. Commits 1-4 run only on a fresh
database; commit 5 makes the plugin safe for a store with data. No release before commit 5.
