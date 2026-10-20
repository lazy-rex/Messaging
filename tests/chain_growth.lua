-- F1 growth (docs/f-thread-tail.md, "Tests"): a thread grows to 2000 messages with IDs of about
-- 85 bytes (a live ID is about 80). Without the chain, the thread record passed the request limit
-- at about 780 messages. The recipient acknowledges as the thread grows, so the mailbox stays
-- small (mailbox growth is F2). Every send must commit: a request over the limit is invalid_input.

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

local alice, bob = agent('alice'), agent('bob')

test('a thread grows to 2000 messages; every send commits; the chain keeps every ID', function()
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
  local key = tail_key('alice', 'bob')
  local tail = store(key).value
  local ids = {}
  for k = 0, tail.seg - 1 do
    local seg = store(seg_key(key, tail.chain or '0', k)).value.ids
    expect(size_of(seg) <= 8192, 'segment ' .. k .. ' fits the target').to_be(true)
    for _, id in ipairs(seg) do ids[#ids + 1] = id end
  end
  for _, id in ipairs(tail.ids) do ids[#ids + 1] = id end
  expect(size_of(tail.ids) <= 8192, 'the tail fits the target').to_be(true)
  expect(tail.frozen).to_be(#ids - #tail.ids)
  expect(#ids).to_be(2000)
  expect(ids, 'every ID once, in send order').to_equal(sent)
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
end)
