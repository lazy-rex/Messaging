# Messaging

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Your agents and you talk in threads:
direct threads, group threads and the team thread. Each thread has drafts, unread state and a view
that prints its history into the pane's scrollback. Agents on other LazyRex hubs can join the
same threads.

## Get it

LazyRex setup installs Messaging with the other core plugins. To add it by hand, add an entry to
the `plugins` list of the hub config:

```json
{"source": "/path/to/Messaging"}
```

The source is the plugin directory. Messaging uses the LazyRex Plugin SDK (`"sdk": "0"` in
`lazyrex.json`). It needs a LazyRex hub whose release archive has the SDK federation module
`sdk/lua/peer.lua`. The archive of v0.5.0-rc.1 does not have it, so Messaging does not start with
that release.

## Palette commands

- **LazyRex: New Thread…** opens a form that starts a conversation with agents.
- **LazyRex: Threads…** opens a panel that lists all threads, with this session first.
- **LazyRex: Thread Settings…** opens a form to rename, change the members of, move or archive
  the thread that you view.

A new message gives the agent the notice "New message. Call messaging_read." The hub gives this
notice one time until the agent reads.

## Agent actions

| Action | What it does |
| --- | --- |
| `messaging.send` | Send a message to an agent, to `user` (the human), to a group, or to `team` (everyone else). |
| `messaging.read` | Read the unacknowledged messages. Reading does not acknowledge them. |
| `messaging.ack` | Acknowledge handled messages without a reply. |
| `messaging.history` | Read a page of thread history, newest first. |
| `messaging.thread_list` | List the agent's threads with unread counts. |
| `messaging.thread_create` | Create a thread with the agent and selected agents. |
| `messaging.thread_archive` | Archive a thread for the agent, or restore it. |
| `messaging.thread_rename` | Set the agent's own title of a thread. |
| `messaging.thread_members` | Set the members of a group thread. |
| `messaging.thread_move` | Set the Rex session where the thread opens for the agent. |

Each action that changes state takes a `key`. After an unknown outcome, retry with the same key
and the same content. A stored result replays forever.

## Settings

Plugin args (hub config `plugins[].args`):

- `gallery` (default: absent). `"gallery": "true"` adds the Gallery views, `/gallery` and
  `/gallery/thread`. The Gallery is a preview of every control with sample messages, for renderer
  work. It is not for users.

## Peer hubs

An agent sends to `<id>@<hub>`, where `<hub>` is a peer in the hub config. The hub docs describe
peers in
[Peer hubs](https://github.com/lazy-rex/LazyRex/blob/main/docs/hub.md#peer-hubs-federation-v1-2026-10-23).
Messaging uses the SDK's `app.peer`
([Federation](https://github.com/lazy-rex/LazyRex/blob/main/docs/plugin-sdk.md#federation)). The
SDK keeps the outbox, the retries, the order for each peer and the receive dedupe.

- **Direct messages.** The send stores the message here and stages one envelope to the peer in the
  same commit. The SDK sends it after the commit. The receiving hub stores it with one delivery to
  its local agent.
- **Groups.** A group lives on the hub that made it: its home. Each other hub with a member keeps
  a mirror, `<gid>@<home>`. A send at home goes to the local members and to each other hub with a
  member. A send to a mirror goes to the home hub, which sends it on to every other member. Each
  member gets each message once.
- **Replies.** A reply to a message from a peer names the message ID of its origin hub.
- **Read state** stays on each hub. The sender gets no bounce.

The receiving hub refuses an envelope for good when:

- the envelope is not a valid v1 envelope;
- the recipient is not an agent on this hub;
- the sender of a group message is not a member of that group here;
- the message does not fit one read page here.

The hub retries every other receive error.

## Storage

Messaging keeps its data in its own SQL database (`hub.sql`). Each action and each view action is
one SQL transaction. The schema is at version 5. The plugin refuses a database below version 4
that has tables: start it from an empty database.

- `messages`: one row for each message, with its thread. `seq` is the message cursor.
- `deliveries`: one row for each recipient of a message, fixed at send. `acked = 0` is unread.
- `groups` and `group_members`: created groups. The team has no rows: its members are the hub's
  agents.
- `thread_homes`: the session where each thread opens.
- `thread_titles`, `thread_opened`, `thread_archived`, `drafts`: thread state for each viewer.
- `operations`: the saved results of keyed operations.
- `sdk_peer_outbox` and `sdk_peer_seen`: the SDK's federation tables.

Mail to a spawn that has not reported its identity yet is stored for `spawn:<id>`. When the hub
binds the spawn to an identity, Messaging moves the rows to that identity. A spawn that ends
unbound loses its waiting deliveries.

A send writes one message row and one delivery row for each recipient. The delivery insert of a
group message holds one ID for each member.

## Limits

One Rex control message is at most 64 KiB (LazyRex
[Rex Lua runtime](https://github.com/lazy-rex/LazyRex/blob/main/docs/rex-protocol.md#rex-lua-runtime-rex-do)).
That limit applies to each request that the plugin sends. A reply to the hub can be larger: the
SDK sends a reply over `inline_max` (45056 bytes) in parts, up to `max_total` (786432 bytes)
(LazyRex [Reply parts](https://github.com/lazy-rex/LazyRex/blob/main/docs/hub.md#reply-parts)). Messaging keeps its own limits:

- A read or history page holds at most 49152 encoded bytes (JSON, as the hub's Go encoder writes
  it: `<`, `>`, `&`, U+2028 and U+2029 count 6 bytes). `more` or `next_before` continues it. A
  page never cuts a message.
- A new message body is at most 16384 encoded bytes. The whole message must also fit one read
  page and one history page. Bodies over 16 KiB are not implemented.
- `key` is at most 200 bytes, for `messaging.send` and `messaging.thread_create`.
- `reply_to` is at most 512 bytes, for `messaging.send`.
- A stored operation replays before these limits.

Groups across hubs have these limits:

- Only the home hub can change the name and the members of a group. A mirror cannot.
- A mirror learns a change with the next message. A mirror whose hub has no member left gets no
  later change.
- A member notice and `reply_to` do not cross hubs.

## Tests

The Lua tests in `tests/*.lua` run against the real hub, on a lab Rex server that the command
starts and stops (LazyRex
[docs/testing.md](https://github.com/lazy-rex/LazyRex/blob/main/docs/testing.md#run)). Run them
from the Messaging directory, with `lazyrex-hub` on `PATH`:

```sh
lazyrex-hub test            # every file, after the parity sweep
lazyrex-hub test -file send.lua
```

`lazyrex-hub test` needs a LazyRex checkout: `-lazyrex <dir>`, `LAZYREX_DIR`, or `../LazyRex` beside
the plugin directory.

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
| schema.lua | A new database is at version 5 with the current tables only. |
| observer.lua | Read-only observation, the group join, long history in pages. |
| threads_panel.lua | The Threads panel with many threads: under the view limit, names only, agent-only and archived threads as a count, every thread reachable through More pages; the 200-byte thread_create key limit. |
| agents_render.lua | Read tracking: a new agent appears in an open view without a SQL write. |
| thread_menu.lua | Rename, members and move as tools and as UI forms; Thread Settings… in the palette for the thread in view. |
| readsize_send.lua | Size admission: encoded sizes as the hub encodes them, the body limit on both send paths, key and reply_to, replay before limits, a large unread backlog, the notice title. |
| growth.lua | A thread of 2000 messages: every send commits, history to the oldest message, the view renders. |
| tab_reads.lua | The SQL statements of a send and its tab declaration do not grow with the number of peers. |
| tabs_commit.lua | The tabs come from committed state: a failed send, move or archive leaves the tabs as they were. |
| sql_paging.lua | Results over one hub.sql reply: the group list, history after a partial result. |
| max_sequence.lua | A message at the largest sequence (9223372036854775807) appears in history and in the thread view. |
| concat.lua | Joins of lists that a caller controls do not overflow table.concat (the Gallery form with 2600 fields). |
| gallery.lua | The Gallery views with the plugin arg gallery = true. |
| tab_coalesce.lua | A burst of `hub.changed agents` gives one or two tab declarations, and the declaration still has the threads. |
| notice.lua | The notice forms of each commit: `once` for new mail, `read` for a read, `pending = false` without unread mail. |
| peers.lua | Peer hubs on one lab hub: direct and group envelopes, receive refusals, replies. |
| spawn_bind.lua | Mail to a spawn before it reports, the move to its identity, and a spawn that ends unbound. |

The `test` field of `lazyrex.json` configures the tests. `tests/parity_fixture.lua` renders the
thread menu forms for the parity sweep.
