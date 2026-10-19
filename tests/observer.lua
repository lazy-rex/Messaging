-- Ported from the Node test messaging.mjs (coverage map: commit eaaf529): the user observes agent-only threads. Read-only directs, an
-- atomic group join by the first message, unread isolation, and the full history of a long
-- thread in pages under the 64 KiB control-message limit.

local function part(s) return #s .. ':' .. s end
local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end)) end
local function find(list, id)
  for _, t in ipairs(list or {}) do if t.id == id then return t end end
end
local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')
local group, old, direct_id

local function panel()
  user:command('threads')
  return user:view('/panels/threads', nil, H.args.tests_session)
end

test('agent-only threads appear as observed, with no tab and no unread', function()
  group = alice:call('messaging.thread_create', {key = 'observer-group', title = 'Agent discussion', members = {'bob'}})
  old = alice:call('messaging.send', {to = group.id, key = 'observer-old', body = 'Before the user joined'})
  alice:call('messaging.send', {to = 'bob', key = 'observer-direct', body = 'A direct note'})
  direct_id = 'd-' .. hex(part('alice') .. part('bob'))
  expect(tab('thread/' .. group.id), 'an observed group is not opened automatically').to_be(nil)
  expect(tab('thread/' .. direct_id), 'an observed direct needs an explicit open').to_be(nil)
  local tree = panel():render()
  local observed = H.node(tree, 'observed_threads').items
  expect(find(observed, group.id).detail).to_be('Send a message to join')
  expect(find(observed, direct_id).detail).to_be('Read-only direct thread')
  expect(find(H.node(tree, 'threads').items, group.id)).to_be(nil)
end)

local direct_view
test('an observed direct opens read-only, without status or token, and refuses drafts and sends', function()
  local op = panel():action('observed_threads', 'open', {item_id = direct_id})
  expect(op.result).to_equal({navigate = 'thread/' .. direct_id})
  local t = tab('thread/' .. direct_id)
  expect(t.status).to_be(nil)
  expect(t.revision).to_be('')
  direct_view = user:view('thread/' .. direct_id)
  local tree = direct_view:render()
  expect(H.node(tree, 'composer')).to_be(nil)
  expect(H.node(tree, 'observer_notice').text).to_match('read%-only')
  expect(#H.node(tree, 'history').messages > 0).to_be(true)
  op = direct_view:draft('composer', 'No', '0', 'readonly-draft')
  expect(op.status).to_be('failed')
  expect(op.error.message).to_match('read%-only')
  op = direct_view:send('composer', 'No', '0', 'readonly-send')
  expect(op.status).to_be('failed')
  expect(op.error.message).to_match('read%-only')
end)

test('observing acknowledges and delivers nothing; agents get no observer threads', function()
  local before = store('mailbox/' .. part('user'))
  direct_view:seen()
  local gv = user:open('thread/' .. group.id)
  gv:render()
  gv:seen()
  rex.sleep(1) -- view.seen runs in the hub's view worker
  expect(store('mailbox/' .. part('user')), 'observation does not acknowledge or deliver mail').to_equal(before)
  local list = charlie:call('messaging.thread_list', {}).threads
  expect(find(list, group.id) or find(list, direct_id), 'agents do not get observer threads').to_be(nil)
  expect_error(function() charlie:call('messaging.history', {thread = group.id}) end, 'Only a current member')
end)

local joined
test('the first message joins the group atomically, retries a concurrent rename, and backfills nothing', function()
  local v = user:view('thread/' .. group.id)
  local tree = v:render()
  expect(H.node(tree, 'observer_notice').text).to_match('first message')
  expect(tab('thread/' .. group.id).status).to_be(nil)
  local saved = v:draft('composer', 'Joining the discussion', '0', 'join-draft')
  expect(saved.status).to_be('succeeded')
  local bad = v:send('composer', 'Joining the discussion', '0', 'bad-join')
  expect(bad.status).to_be('failed')
  expect(bad.error.message).to_match('draft differs')
  local members = store('groups').value.groups[group.id].members
  for _, m in ipairs(members) do expect(m, 'a refused send does not join').not_to_be('user') end
  -- A legacy message has no inline delivery snapshot; joining must keep its old audience.
  local legacy = store('message/' .. old.id).value
  legacy.recipients = nil
  write({{key = 'message/' .. old.id, value = legacy}})
  local user_box = store('mailbox/' .. part('user'))
  local groups = store('groups').value
  groups.groups[group.id].name = 'Agent discussion after concurrent rename'
  local join_key = 'send/' .. part('user') .. part('join-group')
  -- Atomic join: a failed commit leaves neither the membership nor the message. The hub retries
  -- the operation (the outcome was unknown); three failures, then a concurrent rename.
  local failing = inject({match = {op_key = join_key}, fail = 'Injected join failure', fail_code = 'unavailable', times = 3})
  local renaming = inject({match = {op_key = join_key}, ops = {{key = 'groups', value = groups}}})
  local _, k = v:admit('send', {node_id = 'composer', text = 'Joining the discussion', draft_revision = saved.result.draft_revision, operation_key = 'join-group'})
  wait('a failed join commit', function() if injection(failing).consumed >= 1 then return true end end)
  expect(operation(k).status, 'the join is still pending').to_be('pending')
  for _, m in ipairs(store('groups').value.groups[group.id].members) do expect(m, 'a failed join commits no membership').not_to_be('user') end
  expect(store('message/' .. join_key).rev, 'and no message').to_be('0')
  joined = v:settle(k)
  expect(injection(failing).consumed).to_be(3)
  expect(injection(renaming).consumed, 'the join retried a concurrent group rename').to_be(1)
  expect(joined.status).to_be('succeeded')
  local writes = batches()
  local again = v:send('composer', 'Joining the discussion', saved.result.draft_revision, 'join-group')
  expect(again.result, 'joining and sending are idempotent').to_equal(joined.result)
  expect(batches(), 'the repeat writes nothing').to_be(writes)
  local n = 0
  for _, m in ipairs(store('groups').value.groups[group.id].members) do if m == 'user' then n = n + 1 end end
  expect(n).to_be(1)
  expect(store('mailbox/' .. part('user')), 'joining does not backfill unread history').to_equal(user_box)
  expect(store('delivery/' .. part(old.id)).value.ids, 'legacy history keeps its recipients').to_equal({'bob'})
  local tree2 = panel():render()
  expect(find(H.node(tree2, 'observed_threads').items, group.id)).to_be(nil)
  expect(H.node(v:render(), 'observer_notice')).to_be(nil)
end)

test('only future messages become unread for the joined user', function()
  local mid = joined.result.message_id
  local read = bob:call('messaging.read', {thread = group.id}).messages
  expect(find(read, mid)).to_be_truthy()
  bob:call('messaging.send', {to = group.id, key = 'observer-future', body = 'Welcome'})
  local t = wait('one unread for the user', function()
    local x = tab('thread/' .. group.id)
    if x and x.status and x.status.msg == '1 unread' then return x end
  end)
  expect(t.title).to_match('%(1%)$')
end)

test('a long thread: the view holds the newest messages; history pages reach the first one', function()
  for i = 0, 204 do alice:call('messaging.send', {to = 'bob', key = 'observer-page-' .. i, body = 'Older message ' .. i}) end
  local history = H.node(direct_view:render(), 'history')
  expect(history.has_more).to_be(true)
  expect(#history.messages > 0).to_be(true)
  expect(history.load_action, 'no load action: the transcript pages').to_be(nil)
  expect(#rex.json.encode(history) < 45000, 'the tail fits in one control message').to_be(true)
  local ids, seen = {}, {}
  for _, m in ipairs(history.messages) do ids[#ids + 1] = m.id end
  local before, more = ids[1], true
  while more do
    local page = direct_view:history(before)
    expect(#rex.json.encode(page) < 60000, 'a page fits in one control message').to_be(true)
    expect(#page.messages > 0).to_be(true)
    for i = #page.messages, 1, -1 do table.insert(ids, 1, page.messages[i].id) end
    before, more = page.messages[1].id, page.has_more
  end
  for _, id in ipairs(ids) do
    expect(seen[id], 'pages do not overlap').to_be(nil)
    seen[id] = true
  end
  expect(#ids >= 206, 'pages reach the first message').to_be(true)
  expect_error(function() direct_view:history('no-such-id') end, 'Unknown history cursor')
end)

test('a long message arrives whole within one control message', function()
  alice:call('messaging.send', {to = 'bob', key = 'observer-huge', body = string.rep('y', 15000)})
  local tail = H.node(direct_view:render(), 'history')
  expect(#tail.messages[#tail.messages].text).to_be(15000)
  expect(#rex.json.encode(tail) < 60000).to_be(true)
end)

test('the overview of an observed direct lists both agents; history load is refused', function()
  direct_view:action('thread_menu', 'open', {})
  local menu = user:view('/forms/thread-menu', nil, direct_view.session)
  local tree = menu:render()
  expect(find(H.node(tree, 'thread_menu').items, 'older'), 'no older item').to_be(nil)
  expect(H.node(tree, 'summary').text:find('showing'), 'no "showing" summary').to_be(nil)
  expect(#H.node(tree, 'agents').items, 'an observed direct lists both agents').to_be(2)
  local op = direct_view:action('history', 'load', {}, 'observer-load-1')
  expect(op.status).to_be('failed')
end)
