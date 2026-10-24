-- Peer hubs (federation v1, hub docs/hub.md "Peer hubs") on one lab hub. The manifest sets
-- test.hub_name "lab" and one peer "away" that cannot be reached: hub.peer.send queues there.
-- H.peer_deliver gives an envelope to Messaging through the hub's real delivery path. The SDK
-- (app.peer) keeps the outbox and sends after the reply, so a test waits for the hub to take an
-- envelope. One sequence: each test uses the state of the tests before it.

local alice = agent('alice')

local function envelope(fields)
  local e = {v = 1, id = 'm1', from = 'bob', to = alice.id, body = 'hello from away', at = '2026-10-23T21:00:00Z'}
  for k, v in pairs(fields or {}) do e[k] = v end
  return e
end
local function deliver(e, key)
  return H.peer_deliver({from_hub = 'away', key = key or e.id, body = rex.json.encode(e)}).reply
end
-- queued returns the envelopes that hub.peer.send holds for the peer "away", decoded. The pull
-- does not ack: after = 0.
local function queued()
  local out = {}
  for _, e in ipairs(H.hub('hub.peer.pull', {hub = 'away', after = 0}).envelopes or {}) do
    out[#out + 1] = rex.json.decode(e.body)
  end
  return out
end
local function count(sql_text, params) return #sql(sql_text, params) end
-- taken waits until the hub holds n envelopes for "away" and the SDK marks n rows sent (a later
-- transaction than the hub's insert).
local function taken(n)
  wait('the hub takes ' .. n .. ' envelopes', function()
    return H.peer_status().peers[1].outbox == n and count("SELECT 1 AS x FROM sdk_peer_outbox WHERE state = 'sent'") == n
  end)
end

local first, first_args
test('a send to <id>@away stores the message with no delivery and queues one envelope', function()
  first_args = {to = 'bob@away', body = 'hello, bob', key = 'peer-first'}
  first = alice:call('messaging.send', first_args)
  expect(sql('SELECT recipient FROM messages WHERE id = ?', {first.id})[1].recipient).to_be('bob@away')
  expect(count('SELECT 1 AS x FROM deliveries d JOIN messages m ON m.seq = d.seq WHERE m.id = ?', {first.id}), 'no local delivery').to_be(0)
  taken(1)
  local e = queued()[1]
  expect({e.v, e.id, e.from, e.to, e.body}).to_equal({1, first.id, alice.id, 'bob', 'hello, bob'})
end)

test('a retry of the send replays and queues nothing more', function()
  expect(alice:call('messaging.send', first_args)).to_equal(first)
  expect(H.peer_status().peers[1].outbox).to_be(1)
end)

local got_id
test('an envelope from away reaches the local agent as <from>@away', function()
  expect(deliver(envelope())).to_equal({})
  local read = alice:call('messaging.read', {})
  expect(#read.messages).to_be(1)
  local m = read.messages[1]
  got_id = m.id
  expect({m.from, m.to, m.body}).to_equal({'bob@away', alice.id, 'hello from away'})
  expect(got_id:sub(1, 5)).to_be('peer/')
end)

test('a repeat of the envelope changes nothing', function()
  expect(deliver(envelope())).to_equal({})
  expect(count('SELECT 1 AS x FROM messages WHERE id = ?', {got_id})).to_be(1)
  expect(#alice:call('messaging.read', {}).messages).to_be(1)
end)

test('a reply to a peer message names the origin ID in its envelope', function()
  local r = alice:call('messaging.send', {to = 'bob@away', body = 'got it', key = 'peer-reply', reply_to = got_id})
  taken(2)
  local e = queued()
  expect(#e).to_be(2)
  expect(e[2].id).to_be(r.id)
  expect(e[2].reply_to, 'the ID on away').to_be('m1')
  expect(#alice:call('messaging.read', {}).messages, 'the reply acks the message').to_be(0)
end)

test('envelopes that can never be stored are refused for good', function()
  local cases = {
    {envelope({id = 'm2', to = 'nobody-here'}), 'unknown_recipient'},
    {envelope({id = 'm3', to = 'team'}), 'unknown_recipient'},
    {envelope({id = 'm4', v = 2}), 'invalid_envelope'},
    {envelope({id = 'm5', body = ''}), 'invalid_envelope'},
  }
  for _, c in ipairs(cases) do
    expect(deliver(c[1]).refused, c[1].id).to_be(c[2])
  end
  expect(deliver(envelope({id = 'm6'}), 'other-key').refused, 'key is not the ID').to_be('invalid_envelope')
  expect(H.peer_deliver({from_hub = 'away', key = 'm7', body = 'not json'}).reply.refused).to_be('invalid_envelope')
  expect(count("SELECT 1 AS x FROM messages WHERE sender = 'bob@away'"), 'none stored').to_be(1)
end)

test('an FYI envelope keeps reply_expected = false', function()
  expect(deliver(envelope({id = 'm9', body = 'for your information', reply_expected = false}))).to_equal({})
  local read = alice:call('messaging.read', {})
  expect(#read.messages).to_be(1)
  expect(read.messages[1].reply_expected).to_be(false)
  alice:call('messaging.ack', {ids = {read.messages[1].id}})
end)

test('an envelope with a body at the limit is stored; one byte more is refused', function()
  expect(deliver(envelope({id = 'm10', body = string.rep('x', 16384), reply_to = got_id}))).to_equal({})
  local m = sql("SELECT reply_to FROM messages WHERE id = ?", {'peer/4:away3:m10'})
  expect(#m).to_be(1)
  expect(m[1].reply_to, 'the reply_to of this hub is kept').to_be(got_id)
  expect(deliver(envelope({id = 'm11', body = string.rep('x', 16385)})).refused).to_be('too_large')
  expect(count("SELECT 1 AS x FROM messages WHERE id = 'peer/4:away3:m11'")).to_be(0)
end)

test('a failed commit is not processed, and the next delivery stores the message once', function()
  local failing = inject({match = {sql_commit_writes = 'messages'}, fail = 'Injected receive failure', fail_code = 'unavailable', times = 1})
  expect_error(function() deliver(envelope({id = 'm8', body = 'after a failure'})) end, 'not_processed')
  expect(injection(failing).consumed).to_be(1)
  expect(count("SELECT 1 AS x FROM messages WHERE body = 'after a failure'"), 'rolled back').to_be(0)
  expect(deliver(envelope({id = 'm8', body = 'after a failure'}))).to_equal({})
  expect(count("SELECT 1 AS x FROM messages WHERE body = 'after a failure'")).to_be(1)
end)

test('Messaging splits <id>@<hub> itself: this hub is local, a peer stays as given, another hub is refused', function()
  local carol = agent('carol')
  local m = alice:call('messaging.send', {to = carol.id .. '@lab', body = 'to this hub', key = 'peer-self'})
  expect(sql('SELECT recipient FROM messages WHERE id = ?', {m.id})[1].recipient, 'the local ID').to_be(carol.id)
  expect(#carol:call('messaging.read', {}).messages).to_be(1)
  local before = count('SELECT 1 AS x FROM messages')
  expect_error(function() alice:call('messaging.send', {to = 'bob@nowhere', body = 'lost', key = 'peer-nowhere'}) end, 'not a configured peer hub')
  expect(count('SELECT 1 AS x FROM messages'), 'nothing stored').to_be(before)
end)

test('a remote correspondent is a thread of the agent, with its hub in the title', function()
  local found
  for _, t in ipairs(alice:call('messaging.thread_list', {}).threads) do if t.id == 'bob@away' then found = t end end
  expect(found ~= nil, 'bob@away is in the thread list').to_be(true)
  expect({found.title, found.group}).to_equal({'bob@away', false})
  expect(#alice:call('messaging.history', {thread = 'bob@away'}).messages > 0).to_be(true)
end)

test('the user opens the thread of a remote sender; its tab names the hub', function()
  local from = 'claude:0123456789abcdef'
  expect(deliver(envelope({id = 'm20', from = from, to = 'user', body = 'to the user from away'}))).to_equal({})
  local id = from .. '@away'
  user:open('thread/' .. id):render()
  local t = wait('the tab of the remote thread', function() return tab('thread/' .. id) end)
  expect(t.title, 'the short ID and the hub').to_match('^claude:01234567@away')
end)

-- Groups across hubs. This hub is "lab"; "away" is the peer.
local gina, hal = agent('gina'), agent('hal')
local function last_queued() local e = queued(); return e[#e] end
local home_gid

test('a group with members on away: local members get it here, away gets one envelope with the group', function()
  home_gid = gina:call('messaging.thread_create', {members = {hal.id, 'bob@away', 'zed@away'}, title = 'Both hubs', key = 'xg-create'}).id
  local before = #queued()
  local m = gina:call('messaging.send', {to = home_gid, body = 'hello both hubs', key = 'xg-1'})
  expect(#hal:call('messaging.read', {}).messages, 'hal here').to_be(1)
  wait('away gets one envelope', function() return #queued() == before + 1 end)
  local e = last_queued()
  expect({e.id, e.from, e.to, e.group.name}).to_equal({m.id, gina.id, home_gid, 'Both hubs'})
  table.sort(e.group.members)
  local want = {gina.id, hal.id, 'bob@away', 'zed@away'}
  table.sort(want)
  expect(e.group.members).to_equal(want)
  expect(count("SELECT 1 AS x FROM deliveries WHERE agent LIKE '%@%'"), 'no local delivery for a remote member').to_be(0)
end)

test('a member on away sends to the group here: local members get it once, and it fans out to away', function()
  local before = #queued()
  expect(deliver(envelope({id = 'bm1', from = 'bob', to = home_gid, body = 'from bob on away'}))).to_equal({})
  for _, a in ipairs({gina, hal}) do
    local got = a:call('messaging.read', {thread = home_gid}).messages
    expect(got[#got].from, a.name).to_be('bob@away')
  end
  wait('the fan-out to away (zed is there)', function() return #queued() == before + 1 end)
  local e = last_queued()
  expect({e.from, e.to, e.origin.hub, e.origin.id}).to_equal({'bob@away', home_gid, 'away', 'bm1'})
  expect(deliver(envelope({id = 'bm2', from = 'mallory', to = home_gid})).refused, 'not a member').to_be('unknown_recipient')
end)

test('a group of away: this hub keeps a mirror; its members get the message once', function()
  local e = envelope({id = 'am1', from = 'dave', to = 'g-away1', body = 'from the away group',
    group = {name = 'Away group', members = {'dave', gina.id .. '@lab', hal.id .. '@lab', 'erin@other'}}})
  expect(deliver(e)).to_equal({})
  local got = gina:call('messaging.read', {thread = 'g-away1@away'}).messages
  expect({got[#got].from, got[#got].to}).to_equal({'dave@away', 'g-away1@away'})
  local mirror
  for _, t in ipairs(gina:call('messaging.thread_list', {}).threads) do if t.id == 'g-away1@away' then mirror = t end end
  expect({mirror.title, mirror.group}).to_equal({'Away group', true})
  table.sort(mirror.members)
  local want = {'dave@away', gina.id, hal.id, 'erin@other'}
  table.sort(want)
  expect(mirror.members).to_equal(want)
end)

local mirror_send
test('a send to the mirror goes to the home hub only; the fan-out back adds the deliveries here', function()
  local before = #queued()
  mirror_send = gina:call('messaging.send', {to = 'g-away1@away', body = 'gina to the away group', key = 'xg-2'})
  wait('one envelope to away', function() return #queued() == before + 1 end)
  local e = last_queued()
  expect({e.to, e.from, e.group}).to_equal({'g-away1', gina.id, nil})
  expect(count('SELECT 1 AS x FROM deliveries d JOIN messages m ON m.seq = d.seq WHERE m.id = ?', {mirror_send.id}), 'no delivery before the home').to_be(0)
  -- The home hub fans it out to this hub, with origin = this hub and the first ID.
  expect(deliver(envelope({id = 'peer/3:lab' .. #mirror_send.id .. ':' .. mirror_send.id, from = gina.id .. '@lab', to = 'g-away1',
    body = 'gina to the away group', origin = {hub = 'lab', id = mirror_send.id},
    group = {name = 'Away group', members = {'dave', gina.id .. '@lab', hal.id .. '@lab', 'erin@other'}}}))).to_equal({})
  expect(count("SELECT 1 AS x FROM messages WHERE body = 'gina to the away group'"), 'one copy').to_be(1)
  local got = hal:call('messaging.read', {thread = 'g-away1@away'}).messages
  expect(got[#got].id, 'hal gets the first copy').to_be(mirror_send.id)
end)

test('a mirror cannot change its members here', function()
  expect_error(function() gina:call('messaging.thread_members', {thread = 'g-away1@away', members = {hal.id}, key = 'xg-members'}) end, 'home hub')
end)

test('a direct thread with a remote agent grows into a group with the remote member', function()
  local r = alice:call('messaging.thread_members', {thread = 'bob@away', members = {'bob@away', hal.id}, key = 'xg-grow'})
  expect(r.group).to_be(true)
  local want = {alice.id, hal.id, 'bob@away'}
  table.sort(want)
  table.sort(r.members)
  expect(r.members).to_equal(want)
end)
