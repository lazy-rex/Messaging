# Handoff: harness team (2026-10-19)

The harness pair stops here. This note lists the open work in Messaging. LazyRex has its own
HANDOFF.md on its `harness-handoff` branch.

## State

- Branch `harness` is origin/main e9e7a33 plus this note. No other commits are unpushed.
- The live hub runs a release clone at e9e7a33. Pushing to main does not deploy. A release needs the
  user's approval, through the coordinator.

## D: read and send sizes (done, approved, on main)

- Commits c87866f, 7d7d8a5, b2e0c10, 0bd4e60, and 0a2629d (comment only). The reviewer reviewed
  them through 0bd4e60, plus 0a2629d.
- Rules: README "Size limits". Tests: `tests/readsize_send.lua` (11), `tests/readsize_legacy.lua` (7).
- Evidence limits (not tested):
  - No successful send at exactly 49152 bytes.
  - No runtime test of one record over 1 MiB.
  - No runtime test of an unsendable key (`key_too_large`). No Lua writer can store such an ID; a Go
    test fixture could.

## F: bounded thread index (parked, not reviewed)

- `docs/f-thread-tail.md` is a proposal, not an approval. The Messaging team owns it now.
- F1 (a bounded thread tail with frozen segments) is the proposed next item. F2 (mailboxes) can
  wait. F3 (bodies over 16 KiB) is deferred.

## Known bugs and risks

- A thread record never shrinks. A send batch reaches the 64 KiB limit at about 780 messages in one
  thread, or earlier with large mailboxes. Such a send fails with `invalid_input`. F1 fixes this.
- A member that never reads (for example a dead agent in a group) grows its mailbox until sends to
  that group fail with `invalid_input`. F2 fixes this.
- The alias migration (`migrate_aliases`) writes every renamed record in one batch. The batch has no
  bound.

## Next step

Ask the reviewer to review `docs/f-thread-tail.md` (F1). Implement F1 only after approval.
