-- Size admission of new messages (LazyRex docs/rex-protocol.md, "Rex Lua runtime"). What this
-- plugin sends is at most 64 KiB in one control message. A send carries the body in two SQL
-- requests (the message insert and the operation fingerprint), so the body limit is 16384 encoded
-- bytes. No request depends on mailbox, group or thread size. Sizes count encoded JSON as the
-- hub's Go encoder writes it.

local function part(s) return #s .. ':' .. s end
local function message(id) return sql('SELECT seq FROM messages WHERE id = ?', {id})[1] end
local function draft_of(viewer, peer)
  return sql('SELECT text, CAST(rev AS TEXT) AS rev FROM drafts WHERE viewer = ? AND peer = ?', {viewer, peer})[1]
end
local function revision() return sql('SELECT CAST(n AS TEXT) AS n FROM clock')[1].n end
-- write_sql runs sql_write; while the plugin holds a transaction, it waits.
local function write_sql(q, p)
  local out = wait('a SQL fixture write', function()
    local ok, r = pcall(sql_write, q, p)
    if ok then return {r} end
    local text = type(r) == 'table' and tostring(r.code) .. ': ' .. tostring(r.message) or tostring(r)
    if not text:find('busy', 1, true) then return {nil, r} end -- another error: no retry
  end)
  if out[2] ~= nil then error(out[2], 0) end
  return out[1]
end
local function save_operation(key, owner, fingerprint, result)
  write_sql('INSERT INTO operations (key, owner, fingerprint, result) VALUES (?, ?, ?, ?)', {key, owner, fingerprint, rex.json.encode(result)})
end
-- put_group writes a created group from before the size rules.
local function put_group(gid, name, members)
  write_sql('INSERT INTO groups (gid, name) VALUES (?, ?)', {gid, name})
  for pos, m in ipairs(members) do
    write_sql('INSERT INTO group_members (gid, agent, pos, current) VALUES (?, ?, ?, 1)', {gid, m, pos})
  end
end
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

test('each content class has the size that the hub encodes (Go encoding)', function()
  -- The hub encodes the reply of an agent call; call_short gives its size in bytes. Two reads of
  -- one message each differ only in the body: n units of the class against n ASCII bytes. The
  -- keys have one length, and the clock starts at 1000 so that every cursor has four digits.
  write_sql('UPDATE clock SET n = 1000')
  local function read_bytes(body, key)
    local sent = alice:call('messaging.send', {to = bob.id, body = body, key = key})
    local out = bob:call_short('messaging.read', {})
    bob:call('messaging.ack', {ids = {sent.id}})
    return out.bytes
  end
  for _, c in ipairs(classes) do
    local n = math.floor(12000 / c[3])
    local plain = read_bytes(string.rep('a', n), 'p-' .. c[1])
    local coded = read_bytes(string.rep(c[2], n), 'c-' .. c[1])
    expect(coded - plain, c[1]).to_be(n * (c[3] - 1))
  end
end)

local sent = {}
test('agent send: a body of exactly 16384 encoded bytes is accepted; one byte more is refused', function()
  for _, c in ipairs(classes) do
    local body = body_of(c[2], c[3], limit)
    local r = alice:call('messaging.send', {to = bob.id, body = body, key = 'body-' .. c[1]})
    sent[r.id] = body
    local over = 'over-' .. c[1]
    expect_error(function() alice:call('messaging.send', {to = bob.id, body = body .. 'a', key = over}) end,
      'body is 16385 bytes encoded; the limit is 16384')
    expect(message('send/' .. part(alice.id) .. part(over)), 'a refused send writes nothing').to_be(nil)
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
  local v = user:open('thread/' .. bob.id)
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
    local draft_before = draft_of('user', bob.id)
    op = v:send('composer', over, saved.result.draft_revision, 'view-over-' .. c[1])
    expect(op.status, c[1] .. ' over the limit').to_be('failed')
    expect(op.error.code).to_be('invalid_input')
    expect(op.error.message).to_match('body is 16385 bytes encoded; the limit is 16384')
    expect(draft_of('user', bob.id), 'a refused send keeps the draft').to_equal(draft_before)
    rev = saved.result.draft_revision
  end
end)

test('key and reply_to limits are raw bytes', function()
  alice:call('messaging.send', {to = bob.id, body = 'k', key = string.rep('k', 200)})
  expect_error(function() alice:call('messaging.send', {to = bob.id, body = 'k', key = string.rep('k', 201)}) end, 'key is 201 bytes; the limit is 200')
  expect_error(function() alice:call('messaging.send', {to = bob.id, body = 'r', key = 'reply-513', reply_to = string.rep('r', 513)}) end,
    'reply_to is 513 bytes; the limit is 512')
  local ok, e = pcall(alice.call, alice, 'messaging.send', {to = bob.id, body = 'r', key = 'reply-512', reply_to = string.rep('r', 512)})
  expect(ok).to_be(false)
  expect(tostring(e.message or e):find('limit is 512', 1, true), 'a 512-byte reply_to passes the size check').to_be(nil)
end)

test('a stored operation replays before the new limits, on both paths', function()
  local key = string.rep('x', 300)
  local body = string.rep('b', 20000)
  local id = 'send/' .. part(alice.id) .. part(key)
  save_operation(id, alice.id, 'send-v2/' .. part(bob.id) .. part(body) .. part(''), {id = id, key = key})
  expect(alice:call('messaging.send', {to = bob.id, body = body, key = key})).to_equal({id = id, key = key})
  local view_id = 'send/' .. part('user') .. part('view-replay')
  local result = {message_id = view_id, cleared_draft_revision = '7'}
  save_operation(view_id, 'user', 'view-send-v1/' .. part('/thread/' .. bob.id) .. part('7') .. part(body), result)
  local v = user:open('thread/' .. bob.id)
  v:render()
  local op = v:send('composer', body, '7', 'view-replay')
  expect(op.status).to_be('succeeded')
  expect(op.result.message_id).to_be(view_id)
end)

-- The key-value version rewrote the whole mailbox in each send batch, so a large backlog made every
-- send fail (the All Teams defect). In SQL, a send writes one delivery row for each recipient.
test('a large unread backlog does not block a send, on both paths', function()
  local before = tonumber(revision())
  write_sql([[INSERT INTO messages (seq, id, sender, recipient, thread_a, thread_b, body, at)
    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 600)
    SELECT (SELECT c.n FROM clock c) + i, 'legacy/' || i || '/' || ?, ?, ?, ?, ?, 'old', '2026-01-01T00:00:00Z' FROM n]],
    {string.rep('u', 80), alice.id, bob.id, alice.id, bob.id})
  write_sql('UPDATE clock SET n = n + 600')
  write_sql([[INSERT INTO deliveries (agent, seq, acked) SELECT ?, seq, 0 FROM messages WHERE id LIKE 'legacy/%']], {bob.id})
  expect(tonumber(revision())).to_be(before + 600)
  local body = string.rep('h', 3000)
  local sent = alice:call('messaging.send', {to = bob.id, body = body, key = 'big-mailbox'})
  expect(message(sent.id), 'the send committed').to_be_truthy()
  local v = user:open('thread/' .. bob.id)
  v:render()
  local current = draft_of('user', bob.id)
  local saved = v:draft('composer', body, current and current.rev or '0', 'draft-big-mailbox')
  local op = v:send('composer', body, saved.result.draft_revision, 'view-big-mailbox')
  expect(op.status).to_be('succeeded')
  expect(message('send/' .. part('user') .. part('view-big-mailbox'))).to_be_truthy()
  write_sql([[UPDATE deliveries SET acked = 1 WHERE agent = ? AND seq IN (SELECT seq FROM messages WHERE id LIKE 'legacy/%')]], {bob.id})
end)

local charlie = agent('charlie')
test('a membership notice cuts a long thread title to fit, and the new member reads it in full', function()
  local gid = alice:call('messaging.thread_create', {members = {bob.id, 'user'}, key = 'notice-title'}).id
  expect(gid:sub(1, 2)).to_be('g-')
  write_sql('INSERT INTO thread_titles (viewer, peer, title, set_rev) VALUES (?, ?, ?, (SELECT n FROM clock))', {alice.id, gid, string.rep('T', 60000)})
  alice:call('messaging.thread_members', {thread = gid, members = {bob.id, charlie.id, 'user'}, key = 'add-charlie'})
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
  put_group(gid, 'Long legacy group', {alice.id, bob.id})
  local members = 'SELECT agent, pos, current FROM group_members WHERE gid = ? ORDER BY agent'
  local before = sql(members, {gid})
  local mail = "SELECT count(*) AS n FROM deliveries WHERE agent = ?"
  local box_before = sql(mail, {charlie.id})[1].n
  local ok, e = pcall(alice.call, alice, 'messaging.thread_members', {thread = gid, members = {bob.id, charlie.id}, key = 'add-to-long'})
  expect(ok).to_be(false)
  expect(e.code).to_be('invalid_input')
  expect(sql(members, {gid}), 'membership is unchanged').to_equal(before)
  expect(sql(mail, {charlie.id})[1].n, 'no notice was delivered').to_be(box_before)
end)

test('a send to a legacy group with a long ID is refused by the page rule, before any write', function()
  -- admit runs before the writes: the read and history pages of this message would hold the
  -- group ID twice (to, and the history thread), over 49152 bytes even with a one-byte body.
  local gid = 'g-' .. string.rep('p', 25000)
  put_group(gid, 'Long legacy group', {alice.id, bob.id})
  local before = revision()
  local ok, e = pcall(alice.call, alice, 'messaging.send', {to = gid, body = 'x', key = 'page-rule'})
  expect(ok).to_be(false)
  expect(e.code).to_be('invalid_input')
  expect(e.message).to_match('The message does not fit one read page: %d+ bytes encoded, limit 49152')
  expect(revision(), 'nothing was written').to_be(before)
  expect(message('send/' .. part(alice.id) .. part('page-rule'))).to_be(nil)
end)
