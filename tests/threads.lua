-- Ported from the Node test messaging.mjs (coverage map: commit eaaf529): tabs, thread creation and replay, membership refusals, FYI,
-- unread status, cursors, and archive and restore. The human acts through the UI (forms, the
-- thread menu, the threads panel); agents act as tools.

-- writes is the write state of the plugin: a write that gives out a revision moves the clock; an
-- open mark or a saved operation adds a row.
local function writes()
  return sql([[SELECT CAST((SELECT n FROM clock) AS TEXT) AS n, (SELECT count(*) FROM thread_opened) AS opened,
    (SELECT count(*) FROM operations) AS operations, (SELECT count(*) FROM groups) AS groups]])[1]
end
local function has_tab(key) return tab(key) ~= nil end
local function find(list, id)
  for _, t in ipairs(list or {}) do if t.id == id then return t end end
end
local function ids(list)
  local out = {}
  for _, t in ipairs(list or {}) do out[#out + 1] = t.id end
  return out
end
local function panel()
  user:command('threads')
  return user:view('/panels/threads')
end
-- archived_page opens the Archived section of the panel (Show) and returns its first page.
local function archived_page()
  local op = panel():action('archived_threads', 'show', {})
  return user:view(op.result.form)
end

local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')

test('roster agents get no empty direct tab; member groups keep theirs', function()
  for _, k in ipairs({'thread/' .. alice.id, 'thread/' .. bob.id, 'thread/' .. charlie.id}) do expect(has_tab(k), k).to_be(false) end
  expect(has_tab('thread/team')).to_be(true)
end)

-- C5 (fresh-install audit): a new user read the Gallery's sample messages as real data. The test
-- manifest sets no gallery arg, as a default install.
test('the default install declares no Gallery tab', function()
  expect(has_tab('gallery')).to_be(false)
  expect(has_tab('gallery/thread')).to_be(false)
end)

-- The plugin had a lab action lab.tabs that passed caller args to hub.ui.tabs with no requester
-- check: any Rex client could replace the user's tab set.
test('a Rex client that is not the hub cannot declare tabs', function()
  local client = H.hub('hub.test.status', {}).plugins.messaging.client_id
  local before = H.tabs()
  local ok = pcall(H.perform, client, 'lab.tabs', {tabs = {{key = 'thread/team', title = 'Replaced', route = '/thread/team'}}})
  expect(ok, 'the call is refused').to_be(false)
  expect(H.tabs(), 'the tab set is unchanged').to_equal(before)
end)

-- B4 (fresh-install audit): the renderer refuses a history node with page_size < 1 (hub
-- view/schema.go). The harness does not apply that check, so the test reads the node itself.
test('an empty thread renders a history node with a positive page_size', function()
  local history = H.node(user:open('thread/team'):render(), 'history')
  expect(#history.messages).to_be(0)
  expect(history.page_size >= 1, 'page_size ' .. tostring(history.page_size)).to_be(true)
end)

-- Thread view v1.2, item 2: a thread tab is one view in thread mode, not a transcript pane over a
-- composer. Messaging declares no layout, so the snapshot has none.
test('a thread view is one view: no transcript layout, total 0 for an empty thread', function()
  local v = user:open('thread/team')
  local history = H.node(v:render(), 'history')
  expect(history.total).to_be(0)
  local layout = v:get().layout
  expect(layout == nil or layout == '', 'the snapshot layout: ' .. tostring(layout)).to_be(true)
end)

test('an explicit open declares the empty direct thread once (view.open through the hub)', function()
  user:open('thread/' .. alice.id):render()
  expect(has_tab('thread/' .. alice.id)).to_be(true)
  local before = writes()
  user:open('thread/' .. alice.id):render()
  expect(writes(), 'opening again does not write').to_equal(before)
  expect_error(function() user:plugin_view('open', {route = '/thread/' .. charlie.id, user = 'user'}) end, 'Only the hub')
end)

test('New Thread declares an empty direct thread; archive hides it; restore brings it back', function()
  user:command('new_thread')
  local form = user:view('/forms/new-thread')
  form:render()
  local op = form:action('new_thread', 'submit', {values = {['member_' .. bob.id] = true}})
  expect(op.status).to_be('succeeded')
  expect(has_tab('thread/' .. bob.id)).to_be(true)
  -- Archive from the thread menu of thread/alice.
  local v = user:open('thread/' .. alice.id)
  v:render()
  v:action('thread_menu', 'open', {})
  local menu = user:view('/forms/thread-menu')
  menu:render()
  op = menu:action('thread_menu', 'archive', {item_id = 'archive'})
  expect(op.result).to_equal({panel = {command = 'threads'}})
  expect(has_tab('thread/' .. alice.id)).to_be(false)
  -- A navigation does not undo the archive: view.open declares nothing.
  pcall(function() H.hub('hub.ui.navigate', {plugin = 'messaging', tab = 'thread/' .. alice.id}) end)
  expect(has_tab('thread/' .. alice.id), 'opening does not undo archive').to_be(false)
  local p = archived_page()
  expect(find(H.node(p:render(), 'archived_threads').items, alice.id)).to_be_truthy()
  op = p:action('archived_threads', 'restore', {item_id = alice.id})
  expect(op.result).to_equal({navigate = 'thread/' .. alice.id})
  expect(has_tab('thread/' .. alice.id), 'restore keeps the explicit open').to_be(true)
  expect(has_tab('thread/' .. charlie.id), 'unopened direct threads stay absent').to_be(false)
end)

local created
local create_args = {key = 'group/:one', title = 'Review', members = {bob.id, 'user'}}

test('thread_create makes a group; a replay returns it without a write', function()
  created = alice:call('messaging.thread_create', create_args)
  expect(created.group).to_be(true)
  expect(created.members).to_equal({alice.id, bob.id, 'user'})
  expect(find(alice:call('messaging.thread_list', {}).threads, created.id).title).to_be('Review')
  expect(has_tab('thread/' .. created.id)).to_be(true)
  local before = writes()
  expect(alice:call('messaging.thread_create', {key = 'group/:one', title = 'Review', members = {'user', bob.id, alice.id}})).to_equal(created)
  expect(writes(), 'a create replay does not write').to_equal(before)
  expect_error(function() alice:call('messaging.thread_create', {key = 'group/:one', title = 'Other', members = {bob.id, 'user'}}) end, 'different content')
  local other = alice:call('messaging.thread_create', {key = 'groupone', title = 'Review', members = {bob.id, 'user'}})
  expect(other.id, 'punctuation in operation keys is kept').not_to_be(created.id)
  expect_error(function() alice:call('messaging.thread_create', {key = 'missing', members = {'unknown'}}) end, 'Unknown recipient')
end)

test('a create keeps the other groups; a direct create returns the direct thread', function()
  local made = alice:call('messaging.thread_create', {key = 'create-second', title = 'Second', members = {bob.id}})
  expect(#sql('SELECT gid FROM groups WHERE gid IN (?, ?)', {created.id, made.id})).to_be(2)
  local direct = alice:call('messaging.thread_create', {key = 'direct', members = {bob.id}})
  expect(direct.id).to_be(bob.id)
  expect(direct.group).to_be(false)
  expect(alice:call('messaging.thread_create', {key = 'direct', members = {bob.id}})).to_equal(direct)
end)

test('a non-member cannot list, archive, read or send to a group', function()
  expect(find(charlie:call('messaging.thread_list', {}).threads, created.id)).to_be(nil)
  expect_error(function() charlie:call('messaging.thread_archive', {thread = created.id, key = 'foreign'}) end, 'Unknown thread')
  expect_error(function() charlie:call('messaging.read', {thread = created.id}) end, 'member')
  expect_error(function() charlie:call('messaging.send', {to = created.id, key = 'foreign', body = 'no'}) end, 'member')
end)

local info, cursor
test('FYI: reply_expected false is stored; unread shows on the user tab; a cursor does not acknowledge', function()
  info = alice:call('messaging.send', {to = created.id, key = 'fyi', body = 'Review complete', reply_expected = false})
  expect(sql('SELECT reply_expected FROM messages WHERE id = ?', {info.id})[1].reply_expected).to_be(0)
  expect_error(function() alice:call('messaging.send', {to = created.id, key = 'fyi', body = 'Review complete'}) end, 'different content')
  -- The user's tab before the user looks at it: the hub shows the view, and that acknowledges.
  local t = tab('thread/' .. created.id)
  expect(t.title).to_be('Review (1)')
  expect(t.status).to_equal({state = 'done', msg = '1 unread'})
  local filtered = bob:call('messaging.read', {thread = created.id})
  expect(#filtered.messages).to_be(1)
  expect(filtered.messages[1].reply_expected).to_be(false)
  cursor = filtered.next_cursor
  expect(bob:call('messaging.read', {thread = created.id, since = cursor}).messages).to_equal({})
  expect(#bob:call('messaging.read', {thread = created.id}).messages, 'a cursor does not acknowledge').to_be(1)
end)

test('the thread view: no tree status, a menu button, FYI marked in history', function()
  local v = user:open('thread/' .. created.id)
  local tree = v:render()
  -- The hub commits the tab status first; a separate worker then updates the snapshots.
  local declared = tab('thread/' .. created.id).status
  expect(declared, 'the FYI is unread').to_equal({state = 'done', msg = '1 unread'})
  wait('the snapshot status', function()
    local s = v:get().status
    if s and s.state == declared.state and s.msg == declared.msg and s.kind == declared.kind then return true end
  end)
  expect(H.node(tree, 'thread_menu').action.name).to_be('open')
  expect(H.node(tree, 'history').messages[1].fyi).to_be(true)
  local op = v:action('thread_menu', 'open', {})
  expect(op.result).to_equal({form = '/forms/thread-menu'})
end)

test('archive from the menu keeps other archived threads, the draft and unread delivery', function()
  -- Unread mail for the user that the archive must keep.
  local unread = alice:call('messaging.send', {to = created.id, key = 'fyi-2', body = 'Second note'})
  local function draft() return sql('SELECT text, rev FROM drafts WHERE viewer = ? AND peer = ?', {'user', created.id})[1] end
  sql_write('INSERT INTO drafts (viewer, peer, text, rev) VALUES (?, ?, ?, 7)', {'user', created.id, 'keep this draft'})
  sql_write("INSERT INTO thread_archived (viewer, peer) VALUES ('user', 'team')")
  local draft_before = draft()
  local menu = user:view('/forms/thread-menu')
  menu:render()
  local op = menu:action('thread_menu', 'archive', {item_id = 'archive'})
  expect(op.result).to_equal({panel = {command = 'threads'}})
  local archived = {}
  for _, r in ipairs(sql('SELECT peer FROM thread_archived WHERE viewer = ?', {'user'})) do archived[r.peer] = true end
  expect(archived.team, 'archive keeps other archived threads').to_be(true)
  expect(archived[created.id]).to_be(true)
  expect(has_tab('thread/' .. created.id), 'archive omits the tab').to_be(false)
  expect(draft(), 'archive keeps the draft').to_equal(draft_before)
  expect(#sql([[SELECT 1 AS x FROM deliveries d JOIN messages m ON m.seq = d.seq
    WHERE d.agent = 'user' AND d.acked = 0 AND m.id = ?]], {unread.id}), 'archive keeps unread delivery').to_be(1)
  expect(find(H.node(archived_page():render(), 'archived_threads').items, created.id)).to_be_truthy()
  expect(find(bob:call('messaging.thread_list', {}).threads, created.id).archived, 'archive is per participant').to_be_falsy()
  local later = alice:call('messaging.send', {to = created.id, key = 'later', body = 'Another note'})
  expect(has_tab('thread/' .. created.id), 'new mail does not undo archive').to_be(false)
  expect(ids(bob:call('messaging.read', {thread = created.id, since = cursor}).messages)).to_contain(later.id)
end)

test('restore from the panel; seeing the thread clears its status', function()
  local p = archived_page()
  p:render()
  local op = p:action('archived_threads', 'restore', {item_id = created.id})
  expect(op.result).to_equal({navigate = 'thread/' .. created.id})
  local v = user:view('thread/' .. created.id)
  v:render()
  v:seen()
  local t = H.wait('the restored tab to have no unread status', function()
    local x = tab('thread/' .. created.id)
    if x and x.status == nil then return x end
  end)
  expect(t.title).to_be('Review')
end)

test('an old archive retry does not undo a newer restore', function()
  local args = {thread = created.id, key = 'archive-1'}
  alice:call('messaging.thread_archive', args)
  alice:call('messaging.thread_archive', {thread = created.id, key = 'restore-1', archived = false})
  alice:call('messaging.thread_archive', args)
  expect(find(alice:call('messaging.thread_list', {}).threads, created.id).archived).to_be_falsy()
end)
