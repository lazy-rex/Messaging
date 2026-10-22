-- The thread menu actions on both paths: the agent tool (messaging.thread_rename, _members, _move,
-- through the agent face) and the UI form submit (the hub view path). Both call one handler.

-- Every call fails with unavailable until the import at start is done (import.lua). Under load,
-- the start can end before it; the tests begin after it.
wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

local function thread_of(list, id)
  for _, t in ipairs(list.threads) do if t.id == id then return t end end
end

-- form opens a thread menu form from the user's thread view and returns the form view.
local function form(thread_id, item)
  local v = user:open('thread/' .. thread_id)
  v:render()
  local op = v:action('thread_menu', 'open', {})
  expect(op.effects, 'thread menu').to_be('done')
  local menu = user:view('/forms/thread-menu')
  menu:render()
  op = menu:action('thread_menu', item, {item_id = item})
  expect(op.effects, item .. ' form').to_be('done')
  local f = user:view('/forms/thread-' .. item)
  f:render()
  return f
end

local group
local function the_group()
  if not group then
    group = agent('alice'):call('messaging.thread_create', {key = 'menu-group', title = 'Menu group', members = {'bob', 'user'}})
  end
  return group
end

test('rename as a tool sets the caller\'s title only', function()
  local alice, bob = agent('alice'), agent('bob')
  local g = the_group()
  expect(alice:call('messaging.thread_rename', {thread = g.id, title = 'Alice title', key = 'r1'})).to_equal({title = 'Alice title'})
  expect(thread_of(alice:call('messaging.thread_list', {}), g.id).title).to_be('Alice title')
  expect(thread_of(bob:call('messaging.thread_list', {}), g.id).title).to_be('Menu group')
  -- A replay returns the first result; the same key with another title is a conflict.
  expect(alice:call('messaging.thread_rename', {thread = g.id, title = 'Alice title', key = 'r1'})).to_equal({title = 'Alice title'})
  expect_error(function() alice:call('messaging.thread_rename', {thread = g.id, title = 'Other', key = 'r1'}) end, 'operation_conflict')
  expect_error(function() alice:call('messaging.thread_rename', {thread = g.id, title = '  ', key = 'r2'}) end, 'empty')
  -- The shared rename handler: an old key replays its result and does not undo a later rename.
  alice:call('messaging.thread_rename', {thread = g.id, title = 'Later title', key = 'r3'})
  expect(alice:call('messaging.thread_rename', {thread = g.id, title = 'Alice title', key = 'r1'})).to_equal({title = 'Alice title'})
  expect(thread_of(alice:call('messaging.thread_list', {}), g.id).title, 'an old replay does not undo a later rename').to_be('Later title')
end)

test('rename in the UI form uses the same record', function()
  local g = the_group()
  local op = form(g.id, 'rename'):action('rename_thread', 'submit', {values = {title = 'User title'}})
  expect(op.status).to_be('succeeded')
  expect(sql('SELECT title FROM thread_titles WHERE viewer = ? AND peer = ?', {'user', g.id})[1].title).to_be('User title')
  expect(tab('thread/' .. g.id).title).to_match('^User title')
end)

test('members as a tool: a member adds a participant; others and the team are refused', function()
  local alice, charlie = agent('alice'), agent('charlie')
  local g = the_group()
  local r = alice:call('messaging.thread_members', {thread = g.id, members = {'bob', 'user', 'charlie'}, key = 'm1'})
  expect(r.id).to_be(g.id)
  expect(r.members).to_equal({'alice', 'bob', 'charlie', 'user'})
  -- charlie got the member notice and can now read the thread.
  local mail = charlie:call('messaging.read', {thread = g.id})
  expect(mail.messages[1].body).to_match('You were added')
  expect_error(function() alice:call('messaging.thread_members', {thread = 'team', members = {'bob'}, key = 'm2'}) end, 'dynamic membership')
  local outsider = agent('bob')
  local other = alice:call('messaging.thread_create', {key = 'menu-private', title = 'Private', members = {'charlie', 'user'}})
  expect_error(function() outsider:call('messaging.thread_members', {thread = other.id, members = {'alice', 'charlie'}, key = 'm3'}) end, 'Unknown thread')
  expect_error(function() outsider:call('messaging.thread_rename', {thread = other.id, title = 'Mine', key = 'm4'}) end, 'Unknown thread')
  expect_error(function() outsider:call('messaging.thread_move', {thread = other.id, session_id = session('Outsider'), key = 'm5'}) end, 'Unknown thread')
end)

test('members in the UI form uses the same handler', function()
  local g = the_group()
  local op = form(g.id, 'members'):action('thread_members', 'submit', {values = {member_alice = true, member_bob = true}})
  expect(op.status).to_be('succeeded')
  local members = {}
  for _, r in ipairs(sql('SELECT agent FROM group_members WHERE gid = ? AND current = 1 ORDER BY pos', {g.id})) do members[#members + 1] = r.agent end
  expect(members).to_equal({'alice', 'bob', 'user'})
end)

test('move as a tool sets the thread home; the UI form does the same', function()
  local alice = agent('alice')
  local g = the_group()
  local s1 = session('Move one')
  expect(alice:call('messaging.thread_move', {thread = g.id, session_id = s1, key = 'mv1'})).to_equal({id = g.id, moved = true})
  local function home() return sql("SELECT home_session FROM thread_homes WHERE thread_a = '' AND thread_b = ?", {g.id})[1].home_session end
  expect(home()).to_be(s1)
  expect_error(function() alice:call('messaging.thread_move', {thread = g.id, session_id = 'session:closed', key = 'mv2'}) end, 'closed')
  local s2 = session('Move two')
  local op = form(g.id, 'move'):action('move_thread', 'submit', {values = {session_id = s2, session_name = ''}})
  expect(op.status).to_be('succeeded')
  expect(home()).to_be(s2)
  -- The new home moves the open thread view: the hub retires it and opens a view in s2, after
  -- the action replied. Wait for that, so that the next test does not act on the retiring view
  -- (reviewer's full run, 2026-10-22: 'the source view is closed').
  wait('one attached view of the moved thread, in s2', function()
    local found, moved = 0, false
    for _, v in ipairs(H.views()) do
      if v.tab == 'thread/' .. g.id then found = found + 1; moved = v.session_id == s2 and v.attached end
    end
    return found == 1 and moved
  end)
end)

-- Ported from the hub's one-tab-migration-lab.mjs (phase 3, items 4 and 5 of the coverage map):
-- the menu form reports blocked/question to the renderer, which writes it as the pane status, and
-- the menu lists Move to session, which opens the move form.
test('the thread menu form waits for input and lists Move to session', function()
  local g = the_group()
  local v = user:open('thread/' .. g.id)
  v:render()
  expect(v:action('thread_menu', 'open', {}).effects).to_be('done')
  local menu = user:view('/forms/thread-menu')
  local tree = menu:render()
  expect(menu:get().status, 'the snapshot that the renderer gets').to_equal({state = 'blocked', kind = 'question', msg = 'Waiting for input'})
  local move
  for _, item in ipairs(H.node(tree, 'thread_menu').items) do if item.id == 'move' then move = item end end
  expect(move.label).to_be('Move to session…')
  expect(menu:action('thread_menu', 'move', {item_id = 'move'}).effects).to_be('done')
  local f = user:view('/forms/thread-move')
  expect(f:render().title).to_be('Move to session')
  expect(f:get().status).to_equal({state = 'blocked', kind = 'question', msg = 'Waiting for input'})
end)
