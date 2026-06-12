-- Mobile Lovely Injector: lovely "pattern" wildcard matching.
--
-- Lovely pattern patches match a wildcard pattern against the *entire trimmed
-- line* (`*` matches any run of characters, `?` matches a single character).
-- This mirrors lovely-core's pattern.rs, which trims each source line and
-- requires WildMatch to match it fully — substring hits do NOT count.
-- Patterns may span multiple lines; each pattern line must match the
-- corresponding source line (the engine handles the windowing; here we match
-- one line against one pattern line).

local glob = {}

-- Characters that are magic in Lua patterns and must be escaped when they
-- appear literally inside a lovely pattern.
local LUA_MAGIC = "^$().%+-[]"

local function escape_literal(s)
  return (s:gsub("([" .. LUA_MAGIC:gsub("(.)", "%%%1") .. "])", "%%%1"))
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
glob.trim = trim

-- Convert a lovely glob pattern to an anchored Lua pattern string that must
-- match a whole (trimmed) line.
function glob.to_lua_pattern(pattern)
  local out = { "^" }
  local i, n = 1, #pattern
  while i <= n do
    local c = pattern:sub(i, i)
    if c == "*" then
      out[#out + 1] = ".-"
    elseif c == "?" then
      out[#out + 1] = "."
    else
      out[#out + 1] = escape_literal(c)
    end
    i = i + 1
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

-- Returns true if the trimmed `line` fully matches the (already trimmed)
-- lovely `pattern`. Plain patterns (no wildcards) use direct equality.
function glob.line_matches(line, pattern)
  local t = trim(line)
  if not pattern:find("[%*%?]") then
    return t == pattern
  end
  return t:find(glob.to_lua_pattern(pattern)) ~= nil
end

return glob
