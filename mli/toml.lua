-- Mobile Lovely Injector: minimal TOML parser.
--
-- This is NOT a complete TOML implementation. It supports the subset used by
-- lovely.toml patch files:
--   * [table] and [[array.of.tables]] headers, including dotted paths that
--     descend into the last element of an array (e.g. [patches.pattern]).
--   * key = value where value is a string, integer, float, boolean, or a
--     (possibly multiline) array of those.
--   * basic strings "..." with escapes, literal strings '...', and multiline
--     basic """...""" / multiline literal '''...''' strings.
--   * # comments on their own line or trailing a value.
--
-- It returns a Lua table mirroring the document structure, or nil + error.

local toml = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---- string unescaping (basic strings) ----------------------------------
local ESCAPES = {
  ["n"] = "\n", ["t"] = "\t", ["r"] = "\r", ['"'] = '"',
  ["\\"] = "\\", ["b"] = "\b", ["f"] = "\f", ["/"] = "/",
}

local function unescape_basic(s)
  return (s:gsub("\\(.)", function(c)
    return ESCAPES[c] or ("\\" .. c)
  end))
end

-- ---- table navigation ----------------------------------------------------
-- Descend a dotted path from `root`, creating tables as needed. When a path
-- component already refers to an array of tables, descend into its LAST
-- element (TOML semantics for sub-tables under [[array]]).
local function navigate(root, parts, create_array_at_last)
  local node = root
  for idx = 1, #parts do
    local key = parts[idx]
    local is_last = (idx == #parts)
    local child = node[key]
    if child == nil then
      if is_last and create_array_at_last then
        child = { _is_array = true }
        node[key] = child
        local elem = {}
        child[#child + 1] = elem
        return elem
      else
        child = {}
        node[key] = child
      end
    end
    if child._is_array then
      if is_last and create_array_at_last then
        local elem = {}
        child[#child + 1] = elem
        return elem
      end
      child = child[#child] -- descend into last array element
    end
    if is_last and create_array_at_last then
      -- existing plain table where an array was expected: wrap it
      local arr = { _is_array = true, child }
      node[key] = arr
      local elem = {}
      arr[#arr + 1] = elem
      return elem
    end
    node = child
  end
  return node
end

local function split_dotted(path)
  local parts = {}
  for part in path:gmatch("[^%.]+") do
    parts[#parts + 1] = trim(part)
  end
  return parts
end

-- ---- value parsing -------------------------------------------------------
-- Parses a scalar (string/number/bool) from a trimmed token. Returns value.
local function parse_scalar(token)
  token = trim(token)
  if token == "" then return nil end
  local first = token:sub(1, 1)
  if first == '"' then
    return unescape_basic(token:sub(2, -2))
  elseif first == "'" then
    return token:sub(2, -2)
  elseif token == "true" then
    return true
  elseif token == "false" then
    return false
  else
    local num = tonumber(token)
    if num ~= nil then return num end
    return token -- fall back to raw (best-effort)
  end
end

-- toml.parse(text) -> table | nil, errmsg
function toml.parse(text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end

  local root = {}
  local current = root
  local i = 1
  local n = #lines

  -- Consume a multiline string starting at `lines[i]` after the opening
  -- delimiter `open` has been found at byte position `start` in lines[i].
  -- Returns value, next_line_index.
  local function read_multiline(open, line, start)
    local close = open
    local rest = line:sub(start + #open)
    -- TOML trims a leading newline immediately after the opening delimiter.
    local collected = {}
    -- check if it closes on the same line
    local close_pos = rest:find(close, 1, true)
    if close_pos then
      return rest:sub(1, close_pos - 1), i
    end
    collected[#collected + 1] = rest
    local j = i + 1
    while j <= n do
      local l = lines[j]
      local cp = l:find(close, 1, true)
      if cp then
        collected[#collected + 1] = l:sub(1, cp - 1)
        local value = table.concat(collected, "\n")
        -- strip a single leading newline per TOML spec
        value = value:gsub("^\n", "")
        return value, j
      end
      collected[#collected + 1] = l
      j = j + 1
    end
    return table.concat(collected, "\n"), n
  end

  -- Parse the value portion (right of '='). May span multiple lines.
  local function parse_value(raw)
    raw = trim(raw)
    if raw:sub(1, 3) == '"""' then
      local v, ni = read_multiline('"""', lines[i], (lines[i]:find('"""', 1, true)))
      i = ni
      return unescape_basic(v)
    elseif raw:sub(1, 3) == "'''" then
      local v, ni = read_multiline("'''", lines[i], (lines[i]:find("'''", 1, true)))
      i = ni
      return v
    elseif raw:sub(1, 1) == "[" then
      -- array (single or multi line)
      local buf = raw
      while not buf:find("%]") and i < n do
        i = i + 1
        buf = buf .. "\n" .. lines[i]
      end
      local inner = buf:match("^%[(.*)%]%s*$") or buf:match("^%[(.*)%]")
      local arr = {}
      if inner then
        -- split on commas not inside quotes
        local items, cur, q = {}, {}, nil
        local k = 1
        while k <= #inner do
          local ch = inner:sub(k, k)
          if q then
            cur[#cur + 1] = ch
            if ch == q then q = nil end
          elseif ch == '"' or ch == "'" then
            q = ch
            cur[#cur + 1] = ch
          elseif ch == "," then
            items[#items + 1] = table.concat(cur)
            cur = {}
          else
            cur[#cur + 1] = ch
          end
          k = k + 1
        end
        if #cur > 0 then items[#items + 1] = table.concat(cur) end
        for _, it in ipairs(items) do
          local s = trim(it)
          if s ~= "" then arr[#arr + 1] = parse_scalar(s) end
        end
      end
      return arr
    else
      -- scalar; strip trailing comment that is outside quotes
      local in_q, qch = false, nil
      for k = 1, #raw do
        local ch = raw:sub(k, k)
        if in_q then
          if ch == qch then in_q = false end
        elseif ch == '"' or ch == "'" then
          in_q = true; qch = ch
        elseif ch == "#" then
          raw = raw:sub(1, k - 1)
          break
        end
      end
      return parse_scalar(raw)
    end
  end

  while i <= n do
    local line = trim(lines[i])
    if line == "" or line:sub(1, 1) == "#" then
      -- skip
    elseif line:sub(1, 2) == "[[" then
      local path = line:match("^%[%[%s*(.-)%s*%]%]")
      if not path then return nil, "bad array header: " .. line end
      current = navigate(root, split_dotted(path), true)
    elseif line:sub(1, 1) == "[" then
      local path = line:match("^%[%s*(.-)%s*%]")
      if not path then return nil, "bad table header: " .. line end
      current = navigate(root, split_dotted(path), false)
    else
      local key, val = line:match("^(.-)%s*=%s*(.*)$")
      if not key then return nil, "bad line: " .. line end
      key = trim(key)
      -- strip quotes around a quoted bare key
      if key:sub(1, 1) == '"' and key:sub(-1) == '"' then
        key = unescape_basic(key:sub(2, -2))
      elseif key:sub(1, 1) == "'" and key:sub(-1) == "'" then
        key = key:sub(2, -2)
      end
      current[key] = parse_value(val)
    end
    i = i + 1
  end

  return root
end

return toml
