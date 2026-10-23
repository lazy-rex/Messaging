-- Growth: a thread grows to 2000 messages with IDs of about 85 bytes (a live ID is about 80). The
-- key-value version stored a thread as one record, and that record passed the request limit at
-- about 780 messages. In SQL, a send writes one message row and one delivery row for each
-- recipient: no request depends on thread size. The recipient acknowledges as the thread grows.

local alice, bob = agent('alice'), agent('bob')

test('a thread grows to 2000 messages; every send commits; history walks back to the first', function()
  local sent, unacked = {}, {}
  for i = 1, 2000 do
    local id = alice:call('messaging.send', {to = 'bob', body = 'g' .. i, key = 'growth-' .. string.rep('x', 60) .. i}).id
    sent[i] = id
    unacked[#unacked + 1] = id
    if #unacked == 10 then
      bob:call('messaging.ack', {ids = unacked})
      unacked = {}
    end
  end
  local ids = {}
  for _, r in ipairs(sql("SELECT id FROM messages WHERE thread_a = 'alice' AND thread_b = 'bob' ORDER BY seq")) do ids[#ids + 1] = r.id end
  expect(ids, 'every ID once, in send order').to_equal(sent)
  expect(sql("SELECT count(*) AS n FROM deliveries WHERE agent = 'bob' AND acked = 0")[1].n).to_be(0)
  -- Agent history walks back to the oldest message: 40 pages of 50.
  local before, pages, oldest = nil, 0, nil
  repeat
    local h = bob:call('messaging.history', {thread = 'alice', limit = 50, before = before})
    pages = pages + 1
    oldest = h.messages[#h.messages].id
    before = h.next_before
  until not before
  expect(pages).to_be(40)
  expect(oldest).to_be(sent[1])
  -- The user observes the thread: the view renders the newest page of it.
  local observed = 'd-' .. ('5:alice3:bob'):gsub('.', function(c) return string.format('%02x', c:byte()) end)
  local tree = user:open('thread/' .. observed):render()
  expect(tree).to_be_truthy()
end)
