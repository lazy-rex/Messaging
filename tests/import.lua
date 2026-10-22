-- The one-time import from the key-value store (docs/sql-storage.md revision 4, "Migration").
-- Each test writes key-value records as the key-value release wrote them, empties the SQL state
-- (rows, the import meta, the fence), and restarts the hub: the plugin then starts with data in
-- the key-value store and none in SQL, and imports it at start.

local function part(s) return #s .. ':' .. s end
local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')
local at = '2026-10-20T00:00:00Z'

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

local TABLES = {'deliveries', 'messages', 'group_members', 'groups', 'thread_homes', 'thread_titles', 'thread_opened',
  'thread_archived', 'drafts', 'operations', 'aliases_applied', 'gallery', 'import_source', 'import_ops', 'import_body'}
local function import_state() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value end

-- reimport empties the SQL state and the fence, and restarts the hub: the plugin imports the
-- key-value records at start. It returns when the import state is `want` (default done).
local function reimport(want)
  for _, t in ipairs(TABLES) do write_sql('DELETE FROM ' .. t) end
  write_sql("DELETE FROM meta WHERE key LIKE 'import%'")
  write({{key = 'sql-import', delete = true}})
  hub:restart()
  return wait('the import', function()
    if import_state() == (want or 'done') then return true end
    local e = sql("SELECT value FROM meta WHERE key = 'import_error'")[1]
    if e and not want then error('the import failed: ' .. e.value, 0) end
  end)
end

-- msg writes a message record as the key-value release did and returns its revision.
local function msg(id, from, to, body, extra)
  local v = {id = id, from = from, to = to, body = body, at = at}
  for k, x in pairs(extra or {}) do v[k] = x end
  write({{key = 'message/' .. id, value = v}})
  return store('message/' .. id).rev
end
local function chain(a, b, ids)
  if a ~= '' and b < a then local t = a; a = b; b = t end
  write({{key = 'thread/' .. part(a) .. part(b), value = {ids = ids}}})
end
local function box(agent_id, ids)
  local set = {}
  for _, id in ipairs(ids) do set[id] = true end
  write({{key = 'mailbox/' .. part(agent_id), value = {ids = set}}})
end
local function deliveries(id)
  local out = {}
  for _, r in ipairs(sql('SELECT d.agent, d.acked FROM deliveries d JOIN messages m ON m.seq = d.seq WHERE m.id = ? ORDER BY d.agent', {id})) do
    out[#out + 1] = r.agent .. '=' .. r.acked
  end
  return out
end

-- craft writes an import in progress, as a crash leaves it: the fence and the meta rows, no rows.
local function craft(meta_rows)
  for _, t in ipairs(TABLES) do write_sql('DELETE FROM ' .. t) end
  write_sql("DELETE FROM meta WHERE key LIKE 'import%'")
  for k, v in pairs(meta_rows) do write_sql('INSERT INTO meta (key, value) VALUES (?, ?)', {k, v}) end
end
local function meta(key) return (sql('SELECT value FROM meta WHERE key = ?', {key})[1] or {}).value end
local function wait_done(seconds)
  return wait('the import', function()
    if import_state() == 'done' then return true end
    local e = sql("SELECT value FROM meta WHERE key = 'import_error'")[1]
    if e then error('the import failed: ' .. e.value, 0) end
  end, seconds)
end

local revs = {}
test('a key-value store imports: messages, audiences, unread, threads, groups, viewer state, gallery, operations', function()
  revs.d1 = msg('kv/d1', 'alice', 'bob', 'direct one')
  revs.d2 = msg('kv/d2', 'bob', 'alice', 'direct two', {reply_to = 'kv/d1', reply_expected = false})
  chain('alice', 'bob', {'kv/d1', 'kv/d2'})
  write({{key = 'groups', value = {groups = {['g-kv'] = {name = 'KV group', members = {'alice', 'bob', 'user'}, past_members = {'charlie'}}}}}})
  revs.g1 = msg('kv/g1', 'alice', 'g-kv', 'to the group', {recipients = {'bob', 'user', 'charlie'}})
  -- No recipients: the delivery snapshot is the audience.
  revs.g2 = msg('kv/g2', 'bob', 'g-kv', 'snapshot')
  write({{key = 'delivery/' .. part('kv/g2'), value = {ids = {'alice', 'user'}}}})
  -- No recipients and no snapshot: today's fallback, the current members without the sender.
  revs.g3 = msg('kv/g3', 'alice', 'g-kv', 'fallback')
  chain('', 'g-kv', {'kv/g1', 'kv/g2', 'kv/g3'})
  box('bob', {'kv/d1', 'kv/g1'})
  box('user', {'kv/g3'})
  -- The home must be a real session: the hub attaches it to place the thread's tab.
  local home = session('kv-home')
  write({
    {key = 'thread-meta/' .. part('alice') .. part('user'), value = {home_session = home, moved = true, set_rev = '3'}},
    {key = 'thread-title/' .. part('user') .. part('g-kv'), value = {title = 'Imported title'}},
    {key = 'thread-open/' .. part('user') .. part('alice'), value = {opened = true}},
    {key = 'thread-archive/' .. part('user'), value = {ids = {['g-old'] = true}}},
    {key = 'draft/' .. part('user') .. part('g-kv'), value = {text = 'a saved draft'}},
    {key = 'gallery/state', value = {last = 'kv state'}},
  })
  put_operation({key = 'send/' .. part('alice') .. part('kv-key'), fingerprint = 'send-v2/' .. part('bob') .. part('direct one') .. part(''),
    result = {id = 'kv/d1', key = 'kv-key'}})
  local draft_rev = store('draft/' .. part('user') .. part('g-kv')).rev
  reimport()

  expect(deliveries('kv/d1')).to_equal({'bob=0'})
  expect(deliveries('kv/d2')).to_equal({'alice=1'})
  expect(deliveries('kv/g1')).to_equal({'bob=0', 'charlie=1', 'user=1'})
  expect(deliveries('kv/g2')).to_equal({'alice=1', 'user=1'})
  expect(deliveries('kv/g3')).to_equal({'bob=1', 'user=0'})
  local d2 = sql('SELECT CAST(seq AS TEXT) AS seq, reply_to, reply_expected, thread_a, thread_b FROM messages WHERE id = ?', {'kv/d2'})[1]
  expect(d2).to_equal({seq = revs.d2, reply_to = 'kv/d1', reply_expected = 0, thread_a = 'alice', thread_b = 'bob'})
  -- The cursor of an imported message is its key-value revision.
  local read = bob:call('messaging.read', {})
  expect(#read.messages).to_be(2)
  expect(read.messages[1].cursor).to_be(revs.d1)
  expect(sql("SELECT gid, agent, pos, current FROM group_members ORDER BY pos")).to_equal({
    {gid = 'g-kv', agent = 'alice', pos = 1, current = 1}, {gid = 'g-kv', agent = 'bob', pos = 2, current = 1},
    {gid = 'g-kv', agent = 'user', pos = 3, current = 1}, {gid = 'g-kv', agent = 'charlie', pos = 4, current = 0}})
  expect(sql('SELECT home_session, moved, CAST(set_rev AS TEXT) AS set_rev FROM thread_homes')).to_equal({{home_session = home, moved = 1, set_rev = '3'}})
  expect(sql('SELECT title FROM thread_titles')).to_equal({{title = 'Imported title'}})
  expect(sql('SELECT viewer, peer FROM thread_opened')).to_equal({{viewer = 'user', peer = 'alice'}})
  expect(sql('SELECT viewer, peer FROM thread_archived')).to_equal({{viewer = 'user', peer = 'g-old'}})
  expect(sql('SELECT text, CAST(rev AS TEXT) AS rev FROM drafts')).to_equal({{text = 'a saved draft', rev = draft_rev}})
  -- A draft_revision from before the cutover still matches.
  local v = user:open('thread/g-kv')
  v:render()
  expect(v:draft('composer', 'edited', draft_rev, 'kv-draft-edit').status).to_be('succeeded')
  -- A saved operation from before the cutover replays.
  expect(alice:call('messaging.send', {to = 'bob', body = 'direct one', key = 'kv-key'})).to_equal({id = 'kv/d1', key = 'kv-key'})
  -- The clock continues above every key-value revision.
  local sent = alice:call('messaging.send', {to = 'bob', body = 'after the cutover', key = 'after-cutover'})
  local seq = sql('SELECT CAST(seq AS TEXT) AS seq FROM messages WHERE id = ?', {sent.id})[1].seq
  expect(#seq > #store('sql-import').rev or seq > store('sql-import').rev, 'a new seq is above f1').to_be(true)
  expect(notice('bob').pending).to_be(true)
end)

test('a body larger than one request is imported in parts', function()
  local body = string.rep('<', 9000) .. string.rep('x', 5000) -- 59000 encoded bytes
  msg('kv/large', 'alice', 'charlie', body, {recipients = {'charlie'}})
  chain('alice', 'charlie', {'kv/large'})
  reimport()
  local r = sql('SELECT length(body) AS n, body = ? AS same FROM messages WHERE id = ?', {body, 'kv/large'})[1]
  expect(r).to_equal({n = #body, same = 1})
  expect(#sql('SELECT key FROM import_body')).to_be(0)
end)
-- body_of compares the imported body with the source byte for byte.
local function body_of(id, body)
  return sql('SELECT length(CAST(body AS BLOB)) AS n, CAST(body AS BLOB) = CAST(? AS BLOB) AS same FROM messages WHERE id = ?', {body, id})[1]
end

test('a chunked body with multibyte characters and a NUL byte is imported exactly', function()
  -- 2 bytes for each character: the byte offsets of the parts differ from the character counts.
  local body = string.rep('é', 25000) .. '\0' .. string.rep('ü', 5000)
  msg('kv/unicode', 'alice', 'charlie', body, {recipients = {'charlie'}})
  chain('alice', 'charlie', {'kv/large', 'kv/unicode'})
  reimport()
  expect(body_of('kv/unicode', body)).to_equal({n = #body, same = 1})
end)

test('an import that stopped between two parts of a body continues at its byte offset', function()
  local body = string.rep('é', 25000) .. '\0' .. string.rep('ü', 5000)
  -- The first message key: no other chunked body comes before it, so the saved offset is its own.
  msg('kv/0resume', 'alice', 'charlie', body, {recipients = {'charlie'}})
  chain('alice', 'charlie', {'kv/large', 'kv/unicode', 'kv/0resume'})
  write({{key = 'sql-import', value = {state = 'importing'}}})
  -- The state a crash leaves after the first part: 10000 bytes stored (5000 characters). The
  -- families before message/ run again, on empty tables.
  craft({import = 'importing', import_f0 = store('sql-import').rev, import_aliases = '{}', import_roster = '["alice","bob","charlie"]',
    import_progress = rex.json.encode({phase = 'families', family = 1, key = 'message/kv/0resume', offset = 10000})})
  write_sql('INSERT INTO import_body (key, body) VALUES (?, CAST(? AS BLOB))', {'message/kv/0resume', body:sub(1, 10000)})
  hub:restart()
  wait_done()
  expect(body_of('kv/0resume', body)).to_equal({n = #body, same = 1})
  expect(#sql('SELECT key FROM import_body')).to_be(0)
end)

test('a resumed import keeps the roster of its start for the team fallback', function()
  msg('kv/t1', 'alice', 'team', 'to the team')
  chain('', 'team', {'kv/t1'})
  write({{key = 'sql-import', value = {state = 'importing'}}})
  -- charlie, bob and the user are on the roster now; the import started when only alice and bob were.
  craft({import = 'importing', import_f0 = store('sql-import').rev, import_aliases = '{}', import_roster = '["alice","bob"]',
    import_progress = '{"phase":"families","family":1}'})
  hub:restart()
  wait_done()
  expect(deliveries('kv/t1')).to_equal({'bob=1'})
end)

test('a saved operation added after the verification resets the import', function()
  reimport()
  local f0 = meta('import_f0')
  put_operation({key = 'send/' .. part('bob') .. part('ops-late'), fingerprint = 'send-v2/' .. part('alice') .. part('late') .. part(''),
    result = {id = 'kv/late', key = 'ops-late'}})
  -- A crash after verified: an old release ran and saved one more operation, and no record changed.
  write_sql("UPDATE meta SET value = 'verified' WHERE key = 'import'")
  write({{key = 'sql-import', value = {state = 'importing'}}})
  hub:restart()
  wait_done()
  expect(meta('import_f0') ~= f0, 'the import began again').to_be(true)
  expect(#sql('SELECT key FROM operations WHERE key = ?', {'send/' .. part('bob') .. part('ops-late')})).to_be(1)
end)

test('a mailbox entry without a delivery stops the import, and every call is refused', function()
  box('charlie', {'kv/d1'}) -- kv/d1 went to bob only
  for _, t in ipairs(TABLES) do write_sql('DELETE FROM ' .. t) end
  write_sql("DELETE FROM meta WHERE key LIKE 'import%'")
  write({{key = 'sql-import', delete = true}})
  hub:restart()
  local e = wait('the import error', function() return sql("SELECT value FROM meta WHERE key = 'import_error'")[1] end)
  expect(e.value:find('migration_conflict', 1, true) ~= nil, e.value).to_be(true)
  expect_error(function() bob:call('messaging.read', {}) end, 'importing')
  write({{key = 'mailbox/' .. part('charlie'), delete = true}})
  reimport()
end)

local charlie_id = 'claude:conversation-charlie'
test('an alias in the hub maps every imported name to its identity; old operations and notices follow', function()
  charlie:report({kind = 'claude', conversation_id = 'conversation-charlie'})
  -- The key-value release moved mailboxes and threads to the identity; messages keep the old name.
  msg('kv/c1', 'charlie', 'bob', 'from charlie')
  msg('kv/c2', 'bob', 'charlie', 'to charlie')
  msg('kv/c3', 'bob', 'charlie', 'to the old name')
  chain(charlie_id, 'bob', {'kv/c1', 'kv/c2', 'kv/c3'})
  -- Two mailboxes meet under M: their unread sets merge.
  box(charlie_id, {'kv/c2'})
  box('charlie', {'kv/c3'})
  put_operation({key = 'send/' .. part('charlie') .. part('charlie-key'), fingerprint = 'send-v2/' .. part('bob') .. part('from charlie') .. part(''),
    result = {id = 'kv/c1', key = 'charlie-key'}})
  -- A notice from before the import: the import replaces SQL, and alice has no unread mail in it.
  bob:call('messaging.send', {to = 'alice', body = 'only in SQL', key = 'live-to-alice'})
  expect(notice('alice').pending).to_be(true)
  reimport()
  local m = sql('SELECT sender, recipient FROM messages WHERE id = ?', {'kv/c1'})[1]
  expect(m).to_equal({sender = charlie_id, recipient = 'bob'})
  expect(deliveries('kv/c2')).to_equal({charlie_id .. '=0'})
  expect(deliveries('kv/c3')).to_equal({charlie_id .. '=0'})
  expect(sql("SELECT identity FROM aliases_applied WHERE alias = 'charlie'")).to_equal({{identity = charlie_id}})
  -- A retry under the identity finds the operation saved under the alias.
  expect(charlie:call('messaging.send', {to = 'bob', body = 'from charlie', key = 'charlie-key'})).to_equal({id = 'kv/c1', key = 'charlie-key'})
  expect(notice('charlie').pending == true, 'no pending notice under the alias').to_be(false)
  expect(notice(charlie_id).pending).to_be(true)
  expect(notice('alice').pending, 'the cutover clears an agent with all mail acknowledged').to_be(false)
end)

test('two chains that meet under M and share an ID do not hide a message missing from both', function()
  msg('kv/x1', 'charlie', 'bob', 'in both chains')
  msg('kv/x2', charlie_id, 'bob', 'in no chain')
  chain(charlie_id, 'bob', {'kv/c1', 'kv/c2', 'kv/c3', 'kv/x1'})
  chain('charlie', 'bob', {'kv/x1'})
  -- The chain lengths add up to the five messages of the thread; the distinct IDs are four.
  reimport('importing')
  local e = wait('the import error', function() return sql("SELECT value FROM meta WHERE key = 'import_error'")[1] end)
  expect(e.value:find('A thread has another set of messages', 1, true) ~= nil, e.value).to_be(true)
  chain(charlie_id, 'bob', {'kv/c1', 'kv/c2', 'kv/c3', 'kv/x1', 'kv/x2'})
  reimport()
end)

test('a thread chain that changes after the verification resets the import', function()
  local f0 = meta('import_f0')
  write_sql("UPDATE meta SET value = 'verified' WHERE key = 'import'")
  chain('charlie', 'bob', {'kv/x1'}) -- the same IDs, a new revision
  write({{key = 'sql-import', value = {state = 'importing'}}})
  hub:restart()
  wait_done()
  expect(meta('import_f0') ~= f0, 'the import began again').to_be(true)
end)
test('an alias that appears after the verification merges at the cutover', function()
  local alice_id = 'claude:conversation-alice'
  msg('kv/a1', 'alice', 'bob', 'from alice')
  chain('alice', 'bob', {'kv/d1', 'kv/d2', 'kv/a1'})
  reimport()
  alice:report({kind = 'claude', conversation_id = 'conversation-alice'})
  wait('the merge of alice', function() return sql("SELECT 1 AS x FROM aliases_applied WHERE alias = 'alice'")[1] end)
  -- Back to the state of a crash after verified, before the alias: alice's rows under the old name.
  write_sql("UPDATE messages SET sender = 'alice', thread_a = 'alice', thread_b = 'bob' WHERE id = 'kv/a1'")
  write_sql("DELETE FROM aliases_applied WHERE alias = 'alice'")
  write_sql("UPDATE meta SET value = 'verified' WHERE key = 'import'")
  write({{key = 'sql-import', value = {state = 'importing'}}})
  hub:restart()
  wait_done()
  expect(sql('SELECT sender, thread_a, thread_b FROM messages WHERE id = ?', {'kv/a1'})[1]).to_equal({sender = alice_id, thread_a = 'bob', thread_b = alice_id})
  expect(sql("SELECT identity FROM aliases_applied WHERE alias = 'alice'")).to_equal({{identity = alice_id}})
end)

test('long IDs go into requests by byte size: 200 messages with 1000-byte IDs', function()
  -- Each record fits one request, as the key-value release wrote it: the chain is in segments of
  -- 50 IDs. A page of 200 keys or IDs is about 200 KB.
  local ids, ops = {}, {}
  for n = 1, 200 do
    local id = 'kv/long/' .. string.format('%03d', n) .. string.rep('i', 989)
    ids[n] = id
    ops[#ops + 1] = {key = 'message/' .. id, value = {id = id, from = 'bob', to = 'claude:conversation-alice', body = 'long ' .. n, at = at}}
    if #ops == 20 then write(ops); ops = {} end
  end
  -- alice has her identity since the test before; this chain is under the identity.
  local pair = part('bob') .. part('claude:conversation-alice')
  for k = 0, 3 do
    local seg = {}
    for n = k * 50 + 1, k * 50 + 50 do seg[#seg + 1] = ids[n] end
    write({{key = 'thread-seg/' .. pair .. '/0/' .. k, value = {ids = seg}}})
  end
  write({{key = 'thread/' .. pair, value = {ids = {}, seg = 4, chain = '0'}}})
  local unread = {}
  for n = 1, 40 do unread[n] = ids[n] end
  box('claude:conversation-alice', unread)
  reimport()
  expect(sql("SELECT count(*) AS n FROM messages WHERE id LIKE 'kv/long/%'")[1].n).to_be(200)
  expect(sql("SELECT count(*) AS n FROM deliveries d JOIN messages m ON m.seq = d.seq WHERE m.id LIKE 'kv/long/%' AND d.acked = 0")[1].n).to_be(40)
end)
test('values that need more than one request import exactly; nothing is refused for its size', function()
  -- A 50000-byte draft: under the record limit of the key-value release.
  local draft_key = 'draft/' .. part('user') .. part('bob')
  local draft_text = string.rep('d', 50000)
  -- A Gallery value of 20000 quotes: 40000 bytes in its record, about 80000 as a JSON text
  -- parameter (each quote is escaped twice). It goes into the insert in parts.
  local gallery_value = {text = string.rep('"', 20000)}
  -- IDs with quotes and backslashes: the batches count their encoding twice (the reviewer's case).
  local ids = {}
  for n = 1, 100 do ids[n] = 'kv/esc/' .. string.format('%03d', n) .. string.rep('"', 225) .. string.rep('\\', 225) end
  local ops = {}
  for n, id in ipairs(ids) do
    ops[#ops + 1] = {key = 'message/' .. id, value = {id = id, from = 'charlie', to = 'user', body = 'escaped ' .. n, at = at}}
    if #ops == 10 then write(ops); ops = {} end
  end
  local pair = part(charlie_id) .. part('user')
  for k = 0, 3 do
    local seg = {}
    for n = k * 25 + 1, k * 25 + 25 do seg[#seg + 1] = ids[n] end
    write({{key = 'thread-seg/' .. pair .. '/0/' .. k, value = {ids = seg}}})
  end
  write({{key = 'thread/' .. pair, value = {ids = {}, seg = 4, chain = '0'}}})
  -- One record in each write: each fits one request, as the key-value release wrote it.
  write({{key = draft_key, value = {text = draft_text}}})
  write({{key = 'gallery/escaped', value = gallery_value}})
  reimport()
  expect(sql('SELECT length(text) AS n, text = ? AS same FROM drafts WHERE viewer = ? AND peer = ?', {draft_text, 'user', 'bob'})[1])
    .to_equal({n = 50000, same = 1})
  local g = sql("SELECT value FROM gallery WHERE key = 'escaped'")[1]
  expect(rex.json.decode(g.value)).to_equal(gallery_value)
  expect(sql("SELECT count(*) AS n FROM messages WHERE id LIKE 'kv/esc/%'")[1].n).to_be(100)
  expect(#sql("SELECT key FROM import_body")).to_be(0)
end)
test('an orphan fence (a crash before the import began) begins a new import', function()
  write({{key = 'sql-import', value = {state = 'importing'}}})
  local orphan = store('sql-import').rev
  write_sql("DELETE FROM meta WHERE key LIKE 'import%'")
  hub:restart()
  wait_done()
  expect(meta('import_f0') ~= orphan, 'a new fence').to_be(true)
end)

test('a crash after the fence moved to cutover and before the SQL commit ends at that fence', function()
  -- The fence says cutover; SQL is still verified.
  write_sql("UPDATE meta SET value = 'verified' WHERE key = 'import'")
  write_sql("DELETE FROM meta WHERE key = 'import_f1'")
  write({{key = 'sql-import', value = {state = 'cutover'}}})
  local f1 = store('sql-import').rev
  hub:restart()
  wait_done()
  expect(meta('import_f1')).to_be(f1)
  expect(store('sql-import').rev, 'the fence is not written again').to_be(f1)
  expect(sql('SELECT CAST(n AS TEXT) AS n FROM clock')[1].n).to_be(f1)
end)

test('a restart after the cutover changes nothing', function()
  local f1, rev = meta('import_f1'), store('sql-import').rev
  hub:restart()
  wait_done()
  expect(meta('import_f1')).to_be(f1)
  expect(store('sql-import').rev).to_be(rev)
end)

test('an imported operation key replays only the same content, also under an alias', function()
  -- alice has her identity since an earlier test; kv-key was saved under her old name.
  expect(alice:call('messaging.send', {to = 'bob', body = 'direct one', key = 'kv-key'})).to_equal({id = 'kv/d1', key = 'kv-key'})
  expect_error(function() alice:call('messaging.send', {to = 'bob', body = 'other content', key = 'kv-key'}) end, 'different content')
end)

test('a late alias whose merge has a draft conflict keeps the import verified until the conflict goes', function()
  local bob_id = 'claude:conversation-bob'
  -- A crash after verified, with two different drafts of the user: one for bob, one for the
  -- identity that bob is about to get.
  write_sql([[INSERT INTO drafts (viewer, peer, text, rev) VALUES ('user', 'bob', 'draft for bob', 1)
    ON CONFLICT (viewer, peer) DO UPDATE SET text = excluded.text, rev = excluded.rev]])
  write_sql('INSERT INTO drafts (viewer, peer, text, rev) VALUES (?, ?, ?, 2)', {'user', bob_id, 'another draft'})
  write_sql("UPDATE meta SET value = 'verified' WHERE key = 'import'")
  write({{key = 'sql-import', value = {state = 'importing'}}})
  bob:report({kind = 'claude', conversation_id = 'conversation-bob'})
  hub:restart()
  local e = wait('the import error', function() return sql("SELECT value FROM meta WHERE key = 'import_error'")[1] end)
  expect(e.value:find('Two drafts have different text', 1, true) ~= nil, e.value).to_be(true)
  expect(import_state(), 'the cutover rolled back').to_be('verified')
  expect(sql("SELECT 1 AS x FROM aliases_applied WHERE alias = 'bob'")[1]).to_be(nil)
  -- The conflict goes (here: one draft is removed); the next start ends the cutover.
  write_sql('DELETE FROM drafts WHERE viewer = ? AND peer = ?', {'user', bob_id})
  hub:restart()
  wait_done()
  expect(sql("SELECT identity FROM aliases_applied WHERE alias = 'bob'")).to_equal({{identity = bob_id}})
  expect(sql('SELECT text FROM drafts WHERE viewer = ? AND peer = ?', {'user', bob_id})).to_equal({{text = 'draft for bob'}})
end)
-- A key-value store with 3000 messages: its import takes many steps.
local bulk = {}
local function write_bulk()
  if #bulk > 0 then return end
  local ops = {}
  for i = 1, 3000 do
    local id = string.format('kv/n%04d', i)
    bulk[i] = id
    ops[#ops + 1] = {key = 'message/' .. id, value = {id = id, from = 'bob', to = 'user', body = 'bulk ' .. i, at = at}}
    if #ops == 300 then write(ops); ops = {} end
  end
  -- The chain in 60 segments of 50 IDs, as the key-value release stored a long thread.
  local pair = part('bob') .. part('user')
  for k = 0, 59 do
    local seg = {}
    for n = k * 50 + 1, k * 50 + 50 do seg[#seg + 1] = bulk[n] end
    write({{key = 'thread-seg/' .. pair .. '/0/' .. k, value = {ids = seg}}})
  end
  write({{key = 'thread/' .. pair, value = {ids = {}, seg = 60, chain = '0'}}})
end
local function restart_empty()
  for _, t in ipairs(TABLES) do write_sql('DELETE FROM ' .. t) end
  write_sql("DELETE FROM meta WHERE key LIKE 'import%'")
  write({{key = 'sql-import', delete = true}})
  hub:restart()
end

test('every call during the import and its verification fails with unavailable at once', function()
  write_bulk()
  restart_empty()
  -- The plugin starts the import after its registration.
  wait('the import to start', function() return import_state() == 'importing' end)
  -- The import gives way to calls between its steps, also while it verifies the 60 segments of the
  -- chain; it does not hold a call until its end (a held call times out after 10 s).
  -- A table field, not a captured local: a change of a captured local in the wait callback is lost
  -- (the pcall rule, LazyRex docs/rex-protocol.md).
  local calls = {n = 0}
  wait('the import, with calls during it', function()
    local ok, err = pcall(bob.call, bob, 'messaging.read', {})
    calls.n = calls.n + 1
    if not ok then
      local text = type(err) == 'table' and tostring(err.code) .. ': ' .. tostring(err.message) or tostring(err)
      if not text:find('importing', 1, true) then error('a call during the import: ' .. text, 0) end
    end
    return import_state() == 'done' and ok
  end, 300)
  expect(calls.n > 1, 'calls ran during the import').to_be(true)
  expect(#bob:call('messaging.history', {thread = 'user', limit = 1}).messages).to_be(1)
end)

test('an import that the hub kill stops in the middle of the messages continues', function()
  write_bulk()
  restart_empty()
  wait('the import in the middle of the messages', function()
    local p = rex.json.decode(meta('import_progress') or '{}')
    return p.phase == 'families' and p.family == 3 and p.after ~= nil
  end)
  local f0 = meta('import_f0')
  hub:restart({crash = true})
  wait_done(300)
  expect(meta('import_f0'), 'the import continued').to_be(f0)
  expect(sql("SELECT count(*) AS n FROM messages WHERE id LIKE 'kv/n%'")[1].n).to_be(3000)
end)
