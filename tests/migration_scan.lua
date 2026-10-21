-- M1: the alias migration reads only the records that it can change (migration_records). A prefix
-- scan per key family keeps a record whose key changes, or an archive whose value names an
-- aliased peer; direct reads get the targets and the canonical mailbox of each alias. These tests
-- cover the records that a key-only selection would miss.

local function part(s) return #s .. ':' .. s end
local function hex(s) return (s:gsub('.', function(c) return string.format('%02x', string.byte(c)) end)) end
-- observed is the ID of the agent-to-agent direct thread of a and b, as the plugin makes it.
local function observed(a, b)
  if b < a then local t = a; a = b; b = t end -- not a, b = b, a: wrong in Rex Lua (rex-protocol.md)
  return 'd-' .. hex(part(a) .. part(b))
end

local a_id, b_id = 'claude:conversation-a', 'codex:conversation-b'
local alice, bob = agent('alice'), agent('bob')
local function migrated(name)
  return wait('the migration of ' .. name, function()
    if store('identity-migrated/' .. part(name)).rev ~= '0' then return true end
  end)
end

test('an archive whose key stays but whose value names an aliased observed thread', function()
  local archive = 'thread-archive/' .. part('user')
  write({{key = archive, value = {ids = {[observed('alice', 'bob')] = true, charlie = true}}}})
  alice:report({kind = 'claude', conversation_id = 'conversation-a'})
  migrated('alice')
  expect(store(archive).value).to_equal({ids = {[observed(a_id, 'bob')] = true, charlie = true}})
end)

test('a pending alias without a legacy mailbox: the canonical mailbox sets the notice', function()
  expect(store('mailbox/' .. part('bob')).rev, 'no legacy mailbox').to_be('0')
  local m = alice:call('messaging.send', {to = 'bob', body = 'before the report', key = 'scan-1'})
  -- The message is in bob's legacy mailbox. Move it to the canonical one, as an earlier write did.
  write({
    {key = 'mailbox/' .. part('bob'), delete = true},
    {key = 'mailbox/' .. part(b_id), value = {ids = {[m.id] = true}}},
  })
  bob:report({kind = 'codex', conversation_id = 'conversation-b'})
  migrated('bob')
  expect(notice(b_id).pending, 'the notice derives from the canonical mailbox').to_be(true)
  expect(store('mailbox/' .. part(b_id)).value).to_equal({ids = {[m.id] = true}})
end)

-- The request evidence (M1, reviewer): many large unrelated messages, then a migration. Every scan
-- has a prefix that is not message/ (a scan without a prefix reads every record), and every read
-- of message/ keys names only messages of the migrated agent's threads, at most 8 per request.
-- Needs hub.test.calls (hub branch hub/test-calls); without it, a test named SKIP.
local c_id = 'claude:conversation-c'
local charlie = agent('charlie')
if not H.calls or not pcall(H.calls, 'none') then
  test('SKIP: no hub.test.calls; the migration request evidence is not measured', function() end)
  return
end

test('a migration reads no unrelated message: request evidence', function()
  local body = string.rep('u', 15000)
  for i = 1, 40 do alice:call('messaging.send', {to = 'bob', body = body .. i, key = 'unrelated-' .. i}) end
  local own = {}
  for i = 1, 3 do
    own['message/' .. charlie:call('messaging.send', {to = 'user', body = 'c' .. i, key = 'own-' .. i}).id] = true
  end
  local _, base = H.calls('none')
  charlie:report({kind = 'claude', conversation_id = 'conversation-c'})
  migrated('charlie')
  local scans, scanned = H.calls('hub.store.scan', {after = base.next})
  local gets, got = H.calls('hub.store.get', {after = base.next})
  expect(scanned.dropped or got.dropped, 'no call record dropped').to_be(false)
  expect(#scans > 0, 'the migration scans').to_be(true)
  for _, c in ipairs(scans) do
    local prefix = c.args.prefix
    expect(type(prefix) == 'string' and prefix ~= '' and prefix:sub(1, 8) ~= 'message/', 'scan prefix ' .. tostring(prefix)).to_be(true)
  end
  local read = 0
  for _, c in ipairs(gets) do
    local messages = 0
    for _, k in ipairs(c.args.keys or {}) do
      if k:sub(1, 8) == 'message/' then
        expect(own[k], 'an unrelated message read: ' .. k).to_be(true)
        messages = messages + 1
      end
    end
    expect(messages <= 8, 'message keys in one request').to_be(true)
    read = read + messages
  end
  expect(read > 0, 'the migration reads the revisions of its own messages').to_be(true)
  expect(store('thread/' .. part(c_id) .. part('user')).value.ids ~= nil).to_be(true)
end)
