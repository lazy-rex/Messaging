-- Ported from the hub's Node test identity-native.mjs (coverage map: the commit that adds this
-- file): mail between conversation identities. An identity sends to an identity; a /clear and a
-- resume in one pane; a hub crash. Every call goes through the agent face. A file of its own: it
-- crashes the hub. One sequence: each test uses the state of the tests before it.

local function ids(list)
  local out = {}
  for _, m in ipairs(list.messages) do out[#out + 1] = m.id end
  return out
end

local a, b = agent('first', {report = false}), agent('second', {report = false})
a:report({kind = 'codex', conversation_id = 'native-a'})
b:report({kind = 'claude', conversation_id = 'native-b'})
local a_id, b_id = 'codex:native-a', 'claude:native-b'
local first_args = {to = b_id, body = 'from an identity', key = 'im-first'}
local first, to_a

test('an identity sends to an identity; a retry replays; an ack empties the read', function()
  first = a:call('messaging.send', first_args)
  local got = b:call('messaging.read', {})
  expect(#got.messages).to_be(1)
  local m = got.messages[1]
  expect(m.id).to_be(first.id)
  expect(m.from).to_be(a_id)
  expect(m.to).to_be(b_id)
  expect(a:call('messaging.send', first_args), 'a retry returns the original result').to_equal(first)
  b:call('messaging.ack', {ids = {first.id}})
  expect(b:call('messaging.read', {}).messages).to_equal({})
end)

test('after /clear, mail to the first conversation stays with it', function()
  a:report({kind = 'codex', conversation_id = 'native-a-new', source = 'clear'})
  to_a = b:call('messaging.send', {to = a_id, body = 'to the first conversation', key = 'im-to-first'})
  expect(sql('SELECT recipient FROM messages WHERE id = ?', {to_a.id})[1].recipient).to_be(a_id)
  expect(ids(a:call('messaging.read', {})), 'the new conversation does not get it').not_to_contain(to_a.id)
end)

test('after a resume of the first conversation, the pane reads that mail', function()
  a:report({kind = 'codex', conversation_id = 'native-a', source = 'resume'})
  expect(ids(a:call('messaging.read', {}))).to_contain(to_a.id)
end)

test('after a hub crash, the first read has the mail; a retry replays', function()
  hub:restart({crash = true})
  expect(ids(a:call('messaging.read', {})), 'the first read after the restart').to_contain(to_a.id)
  expect(a:call('messaging.send', first_args), 'a retry returns the original result').to_equal(first)
end)
