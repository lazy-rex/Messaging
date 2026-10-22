-- The tab declaration (declare_tabs) runs after every mutating action, every view.seen and every
-- hub.changed agents. The key-value version read about four records for every peer; live, with
-- about a hundred identities, that was tens of thousands of gets per minute (coordinator,
-- 2026-10-21). In SQL, a send and its tab declaration run a fixed number of statements: the
-- statements must not grow with the number of peers.
--
-- The count needs hub.test.calls (hub branch hub/test-calls). On a harness without H.calls, or a
-- hub that refuses the action as unknown, the file has one test named SKIP and measures nothing.
-- The harness shows a passing test's name only with -v; the SKIP is not a measurement.

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
  test('SKIP: ' .. missing .. '; the tab read count is not measured', function() end)
  return
end

local alice = agent('alice')
-- The plugin imports at start (import.lua), in its own transactions: a direct SQL write waits for it.
wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

-- statements counts the plugin's hub.sql.query and hub.sql.exec calls during fn, up to its tab
-- declaration (hub.ui.tabs). The declaration reads before it calls hub.ui.tabs; the hub then
-- opens and renders the views of new tabs, and those renders are not part of the send.
local function statements(fn)
  local base = select(2, H.calls('none')).next
  fn()
  local tabs = H.calls('hub.ui.tabs', {after = base})
  expect(#tabs > 0, 'the send declares the tabs').to_be(true)
  local n = 0
  for _, action in ipairs({'hub.sql.query', 'hub.sql.exec'}) do
    local list, out = H.calls(action, {after = base})
    expect(out.dropped, 'no call record dropped').to_be(false)
    for _, c in ipairs(list) do if c.seq < tabs[1].seq then n = n + 1 end end
  end
  return n
end

-- groups adds groups g-reads-<from>..g-reads-<to>, each with alice and the user.
local function groups(from, to)
  for _, q in ipairs({
    [[INSERT INTO groups (gid, name) WITH RECURSIVE n(i) AS (SELECT ? UNION ALL SELECT i + 1 FROM n WHERE i < ?)
      SELECT 'g-reads-' || i, 'Reads ' || i FROM n]],
    [[INSERT INTO group_members (gid, agent, pos, current) WITH RECURSIVE n(i) AS (SELECT ? UNION ALL SELECT i + 1 FROM n WHERE i < ?)
      SELECT 'g-reads-' || i, a.agent, a.pos, 1 FROM n, (SELECT 'alice' AS agent, 1 AS pos UNION ALL SELECT 'user', 2) a]],
  }) do sql_write(q, {from, to}) end
end

test('a send declares the tabs with a number of statements that does not grow with the peers', function()
  groups(1, 5)
  local few = statements(function() alice:call('messaging.send', {to = 'user', body = 'one', key = 'reads-1'}) end)
  expect(few > 0, 'the count sees the statements').to_be(true)
  groups(6, 60)
  local many = statements(function() alice:call('messaging.send', {to = 'user', body = 'two', key = 'reads-2'}) end)
  -- The first send also creates its thread rows, so the counts can differ by a statement or two.
  expect(many <= few + 2, 'statements: ' .. many .. ' with 60 groups, ' .. few .. ' with 5').to_be(true)
end)
