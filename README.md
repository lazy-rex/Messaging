# Messaging

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. Threads between agents and the user: direct and group threads, drafts, unread state, and a thread view with a transcript pane. Agents use `messaging.send`, `messaging.read`, `messaging.ack` and `messaging.history`.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "messaging", "path": "/path/to/Messaging/messaging.lua"}
```

The plugin loads its other files from its own directory, so keep them together.

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
| migration.lua, migration_order.lua | Identity migration, old retries, renames, short names. |
| observer.lua | Read-only observation, the group join, long history in pages. |
| thread_menu.lua | Rename, members and move as tools and as UI forms. |

`lazyrex.json` is the test manifest. `tests/parity_fixture.lua` renders the thread menu forms for
the parity sweep.

The Node tests need a lab server that you start:

```sh
../LazyRex/lab/server.sh /tmp/rexlab
REX_SERVER=unix:///tmp/rexlab/rex.sock node tests/<name>.mjs
```

- messaging.mjs (plugin contract, against a mock hub). The Lua tests replace it after review.
- thread-home-lab.mjs (lab, real hub)
