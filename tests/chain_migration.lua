-- F1 alias migration (docs/f-thread-tail.md, "Alias migration"): the migration reads each
-- contributor's whole chain, merges the IDs (no duplicates, message order), packs them with the
-- step rule into a new chain, and deletes every old segment and the legacy tails in one batch.
-- The new chain number is 1 + the largest contributor chain number if a contributor has segments.

local function part(s) return #s .. ':' .. s end
local function tail_key(a, b)
  if b < a then local t = a; a = b; b = t end -- not a, b = b, a: wrong in Rex Lua (rex-protocol.md)
  return 'thread/' .. part(a) .. part(b)
end
local function seg_key(tail, chain, k) return 'thread-seg/' .. tail:sub(8) .. '/' .. chain .. '/' .. k end
local function size_of(ids) -- encoded {"ids":[...]} of ASCII IDs without escapes
  local s = 10 + math.max(#ids - 1, 0)
  for _, id in ipairs(ids) do s = s + #id + 2 end
  return s
end
local function slice(list, i, j)
  local out = {}
  for n = i, j do out[#out + 1] = list[n] end
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
-- segments_left returns the segment keys of a chain that still exist, from k = 0 to k = n - 1.
local function segments_left(key, chain, n)
  local out = {}
  for k = 0, n - 1 do
    if store(seg_key(key, chain, k)).rev ~= '0' then out[#out + 1] = seg_key(key, chain, k) end
  end
  return out
end

local a_id, b_id, c_id = 'claude:conversation-a', 'codex:conversation-b', 'claude:conversation-c'
local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')
local function migrated(name)
  return wait('the migration of ' .. name, function()
    if store('identity-migrated/' .. part(name)).rev ~= '0' then return true end
  end)
end

local order = {} -- every message of the alice-bob thread, in send order
local first_target

test('two contributors with segments: one new chain, no duplicates, in message order', function()
  local legacy = tail_key('alice', 'bob')
  local canonical = {}
  for i = 1, 40 do
    local key = string.rep('k', 190) .. i
    order[#order + 1] = alice:call('messaging.send', {to = 'bob', body = 'a' .. i, key = key}).id
    if i % 7 == 0 then
      local id = charlie:call('messaging.send', {to = 'bob', body = 'c' .. i, key = 'canonical-' .. i}).id
      order[#order + 1] = id
      canonical[#canonical + 1] = id
    end
  end
  -- The writer froze the legacy tail: chain 0 with segments.
  local _, _, legacy_tail = chain_of(legacy)
  expect(legacy_tail.seg >= 1, 'the legacy tail has segments').to_be(true)
  -- The canonical contributor: chain 2, the charlie messages and one legacy ID again.
  canonical[#canonical + 1] = order[#order]
  local target = tail_key(a_id, 'bob')
  write({
    {key = seg_key(target, '2', 0), value = {ids = slice(canonical, 1, 2)}},
    {key = seg_key(target, '2', 1), value = {ids = slice(canonical, 3, 4)}},
    {key = target, value = {ids = slice(canonical, 5, #canonical), seg = 2, chain = '2', frozen = 4}},
  })
  alice:report({kind = 'claude', conversation_id = 'conversation-a'})
  migrated('alice')
  local ids, sizes, tail = chain_of(target)
  expect(ids, 'every ID once, in message order').to_equal(order)
  expect(tail.chain).to_be('3')
  expect(tail.frozen).to_be(#ids - #tail.ids)
  expect(#sizes >= 1, 'the merged IDs are over the target, so they are packed').to_be(true)
  for k, size in ipairs(sizes) do expect(size <= 8192, 'segment ' .. (k - 1) .. ' fits the target').to_be(true) end
  expect(size_of(tail.ids) <= 8192, 'the tail fits the target').to_be(true)
  expect(store(legacy).rev, 'the legacy tail is deleted').to_be('0')
  expect(segments_left(legacy, '0', legacy_tail.seg)).to_equal({})
  expect(segments_left(target, '2', 2)).to_equal({})
  local h = alice:call('messaging.history', {thread = 'bob', limit = 50})
  local newest_first = {}
  for i = #order, 1, -1 do newest_first[#newest_first + 1] = order[i] end
  local got = {}
  for _, m in ipairs(h.messages) do got[#got + 1] = m.id end
  expect(got).to_equal(newest_first)
  first_target = {key = target, seg = tail.seg}
end)

test('a second migration replaces the migrated chain; a thread without segments keeps chain 0', function()
  local plain = tail_key('bob', 'charlie')
  local plain_ids = store(plain).value.ids
  bob:report({kind = 'codex', conversation_id = 'conversation-b'})
  migrated('bob')
  local target = tail_key(a_id, b_id)
  local ids, _, tail = chain_of(target)
  expect(ids).to_equal(order)
  expect(tail.chain).to_be('4')
  expect(store(first_target.key).rev).to_be('0')
  expect(segments_left(first_target.key, '3', first_target.seg)).to_equal({})
  expect(store(tail_key(b_id, 'charlie')).value, 'no segments: no new chain number').to_equal({ids = plain_ids})
end)

test('a revision conflict before the migration batch: the migration scans again', function()
  local key = tail_key(b_id, 'charlie')
  local ids = store(key).value.ids
  -- A segmented contributor: the first two IDs in segment 0 of chain 0.
  write({
    {key = seg_key(key, '0', 0), value = {ids = slice(ids, 1, 2)}},
    {key = key, value = {ids = slice(ids, 3, #ids), seg = 1, frozen = 2}},
  })
  local extra = alice:call('messaging.send', {to = 'charlie', body = 'newest', key = 'extra'}).id
  local appended = slice(ids, 3, #ids)
  appended[#appended + 1] = extra
  local migration = 'identity-migrate/' .. part('charlie') .. part(c_id)
  with_injection({match = {op_key = migration}, ops = {
    {key = key, value = {ids = appended, seg = 1, frozen = 2}},
  }}, 1, function()
    charlie:report({kind = 'claude', conversation_id = 'conversation-c'})
    return migrated('charlie')
  end)
  local want = {}
  for _, x in ipairs(ids) do want[#want + 1] = x end
  want[#want + 1] = extra
  local got, _, tail = chain_of(tail_key(b_id, c_id))
  expect(got, 'the retry merges the appended ID').to_equal(want)
  expect(tail.chain).to_be('1')
  expect(store(key).rev).to_be('0')
  expect(segments_left(key, '0', 1)).to_equal({})
end)
