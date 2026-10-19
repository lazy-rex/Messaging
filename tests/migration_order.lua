-- Identity migrations that run one at a time (each agent reports its own conversation).
-- - Inherited homes (legacy, canonical, carried): the first home wins. A carried home keeps the
--   revision at which it was set (set_rev), so a later migration still sees its age.
-- - An explicit move (moved = true) is the newest intent: it wins over inherited homes, and it
--   stays selected in later migrations.
-- Two direct threads: alice-bob has no move; bob-charlie gets a move between the migrations.

local function part(s) return #s .. ':' .. s end
local function meta(a, b)
  if b < a then local t = a; a = b; b = t end -- not a, b = b, a: wrong in Rex Lua (rex-protocol.md)
  return 'thread-meta/' .. part(a) .. part(b)
end
local a_id, b_id, c_id = 'claude:conversation-a', 'codex:conversation-b', 'claude:conversation-c'
local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')
local function migrated(name)
  return wait('the migration of ' .. name, function()
    if store('identity-migrated/' .. part(name)).rev ~= '0' then return true end
  end)
end
local function title(owner, peer) return 'thread-title/' .. part(owner) .. part(peer) end
local moved_to

test('the first migrations carry the legacy homes with their age', function()
  write({
    {key = meta('alice', 'bob'), value = {home_session = 'session:ab-first'}},
    {key = meta('bob', 'charlie'), value = {home_session = 'session:bc-first'}},
    {key = 'thread-title/' .. part('bob') .. part('alice'), value = {title = 'Legacy title'}},
  })
  local ab_rev, bc_rev = store(meta('alice', 'bob')).rev, store(meta('bob', 'charlie')).rev
  write({
    {key = meta(a_id, b_id), value = {home_session = 'session:ab-later'}},
    {key = meta(b_id, c_id), value = {home_session = 'session:bc-later'}},
    {key = title(a_id, b_id), value = {title = 'Canonical A'}},
  })
  -- Two-alias title keys: an owner renames a peer before either identity exists.
  alice:call('messaging.thread_rename', {thread = 'bob', title = 'Alice legacy', key = 'alice-legacy'})
  charlie:call('messaging.thread_rename', {thread = 'bob', title = 'Charlie legacy', key = 'charlie-legacy'})
  -- A canonical title set after charlie's legacy rename, before the migrations: the newest.
  write({{key = title(c_id, b_id), value = {title = 'Canonical C'}}})
  alice:report({kind = 'claude', conversation_id = 'conversation-a'})
  migrated('alice')
  charlie:report({kind = 'claude', conversation_id = 'conversation-c'})
  migrated('charlie')
  local ab = store(meta(a_id, 'bob'))
  expect(ab.value.home_session).to_be('session:ab-first')
  expect(ab.value.set_rev, 'a carried home keeps its first revision').to_be(ab_rev)
  local bc = store(meta('bob', c_id))
  expect(bc.value.home_session).to_be('session:bc-first')
  expect(bc.value.set_rev).to_be(bc_rev)
  expect(store(title(a_id, 'bob')).value.title, 'the owner migration carries the title').to_be('Alice legacy')
  expect(store(title(a_id, 'bob')).value.set_rev).to_be_truthy()
  expect(store(title(c_id, 'bob')).value.title).to_be('Charlie legacy')
end)

test('an explicit move between the migrations is marked as a move', function()
  moved_to = session('Moved home')
  expect(charlie:call('messaging.thread_move', {thread = 'bob', session_id = moved_to, key = 'move-before-bob'}).moved).to_be(true)
  local bc = store(meta('bob', c_id)).value
  expect(bc).to_equal({home_session = moved_to, moved = true})
  alice:call('messaging.thread_rename', {thread = 'bob', title = 'Alice explicit', key = 'alice-explicit'})
  expect(store(title(a_id, 'bob')).value, 'an explicit rename replaces the carried title').to_equal({title = 'Alice explicit'})
end)

test('the last migration: the first inherited home wins; the explicit move stays', function()
  bob:report({kind = 'codex', conversation_id = 'conversation-b'})
  migrated('bob')
  expect(store(meta(a_id, b_id)).value.home_session, 'no move: the first home wins over the later canonical home').to_be('session:ab-first')
  local bc = store(meta(b_id, c_id)).value
  expect(bc.home_session, 'the explicit move wins over the inherited homes').to_be(moved_to)
  expect(bc.moved, 'the move stays marked for later merges').to_be(true)
  expect(store(meta(a_id, 'bob')).rev).to_be('0')
  expect(store(meta('bob', c_id)).rev).to_be('0')
end)

test('two-alias titles after the last migration: the newest effective write wins', function()
  expect(store(title(a_id, b_id)).value.title, 'the explicit rename between the migrations wins').to_be('Alice explicit')
  expect(store(title(c_id, b_id)).value.title, 'a migration rewrite does not make the legacy title newest').to_be('Canonical C')
  expect(store(title(a_id, 'bob')).rev).to_be('0')
end)

test('an explicit rename after a carried title wins', function()
  -- A title key (owner, peer) holds one alias, so its legacy and canonical records merge once.
  local carried = store('thread-title/' .. part(b_id) .. part(a_id)).value
  expect(carried.title).to_be('Legacy title')
  expect(carried.set_rev, 'the carried title keeps its age').to_be_truthy()
  bob:call('messaging.thread_rename', {thread = a_id, title = 'Explicit after migration', key = 'rename-after'})
  expect(store('thread-title/' .. part(b_id) .. part(a_id)).value).to_equal({title = 'Explicit after migration'})
  expect(store('thread-title/' .. part(b_id) .. part(a_id)).value.title).to_be('Explicit after migration')
end)
