-- One hub.sql reply holds a part of a large result (more = true; about 1 MB of rows, LazyRex
-- docs/sql.md). Every reader must read the whole result, or stop at a page boundary that it
-- reports; none may drop the rest silently. (Review of 92d5f7c: rows() dropped the continuation
-- flag.) The history test is coverage: it also passed before the fix.

-- Every call fails with unavailable until the import at start is done (import.lua). Under load,
-- the start can end before it; the tests begin after it.
wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

local alice, bob = agent('alice'), agent('bob')

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

test('the group list reads every group when the groups are larger than one reply', function()
  -- 60 groups of others with 20000-byte names (1.2 MB; the hub stops a query reply at about 1 MB)
  -- come first; alice's group comes last.
  write_sql([[INSERT INTO groups (gid, name) WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 60)
    SELECT 'g-others-' || i, ? FROM n]], {string.rep('o', 20000)})
  write_sql([[INSERT INTO group_members (gid, agent, pos, current) SELECT gid, 'bob', 1, 1 FROM groups WHERE gid LIKE 'g-others-%']])
  write_sql("INSERT INTO groups (gid, name) VALUES ('g-zz-alice', 'Alice group')")
  write_sql([[INSERT INTO group_members (gid, agent, pos, current) VALUES ('g-zz-alice', 'alice', 1, 1), ('g-zz-alice', 'bob', 2, 1)]])
  local found = false
  for _, t in ipairs(alice:call('messaging.thread_list', {}).threads) do found = found or t.id == 'g-zz-alice' end
  expect(found, 'the last group is listed').to_be(true)
end)

test('alias migration moves every draft before it marks the alias applied', function()
  for i = 1, 60 do
    write_sql('INSERT INTO drafts (viewer, peer, text, rev) VALUES (?, ?, ?, ?)', {'alice', 'paging-peer-' .. i, string.rep('d', 20000), 2000 + i})
  end
  alice:report({kind = 'claude', conversation_id = 'paging-alias'})
  alice:call('messaging.read', {})
  expect(sql("SELECT count(*) AS n FROM drafts WHERE viewer = 'alice'")[1].n, 'no source row stays').to_be(0)
  expect(sql("SELECT count(*) AS n FROM drafts WHERE viewer = 'claude:paging-alias'")[1].n, 'every draft moved').to_be(60)
  local sizes = sql("SELECT DISTINCT length(text) AS n FROM drafts WHERE viewer = 'claude:paging-alias'")
  expect(sizes, 'the texts are complete').to_equal({{n = 20000}})
end)

test('history continues after a partial result of large messages', function()
  local base = tonumber(sql('SELECT CAST(n AS TEXT) AS n FROM clock')[1].n)
  for i = 1, 24 do
    write_sql([[INSERT INTO messages (seq, id, sender, recipient, thread_a, thread_b, body, reply_to, at)
      VALUES (?, ?, 'bob', 'claude:paging-alias', 'bob', 'claude:paging-alias', 'x', ?, '2026-10-22T00:00:00Z')]],
      {base + i, 'paging/meta/' .. i, string.rep('r', 50000)})
  end
  write_sql('UPDATE clock SET n = ?', {base + 24})
  local page = bob:call('messaging.history', {thread = 'claude:paging-alias', limit = 50})
  expect(#page.messages > 0 and #page.messages < 24, 'the page stops before all rows').to_be(true)
  expect(page.next_before ~= nil, 'the page reports older messages').to_be(true)
end)
