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
