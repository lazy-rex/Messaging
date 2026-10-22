-- Durable messaging. The LazyRex Plugin SDK does the registration, the dispatch and one SQL
-- transaction for each handler; the hub keeps the database and replaces this process after a
-- restart. The hub starts this file through the SDK launcher (lazyrex.json "sdk": "0").
local app = require('lazyrex').plugin('messaging')
local fail = app.fail
local db = app.db

-- Hub calls (roster, tabs, sessions). A hub error keeps its code; only an unknown outcome is
-- 'unavailable' (the SDK).
local hub = app.hub

local function part(value)
  return tostring(#value) .. ':' .. value
end

-- join is table.concat for a list of any length. Rex Lua fails table.concat of more than 2559
-- items with "registry overflow" (LazyRex docs/rex-protocol.md), so join concatenates blocks of
-- 1000 items.
local function join(list, sep)
  local blocks = {}
  for k = 1, #list, 1000 do blocks[#blocks + 1] = table.concat(list, sep, k, math.min(k + 999, #list)) end
  return table.concat(blocks, sep)
end

-- The hub owns immutable aliases. The plugin owns the rows that use those aliases.
local aliases, participants = {}, {}
local function canonical(id) return aliases[id] or id end
local function later(a, b) return #a > #b or (#a == #b and a > b) end

local function parts(text)
  local out, pos = {}, 1
  while pos <= #text do
    local first, last, size = text:find('^(%d+):', pos)
    if not first then return nil end
    size = tonumber(size)
    if last + size > #text then return nil end
    out[#out + 1] = text:sub(last + 1, last + size)
    pos = last + size + 1
  end
  return out
end

local function observed_direct_id(a, b)
  a, b = canonical(a), canonical(b)
  if b < a then local t = a; a = b; b = t end
  return 'd-' .. (part(a) .. part(b)):gsub('.', function(c) return string.format('%02x', string.byte(c)) end)
end

local function observed_direct_parts(id)
  if type(id) ~= 'string' or not id:match('^d%-%x+$') or (#id - 2) % 2 ~= 0 then return nil end
  local raw = id:sub(3):gsub('%x%x', function(byte) return string.char(tonumber(byte, 16)) end)
  local pair = parts(raw)
  if not pair or #pair ~= 2 or pair[1] == '' or pair[2] == '' then return nil end
  pair[1], pair[2] = canonical(pair[1]), canonical(pair[2])
  if pair[1] == 'user' or pair[2] == 'user' then return nil end
  if pair[2] < pair[1] then local t = pair[1]; pair[1] = pair[2]; pair[2] = t end
  return pair
end

local function canonical_thread_id(id)
  local pair = observed_direct_parts(id)
  return pair and observed_direct_id(pair[1], pair[2]) or canonical(id)
end

-- pending: in a render, the aliases that the rows do not show yet (render_aliases). A render
-- treats them as plain agents. Each call starts with none.
local pending = {names = {}}
local function refresh_participants()
  aliases, participants, pending.names = {}, hub('hub.agents', {all = true}).agents or {}, {}
  for _, a in ipairs(participants) do
    if a.alias_of then aliases[a.id] = a.alias_of end
  end
end

local function resolve_recipient(id)
  -- The hub resolves a pending alias to its identity already; the rows still use the alias.
  if pending.names[id] then return id end
  if id == 'team' or (type(id) == 'string' and id:sub(1, 2) == 'g-') then return id end
  local ok, result = pcall(hub, 'hub.agents.resolve', {to = id})
  if ok then return result.id end
  -- The hub refuses a name that matches no agent, or more than one. A retry cannot change that, so
  -- it is invalid input, not 'unavailable'.
  if type(result) == 'table' and result.code == 'refused' then
    fail('invalid_input', 'Unknown recipient: ' .. tostring(id) .. ' (' .. tostring(result.message) .. ')')
  end
  error(result, 0)
end


-- Storage: the plugin's SQL database (hub.sql, docs/sql-storage.md). Each action and view handler
-- runs in one transaction (the SDK), so a rule is a plain read and write: no revision guards and
-- no retry loops. Revisions are INTEGER in SQL and decimal strings in Lua (CAST AS TEXT): a Lua
-- number is exact only up to 2^53.
--
-- A thread is a pair (thread_a, thread_b): a direct thread is the sorted pair of its agents; a
-- group thread is ('', group ID). A peer is what a viewer sees in its thread list: an agent ID, a
-- group ID, or the observed ID d-<hex> of an agent-to-agent thread (the user only).
db.migrate {function()
  for _, sql in ipairs({
    'CREATE TABLE clock (one INTEGER PRIMARY KEY CHECK (one = 1), n INTEGER NOT NULL)',
    'INSERT INTO clock (one, n) VALUES (1, 0)',
    'CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    [[CREATE TABLE messages (seq INTEGER PRIMARY KEY, id TEXT NOT NULL UNIQUE, sender TEXT NOT NULL,
      recipient TEXT NOT NULL, thread_a TEXT NOT NULL, thread_b TEXT NOT NULL, body TEXT NOT NULL,
      reply_to TEXT, reply_expected INTEGER, at TEXT NOT NULL)]],
    'CREATE INDEX messages_thread ON messages (thread_a, thread_b, seq)',
    'CREATE INDEX messages_sender ON messages (sender)',
    'CREATE INDEX messages_recipient ON messages (recipient)',
    -- The audience, fixed at send: one row for each recipient. acked = 0 is unread.
    [[CREATE TABLE deliveries (agent TEXT NOT NULL, seq INTEGER NOT NULL REFERENCES messages (seq),
      acked INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (agent, seq)) WITHOUT ROWID]],
    'CREATE INDEX deliveries_unread ON deliveries (agent, seq) WHERE acked = 0',
    -- Created groups. The team has no rows: its members are the live roster. pos keeps the member
    -- order; current = 0 is a past member.
    'CREATE TABLE groups (gid TEXT PRIMARY KEY, name TEXT NOT NULL)',
    [[CREATE TABLE group_members (gid TEXT NOT NULL REFERENCES groups (gid), agent TEXT NOT NULL,
      pos INTEGER NOT NULL, current INTEGER NOT NULL, PRIMARY KEY (gid, agent)) WITHOUT ROWID]],
    -- The home session of a thread. The user's home of an observed thread is (d-<hex>, 'user').
    [[CREATE TABLE thread_homes (thread_a TEXT NOT NULL, thread_b TEXT NOT NULL, home_session TEXT NOT NULL,
      moved INTEGER NOT NULL DEFAULT 0, set_rev INTEGER NOT NULL, PRIMARY KEY (thread_a, thread_b)) WITHOUT ROWID]],
    [[CREATE TABLE thread_titles (viewer TEXT NOT NULL, peer TEXT NOT NULL, title TEXT NOT NULL,
      set_rev INTEGER NOT NULL, PRIMARY KEY (viewer, peer)) WITHOUT ROWID]],
    'CREATE TABLE thread_opened (viewer TEXT NOT NULL, peer TEXT NOT NULL, PRIMARY KEY (viewer, peer)) WITHOUT ROWID',
    'CREATE TABLE thread_archived (viewer TEXT NOT NULL, peer TEXT NOT NULL, PRIMARY KEY (viewer, peer)) WITHOUT ROWID',
    -- A draft row can have empty text: its rev is still the draft revision. No row is revision 0.
    [[CREATE TABLE drafts (viewer TEXT NOT NULL, peer TEXT NOT NULL, text TEXT NOT NULL, rev INTEGER NOT NULL,
      PRIMARY KEY (viewer, peer)) WITHOUT ROWID]],
    -- Saved operations: an agent key replays forever (store = false in the SDK). owner is the
    -- agent part of the key, so a lookup finds the keys of an identity's aliases.
    'CREATE TABLE operations (key TEXT PRIMARY KEY, owner TEXT NOT NULL, fingerprint TEXT NOT NULL, result TEXT NOT NULL)',
    'CREATE TABLE aliases_applied (alias TEXT PRIMARY KEY, identity TEXT NOT NULL)',
    'CREATE TABLE gallery (key TEXT PRIMARY KEY, value TEXT NOT NULL, rev INTEGER NOT NULL)',
    -- The import from the key-value store (import.lua): the source records with their revisions,
    -- the saved operations, and large bodies in parts.
    'CREATE TABLE import_source (key TEXT PRIMARY KEY, rev TEXT NOT NULL, complete INTEGER NOT NULL)',
    'CREATE TABLE import_ops (key TEXT PRIMARY KEY)',
    'CREATE TABLE import_body (key TEXT PRIMARY KEY, body BLOB NOT NULL)',
  }) do db.exec(sql) end
end}

-- rows returns every row of a query. One hub.sql reply holds about 1 MB of rows; db.each reads
-- the next parts with OFFSET (a query with its own LIMIT too). In a transaction the parts come
-- from one snapshot. In a render (no transaction) they can come from two commits; the next change
-- renders again.
local function rows(sql, ...)
  local out, n = {}, select('#', ...)
  local args = {...}
  args[n + 1] = function(r) out[#out + 1] = r end
  db.each(sql, unpack(args, 1, n + 1))
  return out
end
local function json(list) return rex.json.encode(list) end

-- bump gives out the next revision. Every write that gives out a revision (a message seq, a draft
-- rev, a set_rev, a gallery rev) bumps the clock, so two writes never share one.
local function bump()
  local r = db.exec('UPDATE clock SET n = n + 1 WHERE one = 1 AND n < 9223372036854775807 RETURNING CAST(n AS TEXT) AS n')
  if r.changes ~= 1 then fail('clock_exhausted', 'The revision counter is exhausted') end
  return r.rows[1].n
end

-- Notices. A handler marks each agent whose unread state it may change; at its end, flush gives
-- the hub one notice for each agent (the hub admits one for each agent in a commit), with
-- pending queried after the writes, so it is exact. inside: a handler runs, and its end flushes.
local notes = {marked = {}, list = {}, inside = false}
local function notify(agent)
  if not notes.marked[agent] then notes.marked[agent] = true; notes.list[#notes.list + 1] = agent end
end
local function flush()
  local list = notes.list
  notes.marked, notes.list = {}, {}
  if #list == 0 then return end
  for _, r in ipairs(rows([[SELECT value AS agent,
      EXISTS (SELECT 1 FROM deliveries d WHERE d.agent = value AND d.acked = 0) AS p FROM json_each(?)]], json(list))) do
    app.notice(r.agent, r.p == 1)
  end
end


-- Saved operations. saved_operation looks up exact keys; prior_operation searches the keys of an
-- identity and of its aliases.
local function saved_operation(keys)
  local found = rows('SELECT fingerprint, result FROM operations WHERE key IN (SELECT value FROM json_each(?))', json(keys))
  if #found > 1 then fail('operation_conflict', 'This key was used by more than one aliased agent') end
  if #found == 0 then return {found = false} end
  return {found = true, fingerprint = found[1].fingerprint, result = rex.json.decode(found[1].result)}
end
local function prior_operation(prefix, agent, key)
  local keys = {prefix .. part(agent) .. part(key)}
  for old, id in pairs(aliases) do if id == agent then keys[#keys + 1] = prefix .. part(old) .. part(key) end end
  return saved_operation(keys)
end

local function save_operation(key, owner, fingerprint, result)
  db.exec('INSERT INTO operations (key, owner, fingerprint, result) VALUES (?, ?, ?, ?)', key, owner, fingerprint, json(result))
end

-- Identity aliases. The hub owns them; the plugin moves its rows to the identity once for each
-- alias, in one transaction, in sorted order. A message unread under either name stays unread.
-- Viewer rows and homes: Lua reads only their keys and the columns of the winner rule; the values
-- (a draft can be 16 KB) stay in SQL. settle gives the target row the winner's values and deletes
-- the other rows of the group. A key column changes in place only when no row has the target key.
local function settle(t, target, group, winner)
  local where = t.k1 .. ' = ? AND ' .. t.k2 .. ' = ?'
  local function is_target(r) return r.k1 == target[1] and r.k2 == target[2] end
  local has_target = false
  for _, r in ipairs(group) do
    if is_target(r) then has_target = true
    elseif r ~= winner then db.exec('DELETE FROM ' .. t.name .. ' WHERE ' .. where, r.k1, r.k2) end
  end
  if is_target(winner) then return end
  if not has_target then
    db.exec('UPDATE ' .. t.name .. ' SET ' .. t.k1 .. ' = ?, ' .. t.k2 .. ' = ? WHERE ' .. where, target[1], target[2], winner.k1, winner.k2)
    return
  end
  if t.values then
    db.exec('UPDATE ' .. t.name .. ' SET (' .. t.values .. ') = (SELECT ' .. t.values .. ' FROM ' .. t.name .. ' WHERE ' .. where .. ') WHERE ' .. where,
      winner.k1, winner.k2, target[1], target[2])
  end
  db.exec('DELETE FROM ' .. t.name .. ' WHERE ' .. where, winner.k1, winner.k2)
end

-- merge groups the rows of table t by target key and settles each group that changes. pick returns
-- the winner of a group.
local function merge(t, list, target_of, pick)
  local groups, order = {}, {}
  for _, r in ipairs(list) do
    local target = target_of(r)
    local k = part(target[1]) .. part(target[2])
    if not groups[k] then groups[k] = {target = target, rows = {}, changed = false}; order[#order + 1] = k end
    table.insert(groups[k].rows, r)
    if target[1] ~= r.k1 or target[2] ~= r.k2 then groups[k].changed = true end
  end
  for _, k in ipairs(order) do
    local g = groups[k]
    if g.changed then settle(t, g.target, g.rows, pick(g.target, g.rows)) end
  end
end

-- newest returns the row with the latest revision in column c (decimal text).
local function newest(list, c)
  local w = list[1]
  for _, r in ipairs(list) do if later(r[c], w[c]) then w = r end end
  return w
end

local function merge_alias(x, y)
  db.exec('UPDATE messages SET sender = ? WHERE sender = ?', y, x)
  db.exec('UPDATE messages SET recipient = ? WHERE recipient = ?', y, x)
  db.exec([[UPDATE messages SET
      thread_a = min(CASE thread_a WHEN ? THEN ? ELSE thread_a END, CASE thread_b WHEN ? THEN ? ELSE thread_b END),
      thread_b = max(CASE thread_a WHEN ? THEN ? ELSE thread_a END, CASE thread_b WHEN ? THEN ? ELSE thread_b END)
    WHERE thread_a <> '' AND (thread_a = ? OR thread_b = ?)]], x, y, x, y, x, y, x, y, x, x)
  db.exec([[INSERT INTO deliveries (agent, seq, acked) SELECT ?, seq, acked FROM deliveries WHERE agent = ?
    ON CONFLICT (agent, seq) DO UPDATE SET acked = min(acked, excluded.acked)]], y, x)
  db.exec('DELETE FROM deliveries WHERE agent = ?', x)
  db.exec([[INSERT INTO group_members (gid, agent, pos, current) SELECT gid, ?, pos, current FROM group_members WHERE agent = ?
    ON CONFLICT (gid, agent) DO UPDATE SET pos = min(pos, excluded.pos), current = max(current, excluded.current)]], y, x)
  db.exec('DELETE FROM group_members WHERE agent = ?', x)
  -- Viewer rows: (viewer, peer). An observed peer d-<hex> names agents too.
  local function viewer_merge(name, values, columns, pick)
    local list = rows('SELECT viewer AS k1, peer AS k2' .. columns .. ' FROM ' .. name
      .. " WHERE viewer IN (?, ?) OR peer IN (?, ?) OR peer LIKE 'd-%' ORDER BY viewer, peer", x, y, x, y)
    merge({name = name, k1 = 'viewer', k2 = 'peer', values = values}, list,
      function(r) return {canonical(r.k1), canonical_thread_id(r.k2)} end, pick)
  end
  -- The latest explicit rename wins.
  viewer_merge('thread_titles', 'title, set_rev', ', CAST(set_rev AS TEXT) AS set_rev', function(_, g) return newest(g, 'set_rev') end)
  viewer_merge('thread_opened', nil, '', function(_, g) return g[1] end)
  viewer_merge('thread_archived', nil, '', function(_, g) return g[1] end)
  -- Drafts: a non-empty draft wins over an empty one, then the latest revision. Two non-empty
  -- drafts with different text are a conflict: SQL compares the texts.
  viewer_merge('drafts', 'text, rev', ", CAST(rev AS TEXT) AS rev, text <> '' AS full", function(target, g)
    local full = {}
    for _, r in ipairs(g) do if r.full == 1 then full[#full + 1] = r end end
    if #full > 1 then
      local keys = {}
      for _, r in ipairs(full) do keys[#keys + 1] = {r.k1, r.k2} end
      local n = db.first([[SELECT count(DISTINCT d.text) AS n FROM drafts d JOIN json_each(?) k
        ON d.viewer = json_extract(k.value, '$[0]') AND d.peer = json_extract(k.value, '$[1]')]], json(keys)).n
      if n > 1 then fail('migration_conflict', 'Two drafts have different text for ' .. target[1] .. ' and ' .. target[2]) end
    end
    return newest(#full > 0 and full or g, 'rev')
  end)
  -- Homes: a move (moved = 1) is an explicit choice, and the newest move wins. Without a move, the
  -- first home wins. set_rev moves with the value.
  local list = rows([[SELECT thread_a AS k1, thread_b AS k2, moved, CAST(set_rev AS TEXT) AS set_rev FROM thread_homes
    WHERE thread_a IN (?, ?) OR thread_b IN (?, ?) OR thread_a LIKE 'd-%' ORDER BY thread_a, thread_b]], x, y, x, y)
  merge({name = 'thread_homes', k1 = 'thread_a', k2 = 'thread_b', values = 'home_session, moved, set_rev'}, list, function(r)
    if r.k1:sub(1, 2) == 'd-' then return {canonical_thread_id(r.k1), r.k2} end
    if r.k1 == '' then return {r.k1, r.k2} end
    local a, b = canonical(r.k1), canonical(r.k2)
    if b < a then return {b, a} end
    return {a, b}
  end, function(_, g)
    local moved, first
    for _, r in ipairs(g) do
      if r.moved == 1 and (not moved or later(r.set_rev, moved.set_rev)) then moved = r end
      if not first or later(first.set_rev, r.set_rev) then first = r end
    end
    return moved or first
  end)
  db.exec('INSERT INTO aliases_applied (alias, identity) VALUES (?, ?)', x, y)
  notify(x)
  notify(y)
end

local function migrate_aliases()
  local names = {}
  for id in pairs(aliases) do names[#names + 1] = id end
  if #names == 0 then return end
  table.sort(names)
  local applied = {}
  for _, r in ipairs(rows('SELECT alias, identity FROM aliases_applied WHERE alias IN (SELECT value FROM json_each(?))', json(names))) do
    applied[r.alias] = r.identity
  end
  for _, x in ipairs(names) do
    if not applied[x] then
      -- In a handler, the handler's end flushes the notices; else this merge's own transaction does.
      db.transaction(function() merge_alias(x, aliases[x]); if not notes.inside then flush() end end)
    elseif applied[x] ~= aliases[x] then fail('internal', 'An identity alias changed') end
  end
end

local function normalized_fingerprint(fp)
  local prefix, suffix = fp:match('^([^/]+)/(.+)$')
  if prefix == 'send-v2' then
    local p, fyi = parts(suffix), false
    if not p and suffix:sub(-4) == '/fyi' then fyi = true; p = parts(suffix:sub(1, -5)) end
    if not p or #p ~= 3 then return fp end
    return prefix .. '/' .. part(canonical(p[1])) .. part(p[2]) .. part(p[3]) .. (fyi and '/fyi' or '')
  elseif prefix == 'thread-create-v1' or prefix == 'thread-create-home-v1' or prefix == 'thread-create-session-v1' then
    local p = parts(suffix)
    if not p or #p < 2 then return fp end
    local members, seen = {}, {}
    local start = prefix == 'thread-create-session-v1' and 4 or (prefix == 'thread-create-home-v1' and 3 or 2)
    for i = start, #p do local id = canonical(p[i]); if not seen[id] then seen[id] = true; members[#members + 1] = id end end
    table.sort(members)
    local result = prefix .. '/' .. part(p[1])
    for i = 2, start - 1 do result = result .. part(p[i]) end
    for _, id in ipairs(members) do result = result .. part(id) end
    return result
  elseif prefix == 'thread-members-v1' then
    local p = parts(suffix)
    if not p or #p < 2 then return fp end
    local members, seen = {}, {}
    for i = 2, #p do local id = canonical(p[i]); if not seen[id] then seen[id] = true; members[#members + 1] = id end end
    table.sort(members)
    local result = prefix .. '/' .. part(canonical(p[1]))
    for _, id in ipairs(members) do result = result .. part(id) end
    return result
  elseif prefix == 'thread-move-v1' then
    local p = parts(suffix)
    if not p or #p ~= 3 then return fp end
    return prefix .. '/' .. part(canonical_thread_id(p[1])) .. part(p[2]) .. part(p[3])
  elseif prefix == 'thread-rename-v1' then
    local p = parts(suffix)
    if not p or #p ~= 2 then return fp end
    return prefix .. '/' .. part(canonical_thread_id(p[1])) .. part(p[2])
  elseif prefix == 'thread-archive-v1' then
    local ending = suffix:match('(true)$') or suffix:match('(false)$')
    if not ending then return fp end
    local p = parts(suffix:sub(1, -#ending - 1))
    if not p or #p ~= 1 then return fp end
    return prefix .. '/' .. part(canonical_thread_id(p[1])) .. ending
  elseif prefix == 'history-load-v1' then
    local p = parts(suffix)
    if not p or #p ~= 1 then return fp end
    return prefix .. '/' .. part(canonical_thread_id(p[1]))
  end
  return fp
end

-- Size limits (LazyRex docs/rex-protocol.md, "Rex Lua runtime"). What this plugin sends is at
-- most 64 KiB in one control message, and a reply that is too large never arrives. A result to
-- an agent (read, history) holds at most reply_budget encoded bytes; the client.reply frame adds
-- its envelope and call_id, inside the 16 KiB left.
local reply_budget = 49152

-- encoded_size returns the JSON size of v, counted as the hub's Go encoder writes it: '<', '>' and
-- '&' as \u003c (6 bytes), U+2028 and U+2029 as \u2028 (6 bytes). rex.json escapes no more than
-- that, so the count is also an upper bound of this plugin's own encoding.
local function encoded_size(v)
  local text = assert(rex.json.encode(v))
  local _, html = text:gsub('[<>&]', '')
  local _, separators = text:gsub('\226\128[\168\169]', '')
  return #text + 5 * html + 3 * separators
end

-- utf8_cut returns a prefix of s of at most n bytes that ends at a UTF-8 boundary.
local function utf8_cut(s, n)
  if n < 0 then n = 0 end
  if #s <= n then return s end
  local cut = n
  while cut > 0 do
    local b = s:byte(cut + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut)
end

-- preview names a long value in an error: a UTF-8-safe prefix of at most 64 bytes and its size.
local function preview(v)
  if #v <= 64 then return v end
  return utf8_cut(v, 64) .. '... (' .. #v .. ' bytes)'
end

-- Groups: a group is a recipient with members. A message to a group gets a delivery for every
-- other member and goes into the group's thread. The built-in group "team" has the whole roster
-- as members. The user and agents create other groups; their IDs start with "g-", so they never
-- equal an agent ID.
local builtin = {team = {name = 'Team'}}

local function roster()
  local ids = {}
  for _, a in ipairs(participants) do if not a.alias_of and a.state ~= 'superseded' then ids[#ids + 1] = a.id end end
  return ids
end

local function is_group_id(id)
  return builtin[id] ~= nil or (type(id) == 'string' and id:sub(1, 2) == 'g-')
end

-- created_groups returns every created group: {[gid] = {name, members, past_members}}, members
-- in order.
local function created_groups()
  local out = {}
  for _, g in ipairs(rows('SELECT gid, name FROM groups')) do out[g.gid] = {name = g.name, members = {}, past_members = {}} end
  for _, m in ipairs(rows('SELECT gid, agent, current FROM group_members ORDER BY gid, pos, agent')) do
    local g = out[m.gid]
    if m.current == 1 then g.members[#g.members + 1] = m.agent else g.past_members[#g.past_members + 1] = m.agent end
  end
  return out
end

-- group returns {name, members, past_members} for a group ID, or nil.
local function group(id)
  if builtin[id] then return {name = builtin[id].name, members = roster()} end
  if not is_group_id(id) then return nil end
  local g = db.first('SELECT name FROM groups WHERE gid = ?', id)
  if not g then return nil end
  local out = {name = g.name, members = {}, past_members = {}}
  for _, m in ipairs(rows('SELECT agent, current FROM group_members WHERE gid = ? ORDER BY pos, agent', id)) do
    if m.current == 1 then out.members[#out.members + 1] = m.agent else out.past_members[#out.past_members + 1] = m.agent end
  end
  return out
end

local function is_member(g, agent)
  for _, m in ipairs(g.members) do
    if m == agent then return true end
  end
  return false
end

-- recipients returns the audience of a message from sender to `to`.
local function recipients(sender, to)
  local g = group(to)
  if g then
    if not is_member(g, sender) then fail('refused', 'Only a member sends to this group') end
    local list = {}
    for _, id in ipairs(g.members) do
      if id ~= sender then list[#list + 1] = id end
    end
    return list
  end
  for _, a in ipairs(participants) do
    if not a.alias_of and a.id == to then return {to} end
  end
  fail('refused', 'Unknown recipient')
end

-- thread_pair returns the thread of a viewer a and a peer b. The user sees an observed thread
-- d-<hex> as the pair of its agents.
local function thread_pair(a, b)
  if a == 'user' then
    local pair = observed_direct_parts(b)
    if pair then return pair[1], pair[2] end
  end
  if is_group_id(b) then return '', b end -- a group has one thread for all members
  -- Not `a, b = b, a`: Rex 1203 Lua gives (b, b) (docs/rex-protocol.md).
  if b < a then local t = a; a = b; b = t end
  return a, b
end
local function pair_key(a, b) return part(a) .. part(b) end

-- home_pair returns the thread_homes key of a and b. The user's home of an observed thread is its
-- own row, (d-<hex>, 'user').
local function home_pair(a, b)
  if a == 'user' and observed_direct_parts(b) then
    if b < a then return b, a end
    return a, b
  end
  return thread_pair(a, b)
end

-- insert_message adds message m and its deliveries (the audience, fixed now) and marks the notices.
-- It returns the message's seq, its cursor.
local function insert_message(m, audience)
  local seq = bump()
  local ta, tb = thread_pair(m.from, m.to)
  db.exec([[INSERT INTO messages (seq, id, sender, recipient, thread_a, thread_b, body, reply_to, reply_expected, at)
    VALUES (CAST(? AS INTEGER), ?, ?, ?, ?, ?, ?, ?, ?, ?)]],
    seq, m.id, m.from, m.to, ta, tb, m.body, m.reply_to, m.reply_expected == false and 0 or nil, m.at)
  db.exec('INSERT INTO deliveries (agent, seq, acked) SELECT value, CAST(? AS INTEGER), 0 FROM json_each(?)', seq, json(audience))
  for _, id in ipairs(audience) do notify(id) end
  return seq
end

-- message_columns reads a message for a page: a body longer than cut bytes is cut in SQL to at
-- most cut bytes, at a UTF-8 boundary, so it stays TEXT; body_bytes is its full size. Not a BLOB
-- prefix: the SDK decodes a BLOB in Lua, and a 49 KB one fails with "registry overflow".
local function message_columns(cut)
  -- k continuation bytes (0x80..0xBF) start at byte cut + 1 - k: the cut moves back k bytes.
  local function cont(at) return 'substr(CAST(m.body AS BLOB), ' .. at .. ", 1) BETWEEN x'80' AND x'BF'" end
  local back = 'CASE WHEN NOT ' .. cont(cut + 1) .. ' THEN 0 WHEN NOT ' .. cont(cut) .. ' THEN 1 WHEN NOT '
    .. cont(cut - 1) .. ' THEN 2 ELSE 3 END'
  return [[CAST(m.seq AS TEXT) AS seq, m.id, m.sender, m.recipient, m.reply_to, m.reply_expected, m.at,
    CASE WHEN length(CAST(m.body AS BLOB)) > ]] .. cut .. [[ THEN CAST(substr(CAST(m.body AS BLOB), 1, ]] .. cut .. ' - ' .. back
    .. [[) AS TEXT) ELSE m.body END AS body, length(CAST(m.body AS BLOB)) AS body_bytes]]
end
local function as_message(r)
  local m = {id = r.id, from = r.sender, to = r.recipient, body = r.body, reply_to = r.reply_to, at = r.at}
  if r.reply_expected == 0 then m.reply_expected = false end
  return m
end
-- Pages. A read or history page holds at most reply_budget encoded bytes. A page is measured with
-- the largest value of its continuation fields (cursor_max), so the final page is not larger.
local cursor_max = string.rep('9', 20)
local count_max = 9999999999

-- read_item is the item of message m in a read or history page.
local function read_item(m, cursor)
  return {id = m.id, from = m.from, to = m.to, body = m.body, reply_to = m.reply_to,
    reply_expected = m.reply_expected, at = m.at, cursor = cursor}
end

-- min_marker is the smallest item a page can hold for a message: a marker with an empty ID prefix.
local min_marker = {cursor = cursor_max, id_prefix = '', id_bytes = count_max, metadata_too_large = true, bytes = count_max}

-- history_fits reports whether a history page of thread peer can hold one message at all.
local function history_fits(peer)
  return encoded_size({thread = peer, messages = {min_marker}, next_before = cursor_max}) <= reply_budget
end

-- page_bytes is the size of the largest page that holds message m alone: a read page, and a
-- history page for each thread value a reader can see (from, to).
local function page_bytes(m)
  local item = read_item(m, cursor_max)
  local worst = encoded_size({messages = {item}, next_cursor = cursor_max, more = true})
  for _, peer in ipairs({m.from, m.to}) do
    worst = math.max(worst, encoded_size({thread = peer, messages = {item}, next_before = cursor_max}))
  end
  return worst
end

-- admit refuses a new message that would not arrive in full in one read or history page.
-- body_limit: one SQL request of a send carries the body (the message insert, and the operation
-- fingerprint in another), and every request is at most 64 KiB. No request depends on mailbox,
-- group or thread size.
local body_limit = 16384
local function admit(m)
  local body = encoded_size(m.body) - 2
  if body > body_limit then
    fail('invalid_input', 'body is ' .. body .. ' bytes encoded; the limit is ' .. body_limit)
  end
  local n = page_bytes(m)
  if n > reply_budget then
    fail('invalid_input', 'The message does not fit one read page: ' .. n .. ' bytes encoded, limit ' .. reply_budget)
  end
end

-- full_body holds the full byte size of a body that a query read as a prefix (message_columns).
-- Such an item never fits a page; shrink reports its full sizes.
local full_body = setmetatable({}, {__mode = 'k'})

-- shrink makes the only item of page fit (a stored message from before admit). In order:
--   1. the body is cut to a UTF-8-safe prefix: truncated = true, body_bytes = its full size;
--   2. the metadata does not fit either: a marker {cursor, id, metadata_too_large, bytes};
--   3. the ID does not fit either: id_prefix (at most 256 bytes, can be empty) and id_bytes.
-- bytes is the encoded size of the full item (for a prefix-read body: without the escapes of the
-- part not read). The caller checked that min_marker fits.
local function shrink(page, item)
  local body = item.body or ''
  local body_bytes = full_body[item] or #body
  local full = encoded_size(item) + body_bytes - #body
  item.truncated, item.body_bytes, item.body = true, body_bytes, ''
  page.messages = {item}
  local over = encoded_size(page) - reply_budget
  if over <= 0 then
    local cut = utf8_cut(body, -over)
    item.body = cut
    over = encoded_size(page) - reply_budget
    while over > 0 do
      cut = utf8_cut(cut, #cut - over)
      item.body = cut
      over = encoded_size(page) - reply_budget
    end
    return
  end
  local marker = {cursor = item.cursor, id = item.id, metadata_too_large = true, bytes = full}
  page.messages = {marker}
  if encoded_size(page) <= reply_budget then return end
  marker.id, marker.id_bytes = nil, #item.id
  local prefix = utf8_cut(item.id, 256)
  marker.id_prefix = prefix
  over = encoded_size(page) - reply_budget
  while over > 0 and prefix ~= '' do
    prefix = utf8_cut(prefix, #prefix - over)
    marker.id_prefix = prefix
    over = encoded_size(page) - reply_budget
  end
  if over > 0 then fail('internal', 'A message marker does not fit one page') end
end

-- fit_page adds items to page.messages while the page stays within reply_budget, and returns the
-- number added. A first item that does not fit alone is shrunk, so each page makes progress.
local function fit_page(page, items)
  page.messages = {}
  local size = encoded_size(page)
  for i, item in ipairs(items) do
    local cost = encoded_size(item) + (i > 1 and 1 or 0)
    if size + cost > reply_budget then
      if i > 1 then return i - 1 end
      shrink(page, item)
      return 1
    end
    page.messages[i] = item
    size = size + cost
  end
  return #items
end

local function checked(page)
  local n = encoded_size(page)
  if n > reply_budget then fail('internal', 'A page is ' .. n .. ' bytes, over ' .. reply_budget) end
  return page
end

-- read_page_item is the page item of a message row, with its cursor. A body read as a prefix
-- keeps its full size in full_body.
local function page_item(r)
  local item = read_item(as_message(r), r.seq)
  if r.body_bytes > #r.body then full_body[item] = r.body_bytes end
  return item
end

local function saved_result(saved, fingerprint)
  if normalized_fingerprint(saved.fingerprint) ~= normalized_fingerprint(fingerprint) then fail('conflict', 'Send key already has different content') end
  if type(saved.result) ~= 'table' or type(saved.result.id) ~= 'string' then
    fail('internal', 'Invalid saved send result')
  end
  return saved.result
end

local function send(agent, args)
  for _, name in ipairs({'to', 'body', 'key'}) do
    if type(args[name]) ~= 'string' or args[name] == '' then
      fail('refused', name .. ' must be a nonempty string')
    end
  end
  if args.reply_to ~= nil and (type(args.reply_to) ~= 'string' or args.reply_to == '') then
    fail('refused', 'reply_to must be a nonempty message ID')
  end
  local id = 'send/' .. part(agent) .. part(args.key)
  if args.reply_expected ~= nil and type(args.reply_expected) ~= 'boolean' then fail('invalid_input', 'reply_expected must be boolean') end
  local fingerprint = 'send-v2/' .. part(args.to) .. part(args.body) .. part(args.reply_to or '')
  if args.reply_expected == false then fingerprint = fingerprint .. '/fyi' end
  local saved = prior_operation('send/', agent, args.key)
  if saved.found then return saved_result(saved, fingerprint) end
  -- Size limits apply to new sends only: a stored result replays above, whatever its size.
  if #args.key > 200 then fail('invalid_input', 'key is ' .. #args.key .. ' bytes; the limit is 200') end
  if args.reply_to and #args.reply_to > 512 then fail('invalid_input', 'reply_to is ' .. #args.reply_to .. ' bytes; the limit is 512') end
  args.to = resolve_recipient(args.to)
  local targets = recipients(agent, args.to)
  -- The reply target: a message to this agent (a delivery), from the recipient or in the same group.
  local original
  if args.reply_to then
    original = db.first([[SELECT CAST(m.seq AS TEXT) AS seq, m.sender, m.recipient FROM messages m
      JOIN deliveries d ON d.seq = m.seq AND d.agent = ? WHERE m.id = ?]], agent, args.reply_to)
    if not original or (original.sender ~= args.to and (not is_group_id(args.to) or original.recipient ~= args.to)) then
      fail('refused', 'reply_to must name a message to this agent, from the recipient or in the same group')
    end
  end
  local result = {id = id, key = args.key}
  local message = {id = id, from = agent, to = args.to, body = args.body, reply_to = args.reply_to, at = os.date('!%Y-%m-%dT%H:%M:%SZ')}
  if args.reply_expected == false then message.reply_expected = false end
  admit(message)
  insert_message(message, targets)
  if original then
    -- A reply acknowledges the message that it answers. An acked target is not an error.
    db.exec('UPDATE deliveries SET acked = 1 WHERE agent = ? AND seq = CAST(? AS INTEGER)', agent, original.seq)
    notify(agent)
  end
  save_operation(id, agent, fingerprint, result)
  return result
end

-- read_limit is the most messages one read page can hold: a page is reply_budget bytes, and an
-- item is larger than 64 bytes.
local read_limit = math.floor(reply_budget / 64)

local function read(agent, args)
  local since = args.since or '0'
  if type(since) ~= 'string' or not since:match('^%d+$') or (#since > 1 and since:sub(1, 1) == '0') then
    fail('invalid_input', 'since must be a decimal revision cursor')
  end
  local filter, ta, tb = '', nil, nil
  if args.thread ~= nil then
    if type(args.thread) ~= 'string' or args.thread == '' then fail('invalid_input', 'thread must be a nonempty ID') end
    args.thread = resolve_recipient(args.thread)
    if not is_group_id(args.thread) then recipients(agent, args.thread)
    else
      local g = group(args.thread)
      if not g then fail('invalid_input', 'Unknown thread') end
      local allowed = is_member(g, agent)
      for _, id in ipairs(g.past_members or {}) do if id == agent then allowed = true end end
      if not allowed then fail('refused', 'Only a current or former member reads delivered group mail') end
    end
    ta, tb = thread_pair(agent, args.thread)
    filter = ' AND m.thread_a = ? AND m.thread_b = ?'
  end
  -- One snapshot (the handler's transaction). high is the newest delivery of the agent in it, so
  -- it changes only with the agent's own mail; a later delivery gets a larger seq.
  local high = db.first('SELECT CAST(coalesce(max(seq), 0) AS TEXT) AS n FROM deliveries WHERE agent = ?', agent).n
  local query = 'SELECT ' .. message_columns(reply_budget + 1) .. [[ FROM deliveries d JOIN messages m ON m.seq = d.seq
    WHERE d.agent = ? AND d.acked = 0 AND d.seq > CAST(? AS INTEGER)]] .. filter .. ' ORDER BY d.seq LIMIT ' .. read_limit
  local selected
  if filter ~= '' then selected = rows(query, agent, since, ta, tb) else selected = rows(query, agent, since) end
  if #selected == 0 then return {messages = {}, next_cursor = high} end
  local messages = {}
  for i, r in ipairs(selected) do messages[i] = page_item(r) end
  -- A page that stops early continues after its last message: next_cursor is that cursor.
  local page = {next_cursor = cursor_max, more = true}
  local n = fit_page(page, messages)
  if n == #messages and #selected < read_limit then
    page.more, page.next_cursor = nil, high
  else
    page.next_cursor = page.messages[n].cursor
  end
  return checked(page)
end

-- History pages do not change unread mail. Group history requires current membership.
local function history(agent, args)
  if type(args.thread) ~= 'string' or args.thread == '' then fail('invalid_input', 'thread is required') end
  local peer = resolve_recipient(args.thread)
  local g = group(peer)
  if g and not is_member(g, agent) then fail('refused', 'Only a current member can read this group history') end
  recipients(agent, peer)
  if not history_fits(peer) then
    fail('thread_id_too_large', 'Thread ID ' .. preview(peer) .. ' is too long for one history page (' .. encoded_size(peer) .. ' bytes encoded)')
  end
  local limit = args.limit or 20
  if type(limit) ~= 'number' or limit % 1 ~= 0 or limit < 1 or limit > 50 then fail('invalid_input', 'limit must be an integer from 1 to 50') end
  local before = args.before
  if before ~= nil and (type(before) ~= 'string' or not before:match('^[1-9][0-9]*$')) then fail('invalid_input', 'before must be a positive revision cursor') end
  local ta, tb = thread_pair(agent, peer)
  local query = 'SELECT ' .. message_columns(reply_budget + 1) .. ' FROM messages m WHERE m.thread_a = ? AND m.thread_b = ?'
    .. (before and ' AND m.seq < CAST(? AS INTEGER)' or '') .. ' ORDER BY m.seq DESC LIMIT ' .. (limit + 1)
  local found
  if before then found = rows(query, ta, tb, before) else found = rows(query, ta, tb) end
  local messages = {}
  for i = 1, math.min(limit, #found) do messages[i] = page_item(found[i]) end
  -- The page also stops at reply_budget. next_before then names its oldest message.
  local result = {thread = peer, next_before = cursor_max}
  local n = fit_page(result, messages)
  result.next_before = (n < #messages or #found > limit) and result.messages[n].cursor or nil
  return checked(result)
end

local function ack(agent, args)
  if type(args.ids) ~= 'table' then fail('refused', 'ids must be an array of message IDs') end
  local wanted, ids, count, maximum = {}, {}, 0, 0
  for index, id in pairs(args.ids) do
    if type(index) ~= 'number' or index < 1 or index % 1 ~= 0 or type(id) ~= 'string' or id == '' then
      fail('refused', 'ids must be an array of nonempty message IDs')
    end
    count = count + 1
    maximum = math.max(maximum, index)
    if not wanted[id] then ids[#ids + 1] = id end
    wanted[id] = true
  end
  if count ~= maximum then fail('refused', 'ids must be a contiguous array') end
  if count == 0 then return {acked = true} end
  -- Every ID must be addressed to this agent (a delivery), else nothing changes.
  local found = rows([[SELECT m.id, d.acked FROM messages m JOIN deliveries d ON d.seq = m.seq AND d.agent = ?
    WHERE m.id IN (SELECT value FROM json_each(?))]], agent, json(ids))
  if #found ~= #ids then fail('refused', 'Unknown message ID for this agent') end
  local unread = false
  for _, r in ipairs(found) do unread = unread or r.acked == 0 end
  if not unread then return {acked = true} end
  db.exec([[UPDATE deliveries SET acked = 1 WHERE agent = ? AND acked = 0
    AND seq IN (SELECT seq FROM messages WHERE id IN (SELECT value FROM json_each(?)))]], agent, json(ids))
  notify(agent)
  return {acked = true}
end

-- Views for the user's renderer (spike 3 "Renderer contract"). Only the hub calls these; it
-- passes the user. The landing panel lists threads; "/thread/<agent>" shows one conversation.
-- The gallery's history holds at most page_size messages. A thread view sends its whole history:
-- the transcript pane prints it once into native scrollback (the maintainer, 2026-10-18).
local page_size = 200

local function display_name(a)
  if type(a.name) == 'string' and a.name ~= a.id and a.name:match('%S') then return a.name end
  local kind, suffix = a.id:match('^([^:]+):(.+)$')
  if kind == 'claude' or kind == 'codex' then return kind .. ':' .. suffix:sub(1, 8) end
  return a.id
end

-- unread_counts returns the unread messages of user for each peer, and their total.
local function unread_counts(user)
  local counts, total = {}, 0
  for _, r in ipairs(rows([[SELECT CASE WHEN m.thread_a = '' THEN m.recipient WHEN m.sender = ? THEN m.recipient ELSE m.sender END AS peer,
      count(*) AS n FROM deliveries d JOIN messages m ON m.seq = d.seq WHERE d.agent = ? AND d.acked = 0 GROUP BY 1]], user, user)) do
    counts[r.peer] = r.n
    total = total + r.n
  end
  return counts, total
end

-- view_state reads at once what the thread lists of user show: the homes, the newest message of
-- each thread, user's titles, opened and archived threads, unread counts and the created groups.
-- A function that takes a state s reads from it; without one, it queries.
local function view_state(user)
  local s = {homes = {}, last = {}, titles = {}, opened = {}, archived = {}, groups = created_groups()}
  for _, r in ipairs(rows('SELECT thread_a, thread_b, home_session FROM thread_homes')) do s.homes[pair_key(r.thread_a, r.thread_b)] = r.home_session end
  for _, r in ipairs(rows([[SELECT m.thread_a, m.thread_b, m.id FROM messages m
      JOIN (SELECT max(seq) AS s FROM messages GROUP BY thread_a, thread_b) t ON m.seq = t.s]])) do
    s.last[pair_key(r.thread_a, r.thread_b)] = r.id
  end
  for _, r in ipairs(rows('SELECT peer, title FROM thread_titles WHERE viewer = ?', user)) do s.titles[r.peer] = r.title end
  for _, r in ipairs(rows('SELECT peer FROM thread_opened WHERE viewer = ?', user)) do s.opened[r.peer] = true end
  for _, r in ipairs(rows('SELECT peer FROM thread_archived WHERE viewer = ?', user)) do s.archived[r.peer] = true end
  s.counts, s.total = unread_counts(user)
  return s
end

local function thread_home(a, b, s)
  local ha, hb = home_pair(a, b)
  if s then return s.homes[pair_key(ha, hb)] end
  local r = db.first('SELECT home_session FROM thread_homes WHERE thread_a = ? AND thread_b = ?', ha, hb)
  return r and r.home_session or nil
end

-- last_message returns the ID of the newest message of the thread of a and b, or nil.
local function last_message(a, b, s)
  local ta, tb = thread_pair(a, b)
  if s then return s.last[pair_key(ta, tb)] end
  local r = db.first('SELECT id FROM messages WHERE thread_a = ? AND thread_b = ? ORDER BY seq DESC LIMIT 1', ta, tb)
  return r and r.id or nil
end

-- Only explicit user opens create a marker. Roster membership does not create a tab.
local function opened_thread(user, peer, s)
  peer = canonical_thread_id(peer)
  if s then return s.opened[peer] == true end
  return db.first('SELECT 1 AS x FROM thread_opened WHERE viewer = ? AND peer = ?', user, peer) ~= nil
end

local function remember_thread_open(user, peer)
  if user ~= 'user' then return end
  db.exec('INSERT INTO thread_opened (viewer, peer) VALUES (?, ?) ON CONFLICT DO NOTHING', user, canonical_thread_id(peer))
end

local function thread_title(user, peer, s)
  local title
  if s then title = s.titles[peer.id]
  else
    local r = db.first('SELECT title FROM thread_titles WHERE viewer = ? AND peer = ?', user, peer.id)
    title = r and r.title
  end
  if type(title) == 'string' and title:match('%S') then return title end
  return display_name(peer)
end

local function observed_direct_peer(id, s)
  local pair = observed_direct_parts(id)
  if not pair or not last_message(pair[1], pair[2], s) then return nil end
  local names = {}
  for _, a in ipairs(participants) do if not a.alias_of then names[a.id] = display_name(a) end end
  return {id = observed_direct_id(pair[1], pair[2]), name = (names[pair[1]] or pair[1]) .. ' ↔ ' .. (names[pair[2]] or pair[2]),
    observer = true, readonly = true}
end

-- peers lists the threads of user. s: optional view state. direct_only: no observed
-- agent-to-agent threads (a caller that resolves one by its ID first).
local function peers(user, s, direct_only)
  local list = {}
  for _, a in ipairs(participants) do
    if a.id ~= user and not a.alias_of then list[#list + 1] = a end
  end
  for gid, g in pairs(builtin) do list[#list + 1] = {id = gid, name = g.name, group = true} end
  local created = {}
  for gid, g in pairs(s and s.groups or created_groups()) do
    if is_member(g, user) or user == 'user' then
      created[#created + 1] = {id = gid, name = g.name, group = true, observer = not is_member(g, user)}
    end
  end
  table.sort(created, function(x, y) return x.name < y.name or (x.name == y.name and x.id < y.id) end)
  for _, g in ipairs(created) do list[#list + 1] = g end
  if user == 'user' and not direct_only then
    -- The observed agent-to-agent threads: every direct thread of two agents with a message.
    local pairs_list = {}
    if s then
      for key in pairs(s.last) do
        local p = parts(key)
        if p[1] ~= '' then pairs_list[#pairs_list + 1] = {thread_a = p[1], thread_b = p[2]} end
      end
    else
      pairs_list = rows("SELECT DISTINCT thread_a, thread_b FROM messages WHERE thread_a <> ''")
    end
    local seen, observed = {}, {}
    for _, r in ipairs(pairs_list) do
      if r.thread_a ~= user and r.thread_b ~= user then
        local id = observed_direct_id(r.thread_a, r.thread_b)
        if not seen[id] then
          local peer = observed_direct_peer(id, s)
          if peer then observed[#observed + 1] = peer; seen[id] = true end
        end
      end
    end
    table.sort(observed, function(a, b) return a.name < b.name or (a.name == b.name and a.id < b.id) end)
    for _, peer in ipairs(observed) do list[#list + 1] = peer end
  end
  return list
end

local function thread_peer(route, user)
  local peer = type(route) == 'string' and route:match('^/thread/([^/]+)$')
  if user == 'user' and observed_direct_parts(peer) then
    local observed = observed_direct_peer(peer)
    if observed then return observed end
    fail('invalid_input', 'Unknown observed thread')
  end
  if peer then peer = resolve_recipient(peer) end
  if not peer then fail('invalid_input', 'Not a thread route: ' .. tostring(route)) end
  for _, a in ipairs(peers(user, nil, true)) do
    if a.id == peer then return a end
  end
  fail('invalid_input', 'Unknown thread: ' .. peer)
end

local function unread_status(count, name)
  if count > 0 then return {state = 'done', msg = tostring(count) .. ' unread' .. (name and (' in ' .. name) or '')} end
end

local function thread_list(agent, args)
  if args.include_archived ~= nil and type(args.include_archived) ~= 'boolean' then fail('invalid_input', 'include_archived must be boolean') end
  local s = view_state(agent)
  local list = {}
  for _, peer in ipairs(peers(agent, s)) do
    if not s.archived[peer.id] or args.include_archived then
      local g = peer.group and (builtin[peer.id] and group(peer.id) or s.groups[peer.id]) or nil
      list[#list + 1] = {id = peer.id, title = thread_title(agent, peer, s), members = g and g.members or {agent, peer.id},
        group = peer.group == true, observer = peer.observer or nil, readonly = peer.readonly or nil,
        archived = s.archived[peer.id] == true, unread = peer.observer and 0 or (s.counts[peer.id] or 0)}
    end
  end
  return {threads = list}
end

local function operation_result(saved, fingerprint)
  if normalized_fingerprint(saved.fingerprint) ~= normalized_fingerprint(fingerprint) then fail('operation_conflict', 'Operation key already has different content') end
  if type(saved.result) ~= 'table' then fail('internal', 'Invalid saved operation') end
  return saved.result
end

-- An intent keeps operation retries independent of the caller's current session.
local function session_intent(args)
  if args.session_id ~= nil and args.new_session ~= nil then fail('invalid_input', 'Choose an existing session or a new session') end
  if args.session_id ~= nil then
    if type(args.session_id) ~= 'string' or args.session_id == '' then fail('invalid_input', 'session_id must be a session ID') end
    return 'id', args.session_id
  end
  if args.new_session ~= nil then
    if type(args.new_session) ~= 'string' then fail('invalid_input', 'new_session must be a name') end
    local name = args.new_session:match('^%s*(.-)%s*$')
    if name == '' then fail('invalid_input', 'Enter a new session name') end
    return 'new', name
  end
  return 'default', ''
end

local function resolve_session(kind, value, source_session, key)
  if kind == 'new' then
    local result = hub('hub.session.ensure', {key = key, name = value})
    if type(result.session_id) ~= 'string' or result.session_id == '' then fail('internal', 'The hub returned no session ID') end
    return result.session_id
  end
  local id = kind == 'id' and value or source_session
  if type(id) ~= 'string' or id == '' then fail('invalid_input', 'The caller has no source session. Choose a session explicitly.') end
  for _, session in ipairs(hub('hub.session.list').sessions or {}) do
    if session.session_id == id then return id end
  end
  fail('not_found', 'The selected session is closed. Choose an open session.')
end


local function thread_create(agent, args, source_session)
  if type(args.key) ~= 'string' or args.key == '' then fail('invalid_input', 'key is required') end
  if type(args.members) ~= 'table' then fail('invalid_input', 'members must be an array') end
  if args.title ~= nil and type(args.title) ~= 'string' then fail('invalid_input', 'title must be text') end
  local session_kind, session_value = session_intent(args)
  local title = (args.title or ''):match('^%s*(.-)%s*$')
  local known = {}
  for _, a in ipairs(participants) do if not a.alias_of then known[a.id] = display_name(a) end end
  local selected, count, maximum = {[agent] = true}, 0, 0
  for index, id in pairs(args.members) do
    if type(index) ~= 'number' or index < 1 or index % 1 ~= 0 or type(id) ~= 'string' then
      fail('invalid_input', 'members must contain known participant IDs')
    end
    id = resolve_recipient(id)
    if not known[id] then fail('invalid_input', 'members must contain known participant IDs') end
    selected[id] = true
    count = count + 1
    maximum = math.max(maximum, index)
  end
  if count ~= maximum then fail('invalid_input', 'members must be a contiguous array') end
  local members, names = {}, {}
  for id in pairs(selected) do members[#members + 1] = id end
  table.sort(members)
  if #members < 2 then fail('invalid_input', 'Choose at least one other participant') end
  local fingerprint = 'thread-create-session-v1/' .. part(title) .. part(session_kind) .. part(session_value)
  for _, id in ipairs(members) do
    fingerprint = fingerprint .. part(id)
    if id ~= agent then names[#names + 1] = known[id] end
  end
  local saved = prior_operation('thread-create/', agent, args.key)
  if saved.found then
    -- A saved operation from before home sessions keeps its original result and placement.
    local expected = fingerprint
    if session_kind == 'default' then
      local prefix, suffix = saved.fingerprint:match('^([^/]+)/(.+)$')
      if prefix == 'thread-create-v1' or prefix == 'thread-create-home-v1' then
        expected = prefix .. '/' .. part(title)
        if prefix == 'thread-create-home-v1' then
          local old = parts(suffix)
          if not old or not old[2] then fail('internal', 'Invalid saved thread operation') end
          expected = expected .. part(old[2])
        end
        for _, id in ipairs(members) do expected = expected .. part(id) end
      end
    end
    local result = operation_result(saved, expected)
    if result.group == false then remember_thread_open(agent, result.id) end
    return result
  end
  local op_key = 'thread-create/' .. part(agent) .. part(args.key)
  -- Encode the complete scoped key. Do not truncate or discard punctuation.
  local id = 'g-' .. op_key:gsub('.', function(c) return string.format('%02x', string.byte(c)) end)
  local direct = #members == 2 and title == ''
  if direct then
    for _, member in ipairs(members) do if member ~= agent then id = member end end
  end
  local name = title ~= '' and title or join(names, ', ')
  local result = {id = id, title = name, members = members, group = not direct}
  if not thread_home(agent, id) then
    local session = resolve_session(session_kind, session_value, source_session, op_key)
    local ha, hb = home_pair(agent, id)
    db.exec('INSERT INTO thread_homes (thread_a, thread_b, home_session, moved, set_rev) VALUES (?, ?, ?, 0, CAST(? AS INTEGER))',
      ha, hb, session, bump())
  end
  if not direct then
    db.exec('INSERT INTO groups (gid, name) VALUES (?, ?)', id, name)
    for pos, member in ipairs(members) do
      db.exec('INSERT INTO group_members (gid, agent, pos, current) VALUES (?, ?, ?, 1)', id, member, pos)
    end
  end
  save_operation(op_key, agent, fingerprint, result)
  if direct then remember_thread_open(agent, id) end
  return result
end

local function selected_members(user, input)
  local values = type(input) == 'table' and type(input.values) == 'table' and input.values or {}
  local selected = {[user] = true}
  for field, enabled in pairs(values) do
    if type(field) == 'string' and field:sub(1, 7) == 'member_' and enabled == true then
      local id = resolve_recipient(field:sub(8))
      if is_group_id(id) then fail('invalid_input', 'Choose participants, not groups') end
      selected[id] = true
    end
  end
  local members = {}
  for id in pairs(selected) do members[#members + 1] = id end
  table.sort(members)
  if #members < 2 then fail('invalid_input', 'Choose at least one other participant') end
  return members, selected
end

-- notice_body sets the body of a membership notice. A title that would make the notice too large
-- for one read page, or its body larger than body_limit, is cut (with "…"). If the notice does not fit with an empty title, the change
-- is refused, and the transaction writes nothing.
local function notice_body(message, title)
  local function body(t) return 'You were added to ' .. t .. '. Read earlier messages with messaging.history.' end
  -- over: the bytes to remove, for the page and for the body limit of every message.
  local function over_by()
    return math.max(page_bytes(message) - reply_budget, encoded_size(message.body) - 2 - body_limit)
  end
  message.body = body(title)
  local over = over_by()
  if over <= 0 then return end
  local cut = title
  while over > 0 and cut ~= '' do
    cut = utf8_cut(cut, #cut - over - 3)
    message.body = body(cut .. '…')
    over = over_by()
  end
  if over > 0 then
    message.body = body('')
    admit(message) -- fails: the IDs alone do not fit one page
  end
end


-- A membership change affects later deliveries only: every message keeps the audience of its send.
-- An added member gets a notice message; a removed member keeps its mail and becomes a past member.
local function change_members(user, peer, input, operation_key, context)
  if peer.observer then fail('refused', 'Send a message to join this group before changing its members') end
  if type(operation_key) ~= 'string' or operation_key == '' then fail('invalid_input', 'An operation key is required') end
  if builtin[peer.id] then fail('refused', 'The team group has dynamic membership') end
  local members = selected_members(user, input)
  if not peer.group then
    -- A direct thread stays intact. An expanded selection creates a separate group.
    return thread_create(user, {members = members, key = 'members/' .. operation_key}, context and context.session_id)
  end
  local fingerprint = 'thread-members-v1/' .. part(peer.id)
  for _, id in ipairs(members) do fingerprint = fingerprint .. part(id) end
  local saved = prior_operation('members/', user, operation_key)
  if saved.found then return operation_result(saved, fingerprint) end
  local op_key = 'members/' .. part(user) .. part(operation_key)
  local result = {id = peer.id, members = members, group = true}
  local g = group(peer.id)
  if not g or not is_member(g, user) then fail('refused', 'Only a member changes this group') end
  local added = {}
  for _, id in ipairs(members) do if not is_member(g, id) then added[#added + 1] = id end end
  db.exec('UPDATE group_members SET current = 0 WHERE gid = ?', peer.id)
  for pos, id in ipairs(members) do
    db.exec([[INSERT INTO group_members (gid, agent, pos, current) VALUES (?, ?, ?, 1)
      ON CONFLICT (gid, agent) DO UPDATE SET pos = excluded.pos, current = 1]], peer.id, id, pos)
  end
  if #added > 0 then
    local message = {id = 'member-notice/' .. op_key, from = user, to = peer.id, reply_expected = false, at = os.date('!%Y-%m-%dT%H:%M:%SZ')}
    notice_body(message, thread_title(user, peer))
    insert_message(message, added)
  end
  save_operation(op_key, user, fingerprint, result)
  return result
end

local function thread_archive(agent, args)
  if type(args.thread) ~= 'string' or args.thread == '' then fail('invalid_input', 'thread is required') end
  if type(args.key) ~= 'string' or args.key == '' then fail('invalid_input', 'key is required') end
  if args.archived ~= nil and type(args.archived) ~= 'boolean' then fail('invalid_input', 'archived must be boolean') end
  thread_peer('/thread/' .. args.thread, agent)
  local archived = args.archived ~= false
  local op_key = 'thread-archive/' .. part(agent) .. part(args.key)
  local fingerprint = 'thread-archive-v1/' .. part(args.thread) .. tostring(archived)
  local saved = prior_operation('thread-archive/', agent, args.key)
  if saved.found then return operation_result(saved, fingerprint) end
  args.thread = thread_peer('/thread/' .. args.thread, agent).id
  local result = {id = args.thread, archived = archived}
  if archived then
    db.exec('INSERT INTO thread_archived (viewer, peer) VALUES (?, ?) ON CONFLICT DO NOTHING', agent, args.thread)
  else
    db.exec('DELETE FROM thread_archived WHERE viewer = ? AND peer = ?', agent, args.thread)
  end
  save_operation(op_key, agent, fingerprint, result)
  return result
end

-- draft returns the user's draft text of a peer and its revision ('0': no draft).
local function draft(user, peer)
  local r = db.first('SELECT text, CAST(rev AS TEXT) AS rev FROM drafts WHERE viewer = ? AND peer = ?', user, peer)
  if not r then return '', '0' end
  return r.text, r.rev
end

-- set_draft writes the draft text of user and peer at a new revision, and returns the revision.
local function set_draft(user, peer, text)
  local rev = bump()
  db.exec([[INSERT INTO drafts (viewer, peer, text, rev) VALUES (?, ?, ?, CAST(? AS INTEGER))
    ON CONFLICT (viewer, peer) DO UPDATE SET text = excluded.text, rev = excluded.rev]], user, peer, text, rev)
  return rev
end

local function render_home(user, context)
  local placement = hub('hub.ui.describe', {plugin = 'messaging'})
  local redirects = placement.home_redirects or {}
  local current, other = {}, {}
  local s = view_state(user)
  for _, peer in ipairs(peers(user, s)) do
    local home = thread_home(user, peer.id, s)
    local session = home and (redirects[home] or home) or placement.default_session_id
    local target = context and session == context.session_id and current or other
    target[#target + 1] = peer
  end
  local ordered = {}
  for _, list in ipairs({current, other}) do
    for _, peer in ipairs(list) do ordered[#ordered + 1] = peer end
  end
  local items, archived_items, observed_items = {}, {}, {}
  for _, a in ipairs(ordered) do
    local n = a.observer and 0 or (s.counts[a.id] or 0)
    local archived = s.archived[a.id]
    local item = {id = a.id, label = thread_title(user, a, s), detail = n > 0 and (n .. ' unread') or 'No unread messages',
      action = archived and {name = 'restore', label = 'Restore', enabled = true, tool = 'messaging.thread_archive'}
        or {name = 'open', label = 'Open', enabled = true, user_only = 'navigation'}}
    if a.observer then item.detail = a.readonly and 'Read-only direct thread' or 'Send a message to join' end
    local target = archived and archived_items or (a.observer and observed_items or items)
    target[#target + 1] = item
  end
  -- New thread: an optional title and a checkbox per participant.
  local fields = {{id = 'title', label = 'Title (optional)', kind = 'text', value = '', required = false}}
  for _, a in ipairs(participants) do
    if a.id ~= user and not a.alias_of then
      fields[#fields + 1] = {id = 'member_' .. a.id, label = display_name(a), kind = 'boolean', value = false, required = false}
    end
  end
  return {title = 'Messages', nodes = {
    {id = 'threads', type = 'list', label = 'Conversations', items = items},
    {id = 'observed_threads', type = 'list', label = 'Agent-only threads', items = observed_items},
    {id = 'archived_threads', type = 'list', label = 'Archived', items = archived_items},
    {id = 'new_thread', type = 'form', label = 'New thread', fields = fields,
      submit_action = {name = 'submit', label = 'Create thread', enabled = true, tool = 'messaging.thread_create'}},
  }}
end
-- Rex limits one control message to 64 KiB (rex-protocol.md), for requests and replies. A view
-- tree and a history page therefore carry a bounded part of a thread. The transcript pane fetches
-- the older pages (view.history) and prints the whole thread.
local page_budget = 40000


-- history_page returns the newest messages older than the message ID before (nil: the newest
-- messages), oldest first, within budget bytes of encoded JSON, and whether older messages exist.
-- Each item is measured exactly (encoded_size): a JSON escape takes up to 6 bytes for 1. The first
-- message always fits. A message larger than a page is cut, with a note, in the tree and in pages
-- alike.
local function history_page(user, peer, before, budget)
  local ta, tb = thread_pair(user, peer.id)
  local cursor
  if before ~= nil then
    local r = db.first('SELECT CAST(seq AS TEXT) AS seq FROM messages WHERE id = ? AND thread_a = ? AND thread_b = ?', before, ta, tb)
    if not r then fail('invalid_input', 'Unknown history cursor') end
    cursor = r.seq
  end
  local names = {}
  for _, a in ipairs(participants) do names[a.id] = display_name(a) end
  local function query(op)
    return 'SELECT ' .. message_columns(page_budget) .. ' FROM messages m WHERE m.thread_a = ? AND m.thread_b = ?'
      .. ' AND m.seq ' .. op .. ' CAST(? AS INTEGER) ORDER BY m.seq DESC LIMIT 8'
  end
  local newest_first, size = {}, 0
  local function older()
    local out = {}
    for n = #newest_first, 1, -1 do out[#out + 1] = newest_first[n] end
    return out
  end
  -- Bounded chunks, newest first. Without a cursor, the first chunk includes the largest
  -- sequence, 9223372036854775807; later chunks start below the oldest row read.
  local op = cursor and '<' or '<='
  cursor = cursor or '9223372036854775807'
  while true do
    local chunk = rows(query(op), ta, tb, cursor)
    op = '<'
    if #chunk == 0 then break end
    for _, r in ipairs(chunk) do
      -- author is display text. own (optional) marks the user's own messages for styling.
      local item = {id = r.id, author = names[r.sender] or r.sender, own = r.sender == user, text = r.body, at = r.at, fyi = r.reply_expected == 0}
      local cut = r.body_bytes > #r.body -- the query read a prefix: the full item is over a page
      local cost = cut and budget + page_budget or encoded_size(item) + 1
      if #newest_first > 0 and size + cost > budget then return older(), true end
      -- Only the first item gets here over the budget: it is cut to the budget (the render passes
      -- what remains after the draft), at most one page.
      local limit = math.min(page_budget, budget)
      if cost > limit then
        local note = '\n\n… (message cut: ' .. math.floor(r.body_bytes / 1024) .. ' KB)'
        -- Each step removes at least the bytes over the limit: one raw byte is 1 to 6 encoded.
        local text = utf8_cut(r.body, limit)
        item.text = text .. note
        cost = encoded_size(item) + 1
        while cost > limit and text ~= '' do
          text = utf8_cut(text, #text - (cost - limit))
          item.text = text .. note
          cost = encoded_size(item) + 1
        end
      end
      newest_first[#newest_first + 1] = item
      size = size + cost
      cursor = r.seq
    end
  end
  return older(), false
end

local function render_thread(user, route)
  local peer = thread_peer(route, user)
  local text, draft_rev = draft(user, peer.id)
  -- The draft shares the tree's control message with the newest messages.
  local messages, has_more = history_page(user, peer, nil, math.max(4000, page_budget - encoded_size(text)))
  local tree = {
    title = thread_title(user, peer),
    back = nil, -- the Rex sidebar lists the threads; no Back control
    nodes = {
      {id = 'thread_menu', type = 'menu', label = 'Thread…', action = {name = 'open', enabled = true, user_only = 'navigation'}},
      -- has_more: older messages exist. The transcript pane fetches them with view.history.
      -- The renderer refuses a page_size below 1, so an empty thread sends 1.
      {id = 'history', type = 'history', messages = messages, has_more = has_more, page_size = math.max(1, #messages)},
      {id = 'composer', type = 'composer', label = 'Message', text = text, draft_revision = draft_rev,
        save_action = {name = 'save', label = 'Save', enabled = true, user_only = 'draft is UI state'},
        send_action = {name = 'send', label = 'Send', enabled = true, tool = 'messaging.send'}},
    },
  }
  if peer.readonly then
    tree.nodes[3] = {id = 'observer_notice', type = 'widget', text = 'This agent-to-agent direct thread is read-only.'}
  elseif peer.observer then
    table.insert(tree.nodes, 3, {id = 'observer_notice', type = 'widget', text = 'Your first message adds you to this group. Earlier messages stay read.'})
  end
  return tree
end

-- Gallery: a live preview of every control, on the route "/gallery". It runs through the real
-- renderer and hub, so hover, click, wheel and typing behave as in production. Its state lives
-- in the gallery table (state, history, draft) and never touches messages or threads.
local gallery_route = '/gallery'

local function gallery_state()
  local r = {}
  for _, row in ipairs(rows('SELECT key, value, CAST(rev AS TEXT) AS rev FROM gallery')) do r[row.key] = row end
  local function value(key) return r[key] and rex.json.decode(r[key].value) or {} end
  local draft = value('draft')
  return value('state'), value('history').messages or {}, type(draft.text) == 'string' and draft.text or '', r.draft and r.draft.rev or '0'
end

local function gallery_put(key, value)
  db.exec([[INSERT INTO gallery (key, value, rev) VALUES (?, ?, CAST(? AS INTEGER))
    ON CONFLICT (key) DO UPDATE SET value = excluded.value, rev = excluded.rev]], key, json(value), bump())
end
local gallery_samples = {
  {id = 'g1', author = 'Claude', text = 'A short message.', at = '2026-10-16T21:00:00Z'},
  {id = 'g2', author = 'Codex', text = 'A longer message that wraps across several lines, so you can check line breaks, bubble padding and the reading width on a wide pane. It has **bold**, *italic* and `inline code`.', at = '2026-10-16T21:01:00Z'},
  {id = 'g3', author = 'Codex', text = 'A second message from the same author within two minutes, which groups under one header.', at = '2026-10-16T21:02:00Z'},
  {id = 'g4', author = 'User', own = true, text = 'One of your own messages, aligned right.', at = '2026-10-16T21:05:00Z'},
  {id = 'g5', author = 'Claude', text = 'A list and a code block:\n\n- first item\n- second item\n\n```go\nfunc main() {\n\tfmt.Println("hello")\n}\n```', at = '2026-10-16T21:10:00Z'},
}

local function render_gallery()
  local state, history, text, draft_rev = gallery_state()
  local messages = {}
  for _, m in ipairs(gallery_samples) do messages[#messages + 1] = m end
  -- The history node holds at most page_size messages: the samples plus the newest saved sends.
  for i = math.max(1, #history - (page_size - #gallery_samples) + 1), #history do messages[#messages + 1] = history[i] end
  return {
    title = 'Gallery', back = nil,
    nodes = {
      {id = 'intro', type = 'widget', text = 'Live control gallery. Every control here runs the real renderer: hover, click, scroll and type. Nothing here changes your threads.',
        action = {name = 'open', label = 'Reset gallery', enabled = true, user_only = 'sample view'}},
      {id = 'last', type = 'widget', text = 'Last action: ' .. (state.last or 'none yet')},
      {id = 'sample_list', type = 'list', label = 'List', items = {
        {id = 'a', label = 'Design review', detail = '2 unread messages', action = {name = 'open', label = 'Open', enabled = true, user_only = 'sample view'}},
        {id = 'b', label = 'Release notes', detail = 'No unread messages', action = {name = 'open', label = 'Open', enabled = true, user_only = 'sample view'}},
        {id = 'c', label = 'Archived thread', detail = 'Disabled item', action = {name = 'open', label = 'Open', enabled = false, user_only = 'sample view'}},
      }},
      {id = 'sample_form', type = 'form', label = 'Form', fields = {
        {id = 'name', label = 'Text field', kind = 'text', value = '', required = false},
        {id = 'notes', label = 'Multiline field', kind = 'multiline', value = '', required = false},
        {id = 'opt_a', label = 'Checkbox, off', kind = 'boolean', value = false, required = false},
        {id = 'opt_b', label = 'Checkbox, on', kind = 'boolean', value = true, required = false},
        {id = 'size', label = 'Select', kind = 'select', value = 'medium', required = false, options = {
          {value = 'small', label = 'Small'}, {value = 'medium', label = 'Medium'}, {value = 'large', label = 'Large'}}},
      }, submit_action = {name = 'submit', label = 'Apply', enabled = true, user_only = 'sample view'}},
      {id = 'history', type = 'history', messages = messages, has_more = false, page_size = page_size,
        load_action = {name = 'load', label = 'Older messages', enabled = false}},
      {id = 'composer', type = 'composer', label = 'Message', text = text, draft_revision = draft_rev,
        save_action = {name = 'save', label = 'Save', enabled = true, user_only = 'sample view'},
        send_action = {name = 'send', label = 'Send', enabled = true, user_only = 'sample view'}},
    },
  }
end


local function gallery_action(args)
  local input = type(args.input) == 'table' and args.input or {}
  if args.node_id == 'intro' then
    gallery_put('history', {messages = {}})
    gallery_put('state', {})
    return {}
  end
  if args.node_id == 'sample_list' then gallery_put('state', {last = 'opened list item ' .. tostring(input.item_id)}); return {} end
  if args.node_id == 'sample_form' then
    local parts = {}
    for k, v in pairs(type(input.values) == 'table' and input.values or {}) do parts[#parts + 1] = k .. '=' .. tostring(v) end
    table.sort(parts)
    gallery_put('state', {last = 'submitted form: ' .. join(parts, ', ')})
    return {}
  end
  fail('invalid_input', 'Unknown gallery action')
end

local function gallery_draft_save(args)
  local key = 'gallery-draft/' .. part(args.operation_key)
  local saved = saved_operation({key})
  if saved.found then return saved.result end
  local _, _, _, draft_rev = gallery_state()
  if draft_rev ~= args.base_revision then fail('draft_conflict', 'The draft changed in another view') end
  gallery_put('draft', {text = args.text})
  local _, _, _, rev = gallery_state()
  local result = {draft_revision = rev, text = args.text}
  save_operation(key, 'user', 'g/' .. part(args.base_revision) .. part(args.text), result)
  return result
end

local function gallery_send(args)
  local key = 'gallery-send/' .. part(args.operation_key)
  local saved = saved_operation({key})
  if saved.found then return saved.result end
  local _, history, text, draft_rev = gallery_state()
  if draft_rev ~= args.draft_revision or text ~= args.text then fail('draft_conflict', 'The saved draft differs from the text to send') end
  history[#history + 1] = {id = key, author = 'User', own = true, text = args.text, at = os.date('!%Y-%m-%dT%H:%M:%SZ')}
  -- The history node holds at most page_size messages, samples included. Drop the oldest sends.
  while #history > page_size - #gallery_samples do table.remove(history, 1) end
  gallery_put('history', {messages = history})
  gallery_put('draft', {text = ''})
  local _, _, _, rev = gallery_state()
  local result = {message_id = key, cleared_draft_revision = args.draft_revision, draft_revision = rev}
  save_operation(key, 'user', 'gs/' .. part(args.draft_revision) .. part(args.text), result)
  return result
end
local function form_context(args)
  local context = args.context
  if type(context) ~= 'table' or type(context.session_id) ~= 'string' or context.session_id == '' then
    fail('invalid_input', 'The form has no source session')
  end
  return context
end

local function form_peer(args)
  local context = form_context(args)
  if type(context.source_view_id) ~= 'string' or context.source_view_id == '' then
    fail('invalid_input', 'The form has no source thread')
  end
  return thread_peer(context.source_route, args.user)
end

local function cancel_node(label)
  return {id = 'cancel', type = 'widget', text = '', action = {name = '$cancel', label = label or 'Cancel', enabled = true}}
end

-- thread_agents returns the agent IDs in a thread, without the user.
local function thread_agents(user, peer)
  local ids = observed_direct_parts(peer.id)
  if not ids then
    local g = group(peer.id)
    ids = g and g.members or {peer.id}
  end
  local out, seen = {}, {[user] = true}
  for _, id in ipairs(ids) do
    id = canonical(id)
    if not seen[id] then seen[id] = true; out[#out + 1] = id end
  end
  return out
end

-- agent_items lists a thread's agents. A row with an open tab opens that tab.
local function agent_items(user, peer)
  local known = {}
  for _, a in ipairs(participants) do known[a.id] = a end
  local items = {}
  for _, id in ipairs(thread_agents(user, peer)) do
    local a = known[id] or {id = id}
    local open = a.joined == true
    local activity = open and type(a.activity) == 'string' and a.activity ~= '' and a.activity or nil
    items[#items + 1] = {id = id, label = display_name(a),
      icon = not open and '◌' or (activity == 'working' and '●' or '○'),
      status = open and activity or 'no tab',
      action = {name = 'agent', label = 'Open tab', enabled = open, user_only = 'navigation'}}
  end
  return items
end

local function participant_fields(user, session, selected)
  local fields = {{id = 'other_sessions', label = 'Show agents in other sessions', kind = 'boolean', value = false}}
  local seen = {[user] = true}
  for _, a in ipairs(participants) do
    if a.id ~= user and not a.alias_of and (a.state ~= 'superseded' or selected[a.id]) then
      seen[a.id] = true
      local field = {id = 'member_' .. a.id, label = display_name(a), kind = 'boolean', value = selected[a.id] == true}
      if a.session_id ~= session and not selected[a.id] then field.visible_when = {field = 'other_sessions', value = true} end
      fields[#fields + 1] = field
    end
  end
  for id in pairs(selected) do
    if not seen[id] then fields[#fields + 1] = {id = 'member_' .. id, label = display_name({id = id}), kind = 'boolean', value = true} end
  end
  return fields
end

local function session_fields(default_session)
  local options, selected = {}, nil
  for _, session in ipairs(hub('hub.session.list').sessions or {}) do
    options[#options + 1] = {value = session.session_id, label = (session.label or '') ~= '' and session.label or session.session_id}
    if session.session_id == default_session then selected = default_session end
  end
  options[#options + 1] = {value = '@new', label = 'New session…'}
  return {
    {id = 'session_id', label = 'Session', kind = 'select', required = true, value = selected or '@new', options = options},
    {id = 'session_name', label = 'New session name (only for New session…)', kind = 'text', value = ''},
  }
end

local function chosen_session(values)
  if values.session_id == '@new' then
    if type(values.session_name) ~= 'string' or values.session_name == '' then fail('invalid_input', 'Enter a new session name') end
    return {new_session = values.session_name}
  end
  return {session_id = values.session_id}
end


-- move_thread sets the home session of a thread. intent is {session_id} or {new_session} (or
-- empty: the source session). The form submit and messaging.thread_move both call it.
local function move_thread(user, peer, intent, operation_key, source_session)
  if type(operation_key) ~= 'string' or operation_key == '' then fail('invalid_input', 'An operation key is required') end
  local kind, value = session_intent(intent)
  local fingerprint = 'thread-move-v1/' .. part(peer.id) .. part(kind) .. part(value)
  local saved = prior_operation('thread-move/', user, operation_key)
  if saved.found then return operation_result(saved, fingerprint) end
  local op_key = 'thread-move/' .. part(user) .. part(operation_key)
  local session = resolve_session(kind, value, source_session, op_key)
  local result = {navigate = 'thread/' .. peer.id}
  local ha, hb = home_pair(user, peer.id)
  -- moved: an explicit choice, which a later identity merge keeps (merge_alias).
  db.exec([[INSERT INTO thread_homes (thread_a, thread_b, home_session, moved, set_rev) VALUES (?, ?, ?, 1, CAST(? AS INTEGER))
    ON CONFLICT (thread_a, thread_b) DO UPDATE SET home_session = excluded.home_session, moved = 1, set_rev = excluded.set_rev]],
    ha, hb, session, bump())
  save_operation(op_key, user, fingerprint, result)
  return result
end
local function render_form(args)
  local context = form_context(args)
  if args.route == '/forms/thread-menu' then
    -- The thread overview: who is in the thread, then what the user can do with it.
    local peer = form_peer(args)
    local ta, tb = thread_pair(args.user, peer.id)
    local count = db.first('SELECT count(*) AS n FROM messages WHERE thread_a = ? AND thread_b = ?', ta, tb).n
    local agents = agent_items(args.user, peer)
    local summary = (#agents == 1 and '1 agent' or #agents .. ' agents') .. ' · ' .. count .. (count == 1 and ' message' or ' messages')
    local actions = {
      {id = 'rename', label = 'Rename…', icon = '✎', action = {name = 'rename', enabled = true, user_only = 'navigation'}},
      {id = 'move', label = 'Move to session…', icon = '⇄', action = {name = 'move', enabled = true, user_only = 'navigation'}},
      {id = 'archive', label = 'Archive', icon = '▤', action = {name = 'archive', enabled = true, tool = 'messaging.thread_archive'}},
    }
    -- The team and observed threads have no member list to change, so they show no Members… row.
    if not peer.observer and builtin[peer.id] == nil then
      table.insert(actions, 2, {id = 'members', label = 'Members…', icon = '+', action = {name = 'members', enabled = true, user_only = 'navigation'}})
    end
    local nodes = {{id = 'summary', type = 'widget', text = summary}}
    if #agents > 0 then nodes[#nodes + 1] = {id = 'agents', type = 'list', label = 'Agents', items = agents} end
    nodes[#nodes + 1] = {id = 'thread_menu', type = 'list', label = 'Thread', items = actions}
    nodes[#nodes + 1] = cancel_node('Close')
    return {title = thread_title(args.user, peer), menu = true, nodes = nodes}
  end
  if args.route == '/forms/new-thread' then
    local fields = session_fields(context.session_id)
    fields[#fields + 1] = {id = 'title', label = 'Title (optional)', kind = 'text', value = ''}
    for _, field in ipairs(participant_fields(args.user, context.session_id, {})) do fields[#fields + 1] = field end
    return {title = 'New thread', nodes = {
      {id = 'new_thread', type = 'form', fields = fields, submit_action = {name = 'submit', label = 'Create thread', enabled = true, tool = 'messaging.thread_create'}},
      cancel_node(),
    }}
  end
  local peer = form_peer(args)
  if args.route == '/forms/thread-move' then
    return {title = 'Move to session', menu = true, nodes = {
      {id = 'move_thread', type = 'form', fields = session_fields(context.session_id), submit_action = {name = 'submit', label = 'Move thread', enabled = true, tool = 'messaging.thread_move'}},
      cancel_node(),
    }}
  end
  if args.route == '/forms/thread-rename' then
    return {title = 'Rename thread', menu = true, nodes = {
      {id = 'rename_thread', type = 'form', fields = {{id = 'title', label = 'Title', kind = 'text', value = thread_title(args.user, peer), required = true}},
        submit_action = {name = 'submit', label = 'Save title', enabled = true, tool = 'messaging.thread_rename'}},
      cancel_node(),
    }}
  end
  if args.route == '/forms/thread-members' then
    if builtin[peer.id] then fail('refused', 'The team group has dynamic membership') end
    local selected = {[args.user] = true}
    if peer.group then for _, id in ipairs(group(peer.id).members) do selected[id] = true end
    else selected[peer.id] = true end
    return {title = 'Thread members', menu = true, nodes = {
      {id = 'thread_members', type = 'form', fields = participant_fields(args.user, context.session_id, selected),
        submit_action = {name = 'submit', label = 'Save members', enabled = true, tool = 'messaging.thread_members'}},
      {id = 'membership_help', type = 'widget', text = 'New members can read full history in pages. Old messages do not become unread. Adding members to a direct thread creates a new group.'},
      cancel_node(),
    }}
  end
  fail('invalid_input', 'Unknown form route')
end

local function form_view(args)
  local tree = render_form(args)
  tree.status = {state = 'blocked', kind = 'question', msg = 'Waiting for input'}
  return tree
end


-- The gallery shows sample messages. A new user can read them as real data, so its tab and its
-- view exist only when the plugin arg gallery is true (hub config plugins[].args).
local gallery_tab = app.args.gallery == true

-- tab_list returns the conversation tabs and, if gallery_tab, the gallery.
local function tab_list(user)
  local s = view_state(user)
  local function title(name, n) return n > 0 and (name .. ' (' .. n .. ')') or name end
  local tabs = {}
  for _, a in ipairs(peers(user, s)) do
    if not s.archived[a.id] then
      local last = last_message(user, a.id, s)
      if (not a.observer and (a.group or last)) or opened_thread(user, a.id, s) then
        -- A thread with a composer opens as a transcript pane over the composer when the hub enables
        -- it (spikes/04-scrollback). A read-only direct thread has no composer: it keeps one view.
        local n = a.observer and 0 or (s.counts[a.id] or 0)
        tabs[#tabs + 1] = {key = 'thread/' .. a.id, title = title(thread_title(user, a, s), n), route = '/thread/' .. a.id,
          session_id = thread_home(user, a.id, s), revision = a.observer and '' or (last or ''),
          status = not a.observer and unread_status(n) or nil, layout = not a.readonly and 'transcript' or nil}
      end
    end
  end
  if gallery_tab then tabs[#tabs + 1] = {key = 'gallery', title = 'Gallery', route = gallery_route} end
  return tabs
end

-- declare_tabs declares the tabs from committed state: it reads in its own transaction, after the
-- writes of the call have committed, and calls the hub outside it.
local function declare_tabs(user)
  hub('hub.ui.tabs', {tabs = db.transaction(tab_list, user)})
end

-- A tab rename changes this user's thread title. It does not rename the participant.
local function view_rename(args)
  local peer = thread_peer(args.route, args.user)
  if type(args.title) ~= 'string' then fail('invalid_input', 'title must be text') end
  local title = args.title:match('^%s*(.-)%s*$')
  if title == '' then fail('invalid_input', 'A thread title must not be empty') end
  local op_key, fingerprint
  if args.operation_key ~= nil then
    if type(args.operation_key) ~= 'string' or args.operation_key == '' then fail('invalid_input', 'An operation key is required') end
    fingerprint = 'thread-rename-v1/' .. part(peer.id) .. part(title)
    local saved = prior_operation('rename/', args.user, args.operation_key)
    if saved.found then return operation_result(saved, fingerprint) end
    op_key = 'rename/' .. part(args.user) .. part(args.operation_key)
  elseif db.first('SELECT 1 AS x FROM thread_titles WHERE viewer = ? AND peer = ? AND title = ?', args.user, peer.id, title) then
    return {title = title}
  end
  db.exec([[INSERT INTO thread_titles (viewer, peer, title, set_rev) VALUES (?, ?, ?, CAST(? AS INTEGER))
    ON CONFLICT (viewer, peer) DO UPDATE SET title = excluded.title, set_rev = excluded.set_rev]], args.user, peer.id, title, bump())
  if op_key then save_operation(op_key, args.user, fingerprint, {title = title}) end
  return {title = title}
end
-- Agent actions of the thread menu forms (agent parity). Each calls the handler of its form
-- submit, with the same rules: the caller must see the thread; only a member changes a group's
-- members; the team group's members are fixed.
local function thread_arg(agent, args)
  if type(args.thread) ~= 'string' or args.thread == '' then fail('invalid_input', 'thread is required') end
  if type(args.key) ~= 'string' or args.key == '' then fail('invalid_input', 'key is required') end
  return thread_peer('/thread/' .. args.thread, agent)
end

local function thread_rename(agent, args)
  local peer = thread_arg(agent, args)
  return view_rename({user = agent, route = '/thread/' .. peer.id, title = args.title, operation_key = args.key})
end

local function thread_members(agent, args, source_session)
  local peer = thread_arg(agent, args)
  if type(args.members) ~= 'table' then fail('invalid_input', 'members must be an array') end
  local values = {}
  for _, id in ipairs(args.members) do
    if type(id) ~= 'string' or id == '' then fail('invalid_input', 'members must be agent IDs') end
    values['member_' .. id] = true
  end
  return change_members(agent, peer, {values = values}, args.key, {session_id = source_session})
end

local function thread_move(agent, args, source_session)
  local peer = thread_arg(agent, args)
  move_thread(agent, peer, {session_id = args.session_id, new_session = args.new_session}, args.key, source_session)
  return {id = peer.id, moved = true}
end

-- The UI uses the same creation operation as agent tools.
local function create_thread(user, input, operation_key, context)
  local values = type(input) == 'table' and type(input.values) == 'table' and input.values or {}
  local members = {}
  for _, a in ipairs(participants) do
    if a.id ~= user and values['member_' .. a.id] == true then members[#members + 1] = a.id end
  end
  local request = chosen_session(values)
  request.members, request.title, request.key = members, values.title, operation_key
  local result = thread_create(user, request, context and context.session_id)
  thread_archive(user, {thread = result.id, archived = false, key = 'create-restore/' .. operation_key})
  return {navigate = 'thread/' .. result.id}
end

-- Navigation results: the hub opens and shows the named tab.
local function view_action(args)
  if args.route == '/forms/new-thread' then
    form_context(args)
    if args.node_id ~= 'new_thread' or args.action ~= 'submit' then fail('invalid_input', 'Unknown form action') end
    return create_thread(args.user, args.input, args.operation_key, args.context)
  end
  if args.route == '/forms/thread-move' then
    local peer = form_peer(args)
    if args.node_id ~= 'move_thread' or args.action ~= 'submit' then fail('invalid_input', 'Unknown form action') end
    local values = type(args.input) == 'table' and type(args.input.values) == 'table' and args.input.values or {}
    return move_thread(args.user, peer, chosen_session(values), args.operation_key, args.context and args.context.session_id)
  end
  if args.route == '/forms/thread-members' then
    local peer = form_peer(args)
    if args.node_id ~= 'thread_members' or args.action ~= 'submit' then fail('invalid_input', 'Unknown form action') end
    local result = change_members(args.user, peer, args.input, args.operation_key, args.context)
    if result.id ~= peer.id then return {navigate = 'thread/' .. result.id} end
    return {close_form = true}
  end
  if args.route == '/forms/thread-rename' then
    local peer = form_peer(args)
    if args.node_id ~= 'rename_thread' or args.action ~= 'submit' then fail('invalid_input', 'Unknown form action') end
    local values = type(args.input) == 'table' and args.input.values or {}
    view_rename({user = args.user, route = '/thread/' .. peer.id, title = values.title, operation_key = args.operation_key})
    return {close_form = true}
  end
  if args.node_id == 'agents' and args.route == '/forms/thread-menu' and args.action == 'agent' then
    local peer = form_peer(args)
    local id = type(args.input) == 'table' and args.input.item_id
    local member = false
    for _, a in ipairs(thread_agents(args.user, peer)) do member = member or a == id end
    if not member then fail('invalid_input', 'The agent is not in this thread') end
    hub('hub.navigate.agent', {agent = id})
    return {close_form = true}
  end
  if args.node_id == 'thread_menu' then
    if args.route:sub(1, 8) == '/thread/' and args.action == 'open' then
      thread_peer(args.route, args.user)
      return {form = '/forms/thread-menu'}
    end
    if args.route ~= '/forms/thread-menu' then fail('invalid_input', 'Unknown thread menu route') end
    local peer = form_peer(args)
    if args.action == 'move' then return {form = '/forms/thread-move'} end
    if args.action == 'rename' then return {form = '/forms/thread-rename'} end
    if args.action == 'members' and not peer.observer and not builtin[peer.id] then return {form = '/forms/thread-members'} end
    if args.action == 'archive' then
      thread_archive(args.user, {thread = peer.id, key = args.operation_key})
      return {panel = {command = 'threads'}}
    end
    fail('invalid_input', 'Unknown thread menu action')
  end
  if args.node_id == '$back' then return {panel = {command = 'threads'}} end
  if (args.node_id == 'threads' or args.node_id == 'observed_threads') and args.action == 'open' then
    local peer = type(args.input) == 'table' and args.input.item_id
    local target = thread_peer('/thread/' .. tostring(peer), args.user)
    remember_thread_open(args.user, target.id)
    return {navigate = 'thread/' .. target.id}
  end
  if args.node_id == 'archived_threads' and args.action == 'restore' then
    local peer = type(args.input) == 'table' and args.input.item_id
    thread_archive(args.user, {thread = peer, archived = false, key = args.operation_key})
    remember_thread_open(args.user, peer)
    return {navigate = 'thread/' .. peer}
  end
  if args.node_id == 'new_thread' and args.action == 'submit' then
    return create_thread(args.user, args.input, args.operation_key, args.context)
  end
  fail('invalid_input', 'Unknown action ' .. tostring(args.action) .. ' on ' .. tostring(args.node_id))
end


-- view_seen: the user looks at this thread. Acknowledge the user's unread messages in it.
local function view_seen(args)
  local peer = thread_peer(args.route, args.user)
  if peer.observer then return {acked = 0} end
  local update = 'UPDATE deliveries SET acked = 1 WHERE agent = ? AND acked = 0 AND seq IN (SELECT seq FROM messages WHERE '
  local r
  if peer.group then r = db.exec(update .. 'recipient = ?)', args.user, peer.id)
  else r = db.exec(update .. 'recipient = ? AND sender = ?)', args.user, args.user, peer.id) end
  if r.changes > 0 then notify(args.user) end
  return {acked = r.changes}
end

local function view_draft_save(args)
  local peer = thread_peer(args.route, args.user)
  if peer.readonly then fail('refused', 'This direct thread is read-only') end
  if type(args.text) ~= 'string' or type(args.base_revision) ~= 'string' then fail('invalid_input', 'text and base_revision are required') end
  local op_key = 'draft/' .. part(args.user) .. part(args.operation_key)
  local fingerprint = 'draft-v1/' .. part(args.route) .. part(args.base_revision) .. part(args.text)
  local saved = saved_operation({op_key})
  if saved.found then
    if saved.fingerprint ~= fingerprint then fail('operation_conflict', 'Save key already has different content') end
    return saved.result
  end
  local _, rev = draft(args.user, peer.id)
  if rev ~= args.base_revision then fail('draft_conflict', 'The draft changed in another view') end
  -- The saved result holds the committed draft revision, so a replay after a lost reply returns
  -- exactly what the first execution produced.
  local result = {draft_revision = set_draft(args.user, peer.id, args.text), text = args.text}
  save_operation(op_key, args.user, fingerprint, result)
  return result
end

-- A user joins an observed group in the same transaction as the first message. Earlier mail keeps
-- its audience and never becomes the user's unread mail.
local function ui_recipients(user, peer)
  local g = group(peer.id)
  if user ~= 'user' or not g or builtin[peer.id] then return recipients(user, peer.id) end
  if not is_member(g, user) then
    db.exec([[INSERT INTO group_members (gid, agent, pos, current)
      VALUES (?, ?, (SELECT coalesce(max(pos), 0) + 1 FROM group_members WHERE gid = ?), 1)
      ON CONFLICT (gid, agent) DO UPDATE SET pos = excluded.pos, current = 1]], peer.id, user, peer.id)
    g.members[#g.members + 1] = user
  end
  local targets = {}
  for _, id in ipairs(g.members) do if id ~= user then targets[#targets + 1] = id end end
  return targets
end

local function view_send(args)
  local peer = thread_peer(args.route, args.user)
  if peer.readonly then fail('refused', 'This direct thread is read-only') end
  if type(args.text) ~= 'string' or args.text == '' or type(args.draft_revision) ~= 'string' then
    fail('invalid_input', 'text and draft_revision are required')
  end
  local user = args.user
  local id = 'send/' .. part(user) .. part(args.operation_key)
  local fingerprint = 'view-send-v1/' .. part(args.route) .. part(args.draft_revision) .. part(args.text)
  local saved = saved_operation({id})
  if saved.found then
    if normalized_fingerprint(saved.fingerprint) ~= normalized_fingerprint(fingerprint) then fail('operation_conflict', 'Send key already has different content') end
    return saved.result -- includes the draft revision that the send transaction produced
  end
  local message = {id = id, from = user, to = peer.id, body = args.text, at = os.date('!%Y-%m-%dT%H:%M:%SZ')}
  admit(message)
  local text, rev = draft(user, peer.id)
  if rev ~= args.draft_revision or text ~= args.text then fail('draft_conflict', 'The saved draft differs from the text to send') end
  insert_message(message, ui_recipients(user, peer))
  local result = {message_id = id, cleared_draft_revision = args.draft_revision, draft_revision = set_draft(user, peer.id, '')}
  save_operation(id, user, fingerprint, result)
  return result
end
-- Agent actions. fn(agent, args, source session) runs the action; declares: it can change a thread.
local actions = {
  {name = 'messaging.send', fn = send, declares = true, title = 'Send a message',
    description = 'Send a message to an agent, to "user" (the human), or to the group "team" (everyone else). Choose a key before sending. After an unknown outcome, retry the same key and content. Set reply_to to acknowledge the message you answer. Set reply_expected=false for an informational message. Use ack for routine receipts. Limits: body at most 16384 bytes encoded as JSON, key at most 200 bytes, reply_to at most 512 bytes, and the whole message must fit one read page (48 KB).',
    args = {type = 'object', properties = {
      to = {type = 'string', minLength = 1}, body = {type = 'string', minLength = 1}, key = {type = 'string', minLength = 1},
      reply_to = {type = 'string', minLength = 1}, reply_expected = {type = 'boolean'}
    }, required = {'to', 'body', 'key'}, additionalProperties = false}},
  {name = 'messaging.read', fn = read, title = 'Read messages',
    description = 'Read your unacknowledged messages. Reading does not acknowledge them. Optional thread filters by recipient/group ID. Pass next_cursor as since to get later arrivals; keep a cursor per filter. Omit since for recovery. A reply holds at most 48 KB: if more is true, call again with since = next_cursor. An older message larger than one reply arrives with a prefix of its body, truncated = true and body_bytes (the full body size). If even its other fields do not fit, it arrives as {cursor, id, metadata_too_large = true, bytes}; if its ID does not fit either, id_prefix and id_bytes replace id, and that message cannot be acknowledged. An empty list can appear as {}.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, since = {type = 'string', pattern = '^(0|[1-9][0-9]*)$'}}, additionalProperties = false}},
  {name = 'messaging.ack', fn = ack, declares = true, title = 'Acknowledge messages',
    description = 'Acknowledge handled messages without sending a receipt reply. Safe to retry. An empty list changes nothing.',
    args = {type = 'object', properties = {ids = {type = 'array', items = {type = 'string', minLength = 1}}},
      required = {'ids'}, additionalProperties = false}},
  {name = 'messaging.thread_list', fn = thread_list, title = 'List threads',
    description = 'List your direct and group threads with unread counts. Set include_archived=true to include archived threads.',
    args = {type = 'object', properties = {include_archived = {type = 'boolean'}}, additionalProperties = false}},
  {name = 'messaging.thread_create', fn = thread_create, declares = true, title = 'Create a thread',
    description = 'Create a thread with yourself and selected roster members. The home defaults to your current session. Set session_id for an open session or new_session for a new name. An existing direct thread keeps its home. Retry with the same key and content.',
    args = {type = 'object', properties = {members = {type = 'array', items = {type = 'string', minLength = 1}}, title = {type = 'string'}, session_id = {type = 'string', minLength = 1}, new_session = {type = 'string', minLength = 1}, key = {type = 'string', minLength = 1}},
      required = {'members', 'key'}, additionalProperties = false}},
  {name = 'messaging.history', fn = history, title = 'Read thread history',
    description = 'Read a page of thread history, newest messages first. Current group members can read all history. This does not acknowledge or backfill unread mail. Default 20 messages, maximum 50. A page holds at most 48 KB, so it can hold fewer messages; next_before is set when older messages exist. An older message larger than one page arrives as in messaging.read: a body prefix with truncated = true and body_bytes, or a metadata_too_large marker. A thread whose ID is too long for one page fails with thread_id_too_large. Pass next_before as before only when you need older context.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, before = {type = 'string', pattern = '^[1-9][0-9]*$'}, limit = {type = 'integer', minimum = 1, maximum = 50}},
      required = {'thread'}, additionalProperties = false}},
  {name = 'messaging.thread_archive', fn = thread_archive, declares = true, title = 'Archive or restore a thread',
    description = 'Archive a thread for yourself without deleting history or drafts or changing delivery. Set archived=false to restore. Choose a key and retry with the same content after an unknown outcome.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, archived = {type = 'boolean'}, key = {type = 'string', minLength = 1}},
      required = {'thread', 'key'}, additionalProperties = false}},
  {name = 'messaging.thread_rename', fn = thread_rename, declares = true, title = 'Rename a thread',
    description = 'Set your title of a thread. Other participants keep their own titles. Choose a key and retry with the same content after an unknown outcome.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, title = {type = 'string', minLength = 1}, key = {type = 'string', minLength = 1}},
      required = {'thread', 'title', 'key'}, additionalProperties = false}},
  {name = 'messaging.thread_members', fn = thread_members, declares = true, title = 'Change thread members',
    description = 'Set the members of a group thread that you are in (you stay a member). New members can read full history; old messages do not become unread for them. For a direct thread, a larger selection creates a new group and returns its id. The team group cannot change. Choose a key and retry with the same content after an unknown outcome.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, members = {type = 'array', items = {type = 'string', minLength = 1}}, key = {type = 'string', minLength = 1}},
      required = {'thread', 'members', 'key'}, additionalProperties = false}},
  {name = 'messaging.thread_move', fn = thread_move, declares = true, title = 'Move a thread to a session',
    description = 'Set the Rex session where the thread opens for you. Set session_id for an open session or new_session for a new name; with neither, your current session. Choose a key and retry with the same content after an unknown outcome.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, session_id = {type = 'string', minLength = 1}, new_session = {type = 'string', minLength = 1}, key = {type = 'string', minLength = 1}},
      required = {'thread', 'key'}, additionalProperties = false}}
}

-- Each action and view handler runs its writes in one SQL transaction (db.transaction; the SDK
-- frame has tx = false). store = false: Messaging keeps its own operations table
-- (saved_operation). A call first reads the roster and applies new aliases. At its end it gives
-- the notices of its writes, in the same commit. A call that can change a thread then declares the
-- tabs, after the commit: a rolled-back call declares nothing. A failed declaration does not fail
-- the committed call: it is logged, and the next change declares the tabs again.
local ui_user = 'user'
local plain = {store = false, tx = false}
-- imported is true once SQL holds Messaging's data (import.lua). Before, every call is refused.
local imported = {done = false, error = nil}

-- The refresh applies new aliases and declares the tabs, in a timer after the call that asks for
-- it: an agents change (hub.changed) or a render that sees an alias not yet applied. The schedule
-- state is a table field, not a captured local (the pcall rule, LazyRex docs/rex-protocol.md).
local refresh_schedule = {pending = false}
local refresh_delay = 0.25
local function schedule_refresh()
  if refresh_schedule.pending then return end
  refresh_schedule.pending = true
  app.after(refresh_delay, function()
    refresh_schedule.pending = false
    if not imported.done then return end
    refresh_participants()
    migrate_aliases()
    declare_tabs(ui_user)
  end, {tx = false})
end

-- A render reads only (the SDK refuses a write in a render). It shows the rows as they are: an
-- alias that the rows do not show yet is a plain agent in this render (the roster entry without
-- alias_of, and no alias). The render schedules the refresh, which merges the rows and declares
-- the tabs again.
local function render_aliases()
  local names = {}
  for id in pairs(aliases) do names[#names + 1] = id end
  if #names == 0 then return end
  local applied = {}
  for _, r in ipairs(rows('SELECT alias FROM aliases_applied WHERE alias IN (SELECT value FROM json_each(?))', json(names))) do
    applied[r.alias] = true
  end
  for _, id in ipairs(names) do
    if not applied[id] then aliases[id] = nil; pending.names[id] = true end
  end
  if next(pending.names) == nil then return end
  local list = {}
  for i, a in ipairs(participants) do
    if pending.names[a.id] then
      local copy = {}
      for k, v in pairs(a) do copy[k] = v end
      copy.alias_of = nil
      a = copy
    end
    list[i] = a
  end
  participants = list
  schedule_refresh()
end

local function handler(fn, declares, render)
  return function(ctx, args)
    if not imported.done then
      fail('unavailable', 'Messaging is importing its data' .. (imported.error and (': ' .. imported.error) or ''))
    end
    if render then
      refresh_participants()
      render_aliases()
      return fn(ctx, args)
    end
    local result = db.transaction(function()
      notes.marked, notes.list, notes.inside = {}, {}, true
      local ok, out = pcall(function()
        refresh_participants()
        migrate_aliases()
        local r = fn(ctx, args)
        flush()
        return r
      end)
      notes.inside = false
      if not ok then error(out, 0) end
      return out
    end)
    if declares then
      local ok, err = pcall(declare_tabs, ui_user)
      if not ok then print('messaging: the tab declaration failed: ' .. tostring(type(err) == 'table' and err.message or err)) end
    end
    return result
  end
end

-- Agent actions. The SDK identifies the agent and gives its session and its key in ctx.
for _, a in ipairs(actions) do
  local fn = a.fn
  app.action(a.name, a.args, handler(function(ctx, args)
    args.key = ctx.key
    return fn(ctx.agent, args, ctx.session_id)
  end, a.declares), {title = a.title, description = a.description, store = false, tx = false})
end

-- Views: only the hub calls them, for the user.
local function view(fn, declares) return handler(function(_, args) return fn(args) end, declares) end
local function render(fn) return handler(function(_, args) return fn(args) end, false, true) end
app.view('/thread/*', {
  render = render(function(args) return render_thread(args.user, args.route) end),
  ['view.open'] = view(function(args)
    local peer = thread_peer(args.route, args.user)
    remember_thread_open(args.user, peer.id)
    return {}
  end, true),
  -- A page of messages older than args.before, for the transcript pane.
  ['view.history'] = view(function(args)
    if type(args.before) ~= 'string' or args.before == '' then fail('invalid_input', 'before is required') end
    local messages, has_more = history_page(args.user, thread_peer(args.route, args.user), args.before, page_budget)
    return {messages = messages, has_more = has_more}
  end),
  ['view.rename'] = view(view_rename, true),
  ['view.action'] = view(view_action, true),
  ['view.draft.save'] = view(view_draft_save),
  ['view.send'] = view(view_send, true),
  ['view.seen'] = view(view_seen, true),
}, plain)
app.view('/panels/threads', {
  render = render(function(args) return render_home(args.user, args.context) end),
  ['view.action'] = view(view_action, true),
}, plain)
app.view('/forms/*', {render = render(form_view), ['view.action'] = view(view_action, true)}, plain)
if gallery_tab then
  app.view(gallery_route, {
    render = function() return render_gallery() end,
    ['view.action'] = function(_, args) return gallery_action(args) end,
    ['view.draft.save'] = function(_, args) return gallery_draft_save(args) end,
    ['view.send'] = function(_, args) return gallery_send(args) end,
  }, {store = false})
end

-- hub.changed: the hub sends one for each change of agents, workers and plugins, and does not
-- coalesce them. Only agents changes the tabs. A declaration for each one queued the plugin: on
-- the live hub after release 2 (2026-10-22), bursts of about 30 per 10 s met declarations of about
-- 1 s each, and the 16-request queue filled. So the handler only schedules one declaration and
-- replies at once; a burst gets one or two declarations. The schedule state is a table field, not
-- a captured local (the pcall rule, LazyRex docs/rex-protocol.md). The SDK logs a failed declaration; the next
-- action or agents change declares the tabs again.
app.on('hub.changed', function(args)
  if args.what == 'agents' then schedule_refresh() end
end, {tx = false})

for _, command in ipairs({{id = 'new_thread', title = 'New Thread…', description = 'Start a conversation with agents', keywords = {'message', 'conversation'}, route = '/forms/new-thread', action = 'messaging.thread_create'},
    {id = 'threads', title = 'Threads…', description = 'List all threads, with this session first', keywords = {'message', 'conversation'}, surface = 'panel', landing = true, route = '/panels/threads', user_only = 'navigation'}}) do app.command(command) end

-- Spike 3 has one UI user. Each conversation has one tab.
-- The import runs first, at start (each step its own transaction); calls wait in the plugin's queue
-- until it ends. A failed import leaves every call refused with its error, and meta import_error
-- holds the error; the plugin keeps running, and the next start resumes.
local import = require('import')({
  db = db, hub = hub, fail = fail, part = part, parts = parts, json = json, rows = rows,
  encoded_size = encoded_size, utf8_cut = utf8_cut, later = later, thread_pair = thread_pair,
  c = function(id) return canonical(id) end, c_thread = function(id) return canonical_thread_id(id) end,
  use_aliases = function(map) aliases = map end,
  refresh_participants = refresh_participants, participants = function() return participants end,
  notice = app.notice,
  -- The cutover gives the notices of the whole roster itself: the merges give none.
  migrate_aliases = function()
    local inside = notes.inside
    notes.inside = true
    migrate_aliases()
    notes.inside, notes.marked, notes.list = inside, {}, {}
  end,
})
app.start(function()
  local ok, err = pcall(import.run)
  if not ok then
    imported.error = type(err) == 'table' and tostring(err.code) .. ': ' .. tostring(err.message) or tostring(err)
    print('messaging: the import failed: ' .. imported.error)
    pcall(db.transaction, function()
      db.exec([[INSERT INTO meta (key, value) VALUES ('import_error', ?)
        ON CONFLICT (key) DO UPDATE SET value = excluded.value]], imported.error)
    end)
    return
  end
  pcall(db.transaction, function() db.exec("DELETE FROM meta WHERE key = 'import_error'") end)
  imported.done = true
  refresh_participants()
  migrate_aliases()
  declare_tabs(ui_user)
end, {tx = false})
