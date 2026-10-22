# Messaging storage on the Plugin SDK and hub.sql (proposed)

Status: proposal, revision 3, 2026-10-22. Not implemented. It targets the Plugin SDK and hub.sql
**draft 2** (LazyRex `docs/plugin-sdk.md` and `docs/sql.md`, commit 6ea4180), which the
coordinator made the spec (2026-10-22: code first). Where this plan needs an SDK feature that
draft 2 does not have, it says "needs G<n>" (see "Gaps in draft 2"). F2 (docs/f2-unread.md) is
cancelled; this plan replaces it.

History: revision 0 (d82d47d), 1 (4b7c6c2) and 2 (19838cb) planned against a lower-level hub.sql
(batches, guards, a plugin outbox). The reviewer's points on them stay in force where they still
apply; revision 3 keeps their substance and drops the machinery that draft 2 moves into the hub.
The two points open after revision 2 are closed here: the orphan fence ("States at start") and
the read selection ("Read").

Decision (user, 2026-10-21): each plugin gets its own SQLite database, run by the hub, through the
Plugin SDK. Messaging keeps its current semantics exactly:

- An agent acknowledges each message on its own (per-ID ack). There is no read watermark.
- The audience of a message is fixed when it is sent. A later membership change does not change it.
- A removed member keeps the mail that it received, and can read it with `messaging.read {thread}`.

## Why the key-value store is replaced

Every limit of the current store comes from one rule: a change is a batch of whole records, each
guarded by its revision. So a send rewrites the whole mailbox of each recipient and the whole
`groups` record (the live 64628-byte failure, 2026-10-21); a thread needs a chain of segments (F1);
an unread count reads every unread message (the get storm). In SQL, each of these is a row. The SQL
text and the parameters of a send do not depend on mailbox, group or thread size. (The row work
does: a 100-member send writes 100 delivery rows. See "Sizes and costs".)

## What draft 2 gives Messaging

From `docs/sql.md` draft 2 (proposed; the hub lead's lab tests prove each row before approval):

- **One transaction per handler** (section 3). It begins at the handler's first SQL call, read or
  write, and commits when the handler returns; an error rolls it back. "No other write to the
  plugin's file happens between" a handler's reads and its writes. So Messaging needs no revision
  guards, no retry loops on conflicts, and no `attempts` bound for storage. A rule that today needs
  an `if_rev` is a plain read and write inside the handler.
- **Notices** (section 7): `app.notice(agent, pending)` goes into the hub's outbox in the handler's
  transaction. Messaging computes `pending` with a query in the same transaction, after its writes,
  so it is exact. The hub applies notices in commit order, with receipts and timer retries, and
  keeps a notice for an agent that is absent now. Messaging has no outbox, no timer and no notice
  version. The first SQL commit with notices moves Messaging's notices to SQL for good
  (`notices_moved`): that is the cutover commit.
- **Retries** (section 8): Messaging opts out of the SDK result store (`{store = false}`) and keeps
  its own permanent `operations` table: its agent keys must replay forever, and its fingerprints
  are normalized for identity aliases.
- **Values** (section 4): a NULL is `nil` in a row keyed by column name; an integer above 2^53 is a
  string. `expect_rows` and `expect_changes` exist for assertions.
- **Pages** (section 4): a query returns whole rows up to the reply limit and a `more` flag; a
  first row over the limit is `too_large {row = 0, bytes}`.
- **Views refresh from tables read** (section 10). Messaging's panels and thread views read
  `messages` and `deliveries`, so a send re-renders each open Messaging view once (coalesced).

## Gaps in draft 2

Sent to the hub lead and the Tunnels pair on 2026-10-22 (`msg-sdk-d2-gaps`). None blocks the SDK's
to-do target; each blocks part of the Messaging port.

Answers (2026-10-22, proposed, not yet implemented): G1: `hub.sql.batch` (one transaction without
a token, from any code) and `app.db.transaction(fn)` (SDK v0). G2: any hub call of the instance
counts as activity (hub lead). G4: `app.hub` (SDK v0). G3: open; Messaging declares tabs at the end
of the handler. Views (G5 in the SDK gaps thread): raw `app.view` in v0. Wire fact (claude-22,
observed on Rex 0.0.1792158932-g88fd41): `rex.json.decode` drops a `null` inside an array, so the
SDK and the hub tag NULL; Messaging sees `nil` in rows keyed by column name.

- **G1 Atomic steps outside a handler.** The start-up work (the alias merge, the import steps, the
  cutover with its notices) runs outside an action handler, and `{tx = false}` runs each SQL call
  alone. Each of those steps must commit several statements together. Proposed: an advanced
  `app.db.transaction(fn)`, with the handler-transaction rules and notices.
- **G2 Idle limit.** "No call for 5 s" rolls a handler transaction back. A Messaging handler makes
  non-SQL hub calls (`hub.agents`, `hub.identify`, `hub.ui.tabs`), which took seconds on the live
  hub under load. Either a non-SQL call counts as activity, or Messaging makes its non-SQL calls
  before its first SQL call (possible for all but `hub.ui.tabs`, see G3).
- **G3 After-commit work.** Messaging declares its tabs (`hub.ui.tabs`) from the committed state
  after each write. Proposed: `app.after_commit(fn)`. Without it, Messaging declares tabs inside
  the handler, from its own uncommitted writes; a later failure of the commit leaves stale tabs
  until the next declaration.
- **G4 Raw hub calls.** The import reads the key-value store (`hub.store.scan`, `get`, `op`) and
  writes its fence (`hub.store.batch`). Either the SDK exposes `app.hub(action, args)`, or Messaging
  keeps its own `client.perform` wrapper for these calls.

## Tables

All IDs are TEXT, as today. Revisions and cursors are INTEGER in SQL and decimal strings in Lua and
JSON (see "Exact integers").

Thread and peer keys are columns, not today's length-prefixed strings, so an alias merge is
set-based:

- A **thread** is `(thread_kind, thread_a, thread_b)`. `direct`: the canonical pair, `thread_a <=
  thread_b` (a self thread has `thread_a = thread_b`). `group`: `thread_a = ''`, `thread_b` = the
  group ID (`team` or `g-...`).
- A **peer** (what a viewer sees in its thread list) is `(peer_kind, peer_a, peer_b)`. `agent`:
  `peer_a` = the agent, `peer_b = ''`. `group`: `peer_a` = the group ID, `peer_b = ''`. `observed`
  (the user's view of an agent-to-agent direct thread, today's `d-<hex>` ID): the canonical pair,
  `peer_a < peer_b`. The plugin computes the `d-<hex>` ID for routes and replies, as today.

```sql
-- One counter for every revision that the plugin gives out: message cursors, draft revisions,
-- set_rev of titles and homes, gallery revisions. The cutover sets it (see "Migration").
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
CREATE INDEX messages_sender ON messages (sender);
CREATE INDEX messages_recipient ON messages (recipient);

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

-- Idempotent operations: today's hub.store.op records. Written in the handler's transaction.
-- owner is the agent part of the key, so an alias merge can find them (prior_operation).
CREATE TABLE operations (key TEXT PRIMARY KEY, owner TEXT NOT NULL, fingerprint TEXT NOT NULL,
  result TEXT NOT NULL);

-- Identity aliases that this database has applied (today: identity-migrated/<alias>).
CREATE TABLE aliases_applied (alias TEXT PRIMARY KEY, identity TEXT NOT NULL);

-- Gallery state (gallery/state, gallery/history, gallery/draft), as JSON values with a revision.
CREATE TABLE gallery (key TEXT PRIMARY KEY, value TEXT NOT NULL, rev INTEGER NOT NULL);

-- Import only (see "Migration"): the key and revision of each source record that the import
-- applied, and bodies that arrive in chunks. Dropped by a later cleanup migration.
CREATE TABLE import_source (key TEXT PRIMARY KEY, rev TEXT NOT NULL, complete INTEGER NOT NULL);
CREATE TABLE import_body (key TEXT PRIMARY KEY, body BLOB NOT NULL);
```

The schema is version 1 of `app.db.migrate`. Foreign keys are on (draft 2 fixes it).

## Exact integers

Lua 5.1 numbers are doubles (observed on Rex 0.0.1792158932-g88fd41, hub lead). The SDK gives an
integer above 2^53 as a string and a smaller one as a number. Messaging never mixes them:

- A revision result is `CAST(x AS TEXT)` in SQL, so Lua always has a decimal string.
- A revision parameter is `CAST(? AS INTEGER)` with a decimal string (or the `{"int"}` tag).
- In Lua, revisions are compared with `later()` (length, then bytes), as today.
- The clock and `seq` are SQLite INTEGER (64-bit). "Bump" is an `expect_changes = 1` update
  `UPDATE clock SET n = n + 1 WHERE n < 9223372036854775807`; 0 changes is `clock_exhausted` (an
  increment past 2^63 - 1 would make the value REAL). A key-value revision above 2^63 - 1 stops the
  import with `migration_conflict` (not observed; live revisions are about 10^5).

## Actions

Every action is an SDK handler with `{store = false}`: one transaction, its own operation rules.
"Bump" (above) gives the next revision; a later statement uses `(SELECT n FROM clock)` as "clock".
**Every write that gives out a revision bumps the clock**: a message `seq`, a draft `rev`, a title
or home `set_rev`, a gallery `rev`. So two writes never share a revision.

Each action that changes an agent's unread state ends with, for each such agent, `app.notice(agent,
pending)` where `pending` is `EXISTS (SELECT 1 FROM deliveries WHERE agent = ? AND acked = 0)`,
queried in the same transaction after the writes. An action that changes nothing sends no notice.

### Operation keys

Keys and fingerprints stay exactly as today (`send/`, `thread-create/`, `members/`,
`thread-archive/`, `rename/`, `thread-move/`, `draft/`, `gallery-*`), and so does
`normalized_fingerprint`. A handler first looks the key up (`operations` for the identity and its
aliases; then the read-only key-value fallback, see "Old operation keys"). A hit replays the saved
result, or fails with today's conflict code on another fingerprint. A miss runs the action and
inserts the `operations` row in the same transaction. So a lost reply after the commit replays, and
a retry never sends twice and never sets an acked delivery to unread.

### Send (`messaging.send`, view send, member notice)

1. Validation in Lua, as today: arguments, limits, the operation key, `resolve_recipient`, and the
   reply target. `reply_to` keeps today's whole rule: the message exists, it is addressed to the
   agent (a delivery row for the agent), and it is from the recipient or in the same group
   (`message.from == to`, or `to` is a group and `message.to == to`).
2. In the same transaction: bump; insert the message (`seq` = clock); insert the deliveries; clear
   the reply target (`UPDATE deliveries SET acked = 1 WHERE agent = sender AND seq = <reply_to
   seq>`; an acked or absent row is not an error, as today); insert the operation; notices for the
   recipients (pending is true) and, with `reply_to`, the sender (queried).
3. The audience, by recipient kind:
   - **Direct**: one delivery for `to` (also when `to` is the sender: today's self mailbox).
   - **Created group**: the sender must be a current member (a query; else `refused`, as today).
     The deliveries are `INSERT INTO deliveries SELECT agent, clock, 0 FROM group_members WHERE gid
     = ? AND current = 1 AND agent <> sender`.
   - **team**: the members are the live roster (`hub.agents`), as today; the hub owns it, so it is
     not in this database. The plugin reads the roster in the same action (before the first SQL
     call, G2), checks that the sender is in it, and passes the other members as one JSON array:
     `INSERT INTO deliveries SELECT value, clock, 0 FROM json_each(?)`. This is today's rule: a
     roster change between the read and the commit gives the audience that the read saw.
   - **User join** (view send to an observed group): insert the user's `group_members` row
     (`current = 1`, next `pos`) before the deliveries. No backfill.
4. View send also clears the draft: the draft's `rev` must equal the request's `draft_revision`,
   else `draft_conflict`; then `text = ''` and `rev` = clock.

### Read (`messaging.read`)

The read handler's transaction is one snapshot (draft 2, section 3), so every query of one read sees
the same state, and nothing (no send, no ack, no alias merge) changes it between them.

- **Selection**: `SELECT CAST(m.seq AS TEXT) AS seq, length(CAST(m.id AS BLOB)) AS id_bytes,
  length(CAST(m.body AS BLOB)) AS body_bytes, length(...) of the other text columns, (SELECT
  CAST(n AS TEXT) FROM clock) AS high FROM deliveries d JOIN messages m ... WHERE d.agent = ? AND
  d.acked = 0 AND d.seq > CAST(? AS INTEGER) [AND thread = ?] ORDER BY d.seq LIMIT ?`. Each row is
  a few numbers, so the selection is small; the SDK still sizes it by bytes and returns `more` when
  the rows do not all fit. `LIMIT` is the number of messages that one agent page can hold at most
  (a page is 48 KiB and an item is at least the smallest marker).
- **Fill**: for the selected rows, in order, the plugin reads the columns of each message by `seq`
  in the same transaction (several per query while they fit one reply). For a message whose full
  item does not fit the agent page, it reads only the bytes that the page needs (`substr` on the
  BLOB cast, so offsets are bytes; the cut is made UTF-8-safe with `utf8_cut`). Today's markers
  stay: a body prefix with `truncated` and `body_bytes`; `metadata_too_large` and `bytes`;
  `id_prefix` and `id_bytes` (`shrink`, unchanged). The byte lengths come from the selection.
- **Continuation**: `next_cursor` is `high` only if the selection was complete (no `more`, fewer rows
  than `LIMIT`) and every selected message is on the page. Else it is the `seq` of the last item on
  the page. A message committed after the snapshot has `seq` > `high`, so it is never skipped.

### Other actions

| Action | In the handler's transaction |
| --- | --- |
| `messaging.ack` | Validate the whole request first, as today: the argument shape, then each ID has a delivery row for the agent (today's `addressed`), else `refused` and no effect. If no ID is unread: nothing more (no write, no notice; send.lua tests this). Else `UPDATE deliveries SET acked = 1 WHERE agent = ? AND acked = 0 AND seq IN (SELECT seq FROM messages WHERE id IN (SELECT value FROM json_each(?)))`, and the agent's notice. No statement sets `acked = 0`. |
| `view.seen` | The same no-op rule. Else one `UPDATE deliveries SET acked = 1` with today's filter (group: `recipient = peer`; direct: `recipient = user AND sender = peer`) and the notice. The reply `acked` is its change count. |
| `messaging.history` | `SELECT ... WHERE thread = ? AND seq < CAST(? AS INTEGER) ORDER BY seq DESC LIMIT ?`, fitted as today. Group history needs current membership (team: the roster). |
| unread counts, tabs, thread list | `GROUP BY` over the agent's unread deliveries; homes, titles, opened, archived: one query each. |
| `thread_members` | Update `group_members` (current, pos); insert the member notice message and its deliveries (`added` only, bump); notices for `added`. No backfill (every message has its rows). |
| draft save | The draft's `rev` must equal `base_revision` (absent = `0`), else `draft_conflict`; bump; write `text` and `rev` = clock. The result has `draft_revision` = clock. Two saves from one base: the second fails, even with no message between them. |
| create, archive, rename, move | One row each + the operation row. A title or a home gets `set_rev` = clock after a bump. |
| gallery | Its three rows, with a bump for each new revision. |

### Tabs

Messaging declares its tabs (`hub.ui.tabs`) after each action that writes, as today. With G3, from
`app.after_commit`; without it, at the end of the handler, from the handler's own state.

## Identity aliases

Today `migrate_aliases` rewrites eight key families and merges thread chains. On SQL it is one
transaction for each alias (G1), in sorted order, at the start of each action as today (it runs
only when a new alias exists). The SQL text is constant per alias; the row work is bounded by the
5 s statement limit (the sender and recipient indexes keep it short).

**Order.** A direct `UPDATE` of a key column fails on the first collision with an existing key,
before any `ON CONFLICT` clause can apply. So each keyed table is merged in two steps, never with an
`UPDATE` of its key:

1. Stage: `INSERT INTO <table> (<target key>, <values>) SELECT <canonical key>, <values> FROM
   <table> WHERE <key names x> ON CONFLICT (<key>) DO UPDATE SET <the winner rule>`. The canonical
   key is computed in the SELECT: `y` for `x` in each column, and a pair sorted with `min(a', b')`,
   `max(a', b')`. If several source rows map to one target, SQLite applies them one at a time, and
   the winner rule decides each one, so the result does not depend on the order.
2. Delete the source rows: `DELETE FROM <table> WHERE <key names x>`.

For each alias `x` of identity `y`:

- `messages` (no keyed columns, so plain updates): `sender`, `recipient`, and the thread pair, set
  to `min(a', b'), max(a', b')` where `a' = (CASE a WHEN x THEN y ELSE a END)`.
- `thread_homes`: the winner is today's: a `moved` row with the newest `set_rev`; else the row with
  the oldest `set_rev`. `set_rev` moves with the value.
- Titles: the newest `set_rev` wins. Opened and archived: the union (`DO NOTHING`). Drafts: first an
  assertion (`expect_rows = 0`): two rows that map to one target, both with non-empty text, and
  different text; a row means `migration_conflict` (today's rule). Else the non-empty text wins
  (with its `rev`). Peers include the `observed` pairs, re-sorted.
- `deliveries`: `INSERT INTO deliveries SELECT y, seq, acked FROM deliveries WHERE agent = x ON
  CONFLICT (agent, seq) DO UPDATE SET acked = min(acked, excluded.acked)`, then delete the `x` rows.
  A message unread under either name stays unread (today: the mailbox union).
- `group_members`: one row for `y`, `pos` = the lower one (today keeps the first occurrence),
  `current` = the higher one. Past members are canonical too.
- `operations.owner` stays: `prior_operation` searches the owners of the identity and its aliases.
- `aliases_applied (x, y)`; notices for `x` (false) and `y` (queried).

A transaction fails as a whole; the next action runs it again.

## Migration from the key-value store (one time)

### States at start

The plugin reads the SQL state **first**. If SQL says `done`, it does not read the key-value state
at all (only the read-only operation fallback stays). Else the state comes from the SQL `meta` row
`import` and the key-value fence record `sql-import`:

| State | SQL `import` | Fence | What the plugin does at start |
| --- | --- | --- | --- |
| fresh | absent | absent | `refresh_participants`; today's key-value `migrate_aliases` (unchanged code), so the source is canonical; write the fence (`if_rev = 0`), f0 = its revision; one transaction: `{state = importing, f0, aliases = A0}`; import. |
| orphan fence | absent | `importing` | A crash after the fence write and before the SQL row. Like fresh, but the fence write is a rewrite with `if_rev` = its current revision; its new revision is f0, and A0 is the alias set read now. Today's `migrate_aliases` may run first (no SQL row exists yet, so nothing depends on an older source). |
| importing | `importing` | `importing` | Source check (below). Unchanged: continue from the progress. Changed: reset. No key-value `migrate_aliases` (it would change the source). |
| verified | `verified` | `importing` | Source check again; then the cutover. |
| fence written | `verified` | `cutover` | A crash between the two cutover commits. f1 = the fence record's own revision (read it). Source check against f1; then the SQL cutover transaction. |
| done | `done` | any | SQL only. A stale key-value record or alias state cannot block a start. |

Any other combination (for example SQL `importing` with no fence) stops the start with
`migration_conflict`: it means that someone changed one store by hand.

- A0 is the alias set at the fence. The import canonicalizes with A0 only. An alias that appears
  during the import is not applied to the source: its records import under the old name, and the
  SQL alias merge applies it after `done` (it has no `aliases_applied` row).
- A key that is not canonical under A0, or two source records with one canonical key, stops the
  import with `migration_conflict` and the keys.
- Reset (the source changed): first the plugin rewrites the fence with `if_rev` = its current
  revision (never `if_rev = 0` against an existing record); its new revision is the new f0. Then one
  transaction deletes every imported row and sets `{state = importing, f0 = new f0, progress =
  start}`. A crash between the two leaves SQL with the old f0 and the old rows; the next start finds
  the same change and resets again. The fence is not a source record, so its rewrite alone never
  counts as a change.

### The source fence

The key-value store gives each written record a revision from one global counter (hub store.go,
`nextRev`). The import uses that:

- **Fence**: the key-value record `sql-import`. Every key-value write after the fence has a revision
  above f0.
- Messaging code from this release onward never writes the messaging key-value families: before
  `done` it does not serve actions (the import runs first), and after `done` it uses SQL only. An
  older release does not know the fence; a rollback to it during the import is what the source
  check detects.
- **Source records**: each imported key-value record adds `import_source (key, rev, complete)` in
  the same transaction as its rows.
- **Resume**: before it continues, the import checks that the source did not change: every
  `import_source` row still has its revision, and no family record has a revision above f0. A change
  (an old release wrote, or a record was deleted) is a reset. A deleted record that the import has
  not reached yet is found by the verification. Every insert is a plain insert, so a duplicate is an
  error, never a silent "equal".
- **Verification** (before the cutover) is a full scan of the families: the set of keys and
  revisions equals `import_source`, and every revision is at or below f0. Then the content checks
  below.

### Import steps

The import runs in `{tx = false}` code (G1, G4). Each step is one transaction: its rows, its
`import_source` rows, and the progress `{family, after}` in `meta`. A crash continues from the
progress, after the resume check.

- `message/` -> `messages`, `seq` = the record revision, sender and recipient canonical, the thread
  columns from today's `thread_key(from, to)`.
  - **Large records**: a record that is larger than one request is imported in chunks: the body goes
    into `import_body` in parts (UTF-8-safe cuts, one part per transaction); each step checks the
    stored length first (`length(body) = ?`, `expect_rows = 1`) and moves the progress to `{key,
    offset}`; the last step moves the row into `messages` and sets `complete = 1`. A resumed import
    continues at `offset`. A record that the hub cannot return at all (`record_too_large` today)
    stops the import with `migration_conflict` and the key; the source stays as it is, and nothing
    is truncated or dropped.
- The audience -> `deliveries` (`acked = 1` at first): the message's `recipients`, else
  `delivery/<id>`, else today's fallback (the current members of the group, or the roster for
  `team`, without the sender). The fallback is evaluated once, at the import; today it is evaluated
  at each read, and a membership change snapshots it first. So it differs only for a legacy `team`
  message whose roster changes after the import. README states it.
- `mailbox/<agent>` -> `acked = 0` for each ID. An ID without a message or without a delivery row
  for the agent stops the import with `migration_conflict` (today it is `internal` at read time).
- `groups` -> `groups`, `group_members` (members in order, then `past_members` not in members,
  `current = 0`).
- `thread-meta/` -> `thread_homes`; `thread-title/`, `thread-open/`, `thread-archive/` (one row per
  ID), `draft/` -> their tables. `set_rev` = the stored `set_rev`, else the record revision. A draft
  record with empty text is a row with empty text and its revision; a missing draft is no row (rev
  `0`), as today.
- `identity-migrated/` -> `aliases_applied`. `gallery/*` -> `gallery`.
- `thread/`, `thread-seg/`: not imported (derived); used in the verification.
- `thread-page/`: not imported. No code reads it today (only the alias migration lists it).

### Verification (before the cutover)

After the source check:

- each thread chain (tail and segments, in order) equals `SELECT id ... WHERE thread = ... ORDER BY
  seq`;
- for each message, the delivery rows equal its audience (recipients, delivery snapshot, or
  fallback);
- for each agent, the unread deliveries equal its mailbox, and every other delivery is acked. So a
  message that was acked stays acked.

A mismatch stops the start with `migration_conflict` and the key; nothing is cut over. Success sets
SQL `import = verified`.

### Cutover

Two commits in two stores, in this order. A crash between them is the state "fence written".

1. **Key-value**: the plugin rewrites the fence record (`sql-import` `{state = 'cutover'}`,
   `if_rev` = its revision). Its new revision is f1. Every value that Messaging gave out before
   (read `next_cursor` = a mailbox or message revision, history `before`/`next_before` = message
   revisions, `draft_revision`, `set_rev`) is a key-value revision that the global counter gave out
   before f1. So every one is below f1.
2. **SQL**, one transaction (G1): `clock.n = f1`; `import = done`; a notice for every agent with an
   unread delivery (queried). This is Messaging's first SQL commit with notices, so the hub moves
   Messaging's notices to SQL here (`notices_moved`, draft 2 section 7).

After step 2 the plugin reads and writes SQL only. The fence record stays.

### Old operation keys

`hub.store.op` cannot list its records, so they are not imported. A lookup that misses in
`operations` falls back to `hub.store.op` (read only, G4), for the identity and its aliases (today's
`prior_operation`), so a retry from before the cutover replays its first result.

### Rollback and backup

- **Rollback to a key-value release after the cutover is not supported.** The key-value records stay
  as they were at the cutover. A release that reads them does not see new messages, and it shows
  acked messages as unread again; its notices are refused (`notices_moved`). A rollback needs an
  explicit recovery decision (an export from SQL back to key-value is not in this plan).
- A rollback during the import (before the cutover) is safe: the key-value records are the source of
  truth, and the next import start detects the change and starts again.
- Backup: draft 2's backup is for a stopped hub (`lazyrex-hub sql backup`): hub.db and the SQL files
  as one set. It keeps the import states, because the fence is in hub.db and the progress is in the
  SQL file. Release gate: a backup of the set right before the cutover release.

## Sizes and costs

- A send's request (each SQL call) holds the body once in the message insert and once in the
  fingerprint of the operation row, the recipient, fixed SQL text and, for `team`, the roster as one
  JSON array. It does not depend on mailbox, group or thread size.
- Row work of a send to a group of n: n delivery rows and n notices (pending is true, no query). For
  n = 100: measured in the size test, not estimated.
- The body limit (16384 encoded bytes) and the page rule (one message fits one read page) stay: they
  bound replies, not storage.

## Tests (proposed)

- The behaviour tests stay and must pass unchanged where they use agent and view actions only
  (send, read, ack, history, threads, members, homes, menus).
- Tests that write key-value records before the plugin starts become import tests (the fixture is
  the old data).
- Tests that inject key-value records during a run test machinery that goes away (chains, `if_rev`
  races). Before any is retired, a coverage map (each test, the behaviour that it proves, the SQL
  test that proves it after) goes to the reviewer.
- New:
  - the live case: a short send to a 9-member group whose members have hundreds of unread messages
    commits; a 100-member group send (sizes and costs measured);
  - a lost reply after the commit replays the result (draft 2 fault point `lost-reply`); an error in
    the last statement leaves nothing;
  - a read whose snapshot is followed by a send: the next read returns it; an oversized row in a
    read, with the byte-sized selection; a selection that does not fit one reply (`more`);
  - notices: an ack that clears and a send that sets, in both orders; pending computed in the
    transaction;
  - alias merges: a message unread under one name only; colliding homes, titles and drafts (and
    the draft conflict); an observed pair; member order;
  - import: each start state of the table, including the orphan fence and a crash on both sides of
    f1; a source change during the import; a chunked large body with a crash between chunks; a
    `record_too_large` source; a verification mismatch; acked messages stay acked; a restart in
    `done` with a stale key-value alias state;
  - `since`, `before` and `draft_revision` values from before the cutover; integers above 2^53;
    two draft saves from one base with no send between them; a repeated and an empty ack write
    nothing.

## Order of commits (proposed)

The order follows the SDK's delivery. The Messaging port needs the `lazyrex` module (the Tunnels
pair builds it) and G1 to G4.

1. The plumbing on the SDK: registration, the action dispatch, `hub.forward`, identity, errors.
   Storage stays on the key-value store in this commit if the SDK allows raw hub calls (G4); else
   commits 1 and 2 are one.
2. The schema, send, read, ack, history, view.seen on SQL, with the tests (fresh database only).
3. Threads, groups, members, homes, titles, drafts, gallery.
4. Identity aliases on SQL.
5. The import: states, fence, source records, chunks, verification, cutover; the operation-key
   fallback.
6. Retire the key-value code paths (chains, mailboxes, M1 scans) and their tests, after the reviewer
   accepts the coverage map.

Commits 2 to 4 run only on a fresh database; commit 5 makes the plugin safe for a store with data.
No release before commit 5, and none before the hub's SQL work is on main.
