-- Ported from the hub's Node test identity-native.mjs (coverage map: the commit that adds this
-- file): mail across identity reports. Roster agents become conversation identities; an identity
-- that never joined sends; a /clear and a resume in one pane; a hub crash. Every call goes through
-- the agent face. A file of its own: it crashes the hub. One sequence: each test uses the state
-- of the tests before it.

local function ids(list)
  local out = {}
  for _, m in ipairs(list.messages) do out[#out + 1] = m.id end
  return out
end

local a, b = agent('alice'), agent('bob')
local u = agent('unjoined', {join = false})
local legacy_args = {to = 'bob', body = 'before the identities', key = 'im-legacy'}
local legacy, legacy_cursor, to_alias

test('before the identity reports, a legacy send reads with the roster names', function()
  legacy = a:call('messaging.send', legacy_args)
  local got = b:call('messaging.read', {})
  expect(#got.messages).to_be(1)
  local m = got.messages[1]
  expect(m.id).to_be(legacy.id)
  expect(m.from).to_be('alice')
  expect(m.to).to_be('bob')
  legacy_cursor = m.cursor
  expect(type(legacy_cursor)).to_be('string')
end)

test('after the reports, the same message, id and cursor read with the identities; a retry replays; an ack empties the read', function()
  a:report({kind = 'codex', conversation_id = 'native-a'})
  b:report({kind = 'claude', conversation_id = 'native-b'})
  local got = b:call('messaging.read', {})
  expect(#got.messages).to_be(1)
  local m = got.messages[1]
  expect(m.id).to_be(legacy.id)
  expect(m.cursor, 'the mailbox migration keeps the cursor').to_be(legacy_cursor)
  expect(m.from).to_be('codex:native-a')
  expect(m.to).to_be('claude:native-b')
  expect(a:call('messaging.send', legacy_args), 'a retry returns the original result').to_equal(legacy)
  b:call('messaging.ack', {ids = {legacy.id}})
  expect(b:call('messaging.read', {}).messages).to_equal({})
end)

test('an identity that never joined sends to an identity', function()
  u:report({kind = 'claude', conversation_id = 'native-unjoined'})
  local sent = u:call('messaging.send', {to = 'claude:native-b', body = 'from an unjoined identity', key = 'im-unjoined'})
  local got = b:call('messaging.read', {})
  expect(#got.messages).to_be(1)
  expect(got.messages[1].id).to_be(sent.id)
  expect(got.messages[1].from).to_be('claude:native-unjoined')
end)

test('after /clear, mail to the legacy name stays with the first conversation', function()
  a:report({kind = 'codex', conversation_id = 'native-a-new', source = 'clear'})
  to_alias = b:call('messaging.send', {to = 'alice', body = 'to the legacy name', key = 'im-to-alias'})
  expect(store('message/' .. to_alias.id).value.to, 'the legacy name is an alias of the first conversation').to_be('codex:native-a')
  expect(ids(a:call('messaging.read', {})), 'the new conversation does not get it').not_to_contain(to_alias.id)
end)

test('after a resume of the first conversation, the pane reads that mail', function()
  a:report({kind = 'codex', conversation_id = 'native-a', source = 'resume'})
  expect(ids(a:call('messaging.read', {}))).to_contain(to_alias.id)
end)

test('after a hub crash, the first read has the mail; a retry replays', function()
  hub:restart({crash = true})
  expect(ids(a:call('messaging.read', {})), 'the first read after the restart').to_contain(to_alias.id)
  expect(a:call('messaging.send', legacy_args), 'a retry returns the original result').to_equal(legacy)
end)
