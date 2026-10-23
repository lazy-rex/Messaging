-- A render reads only (SDK eb9654d refuses a write in a render). An alias that the rows do not
-- show yet waits for the refresh timer: the render shows the rows as they are, and the timer
-- merges them and declares the tabs again.

local alice_id = 'claude:conversation-render'
local alice = agent('alice')

local function applied(alias)
  return sql('SELECT identity FROM aliases_applied WHERE alias = ?', {alias})[1]
end
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

test('a render with an alias not yet applied reads, and the refresh applies the alias', function()
  alice:report({kind = 'claude', conversation_id = 'conversation-render'})
  alice:call('messaging.send', {to = 'user', body = 'before the render', key = 'render-alias'})
  wait('the alias merge', function() return applied('alice') end)
  local v = user:open('thread/' .. alice_id)
  v:render()
  -- The rows show the identity, but the plugin does not know the alias was applied.
  write_sql("DELETE FROM aliases_applied WHERE alias = 'alice'")
  local tree = v:render()
  expect(H.node(tree, 'history').messages[1].text).to_be('before the render')
  expect(applied('alice'), 'the render writes nothing').to_be(nil)
  local row = wait('the refresh to apply the alias', function() return applied('alice') end)
  expect(row.identity).to_be(alice_id)
end)

test('a render right after an identity report shows the rows under the old name, then the migrated thread', function()
  local bob, bob_id = agent('bob'), 'claude:conversation-render-bob'
  bob:call('messaging.send', {to = 'user', body = 'visible before the identity', key = 'pending-alias'})
  local v = user:open('thread/bob')
  expect(#H.node(v:render(), 'history').messages).to_be(1)
  bob:report({kind = 'claude', conversation_id = 'conversation-render-bob'})
  -- The hub resolves bob to the identity at once; the rows move only in the refresh.
  local tree = v:render()
  expect(#H.node(tree, 'history').messages, 'the render keeps the history under the old name').to_be(1)
  wait('the refresh to apply the alias', function() return applied('bob') end)
  wait('the old tab to close', function() return tab('thread/bob') == nil end)
  local moved = user:view('thread/' .. bob_id):render()
  expect(H.node(moved, 'history').messages[1].text).to_be('visible before the identity')
end)
