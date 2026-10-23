-- The schema: one base step at version 2 (db.migrate {base = 2}). A new database gets the current
-- tables only: no tables of the removed key-value import and no meta.

local alice = agent('alice')

test('a new database is at version 2 with the current tables only', function()
  alice:call('messaging.read', {})
  expect(sql('PRAGMA user_version')[1].user_version).to_be(2)
  local names = {}
  for _, r in ipairs(sql("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")) do names[#names + 1] = r.name end
  expect(names).to_equal({'aliases_applied', 'clock', 'deliveries', 'drafts', 'gallery', 'group_members', 'groups',
    'messages', 'operations', 'thread_archived', 'thread_homes', 'thread_opened', 'thread_titles'})
end)
