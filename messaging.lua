-- Durable messaging. The hub owns storage and replaces this process after a restart.
local hub_id = assert(rex.args.hub_client_id, 'hub_client_id is required')
local instance_id = assert(rex.args.instance_id, 'instance_id is required')
local attempts = 4 -- Bound revision-conflict retries; this is not a delivery guarantee.

local function fail(code, message)
  error({code = code, message = message})
end

-- A hub error keeps its code. Only an error without a code, or with a transient code, becomes
-- 'unavailable' (retryable): a definite refusal must end an operation, not repeat it.
local transient = {unavailable = true, disconnected = true, timeout = true}

-- hub_error turns a Rex perform error into {code, message}. Rex Lua gives it as text that ends in
-- "(status=<n> code=<code>)" (LazyRex docs/rex-protocol.md).
local function hub_error(call_error)
  local code, message
  if type(call_error) == 'table' then
    code, message = call_error.code, call_error.message
  else
    local text = tostring(call_error or 'Hub request failed')
    code = text:match('code=([%w_%-%.]+)%)%s*$')
    message = text:match('failed: (.*) %(status=%d+ code=[^)]*%)%s*$') or text
    -- A hub error message keeps its own "code: " prefix; drop it when it repeats the code.
    if code and message:sub(1, #code + 2) == code .. ': ' then message = message:sub(#code + 3) end
  end
  if not code or transient[code] then code = 'unavailable' end
  return code, message or 'Hub request failed'
end

-- One control message from this plugin is at most 64 KiB (LazyRex docs/rex-protocol.md, "Rex Lua
-- runtime"). hub() measures each request before it sends it: a request that can never fit is
-- invalid_input with its size, not the retryable 'unavailable', and nothing of it is committed.
-- request_limit leaves 1 KiB for the control frame around the client.perform payload.
local request_limit = 65536 - 1024
local measure -- encoded_size, defined below with the other size helpers

local function hub(action, args)
  local request = {client_id = hub_id, action = action, args = args, timeout_ms = 10000}
  if measure then
    local n = measure(request)
    if n > request_limit then
      fail('invalid_input', 'The ' .. action .. ' request is ' .. n .. ' bytes encoded; one request is at most ' .. request_limit
        .. ' (the records it writes are too large)')
    end
  end
  local response, call_error = rex.call('client.perform', request)
  if not response then fail(hub_error(call_error)) end
  if type(response.result) ~= 'table' then fail('internal', 'Invalid hub result') end
  return response.result
end

local function part(value)
  return tostring(#value) .. ':' .. value
end

-- The hub owns immutable aliases. The plugin owns the records that use those aliases.
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

local function canonical_key(key)
  local prefix, suffix = key:match('^([^/]+)/(.+)$')
  if prefix ~= 'mailbox' and prefix ~= 'thread' and prefix ~= 'thread-archive' and prefix ~= 'draft' and prefix ~= 'thread-title' and prefix ~= 'thread-meta' and prefix ~= 'thread-open' and prefix ~= 'thread-page' then return key end
  local p = parts(suffix)
  local count = (prefix == 'mailbox' or prefix == 'thread-archive') and 1 or 2
  if not p or #p ~= count then fail('internal', 'Invalid messaging key: ' .. key) end
  for i, id in ipairs(p) do p[i] = canonical_thread_id(id) end
  if (prefix == 'thread' or prefix == 'thread-meta') and p[2] < p[1] then local t = p[1]; p[1] = p[2]; p[2] = t end
  local result = prefix .. '/'
  for _, id in ipairs(p) do result = result .. part(id) end
  return result
end

local function refresh_participants()
  aliases, participants = {}, hub('hub.agents', {all = true}).agents or {}
  for _, a in ipairs(participants) do
    if a.alias_of then aliases[a.id] = a.alias_of end
  end
end

local function resolve_recipient(id)
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

-- set_rev is the revision at which a home or a title was set. A migration rewrites a record and
-- so gives it a new revision; the moved value keeps the old one in set_rev. Identities report one
-- at a time, so a second migration must still see the first one's age. A normal write replaces
-- the whole value, so its own revision counts again.
local function set_rev(source) return source.record.value.set_rev or source.record.rev end
local function with_set_rev(source)
  local value = {}
  for k, v in pairs(source.record.value) do value[k] = v end
  value.set_rev = set_rev(source)
  return value
end

local function migrate_aliases()
  local names = {}
  for id in pairs(aliases) do names[#names + 1] = id end
  if #names == 0 then return end
  table.sort(names)
  local markers = {}
  for _, id in ipairs(names) do markers[#markers + 1] = 'identity-migrated/' .. part(id) end
  local completed = hub('hub.store.get', {keys = markers}).records
  local pending = {}
  for _, id in ipairs(names) do
    local marker = completed['identity-migrated/' .. part(id)]
    if marker.rev == '0' then pending[#pending + 1] = id
    elseif marker.value.identity ~= aliases[id] then fail('internal', 'An identity alias changed') end
  end
  names = pending
  if #names == 0 then return end
  local key = 'identity-migrate/'
  for _, id in ipairs(names) do key = key .. part(id) .. part(aliases[id]) end
  if hub('hub.store.op', {key = key}).found then return end
  for _ = 1, attempts do
    local records, after = {}, nil
    repeat
      local page = hub('hub.store.scan', {after = after})
      for k, record in pairs(page.records or {}) do records[k] = record end
      after = page.next
    until not after
    local targets, changed, notices = {}, {}, {}
    -- Collect all contributors before changing a key. Existing canonical records participate too.
    for old, record in pairs(records) do
      local target = canonical_key(old)
      if target ~= old then changed[old], changed[target] = true, true end
      if old:match('^mailbox/') or old:match('^thread/') or old:match('^thread%-archive/') or old:match('^draft/') or old:match('^thread%-title/') or old:match('^thread%-meta/') or old:match('^thread%-open/') or old:match('^thread%-page/') then
        targets[target] = targets[target] or {}
        targets[target][#targets[target] + 1] = {key = old, record = record}
      end
    end
    local values = {}
    for target, contributors in pairs(targets) do
      local value
      if target:match('^thread%-page/') then
        value = {count = 50}
        for _, source in ipairs(contributors) do value.count = math.max(value.count, source.record.value.count or 50) end
      elseif target:match('^thread%-open/') then
        value = {opened = true}
      elseif target:match('^thread%-meta/') then
        -- A move (moved = true) is an explicit choice: the newest move wins. Without a move,
        -- the first home wins among the inherited homes (legacy, canonical, carried).
        local moved, first
        for _, source in ipairs(contributors) do
          if source.record.value.moved and (not moved or later(set_rev(source), set_rev(moved))) then moved = source end
          if not first or later(set_rev(first), set_rev(source)) then first = source end
        end
        value = with_set_rev(moved or first)
      elseif target:match('^thread%-title/') then
        -- The latest explicit rename wins when legacy and canonical titles both exist.
        local newest
        for _, source in ipairs(contributors) do
          if not newest or later(set_rev(source), set_rev(newest)) then newest = source end
        end
        value = with_set_rev(newest)
      elseif target:match('^draft/') then
        value = {text = ''}
        for _, source in ipairs(contributors) do
          local text = source.record.value.text or ''
          if text ~= '' and value.text ~= '' and text ~= value.text then
            fail('migration_conflict', 'Two drafts have different text for ' .. target)
          end
          if text ~= '' then value.text = text end
        end
      elseif target:match('^thread/') then
        local seen, ids = {}, {}
        for _, source in ipairs(contributors) do
          -- Merging only ids would lose a chain's segments. F1 migrates chains in a later commit.
          if (source.record.value.seg or 0) > 0 then fail('migration_conflict', 'Cannot migrate a segmented thread yet: ' .. target) end
          for _, id in ipairs(source.record.value.ids) do
            if not seen[id] then seen[id] = true; ids[#ids + 1] = id end
          end
        end
        table.sort(ids, function(a, b)
          local ra, rb = records['message/' .. a], records['message/' .. b]
          if not ra or not rb then fail('internal', 'Thread references a missing message') end
          if ra.rev == rb.rev then return a < b end
          return later(rb.rev, ra.rev)
        end)
        value = {ids = ids}
      else
        local ids = {}
        for _, source in ipairs(contributors) do
          for id, enabled in pairs(source.record.value.ids) do
            local name = target:match('^thread%-archive/') and canonical_thread_id(id) or id
            ids[name] = enabled
            if name ~= id then changed[target] = true end
          end
        end
        value = {ids = ids}
      end
      values[target] = value
    end
    local groups = records.groups
    if groups then
      for _, g in pairs(groups.value.groups) do
        local seen, members = {}, {}
        for _, id in ipairs(g.members) do
          local name = canonical(id)
          if name ~= id then changed.groups = true end
          if not seen[name] then seen[name] = true; members[#members + 1] = name end
        end
        g.members = members
      end
      values.groups = groups.value
    end
    for _, id in ipairs(names) do
      notices[id] = false
      local box = values['mailbox/' .. part(aliases[id])]
      notices[aliases[id]] = box ~= nil and next(box.ids) ~= nil
      -- The pending notice derives from this mailbox snapshot, so guard it in the same batch.
      if box then changed['mailbox/' .. part(aliases[id])] = true end
    end
    local ops = {}
    for record_key in pairs(changed) do
      local old = records[record_key]
      local op = {key = record_key, if_rev = old and old.rev or '0'}
      if values[record_key] then op.value = values[record_key] else op.delete = true end
      ops[#ops + 1] = op
    end
    for _, id in ipairs(names) do
      ops[#ops + 1] = {key = 'identity-migrated/' .. part(id), if_rev = '0', value = {identity = aliases[id]}}
    end
    for id, pending in pairs(notices) do ops[#ops + 1] = {notify = {agent = id, pending = pending}} end
    local stored = hub('hub.store.batch', {ops = ops, op = {key = key, fingerprint = key, result = {migrated = true}}})
    if stored.op_exists or type(stored.revs) == 'table' then return end
    if not stored.conflict or stored.conflict.kind ~= 'revision' then fail('migration_conflict', 'Identity migration failed') end
  end
  fail('unavailable', 'Messaging changed during identity migration; retry')
end

-- Operation records keep their original owner and result. Search aliases before a new mutation.
local function prior_operation(prefix, agent, key)
  local owners = {agent}
  for old, id in pairs(aliases) do if id == agent then owners[#owners + 1] = old end end
  local found
  for _, owner in ipairs(owners) do
    local saved = hub('hub.store.op', {key = prefix .. part(owner) .. part(key)})
    if saved.found then
      if found then fail('operation_conflict', 'This key was used by more than one aliased agent') end
      found = saved
    end
  end
  return found or {found = false}
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
-- its envelope and call_id, inside the 16 KiB left. A hub request from this plugin holds at most
-- request_budget encoded bytes of keys. The hub refuses its own reply over 1 MiB with
-- reply_too_large.
local reply_budget = 49152
local request_budget = 49152

-- encoded_size returns the JSON size of v, counted as the hub's Go encoder writes it: '<', '>' and
-- '&' as \u003c (6 bytes), U+2028 and U+2029 as \u2028 (6 bytes). rex.json escapes no more than
-- that, so the count is also an upper bound of this plugin's own encoding.
local function encoded_size(v)
  local text = assert(rex.json.encode(v))
  local _, html = text:gsub('[<>&]', '')
  local _, separators = text:gsub('\226\128[\168\169]', '')
  return #text + 5 * html + 3 * separators
end
measure = encoded_size

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

local function get(keys)
  local ok, result = pcall(hub, 'hub.store.get', {keys = keys})
  if not ok then
    -- One record over the hub's reply limit cannot be read at all: a definite size error.
    if type(result) == 'table' and result.code == 'reply_too_large' and #keys == 1 then
      fail('record_too_large', 'Record ' .. preview(keys[1]) .. ' is larger than one hub reply')
    end
    error(result, 0)
  end
  if type(result.records) ~= 'table' then fail('internal', 'Missing store records') end
  for _, key in ipairs(keys) do
    local record = result.records[key]
    if type(record) ~= 'table' or type(record.rev) ~= 'string' then
      fail('internal', 'Invalid store record: ' .. key)
    end
    if key:sub(1, 8) == 'message/' and type(record.value) == 'table' then
      record.value.from = canonical(record.value.from)
      record.value.to = canonical(record.value.to)
    end
  end
  return result.records
end

local function mailbox(agent)
  local key = 'mailbox/' .. part(agent)
  local record = get({key})[key]
  if record.rev == '0' then return key, record.rev, {} end
  if type(record.value) ~= 'table' or type(record.value.ids) ~= 'table' then
    fail('internal', 'Invalid mailbox record')
  end
  local ids = {}
  for id, unread in pairs(record.value.ids) do
    if type(id) ~= 'string' or unread ~= true then fail('internal', 'Invalid mailbox entry') end
    ids[id] = true
  end
  return key, record.rev, ids
end

-- Groups: a group is a recipient with members. A message to a group goes into every other
-- member's mailbox and into the group's thread. The built-in group "team" has the whole roster
-- as members. The user creates other groups in the Messages view; they live in the record
-- "groups" as {groups = {[id] = {name, members}}}. Created group IDs start with "g-", so they
-- never equal an agent ID.
local builtin = {team = {name = 'Team'}}

-- message_records reads records in batches: at most 8 keys and request_budget bytes of keys in
-- one request (a target, not a limit: a larger key goes alone). A batch whose reply is over the
-- hub limit is read one key at a time. Other errors keep their code. A key whose request does not
-- fit request_limit, measured as hub() measures it, is a definite size error.
local function message_records(keys)
  local out = {}
  local function read_batch(batch)
    local ok, got = pcall(get, batch)
    if ok then
      for k, r in pairs(got) do out[k] = r end
    elseif #batch > 1 and type(got) == 'table' and got.code == 'reply_too_large' then
      for _, k in ipairs(batch) do out[k] = get({k})[k] end
    else
      error(got, 0)
    end
  end
  local batch, size = {}, 2
  for _, k in ipairs(keys) do
    local cost = encoded_size(k) + 1
    if cost + 2 > request_budget
      and encoded_size({client_id = hub_id, action = 'hub.store.get', args = {keys = {k}}, timeout_ms = 10000}) > request_limit then
      fail('key_too_large', 'Key ' .. preview(k) .. ' does not fit one hub request')
    end
    if #batch > 0 and (#batch == 8 or size + cost > request_budget) then
      read_batch(batch)
      batch, size = {}, 2
    end
    batch[#batch + 1] = k
    size = size + cost
  end
  if #batch > 0 then read_batch(batch) end
  return out
end

local function roster()
  local ids = {}
  for _, a in ipairs(participants) do if not a.alias_of and a.state ~= 'superseded' then ids[#ids + 1] = a.id end end
  return ids
end

local function is_group_id(id)
  return builtin[id] ~= nil or (type(id) == 'string' and id:sub(1, 2) == 'g-')
end

-- stored_groups returns the created groups, the record revision, and the record value.
local function stored_groups()
  local record = get({'groups'})['groups']
  if record.rev == '0' then return {}, '0' end
  if type(record.value) ~= 'table' or type(record.value.groups) ~= 'table' then fail('internal', 'Invalid groups record') end
  return record.value.groups, record.rev
end

-- group returns {name, members} for a group ID, or nil.
local function group(id)
  if builtin[id] then return {name = builtin[id].name, members = roster()} end
  if not is_group_id(id) then return nil end
  local groups, rev = stored_groups()
  return groups[id], rev, groups
end

local function is_member(g, agent)
  for _, m in ipairs(g.members) do
    if m == agent then return true end
  end
  return false
end

-- addressed reports whether a message is for this agent: directly or through a group.
local function addressed(message, agent)
  if message.to == agent then return true end
  if message.from == agent then return false end
  local audience = message.recipients
  if not audience then
    local delivery = get({'delivery/' .. part(message.id)})['delivery/' .. part(message.id)]
    if delivery.rev ~= '0' then audience = delivery.value.ids end
  end
  if audience then
    for _, id in ipairs(audience) do if canonical(id) == agent then return true end end
    return false
  end
  local g = group(message.to)
  return g ~= nil and is_member(g, agent)
end

-- recipients returns the mailboxes a message from sender to `to` goes into.
local function recipients(sender, to)
  local g, rev, groups = group(to)
  if g then
    if not is_member(g, sender) then fail('refused', 'Only a member sends to this group') end
    local list = {}
    for _, id in ipairs(g.members) do
      if id ~= sender then list[#list + 1] = id end
    end
    local guard = rev and {key = 'groups', value = {groups = groups}, if_rev = rev} or nil
    return list, guard
  end
  for _, a in ipairs(participants) do
    if not a.alias_of and a.id == to then return {to} end
  end
  fail('refused', 'Unknown recipient')
end

-- The history of two participants, or of a group: message IDs, oldest first.
local function thread_key(a, b)
  if a == 'user' then
    local pair = observed_direct_parts(b)
    if pair then return 'thread/' .. part(pair[1]) .. part(pair[2]) end
  end
  if is_group_id(b) then a = '' end -- a group has one thread for all members
  -- Not `a, b = b, a`: Rex 1203 Lua gives (b, b) (docs/rex-protocol.md).
  if b < a then local t = a; a = b; b = t end
  return 'thread/' .. part(a) .. part(b)
end

local function thread_home(a, b)
  local suffix = thread_key(a, b):sub(8)
  if a == 'user' and observed_direct_parts(b) then
    suffix = b < a and (part(b) .. part(a)) or (part(a) .. part(b))
  end
  local key = 'thread-meta/' .. suffix
  local record = get({key})[key]
  return type(record.value) == 'table' and record.value.home_session or nil, key, record.rev
end

-- Thread chains (docs/f-thread-tail.md, F1). The thread record is the tail: {ids, seg, chain,
-- frozen}. ids are the newest message IDs, oldest first. The older IDs are in seg segments
-- thread-seg/<suffix>/<chain>/<k>, each {ids}, segment 0 the oldest; frozen counts their IDs. A
-- tail from before F1 has ids only. A segment is written once and never changes.
local function segment_key(tail_key, chain, k)
  return 'thread-seg/' .. tail_key:sub(8) .. '/' .. chain .. '/' .. k
end

local function count_field(v)
  return v == nil or (type(v) == 'number' and v >= 0 and v % 1 == 0)
end

local function thread(a, b)
  local key = thread_key(a, b)
  local record = get({key})[key]
  local tail = {ids = {}, seg = 0, chain = '0', frozen = 0}
  if record.rev ~= '0' then
    local v = record.value
    if type(v) ~= 'table' or type(v.ids) ~= 'table' or not count_field(v.seg) or not count_field(v.frozen)
      or (v.chain ~= nil and (type(v.chain) ~= 'string' or not v.chain:match('^%d+$'))) then
      fail('internal', 'Invalid thread record')
    end
    for _, id in ipairs(v.ids) do tail.ids[#tail.ids + 1] = id end
    tail.seg, tail.chain, tail.frozen = v.seg or 0, v.chain or '0', v.frozen or 0
  end
  return key, record.rev, tail
end

-- tail_value is the record value of a tail. The chain fields stay absent while they are 0, as in
-- a tail from before F1.
local function tail_value(tail)
  local v = {ids = tail.ids}
  if tail.seg > 0 then v.seg = tail.seg end
  if tail.chain ~= '0' then v.chain = tail.chain end
  if tail.frozen > 0 then v.frozen = tail.frozen end
  return v
end

-- with_chain runs fn(key, rev, tail, segment) on the thread of a and b. segment(k) returns the IDs
-- of segment k. A missing segment means that an alias migration replaced the chain after the tail
-- read: fn's whole work is discarded, and fn runs again from a new tail read, at most attempts
-- times for the whole read. A walk never continues on a new tail: it could repeat or skip IDs.
local chain_changed = {}
local function with_chain(a, b, fn)
  for _ = 1, attempts do
    local key, rev, tail = thread(a, b)
    local function segment(k)
      local sk = segment_key(key, tail.chain, k)
      local record = get({sk})[sk]
      if record.rev == '0' then error(chain_changed, 0) end
      if type(record.value) ~= 'table' or type(record.value.ids) ~= 'table' then fail('internal', 'Invalid thread segment') end
      return record.value.ids
    end
    local out = {pcall(fn, key, rev, tail, segment)}
    if out[1] then return unpack(out, 2) end
    if out[2] ~= chain_changed then error(out[2], 0) end
  end
  fail('unavailable', 'The thread changed during the read; retry')
end

-- chain_reader returns next_ids(n): up to n more IDs of the chain, newest first; {} at the end.
-- The position is in table fields, not captured locals: in Rex Lua, a closure made before a pcall
-- catch keeps its own copy of the locals that it captured (coordinator, 2026-10-19).
local function chain_reader(tail, segment)
  local at = {list = tail.ids, i = #tail.ids, k = tail.seg}
  return function(n)
    local out = {}
    while #out < n do
      if at.i >= 1 then
        out[#out + 1] = at.list[at.i]
        at.i = at.i - 1
      elseif at.k >= 1 then
        at.k = at.k - 1
        at.list = segment(at.k)
        at.i = #at.list
      else
        break
      end
    end
    return out
  end
end

-- chain_ids returns every ID of the chain, oldest first.
local function chain_ids(tail, segment)
  local out = {}
  for k = 0, tail.seg - 1 do
    for _, id in ipairs(segment(k)) do out[#out + 1] = id end
  end
  for _, id in ipairs(tail.ids) do out[#out + 1] = id end
  return out
end

-- tail_limit is the packing target of a tail and of a segment, in encoded bytes of {ids = ...}.
-- It is not a rejection limit: an ID over it gets a segment alone, and a tail of one ID never
-- freezes. The only rejection is the request limit that hub() measures.
local tail_limit = 8192

-- ids_size is the encoded size of {"ids":[...]}: the item sizes, the commas and 10 bytes.
local function ids_size(item_sizes, n)
  local total = 10 + math.max(n - 1, 0)
  for i = 1, n do total = total + item_sizes[i] end
  return total
end

-- prepare_tail runs freeze steps on the thread of a and b until the tail with next_id fits
-- tail_limit, or the tail is one ID. A step is one batch: the longest oldest prefix at or under
-- tail_limit, at least one ID and never the newest, becomes segment seg; the tail keeps the rest.
-- The decision uses the size only, so a tail that a failure left over the target continues with
-- the same steps. Steps have their own conflict bound: a successful step does not use the
-- caller's attempts. Returns the tail of the last read.
local function prepare_tail(a, b, next_id)
  local conflicts = 0
  while true do
    local key, rev, tail = thread(a, b)
    local n = #tail.ids
    if n <= 1 then return key, rev, tail end
    local sizes = {}
    for i, id in ipairs(tail.ids) do sizes[i] = encoded_size(id) end
    sizes[n + 1] = encoded_size(next_id)
    if ids_size(sizes, n + 1) <= tail_limit then return key, rev, tail end
    local take, size = 1, 10 + sizes[1]
    while take < n - 1 and size + 1 + sizes[take + 1] <= tail_limit do
      take = take + 1
      size = size + 1 + sizes[take]
    end
    local frozen, rest = {}, {}
    for i = 1, n do
      if i <= take then frozen[#frozen + 1] = tail.ids[i] else rest[#rest + 1] = tail.ids[i] end
    end
    local after = {ids = rest, seg = tail.seg + 1, chain = tail.chain, frozen = tail.frozen + take}
    local stored = hub('hub.store.batch', {ops = {
      {key = segment_key(key, tail.chain, tail.seg), value = {ids = frozen}, if_rev = '0'},
      {key = key, value = tail_value(after), if_rev = rev},
    }})
    if stored.conflict then
      if stored.conflict.kind ~= 'revision' then fail('internal', 'Unexpected thread freeze conflict') end
      conflicts = conflicts + 1
      if conflicts >= attempts then fail('unavailable', 'The thread changed during a freeze; retry') end
    elseif type(stored.revs) ~= 'table' then
      fail('internal', 'Invalid store batch result')
    end
  end
end

local function identify(ev)
  local principal = ev.requester and ev.requester.principal
  if not principal or principal.kind ~= 'peer' or type(principal.pid) ~= 'number' then
    fail('refused', 'A local requester PID is required')
  end
  local result = hub('hub.identify', {pid = principal.pid})
  if result.found ~= true or type(result.agent) ~= 'string' or result.agent == '' then
    fail('refused', 'The hub does not recognize this agent')
  end
  return result.agent, result.session_id
end

local function saved_result(saved, fingerprint)
  if normalized_fingerprint(saved.fingerprint) ~= normalized_fingerprint(fingerprint) then fail('conflict', 'Send key already has different content') end
  if type(saved.result) ~= 'table' or type(saved.result.id) ~= 'string' then
    fail('internal', 'Invalid saved send result')
  end
  return saved.result
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
-- body_limit: a send's hub.store.batch carries the body twice (the message record and the
-- operation fingerprint), and the rest of the 64 KiB request holds the mailbox, thread and
-- groups records. The body limit is fixed; whether the whole batch fits depends on the current
-- records, and hub() checks that for each batch.
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

-- shrink makes the only item of page fit (a stored message from before admit). In order:
--   1. the body is cut to a UTF-8-safe prefix: truncated = true, body_bytes = its full size;
--   2. the metadata does not fit either: a marker {cursor, id, metadata_too_large, bytes};
--   3. the ID does not fit either: id_prefix (at most 256 bytes, can be empty) and id_bytes.
-- bytes is the encoded size of the full item. The caller checked that min_marker fits.
local function shrink(page, item)
  local full = encoded_size(item)
  local body = item.body or ''
  item.truncated, item.body_bytes, item.body = true, #body, ''
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
  if saved.found == true then return saved_result(saved, fingerprint) end
  if saved.found ~= false then fail('internal', 'Invalid operation lookup') end
  -- Size limits apply to new sends only: a stored result replays above, whatever its size.
  if #args.key > 200 then fail('invalid_input', 'key is ' .. #args.key .. ' bytes; the limit is 200') end
  if args.reply_to and #args.reply_to > 512 then fail('invalid_input', 'reply_to is ' .. #args.reply_to .. ' bytes; the limit is 512') end
  args.to = resolve_recipient(args.to)
  recipients(agent, args.to) -- Validate before checking a reply. Each attempt reads membership again.
  if args.reply_to then
    local original = get({'message/' .. args.reply_to})['message/' .. args.reply_to]
    local message = original.value
    if original.rev == '0' or type(message) ~= 'table' or message.id ~= args.reply_to
      or not addressed(message, agent) or (message.from ~= args.to and (not is_group_id(args.to) or message.to ~= args.to)) then
      fail('refused', 'reply_to must name a message to this agent, from the recipient or in the same group')
    end
  end
  local result = {id = id, key = args.key}
  local message_key = 'message/' .. id
  local message = {id = id, from = agent, to = args.to, body = args.body, reply_to = args.reply_to, at = os.date('!%Y-%m-%dT%H:%M:%SZ')}
  if args.reply_expected == false then message.reply_expected = false end
  admit(message)
  for _ = 1, attempts do
    local targets, guard = recipients(agent, args.to)
    message.recipients = targets
    local ops = {{key = message_key, value = message, if_rev = '0'}}
    if guard then ops[#ops + 1] = guard end
    local boxes = {} -- mailbox keys this attempt reads; a revision conflict on one is retried
    local self_ids
    for _, to in ipairs(targets) do
      local box_key, rev, ids = mailbox(to)
      if to == agent then self_ids = ids else
        ids[id] = true
        ops[#ops + 1] = {key = box_key, value = {ids = ids}, if_rev = rev}
        ops[#ops + 1] = {notify = {agent = to, pending = true}}
      end
      boxes[box_key] = true
    end
    local sender_key
    if args.reply_to then
      if self_ids then
        -- A self-reply changes one mailbox. Do not write the same key twice.
        self_ids[args.reply_to] = nil
      else
        local sender_rev, sender_ids
        sender_key, sender_rev, sender_ids = mailbox(agent)
        if sender_ids[args.reply_to] then
          sender_ids[args.reply_to] = nil
          ops[#ops + 1] = {key = sender_key, value = {ids = sender_ids}, if_rev = sender_rev}
          if next(sender_ids) == nil then
            ops[#ops + 1] = {notify = {agent = agent, pending = false}}
          end
        end
      end
    end
    if self_ids then
      local box_key, rev = mailbox(agent)
      self_ids[id] = true
      ops[#ops + 1] = {key = box_key, value = {ids = self_ids}, if_rev = rev}
      ops[#ops + 1] = {notify = {agent = agent, pending = true}}
    end
    local thread_key, thread_rev, tail = prepare_tail(agent, args.to, id)
    tail.ids[#tail.ids + 1] = id
    ops[#ops + 1] = {key = thread_key, value = tail_value(tail), if_rev = thread_rev}
    local stored = hub('hub.store.batch', {
      ops = ops,
      op = {key = id, fingerprint = fingerprint, result = result}
    })
    if stored.op_exists then return saved_result(stored.op_exists, fingerprint) end
    if stored.conflict then
      if stored.conflict.kind == 'operation' then fail('conflict', 'Send key already has different content') end
      if stored.conflict.kind ~= 'revision'
        or (not boxes[stored.conflict.key] and stored.conflict.key ~= sender_key and stored.conflict.key ~= thread_key and stored.conflict.key ~= 'groups') then
        fail('conflict', 'Message record conflict; reconcile the send key')
      end
    elseif type(stored.revs) == 'table' then
      return result
    else
      fail('internal', 'Invalid store batch result')
    end
  end
  fail('conflict', 'Mailbox changed; retry with the same send key')
end

-- Store revisions increase across all records. Compare decimal strings without rounding.

local function message_thread(message, agent)
  if is_group_id(message.to) then return message.to end
  return message.from == agent and message.to or message.from
end

local function read(agent, args)
  local since = args.since or '0'
  if type(since) ~= 'string' or not since:match('^%d+$') or (#since > 1 and since:sub(1, 1) == '0') then
    fail('invalid_input', 'since must be a decimal revision cursor')
  end
  if args.thread ~= nil then
    if type(args.thread) ~= 'string' or args.thread == '' then fail('invalid_input', 'thread must be a nonempty ID') end
    args.thread = resolve_recipient(args.thread)
    if not is_group_id(args.thread) then recipients(agent, args.thread)
    else
      local g = group(args.thread)
      if not g then fail('invalid_input', 'Unknown thread') end
      local allowed = is_member(g, agent)
      for _, id in ipairs(g.past_members or {}) do if canonical(id) == agent then allowed = true end end
      if not allowed then fail('refused', 'Only a current or former member reads delivered group mail') end
    end
  end
  local _, cursor, ids = mailbox(agent)
  local keys = {}
  for id in pairs(ids) do keys[#keys + 1] = 'message/' .. id end
  if #keys == 0 then return {messages = {}, next_cursor = cursor} end
  local records, messages = message_records(keys), {}
  for id in pairs(ids) do
    local record = records['message/' .. id]
    local message = record.value
    if record.rev == '0' or type(message) ~= 'table' or not addressed(message, agent) or message.id ~= id then
      fail('internal', 'Mailbox references an invalid message')
    end
    if later(record.rev, since) and (args.thread == nil or message_thread(message, agent) == args.thread) then
      messages[#messages + 1] = read_item(message, record.rev)
    end
  end
  table.sort(messages, function(a, b) return later(b.cursor, a.cursor) end)
  -- A page that stops early continues after its last message: next_cursor is that cursor.
  local page = {next_cursor = cursor_max, more = true}
  local n = fit_page(page, messages)
  if n == #messages then
    page.more, page.next_cursor = nil, cursor
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
  local messages, more = with_chain(agent, peer, function(_, _, tail, segment)
    local next_ids = chain_reader(tail, segment)
    local messages, more = {}, false
    -- Fetch bounded chunks, newest first. Only the requested page enters the agent's context.
    while not more do
      local ids = next_ids(50)
      if #ids == 0 then break end
      local keys = {}
      for _, id in ipairs(ids) do keys[#keys + 1] = 'message/' .. id end
      local records = message_records(keys)
      for _, id in ipairs(ids) do
        local record = records['message/' .. id]
        if not before or later(before, record.rev) then
          if #messages == limit then more = true; break end
          local m = record.value
          if type(m) ~= 'table' then fail('internal', 'Thread references a missing message') end
          messages[#messages + 1] = read_item(m, record.rev)
        end
      end
    end
    return messages, more
  end)
  -- The page also stops at reply_budget. next_before then names its oldest message.
  local result = {thread = peer, next_before = cursor_max}
  local n = fit_page(result, messages)
  result.next_before = (n < #messages or more) and result.messages[n].cursor or nil
  return checked(result)
end

local function ack(agent, args)
  if type(args.ids) ~= 'table' then fail('refused', 'ids must be an array of message IDs') end
  local wanted, keys, count, maximum = {}, {}, 0, 0
  for index, id in pairs(args.ids) do
    if type(index) ~= 'number' or index < 1 or index % 1 ~= 0 or type(id) ~= 'string' or id == '' then
      fail('refused', 'ids must be an array of nonempty message IDs')
    end
    count = count + 1
    maximum = math.max(maximum, index)
    if not wanted[id] then keys[#keys + 1] = 'message/' .. id end
    wanted[id] = true
  end
  if count ~= maximum then fail('refused', 'ids must be a contiguous array') end
  if count == 0 then return {acked = true} end
  local records = message_records(keys)
  for id in pairs(wanted) do
    local record = records['message/' .. id]
    if record.rev == '0' or type(record.value) ~= 'table' or not addressed(record.value, agent) or record.value.id ~= id then
      fail('refused', 'Unknown message ID for this agent')
    end
  end
  for _ = 1, attempts do
    local box_key, rev, ids = mailbox(agent)
    local changed = false
    for id in pairs(wanted) do
      if ids[id] then ids[id], changed = nil, true end
    end
    if not changed then return {acked = true} end
    local ops = {{key = box_key, value = {ids = ids}, if_rev = rev}}
    if next(ids) == nil then ops[#ops + 1] = {notify = {agent = agent, pending = false}} end
    local stored = hub('hub.store.batch', {ops = ops})
    if stored.conflict then
      if stored.conflict.kind ~= 'revision' or stored.conflict.key ~= box_key then
        fail('conflict', 'Unexpected acknowledgment conflict')
      end
    elseif type(stored.revs) == 'table' then
      return {acked = true}
    else
      fail('internal', 'Invalid store batch result')
    end
  end
  fail('conflict', 'Mailbox changed; retry acknowledgment')
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

-- Only explicit user opens create a marker. Roster membership does not create a tab.
local function opened_thread(user, peer)
  local key = 'thread-open/' .. part(user) .. part(canonical_thread_id(peer))
  local record = get({key})[key]
  return record.rev ~= '0' and type(record.value) == 'table' and record.value.opened == true, key, record.rev
end

local function remember_thread_open(user, peer)
  if user ~= 'user' then return end
  for _ = 1, attempts do
    local opened, key, rev = opened_thread(user, peer)
    if opened then return end
    local result = hub('hub.store.batch', {ops = {{key = key, if_rev = rev, value = {opened = true}}}})
    if type(result.revs) == 'table' then return end
    if not result.conflict or result.conflict.kind ~= 'revision' then fail('operation_conflict', 'Could not record the opened thread') end
  end
  fail('unavailable', 'The thread changed; retry the open')
end

local function thread_title(user, peer)
  local key = 'thread-title/' .. part(user) .. part(peer.id)
  local record = get({key})[key]
  if record.rev ~= '0' and type(record.value) == 'table'
    and type(record.value.title) == 'string' and record.value.title:match('%S') then return record.value.title end
  return display_name(peer)
end

local function observed_direct_peer(id)
  local pair = observed_direct_parts(id)
  if not pair then return nil end
  local key = 'thread/' .. part(pair[1]) .. part(pair[2])
  local record = get({key})[key]
  if record.rev == '0' or type(record.value) ~= 'table' or type(record.value.ids) ~= 'table' or #record.value.ids == 0 then return nil end
  local names = {}
  for _, a in ipairs(participants) do if not a.alias_of then names[a.id] = display_name(a) end end
  return {id = observed_direct_id(pair[1], pair[2]), name = (names[pair[1]] or pair[1]) .. ' ↔ ' .. (names[pair[2]] or pair[2]),
    observer = true, readonly = true}
end

local function peers(user)
  local list = {}
  for _, a in ipairs(participants) do
    if a.id ~= user and not a.alias_of then list[#list + 1] = a end
  end
  for gid, g in pairs(builtin) do list[#list + 1] = {id = gid, name = g.name, group = true} end
  local created = {}
  for gid, g in pairs(stored_groups()) do
    if is_member(g, user) or user == 'user' then
      created[#created + 1] = {id = gid, name = g.name, group = true, observer = not is_member(g, user)}
    end
  end
  table.sort(created, function(x, y) return x.name < y.name or (x.name == y.name and x.id < y.id) end)
  for _, g in ipairs(created) do list[#list + 1] = g end
  if user == 'user' then
    local after, seen, observed = nil, {}, {}
    repeat
      local page = hub('hub.store.scan', {prefix = 'thread/', after = after})
      for key, record in pairs(page.records or {}) do
        local pair = key:match('^thread/') and parts(key:sub(8))
        if pair and #pair == 2 and pair[1] ~= '' and pair[2] ~= '' and pair[1] ~= user and pair[2] ~= user
          and type(record.value) == 'table' and type(record.value.ids) == 'table' and #record.value.ids > 0 then
          local id = observed_direct_id(pair[1], pair[2])
          if not seen[id] then
            local peer = observed_direct_peer(id)
            if peer then observed[#observed + 1] = peer; seen[id] = true end
          end
        end
      end
      after = page.next
    until not after
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
  for _, a in ipairs(peers(user)) do
    if a.id == peer then return a end
  end
  fail('invalid_input', 'Unknown thread: ' .. peer)
end

local function archived_threads(user)
  local key = 'thread-archive/' .. part(user)
  local record = get({key})[key]
  if record.rev == '0' then return key, record.rev, {} end
  if type(record.value) ~= 'table' or type(record.value.ids) ~= 'table' then fail('internal', 'Invalid archived threads') end
  return key, record.rev, record.value.ids
end

local function unread_counts(user)
  local _, _, ids = mailbox(user)
  local keys, counts, total = {}, {}, 0
  for id in pairs(ids) do keys[#keys + 1] = 'message/' .. id end
  if #keys > 0 then
    for _, record in pairs(get(keys)) do
      local m = record.value
      if type(m) ~= 'table' or not addressed(m, user) then fail('internal', 'Invalid unread message') end
      local peer = message_thread(m, user)
      counts[peer] = (counts[peer] or 0) + 1
      total = total + 1
    end
  end
  return counts, total
end

local function unread_status(count, name)
  if count > 0 then return {state = 'done', msg = tostring(count) .. ' unread' .. (name and (' in ' .. name) or '')} end
end

local function thread_list(agent, args)
  if args.include_archived ~= nil and type(args.include_archived) ~= 'boolean' then fail('invalid_input', 'include_archived must be boolean') end
  local _, _, archived = archived_threads(agent)
  local counts = unread_counts(agent)
  local list = {}
  for _, peer in ipairs(peers(agent)) do
    if not archived[peer.id] or args.include_archived then
      local g = peer.group and group(peer.id) or nil
      list[#list + 1] = {id = peer.id, title = thread_title(agent, peer), members = g and g.members or {agent, peer.id},
        group = peer.group == true, observer = peer.observer or nil, readonly = peer.readonly or nil,
        archived = archived[peer.id] == true, unread = peer.observer and 0 or (counts[peer.id] or 0)}
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
  local function replay(saved)
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
  local saved = prior_operation('thread-create/', agent, args.key)
  if saved.found == true then return replay(saved) end
  -- Encode the complete scoped key. Do not truncate or discard punctuation.
  local id = 'g-' .. op_key:gsub('.', function(c) return string.format('%02x', string.byte(c)) end)
  local direct = #members == 2 and title == ''
  if direct then
    for _, member in ipairs(members) do if member ~= agent then id = member end end
  end
  local name = title ~= '' and title or table.concat(names, ', ')
  local result = {id = id, title = name, members = members, group = not direct}
  local selected_session
  for _ = 1, attempts do
    local ops = {}
    local home, home_key, home_rev = thread_home(agent, id)
    if not home then
      selected_session = selected_session or resolve_session(session_kind, session_value, source_session, op_key)
      ops[#ops + 1] = {key = home_key, value = {home_session = selected_session}, if_rev = home_rev}
    end
    if not direct then
      local groups, rev = stored_groups()
      groups[id] = {name = name, members = members}
      ops[#ops + 1] = {key = 'groups', value = {groups = groups}, if_rev = rev}
    end
    local stored = hub('hub.store.batch', {ops = ops, op = {key = op_key, fingerprint = fingerprint, result = result}})
    if stored.op_exists then return replay(stored.op_exists) end
    if type(stored.revs) == 'table' then
      if direct then remember_thread_open(agent, id) end
      return result
    end
    if not stored.conflict or stored.conflict.kind ~= 'revision' or (stored.conflict.key ~= 'groups' and stored.conflict.key ~= home_key) then
      fail('operation_conflict', 'Thread operation conflict; retry with the same key')
    end
  end
  fail('unavailable', 'Threads changed; retry with the same key')
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

-- Membership changes affect future delivery. Legacy messages keep a separate delivery snapshot.
-- notice_body sets the body of a membership notice. A title that would make the notice too large
-- for one read page, or its body larger than body_limit, is cut (with "…"). If the notice does not fit with an empty title, the change
-- is refused before its batch, so nothing is written.
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

local function change_members(user, peer, input, operation_key, context)
  if peer.observer then fail('refused', 'Send a message to join this group before changing its members') end
  if type(operation_key) ~= 'string' or operation_key == '' then fail('invalid_input', 'An operation key is required') end
  if builtin[peer.id] then fail('refused', 'The team group has dynamic membership') end
  local members, selected = selected_members(user, input)
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
  for _ = 1, attempts do
    local groups, rev = stored_groups()
    local g = groups[peer.id]
    if not g or not is_member(g, user) then fail('refused', 'Only a member changes this group') end
    local added = {}
    for _, id in ipairs(members) do if not is_member(g, id) then added[#added + 1] = id end end
    -- Freeze first; then the backfill reads the whole chain, and its tail revision guards the batch.
    prepare_tail(user, peer.id, 'member-notice/' .. op_key)
    local thread_key, thread_rev, tail, ids = with_chain(user, peer.id, function(key, rev, tail, segment)
      return key, rev, tail, chain_ids(tail, segment)
    end)
    local keys = {}
    for _, id in ipairs(ids) do keys[#keys + 1] = 'message/' .. id end
    local messages = #keys > 0 and message_records(keys) or {}
    local ops = {}
    for _, id in ipairs(ids) do
      local message = messages['message/' .. id].value
      if type(message) ~= 'table' then fail('internal', 'Thread references a missing message') end
      if not message.recipients then
        local key = 'delivery/' .. part(id)
        local delivery = get({key})[key]
        if delivery.rev == '0' then
          local audience = {}
          for _, member in ipairs(g.members) do if member ~= message.from then audience[#audience + 1] = member end end
          ops[#ops + 1] = {key = key, if_rev = '0', value = {ids = audience}}
        end
      end
    end
    local past, seen = {}, {}
    for _, list in ipairs({g.past_members or {}, g.members}) do
      for _, id in ipairs(list) do id = canonical(id); if not seen[id] then seen[id] = true; past[#past + 1] = id end end
    end
    g.past_members, g.members = past, members
    ops[#ops + 1] = {key = 'groups', if_rev = rev, value = {groups = groups}}
    if #added > 0 then
      local id = 'member-notice/' .. op_key
      local message = {id = id, from = user, to = peer.id, recipients = added, reply_expected = false, at = os.date('!%Y-%m-%dT%H:%M:%SZ')}
      notice_body(message, thread_title(user, peer))
      ops[#ops + 1] = {key = 'message/' .. id, if_rev = '0', value = message}
      tail.ids[#tail.ids + 1] = id
      for _, member in ipairs(added) do
        local key, box_rev, unread = mailbox(member)
        unread[id] = true
        ops[#ops + 1] = {key = key, if_rev = box_rev, value = {ids = unread}}
        ops[#ops + 1] = {notify = {agent = member, pending = true}}
      end
    end
    -- This revision check also prevents a concurrent send from escaping the membership snapshot.
    ops[#ops + 1] = {key = thread_key, if_rev = thread_rev, value = tail_value(tail)}
    local stored = hub('hub.store.batch', {ops = ops, op = {key = op_key, fingerprint = fingerprint, result = result}})
    if stored.op_exists then return operation_result(stored.op_exists, fingerprint) end
    if type(stored.revs) == 'table' then return result end
    if not stored.conflict or stored.conflict.kind ~= 'revision' then fail('operation_conflict', 'Membership operation conflict') end
  end
  fail('conflict', 'Membership changed; retry with the same operation key')
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
  if saved.found == true then return operation_result(saved, fingerprint) end
  args.thread = thread_peer('/thread/' .. args.thread, agent).id
  local result = {id = args.thread, archived = archived}
  for _ = 1, attempts do
    local key, rev, ids = archived_threads(agent)
    ids[args.thread] = archived and true or nil
    local stored = hub('hub.store.batch', {
      ops = {{key = key, value = {ids = ids}, if_rev = rev}},
      op = {key = op_key, fingerprint = fingerprint, result = result},
    })
    if stored.op_exists then return operation_result(stored.op_exists, fingerprint) end
    if type(stored.revs) == 'table' then return result end
    if not stored.conflict or stored.conflict.kind ~= 'revision' or stored.conflict.key ~= key then
      fail('operation_conflict', 'Archive operation conflict; retry with the same key')
    end
  end
  fail('unavailable', 'Archive changed; retry with the same key')
end

local function draft(user, peer)
  local key = 'draft/' .. part(user) .. part(peer)
  local record = get({key})[key]
  local text = ''
  if record.rev ~= '0' and type(record.value) == 'table' and type(record.value.text) == 'string' then text = record.value.text end
  return key, record.rev, text
end

local function render_home(user, context)
  local placement = hub('hub.ui.describe', {plugin = 'messaging'})
  local redirects = placement.home_redirects or {}
  local current, other = {}, {}
  for _, peer in ipairs(peers(user)) do
    local home = thread_home(user, peer.id)
    local session = home and (redirects[home] or home) or placement.default_session_id
    local target = context and session == context.session_id and current or other
    target[#target + 1] = peer
  end
  local ordered = {}
  for _, list in ipairs({current, other}) do
    for _, peer in ipairs(list) do ordered[#ordered + 1] = peer end
  end
  local counts, total = unread_counts(user)
  local _, _, archived = archived_threads(user)
  local items, archived_items, observed_items = {}, {}, {}
  for _, a in ipairs(ordered) do
    local n = a.observer and 0 or (counts[a.id] or 0)
    local item = {id = a.id, label = thread_title(user, a), detail = n > 0 and (n .. ' unread') or 'No unread messages',
      action = archived[a.id] and {name = 'restore', label = 'Restore', enabled = true, tool = 'messaging.thread_archive'}
        or {name = 'open', label = 'Open', enabled = true, user_only = 'navigation'}}
    if a.observer then item.detail = a.readonly and 'Read-only direct thread' or 'Send a message to join' end
    local target = archived[a.id] and archived_items or (a.observer and observed_items or items)
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
-- messages), oldest first, within budget bytes of estimated JSON, and whether older messages
-- exist. JSON escapes can double a body, so the estimate counts each body twice. The first message
-- always fits. A message larger than a page is cut, with a note, in the tree and in pages alike.
local function history_page(user, peer, before, budget)
  return with_chain(user, peer.id, function(_, _, tail, segment)
    local next_ids = chain_reader(tail, segment)
    if before ~= nil then
      repeat
        local id = next_ids(1)[1]
        if not id then fail('invalid_input', 'Unknown history cursor') end
      until id == before
    end
    local names = {}
    for _, a in ipairs(participants) do names[a.id] = display_name(a) end
    local newest_first, size = {}, 0
    while true do
      local ids = next_ids(8)
      if #ids == 0 then break end
      local keys = {}
      for _, id in ipairs(ids) do keys[#keys + 1] = 'message/' .. id end
      local records = message_records(keys)
      for _, id in ipairs(ids) do
        local m = records['message/' .. id].value
        if type(m) == 'table' then
          local body = type(m.body) == 'string' and m.body or ''
          local author = names[m.from] or m.from
          local cost = 2 * #body + #author + #m.id + 200
          if #newest_first > 0 and size + cost > budget then
            local older = {}
            for n = #newest_first, 1, -1 do older[#older + 1] = newest_first[n] end
            return older, true
          end
          if cost > page_budget then
            body = utf8_cut(body, math.floor((page_budget - 400) / 2)) .. '\n\n… (message cut: ' .. math.floor(#m.body / 1024) .. ' KB)'
            cost = page_budget
          end
          -- author is display text. own (optional) marks the user's own messages for styling.
          newest_first[#newest_first + 1] = {id = m.id, author = author, own = m.from == user, text = body, at = m.at, fyi = m.reply_expected == false}
          size = size + cost
        end
      end
    end
    local older = {}
    for n = #newest_first, 1, -1 do older[#older + 1] = newest_first[n] end
    return older, false
  end)
end

local function render_thread(user, route)
  local peer = thread_peer(route, user)
  local _, draft_rev, text = draft(user, peer.id)
  -- The draft shares the tree's control message with the newest messages.
  local messages, has_more = history_page(user, peer, nil, math.max(4000, page_budget - 2 * #(text or '')))
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
-- in the records "gallery/*" and never touches mailboxes or threads.
local gallery_route = '/gallery'

local function gallery_state()
  local keys = {'gallery/state', 'gallery/history', 'gallery/draft'}
  local r = get(keys)
  local state = type(r['gallery/state'].value) == 'table' and r['gallery/state'].value or {}
  local history = type(r['gallery/history'].value) == 'table' and r['gallery/history'].value.messages or {}
  local draft = r['gallery/draft']
  local text = type(draft.value) == 'table' and type(draft.value.text) == 'string' and draft.value.text or ''
  return state, r['gallery/state'].rev, history, r['gallery/history'].rev, text, draft.rev
end

local gallery_samples = {
  {id = 'g1', author = 'Claude', text = 'A short message.', at = '2026-10-16T21:00:00Z'},
  {id = 'g2', author = 'Codex', text = 'A longer message that wraps across several lines, so you can check line breaks, bubble padding and the reading width on a wide pane. It has **bold**, *italic* and `inline code`.', at = '2026-10-16T21:01:00Z'},
  {id = 'g3', author = 'Codex', text = 'A second message from the same author within two minutes, which groups under one header.', at = '2026-10-16T21:02:00Z'},
  {id = 'g4', author = 'User', own = true, text = 'One of your own messages, aligned right.', at = '2026-10-16T21:05:00Z'},
  {id = 'g5', author = 'Claude', text = 'A list and a code block:\n\n- first item\n- second item\n\n```go\nfunc main() {\n\tfmt.Println("hello")\n}\n```', at = '2026-10-16T21:10:00Z'},
}

local function render_gallery()
  local state, _, history, _, text, draft_rev = gallery_state()
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

local function gallery_note(last)
  for _ = 1, attempts do
    local _, rev = gallery_state()
    local stored = hub('hub.store.batch', {ops = {{key = 'gallery/state', value = {last = last}, if_rev = rev}}})
    if type(stored.revs) == 'table' then return end
  end
end

local function gallery_action(args)
  local input = type(args.input) == 'table' and args.input or {}
  if args.node_id == 'intro' then
    hub('hub.store.batch', {ops = {{key = 'gallery/history', value = {messages = {}}}, {key = 'gallery/state', value = {}}}})
    return {}
  end
  if args.node_id == 'sample_list' then gallery_note('opened list item ' .. tostring(input.item_id)); return {} end
  if args.node_id == 'sample_form' then
    local parts = {}
    for k, v in pairs(type(input.values) == 'table' and input.values or {}) do parts[#parts + 1] = k .. '=' .. tostring(v) end
    table.sort(parts)
    gallery_note('submitted form: ' .. table.concat(parts, ', '))
    return {}
  end
  fail('invalid_input', 'Unknown gallery action')
end

local function gallery_draft_save(args)
  local stored = hub('hub.store.batch', {
    ops = {{key = 'gallery/draft', value = {text = args.text}, if_rev = args.base_revision}},
    op = {key = 'gallery-draft/' .. part(args.operation_key), fingerprint = 'g/' .. part(args.base_revision) .. part(args.text),
      result = {text = args.text}, result_revs = {draft_revision = 'gallery/draft'}},
  })
  if stored.op_exists then return stored.op_exists.result end
  if stored.conflict then fail('draft_conflict', 'The draft changed in another view') end
  return {draft_revision = stored.revs['gallery/draft'], text = args.text}
end

local function gallery_send(args)
  local key = 'gallery-send/' .. part(args.operation_key)
  local saved = hub('hub.store.op', {key = key})
  if saved.found == true then return saved.result end
  for _ = 1, attempts do
    local _, _, history, history_rev, text, draft_rev = gallery_state()
    if draft_rev ~= args.draft_revision or text ~= args.text then fail('draft_conflict', 'The saved draft differs from the text to send') end
    history[#history + 1] = {id = key, author = 'User', own = true, text = args.text, at = os.date('!%Y-%m-%dT%H:%M:%SZ')}
    -- The history node holds at most page_size messages, samples included. Drop the oldest sends.
    while #history > page_size - #gallery_samples do table.remove(history, 1) end
    local stored = hub('hub.store.batch', {
      ops = {{key = 'gallery/history', value = {messages = history}, if_rev = history_rev},
        {key = 'gallery/draft', value = {text = ''}, if_rev = draft_rev}},
      op = {key = key, fingerprint = 'gs/' .. part(args.draft_revision) .. part(args.text),
        result = {message_id = key, cleared_draft_revision = args.draft_revision}, result_revs = {draft_revision = 'gallery/draft'}},
    })
    if stored.op_exists then return stored.op_exists.result end
    if type(stored.revs) == 'table' then
      return {message_id = key, cleared_draft_revision = args.draft_revision, draft_revision = stored.revs['gallery/draft']}
    end
  end
  fail('unavailable', 'Gallery changed; retry with the same operation key')
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

-- move_thread sets the user's home session of a thread. intent is {session_id} or {new_session}
-- (or empty: the source session). The form submit and messaging.thread_move both call it.
local function move_thread(user, peer, intent, operation_key, source_session)
  if type(operation_key) ~= 'string' or operation_key == '' then fail('invalid_input', 'An operation key is required') end
  local kind, value = session_intent(intent)
  local fingerprint = 'thread-move-v1/' .. part(peer.id) .. part(kind) .. part(value)
  local saved = prior_operation('thread-move/', user, operation_key)
  if saved.found then return operation_result(saved, fingerprint) end
  local op_key = 'thread-move/' .. part(user) .. part(operation_key)
  local session = resolve_session(kind, value, source_session, op_key)
  local result = {navigate = 'thread/' .. peer.id}
  for _ = 1, attempts do
    local _, home_key, rev = thread_home(user, peer.id)
    -- moved: an explicit choice, which a later identity migration keeps (migrate_aliases).
    local stored = hub('hub.store.batch', {ops = {{key = home_key, if_rev = rev, value = {home_session = session, moved = true}}},
      op = {key = op_key, fingerprint = fingerprint, result = result}})
    if stored.op_exists then return operation_result(stored.op_exists, fingerprint) end
    if type(stored.revs) == 'table' then return result end
    if not stored.conflict or stored.conflict.kind ~= 'revision' then fail('operation_conflict', 'Thread move conflict; retry with the same key') end
  end
  fail('unavailable', 'The thread home changed; retry with the same key')
end

local function render_form(args)
  local context = form_context(args)
  if args.route == '/forms/thread-menu' then
    -- The thread overview: who is in the thread, then what the user can do with it.
    local peer = form_peer(args)
    local _, _, tail = thread(args.user, peer.id)
    local count = tail.frozen + #tail.ids
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

local function view_render(args)
  if args.route:sub(1, 7) == '/forms/' then
    local tree = render_form(args)
    tree.status = {state = 'blocked', kind = 'question', msg = 'Waiting for input'}
    return {tree = tree}
  end
  if args.route == gallery_route then return {tree = render_gallery()} end
  if args.route == '/panels/threads' then return {tree = render_home(args.user, args.context)} end
  return {tree = render_thread(args.user, args.route)}
end

-- The gallery shows sample messages. A new user can read them as real data, so its tab exists only
-- when the plugin arg gallery is true (hub config plugins[].args).
local gallery_tab = rex.args.gallery == true

-- declare_tabs declares conversation tabs and, if gallery_tab, the gallery.
local function declare_tabs(user)
  local counts, total = unread_counts(user)
  local _, _, archived = archived_threads(user)
  local function title(name, n) return n > 0 and (name .. ' (' .. n .. ')') or name end
  local tabs = {}
  for _, a in ipairs(peers(user)) do
    if not archived[a.id] then
      local home = thread_home(user, a.id)
      local _, _, tail = thread(user, a.id)
      local ids = tail.ids -- never empty after the first message (F1)
      if (not a.observer and (a.group or #ids > 0)) or opened_thread(user, a.id) then
        -- A thread with a composer opens as a transcript pane over the composer when the hub enables
        -- it (spikes/04-scrollback). A read-only direct thread has no composer: it keeps one view.
        tabs[#tabs + 1] = {key = 'thread/' .. a.id, title = title(thread_title(user, a), a.observer and 0 or (counts[a.id] or 0)), route = '/thread/' .. a.id,
          session_id = home, revision = a.observer and '' or (ids[#ids] or ''), status = not a.observer and unread_status(counts[a.id] or 0) or nil,
          layout = not a.readonly and 'transcript' or nil}
      end
    end
  end
  if gallery_tab then tabs[#tabs + 1] = {key = 'gallery', title = 'Gallery', route = gallery_route} end
  hub('hub.ui.tabs', {tabs = tabs})
end

-- A tab rename changes this user's thread title. It does not rename the participant.
local function view_rename(args)
  local peer = thread_peer(args.route, args.user)
  if type(args.title) ~= 'string' then fail('invalid_input', 'title must be text') end
  local title = args.title:match('^%s*(.-)%s*$')
  if title == '' then fail('invalid_input', 'A thread title must not be empty') end
  local key = 'thread-title/' .. part(args.user) .. part(peer.id)
  local operation
  if args.operation_key ~= nil then
    if type(args.operation_key) ~= 'string' or args.operation_key == '' then fail('invalid_input', 'An operation key is required') end
    local fingerprint = 'thread-rename-v1/' .. part(peer.id) .. part(title)
    local saved = prior_operation('rename/', args.user, args.operation_key)
    if saved.found then return operation_result(saved, fingerprint) end
    operation = {key = 'rename/' .. part(args.user) .. part(args.operation_key), fingerprint = fingerprint, result = {title = title}}
  end
  for _ = 1, attempts do
    local record = get({key})[key]
    if not operation and record.rev ~= '0' and record.value.title == title then return {title = title} end
    local stored = hub('hub.store.batch', {ops = {{key = key, if_rev = record.rev, value = {title = title}}}, op = operation})
    if stored.op_exists then return operation_result(stored.op_exists, operation.fingerprint) end
    if type(stored.revs) == 'table' then return {title = title} end
    if not stored.conflict or stored.conflict.kind ~= 'revision' then fail('internal', 'Invalid rename result') end
  end
  fail('conflict', 'Thread title changed; retry the rename')
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
  if args.route == gallery_route then return gallery_action(args) end
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
  if args.route == '/panels/threads' or args.route == gallery_route or args.route:sub(1, 7) == '/forms/' then return {acked = 0} end
  local peer = thread_peer(args.route, args.user)
  if peer.observer then return {acked = 0} end
  local _, _, unread = mailbox(args.user)
  local keys = {}
  for id in pairs(unread) do keys[#keys + 1] = 'message/' .. id end
  if #keys == 0 then return {acked = 0} end
  local ids = {}
  for _, record in pairs(get(keys)) do
    local m = record.value
    if type(m) == 'table' and ((peer.group and m.to == peer.id) or (not peer.group and m.to == args.user and m.from == peer.id)) then
      ids[#ids + 1] = m.id
    end
  end
  if #ids > 0 then ack(args.user, {ids = ids}) end
  return {acked = #ids}
end

local function view_draft_save(args)
  if args.route == gallery_route then return gallery_draft_save(args) end
  local peer = thread_peer(args.route, args.user)
  if peer.readonly then fail('refused', 'This direct thread is read-only') end
  if type(args.text) ~= 'string' or type(args.base_revision) ~= 'string' then fail('invalid_input', 'text and base_revision are required') end
  local key = draft(args.user, peer.id)
  local op_key = 'draft/' .. part(args.user) .. part(args.operation_key)
  local fingerprint = 'draft-v1/' .. part(args.route) .. part(args.base_revision) .. part(args.text)
  -- The store writes the committed draft revision into the saved result (result_revs), so a
  -- replay after a lost reply returns exactly what the first execution produced.
  local stored = hub('hub.store.batch', {
    ops = {{key = key, value = {text = args.text}, if_rev = args.base_revision}},
    op = {key = op_key, fingerprint = fingerprint, result = {text = args.text}, result_revs = {draft_revision = key}},
  })
  if stored.op_exists then
    if stored.op_exists.fingerprint ~= fingerprint then fail('operation_conflict', 'Save key already has different content') end
    return stored.op_exists.result
  end
  if stored.conflict then
    if stored.conflict.kind == 'operation' then fail('operation_conflict', 'Save key already has different content') end
    fail('draft_conflict', 'The draft changed in another view')
  end
  return {draft_revision = stored.revs[key], text = args.text}
end

-- A user joins an observed group in the same transaction as the first message.
-- Earlier mail keeps its original delivery list and never enters the user's mailbox.
-- ui_recipients returns the targets, the groups guard, the delivery backfill ops, and the tail
-- that the backfill read ({key, rev, tail}, or nil): the send batch guards that same revision.
local function ui_recipients(user, peer)
  local g, rev, groups = group(peer.id)
  if user ~= 'user' or not g then return recipients(user, peer.id) end
  local ops, read = {}, nil
  if not is_member(g, user) then
    if not rev then fail('refused', 'The user cannot join this group') end
    local ids
    read, ids = with_chain(user, peer.id, function(key, tail_rev, tail, segment)
      return {key = key, rev = tail_rev, tail = tail}, chain_ids(tail, segment)
    end)
    for _, id in ipairs(ids) do
      local message = get({'message/' .. id})['message/' .. id].value
      if type(message) ~= 'table' then fail('internal', 'Thread references a missing message') end
      if not message.recipients then
        local key = 'delivery/' .. part(id)
        local delivery = get({key})[key]
        if delivery.rev == '0' then
          local audience = {}
          for _, member in ipairs(g.members) do if member ~= message.from then audience[#audience + 1] = member end end
          ops[#ops + 1] = {key = key, if_rev = '0', value = {ids = audience}}
        end
      end
    end
    g.members[#g.members + 1] = user
  end
  local targets = {}
  for _, id in ipairs(g.members) do if id ~= user then targets[#targets + 1] = id end end
  return targets, rev and {key = 'groups', if_rev = rev, value = {groups = groups}} or nil, ops, read
end

local function view_send(args)
  if args.route == gallery_route then return gallery_send(args) end
  local peer = thread_peer(args.route, args.user)
  if peer.readonly then fail('refused', 'This direct thread is read-only') end
  if type(args.text) ~= 'string' or args.text == '' or type(args.draft_revision) ~= 'string' then
    fail('invalid_input', 'text and draft_revision are required')
  end
  local user = args.user
  local id = 'send/' .. part(user) .. part(args.operation_key)
  local fingerprint = 'view-send-v1/' .. part(args.route) .. part(args.draft_revision) .. part(args.text)
  local function replay(saved)
    if normalized_fingerprint(saved.fingerprint) ~= normalized_fingerprint(fingerprint) then fail('operation_conflict', 'Send key already has different content') end
    return saved.result -- includes the draft revision that the send transaction produced
  end
  local saved = hub('hub.store.op', {key = id})
  if saved.found == true then return replay(saved) end
  local message = {id = id, from = user, to = peer.id, body = args.text, at = os.date('!%Y-%m-%dT%H:%M:%SZ')}
  admit(message)
  local result = {message_id = id, cleared_draft_revision = args.draft_revision}
  for _ = 1, attempts do
    local draft_key, draft_rev, draft_text = draft(user, peer.id)
    if draft_rev ~= args.draft_revision or draft_text ~= args.text then
      fail('draft_conflict', 'The saved draft differs from the text to send')
    end
    -- Freeze first. A group join then reads the chain for its backfill and guards that tail read.
    local prepared = {prepare_tail(user, peer.id, id)}
    local targets, guard, membership_ops, read = ui_recipients(user, peer)
    message.recipients = targets
    local ops = membership_ops or {}
    ops[#ops + 1] = {key = 'message/' .. id, value = message, if_rev = '0'}
    if guard then ops[#ops + 1] = guard end
    for _, to in ipairs(targets) do
      local box_key, box_rev, ids = mailbox(to)
      ids[id] = true
      ops[#ops + 1] = {key = box_key, value = {ids = ids}, if_rev = box_rev}
      ops[#ops + 1] = {notify = {agent = to, pending = true}}
    end
    if not read then read = {key = prepared[1], rev = prepared[2], tail = prepared[3]} end
    local thread_key, thread_rev, tail = read.key, read.rev, read.tail
    tail.ids[#tail.ids + 1] = id
    ops[#ops + 1] = {key = thread_key, value = tail_value(tail), if_rev = thread_rev}
    ops[#ops + 1] = {key = draft_key, value = {text = ''}, if_rev = draft_rev}
    local stored = hub('hub.store.batch', {
      ops = ops,
      op = {key = id, fingerprint = fingerprint, result = result, result_revs = {draft_revision = draft_key}},
    })
    if stored.op_exists then return replay(stored.op_exists) end
    if stored.conflict then
      if stored.conflict.kind == 'operation' then fail('operation_conflict', 'Send key already has different content') end
      if stored.conflict.key == draft_key then fail('draft_conflict', 'The draft changed in another view') end
      -- A mailbox or thread changed: try again.
    elseif type(stored.revs) == 'table' then
      return {message_id = id, cleared_draft_revision = args.draft_revision, draft_revision = stored.revs[draft_key]}
    end
  end
  fail('unavailable', 'Mailbox changed; retry with the same operation key')
end

local actions = {
  {name = 'messaging.send', kind = 'client', title = 'Send a message',
    description = 'Send a message to an agent, to "user" (the human), or to the group "team" (everyone else). Choose a key before sending. After an unknown outcome, retry the same key and content. Set reply_to to acknowledge the message you answer. Set reply_expected=false for an informational message. Use ack for routine receipts. Limits: body at most 16384 bytes encoded as JSON, key at most 200 bytes, reply_to at most 512 bytes, and the whole message must fit one read page (48 KB).',
    args = {type = 'object', properties = {
      to = {type = 'string', minLength = 1}, body = {type = 'string', minLength = 1}, key = {type = 'string', minLength = 1},
      reply_to = {type = 'string', minLength = 1}, reply_expected = {type = 'boolean'}
    }, required = {'to', 'body', 'key'}, additionalProperties = false}},
  {name = 'messaging.read', kind = 'client', title = 'Read messages',
    description = 'Read your unacknowledged messages. Reading does not acknowledge them. Optional thread filters by recipient/group ID. Pass next_cursor as since to get later arrivals; keep a cursor per filter. Omit since for recovery. A reply holds at most 48 KB: if more is true, call again with since = next_cursor. An older message larger than one reply arrives with a prefix of its body, truncated = true and body_bytes (the full body size). If even its other fields do not fit, it arrives as {cursor, id, metadata_too_large = true, bytes}; if its ID does not fit either, id_prefix and id_bytes replace id, and that message cannot be acknowledged. An empty list can appear as {}.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, since = {type = 'string', pattern = '^(0|[1-9][0-9]*)$'}}, additionalProperties = false}},
  {name = 'messaging.ack', kind = 'client', title = 'Acknowledge messages',
    description = 'Acknowledge handled messages without sending a receipt reply. Safe to retry. An empty list changes nothing.',
    args = {type = 'object', properties = {ids = {type = 'array', items = {type = 'string', minLength = 1}}},
      required = {'ids'}, additionalProperties = false}},
  {name = 'messaging.thread_list', kind = 'client', title = 'List threads',
    description = 'List your direct and group threads with unread counts. Set include_archived=true to include archived threads.',
    args = {type = 'object', properties = {include_archived = {type = 'boolean'}}, additionalProperties = false}},
  {name = 'messaging.thread_create', kind = 'client', title = 'Create a thread',
    description = 'Create a thread with yourself and selected roster members. The home defaults to your current session. Set session_id for an open session or new_session for a new name. An existing direct thread keeps its home. Retry with the same key and content.',
    args = {type = 'object', properties = {members = {type = 'array', items = {type = 'string', minLength = 1}}, title = {type = 'string'}, session_id = {type = 'string', minLength = 1}, new_session = {type = 'string', minLength = 1}, key = {type = 'string', minLength = 1}},
      required = {'members', 'key'}, additionalProperties = false}},
  {name = 'messaging.history', kind = 'client', title = 'Read thread history',
    description = 'Read a page of thread history, newest messages first. Current group members can read all history. This does not acknowledge or backfill unread mail. Default 20 messages, maximum 50. A page holds at most 48 KB, so it can hold fewer messages; next_before is set when older messages exist. An older message larger than one page arrives as in messaging.read: a body prefix with truncated = true and body_bytes, or a metadata_too_large marker. A thread whose ID is too long for one page fails with thread_id_too_large. Pass next_before as before only when you need older context.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, before = {type = 'string', pattern = '^[1-9][0-9]*$'}, limit = {type = 'integer', minimum = 1, maximum = 50}},
      required = {'thread'}, additionalProperties = false}},
  {name = 'messaging.thread_archive', kind = 'client', title = 'Archive or restore a thread',
    description = 'Archive a thread for yourself without deleting history or drafts or changing delivery. Set archived=false to restore. Choose a key and retry with the same content after an unknown outcome.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, archived = {type = 'boolean'}, key = {type = 'string', minLength = 1}},
      required = {'thread', 'key'}, additionalProperties = false}},
  {name = 'messaging.thread_rename', kind = 'client', title = 'Rename a thread',
    description = 'Set your title of a thread. Other participants keep their own titles. Choose a key and retry with the same content after an unknown outcome.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, title = {type = 'string', minLength = 1}, key = {type = 'string', minLength = 1}},
      required = {'thread', 'title', 'key'}, additionalProperties = false}},
  {name = 'messaging.thread_members', kind = 'client', title = 'Change thread members',
    description = 'Set the members of a group thread that you are in (you stay a member). New members can read full history; old messages do not become unread for them. For a direct thread, a larger selection creates a new group and returns its id. The team group cannot change. Choose a key and retry with the same content after an unknown outcome.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, members = {type = 'array', items = {type = 'string', minLength = 1}}, key = {type = 'string', minLength = 1}},
      required = {'thread', 'members', 'key'}, additionalProperties = false}},
  {name = 'messaging.thread_move', kind = 'client', title = 'Move a thread to a session',
    description = 'Set the Rex session where the thread opens for you. Set session_id for an open session or new_session for a new name; with neither, your current session. Choose a key and retry with the same content after an unknown outcome.',
    args = {type = 'object', properties = {thread = {type = 'string', minLength = 1}, session_id = {type = 'string', minLength = 1}, new_session = {type = 'string', minLength = 1}, key = {type = 'string', minLength = 1}},
      required = {'thread', 'key'}, additionalProperties = false}}
}
local exports = {}
for _, action in ipairs(actions) do exports[#exports + 1] = action.name end
-- View actions: only the hub calls them. They are not exported to agents.
local view_handlers = {['view.open'] = function(args)
  if args.user ~= 'user' then fail('refused', 'Only the user opens a UI thread') end
  local peer = thread_peer(args.route, args.user)
  remember_thread_open(args.user, peer.id)
  declare_tabs(args.user)
  return {}
end, ['view.history'] = function(args)
  -- A page of messages older than args.before, for the transcript pane.
  if type(args.before) ~= 'string' or args.before == '' then fail('invalid_input', 'before is required') end
  local messages, has_more = history_page(args.user, thread_peer(args.route, args.user), args.before, page_budget)
  return {messages = messages, has_more = has_more}
end, ['view.rename'] = view_rename, ['view.render'] = view_render, ['view.action'] = view_action,
  ['view.draft.save'] = view_draft_save, ['view.send'] = view_send, ['view.seen'] = view_seen,
  ['hub.changed'] = function(args)
    if args.what == 'agents' then declare_tabs('user') end
    return {}
  end}
local view_args = {type = 'object', properties = {route = {type = 'string'}, user = {type = 'string'}}, required = {'route', 'user'}}
for name in pairs(view_handlers) do
  actions[#actions + 1] = {name = name, kind = 'client', title = name,
    args = name == 'hub.changed' and {type = 'object', properties = {what = {type = 'string'}}, required = {'what'}} or view_args}
end
-- Only the hub can assert the original caller for a forwarded public action.
actions[#actions + 1] = {name = 'hub.forward', kind = 'client', title = 'Forward an agent action',
  args = {type = 'object', properties = {action = {type = 'string'}, args = {type = 'object'}, requester_pid = {type = 'integer'}},
    required = {'action', 'args', 'requester_pid'}, additionalProperties = false}}
rex.call('client.keymap', {actions = actions})
local registration = hub('hub.register', {plugin = 'messaging', instance_id = instance_id, exports = exports,
  commands = {{id = 'new_thread', title = 'New Thread…', description = 'Start a conversation with agents', keywords = {'message', 'conversation'}, route = '/forms/new-thread', action = 'messaging.thread_create'},
    {id = 'threads', title = 'Threads…', description = 'List all threads, with this session first', keywords = {'message', 'conversation'}, surface = 'panel', landing = true, route = '/panels/threads', user_only = 'navigation'}}})
if type(registration.generation) ~= 'string' then fail('internal', 'Missing hub generation') end
-- Spike 3 has one UI user. Each conversation has one tab.
local ui_user = 'user'
refresh_participants()
migrate_aliases()
declare_tabs(ui_user)
rex.on('client_perform_requested', function(ctx, ev)
  local call_id = ev.call_id
  local ok, result = pcall(function()
    if ev.action == 'hub.forward' then
      if not ev.requester or ev.requester.client_id ~= hub_id then fail('refused', 'Only the hub forwards agent actions') end
      local forwarded = ev.args or {}
      local exported = false
      for _, name in ipairs(exports) do if name == forwarded.action then exported = true end end
      if not exported then fail('refused', 'The forwarded action is not exported') end
      if type(forwarded.requester_pid) ~= 'number' or forwarded.requester_pid <= 0 or forwarded.requester_pid % 1 ~= 0 then
        fail('invalid_input', 'A positive requester PID is required')
      end
      ev = {action = forwarded.action, args = forwarded.args,
        requester = {principal = {kind = 'peer', pid = forwarded.requester_pid}}}
    end
    refresh_participants()
    migrate_aliases()
    local args = ev.args or {}
    if view_handlers[ev.action] then
      if not ev.requester or ev.requester.client_id ~= hub_id then fail('refused', 'Only the hub calls view actions') end
      return view_handlers[ev.action](args)
    end
    local agent, source_session = identify(ev)
    if type(args) ~= 'table' then fail('refused', 'Arguments must be an object') end
    if ev.action == 'messaging.send' then return send(agent, args) end
    if ev.action == 'messaging.read' then return read(agent, args) end
    if ev.action == 'messaging.history' then return history(agent, args) end
    if ev.action == 'messaging.thread_list' then return thread_list(agent, args) end
    if ev.action == 'messaging.thread_create' then return thread_create(agent, args, source_session) end
    if ev.action == 'messaging.thread_archive' then return thread_archive(agent, args) end
    if ev.action == 'messaging.thread_rename' then return thread_rename(agent, args) end
    if ev.action == 'messaging.thread_members' then return thread_members(agent, args, source_session) end
    if ev.action == 'messaging.thread_move' then return thread_move(agent, args, source_session) end
    if ev.action == 'messaging.ack' then return ack(agent, args) end
    fail('not_supported', 'Unknown messaging action')
  end)
  if ok and (ev.action == 'messaging.send' or ev.action == 'messaging.ack'
    or ev.action == 'messaging.thread_create' or ev.action == 'messaging.thread_archive'
    or ev.action == 'messaging.thread_rename' or ev.action == 'messaging.thread_members' or ev.action == 'messaging.thread_move'
    or ev.action == 'view.rename' or ev.action == 'view.action' or ev.action == 'view.send' or ev.action == 'view.seen') then
    local tabs_ok, tabs_error = pcall(declare_tabs, ui_user)
    if not tabs_ok then ok = false; result = tabs_error end
  end
  if ok then
    rex.call('client.reply', {call_id = call_id, result = result})
  else
    local failure = type(result) == 'table' and result or {code = 'internal', message = tostring(result)}
    rex.call('client.reply', {call_id = call_id, error = failure})
  end
end)
rex.call('client.set_label', {label = 'lazyrex-plugin:messaging'})
