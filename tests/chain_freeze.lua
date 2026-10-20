-- F1 writers (docs/f-thread-tail.md, "Freeze"): before an append, freeze steps move the oldest IDs
-- into segments until the tail with the new ID fits tail_limit (8192 encoded bytes), or the tail
-- is one ID. Fixtures with fake IDs (ASCII, no message records) test the sizes: a send does not
-- read the old messages.

local function part(s) return #s .. ':' .. s end
local function tail_key(a, b)
  if b < a then local t = a; a = b; b = t end -- not a, b = b, a: wrong in Rex Lua (rex-protocol.md)
  return 'thread/' .. part(a) .. part(b)
end
local function seg_key(tail, chain, k) return 'thread-seg/' .. tail:sub(8) .. '/' .. chain .. '/' .. k end
local function send_id(from, key) return 'send/' .. part(from) .. part(key) end
local function size_of(ids) -- encoded {"ids":[...]} of ASCII IDs without escapes
  local s = 10 + math.max(#ids - 1, 0)
  for _, id in ipairs(ids) do s = s + #id + 2 end
  return s
end
local function concat(a, b)
  local out = {}
  for _, x in ipairs(a) do out[#out + 1] = x end
  for _, x in ipairs(b) do out[#out + 1] = x end
  return out
end
-- fake_ids returns n IDs that, with next_id after them, encode to exactly total bytes.
local function fake_ids(tag, n, total, next_id)
  local sum = total - 10 - n - (#next_id + 2) - 2 * n
  local out, used = {}, 0
  for i = 1, n do
    local len = i < n and math.floor(sum / n) or sum - used
    local head = tag .. i .. '-'
    out[i] = head .. string.rep('x', len - #head)
    used = used + len
  end
  assert(size_of(concat(out, {next_id})) == total, 'fixture size')
  return out
end
-- chain_of returns every ID of a stored chain, oldest first, and the encoded size of each segment.
local function chain_of(key)
  local tail = store(key).value
  local ids, sizes = {}, {}
  for k = 0, (tail.seg or 0) - 1 do
    local seg = store(seg_key(key, tail.chain or '0', k)).value.ids
    sizes[#sizes + 1] = size_of(seg)
    for _, id in ipairs(seg) do ids[#ids + 1] = id end
  end
  for _, id in ipairs(tail.ids) do ids[#ids + 1] = id end
  return ids, sizes, tail
end

local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')

test('a tail at exactly the target after the append does not freeze; one byte over does', function()
  local exact_key, next_exact = tail_key('alice', 'bob'), send_id('alice', 'edge-0123')
  local old = fake_ids('e', 35, 8192, next_exact)
  write({{key = exact_key, value = {ids = old}}})
  alice:call('messaging.send', {to = 'bob', body = 'exact', key = 'edge-0123'})
  expect(store(exact_key).value, 'no freeze at 8192').to_equal({ids = concat(old, {next_exact})})

  local over_key, next_over = tail_key('alice', 'charlie'), send_id('alice', 'edge-01234')
  old = fake_ids('o', 35, 8193, next_over)
  write({{key = over_key, value = {ids = old}}})
  alice:call('messaging.send', {to = 'charlie', body = 'over', key = 'edge-01234'})
  local frozen = {}
  for i = 1, 34 do frozen[i] = old[i] end
  expect(store(seg_key(over_key, '0', 0)).value, 'every ID but the newest').to_equal({ids = frozen})
  expect(store(over_key).value).to_equal({ids = {old[35], next_over}, seg = 1, frozen = 34})
end)

-- fill sends from alice to user until the next send (key next_key) needs a freeze.
local function fill(next_key)
  local key, ids, n = tail_key('alice', 'user'), {}, 0
  while true do
    local tail = store(key).value or {ids = {}}
    if size_of(concat(tail.ids, {send_id('alice', next_key)})) > 8192 then return key, ids end
    n = n + 1
    local k = 'fill-' .. n .. '-' .. string.rep('k', 100) -- shorter than next_key: no filler send freezes
    ids[#ids + 1] = alice:call('messaging.send', {to = 'user', body = 'f' .. n, key = k}).id
  end
end

local after_key = 'after-freeze-' .. string.rep('a', 140)
test('a freeze whose send fails changes no reader; the retry appends', function()
  local key, ids = fill(after_key)
  local history = alice:call('messaging.history', {thread = 'user', limit = 50})
  local tab_before = tab('thread/alice').revision
  local v = user:open('thread/alice')
  local tree_before = H.node(v:render(), 'history').messages
  v:action('thread_menu', 'open', {})
  local menu = user:view('/forms/thread-menu')
  local summary = H.node(menu:render(), 'summary').text
  local next_id = send_id('alice', after_key)
  with_injection({match = {op_key = next_id}, fail = 'Injected send failure'}, 1, function()
    expect_error(function() alice:call('messaging.send', {to = 'user', body = 'after', key = after_key}) end, 'Injected send failure')
  end)
  expect(store(key).value.seg, 'the freeze committed').to_be(1)
  expect(store(key).value.ids, 'the newest ID stays in the tail').to_equal({ids[#ids]})
  expect(alice:call('messaging.history', {thread = 'user', limit = 50}), 'agent history').to_equal(history)
  expect(tab('thread/alice').revision, 'tab revision').to_be(tab_before)
  expect(H.node(v:render(), 'history').messages, 'view history').to_equal(tree_before)
  expect(H.node(menu:render(), 'summary').text, 'menu count').to_be(summary)
  local sent = alice:call('messaging.send', {to = 'user', body = 'after', key = after_key})
  expect(store(key).value).to_equal({ids = {ids[#ids], sent.id}, seg = 1, frozen = #ids - 1})
  expect(alice:call('messaging.send', {to = 'user', body = 'after', key = after_key}), 'a replay after the freeze').to_equal(sent)
  expect(store(key).value.ids, 'the replay writes nothing').to_equal({ids[#ids], sent.id})
end)

test('the observer scan lists a frozen agent thread once and no segment', function()
  user:command('threads')
  local items = H.node(user:view('/panels/threads'):render(), 'observed_threads').items
  local count = 0
  for _, item in ipairs(items) do
    if item.id:match('^d%-') then count = count + 1 end
    expect(item.id:match('seg') == nil, 'no segment entry').to_be(true)
  end
  expect(count, 'alice-bob and alice-charlie (frozen) are observed').to_be(2)
end)

test('a legacy tail of about 60 KB freezes in bounded steps, more than attempts, then appends', function()
  local key, next_id = tail_key('bob', 'charlie'), send_id('bob', 'legacy-60')
  local old = fake_ids('l', 590, 60000, next_id)
  write({{key = key, value = {ids = old}}})
  bob:call('messaging.send', {to = 'charlie', body = 'after 60 KB', key = 'legacy-60'})
  local ids, sizes, tail = chain_of(key)
  expect(ids, 'every ID once, in order').to_equal(concat(old, {next_id}))
  expect(tail.seg > 4, 'more steps than attempts').to_be(true)
  for k, s in ipairs(sizes) do expect(s <= 8192, 'segment ' .. (k - 1) .. ' fits the target').to_be(true) end
  expect(size_of(tail.ids) <= 8192, 'the tail fits').to_be(true)
  expect(tail.frozen).to_be(#old + 1 - #tail.ids)
end)

test('a failure between legacy steps leaves a valid chain; the retry continues', function()
  local key, next_id = tail_key('bob', 'user'), send_id('bob', 'legacy-30')
  local old = fake_ids('s', 300, 30000, next_id)
  write({{key = key, value = {ids = old}}})
  with_injection({match = {writes = seg_key(key, '0', 1)}, fail = 'Injected step failure'}, 1, function()
    expect_error(function() bob:call('messaging.send', {to = 'user', body = 'b', key = 'legacy-30'}) end, 'Injected step failure')
  end)
  local ids, sizes, tail = chain_of(key)
  expect(tail.seg).to_be(1)
  expect(size_of(tail.ids) > 8192, 'the tail is still over the target').to_be(true)
  expect(ids).to_equal(old)
  bob:call('messaging.send', {to = 'user', body = 'b', key = 'legacy-30'})
  ids, sizes, tail = chain_of(key)
  expect(ids).to_equal(concat(old, {next_id}))
  for k, s in ipairs(sizes) do expect(s <= 8192, 'segment ' .. (k - 1)).to_be(true) end
end)

test('an ID over the target gets a segment alone; a one-ID tail appends without a step', function()
  local key, next_id = tail_key('charlie', 'user'), send_id('charlie', 'big-1')
  local huge = 'h-' .. string.rep('x', 9000)
  write({{key = key, value = {ids = {huge, 'small-1', 'small-2'}}}})
  charlie:call('messaging.send', {to = 'user', body = 'c', key = 'big-1'})
  expect(store(seg_key(key, '0', 0)).value).to_equal({ids = {huge}})
  expect(store(key).value).to_equal({ids = {'small-1', 'small-2', next_id}, seg = 1, frozen = 1})

  local g = alice:call('messaging.thread_create', {members = {'charlie'}, title = 'big', key = 'big-group'})
  local gkey = tail_key('', g.id)
  local huge2 = 'h2-' .. string.rep('x', 9000)
  write({{key = gkey, value = {ids = {huge2}}}})
  local first = alice:call('messaging.send', {to = g.id, body = 'one', key = 'big-2'}).id
  expect(store(gkey).value, 'no step on a one-ID tail').to_equal({ids = {huge2, first}})
  local second = alice:call('messaging.send', {to = g.id, body = 'two', key = 'big-3'}).id
  expect(store(seg_key(gkey, '0', 0)).value).to_equal({ids = {huge2}})
  expect(store(gkey).value).to_equal({ids = {first, second}, seg = 1, frozen = 1})
end)

test('a concurrent append between the freeze and the send: the send retries', function()
  local g = alice:call('messaging.thread_create', {members = {'bob'}, title = 'race', key = 'race-group'})
  local key = tail_key('', g.id)
  local next_id = send_id('alice', 'race-send')
  local old = fake_ids('c', 35, 8193, next_id)
  write({{key = key, value = {ids = old}}})
  -- The freeze is the first change of the tail; the send batch is the second.
  local after_freeze = {ids = {old[35], 'raced-id'}, seg = 1, frozen = 34}
  with_injection({match = {updates = key}, skip = 1, ops = {{key = key, value = after_freeze}}}, 1, function()
    alice:call('messaging.send', {to = g.id, body = 'race', key = 'race-send'})
  end)
  expect(store(key).value).to_equal({ids = {old[35], 'raced-id', next_id}, seg = 1, frozen = 34})
end)

test('change_members: a concurrent freeze makes it read the new chain for its backfill', function()
  local g = alice:call('messaging.thread_create', {members = {'bob'}, title = 'cm', key = 'cm-group'})
  local old = alice:call('messaging.send', {to = g.id, body = 'old', key = 'cm-old'}).id
  local new = alice:call('messaging.send', {to = g.id, body = 'new', key = 'cm-new'}).id
  local m = store('message/' .. old).value
  m.recipients = nil
  write({{key = 'message/' .. old, value = m}})
  local key = tail_key('', g.id)
  local frozen = {
    {key = seg_key(key, '0', 0), value = {ids = {old}}},
    {key = key, value = {ids = {new}, seg = 1, frozen = 1}},
  }
  with_injection({match = {op_prefix = 'members/'}, ops = frozen}, 1, function()
    alice:call('messaging.thread_members', {thread = g.id, members = {'alice', 'bob', 'charlie'}, key = 'cm-add'})
  end)
  expect(store('delivery/' .. part(old)).value).to_equal({ids = {'bob'}})
  local tail = store(key).value
  expect(tail.seg).to_be(1)
  expect(tail.ids[1]).to_be(new)
  expect(#tail.ids).to_be(2)
end)

test('a view send freezes like an agent send', function()
  local key, next_id = tail_key('charlie', 'user'), send_id('user', 'view-freeze')
  local old = fake_ids('v', 35, 8193, next_id)
  -- An earlier test froze this thread: keep its chain fields, or the step would write segment 0 again.
  local before = store(key).value
  write({{key = key, value = {ids = old, seg = before.seg, frozen = before.frozen}}})
  local v = user:open('thread/charlie')
  local composer = H.node(v:render(), 'composer')
  local saved = v:draft('composer', 'from the view', composer.draft_revision, 'view-freeze-draft')
  local op = v:send('composer', 'from the view', saved.result.draft_revision, 'view-freeze')
  expect(op.status).to_be('succeeded')
  expect(store(key).value).to_equal({ids = {old[35], next_id}, seg = before.seg + 1, frozen = before.frozen + 34})
end)

test('a user join: a concurrent freeze makes the backfill read the new chain', function()
  local g = alice:call('messaging.thread_create', {members = {'bob'}, title = 'uj', key = 'uj-group'})
  local old = alice:call('messaging.send', {to = g.id, body = 'old', key = 'uj-old'}).id
  local new = alice:call('messaging.send', {to = g.id, body = 'new', key = 'uj-new'}).id
  local m = store('message/' .. old).value
  m.recipients = nil
  write({{key = 'message/' .. old, value = m}})
  local key = tail_key('', g.id)
  local v = user:open('thread/' .. g.id)
  v:render()
  local saved = v:draft('composer', 'joining', '0', 'uj-draft')
  local frozen = {
    {key = seg_key(key, '0', 0), value = {ids = {old}}},
    {key = key, value = {ids = {new}, seg = 1, frozen = 1}},
  }
  local op = with_injection({match = {op_key = send_id('user', 'uj-send')}, ops = frozen}, 1, function()
    return v:send('composer', 'joining', saved.result.draft_revision, 'uj-send')
  end)
  expect(op.status).to_be('succeeded')
  expect(store('delivery/' .. part(old)).value).to_equal({ids = {'bob'}})
  expect(store(key).value).to_equal({ids = {new, op.result.message_id}, seg = 1, frozen = 1})
end)
