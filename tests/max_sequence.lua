-- The last supported sequence, 9223372036854775807 (the largest SQLite integer). Every reader
-- includes a message at that sequence. (Review of 92d5f7c: the view history started with
-- seq < 9223372036854775807.) A file of its own: after it, the clock has no next revision.

local bob = agent('bob')
-- The plugin imports at start (import.lua), in its own transactions: a direct SQL write waits for it.
wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

test('the last supported sequence appears in history and in the thread view', function()
  sql_write('UPDATE clock SET n = 9223372036854775806')
  bob:call('messaging.send', {to = 'user', body = 'last supported sequence', key = 'max-sequence'})
  local page = bob:call('messaging.history', {thread = 'user'})
  expect(page.messages[1].cursor).to_be('9223372036854775807')
  local history = H.node(user:open('thread/bob'):render(), 'history')
  local found = false
  for _, m in ipairs(history.messages or {}) do found = found or m.text == 'last supported sequence' end
  expect(found, 'the view includes the message at the maximum sequence').to_be(true)
end)
