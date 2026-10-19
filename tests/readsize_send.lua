-- Size admission of new messages (LazyRex docs/rex-protocol.md, "Rex Lua runtime"). What this
-- plugin sends is at most 64 KiB in one control message. A send's batch carries the body twice
-- (the record and the operation fingerprint), so the body limit is 16384 encoded bytes; the whole
-- batch request is measured too, and one that can never fit is invalid_input. Sizes count encoded
-- JSON as the hub's Go encoder writes it.

local function part(s) return #s .. ':' .. s end
local function box(name) return 'mailbox/' .. part(name) end
local alice, bob = agent('alice'), agent('bob')
local budget = 49152
local limit = 16384

-- The six content classes and their encoded sizes in a JSON string.
local classes = {
  {'ascii', 'a', 1}, {'lt', '<', 6}, {'e-acute', '\195\169', 2}, {'u2028', '\226\128\168', 6},
  {'ctl-01', '\1', 6}, {'quote-backslash', '"\\', 4},
}

-- body_of returns a body of exactly n encoded bytes: copies of unit, then ASCII padding.
local function body_of(unit, size, n)
  local k = math.floor(n / size)
  return string.rep(unit, k) .. string.rep('a', n - k * size)
end

-- read_all reads every page of agent's unread mail; it checks each page against the budget.
local function read_all(a)
  local out, since = {}, '0'
  for _ = 1, 50 do
    local page = a:call('messaging.read', {since = since})
    expect(#rex.json.encode(page) <= budget, 'a read page is within the budget').to_be(true)
    for _, m in ipairs(page.messages or {}) do out[m.id] = m end
    if not page.more then return out end
    since = page.next_cursor
  end
  error('read did not finish')
end

test('each content class has the size that the hub stores (Go encoding)', function()
  for _, c in ipairs(classes) do
    local n = math.floor(52000 / c[3])
    local key = 'size/' .. c[1]
    write({{key = key, value = {text = string.rep(c[2], n)}}})
    local out = H.hub('hub.test.store', {plugin = 'messaging', keys = {key}})
    local big = out.too_large and out.too_large[key]
    expect(big, c[1] .. ' is reported by size').to_be_truthy()
    expect(big.bytes, c[1]).to_be(#'{"text":""}' + n * c[3])
  end
end)

local sent = {}
test('agent send: a body of exactly 16384 encoded bytes is accepted; one byte more is refused', function()
  for _, c in ipairs(classes) do
    local body = body_of(c[2], c[3], limit)
    local r = alice:call('messaging.send', {to = 'bob', body = body, key = 'body-' .. c[1]})
    sent[r.id] = body
    local over = 'over-' .. c[1]
    expect_error(function() alice:call('messaging.send', {to = 'bob', body = body .. 'a', key = over}) end,
      'body is 16385 bytes encoded; the limit is 16384')
    expect(store('message/send/' .. part('alice') .. part(over)).rev, 'a refused send writes nothing').to_be('0')
  end
end)

test('the accepted bodies read back in full', function()
  local got = read_all(bob)
  for id, body in pairs(sent) do
    expect(got[id], 'message ' .. id).to_be_truthy()
    expect(got[id].body == body, 'the body of ' .. id .. ' is complete').to_be(true)
    expect(got[id].truncated).to_be(nil)
  end
  local ids = {}
  for id in pairs(sent) do ids[#ids + 1] = id end
  bob:call('messaging.ack', {ids = ids})
end)

test('view send: the same limit, counted the same way, for every class', function()
  local v = user:open('thread/bob')
  v:render()
  local rev = '0'
  for _, c in ipairs(classes) do
    local body = body_of(c[2], c[3], limit)
    local saved = v:draft('composer', body, rev, 'draft-' .. c[1])
    expect(saved.status, c[1] .. ' draft: ' .. rex.json.encode(saved.error or {})).to_be('succeeded')
    local op = v:send('composer', body, saved.result.draft_revision, 'view-' .. c[1])
    expect(op.status, c[1] .. ' at the limit').to_be('succeeded')
    local over = body .. 'a'
    saved = v:draft('composer', over, op.result.draft_revision, 'draft-over-' .. c[1])
    local draft_before = store('draft/' .. part('user') .. part('bob'))
    op = v:send('composer', over, saved.result.draft_revision, 'view-over-' .. c[1])
    expect(op.status, c[1] .. ' over the limit').to_be('failed')
    expect(op.error.code).to_be('invalid_input')
    expect(op.error.message).to_match('body is 16385 bytes encoded; the limit is 16384')
    expect(store('draft/' .. part('user') .. part('bob')), 'a refused send keeps the draft').to_equal(draft_before)
    rev = saved.result.draft_revision
  end
end)

test('key and reply_to limits are raw bytes', function()
  alice:call('messaging.send', {to = 'bob', body = 'k', key = string.rep('k', 200)})
  expect_error(function() alice:call('messaging.send', {to = 'bob', body = 'k', key = string.rep('k', 201)}) end, 'key is 201 bytes; the limit is 200')
  expect_error(function() alice:call('messaging.send', {to = 'bob', body = 'r', key = 'reply-513', reply_to = string.rep('r', 513)}) end,
    'reply_to is 513 bytes; the limit is 512')
  local ok, e = pcall(alice.call, alice, 'messaging.send', {to = 'bob', body = 'r', key = 'reply-512', reply_to = string.rep('r', 512)})
  expect(ok).to_be(false)
  expect(tostring(e.message or e):find('limit is 512', 1, true), 'a 512-byte reply_to passes the size check').to_be(nil)
end)

test('a stored operation replays before the new limits, on both paths', function()
  local key = string.rep('x', 300)
  local body = string.rep('b', 20000)
  local id = 'send/' .. part('alice') .. part(key)
  put_operation({key = id, fingerprint = 'send-v2/' .. part('bob') .. part(body) .. part(''), result = {id = id, key = key}})
  expect(alice:call('messaging.send', {to = 'bob', body = body, key = key})).to_equal({id = id, key = key})
  local view_id = 'send/' .. part('user') .. part('view-replay')
  local result = {message_id = view_id, cleared_draft_revision = '7'}
  put_operation({key = view_id, fingerprint = 'view-send-v1/' .. part('/thread/bob') .. part('7') .. part(body), result = result})
  local v = user:open('thread/bob')
  v:render()
  local op = v:send('composer', body, '7', 'view-replay')
  expect(op.status).to_be('succeeded')
  expect(op.result.message_id).to_be(view_id)
end)

test('a body that fits but a batch that cannot: invalid_input, and nothing is written', function()
  -- A legacy mailbox of about 50 KB: the send batch must rewrite it, so it can never fit.
  local unread = {}
  for i = 1, 600 do unread['legacy/' .. i .. '/' .. string.rep('u', 80)] = true end
  write({{key = box('bob'), value = {ids = unread}}})
  local mailbox_before = store(box('bob'))
  local key = 'big-mailbox'
  local body = string.rep('h', 3000) -- within the body limit; the batch carries it twice
  local ok, e = pcall(alice.call, alice, 'messaging.send', {to = 'bob', body = body, key = key})
  expect(ok).to_be(false)
  expect(e.code).to_be('invalid_input')
  expect(e.message).to_match('hub.store.batch request is %d+ bytes encoded')
  local id = 'send/' .. part('alice') .. part(key)
  expect(store('message/' .. id).rev, 'no message').to_be('0')
  expect(store(box('bob')), 'the mailbox is unchanged').to_equal(mailbox_before)
  -- No operation result was stored: after the mailbox shrinks, the same key with another body is
  -- a new send, not a conflict with a stored one.
  write({{key = box('bob'), value = {ids = {}}}})
  expect(alice:call('messaging.send', {to = 'bob', body = 'hello again', key = key}).id).to_be(id)
  write({{key = box('bob'), value = {ids = unread}}})
  -- The view path: the draft stays, and the operation fails with the same code.
  local v = user:open('thread/bob')
  v:render()
  local saved = v:draft('composer', body, store('draft/' .. part('user') .. part('bob')).rev, 'draft-big-mailbox')
  local draft_before = store('draft/' .. part('user') .. part('bob'))
  local op = v:send('composer', body, saved.result.draft_revision, 'view-big-mailbox')
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('invalid_input')
  expect(store('draft/' .. part('user') .. part('bob')), 'the draft is not cleared').to_equal(draft_before)
  expect(store('message/send/' .. part('user') .. part('view-big-mailbox')).rev, 'no message').to_be('0')
end)

local charlie = agent('charlie')
test('a membership notice cuts a long thread title to fit, and the new member reads it in full', function()
  local gid = alice:call('messaging.thread_create', {members = {'bob', 'user'}, key = 'notice-title'}).id
  expect(gid:sub(1, 2)).to_be('g-')
  write({{key = 'thread-title/' .. part('alice') .. part(gid), value = {title = string.rep('T', 60000)}}})
  alice:call('messaging.thread_members', {thread = gid, members = {'bob', 'charlie', 'user'}, key = 'add-charlie'})
  local page = charlie:call('messaging.read', {thread = gid})
  expect(#rex.json.encode(page) <= budget).to_be(true)
  local notice = page.messages[1]
  expect(notice.id).to_match('^member%-notice/')
  expect(notice.truncated).to_be(nil)
  expect(notice.body:sub(1, 22)).to_be('You were added to TTTT')
  expect(notice.body).to_match('…%. Read earlier messages with messaging%.history%.$')
  expect(#notice.body <= limit, 'the notice keeps the body limit').to_be(true)
  expect(#notice.body > limit - 100, 'the title is cut only as much as needed').to_be(true)
end)

test('a membership change whose notice cannot fit is refused, and nothing is written', function()
  local gid = 'g-' .. string.rep('n', 25000)
  local groups = store('groups').value.groups
  groups[gid] = {name = 'Long legacy group', members = {'alice', 'bob'}}
  write({{key = 'groups', value = {groups = groups}}})
  local before = store('groups')
  local box_before = store(box('charlie'))
  local ok, e = pcall(alice.call, alice, 'messaging.thread_members', {thread = gid, members = {'bob', 'charlie'}, key = 'add-to-long'})
  expect(ok).to_be(false)
  expect(e.code).to_be('invalid_input')
  expect(store('groups'), 'membership is unchanged').to_equal(before)
  expect(store(box('charlie')), 'no notice was delivered').to_equal(box_before)
end)
