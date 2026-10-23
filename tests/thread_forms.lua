-- Ported from the Node test messaging.mjs (coverage map: commit eaaf529): the New Thread form, the
-- thread menu overview, thread renames (the form and a Rex tab rename) and short identity names.
-- The hub makes an identity from a real report in the agent pane (hub.identity.report).

local function one(q, p) return sql(q, p)[1] end
local function title_of(viewer, peer) return one('SELECT title FROM thread_titles WHERE viewer = ? AND peer = ?', {viewer, peer}) end
local function find(list, id)
  for _, t in ipairs(list or {}) do if t.id == id then return t end end
end
local function has_id(list, id) return find(list, id) ~= nil end

local bob_home = session('Bob home')
local alice = agent('alice', {title = 'alice tab'})
local bob = agent('bob', {title = 'bob tab', session = bob_home})
-- An identity with no roster name: the hub names it after its tab label.
local nameless = agent('nameless', {join = false, title = 'nameless tab'})
local nameless_id = 'codex:conversation-b'
nameless:report({kind = 'codex', conversation_id = 'conversation-b'})
alice:call('messaging.send', {to = 'user', body = 'hello user', key = 'to-user'})

local thread_view, menu
test('New Thread form: source session, a new session choice, other-session members, cancel', function()
  thread_view = user:open('thread/alice')
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
  expect(find(fields, 'member_bob').visible_when.field, 'a member in another session hides behind other_sessions').to_be('other_sessions')
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
  expect(rows[1].id).to_be('alice')
  expect(rows[1].action.enabled and rows[1].status and rows[1].icon, 'an agent row opens its tab').to_be_truthy()
  expect(has_id(H.node(tree, 'thread_menu').items, 'older'), 'no older item').to_be(false)
  expect(tree.nodes[#tree.nodes].action.label).to_be('Close')
  local op = menu:action('agents', 'agent', {item_id = 'bob'})
  expect(op.status).to_be('failed')
  expect(op.error.message).to_match('not in this thread')
  op = menu:action('agents', 'agent', {item_id = 'alice'})
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
  expect(title_of('user', 'alice').title).to_be('Release notes')
  expect(operation('rename-form').status, 'the form operation is final').to_be('succeeded')
  expect_error(function() user:plugin_view('rename', {route = '/thread/alice', user = 'user', title = 'Wrong caller'}) end, 'Only the hub')
end)

test('an unnamed identity shows a short ID; declared titles are never empty', function()
  -- An empty Rex label restores the generated default label, so '' cannot reach the hub.
  user:open('thread/' .. nameless_id):render()
  for _, label in ipairs({'  ', nameless_id}) do
    nameless:set_label(label)
    local ok = wait('the tab title of nameless with label ' .. string.format('%q', label), function()
      local t = tab('thread/' .. nameless_id)
      if t and t.title:find('^codex:conversa') then return t end
    end, 5)
    expect(ok.title).to_match('^codex:conversa')
    for _, t in ipairs(tabs()) do expect(t.title:match('%S'), 'tab ' .. t.key).to_be_truthy() end
    -- The New Thread member field shows the same short name.
    user:command('new_thread')
    local form = user:view('/forms/new-thread', nil, H.args.tests_session)
    local field
    for _, f in ipairs(H.node(form:render(), 'new_thread').fields) do if f.id == 'member_' .. nameless_id then field = f end end
    expect(field.label, 'the member field label').to_be('codex:conversa')
    form:action('cancel', '$cancel', {})
  end
  nameless:set_label('nameless tab')
end)
