-- Mobile Lovely Injector: lovely "pattern" wildcard matching.
--
-- Lovely pattern patches match a literal string against a source line, where
-- `*` matches any run of characters and `?` matches a single character (glob
-- semantics, not regex). This converts such a pattern into a Lua pattern and
-- exposes a substring search over a single line.

local glob = {}

-- Characters that are magic in Lua patterns and must be escaped when they
-- appear literally inside a lovely pattern.
local LUA_MAGIC = "^$().%+-[]"

local function escape_literal(s)
  return (s:gsub("([" .. LUA_MAGIC:gsub("(.)", "%%%1") .. "])", "%%%1"))
end

-- Convert a lovely glob pattern to a Lua pattern string.
function glob.to_lua_pattern(pattern)
  local out = {}
  local i, n = 1, #pattern
  while i <= n do
    local c = pattern:sub(i, i)
    if c == "*" then
      out[#out + 1] = ".-"      -- non-greedy: closest match wins
    elseif c == "?" then
      out[#out + 1] = "."
    else
      out[#out + 1] = escape_literal(c)
    end
    i = i + 1
  end
  return table.concat(out)
end

-- Returns true if `line` contains a match for the lovely `pattern`.
-- Plain patterns (no wildcards) use a fast literal search.
function glob.line_matches(line, pattern)
  if not pattern:find("[%*%?]") then
    return line:find(pattern, 1, true) ~= nil
  end
  return line:find(glob.to_lua_pattern(pattern)) ~= nil
end

return glob
