-- Ported from the Node test messaging.mjs (coverage map: commit eaaf529): membership changes (the UI form and the tool), delivery
-- snapshots, history pages, a send race with a membership change, direct expansion, the team
-- refusal, and the replay of a creation that an older plugin version saved.

local function part(s) return #s .. ':' .. s end
local function box(name) return 'mailbox/' .. part(name) end
local function find(list, id)
  for _, t in ipairs(list or {}) do if t.id == id then return t end end
end
local function has_id(list, id) return find(list, id) ~= nil end

local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')

-- open_form opens a thread menu form from a thread view, as the user does.
local function menu_form(thread_id, item)
  local v = user:open('thread/' .. thread_id)
  v:render()
  v:action('thread_menu', 'open', {})
  local menu = user:view('/forms/thread-menu')
  menu:render()
  local op = menu:action('thread_menu', item, {item_id = item})
  if op.status ~= 'succeeded' then return op end
  local f = user:view('/forms/thread-' .. item)
  f:render()
  return f
end

local editable, old_mail, old_rev
test('the user creates a group in the New Thread form', function()
  user:command('new_thread')
  local f = user:view('/forms/new-thread')
  f:render()
  local op = f:action('new_thread', 'submit', {values = {title = 'Membership review', member_alice = true, member_bob = true}})
  expect(op.status).to_be('succeeded')
  local id = op.result.navigate:match('^thread/(.+)$')
  editable = {id = id}
  expect(store('groups').value.groups[id].members).to_equal({'alice', 'bob', 'user'})
end)

test('a member change in the form keeps delivered mail and an unrelated concurrent group', function()
  old_mail = alice:call('messaging.send', {to = editable.id, body = 'Before membership changed', key = 'before-members'})
  -- A message from before immutable recipient snapshots: no recipients field.
  local legacy = store('message/' .. old_mail.id).value
  legacy.recipients = nil
  write({{key = 'message/' .. old_mail.id, value = legacy}})
  old_rev = store('message/' .. old_mail.id).rev
  local f = menu_form(editable.id, 'members')
  expect(find(H.node(f:render(), 'thread_members').fields, 'member_bob').value).to_be(true)
  local groups = store('groups').value
  groups.groups['g-concurrent-members'] = {name = 'Concurrent group', members = {'bob', 'user'}}
  local op
  with_injection({match = {op_prefix = 'members/'}, ops = {{key = 'groups', value = groups}}}, 1, function()
    op = f:action('thread_members', 'submit', {values = {member_alice = true, member_charlie = true}}, 'change-members')
  end)
  expect(op.result).to_equal({close_form = true})
  expect(store('groups').value.groups['g-concurrent-members'], 'the retry keeps an unrelated group').to_be_truthy()
  expect(store('groups').value.groups[editable.id].members).to_equal({'alice', 'charlie', 'user'})
  expect(store('message/' .. old_mail.id).rev, 'membership never rewrites old messages').to_be(old_rev)
end)

test('members as a tool: a replay returns the first result; changed members under the key conflict', function()
  local args = {thread = editable.id, members = {'charlie', 'user'}, key = 'tool-members'}
  local first = alice:call('messaging.thread_members', args)
  local before = batches()
  expect(alice:call('messaging.thread_members', args)).to_equal(first)
  expect(batches(), 'a replay does not write').to_be(before)
  expect_error(function() alice:call('messaging.thread_members', {thread = editable.id, members = {'bob', 'user'}, key = 'tool-members'}) end, 'different content')
end)

test('a removed member keeps delivered mail but cannot read history; a new member gets one notice', function()
  expect(has_id(bob:call('messaging.read', {thread = editable.id}).messages, old_mail.id), 'a removed member keeps delivered mail').to_be(true)
  expect_error(function() bob:call('messaging.history', {thread = editable.id}) end, 'Only a current member can read')
  bob:call('messaging.ack', {ids = {old_mail.id}})
  local welcome = charlie:call('messaging.read', {thread = editable.id}).messages
  expect(#welcome, 'one new notice, no unread backfill').to_be(1)
  expect(welcome[1].body).to_match('messaging.history')
  expect(has_id(charlie:call('messaging.history', {thread = editable.id}).messages, old_mail.id), 'a new member reads old history').to_be(true)
end)

test('history pages: newest first, an older cursor excludes later arrivals, no acknowledgement', function()
  local pages = {}
  for i = 0, 23 do pages[#pages + 1] = alice:call('messaging.send', {to = editable.id, body = 'History page ' .. i, key = 'page-' .. i}) end
  local newest = charlie:call('messaging.history', {thread = editable.id})
  expect(#newest.messages).to_be(20)
  expect(newest.messages[1].id).to_be(pages[#pages].id)
  local between = alice:call('messaging.send', {to = editable.id, body = 'Between pages', key = 'between-pages'})
  local older = charlie:call('messaging.history', {thread = editable.id, before = newest.next_before})
  expect(has_id(older.messages, between.id), 'an older cursor excludes later arrivals').to_be(false)
  expect(has_id(older.messages, old_mail.id)).to_be(true)
  expect(older.next_before).to_be(nil)
  local seen, n = {}, 0
  for _, list in ipairs({newest.messages, older.messages}) do
    for _, m in ipairs(list) do if not seen[m.id] then seen[m.id] = true; n = n + 1 end end
  end
  expect(n).to_be(26)
  expect(#charlie:call('messaging.read', {thread = editable.id}).messages, 'history does not acknowledge').to_be(26)
  expect_error(function() charlie:call('messaging.history', {thread = editable.id, limit = 51}) end, 'limit')
end)

test('a send whose membership snapshot goes stale uses the new members on retry', function()
  local groups = store('groups').value
  groups.groups[editable.id].members = {'alice', 'bob', 'user'}
  local raced
  with_injection({match = {op_key = 'send/' .. part('alice') .. part('membership-race')}, ops = {{key = 'groups', value = groups}}}, 1, function()
    raced = alice:call('messaging.send', {to = editable.id, body = 'Membership race', key = 'membership-race'})
  end)
  expect(store(box('bob')).value.ids[raced.id]).to_be(true)
  expect((store(box('charlie')).value or {ids = {}}).ids[raced.id]).to_be(nil)
end)

test('adding members to a direct thread creates a group; the direct history stays', function()
  alice:call('messaging.send', {to = 'user', body = 'direct hello', key = 'direct-hello'})
  local f = menu_form('alice', 'members')
  local op = f:action('thread_members', 'submit', {values = {member_alice = true, member_bob = true}}, 'expand-direct')
  expect(op.result.navigate:match('^thread/g%-')).to_be_truthy()
  local tree = user:open('thread/alice'):render()
  expect(#H.node(tree, 'history').messages > 0, 'the direct history remains').to_be(true)
end)

test('the team has no members form', function()
  local op = menu_form('team', 'members')
  expect(op.status).to_be('failed')
  expect(op.error.message).to_match('Unknown thread menu action')
end)

test('a creation saved by an older plugin version replays without adding a home', function()
  local key = 'thread-create/' .. part('user') .. part('old-create-no-home')
  put_operation({key = key, fingerprint = 'thread-create-v1/' .. part('') .. part('charlie') .. part('user'),
    result = {id = 'charlie', title = 'charlie', members = {'charlie', 'user'}, group = false}})
  write({{key = 'thread-meta/' .. part('charlie') .. part('user'), delete = true}})
  user:command('new_thread')
  local f = user:view('/forms/new-thread')
  f:render()
  local op = f:action('new_thread', 'submit', {values = {member_charlie = true}}, 'old-create-no-home')
  expect(op.status).to_be('succeeded')
  expect(tab('thread/charlie').session_id or '', 'an old operation replay does not add a home').to_be('')
  expect(store('thread-meta/' .. part('charlie') .. part('user')).rev).to_be('0')
end)
