-- One hub.sql reply holds a part of a large result (more = true; about 1 MB of rows, LazyRex
-- docs/sql.md). Every reader must read the whole result, or stop at a page boundary that it
-- reports; none may drop the rest silently. (Review of 92d5f7c: rows() dropped the continuation
-- flag.) The history test is coverage: it also passed before the fix.

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
  write_sql([[INSERT INTO group_members (gid, agent, pos, current) SELECT gid, ?, 1, 1 FROM groups WHERE gid LIKE 'g-others-%']], {bob.id})
  write_sql("INSERT INTO groups (gid, name) VALUES ('g-zz-alice', 'Alice group')")
  write_sql([[INSERT INTO group_members (gid, agent, pos, current) VALUES ('g-zz-alice', ?, 1, 1), ('g-zz-alice', ?, 2, 1)]], {alice.id, bob.id})
  local found = false
  for _, t in ipairs(alice:call('messaging.thread_list', {}).threads) do found = found or t.id == 'g-zz-alice' end
  expect(found, 'the last group is listed').to_be(true)
end)

test('history continues after a partial result of large messages', function()
  local base = tonumber(sql('SELECT CAST(n AS TEXT) AS n FROM clock')[1].n)
  -- 24 bodies of 16000 bytes (inside the send limit): 384 KB of rows, over one hub.sql reply.
  for i = 1, 24 do
    write_sql([[INSERT INTO messages (seq, id, sender, recipient, thread_a, thread_b, body, at)
      VALUES (?, ?, ?, ?, ?, ?, ?, '2026-10-22T00:00:00Z')]],
      {base + i, 'paging/large/' .. i, bob.id, alice.id, alice.id, bob.id, string.rep('b', 16000)})
  end
  write_sql('UPDATE clock SET n = ?', {base + 24})
  local page = bob:call('messaging.history', {thread = alice.id, limit = 50})
  expect(#page.messages > 0 and #page.messages < 24, 'the page stops before all rows').to_be(true)
  expect(page.next_before ~= nil, 'the page reports older messages').to_be(true)
  -- Every message arrives in full, across pages.
  local seen = 0
  while true do
    for _, m in ipairs(page.messages) do
      if m.id:match('^paging/large/') then
        expect(#m.body, m.id .. ' in full').to_be(16000)
        seen = seen + 1
      end
    end
    if not page.next_before then break end
    page = bob:call('messaging.history', {thread = alice.id, limit = 50, before = page.next_before})
  end
  expect(seen).to_be(24)
end)
