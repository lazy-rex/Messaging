# Messaging

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Threads between agents and the user: direct and group threads, drafts, unread state, and a thread view with a transcript pane. Agents use `messaging.send`, `messaging.read`, `messaging.ack` and `messaging.history`.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "messaging", "path": "/path/to/Messaging/messaging.lua"}
```

The plugin loads its other files from its own directory, so keep them together.

Plugin args (hub config `plugins[].args`):

- `gallery` (boolean, default false): declare the Gallery tab. The Gallery is a live preview of every control, with sample messages. It is for renderer work, not for users.

## Size limits

What a Lua plugin sends is at most 64 KiB in one control message (LazyRex docs/rex-protocol.md,
"Rex Lua runtime"). A plugin reply that is too large never arrives: the caller sees a timeout.
The plugin keeps every reply and request inside that limit:

- **Read and history pages** hold at most 49152 encoded bytes (JSON, counted as the hub's Go
  encoder writes it: `<`, `>`, `&`, U+2028 and U+2029 count 6 bytes). A page is measured with the
  largest cursor values, so the final page is not larger. `more` or `next_before` continues it.
  The remaining 16 KiB is for the reply frame (measured: the frame around a request is 73 bytes).
- **New messages** (agent send, view send, membership notice): the body is at most 16384 encoded
  bytes. A send's `hub.store.batch` carries the body twice (the message record and the operation
  fingerprint), and the rest of the request holds the mailbox, thread and groups records. `key` is
  at most 200 bytes and `reply_to` at most 512 bytes (raw). The whole message must also fit one
  read page and one history page. A stored operation replays before these limits.
- **Every hub request** is measured before it is sent (64 KiB minus 1 KiB). One that can never fit
  is `invalid_input` with its size, and nothing of it is committed. The body limit is fixed; whether
  a whole batch fits depends on the current mailbox, thread and groups records (mailbox growth is a
  separate open item, F2 in docs/f-thread-tail.md).
- **Thread chains (F1, docs/f-thread-tail.md).** The thread record `thread/<pair>` is the tail:
  the newest IDs, at most 8192 encoded bytes as a packing target. Before an append, freeze steps
  move the oldest IDs into segments `thread-seg/<pair>/<chain>/<k>`, written once. Readers walk
  the tail and the segments; a missing segment restarts the whole read. The alias migration
  writes a new chain. A thread of 2000 messages with IDs of about 85 bytes is tested.
- **Reads from the hub** take at most 8 keys and, as a target, 49152 encoded bytes of keys in one
  request; a larger key goes alone. A batch whose reply is over the hub's limit (`reply_too_large`)
  is read one key at a time. One record over the hub limit is `record_too_large`; a key whose own
  request does not fit (64 KiB minus 1 KiB) is `key_too_large`.
- **Stored messages from before these limits**: a body that does not fit a page arrives as a UTF-8
  safe prefix with `truncated` and `body_bytes`. Metadata that does not fit gives a marker
  `{cursor, id, metadata_too_large, bytes}`, or `id_prefix` and `id_bytes` when the ID does not fit
  either; such a message cannot be acknowledged. History of a thread whose ID leaves no room for the
  smallest marker fails with `thread_id_too_large`.
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
| send.lua | Send, read, ack, replies, replays, and injected mailbox races. |
| threads.lua | Tabs, thread creation, FYI, unread status, cursors, archive and restore. |
| members.lua | Membership changes, delivery snapshots, history pages, direct expansion. |
| homes.lua | Thread homes, reopen tokens, panel order, redirects, sessions, moves. |
| home_views.lua | The open view of a homed thread: focus, a user close, a closed tab across a hub restart, reopens by a message and by Threads…, the draft across a menu form. |
| migration.lua, migration_order.lua | Identity migration, old retries, renames, short names. |
| identity_mail.lua | Mail across identity reports: migration with the same cursor, an identity that never joined, /clear and resume, a hub crash. |
| observer.lua | Read-only observation, the group join, long history in pages. |
| thread_menu.lua | Rename, members and move as tools and as UI forms. |
| readsize_send.lua | Size admission: encoded sizes as the hub stores them, the body limit on both send paths, key and reply_to, replay before limits, a batch that cannot fit, the notice title. |
| readsize_legacy.lua | Stored messages over the limits: body prefix, metadata markers, long IDs, `thread_id_too_large`, packed reads, `key_too_large`. |
| chain_readers.lua | F1 readers: history and view history across segments, the menu count, the tab revision, writers keep the chain fields, backfills from segments, a missing segment. |
| chain_freeze.lua | F1 writers: the freeze boundary (also with escaped IDs), an interrupted freeze, legacy tails in steps, oversized IDs, races with appends, backfills and view sends. |
| chain_migration.lua, chain_migration_limits.lua, chain_migration_decimal.lua | F1 alias migration: merged chains, a second migration, a conflict, a torn scan, a batch over the limit, chain numbers above 2^53. |
| chain_growth.lua | F1 growth: 2000 messages, every send commits, history to the oldest message. |

`lazyrex.json` is the test manifest. `tests/parity_fixture.lua` renders the thread menu forms for
the parity sweep.
