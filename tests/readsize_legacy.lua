-- Stored messages from before size admission (written here with hub.test.write) must still read:
-- a page never exceeds 49152 encoded bytes, never skips a message, and always makes progress.

local function part(s) return #s .. ':' .. s end
local function box(name) return 'mailbox/' .. part(name) end
local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')
local budget = 49152
local at = '2026-10-19T00:00:00Z'

local function within(page)
  local n = #rex.json.encode(page)
  expect(n <= budget, 'page size ' .. n).to_be(true)
  return page
end

-- deliver writes a legacy message record and adds it to the reader's mailbox and the thread.
local function deliver(m, reader, thread_key)
  write({{key = 'message/' .. m.id, value = m}})
  local mb = store(box(reader))
  local ids = mb.value and mb.value.ids or {}
  ids[m.id] = true
  write({{key = box(reader), value = {ids = ids}}})
  if thread_key then
    local t = store(thread_key)
    local list = t.value and t.value.ids or {}
    list[#list + 1] = m.id
    write({{key = thread_key, value = {ids = list}}})
  end
  return store('message/' .. m.id).rev
end

local direct = 'thread/' .. part('alice') .. part('bob')

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
-- legacy_group replaces the groups record with one legacy group (a write is at most 64 KiB).
local function legacy_group(id, members)
  write({{key = 'groups', value = {groups = {[id] = {name = 'Legacy group', members = members}}}}})
end

test('a long thread ID and a long message ID: history returns id_prefix and id_bytes', function()
  local gid = 'g-' .. string.rep('t', 28000)
  legacy_group(gid, {'alice', 'charlie'})
  local mid = 'legacy/' .. string.rep('m', 22000)
  local m = {id = mid, from = 'alice', to = 'charlie', recipients = {'charlie'}, body = 'hello', at = at}
  local rev = deliver(m, 'charlie', 'thread/' .. part('') .. part(gid))
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

test('several long message IDs: requests are packed by size, and every message arrives with its full ID', function()
  local ids = {}
  for i = 1, 4 do
    local id = 'legacy/' .. i .. '/' .. string.rep('l', 13000)
    ids[#ids + 1] = id
    deliver({id = id, from = 'bob', to = 'alice', recipients = {'alice'}, body = 'long id ' .. i, at = at}, 'alice', nil)
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

test('a key too long for one hub request is key_too_large, not a skip', function()
  local id = 'legacy/' .. string.rep('k', 50000)
  local mb = store(box('bob'))
  local unread = mb.value and mb.value.ids or {}
  unread[id] = true
  write({{key = box('bob'), value = {ids = unread}}})
  local ok, e = pcall(bob.call, bob, 'messaging.read', {})
  expect(ok).to_be(false)
  expect(e.code).to_be('key_too_large')
  expect(#(e.message or '') < 400, 'the error is bounded').to_be(true)
end)
