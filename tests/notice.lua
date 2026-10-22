-- Notice v2 (hub contract; SDK app.notice once and app.notice_read): the notices that each commit
-- of the plugin gives the hub, as the hub received them (hub.test.calls).

-- Every call fails with unavailable until the import at start is done (import.lua). Under load,
-- the start can end before it; the tests begin after it.
wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

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

test('a failed read leaves no notice for a later alias merge to flush', function()
  -- The reviewer's case: the read fails after it marked its agent; the merge that follows (alice
  -- gets an identity) must not give bob's read in its own commit.
  alice:call('messaging.send', {to = 'bob', body = 'unread mail', key = 'rollback-notice'})
  local _, base = calls('none')
  expect_error(function() bob:call('messaging.read', {thread = 'g-missing'}) end, 'Unknown thread')
  alice:report({kind = 'claude', conversation_id = 'rollback-notice-alice'})
  wait('the alias merge', function() return sql("SELECT identity FROM aliases_applied WHERE alias = 'alice'")[1] end)
  local reads = 0
  for _, c in ipairs(calls('hub.sql.commit', {after = base.next})) do
    for _, n in ipairs(c.args.notices or {}) do
      if n.agent == 'bob' and n.read then reads = reads + 1 end
    end
  end
  expect(reads, 'a failed read records no read in another commit').to_be(0)
end)

test('an alias that appears during reads merges in a commit of its own; the read keeps its own notice', function()
  -- The report lands at a time that the test does not control: before, during or after a read.
  -- The handler never merges, so wherever it lands, a commit with a read notice has no other
  -- notice, and the merge commit gives the identity pending.
  local charlie, identity = agent('charlie'), 'claude:conversation-race'
  local _, base = calls('none')
  alice:call('messaging.send', {to = 'charlie', body = 'before the identity', key = 'race-1'})
  charlie:report_async('race', {kind = 'claude', conversation_id = 'conversation-race'}, 20)
  for _ = 1, 20 do charlie:call('messaging.read', {}) end
  expect(charlie:report_result('race').error).to_be(nil)
  charlie:call('messaging.read', {})
  local merged = false
  for _, c in ipairs(calls('hub.sql.commit', {after = base.next})) do
    local n = c.args.notices or {}
    for _, x in ipairs(n) do
      if x.read then expect(#n, 'a read notice shares no commit').to_be(1) end
      if x.agent == identity and x.pending then merged = true end
    end
  end
  expect(merged, 'the merge gives the identity pending').to_be(true)
  expect(sql("SELECT identity FROM aliases_applied WHERE alias = 'charlie'")).to_equal({{identity = identity}})
  -- The last read is recorded: new mail nudges again.
  local before = notice(identity).intent_rev
  alice:call('messaging.send', {to = identity, body = 'after the read', key = 'race-2'})
  expect(notice(identity).intent_rev ~= before, 'new mail after the read needs a new notice revision').to_be(true)
end)
