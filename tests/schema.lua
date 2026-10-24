-- The schema: one base step at version 4 (db.migrate {base = 4}). A new database gets the current
-- tables only: no tables of the removed key-value import, no meta and no
-- aliases_applied. The hub and SQLite can add their own tables, so the test checks the plugin's
-- names only.

local alice = agent('alice')

test('a new database is at version 4 with the current tables, without the import tables, meta or aliases_applied', function()
  alice:call('messaging.read', {})
  expect(sql('PRAGMA user_version')[1].user_version).to_be(4)
  local have = {}
  for _, r in ipairs(sql("SELECT name FROM sqlite_master WHERE type = 'table'")) do have[r.name] = true end
  for _, name in ipairs({'clock', 'deliveries', 'drafts', 'gallery', 'group_members', 'groups',
      'messages', 'operations', 'peer_outbox', 'spawns_ended', 'thread_archived', 'thread_homes', 'thread_opened', 'thread_titles'}) do
    expect(have[name], name).to_be(true)
  end
  for _, name in ipairs({'aliases_applied', 'meta', 'import_source', 'import_ops', 'import_body'}) do
    expect(have[name], name .. ' is absent').to_be(nil)
  end
end)
