-- import.lua: the one-time import of Messaging's key-value records into SQL (docs/sql-storage.md
-- revision 4, "Migration"). messaging.lua calls run() in app.start, before it serves calls: the
-- plugin answers calls only after the import is done. Each step is one SQL transaction, with its
-- progress in meta, so a crash continues where it stopped.
--
-- Names: the import maps every name through M, the hub's alias set recorded with the fence (env.c
-- and env.c_thread use the aliases that use_aliases set). Two source records that meet under M
-- merge with the winner rules of the SQL alias merge, as upserts.

return function(env)
  local db, hub, fail, part, parts, json = env.db, env.hub, env.fail, env.part, env.parts, env.json
  local encoded_size, utf8_cut, later = env.encoded_size, env.utf8_cut, env.later

  local FENCE = 'sql-import'
  local STEP = 50 -- source records in one step (one transaction)
  local CHUNK = 30000 -- encoded bytes of one body part in import_body
  local LARGE = 40000 -- a message whose encoded body is larger is imported in chunks
  -- The families in import order: groups first (the audience fallback), messages before mailboxes.
  -- The thread chains give no rows: they are sources of the verification, so the source check
  -- covers them.
  local FAMILIES = {'groups', 'delivery/', 'message/', 'mailbox/', 'thread-meta/', 'thread-title/',
    'thread-open/', 'thread-archive/', 'draft/', 'gallery/', 'identity-migrated/', 'thread/', 'thread-seg/'}
  -- Saved operation families whose key has an agent part (the owner); others have owner ''.
  local OWNED = {['send/'] = true, ['thread-create/'] = true, ['thread-move/'] = true, ['rename/'] = true,
    ['thread-archive/'] = true, ['draft/'] = true, ['members/'] = true, ['create-restore/'] = true}

  local function conflict(message, key)
    fail('migration_conflict', message .. (key and (': ' .. key) or ''))
  end

  -- batches cuts a list of strings into lists of at most BATCH encoded bytes: each list goes into
  -- one request as JSON, and a request holds at most 64 KiB with its SQL text. An item larger than
  -- BATCH alone stops the import.
  local BATCH = 48000
  local function batches(list)
    local out, block, size = {}, {}, 2
    for _, item in ipairs(list) do
      local cost = encoded_size(item) + 1
      if cost + 2 > BATCH then conflict('A key or ID is too large for one request', utf8_cut(item, 200)) end
      if size + cost > BATCH then out[#out + 1] = block; block, size = {}, 2 end
      block[#block + 1] = item
      size = size + cost
    end
    if #block > 0 then out[#out + 1] = block end
    return out
  end
  -- fits stops the import when the values of one row are larger than one request.
  local function fits(key, ...)
    local size = 0
    for i = 1, select('#', ...) do size = size + encoded_size(select(i, ...) or '') end
    if size > LARGE then conflict('A record is too large for one request', key) end
  end

  -- meta -----------------------------------------------------------------------------------------

  local function meta(key)
    local r = db.first('SELECT value FROM meta WHERE key = ?', key)
    return r and r.value
  end
  local function set_meta(key, value)
    db.exec('INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value', key, value)
  end
  local function progress() return rex.json.decode(meta('import_progress') or '{}') end
  local function set_progress(p) set_meta('import_progress', json(p)) end

  -- Key-value reads ------------------------------------------------------------------------------

  local function kv_get(keys)
    local records = hub('hub.store.get', {keys = keys}).records
    if type(records) ~= 'table' then fail('internal', 'Missing store records') end
    return records
  end
  local function fence() return kv_get({FENCE})[FENCE] end
  -- write_fence rewrites the fence with if_rev = rev and returns its new revision.
  local function write_fence(state, rev)
    local r = hub('hub.store.batch', {ops = {{key = FENCE, value = {state = state}, if_rev = rev}}})
    if type(r.revs) ~= 'table' or type(r.revs[FENCE]) ~= 'string' then conflict('The import fence changed', FENCE) end
    return r.revs[FENCE]
  end
  -- scan returns the records of prefix after key `after`, at most limit, sorted by key, and
  -- whether more exist. 'groups' and 'gallery/' are prefixes as well.
  local function scan(prefix, after, limit)
    local page = hub('hub.store.scan', {prefix = prefix, after = after or '', limit = limit})
    local list = {}
    for key, r in pairs(page.records or {}) do list[#list + 1] = {key = key, rev = r.rev, value = r.value} end
    table.sort(list, function(x, y) return x.key < y.key end)
    return list, page.next ~= nil
  end
  local function in_family(prefix, key) return prefix ~= 'groups' or key == 'groups' end

  -- Names through M ------------------------------------------------------------------------------

  local c, c_thread = env.c, env.c_thread
  local state = {} -- M, the roster and f0 of this import, from meta

  local function load_state()
    state.aliases = rex.json.decode(meta('import_aliases') or '{}')
    state.roster = rex.json.decode(meta('import_roster') or '[]')
    state.f0 = meta('import_f0')
    env.use_aliases(state.aliases)
  end

  local function str(v, key, what)
    if type(v) ~= 'string' then conflict('Invalid ' .. what, key) end
    return v
  end
  -- pair2 parses a key suffix of two parts.
  local function pair2(suffix, key)
    local p = parts(suffix)
    if not p or #p ~= 2 then conflict('Invalid key', key) end
    return p[1], p[2]
  end
  local function sorted(a, b)
    if b < a then return b, a end -- not a, b = b, a (rex-protocol.md)
    return a, b
  end

  -- Row writes with the winner rules -------------------------------------------------------------

  local function member(gid, agent, pos, current)
    db.exec([[INSERT INTO group_members (gid, agent, pos, current) VALUES (?, ?, ?, ?)
      ON CONFLICT (gid, agent) DO UPDATE SET pos = min(pos, excluded.pos), current = max(current, excluded.current)]],
      gid, agent, pos, current)
  end
  local function title(viewer, peer, text, rev)
    db.exec([[INSERT INTO thread_titles (viewer, peer, title, set_rev) VALUES (?, ?, ?, CAST(? AS INTEGER))
      ON CONFLICT (viewer, peer) DO UPDATE SET title = excluded.title, set_rev = excluded.set_rev
      WHERE excluded.set_rev > thread_titles.set_rev]], viewer, peer, text, rev)
  end
  local function draft(viewer, peer, text, rev, key)
    local old = db.first('SELECT text, CAST(rev AS TEXT) AS rev FROM drafts WHERE viewer = ? AND peer = ?', viewer, peer)
    if old then
      if old.text ~= '' and text ~= '' and old.text ~= text then conflict('Two drafts have different text', key) end
      local wins = (text ~= '' and old.text == '') or (text == old.text and later(rev, old.rev))
      if not wins then return end
    end
    db.exec([[INSERT INTO drafts (viewer, peer, text, rev) VALUES (?, ?, ?, CAST(? AS INTEGER))
      ON CONFLICT (viewer, peer) DO UPDATE SET text = excluded.text, rev = excluded.rev]], viewer, peer, text, rev)
  end
  local function home(a, b, session, moved, rev)
    local old = db.first('SELECT moved, CAST(set_rev AS TEXT) AS set_rev FROM thread_homes WHERE thread_a = ? AND thread_b = ?', a, b)
    if old then
      -- The newest move wins; without a move, the first home wins.
      local wins
      if moved == 1 then wins = old.moved == 0 or later(rev, old.set_rev)
      else wins = old.moved == 0 and later(old.set_rev, rev) end
      if not wins then return end
    end
    db.exec([[INSERT INTO thread_homes (thread_a, thread_b, home_session, moved, set_rev) VALUES (?, ?, ?, ?, CAST(? AS INTEGER))
      ON CONFLICT (thread_a, thread_b) DO UPDATE SET home_session = excluded.home_session, moved = excluded.moved,
        set_rev = excluded.set_rev]], a, b, session, moved, rev)
  end

  -- The audience -----------------------------------------------------------------------------------

  -- audience returns c of the audience of message m, without duplicates and in order: its
  -- recipients, else its delivery snapshot, else the fallback (the group's current members or the
  -- roster at the fence, without the sender; a direct message goes to its recipient).
  local function audience(m, delivery, groups)
    local list = m.recipients
    if list == nil and delivery and delivery.rev ~= '0' then
      if type(delivery.value) ~= 'table' or type(delivery.value.ids) ~= 'table' then conflict('Invalid delivery record', 'delivery/' .. part(m.id)) end
      list = delivery.value.ids
    end
    if list == nil then
      list = {}
      local sender = c(m.from)
      if m.to == 'team' then
        for _, id in ipairs(state.roster) do if id ~= sender then list[#list + 1] = id end end
      elseif m.to:sub(1, 2) == 'g-' then
        local g = groups[m.to]
        if not g then conflict('A message names an unknown group', 'message/' .. m.id) end
        for _, id in ipairs(g.members or {}) do if c(id) ~= sender then list[#list + 1] = id end end
      else
        list = {m.to}
      end
    end
    local out, seen = {}, {}
    for _, id in ipairs(list) do
      id = c(str(id, 'message/' .. m.id, 'audience'))
      if not seen[id] then seen[id] = true; out[#out + 1] = id end
    end
    return out
  end

  local function groups_value()
    local r = kv_get({'groups'}).groups
    if r.rev == '0' then return {} end
    if type(r.value) ~= 'table' or type(r.value.groups) ~= 'table' then conflict('Invalid groups record', 'groups') end
    return r.value.groups
  end

  local function message_value(r)
    local m = r.value
    if type(m) ~= 'table' then conflict('Invalid message record', r.key) end
    str(m.id, r.key, 'message id'); str(m.from, r.key, 'sender'); str(m.to, r.key, 'recipient')
    str(m.body, r.key, 'body'); str(m.at, r.key, 'time')
    if r.key ~= 'message/' .. m.id then conflict('A message record has another ID', r.key) end
    return m
  end

  -- insert_message writes the message row (body = the text given) and its deliveries, acked.
  local function insert_message(r, m, body_sql, body, groups)
    local from, to = c(m.from), c(m.to)
    local ta, tb = env.thread_pair(from, to)
    db.exec([[INSERT INTO messages (seq, id, sender, recipient, thread_a, thread_b, body, reply_to, reply_expected, at)
      VALUES (CAST(? AS INTEGER), ?, ?, ?, ?, ?, ]] .. body_sql .. [[, ?, ?, ?)]],
      r.rev, m.id, from, to, ta, tb, body, m.reply_to, m.reply_expected == false and 0 or nil, m.at)
    local key = 'delivery/' .. part(m.id)
    local delivery = m.recipients == nil and kv_get({key})[key] or nil
    -- The audience has no duplicates; a row from an earlier record cannot exist (a new seq).
    for _, block in ipairs(batches(audience(m, delivery, groups))) do
      db.exec('INSERT INTO deliveries (agent, seq, acked) SELECT value, CAST(? AS INTEGER), 1 FROM json_each(?)', r.rev, json(block))
    end
  end

  -- Families: one function for each, called with one source record ------------------------------

  local import_record = {}

  import_record['groups'] = function(r)
    if type(r.value) ~= 'table' or type(r.value.groups) ~= 'table' then conflict('Invalid groups record', r.key) end
    for gid, g in pairs(r.value.groups) do
      if type(g) ~= 'table' or type(g.name) ~= 'string' or type(g.members) ~= 'table' then conflict('Invalid group', gid) end
      fits('groups ' .. utf8_cut(gid, 200), gid, g.name)
      db.exec('INSERT INTO groups (gid, name) VALUES (?, ?)', gid, g.name)
      local pos = 0
      for _, id in ipairs(g.members) do pos = pos + 1; member(gid, c(str(id, gid, 'member')), pos, 1) end
      for _, id in ipairs(g.past_members or {}) do pos = pos + 1; member(gid, c(str(id, gid, 'member')), pos, 0) end
    end
  end
  -- A delivery snapshot is read with its message; here it is only a source record.
  import_record['delivery/'] = function() end
  import_record['mailbox/'] = function(r)
    local agent = c(r.key:sub(#'mailbox/' + 1):match('^%d+:(.*)$') or conflict('Invalid key', r.key))
    if type(r.value) ~= 'table' or type(r.value.ids) ~= 'table' then conflict('Invalid mailbox record', r.key) end
    local ids = {}
    for id, unread in pairs(r.value.ids) do
      if type(id) ~= 'string' or unread ~= true then conflict('Invalid mailbox entry', r.key) end
      ids[#ids + 1] = id
    end
    if #ids == 0 then return end
    local changed = 0
    for _, block in ipairs(batches(ids)) do
      changed = changed + db.exec([[UPDATE deliveries SET acked = 0 WHERE agent = ?
        AND seq IN (SELECT m.seq FROM messages m JOIN json_each(?) j ON m.id = j.value)]], agent, json(block)).changes
    end
    if changed ~= #ids then conflict('A mailbox names a message without a delivery to its agent', r.key) end
  end
  import_record['thread-meta/'] = function(r)
    local a, b = pair2(r.key:sub(#'thread-meta/' + 1), r.key)
    local v = r.value
    if type(v) ~= 'table' or type(v.home_session) ~= 'string' then conflict('Invalid thread home', r.key) end
    if a:sub(1, 2) == 'd-' then a = c_thread(a)
    elseif a ~= '' then a, b = sorted(c(a), c(b)) end
    fits(r.key, a, b, v.home_session)
    home(a, b, v.home_session, v.moved == true and 1 or 0, type(v.set_rev) == 'string' and v.set_rev or r.rev)
  end
  import_record['thread-title/'] = function(r)
    local viewer, peer = pair2(r.key:sub(#'thread-title/' + 1), r.key)
    local v = r.value
    -- Today a title without a visible character shows the display name: no row.
    if type(v) ~= 'table' or type(v.title) ~= 'string' or not v.title:match('%S') then return end
    fits(r.key, viewer, peer, v.title)
    title(c(viewer), c_thread(peer), v.title, type(v.set_rev) == 'string' and v.set_rev or r.rev)
  end
  import_record['thread-open/'] = function(r)
    local viewer, peer = pair2(r.key:sub(#'thread-open/' + 1), r.key)
    if type(r.value) ~= 'table' or r.value.opened ~= true then return end
    db.exec('INSERT INTO thread_opened (viewer, peer) VALUES (?, ?) ON CONFLICT DO NOTHING', c(viewer), c_thread(peer))
  end
  import_record['thread-archive/'] = function(r)
    local viewer = c(r.key:sub(#'thread-archive/' + 1):match('^%d+:(.*)$') or conflict('Invalid key', r.key))
    if type(r.value) ~= 'table' or type(r.value.ids) ~= 'table' then conflict('Invalid archived threads', r.key) end
    for peer, archived in pairs(r.value.ids) do
      if archived == true then
        db.exec('INSERT INTO thread_archived (viewer, peer) VALUES (?, ?) ON CONFLICT DO NOTHING', viewer, c_thread(str(peer, r.key, 'peer')))
      end
    end
  end
  import_record['draft/'] = function(r)
    local viewer, peer = pair2(r.key:sub(#'draft/' + 1), r.key)
    local text = type(r.value) == 'table' and type(r.value.text) == 'string' and r.value.text or ''
    fits(r.key, viewer, peer, text)
    draft(c(viewer), c_thread(peer), text, r.rev, r.key)
  end
  import_record['gallery/'] = function(r)
    fits(r.key, r.key, json(r.value))
    db.exec('INSERT INTO gallery (key, value, rev) VALUES (?, ?, CAST(? AS INTEGER))', r.key:sub(#'gallery/' + 1), json(r.value), r.rev)
  end
  -- Provenance only: the source check covers it; aliases_applied comes from M.
  import_record['identity-migrated/'] = function() end
  -- Read by threads_task.
  import_record['thread/'] = function() end
  import_record['thread-seg/'] = function() end

  -- The message family has large records: a body over LARGE goes into import_body in parts.
  local function source(key, rev) db.exec("INSERT INTO import_source (key, rev, complete) VALUES (?, ?, 1)", key, rev) end

  -- message_step imports one message record, or one part of a large one. It returns true when the
  -- record is complete.
  local function message_step(r, p, groups)
    local m = message_value(r)
    local rest = {id = m.id, from = m.from, to = m.to, reply_to = m.reply_to, at = m.at, recipients = m.recipients}
    if encoded_size(rest) > LARGE then conflict('A message has fields too large for one request', r.key) end
    -- Inline: the body and the other fields go into one request together.
    if encoded_size(rest) + encoded_size(m.body) <= LARGE then
      insert_message(r, m, '?', m.body, groups)
      source(r.key, r.rev)
      return true
    end
    local offset = p.key == r.key and p.offset or 0
    -- body is a BLOB: length counts bytes, as offset does (on TEXT it counts characters).
    local stored = db.first('SELECT length(body) AS n FROM import_body WHERE key = ?', r.key)
    if (stored and stored.n or 0) ~= offset then conflict('A chunked body has another length', r.key) end
    if offset < #m.body then
      local piece = utf8_cut(m.body:sub(offset + 1), CHUNK)
      while encoded_size(piece) > CHUNK do piece = utf8_cut(piece, math.floor(#piece / 2)) end
      if piece == '' then conflict('A body cannot be cut', r.key) end
      -- || gives TEXT, also for two BLOBs: the CAST keeps the stored body a BLOB.
      db.exec([[INSERT INTO import_body (key, body) VALUES (?, CAST(? AS BLOB))
        ON CONFLICT (key) DO UPDATE SET body = CAST(body || excluded.body AS BLOB)]], r.key, piece)
      p.key, p.offset = r.key, offset + #piece
      return false
    end
    insert_message(r, m, '(SELECT CAST(body AS TEXT) FROM import_body WHERE key = ?)', r.key, groups)
    db.exec('DELETE FROM import_body WHERE key = ?', r.key)
    source(r.key, r.rev)
    p.key, p.offset = nil, nil
    return true
  end

  -- family_step imports the next records of family p.family. It returns false at its end.
  local function family_step(p)
    local prefix = FAMILIES[p.family]
    local list = scan(prefix, p.after, STEP)
    local groups = prefix == 'message/' and groups_value() or nil
    local any = false
    for _, r in ipairs(list) do
      if in_family(prefix, r.key) then
        any = true
        -- A record newer than f0 is imported too; the verification finds it and resets.
        if prefix == 'message/' then
          if not message_step(r, p, groups) then return true end -- one part per step
        else
          import_record[prefix](r)
          source(r.key, r.rev)
        end
        p.after = r.key
      end
    end
    if not any then p.family, p.after = p.family + 1, nil end
    return p.family <= #FAMILIES
  end

  -- owner returns the agent part of a saved operation key, or ''.
  local function owner(key)
    local prefix, rest = key:match('^([^/]+/)(.*)$')
    if not prefix or not OWNED[prefix] then return '' end
    local p = parts(rest)
    return p and p[1] or ''
  end

  local function ops_step(p)
    local page = hub('hub.store.ops_scan', {after = p.after or '', limit = STEP})
    for _, op in ipairs(page.ops or {}) do
      local result = json(op.result)
      if encoded_size(op.key) + encoded_size(op.fingerprint) + encoded_size(result) > LARGE then
        conflict('A saved operation is too large for one request', op.key)
      end
      db.exec('INSERT INTO operations (key, owner, fingerprint, result) VALUES (?, ?, ?, ?)', op.key, owner(op.key), op.fingerprint, result)
      db.exec('INSERT INTO import_ops (key) VALUES (?)', op.key)
      p.after = op.key
    end
    return page.next ~= nil
  end

  -- Checks and verification: tasks ------------------------------------------------------------------
  --
  -- A task does one bounded part of a check in each call of its step: one page of source records,
  -- of saved operations or of SQL rows. step returns nil while work remains, true at a successful
  -- end, and false, key when a source changed (the import begins again). A content mismatch stops
  -- the import (conflict). The checks only read, so a task that a crash stops starts again from its
  -- beginning at the next start.

  -- same_value compares two decoded JSON values.
  local function same_value(x, y)
    if type(x) ~= type(y) then return false end
    if type(x) ~= 'table' then return x == y end
    for k, v in pairs(x) do if not same_value(v, y[k]) then return false end end
    for k in pairs(y) do if x[k] == nil then return false end end
    return true
  end

  -- sources_task fails when a source record changed: a revision of an imported record differs, or
  -- a record was added or deleted after the fence. complete = true also requires the family key set
  -- to equal import_source (verification).
  local function sources_task(complete)
    local t = {family = 1, after = nil, seen = {}, deleted_after = nil}
    function t.step()
      if t.family <= #FAMILIES then
        local prefix = FAMILIES[t.family]
        local list, more = scan(prefix, t.after, 200)
        local keys = {}
        for _, r in ipairs(list) do
          t.after = r.key
          if in_family(prefix, r.key) then
            if later(r.rev, state.f0) then return false, r.key end
            keys[#keys + 1] = r.key
            t.seen[r.key] = r.rev
          end
        end
        local found = {}
        for _, block in ipairs(batches(keys)) do
          for _, row in ipairs(env.rows('SELECT key, rev FROM import_source WHERE key IN (SELECT value FROM json_each(?))', json(block))) do
            found[#found + 1] = row
          end
        end
        for _, row in ipairs(found) do
          if t.seen[row.key] ~= row.rev then return false, row.key end
        end
        if complete and #found ~= #keys then return false, 'a record that is not imported' end
        if not more then t.family, t.after = t.family + 1, nil end
        return nil
      end
      -- A deleted record: an import_source row whose key no longer exists. One page for each step.
      local page = env.rows('SELECT key FROM import_source WHERE key > ? ORDER BY key LIMIT 500', t.deleted_after or '')
      for _, row in ipairs(page) do
        if not t.seen[row.key] then return false, row.key end
        t.deleted_after = row.key
      end
      if #page == 500 then return nil end
      return true
    end
    return t
  end

  -- ops_task compares every saved operation with the operations rows: the key set equals
  -- import_ops (complete) or contains it (partial), and each fingerprint and result are equal.
  local function ops_task(complete)
    local t = {after = '', count = 0}
    function t.step()
      local page = hub('hub.store.ops_scan', {after = t.after, limit = 200})
      local keys, by_key = {}, {}
      for _, op in ipairs(page.ops or {}) do keys[#keys + 1] = op.key; by_key[op.key] = op; t.after = op.key end
      local found = {}
      for _, block in ipairs(batches(keys)) do
        for _, row in ipairs(env.rows([[SELECT o.key, o.fingerprint, o.result FROM operations o JOIN import_ops i ON i.key = o.key
          WHERE o.key IN (SELECT value FROM json_each(?))]], json(block))) do found[#found + 1] = row end
      end
      for _, row in ipairs(found) do
        local op = by_key[row.key]
        if op.fingerprint ~= row.fingerprint or not same_value(op.result, rex.json.decode(row.result)) then return false, row.key end
      end
      t.count = t.count + #found
      if complete and #found ~= #keys then return false, 'a saved operation that is not imported' end
      if page.next ~= nil then return nil end
      if db.first('SELECT count(*) AS n FROM import_ops').n ~= t.count then return false, 'a saved operation that was deleted' end
      return true
    end
    return t
  end

  -- seq_of_ids looks the IDs up in byte-bounded batches.
  local function seq_of_ids(ids)
    local out = {}
    for _, block in ipairs(batches(ids)) do
      for _, r in ipairs(env.rows([[SELECT m.id, CAST(m.seq AS TEXT) AS seq, m.thread_a, m.thread_b FROM messages m
        JOIN json_each(?) j ON m.id = j.value]], json(block))) do out[r.id] = r end
    end
    return out
  end

  -- threads_task: each key-value chain maps through M to one SQL thread, ascends in seq, and the
  -- union of the chains of a thread equals its SQL messages.
  local function threads_task()
    local t = {after = nil, done = false, union = {}} -- union: part(a) .. part(b) -> {n = distinct IDs, ids = set}
    function t.step()
      if not t.done then
        local list, more = scan('thread/', t.after, 100)
        for _, r in ipairs(list) do
          t.after = r.key
          local a, b = pair2(r.key:sub(#'thread/' + 1), r.key)
          if a ~= '' then a, b = sorted(c(a), c(b)) end
          local v = r.value
          if type(v) ~= 'table' or type(v.ids) ~= 'table' then conflict('Invalid thread record', r.key) end
          local ids = {}
          for k = 0, (v.seg or 0) - 1 do
            local key = 'thread-seg/' .. r.key:sub(#'thread/' + 1) .. '/' .. (v.chain or '0') .. '/' .. k
            local seg = kv_get({key})[key]
            if seg.rev == '0' or type(seg.value) ~= 'table' or type(seg.value.ids) ~= 'table' then conflict('A thread segment is missing', key) end
            for _, id in ipairs(seg.value.ids) do ids[#ids + 1] = id end
          end
          for _, id in ipairs(v.ids) do ids[#ids + 1] = id end
          local found, last = seq_of_ids(ids), nil
          for _, id in ipairs(ids) do
            local m = found[id]
            if not m then conflict('A thread names a message that is not imported', r.key .. ' ' .. id) end
            if m.thread_a ~= a or m.thread_b ~= b then conflict('A message is in another thread', r.key .. ' ' .. id) end
            if last and not later(m.seq, last) then conflict('A thread is not in message order', r.key) end
            last = m.seq
          end
          local k = part(a) .. part(b)
          local u = t.union[k] or {n = 0, ids = {}}
          t.union[k] = u
          for _, id in ipairs(ids) do
            if not u.ids[id] then u.ids[id] = true; u.n = u.n + 1 end
          end
        end
        t.done = not more
        return nil
      end
      -- Each chain ID is a message of its thread (above). So a thread whose distinct chain IDs are
      -- as many as its SQL messages has exactly those messages. Two chains that meet under M can
      -- share IDs: a sum of their lengths would hide a missing message.
      for _, row in ipairs(env.rows('SELECT thread_a, thread_b, count(*) AS n FROM messages GROUP BY thread_a, thread_b')) do
        local k = part(row.thread_a) .. part(row.thread_b)
        if (t.union[k] and t.union[k].n or 0) ~= row.n then conflict('A thread has another set of messages', k) end
        t.union[k] = nil
      end
      for k in pairs(t.union) do conflict('A thread has another set of messages', k) end
      return true
    end
    return t
  end

  -- audience_task: the delivery agents of each message equal c of its audience.
  local function audience_task()
    local t = {after = nil, groups = nil}
    function t.step()
      t.groups = t.groups or groups_value()
      local list, more = scan('message/', t.after, 100)
      for _, r in ipairs(list) do
        t.after = r.key
        local m = message_value(r)
        local key = 'delivery/' .. part(m.id)
        local want = audience(m, m.recipients == nil and kv_get({key})[key] or nil, t.groups)
        local got = env.rows('SELECT agent FROM deliveries WHERE seq = CAST(? AS INTEGER) ORDER BY agent', r.rev)
        table.sort(want)
        if #got ~= #want then conflict('A message has another audience', r.key) end
        for i, row in ipairs(got) do if row.agent ~= want[i] then conflict('A message has another audience', r.key) end end
      end
      if more then return nil end
      return true
    end
    return t
  end

  -- unread_task: the unread deliveries of each agent equal the union of its mailboxes.
  local function unread_task()
    local t = {after = nil, done = false, unread = {}, rows_after = nil} -- unread: agent -> {id = true}
    function t.step()
      if not t.done then
        local list, more = scan('mailbox/', t.after, 100)
        for _, r in ipairs(list) do
          t.after = r.key
          local agent = c(r.key:sub(#'mailbox/' + 1):match('^%d+:(.*)$'))
          t.unread[agent] = t.unread[agent] or {}
          for id in pairs(r.value.ids) do t.unread[agent][id] = true end
        end
        t.done = not more
        return nil
      end
      -- One page of unread deliveries for each step, in (agent, seq) order.
      local a, s = '', -1
      if t.rows_after then a, s = t.rows_after.agent, t.rows_after.seq end
      local page = env.rows([[SELECT d.agent, d.seq, m.id FROM deliveries d JOIN messages m ON m.seq = d.seq
        WHERE d.acked = 0 AND (d.agent > ? OR (d.agent = ? AND d.seq > ?)) ORDER BY d.agent, d.seq LIMIT 500]], a, a, s)
      for _, row in ipairs(page) do
        local set = t.unread[row.agent]
        if not set or not set[row.id] then conflict('A delivery is unread without a mailbox entry', row.agent .. ' ' .. row.id) end
        set[row.id] = nil
        t.rows_after = row
      end
      if #page == 500 then return nil end
      for agent, set in pairs(t.unread) do
        for id in pairs(set) do conflict('A mailbox entry is not an unread delivery', agent .. ' ' .. id) end
      end
      return true
    end
    return t
  end

  -- States -----------------------------------------------------------------------------------------

  local TABLES = {'deliveries', 'messages', 'group_members', 'groups', 'thread_homes', 'thread_titles', 'thread_opened',
    'thread_archived', 'drafts', 'operations', 'aliases_applied', 'gallery', 'import_source', 'import_ops', 'import_body'}

  -- begin records a new import: the hub's alias set M and roster now, f0, and an empty progress. A
  -- reset deletes every imported row first.
  local function begin(f0)
    env.refresh_participants()
    local aliases, roster = {}, {}
    for _, a in ipairs(env.participants()) do
      if a.alias_of then aliases[a.id] = a.alias_of elseif a.state ~= 'superseded' then roster[#roster + 1] = a.id end
    end
    table.sort(roster)
    db.transaction(function()
      for _, t in ipairs(TABLES) do db.exec('DELETE FROM ' .. t) end
      set_meta('import', 'importing')
      set_meta('import_f0', f0)
      set_meta('import_aliases', json(aliases))
      set_meta('import_roster', json(roster))
      set_progress({phase = 'families', family = 1})
    end)
    load_state()
  end

  -- import_step runs one step of the import, in one transaction. It returns false at the end.
  local function import_step()
    local p = progress()
    return db.transaction(function()
      local m
      if p.phase == 'families' then m = family_step(p)
      else m = ops_step(p) end
      if p.phase == 'families' and not m then p.phase, p.after, m = 'ops', nil, true end
      set_progress(p)
      return m or p.phase == 'families'
    end)
  end

  local function mark_verified()
    db.transaction(function()
      for alias, identity in pairs(state.aliases) do
        db.exec('INSERT INTO aliases_applied (alias, identity) VALUES (?, ?)', alias, identity)
      end
      set_meta('import', 'verified')
    end)
  end

  -- cutover: the fence is at f1 (written now, or found after a crash). One SQL transaction: the
  -- late alias merges, the clock, done and the notices of the whole roster.
  local function cutover()
    local f = fence()
    local f1 = f.value.state == 'cutover' and f.rev or write_fence('cutover', f.rev)
    db.transaction(function()
      env.refresh_participants()
      env.migrate_aliases()
      db.exec('UPDATE clock SET n = CAST(? AS INTEGER)', f1)
      set_meta('import', 'done')
      set_meta('import_f1', f1)
      for _, a in ipairs(env.participants()) do
        if a.state ~= 'superseded' or a.alias_of then
          local pending = false
          if not a.alias_of then
            pending = db.first('SELECT 1 AS x FROM deliveries WHERE agent = ? AND acked = 0 LIMIT 1', a.id) ~= nil
          end
          env.notice(a.id, pending)
        end
      end
    end)
  end

  -- The run: a state machine that step advances by one bounded unit of work (one transaction, or
  -- one page of a check). Its in-memory part is a table field (the pcall rule, LazyRex
  -- docs/rex-protocol.md); a crash loses it, and the next start decides again from meta and the
  -- fence. phase: decide, import, check (tasks, then ok or reset), cutover, done.
  local run = {phase = 'decide', attempts = 0, tasks = nil, ok = nil}

  -- check runs tasks, one step at a time; ok is the next phase when all pass. A changed source
  -- begins the import again: three changes in a row stop the start.
  local function check(tasks, ok)
    run.phase, run.tasks, run.ok = 'check', tasks, ok
  end
  local function restart_import()
    run.attempts = run.attempts + 1
    if run.attempts > 3 then conflict('The key-value store changed during the import, three times') end
    begin(write_fence('importing', fence().rev))
    run.phase = 'import'
  end
  local function verification()
    return {sources_task(true), ops_task(true), threads_task(), audience_task(), unread_task()}
  end

  local phases = {}
  function phases.decide()
    local s = meta('import')
    if s == 'done' then run.phase = 'done'; return end
    local f = fence()
    local fstate = type(f.value) == 'table' and f.value.state or nil
    if s == nil and f.rev == '0' then
      begin(write_fence('importing', '0'))
      run.phase = 'import'
    elseif s == nil and fstate == 'importing' then
      begin(write_fence('importing', f.rev)) -- the orphan fence
      run.phase = 'import'
    elseif s == 'importing' and fstate == 'importing' then
      load_state()
      check({sources_task(false), ops_task(false)}, 'import')
    elseif s == 'verified' and (fstate == 'importing' or fstate == 'cutover') then
      -- The source check again, with the saved operations: an old release can have run.
      load_state()
      check({sources_task(true), ops_task(true)}, 'cutover')
    else
      conflict('The SQL import state ' .. tostring(s) .. ' does not match the fence ' .. tostring(fstate))
    end
  end
  function phases.import()
    if not import_step() then check(verification(), 'verified') end
  end
  function phases.check()
    local ok, key = run.tasks[1].step()
    if ok == nil then return end
    if ok == false then restart_import(); return end
    table.remove(run.tasks, 1)
    if #run.tasks > 0 then return end
    if run.ok == 'verified' then mark_verified(); run.phase = 'cutover'
    else run.phase = run.ok end
  end
  function phases.cutover()
    cutover()
    run.phase = 'done'
  end

  -- step advances the import by one unit. It returns true while work remains, false when SQL is
  -- done.
  local function step()
    if run.phase ~= 'done' then phases[run.phase]() end
    return run.phase ~= 'done'
  end

  return {step = step}
end
