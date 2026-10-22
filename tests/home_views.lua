-- Ported from the Node test thread-home-lab.mjs (coverage map: the commit that removes it): the
-- open view of a homed thread, its focus, a user close, the closed tab across a hub restart, a
-- reopen by a message without focus, a reopen by Threads… with focus, and the draft across a
-- thread menu form. A file of its own: it restarts the hub. Navigation focuses the view's pane
-- (session.focus_block), so focus is the session's active window.

-- Every call fails with unavailable until the import at start is done (import.lua). Under load,
-- the start can end before it; the tests begin after it.
wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

local function active(s) return rex.call('session.view', {session_id = s}).active_window_id end
-- open_views returns the open views of a tab.
local function open_views(t)
  local out = {}
  for _, v in ipairs(views()) do if v.tab == t then out[#out + 1] = v end end
  return out
end
local function one_view(t)
  local list = open_views(t)
  if #list == 1 then return list[1] end
end
local function closed(t)
  wait(t .. ' closed', function() if #open_views(t) == 0 then return true end end)
end
-- close is a user close: the runner closes the pane, as the app does.
local function close(v)
  rex.call('block.close', {session_id = v.session_id or v.session, block_id = v.block_id or v.block})
end
local function focus(s, window) rex.call('session.focus_window', {session_id = s, window_id = window}) end
local function focused(s, window)
  wait('focus on ' .. window, function() if active(s) == window then return true end end)
end
-- pane_in is a palette source in a session: its first block.
local function pane_in(session)
  local blocks = rex.call('session.list_blocks', {session_id = session}).blocks
  return {session = session, block = blocks[1].block_id}
end
local function new_thread(from, key)
  user:command('new_thread', from)
  local f = user:view('/forms/new-thread', nil, from and from.session)
  f:render()
  return f:action('new_thread', 'submit', {values = {member_alice = true}}, key)
end

local here = H.args.tests_session
local B = session('Home B')
local alice, bob = agent('alice'), agent('bob')
local first -- the first view of thread/alice

test('New Thread opens the thread in the source session and gives it focus', function()
  local op = new_thread(pane_in(here), 'hv-create')
  expect(op.result).to_equal({navigate = 'thread/alice'})
  first = wait('the thread view', function() return one_view('thread/alice') end)
  expect(first.session_id).to_be(here)
  focused(here, first.window_id)
end)

test('the same direct thread from another session shows the first view in its home', function()
  focus(here, alice.window) -- another tab of the home: a missing focus operation fails below
  expect(active(here)).to_be(alice.window)
  local op = new_thread(pane_in(B), 'hv-create-b')
  expect(op.result).to_equal({navigate = 'thread/alice'})
  focused(here, first.window_id)
  local list = open_views('thread/alice')
  expect(#list, 'one view, none in the other session').to_be(1)
  expect(list[1].view_id, 'the same view').to_be(first.view_id)
  expect(list[1].session_id).to_be(here)
end)

local alice_rev
test('a closed tab stays closed across a hub restart; a new message reopens another one', function()
  local b = user:open('thread/bob')
  b:render()
  close(first)
  close(b)
  closed('thread/alice')
  closed('thread/bob')
  alice_rev = tab('thread/alice').revision
  hub:restart()
  bob:call('messaging.send', {to = 'user', body = 'after the restart', key = 'hv-bob-after'})
  wait('bob reopened', function() return one_view('thread/bob') end)
  user:view('thread/bob'):render()
  expect(#open_views('thread/alice'), 'alice stays closed').to_be(0)
  expect(tab('thread/alice').revision, 'with the same revision').to_be(alice_rev)
end)

test('a real message reopens the thread in its home without focus', function()
  focus(here, alice.window)
  local mail = alice:call('messaging.send', {to = 'user', body = 'reopen please', key = 'hv-reopen'})
  local v = wait('the reopened view', function() return one_view('thread/alice') end)
  expect(v.session_id).to_be(here)
  user:view('thread/alice'):render()
  expect(tab('thread/alice').revision).to_be(mail.id)
  expect(active(here), 'a reopen does not take focus').to_be(alice.window)
end)

test('after another close, Threads… Open reopens the thread and shows it', function()
  close(wait('the open view', function() return one_view('thread/alice') end))
  closed('thread/alice')
  focus(here, alice.window)
  user:command('threads', pane_in(here))
  local panel = user:view('/panels/threads', nil, here)
  panel:render()
  local op = panel:action('threads', 'open', {item_id = 'alice'})
  expect(op.result).to_equal({navigate = 'thread/alice'})
  local v = wait('the reopened view', function() return one_view('thread/alice') end)
  expect(v.session_id).to_be(here)
  focused(here, v.window_id)
end)

test('a thread menu form keeps the thread draft', function()
  local v = user:view('thread/alice')
  local composer = H.node(v:render(), 'composer')
  local saved = v:draft('composer', 'unsent draft', composer.draft_revision, 'hv-draft')
  expect(saved.status).to_be('succeeded')
  local rev = saved.result.draft_revision
  v:action('thread_menu', 'open', {})
  local menu = user:view('/forms/thread-menu', nil, here)
  menu:render()
  expect(menu:action('thread_menu', 'rename', {item_id = 'rename'}).result).to_equal({form = '/forms/thread-rename'})
  local form = user:view('/forms/thread-rename', nil, here)
  expect(H.node(form:render(), 'rename_thread'), 'the rename form').to_be_truthy()
  close(form)
  wait('the rename form closed', function()
    for _, x in ipairs(views()) do if x.block_id == form.block then return nil end end
    return true
  end)
  expect(sql('SELECT text, CAST(rev AS TEXT) AS rev FROM drafts WHERE viewer = ? AND peer = ?', {'user', 'alice'})[1]).to_equal({text = 'unsent draft', rev = rev})
  composer = H.node(v:render(), 'composer')
  expect(composer.text).to_be('unsent draft')
  expect(composer.draft_revision).to_be(rev)
end)

-- Ported from the hub's one-tab-migration-lab.mjs (phases 4 and 5, item 8 of the coverage map):
-- Move to session with a draft to a new session, and an agent's new thread in the agent's session.
-- Both keep their session across a hub restart; the moved thread keeps its draft.
local function session_label(id)
  for _, s in ipairs(rex.call('session.list', {}).sessions or {}) do
    if s.session_id == id then return s.label end
  end
end
local function draft_text(v) return H.node(v:render(), 'composer').text end

test('a moved thread and an agent thread keep their sessions across a hub restart', function()
  local v = user:view('thread/alice')
  expect(v:action('thread_menu', 'open', {}).effects).to_be('done')
  local menu = user:view('/forms/thread-menu', nil, here)
  menu:render()
  expect(menu:action('thread_menu', 'move', {item_id = 'move'}).effects).to_be('done')
  local form = user:view('/forms/thread-move', nil, here)
  form:render()
  local op = form:action('move_thread', 'submit', {values = {session_id = '@new', session_name = 'Moved home'}}, 'hv-move')
  expect(op.status).to_be('succeeded')
  local moved = wait('thread/alice in the new session', function()
    local x = one_view('thread/alice')
    if x and session_label(x.session_id) == 'Moved home' then return x end
  end)
  expect(draft_text(user:view('thread/alice', nil, moved.session_id)), 'the draft moves with the thread').to_be('unsent draft')

  local A = session('Agent home')
  local charlie = agent('charlie', {session = A})
  local g = charlie:call('messaging.thread_create', {members = {'user', 'bob'}, title = 'Agent thread', key = 'hv-agent'})
  local t = 'thread/' .. g.id
  wait('the agent thread declared in its session', function() if tab(t) and tab(t).session_id == A then return true end end)
  expect(wait('the agent thread open', function() return one_view(t) end).session_id).to_be(A)

  hub:restart()
  local after = wait('thread/alice after the restart', function() return one_view('thread/alice') end)
  expect(after.session_id, 'the moved thread stays in its new session').to_be(moved.session_id)
  expect(draft_text(user:view('thread/alice', nil, moved.session_id)), 'the draft after the restart').to_be('unsent draft')
  expect(tab(t).session_id).to_be(A)
  expect(wait('the agent thread after the restart', function() return one_view(t) end).session_id, 'the agent thread stays in the agent session').to_be(A)
end)

-- Ported from the hub's one-tab-migration-lab.mjs (phase 6, item 9 of the coverage map): New
-- Thread from one session with another open session chosen. The group is declared in the chosen
-- session, opens there, gets the focus there, and its Rex tab shows the title.
test('New Thread into another open session declares, opens, focuses and titles it there', function()
  local before = active(B)
  user:command('new_thread', pane_in(here))
  local f = user:view('/forms/new-thread', nil, here)
  f:render()
  local op = f:action('new_thread', 'submit', {values = {session_id = B, session_name = '', title = 'Group in B',
    member_alice = true, member_bob = true}}, 'hv-create-in-b')
  expect(op.status).to_be('succeeded')
  local t = op.result.navigate
  expect(t:sub(1, 9)).to_be('thread/g-')
  expect(tab(t).session_id, 'declared in the chosen session').to_be(B)
  local opened = wait('the group view in B', function() local x = one_view(t); if x and x.session_id == B then return x end end)
  expect(opened.window_id ~= before, 'a new tab').to_be(true)
  focused(B, opened.window_id)
  local v = user:view(t, nil, B)
  expect(v:render().title).to_be('Group in B')
  wait('the tab label', function() if v:tab_label() == 'Group in B' then return true end end)
  expect(#open_views(t), 'no view in the source session').to_be(1)
end)
