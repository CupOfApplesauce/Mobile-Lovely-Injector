-- Mobile Lovely Injector test suite.
-- Run from the repo root:  lua5.1 tests/run_tests.lua
--
-- Uses an in-memory filesystem and a fake `love` global so the full pipeline
-- (toml -> mod_loader -> patch_engine -> injector hooks) can run without LÖVE
-- or an Android device.

package.path = "./?.lua;" .. package.path

local passed, failed = 0, 0
local function check(name, cond, detail)
  if cond then
    passed = passed + 1
    io.write("  ok   - " .. name .. "\n")
  else
    failed = failed + 1
    io.write("  FAIL - " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or "") .. "\n")
  end
end
local function section(s) io.write("\n# " .. s .. "\n") end

-- ---------------------------------------------------------------------------
-- In-memory filesystem + fake love
-- ---------------------------------------------------------------------------
local function make_fs(files)
  return {
    files = files,
    exists = function(self, p) return self.files[p] ~= nil or self:is_dir(p) end,
  }
end

local FS -- the active in-memory file map (path -> string)

local function fs_is_dir(path)
  if FS[path] ~= nil then return false end
  for k in pairs(FS) do
    if k:sub(1, #path + 1) == path .. "/" then return true end
  end
  return false
end

local function fs_exists(path) return FS[path] ~= nil or fs_is_dir(path) end

local function fs_list(path)
  local seen, out = {}, {}
  local prefix = path .. "/"
  for k in pairs(FS) do
    if k:sub(1, #prefix) == prefix then
      local rest = k:sub(#prefix + 1)
      local child = rest:match("^([^/]+)")
      if child and not seen[child] then
        seen[child] = true
        out[#out + 1] = child
      end
    end
  end
  table.sort(out)
  return out
end

local fs_adapter = {
  exists = fs_exists,
  is_dir = fs_is_dir,
  read = function(p) return FS[p] end,
  list = fs_list,
}

-- minimal fake love.filesystem backed by FS
local function make_fake_love()
  return {
    filesystem = {
      read = function(p)
        local c = FS[p]
        if not c then return nil, "not found" end
        return c, #c
      end,
      load = function(p)
        local c = FS[p]
        if not c then return nil, "not found: " .. p end
        return loadstring(c, "@" .. p)
      end,
      getInfo = function(p)
        if FS[p] ~= nil then return { type = "file" } end
        if fs_is_dir(p) then return { type = "directory" } end
        return nil
      end,
      getDirectoryItems = fs_list,
      write = function(p, data) FS[p] = data; return true end,
      append = function(p, data) FS[p] = (FS[p] or "") .. data; return true end,
      createDirectory = function() return true end,
    },
  }
end

-- ---------------------------------------------------------------------------
-- toml parser
-- ---------------------------------------------------------------------------
section("toml parser")
local toml = require("mli.toml")
do
  local doc = toml.parse([==[
[manifest]
version = "1.0.0"
priority = -5
dump_lua = true

[vars]
greeting = "hi"

[[patches]]
[patches.pattern]
target = "game.lua"
pattern = "self.SPEEDFACTOR = 1"
position = "after"
match_indent = true
payload = '''
print("patched {{lovely:greeting}}")
'''

[[patches]]
[patches.copy]
target = "main.lua"
position = "append"
sources = ["src/core.lua", "src/extra.lua"]

[[patches]]
[patches.module]
source = "version.lua"
name = "SMODS.version"
before = "main.lua"
]==])
  check("manifest.priority parsed", doc and doc.manifest and doc.manifest.priority == -5, doc and doc.manifest and doc.manifest.priority)
  check("manifest.dump_lua parsed", doc and doc.manifest.dump_lua == true)
  check("vars parsed", doc and doc.vars and doc.vars.greeting == "hi")
  check("patches is array of 3", doc and doc.patches and #doc.patches == 3, doc and doc.patches and #doc.patches)
  check("pattern target", doc.patches[1].pattern and doc.patches[1].pattern.target == "game.lua")
  check("pattern match_indent bool", doc.patches[1].pattern.match_indent == true)
  check("multiline payload kept newline content", doc.patches[1].pattern.payload:find("print%(") ~= nil)
  check("copy sources array len 2", #doc.patches[2].copy.sources == 2, doc.patches[2].copy.sources and #doc.patches[2].copy.sources)
  check("copy source[1]", doc.patches[2].copy.sources[1] == "src/core.lua", doc.patches[2].copy.sources[1])
  check("module name", doc.patches[3].module.name == "SMODS.version")
end

-- ---------------------------------------------------------------------------
-- glob
-- ---------------------------------------------------------------------------
section("glob wildcard matching (full trimmed-line semantics)")
local glob = require("mli.glob")
check("literal match ignores indentation", glob.line_matches("  self.SPEEDFACTOR = 1", "self.SPEEDFACTOR = 1"))
check("literal match ignores trailing CR", glob.line_matches("self.SPEEDFACTOR = 1\r", "self.SPEEDFACTOR = 1"))
check("no false match", not glob.line_matches("self.OTHER = 1", "self.SPEEDFACTOR = 1"))
check("substring is NOT a match (lovely full-line)", not glob.line_matches("return foo", "return"))
check("superstring is NOT a match", not glob.line_matches("self.SPEEDFACTOR = 1 + x", "self.SPEEDFACTOR = 1"))
check("star wildcard full line", glob.line_matches("local x = foo(123)", "local x = foo(*)"))
check("star allows empty run", glob.line_matches("foo()", "foo(*)"))
check("leading star", glob.line_matches("local x = foo(123)", "*foo(123)"))
check("question wildcard", glob.line_matches("abc", "a?c"))
check("dot is literal not wildcard", not glob.line_matches("aXc", "a.c"))

-- ---------------------------------------------------------------------------
-- patch engine
-- ---------------------------------------------------------------------------
section("patch engine")
local engine = require("mli.patch_engine")
do
  local src = "function f()\n    self.SPEEDFACTOR = 1\nend\n"
  local out = engine.apply("game.lua", src, {
    { kind = "pattern", pattern = "self.SPEEDFACTOR = 1", position = "after",
      match_indent = true, payload = 'INJECTED("{{lovely:g}}")' },
  }, { vars = { g = "X" } })
  check("pattern inserts after", out:find('INJECTED%("X"%)') ~= nil, out)
  check("match_indent applied", out:find('\n    INJECTED') ~= nil, out)
  check("original line retained", out:find("self.SPEEDFACTOR = 1") ~= nil)
end
do
  local src = "A = 1\nB = 2\n"
  local out = engine.apply("x.lua", src, {
    { kind = "pattern", pattern = "B = 2", position = "before", payload = "PRE" },
  }, {})
  check("pattern before", out:find("PRE\nB = 2") ~= nil, out)
end
do
  local src = "keep1\nREPLACE_ME\nkeep2\n"
  local out = engine.apply("x.lua", src, {
    { kind = "pattern", pattern = "REPLACE_ME", position = "at", payload = "NEW" },
  }, {})
  check("pattern at replaces line", out:find("NEW") ~= nil and out:find("REPLACE_ME") == nil, out)
end
do
  local src = "base\n"
  local out = engine.apply("main.lua", src, {
    { kind = "copy", position = "append", payload = "APPENDED",
      _read_source = function(p) return "FROM:" .. p end, sources = { "a.lua" } },
  }, {})
  check("copy appends sources", out:find("FROM:a.lua") ~= nil, out)
  check("copy appends payload", out:find("APPENDED") ~= nil, out)
  check("copy keeps base first", out:find("^base") ~= nil, out)
end
do
  local src = "x\n"
  local out = engine.apply("main.lua", src, {
    { kind = "copy", position = "prepend", payload = "TOP" },
  }, {})
  check("copy prepend", out:find("^TOP") ~= nil, out)
end
do
  -- multi-line pattern (lovely sliding window)
  local src = "if a then\n    do_thing()\nend\nother()\n"
  local out = engine.apply("x.lua", src, {
    { kind = "pattern", pattern = "if a then\ndo_thing()", position = "before",
      payload = "WINDOW_HIT" },
  }, {})
  check("multiline pattern matches window", out:find("WINDOW_HIT\nif a then") ~= nil, out)
  local out2 = engine.apply("x.lua", src, {
    { kind = "pattern", pattern = "if a then\nnope()", position = "before",
      payload = "WINDOW_HIT" },
  }, {})
  check("multiline pattern needs all lines", out2:find("WINDOW_HIT") == nil)
end
do
  -- a pattern with a trailing newline must not require an empty source line
  local src = "alpha\nbeta\n"
  local out = engine.apply("x.lua", src, {
    { kind = "pattern", pattern = "alpha\n", position = "after", payload = "MID" },
  }, {})
  check("trailing newline in pattern ignored", out:find("alpha\nMID\nbeta") ~= nil, out)
end
do
  -- CRLF source: anchors still match and insertion lands after the CR line
  local src = "function f()\r\n    self.SPEEDFACTOR = 1\r\nend\r\n"
  local out = engine.apply("game.lua", src, {
    { kind = "pattern", pattern = "self.SPEEDFACTOR = 1", position = "after",
      match_indent = true, payload = "CRLF_OK()" },
  }, {})
  check("CRLF line matched", out:find("CRLF_OK%(%)") ~= nil, out)
  local chunk = loadstring(out)
  check("CRLF patched source compiles", chunk ~= nil)
end
do
  -- times cap
  local src = "x = 1\nx = 1\nx = 1\n"
  local out = engine.apply("x.lua", src, {
    { kind = "pattern", pattern = "x = 1", position = "after", payload = "Y", times = 2 },
  }, {})
  local _, count = out:gsub("Y", "")
  check("times caps matches", count == 2, count)
end
do
  -- regex translation sanity
  local lua_pat = engine._regex_to_lua("if (?<cond>x) then")
  check("regex translates to capture", lua_pat ~= nil and lua_pat:find("%(") ~= nil, lua_pat)
  local src = "if x then\n"
  local out = engine.apply("tag.lua", src, {
    { kind = "regex", pattern = "if (?<cond>x) then", position = "after",
      payload = "-- saw $cond" },
  }, {})
  check("regex captured group used", out:find("%-%- saw x") ~= nil, out)
end

-- ---------------------------------------------------------------------------
-- mod_loader + injector full pipeline
-- ---------------------------------------------------------------------------
section("mod_loader + injector pipeline")
_G.love = make_fake_love()

FS = {
  -- the game (as if extracted from the APK), original main moved aside
  ["mli/main_original.lua"] = [[
SPEEDFACTOR_HOLDER = "main ran"
require("game")
MAIN_RETURN = "MAIN_DONE"
]],
  ["game.lua"] = [[
G = {}
function G.init()
    self_SPEEDFACTOR = 1
end
return G
]],
  -- a mod with a pattern patch (game.lua), a copy patch (main.lua),
  -- and a module patch
  ["Mods/TestMod/lovely.toml"] = [==[
[manifest]
version = "1.0.0"
priority = 0

[[patches]]
[patches.pattern]
target = "game.lua"
pattern = "self_SPEEDFACTOR = 1"
position = "after"
match_indent = true
payload = "MOD_PATCH_MARKER = true"

[[patches]]
[patches.copy]
target = "main.lua"
position = "append"
payload = "MAIN_APPEND_MARKER = require('testmod.greet')"

[[patches]]
[patches.module]
source = "modules/greet.lua"
name = "testmod.greet"
before = "main.lua"
]==],
  ["Mods/TestMod/modules/greet.lua"] = [[return "hello-from-module"]],
}

local mod_loader = require("mli.mod_loader")
do
  local result = mod_loader.load(fs_adapter, { "Mods" })
  check("discovered TestMod", result.mods[1] == "TestMod", table.concat(result.mods, ","))
  check("game.lua has 1 patch", result.patches_by_target["game.lua"] and #result.patches_by_target["game.lua"] == 1)
  check("main.lua has 1 patch", result.patches_by_target["main.lua"] and #result.patches_by_target["main.lua"] == 1)
  check("1 module patch", #result.module_patches == 1)
  check("module source path bound to mod dir", result.module_patches[1].source == "Mods/TestMod/modules/greet.lua", result.module_patches[1].source)
end

local injector = require("mli.injector")
do
  injector.init({ fs = fs_adapter, mod_roots = { "Mods" }, log_level = "error" })

  -- module registered into package.preload
  check("module preload registered", package.preload["testmod.greet"] ~= nil)
  check("module loads correct value", require("testmod.greet") == "hello-from-module")

  -- love.filesystem.load was wrapped: loading game.lua should be patched
  local chunk = love.filesystem.load("game.lua")
  check("game.lua load returns chunk", type(chunk) == "function")
  local G = chunk()        -- run module body, returns G
  G.init()                 -- the pattern payload lives inside G.init
  check("game.lua patch marker present", MOD_PATCH_MARKER == true)

  -- loading an unpatched file returns the original untouched chunk
  local plain = love.filesystem.load("mli/main_original.lua")
  check("unpatched file still loadable", type(plain) == "function")

  -- Balatro requires modules with slash-style names ('engine/object'); the
  -- searcher must resolve and patch those too.
  FS["engine/object.lua"] = "ENGINE_OBJECT_LOADED = true\nreturn true\n"
  FS["Mods/TestMod/lovely2.toml"] = nil -- (no extra patches)
  local okreq = pcall(require, "engine/object")
  check("slash-style require resolves via searcher", okreq and ENGINE_OBJECT_LOADED == true)

  -- run() loads original main, applies main.lua patch (copy append), executes
  injector.run()
  check("main body executed", SPEEDFACTOR_HOLDER == "main ran")
  check("main body completed", MAIN_RETURN == "MAIN_DONE", tostring(MAIN_RETURN))
  check("main.lua copy-append executed", MAIN_APPEND_MARKER == "hello-from-module", tostring(MAIN_APPEND_MARKER))
end

-- ---------------------------------------------------------------------------
-- shipped example mod parses and yields the expected patches
-- ---------------------------------------------------------------------------
section("examples/HelloMod")
do
  local f = io.open("examples/HelloMod/lovely.toml", "r")
  check("example lovely.toml present", f ~= nil)
  if f then
    local text = f:read("*a"); f:close()
    local doc, err = toml.parse(text)
    check("example parses", doc ~= nil, err)
    if doc then
      check("example has manifest", doc.manifest and doc.manifest.version == "1.0.0")
      check("example has 3 patches", doc.patches and #doc.patches == 3, doc.patches and #doc.patches)
      check("example var banner", doc.vars and doc.vars.banner ~= nil)
      local kinds = {}
      for _, p in ipairs(doc.patches) do
        if p.module then kinds.module = true end
        if p.copy then kinds.copy = true end
        if p.pattern then kinds.pattern = true end
      end
      check("example covers module/copy/pattern", kinds.module and kinds.copy and kinds.pattern)
    end
  end
end

-- ---------------------------------------------------------------------------
io.write(string.format("\n==== %d passed, %d failed ====\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
