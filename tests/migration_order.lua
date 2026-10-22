-- Identity migrations that run one at a time (each agent reports its own conversation).
-- - Inherited homes (legacy, canonical, carried): the first home wins. A carried home keeps the
--   revision at which it was set (set_rev), so a later migration still sees its age.
-- - An explicit move (moved = true) is the newest intent: it wins over inherited homes, and it
--   stays selected in later migrations.
-- Two direct threads: alice-bob has no move; bob-charlie gets a move between the migrations.

local a_id, b_id, c_id = 'claude:conversation-a', 'codex:conversation-b', 'claude:conversation-c'
local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')

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
-- home returns the thread_homes row of the direct thread of a and b, or nil.
local function home(a, b)
  if b < a then local t = a; a = b; b = t end -- not a, b = b, a: wrong in Rex Lua (rex-protocol.md)
  return sql('SELECT home_session, moved, CAST(set_rev AS TEXT) AS set_rev FROM thread_homes WHERE thread_a = ? AND thread_b = ?', {a, b})[1]
end
local function title(viewer, peer)
  return sql('SELECT title, CAST(set_rev AS TEXT) AS set_rev FROM thread_titles WHERE viewer = ? AND peer = ?', {viewer, peer})[1]
end
-- A fixture row takes a new revision of the clock, as a plugin write does.
local function put_home(a, b, session)
  if b < a then local t = a; a = b; b = t end
  write_sql('UPDATE clock SET n = n + 1')
  write_sql('INSERT INTO thread_homes (thread_a, thread_b, home_session, moved, set_rev) VALUES (?, ?, ?, 0, (SELECT n FROM clock))', {a, b, session})
end
local function put_title(viewer, peer, text)
  write_sql('UPDATE clock SET n = n + 1')
  write_sql('INSERT INTO thread_titles (viewer, peer, title, set_rev) VALUES (?, ?, ?, (SELECT n FROM clock))', {viewer, peer, text})
end
local function migrated(name)
  return wait('the migration of ' .. name, function()
    if sql('SELECT 1 AS x FROM aliases_applied WHERE alias = ?', {name})[1] then return true end
  end)
end
-- Thread homes are real sessions: the hub places a tab in its home.
local homes = {ab_first = session('ab first'), bc_first = session('bc first'), ab_later = session('ab later'), bc_later = session('bc later')}
local moved_to

test('the first migrations carry the legacy homes with their age', function()
  put_home('alice', 'bob', homes.ab_first)
  put_home('bob', 'charlie', homes.bc_first)
  put_title('bob', 'alice', 'Legacy title')
  local ab_rev, bc_rev = home('alice', 'bob').set_rev, home('bob', 'charlie').set_rev
  put_home(a_id, b_id, homes.ab_later)
  put_home(b_id, c_id, homes.bc_later)
  put_title(a_id, b_id, 'Canonical A')
  -- Two-alias titles: an owner renames a peer before either identity exists.
  alice:call('messaging.thread_rename', {thread = 'bob', title = 'Alice legacy', key = 'alice-legacy'})
  charlie:call('messaging.thread_rename', {thread = 'bob', title = 'Charlie legacy', key = 'charlie-legacy'})
  -- A canonical title set after charlie's legacy rename, before the migrations: the newest.
  put_title(c_id, b_id, 'Canonical C')
  alice:report({kind = 'claude', conversation_id = 'conversation-a'})
  migrated('alice')
  charlie:report({kind = 'claude', conversation_id = 'conversation-c'})
  migrated('charlie')
  local ab = home(a_id, 'bob')
  expect(ab.home_session).to_be(homes.ab_first)
  expect(ab.set_rev, 'a carried home keeps its first revision').to_be(ab_rev)
  local bc = home('bob', c_id)
  expect(bc.home_session).to_be(homes.bc_first)
  expect(bc.set_rev).to_be(bc_rev)
  expect(title(a_id, 'bob').title, 'the owner migration carries the title').to_be('Alice legacy')
  expect(title(c_id, 'bob').title).to_be('Charlie legacy')
end)

test('an explicit move between the migrations is marked as a move', function()
  moved_to = session('Moved home')
  expect(charlie:call('messaging.thread_move', {thread = 'bob', session_id = moved_to, key = 'move-before-bob'}).moved).to_be(true)
  local bc = home('bob', c_id)
  expect(bc.home_session).to_be(moved_to)
  expect(bc.moved).to_be(1)
  alice:call('messaging.thread_rename', {thread = 'bob', title = 'Alice explicit', key = 'alice-explicit'})
  expect(title(a_id, 'bob').title, 'an explicit rename replaces the carried title').to_be('Alice explicit')
end)

test('the last migration: the first inherited home wins; the explicit move stays', function()
  bob:report({kind = 'codex', conversation_id = 'conversation-b'})
  migrated('bob')
  expect(home(a_id, b_id).home_session, 'no move: the first home wins over the later canonical home').to_be(homes.ab_first)
  local bc = home(b_id, c_id)
  expect(bc.home_session, 'the explicit move wins over the inherited homes').to_be(moved_to)
  expect(bc.moved, 'the move stays marked for later merges').to_be(1)
  expect(home(a_id, 'bob')).to_be(nil)
  expect(home('bob', c_id)).to_be(nil)
end)

test('two-alias titles after the last migration: the newest effective write wins', function()
  expect(title(a_id, b_id).title, 'the explicit rename between the migrations wins').to_be('Alice explicit')
  expect(title(c_id, b_id).title, 'a migration rewrite does not make the legacy title newest').to_be('Canonical C')
  expect(title(a_id, 'bob')).to_be(nil)
end)

test('an explicit rename after a carried title wins', function()
  -- Bob's legacy title for alice merged when bob migrated; it is carried now.
  local carried = title(b_id, a_id)
  expect(carried.title).to_be('Legacy title')
  bob:call('messaging.thread_rename', {thread = a_id, title = 'Explicit after migration', key = 'rename-after'})
  expect(title(b_id, a_id).title).to_be('Explicit after migration')
end)
