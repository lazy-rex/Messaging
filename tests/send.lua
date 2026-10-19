-- Ported from the Node test messaging.mjs (coverage map: commit eaaf529): the send, read and ack contract, replies, and injected mailbox
-- races. Agents call through the agent face (the MCP path) unless a test says otherwise.

local function part(s) return #s .. ':' .. s end
local function box(name) return 'mailbox/' .. part(name) end
local function ids_of(name)
  local r = store(box(name))
  local out = {}
  for id in pairs(r.value and r.value.ids or {}) do out[#out + 1] = id end
  table.sort(out)
  return out
end
local function sorted(t) table.sort(t); return t end
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
  original = store('message/' .. first.id)
  local before = batches()
  expect(alice:call('messaging.send', {key = 'a/:é', body = body, to = 'bob'})).to_equal(first)
  expect(batches(), 'a saved operation does not write or notify again').to_be(before)
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
  local after = batches()
  bob:call('messaging.ack', {ids = {first.id}})
  bob:call_raw('messaging.ack', '{"ids":[]}')
  expect(batches(), 'a repeated or empty ack does not write').to_be(after)
  expect(notice('bob').pending).to_be(false)
  expect_error(function() alice:call('messaging.ack', {ids = {first.id}}) end, 'Unknown message')
  -- A definite refusal, not 'unavailable': a retry cannot help.
  local e = expect_error(function() alice:call('messaging.send', {key = 'bad-recipient', body = 'hello', to = 'nobody'}) end, 'Unknown recipient')
  expect(tostring(e)).to_match('invalid_input')
end)

test('a caller outside every pane is refused', function()
  expect_error(function() H.perform(plugin_client(), 'messaging.read', {}) end, 'does not recognize')
end)

local third
test('a mailbox conflict retry keeps the concurrent entry', function()
  write({{key = 'message/injected-message', value = {id = 'injected-message', from = 'alice', to = 'bob', body = 'concurrent', at = '2026-01-01T00:00:00Z'}}})
  local current = store(box('bob')).value.ids
  current['injected-message'] = true
  with_injection({match = {writes = box('bob')}, ops = {{key = box('bob'), value = {ids = current}}}}, 1, function()
    third = alice:call('messaging.send', {key = 'conflict-once', body = 'hello', to = 'bob'})
  end)
  expect(ids_of('bob')).to_equal(sorted({'injected-message', third.id}))
end)

test('a send during an ack keeps its entry and its notice', function()
  local ids = {['injected-message'] = true, [third.id] = true, ['arrived-during-ack'] = true}
  with_injection({match = {writes = box('bob')}, ops = {
    {key = 'message/arrived-during-ack', value = {id = 'arrived-during-ack', from = 'alice', to = 'bob', body = 'race', at = '2026-01-01T00:00:01Z'}},
    {key = box('bob'), value = {ids = ids}},
    {notify = {agent = 'bob', pending = true}},
  }}, 1, function()
    bob:call('messaging.ack', {ids = {'injected-message', third.id}})
  end)
  expect(ids_of('bob')).to_equal({'arrived-during-ack'})
  expect(notice('bob').pending).to_be(true)
  expect(store('message/' .. first.id), 'retries and acks keep message data').to_equal(original)
end)

test('the retry budget is bounded and saves no operation', function()
  local before = batches()
  local current = store(box('bob')).value
  with_injection({match = {writes = box('bob')}, ops = {{key = box('bob'), value = current}}, times = 4}, 4, function()
    expect_error(function() alice:call('messaging.send', {key = 'conflict-always', body = 'hello', to = 'bob'}) end, 'retry with the same send key')
  end)
  expect(batches() - before).to_be(4)
  expect(store('message/send/' .. part('alice') .. part('conflict-always')).rev).to_be('0')
  -- No operation was saved: the same key commits now, with a new message.
  local later = alice:call('messaging.send', {key = 'conflict-always', body = 'hello', to = 'bob'})
  expect(later.id).to_be('send/' .. part('alice') .. part('conflict-always'))
  expect(store('message/' .. later.id).value.body).to_be('hello')
end)

test('a batch that another invocation already committed returns the saved result', function()
  local replay
  with_injection({match = {op_key = 'send/' .. part('alice') .. part('committed-before-batch')}, replay = true}, 1, function()
    replay = alice:call('messaging.send', {key = 'committed-before-batch', body = 'hello', to = 'bob'})
  end)
  expect(replay.id).to_be('send/' .. part('alice') .. part('committed-before-batch'))
end)

test('a reply acknowledges only its question; invalid replies write nothing', function()
  local question = alice:call('messaging.send', {key = 'reply-question', body = 'hello', to = 'bob'})
  local args = {to = 'alice', body = 'answer', key = 'reply-answer', reply_to = question.id}
  local reply = bob:call('messaging.send', args)
  expect(store(box('bob')).value.ids[question.id]).to_be(nil)
  expect(store(box('alice')).value.ids[reply.id]).to_be(true)
  expect(store('message/' .. reply.id).value.reply_to).to_be(question.id)
  local after = batches()
  expect(bob:call('messaging.send', args)).to_equal(reply)
  expect(batches(), 'a reply replay changes neither mailbox nor notice').to_be(after)
  expect_error(function() bob:call('messaging.send', {to = 'alice', body = 'answer', key = 'reply-answer', reply_to = first.id}) end, 'different content')
  local before = batches()
  expect_error(function() bob:call('messaging.send', {to = 'alice', body = 'answer', key = 'foreign-reply', reply_to = second.id}) end, 'reply_to must name')
  expect_error(function() bob:call('messaging.send', {to = 'alice', body = 'answer', key = 'missing-reply', reply_to = 'missing'}) end, 'reply_to must name')
  expect_error(function() bob:call('messaging.send', {to = 'bob', body = 'answer', key = 'wrong-recipient', reply_to = question.id}) end, 'reply_to must name')
  expect(batches(), 'invalid replies do not write').to_be(before)
end)

test('an ack between the mailbox read and the reply commit forces one safe retry', function()
  local q = alice:call('messaging.send', {key = 'reply-race-question', body = 'hello', to = 'bob'})
  local ids = store(box('bob')).value.ids
  ids[q.id] = nil
  local before = batches()
  with_injection({match = {writes = box('bob')}, ops = {{key = box('bob'), value = {ids = ids}}}}, 1, function()
    bob:call('messaging.send', {to = 'alice', body = 'raced answer', key = 'reply-race', reply_to = q.id})
  end)
  expect(batches() - before, 'the reply retries once after a concurrent ack').to_be(2)
  expect(store(box('bob')).value.ids[q.id]).to_be(nil)
end)

test('a new message during a reply keeps the notice; the last reply clears it', function()
  local q = alice:call('messaging.send', {key = 'last-question', body = 'hello', to = 'bob'})
  local others = {}
  for _, id in ipairs(ids_of('bob')) do if id ~= q.id then others[#others + 1] = id end end
  bob:call('messaging.ack', {ids = others})
  with_injection({match = {op_key = 'send/' .. part('bob') .. part('reply-arrival')}, ops = {
    {key = 'message/arrived-during-reply', value = {id = 'arrived-during-reply', from = 'alice', to = 'bob', body = 'new', at = '2026-01-01T00:00:02Z'}},
    {key = box('bob'), value = {ids = {[q.id] = true, ['arrived-during-reply'] = true}}},
    {notify = {agent = 'bob', pending = true}},
  }}, 1, function()
    bob:call('messaging.send', {to = 'alice', body = 'answer with race', key = 'reply-arrival', reply_to = q.id})
  end)
  expect(ids_of('bob')).to_equal({'arrived-during-reply'})
  expect(notice('bob').pending).to_be(true)
  bob:call('messaging.send', {to = 'alice', body = 'last answer', key = 'reply-last', reply_to = 'arrived-during-reply'})
  expect(ids_of('bob')).to_equal({})
  expect(notice('bob').pending, 'a reply clears the notice when the mailbox becomes empty').to_be(false)
end)

test('a self-reply leaves its new message pending', function()
  local self = bob:call('messaging.send', {key = 'self-question', body = 'note', to = 'bob'})
  local r = bob:call('messaging.send', {to = 'bob', body = 'self answer', key = 'self-reply', reply_to = self.id})
  expect(ids_of('bob')).to_equal({r.id})
  expect(notice('bob').pending).to_be(true)
end)

test('revisions beyond the exact float range still order arrivals', function()
  advance_rev('9007199254740992')
  alice:call('messaging.send', {key = 'large-rev-1', body = 'one', to = 'bob'})
  local large = bob:call('messaging.read', {thread = 'alice'})
  local last = alice:call('messaging.send', {key = 'large-rev-2', body = 'two', to = 'bob'})
  local after = bob:call('messaging.read', {thread = 'alice', since = large.next_cursor})
  local got = {}
  for _, m in ipairs(after.messages) do got[#got + 1] = m.id end
  expect(got).to_equal({last.id})
  expect_error(function() bob:call('messaging.read', {since = '1e3'}) end, 'since')
end)
