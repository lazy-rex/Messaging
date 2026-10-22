-- Rex Lua fails table.concat of more than 2559 items with "registry overflow" (LazyRex
-- docs/rex-protocol.md, observed on Rex 0.0.1792158932-g88fd41). A join of a list that a caller
-- controls must not use one table.concat. (Review, 2026-10-22: the Gallery form join.)

-- Every call fails with unavailable until the import at start is done (import.lua). Under load,
-- the start can end before it; the tests begin after it.
wait('the import at start', function() return (sql("SELECT value FROM meta WHERE key = 'import'")[1] or {}).value == 'done' end)

test('the Gallery form takes 2600 fields without a registry overflow', function()
  local v = user:open('gallery')
  v:render()
  local values = {}
  for i = 1, 2600 do values['k' .. i] = false end
  local op = v:action('sample_form', 'submit', {values = values})
  expect(op.status, 'form input within the request limit: ' .. rex.json.encode(op.error or {})).to_be('succeeded')
end)
