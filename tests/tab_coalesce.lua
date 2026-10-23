-- hub.changed agents comes once for each change of the agents, and the hub does not coalesce
-- them. Messaging declared its tabs once for each, and each declaration reads the thread families
-- (about 1 s on the live hub after release 2, 2026-10-22). Bursts filled the plugin's request
-- queue (16). A burst must give one or two declarations, and the tabs must still be declared.
--
-- The count needs hub.test.calls (hub branch hub/test-calls). Without it, the file has one test
-- named SKIP and measures nothing.

local function calls_missing()
  if not H.calls then return 'the harness has no H.calls' end
  local ok, err = pcall(H.calls, 'none')
  if ok then return nil end
  local text = type(err) == 'table' and tostring(err.code) .. ': ' .. tostring(err.message) or tostring(err)
  if text:find('unknown') or text:find('not_supported') then return 'the hub refuses hub.test.calls (' .. text .. ')' end
  error(err, 0)
end
local missing = calls_missing()
if missing then
  test('SKIP: ' .. missing .. '; the tab declarations are not counted', function() end)
  return
end

local u = agent('burst', {report = false})

test('a burst of agent changes gives one or two tab declarations', function()
  local _, base = H.calls('none')
  -- Each identity report is a change of the agents: the hub sends hub.changed agents.
  for i = 1, 8 do u:report({kind = 'claude', conversation_id = 'burst-' .. i}) end
  wait('a tab declaration after the burst', function() return #H.calls('hub.ui.tabs', {after = base.next}) > 0 end)
  -- A declaration that was still to come would appear within this pause.
  rex.sleep(1)
  local tabs, got = H.calls('hub.ui.tabs', {after = base.next})
  expect(got.dropped, 'no call record dropped').to_be(false)
  expect(#tabs <= 2, 'tab declarations for 8 changes: ' .. #tabs).to_be(true)
end)

test('the coalesced declaration has the tab of a new thread', function()
  local alice = agent('alice')
  alice:call('messaging.send', {to = 'user', body = 'coalesced', key = 'coalesce-1'})
  local _, base = H.calls('none')
  u:report({kind = 'claude', conversation_id = 'burst-last'})
  local tabs = wait('a tab declaration after the change', function()
    local list = H.calls('hub.ui.tabs', {after = base.next})
    return #list > 0 and list
  end)
  local keys = {}
  for _, t in ipairs(tabs[#tabs].args.tabs) do keys[t.key] = true end
  expect(keys['thread/' .. alice.id], 'the declared tabs have thread/alice').to_be(true)
end)
