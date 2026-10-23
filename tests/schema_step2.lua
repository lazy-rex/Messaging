-- Schema step 2 (4.3): the tables of the removed key-value import (import_source, import_ops,
-- import_body) and meta go, and so do saved operations in a fingerprint format that no handler
-- writes now. Every other row stays. A file of its own: it restarts the hub.

local alice, bob = agent('alice'), agent('bob')

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

local function tables()
  local out = {}
  for _, r in ipairs(sql("SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'import%' OR name = 'meta') ORDER BY name")) do
    out[#out + 1] = r.name
  end
  return out
end
local function operations()
  return sql('SELECT key, owner, fingerprint, result FROM operations ORDER BY key')
end

test('a new database is at version 2, with no import tables and no meta', function()
  alice:call('messaging.read', {})
  expect(sql('PRAGMA user_version')[1].user_version).to_be(2)
  expect(tables()).to_equal({})
end)

test('a start of a database at version 1 drops the import tables and meta, and only the old operations', function()
  -- One saved operation of each format that a handler writes now.
  alice:call('messaging.send', {to = bob.id, body = 'kept', key = 'step2-send'})
  local g = alice:call('messaging.thread_create', {key = 'step2-group', title = 'Step 2', members = {bob.id, 'user'}})
  alice:call('messaging.thread_rename', {thread = g.id, title = 'Renamed', key = 'step2-rename'})
  alice:call('messaging.thread_members', {thread = g.id, members = {bob.id, 'user'}, key = 'step2-members'})
  alice:call('messaging.thread_move', {thread = g.id, session_id = session('Step 2 home'), key = 'step2-move'})
  alice:call('messaging.thread_archive', {thread = g.id, key = 'step2-archive'})
  local v = user:open('thread/' .. bob.id)
  v:render()
  local saved = v:draft('composer', 'from the view', '0', 'step2-draft')
  expect(v:send('composer', 'from the view', saved.result.draft_revision, 'step2-view-send').status).to_be('succeeded')
  local kept = operations()
  local prefixes = {}
  for _, r in ipairs(kept) do prefixes[#prefixes + 1] = r.fingerprint:match('^([^/]+)/') end
  table.sort(prefixes)
  expect(prefixes, 'one row of each current format').to_equal({'draft-v1', 'send-v2', 'thread-archive-v1',
    'thread-create-session-v1', 'thread-members-v1', 'thread-move-v1', 'thread-rename-v1', 'view-send-v1'})
  -- The database as a store at version 1 has it: the import tables, meta, and rows of old formats.
  for _, q in ipairs({
    'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    "INSERT INTO meta (key, value) VALUES ('import', 'done')",
    'CREATE TABLE import_source (key TEXT PRIMARY KEY, rev TEXT NOT NULL, complete INTEGER NOT NULL)',
    "INSERT INTO import_source (key, rev, complete) VALUES ('mailbox/alice', '7', 1)",
    'CREATE TABLE import_ops (key TEXT PRIMARY KEY)',
    'CREATE TABLE import_body (key TEXT PRIMARY KEY, body BLOB NOT NULL)',
    [[INSERT INTO operations (key, owner, fingerprint, result) VALUES
      ('thread-create/old-1', 'user', 'thread-create-v1/0:5:alice4:user', '{}'),
      ('history-load/old-2', 'user', 'history-load-v1/5:alice', '{}'),
      ('send/old-3', 'alice', 'send-v1/3:bob2:hi', '{}'),
      ('old-4', 'alice', 'no separator', '{}')]],
    'PRAGMA user_version = 1',
  }) do write_sql(q) end
  hub:restart()
  alice:call('messaging.read', {})
  expect(sql('PRAGMA user_version')[1].user_version).to_be(2)
  expect(tables(), 'the import tables and meta are gone').to_equal({})
  expect(operations(), 'every current row stays; every old row goes').to_equal(kept)
  -- A kept row still replays.
  expect(alice:call('messaging.thread_rename', {thread = g.id, title = 'Renamed', key = 'step2-rename'})).to_equal({title = 'Renamed'})
end)
