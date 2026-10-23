-- Ported from the Node test messaging.mjs (coverage map: commit eaaf529): the plugin contract on the real hub. The exports reach the agent
-- face; only the hub may forward a call or call view.*; the agent face refuses an action that the
-- plugin does not export; a forwarded call keeps the agent's identity.

local exports = {'messaging.send', 'messaging.read', 'messaging.ack', 'messaging.thread_list', 'messaging.thread_create',
  'messaging.history', 'messaging.thread_archive', 'messaging.thread_rename', 'messaging.thread_members', 'messaging.thread_move'}

local function client(label)
  local r = rex.call('target.resolve', {kinds = {'client'}, queries = {label}})
  local x = r and r.results and r.results[1]
  if not x or x.status ~= 'resolved' then error('cannot resolve client ' .. label, 0) end
  return x.target.client_id
end

local alice = agent('alice')

test('the agent face lists every export, and the plugin registered with its label', function()
  local face = rex.call('client.inspect', {client_id = client('lazyrex')})
  local names = {}
  for _, a in ipairs(face.actions) do names[a.name] = true end
  for _, e in ipairs(exports) do expect(names[e], e).to_be(true) end
  expect(names['view.render'], 'view actions are not exported').to_be(nil)
  local plugin = rex.call('client.inspect', {client_id = client('lazyrex-plugin:messaging')})
  local own = {}
  for _, a in ipairs(plugin.actions) do own[#own + 1] = a.name end
  for _, e in ipairs(exports) do expect(own).to_contain(e) end
end)

test('only the hub may call hub.forward or view.*', function()
  local args = {action = 'messaging.read', args = {}, requester_pid = alice.pid}
  expect_error(function() alice:direct('hub.forward', args) end, 'Only the hub')
  expect_error(function() H.perform(client('lazyrex-plugin:messaging'), 'hub.forward', args) end, 'Only the hub')
  expect_error(function() alice:direct('view.render', {route = '/panels/threads', user = 'user'}) end, 'Only the hub')
end)

test('the agent face refuses an action that the plugin does not export', function()
  expect_error(function() alice:call('view.render', {route = '/panels/threads', user = 'user'}) end, 'view.render')
end)

test('a forwarded call is the same as a direct call of the same agent', function()
  alice:call('messaging.send', {to = agent('bob').id, body = 'forward check', key = 'forward-check'})
  local direct = alice:direct('messaging.thread_list', {})
  local forwarded = alice:call('messaging.thread_list', {})
  expect(forwarded).to_equal(direct)
end)
