-- Mobile Lovely Injector: patch engine.
--
-- Applies lovely-style patches to the *source text* of a game file before it
-- is compiled. Supports the patch kinds that can be performed as pure text
-- transforms: `pattern`, `copy`, and a best-effort `regex`. `module` patches
-- are not source transforms and are handled by the injector (registered into
-- package.preload), not here.

local glob = require("mli.glob")
local log  = require("mli.log")

local engine = {}

-- ---- helpers -------------------------------------------------------------
local function split_lines(s)
  local lines = {}
  local start = 1
  while true do
    local nl = s:find("\n", start, true)
    if not nl then
      lines[#lines + 1] = s:sub(start)
      break
    end
    lines[#lines + 1] = s:sub(start, nl - 1)
    start = nl + 1
  end
  return lines
end

local function leading_indent(line)
  return (line:match("^[ \t]*")) or ""
end

local function interpolate_vars(text, vars)
  if not vars or not text then return text end
  return (text:gsub("{{lovely:([%w_%-%.]+)}}", function(name)
    local v = vars[name]
    if v == nil then return "{{lovely:" .. name .. "}}" end
    return tostring(v)
  end))
end

-- Apply `match_indent` and `line_prepend` to a payload block.
local function format_payload(payload, indent, line_prepend)
  if (not indent or indent == "") and (not line_prepend or line_prepend == "") then
    return payload
  end
  local prefix = (line_prepend or "") .. (indent or "")
  local out = {}
  for _, l in ipairs(split_lines(payload)) do
    out[#out + 1] = prefix .. l
  end
  return table.concat(out, "\n")
end

-- ---- pattern patches -----------------------------------------------------
-- target/pattern/position(before|after|at)/payload/match_indent/times
--
-- Mirrors lovely-core's pattern.rs: the pattern may span multiple lines; each
-- pattern line is trimmed and must FULLY match the corresponding trimmed
-- source line (sliding window). Substring hits do not count.
local function apply_pattern(lines, patch, vars)
  local position = patch.position or "after"
  local payload = interpolate_vars(patch.payload or "", vars)
  local match_indent = patch.match_indent
  local limit = patch.times -- nil = unlimited
  local applied = 0

  -- Split the pattern into trimmed lines (usually just one). Like Rust's
  -- str::lines(), a trailing newline does not produce a final empty line.
  local raw_pat_lines = split_lines(patch.pattern or "")
  if #raw_pat_lines > 0 and raw_pat_lines[#raw_pat_lines] == "" then
    table.remove(raw_pat_lines)
  end
  local pat_lines = {}
  for _, pl in ipairs(raw_pat_lines) do
    pat_lines[#pat_lines + 1] = glob.trim(pl)
  end
  local plen = #pat_lines
  if plen == 0 then return lines, 0 end

  local function window_matches(at)
    for k = 1, plen do
      local src = lines[at + k - 1]
      if src == nil or not glob.line_matches(src, pat_lines[k]) then
        return false
      end
    end
    return true
  end

  local out = {}
  local i, n = 1, #lines
  while i <= n do
    local hit = (limit == nil or applied < limit) and window_matches(i)
    if hit then
      applied = applied + 1
      local indent = match_indent and leading_indent(lines[i]) or ""
      local block = format_payload(payload, indent, nil)
      if position == "before" then
        out[#out + 1] = block
        for k = 0, plen - 1 do out[#out + 1] = lines[i + k] end
      elseif position == "at" then
        out[#out + 1] = block            -- replace the matched window
      else -- "after"
        for k = 0, plen - 1 do out[#out + 1] = lines[i + k] end
        out[#out + 1] = block
      end
      i = i + plen                       -- windows do not overlap
    else
      out[#out + 1] = lines[i]
      i = i + 1
    end
  end
  return out, applied
end

-- ---- regex patches (best effort) -----------------------------------------
-- Lua has no PCRE. We translate a useful subset of regex to Lua patterns so
-- the common SMODS regex patches work; anything we cannot translate is
-- skipped with a warning rather than producing a wrong result.
local function regex_to_lua(re)
  -- Reject features we cannot faithfully translate.
  if re:find("|") then return nil, "alternation unsupported" end
  if re:find("%(%?[:=!<]") and not re:find("%(%?<%w+>") then
    return nil, "lookaround/non-capturing groups unsupported"
  end

  local out = {}
  local i, n = 1, #re
  local LUA_MAGIC = { ["("] = true, [")"] = true, ["."] = true, ["%"] = true,
                      ["+"] = true, ["-"] = true, ["*"] = true, ["?"] = true,
                      ["["] = true, ["]"] = true, ["^"] = true, ["$"] = true }
  while i <= n do
    local c = re:sub(i, i)
    if c == "\\" then
      local nx = re:sub(i + 1, i + 1)
      local map = { t = "\t", n = "\n", r = "\r", s = "%s", S = "%S",
                    d = "%d", D = "%D", w = "%w", W = "%W" }
      if map[nx] then
        out[#out + 1] = map[nx]
      else
        out[#out + 1] = "%" .. nx
      end
      i = i + 2
    elseif c == "(" then
      -- named capture group (?<name>...) -> Lua capture ( ... ); plain ( ... )
      local named = re:match("^%(%?<%w+>", i)
      if named then
        out[#out + 1] = "("
        i = i + #named
      else
        out[#out + 1] = "("
        i = i + 1
      end
    elseif c == "[" then
      -- copy a character class through, translating \t etc inside it
      local j = i + 1
      local cls = { "[" }
      while j <= n and re:sub(j, j) ~= "]" do
        local cc = re:sub(j, j)
        if cc == "\\" then
          local nx = re:sub(j + 1, j + 1)
          local map = { t = "\t", n = "\n", r = "\r", s = "%s", d = "%d", w = "%w" }
          cls[#cls + 1] = map[nx] or nx
          j = j + 2
        else
          cls[#cls + 1] = cc
          j = j + 1
        end
      end
      cls[#cls + 1] = "]"
      out[#out + 1] = table.concat(cls)
      i = j + 1
    elseif c == ")" or c == "." or c == "+" or c == "*" or c == "^" or c == "$" then
      out[#out + 1] = c
      i = i + 1
    elseif c == "?" then
      out[#out + 1] = "?" -- Lua supports ? as optional for a single class
      i = i + 1
    else
      if LUA_MAGIC[c] then
        out[#out + 1] = "%" .. c
      else
        out[#out + 1] = c
      end
      i = i + 1
    end
  end
  return table.concat(out)
end

local function regex_group_names(re)
  local names = {}
  for name in re:gmatch("%(%?<(%w+)>") do
    names[#names + 1] = name
  end
  return names
end

local function apply_regex(source, patch, vars)
  local lua_pat, err = regex_to_lua(patch.pattern)
  if not lua_pat then
    log.warn("skipping regex patch (%s): %s", tostring(patch.pattern), err)
    return source, 0
  end
  local names = regex_group_names(patch.pattern)
  local position = patch.position or "at"
  local limit = patch.times
  local applied = 0
  local payload_template = patch.payload or ""

  local function replace(...)
    local caps = { ... }
    local payload = payload_template
    for idx, name in ipairs(names) do
      local val = caps[idx] or ""
      payload = payload:gsub("%$" .. name, (val:gsub("%%", "%%%%")))
      payload = payload:gsub("%${" .. name .. "}", (val:gsub("%%", "%%%%")))
    end
    payload = interpolate_vars(payload, vars)
    local block = format_payload(payload, nil, patch.line_prepend)
    local whole = caps[1] -- when no groups, %0 isn't available; use full match below
    if position == "before" then
      return block .. "\n" .. "%0"
    elseif position == "after" then
      return "%0" .. "\n" .. block
    else -- at / replace
      return block
    end
  end

  -- gsub with function gives captures; if there are no capture groups we need
  -- the whole match. Wrap the entire pattern in a capture in that case.
  local pat = lua_pat
  if #names == 0 then pat = "(" .. lua_pat .. ")" end

  local count
  source, count = source:gsub(pat, function(...)
    if limit and applied >= limit then return nil end
    applied = applied + 1
    -- position before/after need the full match; emulate with the first cap
    local caps = { ... }
    local payload = payload_template
    for idx, name in ipairs(names) do
      local val = caps[idx] or ""
      local safe = val:gsub("%%", "%%%%")
      payload = payload:gsub("%$" .. name, safe)
      payload = payload:gsub("%${" .. name .. "}", safe)
    end
    payload = interpolate_vars(payload, vars)
    local block = format_payload(payload, nil, patch.line_prepend)
    local full = caps[1]
    if position == "before" then
      return block .. "\n" .. full
    elseif position == "after" then
      return full .. "\n" .. block
    else
      return block
    end
  end, limit)
  return source, applied
end

-- ---- copy patches --------------------------------------------------------
-- position(append|prepend)/sources[]/payload. `read_source(path)` reads a file
-- relative to the owning mod directory (injected by the caller).
local function apply_copy(source, patch, vars, read_source)
  local parts = {}
  if patch.sources then
    for _, src in ipairs(patch.sources) do
      local content = read_source(src)
      if content then
        parts[#parts + 1] = content
      else
        log.warn("copy patch: could not read source '%s'", tostring(src))
      end
    end
  end
  if patch.payload then
    parts[#parts + 1] = interpolate_vars(patch.payload, vars)
  end
  local block = table.concat(parts, "\n")
  if patch.position == "prepend" then
    return block .. "\n" .. source
  else -- append (default)
    return source .. "\n" .. block
  end
end

-- ---- public API ----------------------------------------------------------
-- engine.apply(target, source, patches, opts)
--   patches: array of patch descriptors for this target. Each has a `.kind`
--            field ("pattern"|"regex"|"copy") plus the lovely fields.
--   opts.vars: table of variables for {{lovely:...}} interpolation
--   opts.read_source: function(rel_path) -> string|nil, used by copy patches
-- Returns the patched source string.
function engine.apply(target, source, patches, opts)
  opts = opts or {}
  local vars = opts.vars
  local read_source = opts.read_source or function() return nil end

  for _, patch in ipairs(patches) do
    local kind = patch.kind
    if kind == "pattern" then
      local lines = split_lines(source)
      local out, applied = apply_pattern(lines, patch, vars)
      if applied == 0 then
        log.warn("pattern patch on %s matched 0 lines: %s", target, tostring(patch.pattern))
      end
      source = table.concat(out, "\n")
    elseif kind == "regex" then
      local applied
      source, applied = apply_regex(source, patch, vars)
      if applied == 0 then
        log.debug("regex patch on %s matched 0 times", target)
      end
    elseif kind == "copy" then
      source = apply_copy(source, patch, vars, patch._read_source or read_source)
    else
      log.warn("unknown patch kind '%s' on %s", tostring(kind), target)
    end
  end
  return source
end

engine._split_lines = split_lines       -- exposed for tests
engine._regex_to_lua = regex_to_lua      -- exposed for tests
engine._interpolate = interpolate_vars   -- exposed for tests

return engine
