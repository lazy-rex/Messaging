-- The tabs come from committed state. A call declares the tabs after its commit, so a call whose
-- commit fails declares nothing of it: a failed send, move or archive leaves the tabs as they were.
-- (Review of 92d5f7c: the declaration ran inside the transaction, before the commit.)

local alice = agent('alice')
local elsewhere = session('Elsewhere')

local function menu_for(peer)
  local v = user:open('thread/' .. peer)
  v:render()
  v:action('thread_menu', 'open', {})
  local menu = user:view('/forms/thread-menu')
  menu:render()
  return menu
end

test('a failed send declares no tab', function()
  expect(tab('thread/' .. alice.id)).to_be(nil)
  with_injection({match = {sql_commit_writes = 'messages'}, fail = 'Commit lost'}, 1, function()
    expect_error(function() alice:call('messaging.send', {to = 'user', body = 'rolled back', key = 'failed-send'}) end, 'Commit lost')
  end)
  expect(#sql("SELECT id FROM messages WHERE body = 'rolled back'")).to_be(0)
  expect(tab('thread/' .. alice.id), 'no tab from a rolled-back send').to_be(nil)
  local sent = alice:call('messaging.send', {to = 'user', body = 'committed', key = 'committed-send'})
  expect(tab('thread/' .. alice.id).revision, 'a committed send declares its tab').to_be(sent.id)
end)

test('a failed move keeps the tab in its home', function()
  local home = tab('thread/' .. alice.id).session_id
  local menu = menu_for(alice.id)
  expect(menu:action('thread_menu', 'move', {item_id = 'move'}).result).to_equal({form = '/forms/thread-move'})
  local form = user:view('/forms/thread-move')
  form:render()
  local op = with_injection({match = {sql_commit_writes = 'thread_homes'}, fail = 'Commit lost'}, 1, function()
    return form:action('move_thread', 'submit', {values = {session_id = elsewhere}}, 'failed-move')
  end)
  expect(op.status).to_be('failed')
  expect(tab('thread/' .. alice.id).session_id, 'the tab stays in its home').to_be(home)
end)

test('a failed archive keeps the tab', function()
  local menu = menu_for(alice.id)
  local op = with_injection({match = {sql_commit_writes = 'thread_archived'}, fail = 'Commit lost'}, 1, function()
    return menu:action('thread_menu', 'archive', {item_id = 'archive'})
  end)
  expect(op.status).to_be('failed')
  expect(tab('thread/' .. alice.id), 'the tab stays').to_be_truthy()
  expect(#sql("SELECT peer FROM thread_archived WHERE viewer = 'user'")).to_be(0)
end)
