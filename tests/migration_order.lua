-- Identity migrations that run one at a time (each agent reports its own conversation). A merged
-- home keeps the revision at which it was set (set_rev), so a second migration still sees its
-- age. An explicit write after a migration replaces the value, so its own revision counts.

local function part(s) return #s .. ':' .. s end
local alice_id, bob_id = 'claude:conversation-a', 'codex:conversation-b'
local legacy = 'thread-meta/' .. part('alice') .. part('bob')
local half = 'thread-meta/' .. part('bob') .. part(alice_id) -- alice migrated, bob not yet
local canonical = 'thread-meta/' .. part(alice_id) .. part(bob_id)

local alice, bob = agent('alice'), agent('bob')
local moved_to

test('the first migration moves the legacy home and keeps its age', function()
  write({{key = legacy, value = {home_session = 'session:first-home'}}})
  local legacy_rev = store(legacy).rev
  write({{key = canonical, value = {home_session = 'session:later-home'}}})
  alice:report({kind = 'claude', conversation_id = 'conversation-a'})
  local moved = wait('the alice migration', function()
    local r = store(half)
    if r.value then return r end
  end)
  expect(moved.value.home_session).to_be('session:first-home')
  expect(moved.value.set_rev, 'the moved home keeps its first revision').to_be(legacy_rev)
  expect(store(legacy).rev).to_be('0')
end)

test('an explicit move replaces the carried age; the second migration then keeps the older canonical home', function()
  moved_to = session('Moved home')
  expect(alice:call('messaging.thread_move', {thread = 'bob', session_id = moved_to, key = 'move-before-bob'}).moved).to_be(true)
  local r = store(half)
  expect(r.value.home_session).to_be(moved_to)
  expect(r.value.set_rev, 'a normal write drops set_rev').to_be(nil)
  bob:report({kind = 'codex', conversation_id = 'conversation-b'})
  local merged = wait('the bob migration', function()
    local x = store(canonical)
    if store(half).rev == '0' then return x end
  end)
  -- The canonical home (written before the move) is now the oldest set home.
  expect(merged.value.home_session).to_be('session:later-home')
end)
