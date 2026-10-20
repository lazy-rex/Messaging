-- F1 alias migration limits (docs/f-thread-tail.md, "Alias migration"). A scan that has a tail
-- without one of its segments scans again, then fails with unavailable after attempts, and
-- commits nothing. A migration batch over the request limit fails and commits nothing (known
-- limit). The last test leaves bob's migration failing: keep it last.

local function part(s) return #s .. ':' .. s end
local function tail_key(a, b)
  if b < a then local t = a; a = b; b = t end -- not a, b = b, a: wrong in Rex Lua (rex-protocol.md)
  return 'thread/' .. part(a) .. part(b)
end
local function seg_key(tail, chain, k) return 'thread-seg/' .. tail:sub(8) .. '/' .. chain .. '/' .. k end

local a_id, b_id = 'claude:conversation-a', 'codex:conversation-b'
local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')

test('a tail without its segment stops the migration until the segment exists', function()
  local ids = {}
  for i = 1, 3 do ids[i] = alice:call('messaging.send', {to = 'charlie', body = 't' .. i, key = 'torn-' .. i}).id end
  local legacy = tail_key('alice', 'charlie')
  write({{key = legacy, value = {ids = {ids[2], ids[3]}, seg = 1, frozen = 1}}})
  local legacy_rev = store(legacy).rev
  alice:report({kind = 'claude', conversation_id = 'conversation-a'})
  expect_error(function() charlie:call('messaging.read', {}) end, 'during identity migration')
  expect(store('identity-migrated/' .. part('alice')).rev, 'nothing is committed').to_be('0')
  expect(store(legacy).rev).to_be(legacy_rev)
  write({{key = seg_key(legacy, '0', 0), value = {ids = {ids[1]}}}})
  charlie:call('messaging.read', {})
  local target = tail_key(a_id, 'charlie')
  expect(store(target).value).to_equal({ids = ids, chain = '1'})
  expect(store(legacy).rev).to_be('0')
  expect(store(seg_key(legacy, '0', 0)).rev).to_be('0')
end)

test('a migration batch over the request limit fails and commits nothing', function()
  -- About 70 KB of IDs: the writer freezes them into segments, but the migration rewrites all.
  -- bob acknowledges each message, so his mailbox stays small (mailbox growth is F2).
  for i = 1, 330 do
    local id = charlie:call('messaging.send', {to = 'bob', body = 'b', key = string.rep('k', 190) .. i}).id
    bob:call('messaging.ack', {ids = {id}})
  end
  local legacy = tail_key('bob', 'charlie')
  local before = store(legacy)
  expect(before.value.seg >= 8, 'the legacy thread has segments').to_be(true)
  bob:report({kind = 'codex', conversation_id = 'conversation-b'})
  expect_error(function() charlie:call('messaging.read', {}) end, 'invalid_input')
  expect(store('identity-migrated/' .. part('bob')).rev).to_be('0')
  expect(store(legacy)).to_equal(before)
  expect(store(seg_key(legacy, '0', 0)).rev).not_to_be('0')
  expect(store(tail_key(b_id, 'charlie')).rev).to_be('0')
end)
