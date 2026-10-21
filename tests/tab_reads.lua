-- The tab declaration (declare_tabs) runs after every mutating action, every view.seen and every
-- hub.changed agents. It read about four records with one hub.store.get each for every peer
-- (home, thread tail, opened, title), and peers() read every observed thread again after its own
-- scan. Live, with about a hundred identities, that was tens of thousands of gets per minute
-- (coordinator, 2026-10-21). The reads must not grow with the number of peers.

local alice = agent('alice')

-- reads counts the plugin's hub.store.get and hub.store.scan calls during fn.
local function reads(fn)
  local base = select(2, H.calls('none')).next
  fn()
  local gets, got = H.calls('hub.store.get', {after = base})
  local scans, scanned = H.calls('hub.store.scan', {after = base})
  expect(got.dropped or scanned.dropped, 'no call record dropped').to_be(false)
  return #gets, #scans
end

local function groups(n)
  local list = {}
  for i = 1, n do list['g-reads-' .. i] = {name = 'Reads ' .. i, members = {'alice', 'user'}} end
  write({{key = 'groups', value = {groups = list}}})
end

test('a send declares the tabs with a number of reads that does not grow with the peers', function()
  groups(5)
  local few_gets, few_scans = reads(function() alice:call('messaging.send', {to = 'user', body = 'one', key = 'reads-1'}) end)
  groups(60)
  local many_gets, many_scans = reads(function() alice:call('messaging.send', {to = 'user', body = 'two', key = 'reads-2'}) end)
  -- The first send also creates its thread records, so the counts can differ by a read or two.
  expect(many_gets <= few_gets + 2, 'gets: ' .. many_gets .. ' with 60 groups, ' .. few_gets .. ' with 5').to_be(true)
  expect(many_scans, 'scans with 60 groups (' .. few_scans .. ' with 5)').to_be(few_scans)
end)
