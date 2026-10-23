-- Spawn binds (hub identity (d), lead-d-r1 and lead-d-r2): mail to an agent spawn that has not
-- reported yet is stored for "spawn:<id>". When the spawn reports, the rows move to its identity
-- (rebind_spawns). A spawn that ends unbound loses its waiting deliveries. The fake agent CLI
-- (`lazyrex-hub testagent cli`) reports after its first input line, so the test decides when the
-- bind comes. A file of its own: it crashes the hub. One sequence: each test uses the state of
-- the tests before it.

local alice = agent('alice')
local lab = H.args.lab

write_profiles({profiles = {{id = 'reporter', name = 'reporter', kind = 'agent', cwd = lab,
  command = {'/bin/sh', '-c', 'exec "$0" testagent cli codex "$1" startup prompt', H.args.hub_bin, '${conv}'},
  args = {{name = 'conv', required = true}}}}})

local function spawn(conv)
  local s = alice:hub('hub.spawn', {profile = 'reporter', key = 'spawn-' .. conv, args = {conv = conv}})
  expect(s.agent_id:sub(1, 6), 'the spawn address').to_be('spawn:')
  return s
end

-- prompt writes the first input line: the fake CLI then reports its identity codex:<conv>.
local function prompt(s)
  local _, err = rex.call('block.method', {session_id = s.session_id, block_id = s.block_id, method = 'write', args = {data = 'go\r'}})
  if err ~= nil then error('write: ' .. tostring(err), 0) end
end

local function delivered_to(id)
  local r = sql('SELECT d.agent FROM deliveries d JOIN messages m ON m.seq = d.seq WHERE m.id = ?', {id})[1]
  return r and r.agent
end

local function recipient(id) return sql('SELECT recipient FROM messages WHERE id = ?', {id})[1].recipient end

local bound, first, first_args
test('mail to an unbound spawn waits for "spawn:<id>"; the bind moves it to the identity', function()
  bound = spawn('bind-a')
  first_args = {to = bound.agent_id, body = 'before the report', key = 'sb-first'}
  first = alice:call('messaging.send', first_args)
  expect(recipient(first.id)).to_be(bound.agent_id)
  expect(delivered_to(first.id)).to_be(bound.agent_id)
  prompt(bound)
  wait('the delivery moves to codex:bind-a', function() return delivered_to(first.id) == 'codex:bind-a' end)
  expect(recipient(first.id)).to_be('codex:bind-a')
  expect(#sql("SELECT 1 AS x FROM messages WHERE recipient LIKE 'spawn:%'"), 'no spawn address stays').to_be(0)
end)

test('after the bind, a retry with the spawn address replays the first result', function()
  expect(alice:call('messaging.send', first_args)).to_equal(first)
end)

test('the identity reads the mail that waited for the spawn', function()
  -- A second pane resumes the conversation, so the identity is current where the test can call.
  local reader = agent('reader', {kind = 'codex', report = false})
  reader:report({kind = 'codex', conversation_id = 'bind-a', source = 'resume'})
  local got = reader:call('messaging.read', {})
  expect(#got.messages).to_be(1)
  expect(got.messages[1].id).to_be(first.id)
  expect(got.messages[1].to).to_be('codex:bind-a')
end)

test('a spawn that ends before it reports: its waiting delivery goes, the message stays', function()
  local s = spawn('ended-b')
  local m = alice:call('messaging.send', {to = s.agent_id, body = 'never read', key = 'sb-ended'})
  local _, err = rex.call('block.close', {session_id = s.session_id, block_id = s.block_id})
  if err ~= nil then error('block.close: ' .. tostring(err), 0) end
  wait('the waiting delivery goes', function() return delivered_to(m.id) == nil end)
  expect(recipient(m.id), 'the sender keeps the message').to_be(s.agent_id)
  expect(#sql('SELECT 1 AS x FROM spawns_ended WHERE id = ?', {s.agent_id})).to_be(1)
  expect_error(function() alice:call('messaging.send', {to = s.agent_id, body = 'again', key = 'sb-ended-2'}) end, 'not_delivered')
end)

test('at its start, Messaging moves the rows of a spawn that bound while it did not run', function()
  -- The rows are written after the bind, so only the start can move them.
  local s = spawn('start-c')
  prompt(s)
  wait('codex:start-c is bound', function()
    local ok, r = pcall(function() return alice:hub('hub.agents.resolve', {to = s.agent_id}) end)
    return ok and r.id == 'codex:start-c'
  end)
  sql_write('INSERT INTO thread_opened (viewer, peer) VALUES (?, ?)', {'user', s.agent_id})
  hub:restart({crash = true})
  wait('the start moves the row', function()
    return #sql('SELECT 1 AS x FROM thread_opened WHERE viewer = ? AND peer = ?', {'user', 'codex:start-c'}) == 1
  end)
  expect(#sql('SELECT 1 AS x FROM thread_opened WHERE peer = ?', {s.agent_id})).to_be(0)
end)
