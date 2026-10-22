-- The send, read and ack contract, replies, and commit faults. Agents call through the agent face
-- (the MCP path) unless a test says otherwise. Storage is SQL: each handler is one transaction, so
-- the hub.store races of the key-value version cannot happen; the commit faults replace them.

-- Every call fails with unavailable until the import at start is done (import.lua). Under load,
-- the start can end before it; the tests begin after it.
wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

local function part(s) return #s .. ':' .. s end
-- unread returns the unread message IDs of an agent, sorted.
local function unread(name)
  local out = {}
  for _, r in ipairs(sql([[SELECT m.id FROM deliveries d JOIN messages m ON m.seq = d.seq
      WHERE d.agent = ? AND d.acked = 0 ORDER BY m.id]], {name})) do out[#out + 1] = r.id end
  return out
end
local function message(id) return sql('SELECT * FROM messages WHERE id = ?', {id})[1] end
-- revision is the clock: every write that gives out a revision moves it.
local function revision() return sql('SELECT CAST(n AS TEXT) AS n FROM clock')[1].n end
local function plugin_client() return H.hub('hub.test.status', {}).plugins.messaging.client_id end

local alice, bob = agent('alice'), agent('bob')
local first, original, second, incoming

test('schema: send requires to, body and key, and documents reply_to', function()
  local info = rex.call('client.inspect', {client_id = plugin_client()})
  local send
  for _, a in ipairs(info.actions) do if a.name == 'messaging.send' then send = a end end
  expect(send.args.required).to_equal({'to', 'body', 'key'})
  expect(send.args.properties.reply_to.type).to_be('string')
  expect(send.description).to_match('reply_to')
  expect_error(function() alice:call('messaging.send', {to = 'bob', body = 'missing key'}) end, 'key')
end)

test('send replays its first result and refuses a changed body under the same key', function()
  local body = 'quote " slash \\ nul \0 snow 雪'
  first = alice:call('messaging.send', {key = 'a/:é', body = body, to = 'bob'})
  expect(first.id).to_be('send/' .. part('alice') .. part('a/:é'))
  original = message(first.id)
  expect(original.body).to_be(body)
  local before = revision()
  expect(alice:call('messaging.send', {key = 'a/:é', body = body, to = 'bob'})).to_equal(first)
  expect(revision(), 'a saved operation does not write again').to_be(before)
  expect(unread('bob')).to_equal({first.id})
  expect_error(function() alice:call('messaging.send', {key = 'a/:é', body = 'different', to = 'bob'}) end, 'different content')
end)

test('read does not acknowledge; keys are scoped by sender; ack validates the whole batch', function()
  incoming = bob:call('messaging.read', {})
  expect(incoming.messages[1].from).to_be('alice')
  expect(bob:call('messaging.read', {})).to_equal(incoming)
  second = bob:call('messaging.send', {key = 'a/:é', body = 'reply', to = 'alice'})
  expect(second.id).not_to_be(first.id)
  expect_error(function() bob:call('messaging.ack', {ids = {first.id, 'missing'}}) end, 'Unknown message')
  expect(bob:call('messaging.read', {}), 'an invalid batch acknowledges nothing').to_equal(incoming)
  bob:call('messaging.ack', {ids = {first.id, first.id}})
  expect(unread('bob')).to_equal({})
  local after = revision()
  bob:call('messaging.ack', {ids = {first.id}})
  bob:call_raw('messaging.ack', '{"ids":[]}')
  expect(sql('SELECT count(*) AS n FROM deliveries WHERE agent = ? AND acked = 0', {'bob'})[1].n).to_be(0)
  expect(revision(), 'a repeated or empty ack gives out no revision').to_be(after)
  expect(notice('bob').pending).to_be(false)
  expect_error(function() alice:call('messaging.ack', {ids = {first.id}}) end, 'Unknown message')
  -- A definite refusal, not 'unavailable': a retry cannot help.
  local e = expect_error(function() alice:call('messaging.send', {key = 'bad-recipient', body = 'hello', to = 'nobody'}) end, 'Unknown recipient')
  expect(tostring(e)).to_match('invalid_input')
end)

test('a caller outside every pane is refused', function()
  expect_error(function() H.perform(plugin_client(), 'messaging.read', {}) end, 'does not recognize')
end)

test('a failed commit writes nothing; the same key then sends once', function()
  local before = revision()
  with_injection({match = {sql_commit_writes = 'messages'}, fail = 'Commit lost'}, 1, function()
    expect_error(function() alice:call('messaging.send', {key = 'commit-fails', body = 'hello', to = 'bob'}) end, 'Commit lost')
  end)
  expect(revision(), 'nothing of the send committed').to_be(before)
  expect(message('send/' .. part('alice') .. part('commit-fails'))).to_be(nil)
  local sent = alice:call('messaging.send', {key = 'commit-fails', body = 'hello', to = 'bob'})
  expect(message(sent.id).body).to_be('hello')
  bob:call('messaging.ack', {ids = {sent.id}})
end)

test('a lost reply after the commit replays the first result; nothing is sent twice', function()
  local id = 'send/' .. part('alice') .. part('reply-lost')
  with_injection({match = {sql_commit_writes = 'messages'}, fail = 'Reply lost', fail_code = 'unavailable', after = true}, 1, function()
    expect_error(function() alice:call('messaging.send', {key = 'reply-lost', body = 'once', to = 'bob'}) end, 'Reply lost')
  end)
  expect(message(id).body, 'the send committed').to_be('once')
  local before = revision()
  expect(alice:call('messaging.send', {key = 'reply-lost', body = 'once', to = 'bob'})).to_equal({id = id, key = 'reply-lost'})
  expect(revision(), 'the retry replays and writes nothing').to_be(before)
  expect(unread('bob')).to_equal({id})
  bob:call('messaging.ack', {ids = {id}})
end)

test('a reply acknowledges only its question; invalid replies write nothing', function()
  local question = alice:call('messaging.send', {key = 'reply-question', body = 'hello', to = 'bob'})
  local args = {to = 'alice', body = 'answer', key = 'reply-answer', reply_to = question.id}
  local reply = bob:call('messaging.send', args)
  expect(unread('bob')).to_equal({})
  local alice_unread = unread('alice')
  local found = false
  for _, id in ipairs(alice_unread) do found = found or id == reply.id end
  expect(found, 'the reply is unread for alice').to_be(true)
  expect(message(reply.id).reply_to).to_be(question.id)
  local after = revision()
  expect(bob:call('messaging.send', args)).to_equal(reply)
  expect(revision(), 'a reply replay writes nothing').to_be(after)
  expect_error(function() bob:call('messaging.send', {to = 'alice', body = 'answer', key = 'reply-answer', reply_to = first.id}) end, 'different content')
  local before = revision()
  expect_error(function() bob:call('messaging.send', {to = 'alice', body = 'answer', key = 'foreign-reply', reply_to = second.id}) end, 'reply_to must name')
  expect_error(function() bob:call('messaging.send', {to = 'alice', body = 'answer', key = 'missing-reply', reply_to = 'missing'}) end, 'reply_to must name')
  expect_error(function() bob:call('messaging.send', {to = 'bob', body = 'answer', key = 'wrong-recipient', reply_to = question.id}) end, 'reply_to must name')
  expect(revision(), 'invalid replies do not write').to_be(before)
end)

test('a reply keeps the notice while other mail is unread; the last reply clears it', function()
  local q = alice:call('messaging.send', {key = 'last-question', body = 'hello', to = 'bob'})
  local other = alice:call('messaging.send', {key = 'other-question', body = 'new', to = 'bob'})
  bob:call('messaging.send', {to = 'alice', body = 'answer', key = 'reply-arrival', reply_to = q.id})
  expect(unread('bob')).to_equal({other.id})
  expect(notice('bob').pending).to_be(true)
  bob:call('messaging.send', {to = 'alice', body = 'last answer', key = 'reply-last', reply_to = other.id})
  expect(unread('bob')).to_equal({})
  expect(notice('bob').pending, 'a reply clears the notice when no mail is unread').to_be(false)
end)

test('a self-reply leaves its new message pending', function()
  local self = bob:call('messaging.send', {key = 'self-question', body = 'note', to = 'bob'})
  local r = bob:call('messaging.send', {to = 'bob', body = 'self answer', key = 'self-reply', reply_to = self.id})
  expect(unread('bob')).to_equal({r.id})
  expect(notice('bob').pending).to_be(true)
end)

test('cursors beyond the exact float range still order arrivals', function()
  sql_write('UPDATE clock SET n = 9007199254740992')
  alice:call('messaging.send', {key = 'large-rev-1', body = 'one', to = 'bob'})
  local large = bob:call('messaging.read', {thread = 'alice'})
  expect(large.next_cursor).to_be('9007199254740993')
  local last = alice:call('messaging.send', {key = 'large-rev-2', body = 'two', to = 'bob'})
  local after = bob:call('messaging.read', {thread = 'alice', since = large.next_cursor})
  local got = {}
  for _, m in ipairs(after.messages) do got[#got + 1] = m.id end
  expect(got).to_equal({last.id})
  expect(after.messages[1].cursor).to_be('9007199254740994')
  expect_error(function() bob:call('messaging.read', {since = '1e3'}) end, 'since')
end)

-- A hub error keeps its code. A definite failure ends a view send; only a transient code
-- (unavailable, disconnected, timeout, or no code) is retried by the hub.
test('a definite commit failure ends a view send; a transient one is retried', function()
  alice:call('messaging.send', {to = 'user', body = 'Code check', key = 'code-hello'})
  local v = user:open('thread/alice')
  v:render()
  local function send_with(key, spec)
    local saved = v:draft('composer', 'Code check ' .. key, H.node(v:render(), 'composer').draft_revision or '0', key .. '-draft')
    expect(saved.status, 'draft ' .. key).to_be('succeeded')
    spec.match = {sql_commit_writes = 'messages'}
    return with_injection(spec, 1, function() return v:send('composer', 'Code check ' .. key, saved.result.draft_revision, key) end)
  end
  local definite = send_with('code-definite', {fail = 'Definite refusal'})
  expect(definite.status, 'a definite code is not retried').to_be('failed')
  expect(definite.error.message).to_match('Definite refusal')
  local transient = send_with('code-transient', {fail = 'Transient failure', fail_code = 'unavailable'})
  expect(transient.status, 'the hub retried a transient code').to_be('succeeded')
end)
