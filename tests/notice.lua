-- Notice v2 (hub contract; SDK app.notice once and app.notice_read): the notices that each commit
-- of the plugin gives the hub, as the hub received them (hub.test.calls).

local alice, bob = agent('alice'), agent('bob')

-- notices runs fn and returns the notices of the plugin's commits during it, in order.
local function notices(fn)
  local _, base = calls('none')
  fn()
  local out = {}
  for _, c in ipairs(calls('hub.sql.commit', {after = base.next})) do
    for _, n in ipairs(c.args.notices or {}) do out[#out + 1] = n end
  end
  return out
end

test('new mail nudges once; a read with unread mail records the read; no unread mail is not pending', function()
  local sent
  expect(notices(function() sent = alice:call('messaging.send', {to = 'bob', body = 'one', key = 'n1'}) end))
    .to_equal({{agent = 'bob', pending = true, once = true}})
  expect(notice('bob').pending).to_be(true)
  -- bob reads; the message stays unread until the ack.
  expect(notices(function() bob:call('messaging.read', {}) end)).to_equal({{agent = 'bob', read = true}})
  expect(notice('bob').pending, 'a read does not change pending').to_be(true)
  expect(notices(function() bob:call('messaging.ack', {ids = {sent.id}}) end)).to_equal({{agent = 'bob', pending = false}})
  expect(notice('bob').pending).to_be(false)
  expect(notices(function() bob:call('messaging.read', {}) end)).to_equal({{agent = 'bob', pending = false}})
end)

test('a reply names its sender once: the ack of the answered message and the new mail of the peer', function()
  local first = alice:call('messaging.send', {to = 'bob', body = 'question', key = 'n2'})
  -- bob answers: his copy of the question is acked (bob: no unread), and alice gets new mail.
  local got = notices(function() bob:call('messaging.send', {to = 'alice', body = 'answer', key = 'n3', reply_to = first.id}) end)
  table.sort(got, function(a, b) return a.agent < b.agent end)
  expect(got).to_equal({{agent = 'alice', pending = true, once = true}, {agent = 'bob', pending = false}})
end)

test('a failed read leaves no read notice for a later commit', function()
  -- The reviewer's case: the read fails after it marked its agent; the next commit (a send of
  -- alice) must not give bob's read.
  alice:call('messaging.send', {to = 'bob', body = 'unread mail', key = 'rollback-notice'})
  local _, base = calls('none')
  expect_error(function() bob:call('messaging.read', {thread = 'g-missing'}) end, 'Unknown thread')
  alice:call('messaging.send', {to = 'user', body = 'a later commit', key = 'rollback-notice-later'})
  local reads = 0
  for _, c in ipairs(calls('hub.sql.commit', {after = base.next})) do
    for _, n in ipairs(c.args.notices or {}) do
      if n.agent == 'bob' and n.read then reads = reads + 1 end
    end
  end
  expect(reads, 'a failed read records no read in another commit').to_be(0)
end)
