-- The schema: one base step at version 2 (db.migrate {base = 2}). A new database gets the current
-- tables only: no tables of the removed key-value import and no meta. The hub and SQLite can add
-- their own tables, so the test checks the plugin's names only.

local alice = agent('alice')

test('a new database is at version 2 with the current tables, without the import tables or meta', function()
  alice:call('messaging.read', {})
  expect(sql('PRAGMA user_version')[1].user_version).to_be(2)
  local have = {}
  for _, r in ipairs(sql("SELECT name FROM sqlite_master WHERE type = 'table'")) do have[r.name] = true end
  for _, name in ipairs({'aliases_applied', 'clock', 'deliveries', 'drafts', 'gallery', 'group_members', 'groups',
      'messages', 'operations', 'thread_archived', 'thread_homes', 'thread_opened', 'thread_titles'}) do
    expect(have[name], name).to_be(true)
  end
  for _, name in ipairs({'meta', 'import_source', 'import_ops', 'import_body'}) do
    expect(have[name], name .. ' is absent').to_be(nil)
  end
end)
