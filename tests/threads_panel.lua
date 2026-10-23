-- The Threads panel stays under the view limit at any number of threads. On the live hub
-- (2026-10-22) 273 threads, with a New-thread form inside the panel, gave a 134 KB render: the hub
-- refused it (too_large, the limit is 49152 bytes). This file makes three times the live count:
-- 600 threads of the user and 220 agent-only threads, each with a 170-character group ID like the
-- live ones, and archives 60 of the user's threads. Every thread stays reachable through More.

local alice, bob = agent('alice'), agent('bob')
local limit = 49152

-- write_sql runs sql_write; while the plugin holds a transaction, it waits.
local function write_sql(q, p)
  local out = wait('a SQL fixture write', function()
    local ok, r = pcall(sql_write, q, p)
    if ok then return {r} end
    local text = type(r) == 'table' and tostring(r.code) .. ': ' .. tostring(r.message) or tostring(r)
    if not text:find('busy', 1, true) then return {nil, r} end -- another error: no retry
  end)
  if out[2] ~= nil then error(out[2], 0) end
  return out[1]
end

-- groups writes n created groups whose IDs start with prefix, padded to 170 characters, with
-- the given members.
local function groups(prefix, n, members)
  local series = 'WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < ?) '
  local gid = "'" .. prefix .. "' || printf('%0" .. (170 - #prefix) .. "d', value)"
  write_sql(series .. 'INSERT INTO groups (gid, name) SELECT ' .. gid .. ", 'Thread ' || value FROM n", {n})
  for pos, member in ipairs(members) do
    write_sql(series .. 'INSERT INTO group_members (gid, agent, pos, current) SELECT ' .. gid .. ', ?, ?, 1 FROM n',
      {n, member, pos})
  end
end

local function size(tree) return #assert(rex.json.encode(tree)) end
local function panel()
  user:command('threads')
  return user:view('/panels/threads', nil, H.args.tests_session)
end

-- walk opens a list from the panel (show, or more from the panel's own list) and follows every
-- More item. It returns the IDs of all items, in order, and checks each page's size.
local function walk(id, from_view, action, input)
  local ids = {}
  local view, op = from_view, from_view:action(id, action, input)
  while true do
    expect(op.status, id .. ' ' .. action).to_be('succeeded')
    local route = op.result.form
    expect(route:match('^/forms/threads/') ~= nil, route).to_be(true)
    view = user:view(route)
    local tree = view:render()
    expect(size(tree) < limit, route .. ' is ' .. size(tree) .. ' bytes').to_be(true)
    local more
    for _, item in ipairs(H.node(tree, id).items) do
      if item.id:match('^more:') then more = item.id else ids[#ids + 1] = item.id end
    end
    if not more then return ids, view end
    op, action = view:action(id, 'more', {item_id = more}), 'more'
  end
end

test('the panel stays under the limit at three times the live thread count', function()
  groups('g-u', 600, {'user', alice.id})
  groups('g-a', 220, {alice.id, bob.id})
  write_sql([[WITH RECURSIVE n(value) AS (SELECT 1 UNION ALL SELECT value + 1 FROM n WHERE value < 60)
    INSERT INTO thread_archived (viewer, peer) SELECT 'user', 'g-u' || printf('%0167d', value) FROM n]])
  local tree = panel():render()
  expect(size(tree) < 40000, 'the panel is ' .. size(tree) .. ' bytes').to_be(true)
  -- The user's threads by name; agent-only and archived threads as a count.
  local items = H.node(tree, 'threads').items
  expect(items[#items].id:match('^more:') ~= nil, 'the list ends with More').to_be(true)
  expect(items[1].detail, 'no detail without unread messages').to_be(nil)
  expect(H.node(tree, 'observed_threads').text).to_be('Agent-only threads (220)')
  expect(H.node(tree, 'archived_threads').text).to_be('Archived (60)')
  expect(H.node(tree, 'new_thread').type, 'no New thread form inside the panel').to_be('widget')
end)

test('More reaches every thread of each list, one bounded page at a time', function()
  local p = panel()
  local tree = p:render()
  local items = H.node(tree, 'threads').items
  local shown = {}
  for _, item in ipairs(items) do if not item.id:match('^more:') then shown[#shown + 1] = item.id end end
  local rest = walk('threads', p, 'more', {item_id = items[#items].id})
  local count = {}
  for _, id in ipairs(shown) do count[id] = (count[id] or 0) + 1 end
  for _, id in ipairs(rest) do count[id] = (count[id] or 0) + 1 end
  local mine = 0
  for id, n in pairs(count) do
    expect(n, id .. ' appears once').to_be(1)
    if id:match('^g%-u') then mine = mine + 1 end
  end
  expect(mine, 'every unarchived thread of the user').to_be(540)
  local observed = walk('observed_threads', panel(), 'show', {})
  expect(#observed).to_be(220)
  local archived = walk('archived_threads', panel(), 'show', {})
  expect(#archived).to_be(60)
end)

test('a thread on a later page opens; New thread opens its form', function()
  local ids, view = walk('observed_threads', panel(), 'show', {})
  local last = ids[#ids]
  local op = view:action('observed_threads', 'open', {item_id = last})
  expect(op.result).to_equal({navigate = 'thread/' .. last})
  op = panel():action('new_thread', 'new', {})
  expect(op.result).to_equal({form = '/forms/new-thread'})
  -- The panel has no form: a submit to it is an unknown action.
  op = panel():action('new_thread', 'submit', {values = {['member_' .. alice.id] = true}})
  expect(op.status).to_be('failed')
end)

test('thread_create refuses a key over 200 bytes, so every new group ID is bounded', function()
  expect_error(function()
    alice:call('messaging.thread_create', {key = string.rep('k', 201), title = 'Too long', members = {'user'}})
  end, 'the limit is 200')
  local g = alice:call('messaging.thread_create', {key = string.rep('k', 200), title = 'Bounded', members = {'user'}})
  expect(#g.id < 1000, 'the group ID is ' .. #g.id .. ' bytes').to_be(true)
  local tree = panel():render()
  expect(size(tree) < limit, 'the panel is ' .. size(tree) .. ' bytes').to_be(true)
end)
