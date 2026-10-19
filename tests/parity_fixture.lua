-- Parity fixture (LazyRex docs/testing.md, "Agent parity"): renders the forms that open only
-- from a thread view, so the parity sweep checks them.
local alice = agent('alice')
local g = alice:call('messaging.thread_create', {key = 'parity-fixture', title = 'Parity', members = {'user', 'bob'}})
local thread = user:open('thread/' .. g.id)
thread:render()

local function menu()
  local op = thread:action('thread_menu', 'open', {})
  if op.status ~= 'succeeded' or op.effects == 'failed' then error('thread menu did not open: ' .. show(op), 0) end
  local m = user:view('/forms/thread-menu')
  m:render()
  return m
end

for _, item in ipairs({'rename', 'move', 'members'}) do
  local m = menu()
  local op = m:action('thread_menu', item, {item_id = item})
  if op.status ~= 'succeeded' or op.effects == 'failed' then error(item .. ' form did not open: ' .. show(op), 0) end
  user:view('/forms/thread-' .. item):render()
end
