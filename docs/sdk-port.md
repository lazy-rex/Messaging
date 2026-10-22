# Messaging: port to the Plugin SDK (proposed)

Status: proposed, 2026-10-22. The storage design is in docs/sql-storage.md (revision 3). This page
says which code goes, which stays, and which tests must stay green. Line numbers are of
`messaging.lua` at b555e6d (2518 lines). The counts after the port are estimates, not measurements.

SDK: LazyRex `docs/plugin-sdk.md` and `docs/sql.md` on branch `hub/sql-contract` (a2a0ece). The gaps
G1-G7 went to the hub lead and claude-22 on 2026-10-22 ("SDK gaps: Messaging" thread). Until the SDK
covers G4-G7, Messaging uses the raw escape (`app.hub`, raw dispatch; coordinator, 2026-10-22).

## What the SDK replaces

| Code today | Lines | After the port |
| --- | --- | --- |
| `fail`, `hub_error`, `hub()` with request measuring | 1-51 | SDK errors and `app.hub` (G4). |
| `get`, `lookup`, `message_records`, request budgets | 381-466 | Gone: SQL queries. |
| `mailbox`, `stored_groups`, `group`, `addressed`, `recipients` (record forms) | 412-534 | Short queries on `deliveries`, `groups`, `group_members`. |
| Thread chains (F1): `thread`, `with_chain`, `chain_reader`, `chain_ids`, `prepare_tail`, freeze steps | 558-708 | Gone: thread order is `seq`. |
| Key-value alias migration: `canonical_key`, `migrate_aliases`, `migration_records`, `migrate_chain` | 106-117, 150-276, 710-842 | One SQL alias merge (docs/sql-storage.md "Identity aliases"). |
| `if_rev` retry loops (`for _ = 1, attempts`) in send, ack, create, members, archive, move, rename, draft, gallery, open marks | in each action | Gone: one handler transaction. |
| `notify` ops in batches | in each action | `app.notice`, pending queried in the transaction. |
| `tab_records`, `peers` scans | 1258-1319 | Queries. |
| `identify`, `hub.forward` handling, the dispatcher, `client.keymap`, `hub.register`, `set_label` | 844-854, 2387-2518 | SDK registration and dispatch (G6, G7; raw dispatch until then). |

## What stays

- Page fitting and markers: `encoded_size`, `utf8_cut`, `admit`, `shrink`, `fit_page`, `checked`
  (the agent reply is still 48 KiB).
- Fingerprints and operation keys: `normalized_fingerprint`, `prior_operation` (on the
  `operations` table), `saved_result`.
- Identity rules: `part`, `observed_direct_id`, `observed_direct_parts`, `canonical_thread_id`,
  `resolve_recipient`, `display_name`.
- The UI: `render_home`, `render_thread`, `history_page`, forms, menus, `view_*` handlers,
  `declare_tabs`. They read queries instead of records. Through raw dispatch until G5.
- The gallery, behind `gallery = "true"` (`app.args`), as one `app.view` route (coordinator,
  2026-10-22: the user keeps it and wants it tested).

## Data

The move of the key-value data to SQL tables is docs/sql-storage.md: the schema, the one-time
import with a source fence, verification and cutover. After the cutover, Messaging never writes its
key-value families again.

## Size estimate

About 2518 lines today. Removed: about 1000 (plumbing, chains, the key-value alias migration, the
retry loops, the dispatcher). Added: about 400 (the schema, queries, the SQL alias merge, the
import). Estimate after: 1500 to 1900 lines, and less when the SDK covers G5 (views). The real count
goes into the port report.

## Tests

Must stay green, unchanged where they use only agent and view actions: `contract`, `send`,
`threads`, `members`, `homes`, `home_views`, `identity_mail`, `observer`, `thread_menu`,
`readsize_send`.

Change form (they write key-value records): `migration`, `migration_order` (aliases through
records), `readsize_legacy` (oversized stored messages), `members` and `send` cases that inject
records. They become import tests or SQL fixtures.

Test removed machinery (chains, `if_rev` races, M1 scans): `chain_freeze`, `chain_readers`,
`chain_growth`, `chain_migration`, `chain_migration_decimal`, `chain_migration_limits`,
`migration_scan`, `tab_reads`. Before any is deleted, the reviewer gets a coverage map: each test,
the behaviour that it proves, and the SQL test that proves it after.

New tests: docs/sql-storage.md "Tests".

## Order

docs/sql-storage.md "Order of commits". The first commit starts when claude-22's first `sdk/lua`
commit runs against the fake hub.sql (coordinator, 2026-10-22).
