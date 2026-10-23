# Messaging

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Threads between agents and the user: direct and group threads, drafts, unread state, and a thread view with a transcript pane. Agents use `messaging.send`, `messaging.read`, `messaging.ack` and `messaging.history`.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "messaging", "path": "/path/to/Messaging/messaging.lua"}
```

The plugin loads its other files from its own directory, so keep them together.

Messaging runs on the LazyRex Plugin SDK v0. Its `lazyrex.json` has `"sdk": "0"`, so the hub starts it through the SDK launcher (`sdk/lua/boot.lua`). A hub without the launcher cannot start it. Messaging keeps its data in the plugin's SQL database (`hub.sql`), so it also needs a hub with `hub.sql`. It reads a result of any size with `db.each`, and a render only reads, so it needs SDK commit eb9654d or later. It gives notice v2 forms (`once` and `read`), so it needs SDK commit 7e59a2a or later and a hub with notice v2 in `hub.sql.commit`.

Plugin args (hub config `plugins[].args`):

- `gallery` (default: absent): `"gallery": "true"` declares the Gallery tab and serves its view (`/gallery`). Without it, the route is unknown. The hub config holds arg values as strings; Rex gives the plugin the boolean `true` (observed in a lab check, 2026-10-21). The Gallery is a live preview of every control, with sample messages. It is for renderer work, not for users.

## Storage

Each action and each view action is one SQL transaction (`app.db`). The schema is migration 1 in
`messaging.lua`. The main tables:

- `messages`: one row for each message, with its thread (`thread_a`, `thread_b`). A direct thread is
  the sorted pair of its agents; a group thread is (`''`, group ID). `seq` comes from `clock`, and
  it is the message cursor.
- `deliveries`: one row for each recipient of a message, fixed at send. `acked = 0` is unread.
- `groups` and `group_members`: created groups. The team has no rows: its members are the roster.
- `thread_homes`, `thread_titles`, `thread_opened`, `thread_archived`, `drafts`: thread state for
  each viewer.
- `operations`: saved results of keyed operations. An agent key replays forever.
- `aliases_applied`: identity merges already done.

A send writes one message row and one delivery row for each recipient. No request depends on the
size of a mailbox, a thread or a group. The hub admits one notice for each agent in a commit.
New mail gives a pending notice with `once`: the hub nudges the agent one time until it reads.
`messaging.read` records the read (`read`), or gives `pending = false` when no mail is unread.

## Storage

Messaging keeps all its data in SQL. Releases before v0.2 kept it in the hub's key-value store; the
v0.2 releases imported it once. That import code is removed: a store must have run a v0.2 release
before this one. The import tables (`import_source`, `import_ops`, `import_body`) and `meta` stay
until a later numbered step drops them.

## Size limits

What a Lua plugin sends is at most 64 KiB in one control message (LazyRex docs/rex-protocol.md,
"Rex Lua runtime"). A plugin reply that is too large never arrives: the caller sees a timeout.
The plugin keeps every reply and request inside that limit:

- **Read and history pages** hold at most 49152 encoded bytes (JSON, counted as the hub's Go
  encoder writes it: `<`, `>`, `&`, U+2028 and U+2029 count 6 bytes). A page is measured with the
  largest cursor values, so the final page is not larger. `more` or `next_before` continues it.
  The remaining 16 KiB is for the reply frame (measured: the frame around a request is 73 bytes).
- **New messages** (agent send, view send, membership notice): the body is at most 16384 encoded
  bytes. A send carries the body in two SQL requests (the message insert and the operation
  fingerprint). `key` is at most 200 bytes and `reply_to` at most 512 bytes (raw). The whole
  message must also fit one read page and one history page. A stored operation replays before
  these limits.
- Every stored message fits these limits too (checked on the live store, 2026-10-22). A read or
  history page never cuts a message.
- Open (deferred, F): bodies over 16 KiB would need a digest of the body in the fingerprint, from a
  hub digest action, not a Lua hash.

## Tests

The Lua tests in `tests/*.lua` run against the real hub, on a lab Rex server that the command
starts and stops (docs/testing.md in LazyRex). Build the hub in `../LazyRex/hub`, then run:

```sh
lazyrex-hub test            # every file, after the parity sweep
lazyrex-hub test -file send.lua
```

| File | What it covers |
| --- | --- |
| contract.lua | Exports on the agent face; only the hub forwards or calls `view.*`. |
| send.lua | Send, read, ack, replies, replays, commit faults (a failed commit, a lost reply), large cursors. |
| threads.lua | Tabs, thread creation, FYI, unread status, cursors, archive and restore. |
| members.lua | Membership changes, delivery snapshots, history pages, direct expansion. |
| homes.lua | Thread homes, reopen tokens, panel order, redirects, sessions, moves. |
| home_views.lua | The open view of a homed thread: focus, a user close, a closed tab across a hub restart, reopens by a message and by Threads…, the draft across a menu form. |
| thread_forms.lua | The New Thread form, the thread menu overview, renames (the form and a Rex tab rename), short identity names. |
| identity_mail.lua | Mail between identities: a send and its replay, /clear and resume, a hub crash. |
| observer.lua | Read-only observation, the group join, long history in pages. |
| threads_panel.lua | The Threads panel at three times the live thread count: under the view limit, names only, agent-only and archived threads as a count, every thread reachable through More pages. |
| agents_render.lua | Read tracking: a new agent appears in an open view without a SQL write (the hub renders again on hub.changed agents). |
| thread_menu.lua | Rename, members and move as tools and as UI forms. |
| readsize_send.lua | Size admission: encoded sizes as the hub stores them, the body limit on both send paths, key and reply_to, replay before limits, a large unread backlog, the notice title. |
| growth.lua | A thread of 2000 messages: every send commits, history to the oldest message, the view renders. |
| tab_reads.lua | The SQL statements of a send and its tab declaration do not grow with the number of peers (needs hub.test.calls). |
| tabs_commit.lua | The tabs come from committed state: a failed send, move or archive leaves the tabs as they were. |
| sql_paging.lua | Results over one hub.sql reply: the group list, history after a partial result. |
| max_sequence.lua | A message at the largest sequence (9223372036854775807) appears in history and in the thread view. |
| concat.lua | Joins of lists that a caller controls do not overflow table.concat (the Gallery form with 2600 fields; lazyrex.json test.files sets gallery = true). |
| gallery.lua | The Gallery view with the plugin arg gallery = true (lazyrex.json test.files): render, actions, draft and send. |
| tab_coalesce.lua | A burst of `hub.changed agents` gives one or two tab declarations, and the declaration still has the threads (needs hub.test.calls). |
| notice.lua | The notice forms of each commit (notice v2): `once` for new mail, `read` for a read, `pending = false` without unread mail (needs hub.test.calls). |

`lazyrex.json` is the test manifest. `tests/parity_fixture.lua` renders the thread menu forms for
the parity sweep.
