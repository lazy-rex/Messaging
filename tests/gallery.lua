-- The Gallery is one SDK view. lazyrex.json test.files gives this file the plugin arg
-- gallery = true; the other files run as a default install (threads.lua checks that).

test('the Gallery tab is declared with the gallery arg', function()
  expect(tab('gallery').route).to_be('/gallery')
end)

test('the Gallery renders, and keeps its actions, draft and send', function()
  local v = user:open('gallery')
  expect(v:render().title).to_be('Gallery')
  expect(v:action('sample_list', 'open', {item_id = 'a'}).status).to_be('succeeded')
  expect(store('gallery/state').value.last).to_be('opened list item a')
  local composer = H.node(v:render(), 'composer')
  expect(v:draft('composer', 'Gallery check', composer.draft_revision, 'gallery-draft').status).to_be('succeeded')
  composer = H.node(v:render(), 'composer')
  expect(v:send('composer', 'Gallery check', composer.draft_revision, 'gallery-send').status).to_be('succeeded')
  expect(store('gallery/history').value.messages[1].text).to_be('Gallery check')
  expect(#H.calls('hub.sql.begin'), 'the Gallery uses no SQL transaction').to_be(0)
end)
