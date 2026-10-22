-- The first messages of the key-value store predate its thread index: no chain names them
-- (observed on the live store, 2026-10-22: 62 such messages, all older than every chained
-- message). The import keeps them: a message in no chain is imported if it is older than every
-- chained message (import.lua, threads_task). Any other message in no chain stops the import, and
-- the import does not cut over. A file of its own: it needs messages older than every chain.

wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

local function part(s) return #s .. ':' .. s end
local bob = agent('bob')
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

-- restart empties the SQL state and the fence, and restarts the hub: the plugin imports the
-- key-value records at start.
local function restart()
  for _, t in ipairs(TABLES) do write_sql('DELETE FROM ' .. t) end
  write_sql("DELETE FROM meta WHERE key LIKE 'import%'")
  write({{key = 'sql-import', delete = true}})
  hub:restart()
end
local function reimport()
  restart()
  wait('the import', function()
    if import_state() == 'done' then return true end
    local e = sql("SELECT value FROM meta WHERE key = 'import_error'")[1]
    if e then error('the import failed: ' .. e.value, 0) end
  end)
end
-- refused restarts the import and expects it to stop at the thread check of thread k.
local function refused(k)
  restart()
  local e = wait('the import error', function() return sql("SELECT value FROM meta WHERE key = 'import_error'")[1] end)
  expect(e.value:find('A thread has another set of messages', 1, true) ~= nil, e.value).to_be(true)
  if k then expect(e.value:find(k, 1, true) ~= nil, e.value).to_be(true) end
  expect(import_state() ~= 'done', 'the import does not cut over').to_be(true)
  expect_error(function() bob:call('messaging.read', {}) end, 'importing')
end

local function msg(id, from, to, body)
  write({{key = 'message/' .. id, value = {id = id, from = from, to = to, body = body, at = at}}})
end
local function chain(a, b, ids)
  if b < a then local t = a; a = b; b = t end
  write({{key = 'thread/' .. part(a) .. part(b), value = {ids = ids}}})
end
local function ids()
  local out = {}
  for _, r in ipairs(sql('SELECT id FROM messages ORDER BY seq')) do out[#out + 1] = r.id end
  return table.concat(out, ' ')
end

test('messages older than every chained message are imported without a chain', function()
  msg('kv/p1', 'alice', 'bob', 'before the index')
  msg('kv/p2', 'bob', 'charlie', 'before the index, in a thread with no chain')
  msg('kv/c1', 'alice', 'bob', 'first chained')
  msg('kv/c2', 'bob', 'alice', 'second chained')
  chain('alice', 'bob', {'kv/c1', 'kv/c2'})
  reimport()
  expect(ids()).to_be('kv/p1 kv/p2 kv/c1 kv/c2')
  local seen = {}
  for _, m in ipairs(bob:call('messaging.history', {thread = 'alice'}).messages) do seen[#seen + 1] = m.id end
  expect(table.concat(seen, ' '), 'newest first').to_be('kv/c2 kv/c1 kv/p1')
end)

test('a message in no chain that is newer than the first chained message stops the import', function()
  -- kv/n1 is older than the first chained message of its own thread, but not of every thread.
  msg('kv/n1', 'alice', 'charlie', 'after the index')
  msg('kv/n2', 'charlie', 'alice', 'chained')
  chain('alice', 'charlie', {'kv/n2'})
  refused(part('alice') .. part('charlie'))
  chain('alice', 'charlie', {'kv/n1', 'kv/n2'})
  reimport()
end)

test('a message in no chain that is newer than every chained message stops the import', function()
  msg('kv/n3', 'alice', 'bob', 'after every chain')
  refused(part('alice') .. part('bob'))
  chain('alice', 'bob', {'kv/c1', 'kv/c2', 'kv/n3'})
  reimport()
end)

test('with no chain at all, every message must be in a chain', function()
  write({{key = 'thread/' .. part('alice') .. part('bob'), delete = true},
    {key = 'thread/' .. part('alice') .. part('charlie'), delete = true}})
  refused()
  chain('alice', 'bob', {'kv/c1', 'kv/c2', 'kv/n3'})
  chain('alice', 'charlie', {'kv/n1', 'kv/n2'})
  reimport()
end)
