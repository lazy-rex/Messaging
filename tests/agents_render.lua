-- Read tracking (hub 4.2 default): a view renders again only when a table it read changes, or on a
-- hub change. Messaging views also show hub state: the participants and their names (hub.agents).
-- A new agent changes no SQL row. The hub renders the plugin's views again on hub.changed agents
-- (markChanged), so an open New thread form gets the new participant from a render for the change,
-- not for a commit, and without an app.refresh in Messaging.

-- has_text is true when the snapshot holds the string s anywhere.
local function has_text(v, s)
  if type(v) == 'string' then return v:find(s, 1, true) ~= nil end
  if type(v) ~= 'table' then return false end
  for _, x in pairs(v) do if has_text(x, s) then return true end end
  return false
end

-- causes returns the render cause counts of view v (hub.test.renders).
local function causes(v)
  for _, r in ipairs(H.renders()) do
    if r.view_id == v.id then return {changed = r.causes.changed or 0, commit = r.causes.commit or 0} end
  end
  error('no render record for ' .. v.route, 0)
end

test('a new agent appears in an open New thread form without a commit', function()
  local reporter = agent('reporter', {report = false})
  user:command('new_thread')
  local f = user:view('/forms/new-thread')
  f:render()
  expect(has_text(f:get(), 'render-new'), 'not there before').to_be(false)
  local before = causes(f)
  -- An identity report adds an agent (claude:render-new) to the roster: hub.changed agents.
  reporter:report({kind = 'claude', conversation_id = 'render-new'})
  -- No explicit render: the renderer's snapshot changes by itself.
  wait('the new participant in the open form', function() return has_text(f:get(), 'render-new') end, 20)
  -- The render came from the agents change, not from a commit of the plugin.
  local after = causes(f)
  expect(after.changed > before.changed, 'a render for the agents change').to_be(true)
  expect(after.commit, 'no render for a commit').to_be(before.commit)
end)
