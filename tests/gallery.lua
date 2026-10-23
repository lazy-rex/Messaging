-- The Gallery is two SDK views: "/gallery" (list, form, widgets) and "/gallery/thread" (history
-- and composer, thread view v1.2). lazyrex.json test.files gives this file the plugin arg
-- gallery = true; the other files run as a default install (threads.lua checks that).

local function gallery(key) return rex.json.decode(sql('SELECT value FROM gallery WHERE key = ?', {key})[1].value) end

test('the Gallery tabs are declared with the gallery arg', function()
  -- The plugin declares its tabs at start, after its registration.
  local t = wait('the Gallery tab', function() return tab('gallery') end)
  expect(t.route).to_be('/gallery')
  expect(tab('gallery/thread').route).to_be('/gallery/thread')
end)

test('the Gallery renders its list and form, with no history or composer, and keeps its actions', function()
  local v = user:open('gallery')
  local tree = v:render()
  expect(tree.title).to_be('Gallery')
  expect(H.node(tree, 'history'), 'no history beside a list or form').to_be(nil)
  expect(H.node(tree, 'composer')).to_be(nil)
  expect(v:action('sample_list', 'open', {item_id = 'a'}).status).to_be('succeeded')
  expect(gallery('state').last).to_be('opened list item a')
end)

test('the Gallery thread renders history and composer only, and keeps its draft and send', function()
  local v = user:open('gallery/thread')
  local tree = v:render()
  expect(tree.title).to_be('Gallery thread')
  expect(H.node(tree, 'sample_list')).to_be(nil)
  expect(H.node(tree, 'sample_form')).to_be(nil)
  local history = H.node(tree, 'history')
  expect(history.total).to_be(#history.messages)
  local composer = H.node(tree, 'composer')
  expect(v:draft('composer', 'Gallery check', composer.draft_revision, 'gallery-draft').status).to_be('succeeded')
  composer = H.node(v:render(), 'composer')
  expect(v:send('composer', 'Gallery check', composer.draft_revision, 'gallery-send').status).to_be('succeeded')
  expect(gallery('history').messages[1].text).to_be('Gallery check')
  history = H.node(v:render(), 'history')
  expect(history.messages[#history.messages].text).to_be('Gallery check')
end)
