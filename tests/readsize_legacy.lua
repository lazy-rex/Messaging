-- Stored messages from before size admission (written here as SQL fixtures; the import from the
-- key-value store brings such messages) must still read: a page never exceeds 49152 encoded
-- bytes, never skips a message, and always makes progress.

-- Every call fails with unavailable until the import at start is done (import.lua). Under load,
-- the start can end before it; the tests begin after it.
wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')
local budget = 49152
local at = '2026-10-19T00:00:00Z'

local function within(page)
  local n = #rex.json.encode(page)
  expect(n <= budget, 'page size ' .. n).to_be(true)
  return page
end

-- write_sql runs sql_write; while the plugin holds a transaction, it waits.
local function write_sql(q, p)
  local out = wait('a SQL fixture write', function()
    local ok, r = pcall(sql_write, q, p)
    if ok then return {r} end
    local text = type(r) == 'table' and tostring(r.code) .. ': ' .. tostring(r.message) or tostring(r)
    if not text:find('busy', 1, true) then return {nil, r} end -- another error: no retry
  end)
  if out[2] ~= nil then error(out[2], 0) end
  return out[1]
end

-- deliver writes a legacy message in thread {a, b} and an unread delivery for the reader. It
-- returns the message cursor.
local function deliver(m, reader, thread)
  write_sql('UPDATE clock SET n = n + 1')
  write_sql([[INSERT INTO messages (seq, id, sender, recipient, thread_a, thread_b, body, at)
    VALUES ((SELECT n FROM clock), ?, ?, ?, ?, ?, ?, ?)]], {m.id, m.from, m.to, thread[1], thread[2], m.body, m.at})
  if m.reply_to then write_sql('UPDATE messages SET reply_to = ? WHERE id = ?', {m.reply_to, m.id}) end
  write_sql('INSERT INTO deliveries (agent, seq, acked) VALUES (?, (SELECT n FROM clock), 0)', {reader})
  return sql('SELECT CAST(n AS TEXT) AS n FROM clock')[1].n
end

local direct = {'alice', 'bob'}

test('a body larger than one page arrives as a UTF-8-safe prefix, in read and in history', function()
  local body = string.rep('\195\169', 30000) -- 60000 bytes, 2 bytes a character
  local m = {id = 'legacy/big-body', from = 'alice', to = 'bob', recipients = {'bob'}, body = body, at = at}
  local rev = deliver(m, 'bob', direct)
  for _, page in ipairs({within(bob:call('messaging.read', {})), within(bob:call('messaging.history', {thread = 'alice', limit = 1}))}) do
    local item = page.messages[1]
    expect(item.id).to_be(m.id)
    expect(item.cursor).to_be(rev)
    expect(item.truncated).to_be(true)
    expect(item.body_bytes).to_be(60000)
    expect(#item.body > 40000 and #item.body % 2 == 0, 'a long prefix of whole characters').to_be(true)
    expect(body:sub(1, #item.body) == item.body).to_be(true)
  end
  bob:call('messaging.ack', {ids = {m.id}})
end)

test('metadata larger than one page: a marker with the full ID, and the cursor moves on', function()
  local m = {id = 'legacy/big-meta', from = 'alice', to = 'bob', recipients = {'bob'}, body = 'x', reply_to = string.rep('r', 50000), at = at}
  local rev = deliver(m, 'bob', direct)
  local after = {id = 'legacy/after-meta', from = 'alice', to = 'bob', recipients = {'bob'}, body = 'next', at = at}
  deliver(after, 'bob', direct)
  local page = within(bob:call('messaging.read', {}))
  local item = page.messages[1]
  expect(item).to_equal({cursor = rev, id = m.id, metadata_too_large = true, bytes = item.bytes})
  expect(item.bytes > 50000).to_be(true)
  expect(page.more, 'the page stops after the marker').to_be(true)
  local rest = within(bob:call('messaging.read', {since = page.next_cursor}))
  expect(rest.messages[1].id, 'read makes progress').to_be(after.id)
  -- History, newest first: the marker does not fit beside the newer message, so it is the next page.
  local h = within(bob:call('messaging.history', {thread = 'alice', limit = 2}))
  expect(#h.messages).to_be(1)
  expect(h.messages[1].id).to_be(after.id)
  expect(h.next_before).to_be(h.messages[1].cursor)
  local older = within(bob:call('messaging.history', {thread = 'alice', limit = 2, before = h.next_before}))
  expect(older.messages[1]).to_equal({cursor = rev, id = m.id, metadata_too_large = true, bytes = item.bytes})
  bob:call('messaging.ack', {ids = {m.id, after.id}})
end)

-- A legacy group whose ID leaves room only for small items in a history page.
local function legacy_group(id, members)
  write_sql('INSERT INTO groups (gid, name) VALUES (?, ?)', {id, 'Legacy group'})
  for pos, m in ipairs(members) do
    write_sql('INSERT INTO group_members (gid, agent, pos, current) VALUES (?, ?, ?, 1)', {id, m, pos})
  end
end

test('a long thread ID and a long message ID: history returns id_prefix and id_bytes', function()
  local gid = 'g-' .. string.rep('t', 28000)
  legacy_group(gid, {'alice', 'charlie'})
  local mid = 'legacy/' .. string.rep('m', 22000)
  local m = {id = mid, from = 'alice', to = 'charlie', recipients = {'charlie'}, body = 'hello', at = at}
  local rev = deliver(m, 'charlie', {'', gid})
  local h = within(charlie:call('messaging.history', {thread = gid}))
  expect(h.thread == gid).to_be(true)
  local item = h.messages[1]
  expect(item.cursor).to_be(rev)
  expect(item.metadata_too_large).to_be(true)
  expect(item.id).to_be(nil)
  expect(item.id_bytes).to_be(#mid)
  expect(#item.id_prefix <= 256 and mid:sub(1, #item.id_prefix) == item.id_prefix).to_be(true)
end)

test('a thread ID that fits an empty page but not the smallest marker: thread_id_too_large', function()
  local empty = #rex.json.encode({thread = 'g-', messages = {}, next_before = string.rep('9', 20)})
  local marker = #rex.json.encode({thread = 'g-', messages = {{cursor = string.rep('9', 20), id_prefix = '', id_bytes = 9999999999, metadata_too_large = true, bytes = 9999999999}}, next_before = string.rep('9', 20)})
  -- An ID that leaves room for the empty page and less than the marker.
  local gid = 'g-' .. string.rep('u', budget - empty - math.floor((marker - empty) / 2))
  expect(#rex.json.encode({thread = gid, messages = {}, next_before = string.rep('9', 20)}) <= budget).to_be(true)
  legacy_group(gid, {'alice', 'charlie'})
  local ok, e = pcall(charlie.call, charlie, 'messaging.history', {thread = gid})
  expect(ok).to_be(false)
  expect(e.code).to_be('thread_id_too_large')
  expect(#(e.message or '') < 400, 'the error is bounded').to_be(true)
end)

test('several long message IDs: pages are packed by size, and every message arrives with its full ID', function()
  local ids = {}
  for i = 1, 4 do
    local id = 'legacy/' .. i .. '/' .. string.rep('l', 13000)
    ids[#ids + 1] = id
    deliver({id = id, from = 'bob', to = 'alice', body = 'long id ' .. i, at = at}, 'alice', direct)
  end
  local got, since, pages = {}, '0', 0
  repeat
    local page = within(alice:call('messaging.read', {since = since}))
    pages = pages + 1
    for _, m in ipairs(page.messages) do
      expect(m.metadata_too_large).to_be(nil)
      got[m.id] = m.body
    end
    since = page.next_cursor
  until not page.more or pages > 10
  for i, id in ipairs(ids) do expect(got[id], 'message ' .. i).to_be('long id ' .. i) end
  expect(pages >= 2, 'four 13 KB IDs need more than one page').to_be(true)
end)

-- The view keeps room for the draft: the first history item is cut to the budget that remains
-- after the draft, not to a whole page. (Review of 1ba9952: 56877 bytes, over the 48 KiB view
-- limit of the SDK.)
test('a stored message larger than a page and an admitted draft fit one view together', function()
  local m = {id = 'legacy/view-with-draft', from = 'bob', to = 'user', body = string.rep('x', 50000), at = at}
  deliver(m, 'user', {'bob', 'user'})
  local v = user:open('thread/bob')
  v:render()
  local draft = string.rep('d', 16384)
  local op = v:draft('composer', draft, '0', 'legacy-view-draft')
  expect(op.status).to_be('succeeded')
  local tree = v:render()
  expect(H.node(tree, 'history').messages[1].id).to_be(m.id)
  expect(#rex.json.encode(tree) <= 49152, 'the view fits the SDK limit').to_be(true)
end)
