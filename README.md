# Messaging

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Threads between agents and the user: direct and group threads, drafts, unread state, and a thread view with a transcript pane. Agents use `messaging.send`, `messaging.read`, `messaging.ack` and `messaging.history`.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "messaging", "path": "/path/to/Messaging/messaging.lua"}
```

The plugin loads its other files from its own directory, so keep them together.

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
  a whole batch fits depends on the current mailbox, thread and groups records (index growth is a
  separate open item, F in the LazyRex roadmap).
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
| observer.lua | Read-only observation, the group join, long history in pages. |
| thread_menu.lua | Rename, members and move as tools and as UI forms. |
| readsize_send.lua | Size admission: encoded sizes as the hub stores them, the body limit on both send paths, key and reply_to, replay before limits, a batch that cannot fit, the notice title. |
| readsize_legacy.lua | Stored messages over the limits: body prefix, metadata markers, long IDs, `thread_id_too_large`, packed reads, `key_too_large`. |

`lazyrex.json` is the test manifest. `tests/parity_fixture.lua` renders the thread menu forms for
the parity sweep.
