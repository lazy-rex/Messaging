-- F1 readers (docs/f-thread-tail.md): every reader of a thread walks its chain, the tail and the
-- frozen segments. The fixtures build chains with write(), from real messages: no writer freezes
-- yet. A tail keeps its chain fields when a writer appends.

local function part(s) return #s .. ':' .. s end
local function tail_key(a, b)
  if b < a then local t = a; a = b; b = t end -- not a, b = b, a: wrong in Rex Lua (rex-protocol.md)
  return 'thread/' .. part(a) .. part(b)
end
local function seg_key(tail, chain, k) return 'thread-seg/' .. tail:sub(8) .. '/' .. chain .. '/' .. k end
local function slice(list, i, j)
  local out = {}
  for n = i, j do out[#out + 1] = list[n] end
  return out
end
local function ids_of(list)
  local out = {}
  for _, m in ipairs(list) do out[#out + 1] = m.id end
  return out
end
-- chain writes ids as a chain under key: segments of the given sizes, the rest in the tail.
local function chain(key, name, ids, sizes)
  local ops, n = {}, 0
  for k, size in ipairs(sizes) do
    ops[#ops + 1] = {key = seg_key(key, name, k - 1), value = {ids = slice(ids, n + 1, n + size)}}
    n = n + size
  end
  local value = {ids = slice(ids, n + 1, #ids), seg = #sizes, frozen = n}
  if name ~= '0' then value.chain = name end
  ops[#ops + 1] = {key = key, value = value}
  write(ops)
end

local alice, bob = agent('alice'), agent('bob')
local user_tail = tail_key('alice', 'user')
local sent = {} -- alice -> user, oldest first

test('history walks the tail and three segments, newest first, with exact cursors', function()
  for i = 1, 11 do sent[i] = alice:call('messaging.send', {to = 'user', body = 'm' .. i, key = 'chain-' .. i}).id end
  chain(user_tail, '2', sent, {3, 3, 3})
  local seen, before = {}, nil
  for page = 1, 3 do
    local h = alice:call('messaging.history', {thread = 'user', limit = 4, before = before})
    for _, id in ipairs(ids_of(h.messages)) do seen[#seen + 1] = id end
    before = h.next_before
    if page < 3 then expect(before, 'page ' .. page .. ' continues').to_be(h.messages[#h.messages].cursor) end
  end
  expect(before, 'the last page ends').to_be(nil)
  local newest_first = {}
  for i = 11, 1, -1 do newest_first[#newest_first + 1] = sent[i] end
  expect(seen).to_equal(newest_first)
  -- A cursor inside segment 1 starts in segment 1.
  local all = alice:call('messaging.history', {thread = 'user', limit = 50}).messages
  local h = alice:call('messaging.history', {thread = 'user', limit = 50, before = all[7].cursor}) -- before m5
  expect(ids_of(h.messages)).to_equal({sent[4], sent[3], sent[2], sent[1]})
end)

test('the view: the tree and history pages read the chain, oldest first', function()
  local v = user:open('thread/alice')
  local tree = v:render()
  expect(ids_of(H.node(tree, 'history').messages)).to_equal(sent)
  local page = v:history(sent[6])
  expect(ids_of(page.messages)).to_equal(slice(sent, 1, 5))
  expect(page.has_more).to_be_falsy()
  expect_error(function() v:history('not-in-the-thread') end, 'Unknown history cursor')
end)

test('the menu counts the frozen IDs; the tab keeps the newest ID as its revision', function()
  local v = user:view('thread/alice')
  v:action('thread_menu', 'open', {})
  local menu = user:view('/forms/thread-menu')
  expect(H.node(menu:render(), 'summary').text).to_match('11 messages')
  expect(tab('thread/alice').revision).to_be(sent[11])
end)

test('an agent send and a view send append to the tail and keep the chain fields', function()
  local m12 = alice:call('messaging.send', {to = 'user', body = 'm12', key = 'chain-12'}).id
  expect(store(user_tail).value).to_equal({ids = {sent[10], sent[11], m12}, seg = 3, chain = '2', frozen = 9})
  local v = user:view('thread/alice')
  local composer = H.node(v:render(), 'composer')
  local saved = v:draft('composer', 'm13', composer.draft_revision, 'chain-draft')
  local op = v:send('composer', 'm13', saved.result.draft_revision, 'chain-13')
  expect(op.status).to_be('succeeded')
  local m13 = op.result.message_id
  expect(store(user_tail).value).to_equal({ids = {sent[10], sent[11], m12, m13}, seg = 3, chain = '2', frozen = 9})
end)

-- legacy_group makes a group of alice and bob with two messages, the older one without a delivery
-- snapshot and frozen in segment 0.
local function legacy_group(key)
  local g = alice:call('messaging.thread_create', {members = {'bob'}, title = key, key = key})
  local old = alice:call('messaging.send', {to = g.id, body = 'old', key = key .. '-old'}).id
  local new = alice:call('messaging.send', {to = g.id, body = 'new', key = key .. '-new'}).id
  local m = store('message/' .. old).value
  m.recipients = nil
  write({{key = 'message/' .. old, value = m}})
  local key_ = tail_key('', g.id)
  chain(key_, '0', {old, new}, {1})
  return g, old, new, key_
end

test('change_members backfills a frozen message and keeps the chain', function()
  local g, old, new, key = legacy_group('chain-members')
  alice:call('messaging.thread_members', {thread = g.id, members = {'alice', 'bob', 'user'}, key = 'chain-members-add'})
  expect(store('delivery/' .. part(old)).value, 'the frozen message keeps its old audience').to_equal({ids = {'bob'}})
  local tail = store(key).value
  expect(tail.seg).to_be(1)
  expect(tail.frozen).to_be(1)
  expect(tail.ids[1]).to_be(new)
  expect(#tail.ids, 'the membership notice appends to the tail').to_be(2)
end)

test('the user joins a group by a view send; the backfill reads the segment', function()
  local g, old, new, key = legacy_group('chain-join')
  local v = user:open('thread/' .. g.id)
  v:render()
  local saved = v:draft('composer', 'joining', '0', 'chain-join-draft')
  local op = v:send('composer', 'joining', saved.result.draft_revision, 'chain-join-send')
  expect(op.status).to_be('succeeded')
  expect(store('delivery/' .. part(old)).value).to_equal({ids = {'bob'}})
  expect(store(key).value).to_equal({ids = {new, op.result.message_id}, seg = 1, frozen = 1})
end)

test('a segment missing on every read ends with unavailable', function()
  local ids = {}
  for i = 1, 3 do ids[i] = bob:call('messaging.send', {to = 'alice', body = 'b' .. i, key = 'gone-' .. i}).id end
  local key = tail_key('alice', 'bob')
  chain(key, '0', ids, {1, 1})
  write({{key = seg_key(key, '0', 0), delete = true}})
  expect_error(function() alice:call('messaging.history', {thread = 'bob', limit = 50}) end, 'unavailable')
end)

-- The read hook (hub 6c48bf7): inject{match = {reads = key}} commits its ops after the hub built
-- the reply of a get of key, so the reader has the old data and its next read sees the change.

test('a chain replaced after the reader consumed a segment: the whole read starts again', function()
  local ids = {}
  for i = 1, 11 do ids[i] = bob:call('messaging.send', {to = 'user', body = 'r' .. i, key = 'race-' .. i}).id end
  local key = tail_key('bob', 'user')
  chain(key, '0', ids, {3, 3, 3})
  -- After segment 2 is read, an alias migration replaces chain 0 with chain 1, packed otherwise.
  local ops = {}
  for k = 0, 2 do ops[#ops + 1] = {key = seg_key(key, '0', k), delete = true} end
  ops[#ops + 1] = {key = seg_key(key, '1', 0), value = {ids = slice(ids, 1, 4)}}
  ops[#ops + 1] = {key = seg_key(key, '1', 1), value = {ids = slice(ids, 5, 8)}}
  ops[#ops + 1] = {key = key, value = {ids = slice(ids, 9, 11), seg = 2, chain = '1', frozen = 8}}
  local id = inject({match = {reads = seg_key(key, '0', 2)}, ops = ops})
  local h = bob:call('messaging.history', {thread = 'user', limit = 50})
  expect(injection(id).consumed, 'the reader read segment 2 of the old chain').to_be(1)
  local newest_first = {}
  for i = 11, 1, -1 do newest_first[#newest_first + 1] = ids[i] end
  expect(ids_of(h.messages), 'no repeated and no missing message').to_equal(newest_first)
end)

test('a join send guards the tail that its backfill read', function()
  local g, old, new, key = legacy_group('chain-guard')
  local v = user:open('thread/' .. g.id)
  v:render()
  local saved = v:draft('composer', 'joining', '0', 'chain-guard-draft')
  -- After the backfill reads the delivery record of old, another writer appends a message without
  -- a delivery snapshot. The send must not commit a backfill that misses it.
  local raced = {id = 'raced-legacy', from = 'alice', to = g.id, body = 'raced', at = '2026-10-19T00:00:00Z'}
  local id = inject({match = {reads = 'delivery/' .. part(old)}, ops = {
    {key = 'message/raced-legacy', value = raced},
    {key = key, value = {ids = {new, 'raced-legacy'}, seg = 1, frozen = 1}},
  }})
  local op = v:send('composer', 'joining', saved.result.draft_revision, 'chain-guard-send')
  expect(op.status).to_be('succeeded')
  expect(injection(id).consumed).to_be(1)
  expect(store('delivery/' .. part('raced-legacy')).value, 'the retry backfills the raced message').to_equal({ids = {'bob'}})
  expect(store('delivery/' .. part(old)).value).to_equal({ids = {'bob'}})
  expect(store(key).value).to_equal({ids = {new, 'raced-legacy', op.result.message_id}, seg = 1, frozen = 1})
end)
