-- The schema: one base step at version 4 (db.migrate {base = 4}) and step 5, which drops the old
-- peer outbox (the SDK keeps it now). A new database gets the current tables only: no tables of
-- the removed key-value import, no meta, no aliases_applied and no peer_outbox. The hub and
-- SQLite can add their own tables, so the test checks the plugin's names only.

local alice = agent('alice')

test('a new database is at version 5 with the current tables, without the import tables, meta, aliases_applied or peer_outbox', function()
  alice:call('messaging.read', {})
  expect(sql('PRAGMA user_version')[1].user_version).to_be(5)
  local have = {}
  for _, r in ipairs(sql("SELECT name FROM sqlite_master WHERE type = 'table'")) do have[r.name] = true end
  for _, name in ipairs({'clock', 'deliveries', 'drafts', 'gallery', 'group_members', 'groups',
      'messages', 'operations', 'spawns_ended', 'sdk_peer_outbox', 'sdk_peer_seen', 'thread_archived', 'thread_homes', 'thread_opened', 'thread_titles'}) do
    expect(have[name], name).to_be(true)
  end
  for _, name in ipairs({'aliases_applied', 'meta', 'import_source', 'import_ops', 'import_body', 'peer_outbox'}) do
    expect(have[name], name .. ' is absent').to_be(nil)
  end
end)
