-- Mobile Lovely Injector: a small backtracking regex engine (pure Lua).
--
-- Lua patterns can't express several constructs that lovely/Steamodded patches
-- rely on: group repetition `(...)*`, alternation `a|b`, lazy quantifiers
-- `*?`, counted repetition `{n,m}` on groups, etc. This module implements a
-- PCRE-subset matcher so those patches apply correctly.
--
-- Supported: literals, `.` (does NOT match newline, like the Rust `regex`
-- crate's default), escapes (\t \n \r \s \S \d \D \w \W \\ and \<punct>),
-- character classes `[...]` with ranges, negation and class escapes, groups
-- `( )`, non-capturing `(?: )`, named `(?<name> )`, quantifiers `* + ? {n}
-- {n,} {n,m}` and their lazy `?` forms, alternation `|`, and anchors `^` `$`
-- (start/end of TEXT). Matching is backtracking with a step budget so a
-- pathological pattern degrades to "no match" instead of hanging.

local regex = {}

local STEP_BUDGET = 3000000

-- ---- compilation ---------------------------------------------------------
local CLASS = {
  t = "\t", n = "\n", r = "\r", f = "\f", v = "\v", a = "\a", ["0"] = "\0",
}
local function class_pred(esc)
  if esc == "s" then return function(c) return c:match("%s") ~= nil end end
  if esc == "S" then return function(c) return c:match("%s") == nil end end
  if esc == "d" then return function(c) return c:match("%d") ~= nil end end
  if esc == "D" then return function(c) return c:match("%d") == nil end end
  if esc == "w" then return function(c) return c:match("[%w_]") ~= nil end end
  if esc == "W" then return function(c) return c:match("[%w_]") == nil end end
  return nil
end

local function compile(pattern)
  local i, n = 1, #pattern
  local ngroups = 0
  local names = {}

  local parse_alt -- forward decl

  -- parse a [...] character class starting at i (pointing at '[')
  local function parse_class()
    i = i + 1 -- skip '['
    local neg = false
    if pattern:sub(i, i) == "^" then neg = true; i = i + 1 end
    local items = {}      -- list of {lo,hi} ranges or predicate functions
    local first = true
    while i <= n and (pattern:sub(i, i) ~= "]" or first) do
      first = false
      local c = pattern:sub(i, i)
      if c == "\\" then
        local e = pattern:sub(i + 1, i + 1)
        local pred = class_pred(e)
        if pred then items[#items + 1] = pred
        else items[#items + 1] = { CLASS[e] or e, CLASS[e] or e } end
        i = i + 2
      elseif pattern:sub(i + 1, i + 1) == "-" and pattern:sub(i + 2, i + 2) ~= "]" and i + 2 <= n then
        items[#items + 1] = { c, pattern:sub(i + 2, i + 2) }
        i = i + 3
      else
        items[#items + 1] = { c, c }
        i = i + 1
      end
    end
    i = i + 1 -- skip ']'
    local function match(ch)
      for _, it in ipairs(items) do
        if type(it) == "function" then
          if it(ch) then return not neg end
        elseif ch >= it[1] and ch <= it[2] then
          return not neg
        end
      end
      return neg
    end
    return { t = "cls", match = match }
  end

  local function parse_atom()
    local c = pattern:sub(i, i)
    if c == "(" then
      local cap, name
      if pattern:sub(i, i + 2) == "(?:" then
        i = i + 3
      elseif pattern:match("^%(%?<%w+>", i) then
        local nm = pattern:match("^%(%?<(%w+)>", i)
        ngroups = ngroups + 1; cap = ngroups; name = nm; names[cap] = nm
        i = i + #("(?<" .. nm .. ">")
      else
        ngroups = ngroups + 1; cap = ngroups
        i = i + 1
      end
      local alt = parse_alt()
      if pattern:sub(i, i) == ")" then i = i + 1 end
      return { t = "grp", alt = alt, cap = cap, name = name }
    elseif c == "[" then
      return parse_class()
    elseif c == "\\" then
      local e = pattern:sub(i + 1, i + 1)
      i = i + 2
      local pred = class_pred(e)
      if pred then return { t = "cls", match = pred } end
      local lit = CLASS[e] or e
      return { t = "lit", c = lit }
    elseif c == "." then
      i = i + 1
      return { t = "any" }
    elseif c == "^" then
      i = i + 1
      return { t = "bos" }
    elseif c == "$" then
      i = i + 1
      return { t = "eos" }
    else
      i = i + 1
      return { t = "lit", c = c }
    end
  end

  local function parse_quant()
    local atom = parse_atom()
    local c = pattern:sub(i, i)
    local min, max
    if c == "*" then min, max = 0, -1; i = i + 1
    elseif c == "+" then min, max = 1, -1; i = i + 1
    elseif c == "?" then min, max = 0, 1; i = i + 1
    elseif c == "{" then
      local lo, hi, rest = pattern:match("^{(%d*),(%d*)}()", i)
      local exact, rest2 = pattern:match("^{(%d+)}()", i)
      if exact then min, max = tonumber(exact), tonumber(exact); i = rest2
      elseif lo then
        min = tonumber(lo) or 0
        max = (hi == "") and -1 or tonumber(hi)
        i = rest
      end
    end
    if not min then return atom end
    local lazy = false
    if pattern:sub(i, i) == "?" then lazy = true; i = i + 1 end
    return { t = "quant", node = atom, min = min, max = max, lazy = lazy }
  end

  local function parse_seq()
    local seq = {}
    while i <= n do
      local c = pattern:sub(i, i)
      if c == "|" or c == ")" then break end
      seq[#seq + 1] = parse_quant()
    end
    return seq
  end

  parse_alt = function()
    local seqs = { parse_seq() }
    while pattern:sub(i, i) == "|" do
      i = i + 1
      seqs[#seqs + 1] = parse_seq()
    end
    return { t = "alt", seqs = seqs }
  end

  local root = parse_alt()
  if i <= n then return nil, "unparsed tail at " .. i end
  return { root = root, ngroups = ngroups, names = names }
end

-- ---- matching (continuation-passing backtracking) ------------------------
local function matcher(s)
  local steps = 0
  local caps = {}
  local match_node, match_seq, match_alt

  function match_seq(seq, idx, pos, k)
    if idx > #seq then return k(pos) end
    return match_node(seq[idx], pos, function(np)
      return match_seq(seq, idx + 1, np, k)
    end)
  end

  function match_alt(alt, pos, k)
    for _, seq in ipairs(alt.seqs) do
      local r = match_seq(seq, 1, pos, k)
      if r then return r end
    end
    return nil
  end

  function match_node(node, pos, k)
    steps = steps + 1
    if steps > STEP_BUDGET then error("regex_budget") end
    local t = node.t
    if t == "lit" then
      if s:sub(pos, pos) == node.c then return k(pos + 1) end
      return nil
    elseif t == "any" then
      local ch = s:sub(pos, pos)
      if ch ~= "" and ch ~= "\n" then return k(pos + 1) end
      return nil
    elseif t == "cls" then
      local ch = s:sub(pos, pos)
      if ch ~= "" and node.match(ch) then return k(pos + 1) end
      return nil
    elseif t == "bos" then
      if pos == 1 then return k(pos) end
      return nil
    elseif t == "eos" then
      if pos == #s + 1 then return k(pos) end
      return nil
    elseif t == "grp" then
      return match_alt(node.alt, pos, function(np)
        if node.cap then caps[node.cap] = { pos, np - 1 } end
        return k(np)
      end)
    elseif t == "quant" then
      local node2, min, max, lazy = node.node, node.min, node.max, node.lazy
      local it = node2.t
      if it == "lit" or it == "any" or it == "cls" then
        -- Single-character repetition: match iteratively rather than via
        -- per-char recursion. This makes `.*`, `[..]+`, etc. efficient and,
        -- crucially, avoids catastrophic backtracking in nested forms like
        -- `(.*\n)*` (the inner `.*` no longer backtracks char-by-char).
        local function ok_at(p)
          local ch = s:sub(p, p)
          if ch == "" then return false end
          if it == "lit" then return ch == node2.c end
          if it == "any" then return ch ~= "\n" end
          return node2.match(ch)
        end
        local maxc = 0
        local p = pos
        while (max < 0 or maxc < max) and ok_at(p) do p = p + 1; maxc = maxc + 1 end
        if maxc < min then return nil end
        if lazy then
          for cnt = min, maxc do
            steps = steps + 1; if steps > STEP_BUDGET then error("regex_budget") end
            local r = k(pos + cnt); if r then return r end
          end
        else
          for cnt = maxc, min, -1 do
            steps = steps + 1; if steps > STEP_BUDGET then error("regex_budget") end
            local r = k(pos + cnt); if r then return r end
          end
        end
        return nil
      end
      -- General path (groups). Match the sub-node greedily and ITERATIVELY,
      -- recording the end position after each repetition, then try the
      -- continuation at each count. Iterative (not recursive over the count)
      -- so a long `(.*\n)*` over thousands of lines can't overflow the stack.
      -- Each repetition takes the sub-node's greediest single match.
      local ends = { pos }
      local p = pos
      while max < 0 or (#ends - 1) < max do
        steps = steps + 1
        if steps > STEP_BUDGET then error("regex_budget") end
        local np = match_node(node2, p, function(x) return x end)
        if not np or np == p then break end
        p = np
        ends[#ends + 1] = np
      end
      local hi = #ends - 1
      if lazy then
        for cnt = min, hi do
          local r = k(ends[cnt + 1]); if r then return r end
        end
      else
        for cnt = hi, min, -1 do
          local r = k(ends[cnt + 1]); if r then return r end
        end
      end
      return nil
    end
    return nil
  end

  return {
    run = function(alt, start)
      caps = {}
      steps = 0                           -- fresh budget per start position
      local ok, e = pcall(function()
        return match_alt(alt, start, function(np) return np end)
      end)
      if not ok then return nil end       -- budget exceeded / error
      return e, caps
    end,
  }
end

-- regex.find(compiled, text, init) -> s, e, caps_array, named_map | nil
function regex.find(c, text, init)
  init = init or 1
  local m = matcher(text)
  for start = init, #text + 1 do
    local e, caps = m.run(c.root, start)
    if e then
      local arr, named = {}, {}
      for idx = 1, c.ngroups do
        local cp = caps[idx]
        local v = cp and text:sub(cp[1], cp[2]) or ""
        arr[idx] = v
        if c.names[idx] then named[c.names[idx]] = v end
      end
      return start, e - 1, arr, named
    end
  end
  return nil
end

-- regex.gsub(text, compiled, repl, limit) -> newtext, count
-- repl(whole, caps_array, named_map) -> replacement string
function regex.gsub(text, c, repl, limit)
  local out, pos, count = {}, 1, 0
  while pos <= #text + 1 do
    if limit and count >= limit then break end
    local s, e, arr, named = regex.find(c, text, pos)
    if not s then break end
    out[#out + 1] = text:sub(pos, s - 1)
    local whole = text:sub(s, e)
    out[#out + 1] = repl(whole, arr, named) or whole
    count = count + 1
    if e < s then            -- empty match: emit one char, advance
      out[#out + 1] = text:sub(s, s)
      pos = s + 1
    else
      pos = e + 1
    end
  end
  out[#out + 1] = text:sub(pos)
  return table.concat(out), count
end

regex.compile = compile
return regex
