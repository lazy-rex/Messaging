-- Ported from the Node test messaging.mjs (coverage map: commit eaaf529): identity migration (a legacy roster name becomes a conversation
-- identity), old operation retries, historical cursors, the thread menu overview, thread renames
-- (the form and a Rex tab rename), short identity names, and a draft conflict during migration.
-- The hub makes the identities from real reports in the agent panes (hub.identity.report).

local function one(q, p) return sql(q, p)[1] end
local function unread(name) return one('SELECT count(*) AS n FROM deliveries WHERE agent = ? AND acked = 0', {name}).n end
local function message(id) return one('SELECT * FROM messages WHERE id = ?', {id}) end
local function draft(viewer, peer) return one('SELECT text FROM drafts WHERE viewer = ? AND peer = ?', {viewer, peer}) end
local function title_of(viewer, peer) return one('SELECT title FROM thread_titles WHERE viewer = ? AND peer = ?', {viewer, peer}) end
local function home(a, b) return one('SELECT home_session FROM thread_homes WHERE thread_a = ? AND thread_b = ?', {a, b}) end
-- write runs sql_write; while a tab declaration of the plugin holds a transaction, it waits.
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
local function writes()
  return one([[SELECT CAST((SELECT n FROM clock) AS TEXT) AS n, (SELECT count(*) FROM operations) AS operations,
    (SELECT count(*) FROM deliveries) AS deliveries]])
end
local function find(list, id)
  for _, t in ipairs(list or {}) do if t.id == id then return t end end
end
local function has_id(list, id) return find(list, id) ~= nil end

local alice_id, bob_id, charlie_id = 'claude:conversation-a', 'codex:conversation-b', 'claude:conversation-c'
local bob_home = session('Bob home')
-- Thread homes are real sessions: the hub places a tab in its home.
local first_home, later_home = session('first alias home'), session('later alias home')
local alice = agent('alice', {title = 'alice tab'})
local bob = agent('bob', {title = 'bob tab', session = bob_home})
local charlie = agent('charlie', {title = 'charlie tab'})

local retry_args = {to = 'bob', body = 'legacy migration message', key = 'migration-retry'}
local group_args = {key = 'migration-group', title = 'Migration group', members = {'bob', 'user'}}
local retry_result, historical, legacy_group

test('legacy data before the identities exist', function()
  retry_result = alice:call('messaging.send', retry_args)
  historical = message(retry_result.id)
  legacy_group = alice:call('messaging.thread_create', group_args)
  -- The user opens the direct thread with alice (explicit open intent) and keeps the view open.
  user:open('thread/alice'):render() -- an empty direct thread: view.open records the open intent
  alice:call('messaging.send', {to = 'user', body = 'hello user', key = 'to-user'})
  sql_write("INSERT INTO thread_archived (viewer, peer) VALUES ('user', 'alice')")
  sql_write("INSERT INTO drafts (viewer, peer, text, rev) VALUES ('user', 'alice', 'keep the legacy draft', 1)")
  sql_write('UPDATE clock SET n = n + 1')
  sql_write([[INSERT INTO messages (seq, id, sender, recipient, thread_a, thread_b, body, at)
    SELECT n, 'canonical-before-migration', 'user', ?, ?, 'user', 'existing canonical mail', '2026-10-17T00:00:00Z' FROM clock]], {bob_id, bob_id})
  sql_write("INSERT INTO deliveries (agent, seq, acked) SELECT ?, seq, 0 FROM messages WHERE id = 'canonical-before-migration'", {bob_id})
  sql_write("INSERT INTO thread_homes (thread_a, thread_b, home_session, moved, set_rev) VALUES ('alice', 'bob', ?, 0, 1)", {first_home})
  sql_write("INSERT INTO thread_homes (thread_a, thread_b, home_session, moved, set_rev) VALUES (?, ?, ?, 0, 2)", {alice_id, bob_id, later_home})
end)

test('migration moves mailboxes, groups, drafts, archives and homes to the identities', function()
  alice:report({kind = 'claude', conversation_id = 'conversation-a'})
  bob:report({kind = 'codex', conversation_id = 'conversation-b'})
  local migrated = bob:call('messaging.read', {})
  local m = find(migrated.messages, retry_result.id)
  expect(m.from).to_be(alice_id)
  expect(m.to).to_be(bob_id)
  expect(has_id(migrated.messages, 'canonical-before-migration')).to_be(true)
  expect(home(alice_id, bob_id).home_session, 'the first alias home wins').to_be(first_home)
  expect(home('alice', 'bob')).to_be(nil)
  expect(unread('bob') + unread('alice'), 'no delivery keeps a legacy name').to_be(0)
  local moved = message(retry_result.id)
  expect(moved.seq, 'historical messages keep their cursors').to_be(historical.seq)
  expect(moved.body).to_be(historical.body)
  local members = {}
  for _, r in ipairs(sql('SELECT agent FROM group_members WHERE gid = ? AND current = 1 ORDER BY pos', {legacy_group.id})) do members[#members + 1] = r.agent end
  expect(members).to_equal({alice_id, bob_id, 'user'})
  expect(draft('user', 'alice')).to_be(nil)
  expect(draft('user', alice_id).text).to_be('keep the legacy draft')
  expect(one('SELECT 1 AS x FROM thread_opened WHERE viewer = ? AND peer = ?', {'user', alice_id}), 'migration keeps the explicit open intent').to_be_truthy()
  expect(one('SELECT 1 AS x FROM thread_archived WHERE viewer = ? AND peer = ?', {'user', alice_id})).to_be_truthy()
  expect(notice('bob').pending, 'the legacy notice is cleared').to_be(false)
  expect(notice(bob_id).pending).to_be(true)
  bob:call('messaging.ack', {ids = {retry_result.id}})
  expect(has_id(bob:call('messaging.read', {}).messages, retry_result.id)).to_be(false)
end)

test('old operation keys return their original results after migration', function()
  local before = writes()
  expect(alice:call('messaging.send', retry_args)).to_equal(retry_result)
  expect(writes(), 'a retry does not write again').to_equal(before)
  expect(alice:call('messaging.thread_create', group_args)).to_equal(legacy_group)
  expect_error(function() alice:call('messaging.send', {to = 'bob', body = 'changed', key = 'migration-retry'}) end, 'different content')
  local fresh = alice:call('messaging.send', {to = 'bob tab', body = 'canonical new message', key = 'new-identity-send'})
  expect(message(fresh.id).sender).to_be(alice_id)
  expect(message(fresh.id).recipient).to_be(bob_id)
end)

test('the user sees the migrated thread: archive, history, draft; the old name still resolves', function()
  -- The plugin no longer declares thread/alice, so the hub closed its view.
  expect(tab('thread/alice')).to_be(nil)
  user:command('threads')
  local p = user:view('/panels/threads')
  expect(has_id(H.node(p:render(), 'archived_threads').items, alice_id)).to_be(true)
  local op = p:action('archived_threads', 'restore', {item_id = alice_id})
  expect(op.result).to_equal({navigate = 'thread/' .. alice_id})
  local tree = user:view('thread/' .. alice_id):render()
  expect(#H.node(tree, 'history').messages > 0, 'the identity thread shows the legacy history').to_be(true)
  expect(H.node(tree, 'composer').text).to_be('keep the legacy draft')
  expect(#bob:call('messaging.read', {thread = 'alice'}).messages >= 0, 'the legacy name resolves for a tool').to_be(true)
end)

local thread_view, menu
test('New Thread form: source session, a new session choice, other-session members, cancel', function()
  thread_view = user:view('thread/' .. alice_id)
  thread_view:render()
  user:command('new_thread', thread_view) -- the palette in the thread pane: its source view
  local form = user:view('/forms/new-thread')
  local tree = form:render()
  expect(form:get().status).to_equal({state = 'blocked', kind = 'question', msg = 'Waiting for input'})
  local fields = H.node(tree, 'new_thread').fields
  local s = find(fields, 'session_id')
  expect(s.value, 'the source view session').to_be(thread_view.session)
  local new_choice = false
  for _, o in ipairs(s.options or {}) do if o.value == '@new' then new_choice = true end end
  expect(new_choice, 'a new session is a choice').to_be(true)
  expect(find(fields, 'other_sessions').kind).to_be('boolean')
  expect(find(fields, 'member_' .. bob_id).visible_when.field, 'a member in another session hides behind other_sessions').to_be('other_sessions')
  expect(H.node(tree, 'cancel').action.name).to_be('$cancel')
  form:action('cancel', '$cancel', {})
end)

test('the thread menu is an overview: summary, agents, actions, Close', function()
  thread_view:action('thread_menu', 'open', {})
  menu = user:view('/forms/thread-menu')
  local tree = menu:render()
  expect(tree.menu).to_be(true)
  expect(menu:get().status.state).to_be('blocked')
  expect(H.node(tree, 'summary').text).to_match('^1 agent · %d+ messages?')
  local rows = H.node(tree, 'agents').items
  expect(#rows).to_be(1)
  expect(rows[1].id).to_be(alice_id)
  expect(rows[1].action.enabled and rows[1].status and rows[1].icon, 'an agent row opens its tab').to_be_truthy()
  expect(has_id(H.node(tree, 'thread_menu').items, 'older'), 'no older item').to_be(false)
  expect(tree.nodes[#tree.nodes].action.label).to_be('Close')
  local op = menu:action('agents', 'agent', {item_id = bob_id})
  expect(op.status).to_be('failed')
  expect(op.error.message).to_match('not in this thread')
  op = menu:action('agents', 'agent', {item_id = alice_id})
  expect(op.status, 'hub.navigate.agent found the agent tab').to_be('succeeded')
  expect(op.result).to_equal({close_form = true})
end)

test('rename from the menu form, then a Rex tab rename wins over an old form retry', function()
  thread_view:action('thread_menu', 'open', {})
  menu = user:view('/forms/thread-menu')
  menu:render()
  local op = menu:action('thread_menu', 'rename', {item_id = 'rename'})
  expect(op.result).to_equal({form = '/forms/thread-rename'})
  local form = user:view('/forms/thread-rename')
  local tree = form:render()
  expect(tree.menu).to_be(true)
  expect(H.node(tree, 'rename_thread')).to_be_truthy()
  op = form:action('rename_thread', 'submit', {values = {title = 'From form'}}, 'rename-form')
  expect(op.result).to_equal({close_form = true})
  expect(thread_view:render().title).to_be('From form')
  -- The user renames the Rex tab; the hub sends view.rename.
  thread_view:rename_tab('  Release notes  ')
  local title = wait('view.rename', function()
    local t = thread_view:render().title
    if t == 'Release notes' then return t end
  end)
  expect(title).to_be('Release notes')
  expect(title_of('user', alice_id).title).to_be('Release notes')
  expect(operation('rename-form').status, 'the form operation is final').to_be('succeeded')
  expect_error(function() user:plugin_view('rename', {route = '/thread/' .. alice_id, user = 'user', title = 'Wrong caller'}) end, 'Only the hub')
end)

test('an unnamed identity shows a short ID; declared titles are never empty', function()
  -- An empty Rex label restores the generated default label, so '' cannot reach the hub.
  user:open('thread/' .. bob_id):render()
  for _, label in ipairs({'  ', bob_id}) do
    bob:set_label(label)
    local ok = wait('the tab title of bob with label ' .. string.format('%q', label), function()
      local t = tab('thread/' .. bob_id)
      if t and t.title:find('^codex:conversa') then return t end
    end, 5)
    expect(ok.title).to_match('^codex:conversa')
    for _, t in ipairs(tabs()) do expect(t.title:match('%S'), 'tab ' .. t.key).to_be_truthy() end
    -- The New Thread member field shows the same short name.
    user:command('new_thread')
    local form = user:view('/forms/new-thread', nil, H.args.tests_session)
    local field
    for _, f in ipairs(H.node(form:render(), 'new_thread').fields) do if f.id == 'member_' .. bob_id then field = f end end
    expect(field.label, 'the member field label').to_be('codex:conversa')
    form:action('cancel', '$cancel', {})
  end
  bob:set_label('bob tab')
end)

test('two different drafts stop a migration until one is removed', function()
  sql_write("INSERT INTO drafts (viewer, peer, text, rev) VALUES ('user', 'charlie', 'old draft', 1)")
  sql_write("INSERT INTO drafts (viewer, peer, text, rev) VALUES ('user', ?, 'new draft', 2)", {charlie_id})
  sql_write("INSERT INTO thread_titles (viewer, peer, title, set_rev) VALUES ('user', 'charlie', 'Legacy title', 1)")
  sql_write("INSERT INTO thread_titles (viewer, peer, title, set_rev) VALUES ('user', ?, 'Latest title', 2)", {charlie_id})
  charlie:report({kind = 'claude', conversation_id = 'conversation-c'})
  expect_error(function() alice:call('messaging.read', {}) end, 'Two drafts have different text')
  expect(draft('user', 'charlie').text).to_be('old draft')
  expect(draft('user', charlie_id).text).to_be('new draft')
  write_sql("DELETE FROM drafts WHERE viewer = 'user' AND peer = ?", {charlie_id})
  alice:call('messaging.read', {})
  expect(draft('user', charlie_id).text).to_be('old draft')
  expect(title_of('user', charlie_id).title).to_be('Latest title')
  expect(title_of('user', 'charlie')).to_be(nil)
end)
