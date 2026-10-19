-- Ported from the Node test messaging.mjs (coverage map: commit eaaf529): thread homes (the session where a thread was created), reopen
-- tokens, the session order of the threads panel, home redirects after a home session closes,
-- a concurrent first home, session choices for agents and the UI, menu moves, and a session
-- creation that a failure interrupted.

local function part(s) return #s .. ':' .. s end
local function meta(a, b)
  if b < a then local t = a; a = b; b = t end -- not a, b = b, a: wrong in Rex Lua (rex-protocol.md)
  return 'thread-meta/' .. part(a) .. part(b)
end
local function index_of(items, id)
  for i, t in ipairs(items or {}) do if t.id == id then return i end end
  return nil
end
local function named(label)
  local out = {}
  for _, s in ipairs(rex.call('session.list', {}).sessions or {}) do
    if s.label == label then out[#out + 1] = s.session_id end
  end
  return out
end
-- pane_in is a palette source in a session: its first block.
local function pane_in(session)
  local blocks = rex.call('session.list_blocks', {session_id = session}).blocks
  return {session = session, block = blocks[1].block_id}
end
local function new_thread(from, values, key)
  user:command('new_thread', from)
  local f = user:view('/forms/new-thread')
  f:render()
  return f:action('new_thread', 'submit', {values = values}, key)
end
local function panel_items(from)
  user:command('threads', from)
  local tree = user:view('/panels/threads', nil, from.session):render()
  return H.node(tree, 'threads').items
end
local function home_tab(id) return tab('thread/' .. id) end

local here = H.args.tests_session
local elsewhere = session('Elsewhere')
local alice, bob = agent('alice'), agent('bob')
-- charlie's pane is in another session: its session is the default for its tool calls.
local remote = agent('remote', {join = 'charlie', session = elsewhere, title = 'remote'})
local token

test('a direct thread gets its first home and keeps it', function()
  local op = new_thread(nil, {member_alice = true}, 'home-direct')
  expect(op.result).to_equal({navigate = 'thread/alice'})
  expect(home_tab('alice').session_id).to_be(here)
  token = home_tab('alice').revision
  expect(type(token)).to_be('string')
  op = new_thread(pane_in(elsewhere), {member_alice = true}, 'home-direct-again')
  expect(op.result).to_equal({navigate = 'thread/alice'})
  expect(home_tab('alice').session_id, 'an existing direct thread keeps its first home').to_be(here)
  expect(store(meta('alice', 'user')).value.home_session).to_be(here)
end)

test('a rename and a view do not change the reopen token; a new message does', function()
  local v = user:open('thread/alice')
  v:render()
  v:rename_tab('Homed thread')
  wait('the rename', function() if v:render().title == 'Homed thread' then return true end end)
  v:seen()
  expect(home_tab('alice').revision).to_be(token)
  local mail = alice:call('messaging.send', {to = 'user', body = 'Reopen this thread', key = 'home-reopen'})
  local t = wait('the new token', function()
    local x = home_tab('alice')
    if x.revision ~= token then return x end
  end)
  expect(t.revision, 'a new message changes the reopen token').to_be(mail.id)
end)

test('the panel lists this session\'s threads first and keeps threads of other sessions', function()
  local local_items = panel_items(pane_in(here))
  expect(index_of(local_items, 'alice') < index_of(local_items, 'team'), 'current-session threads first').to_be(true)
  expect(index_of(panel_items(pane_in(elsewhere)), 'alice'), 'the panel keeps threads of other sessions').to_be_truthy()
  -- The team thread has no home: its tab lives in the plugin's app session.
  local team = user:open('thread/team')
  team:render()
  local default_items = panel_items(team)
  expect(index_of(default_items, 'team') < index_of(default_items, 'alice'), 'unhomed threads first in the default session').to_be(true)
  local op = user:view('/panels/threads', nil, team.session):action('threads', 'open', {item_id = 'alice'})
  expect(op.result).to_equal({navigate = 'thread/alice'})
end)

test('a closed home: the tab moves to a replacement session; the panel follows the redirect', function()
  local home = session('Charlie home')
  local op = new_thread(pane_in(home), {member_charlie = true}, 'home-charlie')
  expect(op.result).to_equal({navigate = 'thread/charlie'})
  expect(home_tab('charlie').session_id).to_be(home)
  close_session(home)
  remote:call('messaging.send', {to = 'user', body = 'after the home closed', key = 'after-close'})
  local replacement = wait('a replacement session named Charlie home', function()
    local s = named('Charlie home')
    if #s == 1 and s[1] ~= home then return s[1] end
  end)
  local v = user:open('thread/charlie')
  v:render()
  expect(v.session, 'the tab lives in the replacement session').to_be(replacement)
  local items = panel_items(v)
  expect(index_of(items, 'charlie') < index_of(items, 'team'), 'a redirected thread comes first in the replacement session').to_be(true)
  expect(store(meta('charlie', 'user')).value.home_session, 'the stored home stays').to_be(home)
end)

test('a concurrent first home wins without losing the creation', function()
  local key = meta('bob', 'user')
  with_injection({match = {writes = key}, ops = {{key = key, value = {home_session = 'session:winner'}}}}, 1, function()
    local op = new_thread(nil, {member_bob = true}, 'home-race')
    expect(op.result).to_equal({navigate = 'thread/bob'})
  end)
  expect(store(key).value.home_session).to_be('session:winner')
  expect(home_tab('bob').session_id).to_be('session:winner')
end)

test('an agent creates in its pane session by default; explicit and new sessions; replays', function()
  local args = {members = {'alice', 'bob', 'user'}, title = 'Agent session default', key = 'agent-home-default'}
  local made = remote:call('messaging.thread_create', args)
  expect(home_tab(made.id).session_id).to_be(elsewhere)
  expect(remote:call('messaging.thread_create', args)).to_equal(made)
  expect_error(function() remote:call('messaging.thread_create', {members = {'alice', 'bob', 'user'}, title = 'Agent session default', key = 'agent-home-default', session_id = here}) end, 'different content')
  local closed = session('Closed target')
  close_session(closed)
  expect_error(function() alice:call('messaging.thread_create', {members = {'bob'}, title = 'Closed target', key = 'closed-target', session_id = closed}) end, 'closed')
  local explicit = alice:call('messaging.thread_create', {members = {'bob', 'user'}, title = 'Explicit target', key = 'explicit-target', session_id = elsewhere})
  expect(home_tab(explicit.id).session_id).to_be(elsewhere)
  local named_args = {members = {'bob', 'user'}, title = 'Named target', key = 'named-target', new_session = 'New workspace'}
  local n = alice:call('messaging.thread_create', named_args)
  expect(named('New workspace')).to_equal({home_tab(n.id).session_id})
  expect(alice:call('messaging.thread_create', named_args)).to_equal(n)
  expect(#named('New workspace'), 'a saved creation does not create the session again').to_be(1)
  alice:call('messaging.thread_create', {members = {'user'}, key = 'existing-direct-new-choice', new_session = 'Unused workspace'})
  expect(#named('Unused workspace'), 'an existing direct thread creates no unused session').to_be(0)
  expect(home_tab('alice').session_id).to_be(here)
end)

test('the UI form creates a named new session; a new session needs a name', function()
  local op = new_thread(nil, {title = 'UI session', session_id = '@new', session_name = 'UI workspace', member_alice = true, member_bob = true}, 'ui-new-session')
  local id = op.result.navigate:match('^thread/(.+)$')
  expect(named('UI workspace')).to_equal({home_tab(id).session_id})
  op = new_thread(nil, {session_id = '@new', member_alice = true, member_bob = true}, 'ui-no-name')
  expect(op.status).to_be('failed')
  expect(op.error.message).to_match('name')
end)

test('a menu move changes the home, keeps the token and the draft; @new names a session', function()
  local v = user:open('thread/alice')
  v:render()
  v:action('thread_menu', 'open', {})
  local menu = user:view('/forms/thread-menu')
  menu:render()
  expect(menu:action('thread_menu', 'move', {item_id = 'move'}).result).to_equal({form = '/forms/thread-move'})
  local form = user:view('/forms/thread-move')
  local tree = form:render()
  local field
  for _, f in ipairs(H.node(tree, 'move_thread').fields) do if f.id == 'session_id' then field = f end end
  expect(field.value, 'the current home is the default').to_be(here)
  write({{key = 'draft/' .. part('user') .. part('alice'), value = {text = 'draft before the move'}}})
  local draft = store('draft/' .. part('user') .. part('alice'))
  local before = home_tab('alice').revision
  local op = form:action('move_thread', 'submit', {values = {session_id = elsewhere}}, 'move-existing')
  expect(op.result).to_equal({navigate = 'thread/alice'})
  expect(home_tab('alice').session_id).to_be(elsewhere)
  expect(home_tab('alice').revision, 'a move does not change the token').to_be(before)
  expect(store('draft/' .. part('user') .. part('alice')), 'a move keeps the draft').to_equal(draft)
end)

test('move as a tool: @new, an old replay does not undo a later move, a changed input conflicts, closed refused', function()
  local first = alice:call('messaging.thread_move', {thread = 'user', session_id = here, key = 'tool-move-1'})
  expect(first.moved).to_be(true)
  alice:call('messaging.thread_move', {thread = 'user', new_session = 'Moved workspace', key = 'tool-move-2'})
  local moved = home_tab('alice').session_id
  expect(named('Moved workspace')).to_equal({moved})
  expect(alice:call('messaging.thread_move', {thread = 'user', session_id = here, key = 'tool-move-1'})).to_equal(first)
  expect(home_tab('alice').session_id, 'an old move replay does not undo a later move').to_be(moved)
  expect_error(function() alice:call('messaging.thread_move', {thread = 'user', session_id = elsewhere, key = 'tool-move-1'}) end, 'different content')
  local closed = session('Closed move')
  close_session(closed)
  expect_error(function() alice:call('messaging.thread_move', {thread = 'user', session_id = closed, key = 'tool-move-closed'}) end, 'closed')
  expect(home_tab('alice').session_id).to_be(moved)
end)

test('a creation interrupted after its session exists reuses that session on retry', function()
  local args = {members = {'bob', 'user'}, title = 'Interrupted session creation', new_session = 'Resumed workspace', key = 'interrupted-new-session'}
  with_injection({match = {op_key = 'thread-create/' .. part('alice') .. part('interrupted-new-session')}, fail = 'Injected failure after session creation'}, 1, function()
    expect_error(function() alice:call('messaging.thread_create', args) end, 'Injected failure')
  end)
  expect(#named('Resumed workspace')).to_be(1)
  local resumed = alice:call('messaging.thread_create', args)
  expect(#named('Resumed workspace'), 'the retry reuses the session').to_be(1)
  expect(named('Resumed workspace')).to_equal({home_tab(resumed.id).session_id})
end)

test('a group made by direct expansion takes the form session and an empty token', function()
  local v = user:open('thread/charlie')
  v:render()
  v:action('thread_menu', 'open', {})
  local menu = user:view('/forms/thread-menu', nil, v.session)
  menu:render()
  menu:action('thread_menu', 'members', {item_id = 'members'})
  local form = user:view('/forms/thread-members', nil, v.session)
  form:render()
  local op = form:action('thread_members', 'submit', {values = {member_charlie = true, member_alice = true}}, 'expand-for-home')
  local id = op.result.navigate:match('^thread/(g%-.+)$')
  expect(home_tab(id).session_id, 'the new group lives in the form session').to_be(v.session)
  expect(home_tab(id).revision, 'an empty group has a stable empty token').to_be('')
end)

test('a replay after the conversation resumed in another session keeps the first home', function()
  -- A pane cannot move to another session (rex-protocol.md). A conversation can: it resumes in a
  -- new pane, and the hub moves the identity there. Its source session changes.
  local first = agent('roam', {join = false, session = elsewhere})
  first:report({kind = 'claude', conversation_id = 'roam'})
  local args = {members = {'alice', 'user'}, title = 'Roaming default', key = 'roam-home-default'}
  local made = first:call('messaging.thread_create', args)
  expect(home_tab(made.id).session_id).to_be(elsewhere)
  local resumed = agent('roam-resumed', {join = false})
  resumed:report({kind = 'claude', conversation_id = 'roam', source = 'resume'})
  expect(resumed:call('messaging.thread_list', {}).threads[1] ~= nil, 'the identity moved to the new pane').to_be(true)
  expect(resumed:call('messaging.thread_create', args), 'the replay returns the original result').to_equal(made)
  expect(home_tab(made.id).session_id, 'the original home stays').to_be(elsewhere)
  local fresh = resumed:call('messaging.thread_create', {members = {'bob', 'user'}, title = 'After resume', key = 'roam-after'})
  expect(home_tab(fresh.id).session_id, 'the source session changed with the pane').to_be(here)
  expect_error(function() resumed:call('messaging.thread_create', {members = {'alice', 'user'}, title = 'Roaming default', key = 'roam-home-default', session_id = here}) end, 'different content')
end)
