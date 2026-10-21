# Messaging storage on hub.sql (proposed)

Status: proposal, revision 0, 2026-10-21. Not implemented. It depends on the `hub.sql` contract,
which the hub lead writes now. Where this plan needs a `hub.sql` feature, it says "needs H<n>" (see
"What Messaging needs from hub.sql"). F2 (docs/f2-unread.md) is cancelled; this plan replaces it.

Decision (user, 2026-10-21): each plugin gets its own SQLite database, run by the hub, through hub
actions. Messaging keeps its current semantics exactly:

- An agent acknowledges each message on its own (per-ID ack). There is no read watermark.
- The audience of a message is fixed when it is sent. A later membership change does not change it.
- A removed member keeps the mail that it received, and can read it with `messaging.read {thread}`.

## Why the key-value store is replaced

Every limit of the current store comes from one rule: a change is a batch of whole records, each
guarded by its revision. So a send rewrites the whole mailbox of each recipient and the whole
`groups` record (the live 64628-byte failure, 2026-10-21); a thread needs a chain of segments (F1);
an unread count reads every unread message (the get storm). In SQL, each of these is a row, and a
send writes rows for one message only. The request size of a send no longer depends on the state.

## Tables

All IDs are TEXT, as today. `part(x)` is today's length prefix (`#x .. ':' .. x`). A thread key is
today's suffix of `thread/<suffix>`: `part(a) .. part(b)` for a direct pair (sorted, canonical), and
`part('') .. part(gid)` for a group (`team` included).

```sql
-- One counter for every revision that the plugin gives out: message cursors, draft revisions,
-- set_rev of titles and homes. It starts at the highest key-value revision (see "Migration"), so
-- every cursor and revision from before the migration is lower than every new one.
CREATE TABLE clock (one INTEGER PRIMARY KEY CHECK (one = 1), n INTEGER NOT NULL);

-- Plugin state: import_state (see "Migration").
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE TABLE messages (
  seq            INTEGER PRIMARY KEY,     -- the cursor (today: the message record revision)
  id             TEXT NOT NULL UNIQUE,    -- send/<part(from)><part(key)>, member-notice/...
  sender         TEXT NOT NULL,           -- canonical
  recipient      TEXT NOT NULL,           -- canonical agent ID, team, or g-...
  thread         TEXT NOT NULL,           -- thread key
  is_group       INTEGER NOT NULL,        -- 1 if recipient is team or g-...
  body           TEXT NOT NULL,
  reply_to       TEXT,
  reply_expected INTEGER,                 -- NULL (absent) or 0 (FYI), as today
  at             TEXT NOT NULL
);
CREATE INDEX messages_thread ON messages (thread, seq);

-- The audience, fixed at send: one row per recipient. acked = 0 is unread.
CREATE TABLE deliveries (
  agent TEXT NOT NULL,
  seq   INTEGER NOT NULL REFERENCES messages (seq),
  acked INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (agent, seq)
) WITHOUT ROWID;
CREATE INDEX deliveries_unread ON deliveries (agent, seq) WHERE acked = 0;

CREATE TABLE groups (gid TEXT PRIMARY KEY, name TEXT NOT NULL);
-- pos keeps today's member order. current = 0 is a past member (past_members today).
CREATE TABLE group_members (
  gid TEXT NOT NULL REFERENCES groups (gid), agent TEXT NOT NULL,
  pos INTEGER NOT NULL, current INTEGER NOT NULL,
  PRIMARY KEY (gid, agent)
) WITHOUT ROWID;

-- Per-thread and per-viewer state. peer is today's peer ID (agent, team, g-..., or d-...).
CREATE TABLE thread_homes (thread TEXT PRIMARY KEY, home_session TEXT NOT NULL,
  moved INTEGER NOT NULL DEFAULT 0, set_rev INTEGER NOT NULL);
CREATE TABLE thread_titles (viewer TEXT NOT NULL, peer TEXT NOT NULL, title TEXT NOT NULL,
  set_rev INTEGER NOT NULL, PRIMARY KEY (viewer, peer)) WITHOUT ROWID;
CREATE TABLE thread_opened (viewer TEXT NOT NULL, peer TEXT NOT NULL,
  PRIMARY KEY (viewer, peer)) WITHOUT ROWID;
CREATE TABLE thread_archived (viewer TEXT NOT NULL, peer TEXT NOT NULL,
  PRIMARY KEY (viewer, peer)) WITHOUT ROWID;
CREATE TABLE drafts (viewer TEXT NOT NULL, peer TEXT NOT NULL, text TEXT NOT NULL,
  rev INTEGER NOT NULL, PRIMARY KEY (viewer, peer)) WITHOUT ROWID;

-- Idempotent operations: today's hub.store.op records, in the same transaction as their effect.
CREATE TABLE operations (key TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, result TEXT NOT NULL);

-- Identity aliases that this database has applied (today: identity-migrated/<alias>).
CREATE TABLE aliases_applied (alias TEXT PRIMARY KEY, identity TEXT NOT NULL);

-- Notice outbox (see "Notices").
CREATE TABLE notice_outbox (agent TEXT PRIMARY KEY, version INTEGER NOT NULL);

-- Gallery state (gallery/state, gallery/history, gallery/draft), as JSON values with a revision.
CREATE TABLE gallery (key TEXT PRIMARY KEY, value TEXT NOT NULL, rev INTEGER NOT NULL);
```

Schema version: `PRAGMA user_version` (needs H7). Version 1 is this schema. The plugin applies each
migration in one transaction that also sets the version.

Foreign keys: on (needs H7). A delivery without its message is a defect, not a state.

## Operations

Each operation below is one `hub.sql.batch` (one transaction), unless it says otherwise. "Bump"
means `UPDATE clock SET n = n + 1`; a later statement of the same batch uses `(SELECT n FROM
clock)`. Each guarded statement has an expected change count; a different count rolls the whole
batch back with `conflict` and the statement index (needs H2). The plugin then reads again and
retries, at most `attempts` times, as today.

| Action | Today (key-value) | hub.sql |
| --- | --- | --- |
| `messaging.send` | message + every recipient mailbox + `groups` guard + thread tail + op | Bump. Insert the message (seq = clock). Insert one delivery per recipient: direct `{to}`; group `INSERT ... SELECT agent FROM group_members WHERE gid = ? AND current = 1 AND agent <> sender`, so the audience is the membership in the same transaction (no guard needed). The sender must be a current member: the message insert is `INSERT ... SELECT ... WHERE EXISTS (member)`, expected 1. reply_to: `UPDATE deliveries SET acked = 1` for the sender's delivery of reply_to. Insert the operation row. Outbox rows for each recipient and the sender. |
| `messaging.read` | the mailbox, then every unread message | One query: the agent's unread deliveries joined to messages, `seq > since`, optional thread, `ORDER BY seq`, keyset pages (needs H4). `next_cursor` of a complete read is `clock.n` from the same snapshot (never lower than a cursor from before the cutover, which could be a mailbox revision above every message); of a partial page, the last item's cursor (as today). |
| `messaging.ack` | validate, then rewrite the mailbox | Validate: each ID has a delivery for the agent (that is exactly today's `addressed`), else `refused`. Then `UPDATE deliveries SET acked = 1 WHERE agent = ? AND acked = 0 AND seq IN (SELECT seq FROM messages WHERE id IN (SELECT value FROM json_each(?)))` (needs H6), and an outbox row. An acked ID stays acked: no statement sets `acked = 0`. |
| `messaging.history` | walk the chain, read messages | `SELECT ... FROM messages WHERE thread = ? AND seq < ? ORDER BY seq DESC LIMIT ?`. The chain and its segments go away. Group history still needs current membership. |
| unread counts, tabs, thread list | scans of five families | `SELECT peer, count(*) ... GROUP BY peer` over unread deliveries; the tabs read homes, titles, opened, archived with one query each. |
| `view.seen` | read unread messages, then ack | One `UPDATE deliveries SET acked = 1` with today's filter (group: `recipient = peer`; direct: `recipient = user AND sender = peer`). The reply `acked` is the change count (needs H2). |
| `thread_members` | backfill `delivery/<id>`, rewrite `groups`, notice, tail | Update `group_members` (current, pos). Insert the member notice and its deliveries (`added` only). No backfill: every message already has its audience rows. |
| view send, user join | backfill, `groups`, mailboxes, tail, draft | As send. A join sets the user's `group_members` row in the same batch. The draft clear is `UPDATE drafts SET text = '', rev = clock WHERE viewer = ? AND peer = ? AND rev = ?`, expected 1, else `draft_conflict`. |
| draft save | `if_rev = base_revision` | `UPDATE ... WHERE rev = ?` expected 1 (or `INSERT` when base is `0`). The operation result gets the new revision with `json_set(?, '$.draft_revision', CAST((SELECT n FROM clock) AS TEXT))`. |
| create, archive, rename, move | one record each + op | One row each + the operation row. |

Operation keys and fingerprints stay exactly as today (`send/`, `thread-create/`, `members/`,
`thread-archive/`, `rename/`, `thread-move/`, `draft/`, `gallery-*`), and so does
`normalized_fingerprint`. The `operations` row commits with its effect, so a replay after a lost
reply returns the first result and never sends twice or sets an acked delivery to unread again.

### Lost replies

A `hub.sql.batch` whose reply is lost has an unknown outcome. The plugin never guesses. It ends
the action with `unavailable`. The agent retries with the same key; the retry finds the
`operations` row (the batch committed) or does not find it (it did not commit), and acts on that.
`messaging.ack` and `view.seen` have no key: they are idempotent (setting `acked = 1` twice is one
state). This needs H3: a batch commits completely or not at all, and a timeout never leaves a
batch half-applied or still running after the reply.

## Notices

Today the `notify` op is inside the key-value batch. The SQL database is a separate file, so a
notice cannot commit with the rows. This plan uses an outbox:

1. Each batch that can change an agent's unread state writes `notice_outbox(agent, version =
   clock)` (insert or replace).
2. After the commit, the plugin flushes the outbox: for each row, it reads `pending = EXISTS
   (unread delivery)`, calls the hub notice with `pending`, then deletes the row `WHERE agent = ?
   AND version = ?`. A newer change keeps its row, so it is flushed again.
3. At start, before it serves calls, the plugin flushes the whole outbox. This repairs a crash
   between a commit and its notice.

The notice is a level (pending or not), computed from committed rows at flush time, so a repeated
flush is harmless. A stale clear (an old `false` after a newer `true`) cannot come from one
instance, because it flushes in order and reads the state at flush time. Two instances can race;
H8 (fencing) prevents that. If the hub notice takes a version, the plugin sends `version`, and the
hub ignores an older one (proposed to the hub lead, H5).

Render: the plugin declares its tabs after the commit, from committed rows, as today
(`declare_tabs`). A rolled-back batch declares nothing.

## Identity aliases

Today `migrate_aliases` rewrites eight key families and merges thread chains. In SQL it is one
batch per new alias, with no chain merge (the thread order is `seq`):

- `UPDATE messages SET sender = ?` / `recipient = ?` from alias to identity.
- For each thread key that names the alias: compute the canonical key in Lua, then `UPDATE
  messages SET thread = ? WHERE thread = ?`.
- Deliveries: the union. `INSERT INTO deliveries (agent, seq, acked) SELECT identity, seq, acked
  FROM deliveries WHERE agent = alias ON CONFLICT (agent, seq) DO UPDATE SET acked = min(acked,
  excluded.acked)`, then delete the alias rows. A message unread under either name stays unread
  (today: the mailbox union).
- `group_members`: the same union; a member under both names is one row (current if either is).
- Homes, titles, drafts, opened, archived: today's rules (the newest move, else the first home; the
  newest title; a draft conflict is `migration_conflict`). They are a few rows, read in Lua.
- `aliases_applied` row and outbox rows for both names.

Today's `identity-migrate/` operation key is not needed: `aliases_applied` is in the same batch.

## Migration from the key-value store (one time)

The import runs at plugin start, before the plugin serves any call. It reads the key-value records
and never writes them. The plugin is the only writer of its store, and the hub retires the old
instance before the new one starts; H8 must make that a guarantee (a fence), not an assumption.

1. **Schema.** Create the tables (version 1) in one batch, with the meta row `import_state`:
   `{phase, after}` (a durable progress record).
2. **Import, in bounded batches.** For each family, in key order, from `after`: scan a page, write
   its rows with `INSERT OR IGNORE` (natural keys, so a repeated batch is harmless), and move
   `after` in the same batch. A crash continues from `after`.
   - `message/` -> `messages`, with `seq` = the record revision, `sender` and `recipient`
     canonical, `thread` = today's `thread_key(from, to)`.
   - The audience -> `deliveries` (acked = 1 at first): `recipients` in the message, else
     `delivery/<id>`, else today's fallback (the current members of the group, or the roster for
     `team`). The fallback is evaluated once, at import. Today it is evaluated at each read, and a
     membership change snapshots it first, so it changes only if a legacy `team` message meets a
     roster change after the import. README states it.
   - `mailbox/<agent>` -> `acked = 0` for each ID. An ID without a message is logged and counted
     (today it is `internal` at read time).
   - `groups` -> `groups`, `group_members` (members, then `past_members` with `current = 0`).
   - `thread-meta/`, `thread-title/`, `thread-open/`, `thread-archive/`, `draft/` -> their tables,
     with `set_rev`/`rev` = the record revision (or the stored `set_rev`).
   - `identity-migrated/` -> `aliases_applied`. `gallery/*` -> `gallery`.
   - `thread/` and `thread-seg/`: not imported (derived). They are used in the verification.
   - `thread-page/`: not imported. No code reads it today (only the alias migration lists it).
3. **Verification**, before the cutover: for each thread chain, the IDs in chain order equal
   `SELECT id FROM messages WHERE thread = ? ORDER BY seq`; each mailbox's ID set equals the
   unread deliveries of its agent. A mismatch stops the start with `migration_conflict` and the
   key, and nothing is cut over. (proposed; the live data decides whether a mismatch can happen.)
4. **Cutover.** One batch: `clock.n` = the highest revision that the import saw in any scanned
   record (so `since` and `draft_revision` values from before stay lower than new ones); the meta
   row `import_state = done`; outbox rows for every agent with a mailbox. After this batch the
   plugin reads and writes SQL only. No code path writes the key-value families again.
5. **Old operation keys.** `hub.store.op` cannot list its records, so they are not imported. A
   lookup that misses in `operations` falls back to `hub.store.op` (read only), so a retry of an
   operation from before the cutover replays its first result.

Cursor continuity: a `since` from before the cutover is a key-value revision. Imported messages
keep their revision as `seq`, so `seq > since` selects the same messages as today. A `before`
history cursor is a message revision too, and it stays one.

Rollback: the key-value records stay as they were at the cutover. A rollback to a release before
this one reads them, and it does not see any message, ack or change made after the cutover. A
later cleanup removes the key-value families; it is a separate step that the coordinator decides
after the release holds.

Backup: the hub's backup path must include the SQL file (H9). A restore of only one of the two
files gives the rollback state above, or a state ahead of the key-value records; the SQL file is
the source of truth after the cutover.

## Sizes after the change

- A send's request holds the body twice (the message and the fingerprint in `operations`), the
  recipient, and fixed statements. It does not depend on mailbox, group or thread size. A 100-member
  group send is the same request as a direct send (the deliveries are `INSERT ... SELECT`).
- The body limit (16384 encoded bytes) and the page rule (one message fits one read page) stay:
  they bound replies, not storage.
- Reads: the plugin fetches rows in keyset pages and fits them into the 48 KiB reply, as today. A
  row larger than one hub.sql reply must give a typed error (needs H4), which maps to today's
  `record_too_large` behaviour; `shrink` still makes one oversized message fit a read page.

## What Messaging needs from hub.sql

Sent to the coordinator 2026-10-21; aligned with the reviewer's gates 1-8.

- **H1 Parameters.** Bound parameters only; TEXT, INTEGER (64-bit, exact through JSON: decimal
  strings or a typed encoding, never a float), NULL. No SQL built from IDs.
- **H2 Batch.** `hub.sql.batch` applies all statements in one transaction. Each statement can
  carry an expected change count; a mismatch rolls back with `conflict` and the index. The reply
  has each statement's change count and rows (`RETURNING` or a query statement), in order.
- **H3 Outcome.** A batch commits completely or not at all. A timeout or a cancel gives a defined
  outcome (rolled back, or committed and reported); never "still running".
- **H4 Pages.** Query results inside the reply limit by encoded bytes, with a continuation that
  the plugin controls (keyset `WHERE seq > ?` is enough). One oversized cell: a typed error.
- **H5 Notices.** A hub notice call that takes a version and ignores an older one (or an
  equivalent). The plugin owns the outbox.
- **H6 SQL features.** SQLite with `json_each`, `json_set`, `ON CONFLICT ... DO UPDATE`, partial
  indexes, `WITHOUT ROWID`, multi-argument `min`/`max`. The authorizer allows them.
- **H7 Schema.** `PRAGMA user_version` read and set, `PRAGMA foreign_keys = ON` per connection.
- **H8 Fencing.** A retired plugin instance cannot write after its replacement starts.
- **H9 Lifecycle.** The file belongs to the plugin entry: kept across restart, replace and prune;
  in the hub backup.
- **H10 Harness.** `lazyrex-hub test` gives each run a fresh database; `hub.test.calls` records
  SQL calls with their SQL and parameters; a fault hook can fail a batch at a given statement and
  can drop a reply after commit.

## Tests (proposed)

- The behaviour tests stay and must pass unchanged where they use agent and view actions only
  (send, read, ack, history, threads, members, homes, menus).
- Tests that write key-value records before the plugin starts become import tests (the fixture is
  the old data). Tests that inject key-value records during a run (races on `if_rev`, torn chains,
  segment freezes) test machinery that goes away: each is retired, or replaced by the SQL case it
  stood for (concurrent send and ack; a membership change during a send). The list is part of the
  first commit's review.
- New: the live case (a short send to a 9-member group whose members have hundreds of unread
  messages) commits; a 100-member group send; a lost reply after commit replays the result; a
  batch that fails at its last statement leaves nothing; an ack and a send race; the outbox after a
  crash between commit and notice; import crash and resume at each phase; verification mismatch
  stops the cutover; `since` and `draft_revision` values from before the cutover; integers above
  2^53 in `seq`; an alias union where a message is unread under one name only.

## Order of commits (proposed)

1. Schema, clock, the storage layer (a small module that wraps `hub.sql`), and the outbox.
2. Send, read, ack, history, view.seen on SQL, with the tests.
3. Threads, groups, members, homes, titles, drafts, gallery.
4. Identity aliases on SQL.
5. Import, verification and cutover; the operation-key fallback.
6. Retire the key-value code paths (chains, mailboxes, M1 scans) and the tests of them.

Each commit keeps the suite green against a hub with `hub.sql`. Commits 1-4 run only on a fresh
database; commit 5 makes the plugin safe for a store with data. No release before commit 5.
