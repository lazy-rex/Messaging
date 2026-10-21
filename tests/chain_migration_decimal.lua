-- F1 alias migration (docs/f-thread-tail.md, "Alias migration"): a chain number is a decimal
-- string of any length. The new chain number is 1 + the largest contributor chain number, in
-- exact decimal arithmetic: a Lua number loses precision above 2^53 (reviewer, 2026-10-21).

local function part(s) return #s .. ':' .. s end
local function tail_key(a, b)
  if b < a then local t = a; a = b; b = t end -- not a, b = b, a: wrong in Rex Lua (rex-protocol.md)
  return 'thread/' .. part(a) .. part(b)
end
local function seg_key(tail, chain, k) return 'thread-seg/' .. tail:sub(8) .. '/' .. chain .. '/' .. k end

local a_id, b_id = 'claude:conversation-a', 'codex:conversation-b'
local alice, bob, charlie = agent('alice'), agent('bob'), agent('charlie')
local function migrated(name)
  return wait('the migration of ' .. name, function()
    if store('identity-migrated/' .. part(name)).rev ~= '0' then return true end
  end)
end

-- segmented writes the thread of a and b as one segment and a tail, in the chain chain.
local function segmented(a, b, ids, chain)
  local key = tail_key(a, b)
  write({
    {key = seg_key(key, chain, 0), value = {ids = {ids[1]}}},
    {key = key, value = {ids = {ids[2], ids[3]}, seg = 1, chain = chain, frozen = 1}},
  })
  return key
end

for _, case in ipairs({
  {agent = alice, name = 'alice', peer = 'charlie', target = tail_key(a_id, 'charlie'), report = {kind = 'claude', conversation_id = 'conversation-a'},
    chain = '9007199254740992', want = '9007199254740993'},
  {agent = bob, name = 'bob', peer = 'charlie', target = tail_key(b_id, 'charlie'), report = {kind = 'codex', conversation_id = 'conversation-b'},
    chain = '99999999999999999999', want = '100000000000000000000'},
}) do
  test('chain ' .. case.chain .. ' migrates to chain ' .. case.want, function()
    local ids = {}
    for i = 1, 3 do
      ids[i] = case.agent:call('messaging.send', {to = case.peer, body = 'd' .. i, key = 'decimal-' .. case.name .. '-' .. i}).id
    end
    local legacy = segmented(case.name, case.peer, ids, case.chain)
    case.agent:report(case.report)
    migrated(case.name)
    local tail = store(case.target).value
    expect(tail.chain).to_be(case.want)
    local got = {}
    for k = 0, (tail.seg or 0) - 1 do
      for _, id in ipairs(store(seg_key(case.target, tail.chain, k)).value.ids) do got[#got + 1] = id end
    end
    for _, id in ipairs(tail.ids) do got[#got + 1] = id end
    expect(got).to_equal(ids)
    expect(store(legacy).rev).to_be('0')
    expect(store(seg_key(legacy, case.chain, 0)).rev).to_be('0')
  end)
end
