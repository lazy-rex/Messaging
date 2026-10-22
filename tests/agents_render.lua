-- Read tracking (hub 4.2 default): a view renders again only when a table it read changes, or on a
-- hub change. Messaging views also show hub state: the participants and their names (hub.agents).
-- A new agent changes no SQL row. The hub renders the plugin's views again on hub.changed agents
-- (markChanged), so an open New thread form gets the new participant without a SQL write and
-- without an app.refresh in Messaging.

wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

-- has_text is true when the snapshot holds the string s anywhere.
local function has_text(v, s)
  if type(v) == 'string' then return v:find(s, 1, true) ~= nil end
  if type(v) ~= 'table' then return false end
  for _, x in pairs(v) do if has_text(x, s) then return true end end
  return false
end

test('a new agent appears in an open New thread form without a SQL write', function()
  local reporter = agent('reporter', {join = false})
  user:command('new_thread')
  local f = user:view('/forms/new-thread')
  f:render()
  expect(has_text(f:get(), 'render-new'), 'not there before').to_be(false)
  local before = sql('SELECT CAST(n AS TEXT) AS n FROM clock')[1].n
  -- An identity report adds an agent (claude:render-new) to the roster: hub.changed agents.
  reporter:report({kind = 'claude', conversation_id = 'render-new'})
  -- No explicit render: the renderer's snapshot changes by itself.
  wait('the new participant in the open form', function() return has_text(f:get(), 'render-new') end, 20)
  expect(sql('SELECT CAST(n AS TEXT) AS n FROM clock')[1].n, 'no SQL write').to_be(before)
end)
