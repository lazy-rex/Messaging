-- Ported from the Node test messaging.mjs (coverage map: commit eaaf529): membership changes (the UI form and the tool), the
-- audience fixed at send, history pages, a send after a membership change, direct expansion, the
-- team refusal, and the replay of a creation that an older plugin version saved.

local function part(s) return #s .. ':' .. s end
local function members_of(gid)
  local out = {}
  for _, r in ipairs(sql('SELECT agent FROM group_members WHERE gid = ? AND current = 1 ORDER BY pos', {gid})) do out[#out + 1] = r.agent end
  return out
end
local function delivered(agent, id)
  return #sql('SELECT 1 AS x FROM deliveries d JOIN messages m ON m.seq = d.seq WHERE d.agent = ? AND m.id = ?', {agent, id}) == 1
end
local function writes()
  return sql([[SELECT CAST((SELECT n FROM clock) AS TEXT) AS n, (SELECT count(*) FROM operations) AS operations,
    (SELECT count(*) FROM group_members) AS members]])[1]
end
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
  local op = f:action('new_thread', 'submit', {values = {title = 'Membership review', ['member_' .. alice.id] = true, ['member_' .. bob.id] = true}})
  expect(op.status).to_be('succeeded')
  local id = op.result.navigate:match('^thread/(.+)$')
  editable = {id = id}
  expect(members_of(id)).to_equal({alice.id, bob.id, 'user'})
end)

test('a member change in the form keeps delivered mail and other groups', function()
  old_mail = alice:call('messaging.send', {to = editable.id, body = 'Before membership changed', key = 'before-members'})
  old_rev = sql('SELECT * FROM messages WHERE id = ?', {old_mail.id})[1]
  local other = alice:call('messaging.thread_create', {key = 'other-group', title = 'Other group', members = {bob.id, 'user'}})
  local f = menu_form(editable.id, 'members')
  expect(find(H.node(f:render(), 'thread_members').fields, 'member_' .. bob.id).value).to_be(true)
  local op = f:action('thread_members', 'submit', {values = {['member_' .. alice.id] = true, ['member_' .. charlie.id] = true}}, 'change-members')
  expect(op.result).to_equal({close_form = true})
  expect(members_of(other.id), 'another group is unchanged').to_equal({alice.id, bob.id, 'user'})
  expect(members_of(editable.id)).to_equal({alice.id, charlie.id, 'user'})
  expect(sql('SELECT * FROM messages WHERE id = ?', {old_mail.id})[1], 'membership never rewrites old messages').to_equal(old_rev)
  expect(delivered(bob.id, old_mail.id), 'the audience of a sent message stays').to_be(true)
  expect(delivered(charlie.id, old_mail.id)).to_be(false)
end)

test('members as a tool: a replay returns the first result; changed members under the key conflict', function()
  local args = {thread = editable.id, members = {charlie.id, 'user'}, key = 'tool-members'}
  local first = alice:call('messaging.thread_members', args)
  local before = writes()
  expect(alice:call('messaging.thread_members', args)).to_equal(first)
  expect(writes(), 'a replay does not write').to_equal(before)
  expect_error(function() alice:call('messaging.thread_members', {thread = editable.id, members = {bob.id, 'user'}, key = 'tool-members'}) end, 'different content')
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

test('a send after a membership change goes to the new members', function()
  alice:call('messaging.thread_members', {thread = editable.id, members = {bob.id, 'user'}, key = 'members-back'})
  local sent = alice:call('messaging.send', {to = editable.id, body = 'New members', key = 'membership-after'})
  expect(delivered(bob.id, sent.id)).to_be(true)
  expect(delivered(charlie.id, sent.id)).to_be(false)
end)

test('adding members to a direct thread creates a group; the direct history stays', function()
  alice:call('messaging.send', {to = 'user', body = 'direct hello', key = 'direct-hello'})
  local f = menu_form(alice.id, 'members')
  local op = f:action('thread_members', 'submit', {values = {['member_' .. alice.id] = true, ['member_' .. bob.id] = true}}, 'expand-direct')
  expect(op.result.navigate:match('^thread/g%-')).to_be_truthy()
  local tree = user:open('thread/' .. alice.id):render()
  expect(#H.node(tree, 'history').messages > 0, 'the direct history remains').to_be(true)
end)

test('the team has no members form', function()
  local op = menu_form('team', 'members')
  expect(op.status).to_be('failed')
  expect(op.error.message).to_match('Unknown thread menu action')
end)

test('a creation key saved in a format from before 4.2 conflicts', function()
  -- Keys are retry guards. The older formats are removed (coordinator ruling, 2026-10-22): a
  -- retry of a days-old key gets a conflict, not its old result.
  local key = 'thread-create/' .. part('user') .. part('old-create-no-home')
  sql_write('INSERT INTO operations (key, owner, fingerprint, result) VALUES (?, ?, ?, ?)', {key, 'user',
    'thread-create-v1/' .. part('') .. part(charlie.id) .. part('user'),
    '{"id":"charlie","title":"charlie","members":["charlie","user"],"group":false}'})
  user:command('new_thread')
  local f = user:view('/forms/new-thread')
  f:render()
  local op = f:action('new_thread', 'submit', {values = {['member_' .. charlie.id] = true}}, 'old-create-no-home')
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('operation_conflict')
  expect(#sql("SELECT 1 AS x FROM thread_homes WHERE thread_a = ? AND thread_b = 'user'", {charlie.id})).to_be(0)
end)
