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
do
  -- TOML multiline literal where content ends in quotes: up to two ' may
  -- precede the closing ''' (SMODS uses this, e.g. `pattern = '''x = '''''`).
  -- Regression for the create_text_input/profile-menu crash.
  local doc = toml.parse([==[
[a]
p = '''args.current_prompt_text = '''''
q = '''text ~= '''''
plain = '''hello'''
]==])
  check("trailing 2-quote content kept", doc.a.p == "args.current_prompt_text = ''", "["..tostring(doc.a.p).."]")
  check("trailing 1-quote-pair content kept", doc.a.q == "text ~= ''", "["..tostring(doc.a.q).."]")
  check("plain multiline literal unaffected", doc.a.plain == "hello", "["..tostring(doc.a.plain).."]")
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
do
  -- before/after must preserve the WHOLE match, not just the first group
  local out = engine.apply("x.lua", "abc\n", {
    { kind = "regex", pattern = "a(?<x>b)c", position = "after", payload = "X" },
  }, {})
  check("regex after keeps full match", out:find("abc\nX") ~= nil, out)
end
do
  -- $0 (whole), $1 (numbered) and $name all resolve
  local out = engine.apply("x.lua", "b\n", {
    { kind = "regex", pattern = "(?<x>b)", position = "at", payload = "[$0][$1][$x]" },
  }, {})
  check("regex $0/$1/$name resolve", out:find("%[b%]%[b%]%[b%]") ~= nil, out)
end
do
  -- an unresolved $ref is stripped so no stray '$' breaks compilation
  local out = engine.apply("x.lua", "b\n", {
    { kind = "regex", pattern = "b", position = "at", payload = "v=[$nope]" },
  }, {})
  check("unresolved $ref stripped (no literal $)", out:find("%$") == nil and out:find("v=%[%]") ~= nil, out)
end
do
  -- apply_safe keeps compilable patches and drops a syntax-breaking one
  local function compile(s) return (loadstring(s)) end
  local src = "X=1\n"
  local kept = engine.apply_safe("x.lua", src, {
    { kind = "copy", position = "append", payload = "Y=2" },
    { kind = "copy", position = "append", payload = "Z=@@@ invalid lua @@@" },
    { kind = "copy", position = "append", payload = "W=3" },
  }, {}, compile)
  check("apply_safe result compiles", compile(kept) ~= nil, kept)
  check("apply_safe kept the good patches", kept:find("Y=2") and kept:find("W=3"))
  check("apply_safe dropped the broken patch", kept:find("Z=@@@") == nil)
end
do
  -- lazy quantifier *? maps to Lua's lazy '-' and matches shortest
  local lp = engine._regex_to_lua("a.*?b")
  check("lazy *? becomes '-'", lp:find("%-") ~= nil, lp)
  local out = engine.apply("x.lua", "aXbYb\n", {
    { kind = "regex", pattern = "a(?<mid>.*?)b", position = "at", payload = "[$mid]" },
  }, {})
  check("lazy captures shortest (X not XbY)", out:find("%[X%]") ~= nil and out:find("%[XbY%]") == nil, out)
end
do
  -- counted repetition {n,m} expands correctly
  local p23 = engine._regex_to_lua("ab{2,3}c")
  check("{2,3} compiles + matches 2", ("abbc"):find(p23) ~= nil, p23)
  check("{2,3} matches 3", ("abbbc"):find("^" .. p23) ~= nil)
  check("{2,3} rejects 1", ("abc"):find("^" .. p23) == nil)
  local p3 = engine._regex_to_lua("x{3}")
  check("{3} needs exactly 3", ("xxx"):find("^" .. p3) ~= nil and ("xx"):find("^" .. p3) == nil)
end
do
  -- '.' does not cross newlines (PCRE semantics)
  local pat = engine._regex_to_lua("a.b")
  check("'.' excludes newline", ("a\nb"):find(pat) == nil and ("axb"):find(pat) ~= nil, pat)
end
do
  -- a malformed/unsupported patch is skipped without aborting the others
  local src = "keep\nTARGET\n"
  local out, stats = engine.apply("x.lua", src, {
    { kind = "regex", pattern = "a|b", position = "after", payload = "NOPE" }, -- alternation: skipped
    { kind = "pattern", pattern = "TARGET", position = "after", payload = "APPLIED" },
  }, {})
  check("good patch still applies after a skipped one", out:find("APPLIED") ~= nil, out)
  check("skipped patch did not inject", out:find("NOPE") == nil)
  check("stats report a skip", stats.skipped >= 1, stats and stats.skipped)
end

do
  -- root_capture: position applies relative to a named group inside the match,
  -- not the whole match. SMODS uses this heavily; '$name' and 'name' both work.
  -- 'at' replaces just the group:
  local out = engine.apply("x.lua", "anim = Sprite(0,0, ATLAS['x'], pos)\n", {
    { kind = "regex", pattern = "anim = Sprite\\(0,0, (?<atlas>ATLAS\\['x'\\]), pos\\)",
      position = "at", root_capture = "atlas", payload = "get(y) or ATLAS['x']" },
  }, {})
  check("root_capture 'at' replaces only the group",
    out:find("anim = Sprite(0,0, get(y) or ATLAS['x'], pos)", 1, true) ~= nil, out)
  -- zero-width group as an insertion point with position 'after' and '$' prefix:
  local out2 = engine.apply("x.lua", "AAA\nMID\nBBB\n", {
    { kind = "regex", pattern = "AAA\n(?<root>)[\\s\\S]*BBB", position = "after",
      root_capture = "$root", payload = "INS" },
  }, {})
  check("root_capture zero-width 'after' inserts at marker", out2:find("AAA\nINS", 1, true) ~= nil, out2)
  check("root_capture keeps the rest of the match", out2:find("MID") ~= nil and out2:find("BBB") ~= nil, out2)
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
-- lovely compatibility shim (required by Steamodded)
-- ---------------------------------------------------------------------------
section("lovely shim")
do
  check("lovely registered in package.preload", package.preload["lovely"] ~= nil)
  local lovely = require("lovely")
  check("lovely.version present", type(lovely.version) == "string")
  check("lovely.mod_dir present", type(lovely.mod_dir) == "string" and lovely.mod_dir ~= "")
  check("lovely.reload_patches() truthy", lovely.reload_patches() == true)
  -- apply_patches runs the engine on the given code for that target
  local patched = lovely.apply_patches("game.lua", "function G.init()\n    self_SPEEDFACTOR = 1\nend\n")
  check("apply_patches injects mod patch", patched:find("MOD_PATCH_MARKER") ~= nil, patched)
  -- assert()-safety: unknown target returns code unchanged (never nil)
  local same = lovely.apply_patches("no_such_file.lua", "abc")
  check("apply_patches returns code for unpatched target", same == "abc")
  check("apply_patches never returns nil", lovely.apply_patches("x", "y") ~= nil)
  -- vars
  lovely.set_var("TESTVAR", "1")
  check("set_var then remove_var reports existed", lovely.remove_var("TESTVAR") == true)
  check("remove_var on missing returns false", lovely.remove_var("NOPE") == false)
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
-- external.lua: candidate ordering and binary read
-- ---------------------------------------------------------------------------
section("external mod bundle loader")
do
  local external = require("mli.external")
  check("mount point is Mods", external.MOUNT_POINT == "Mods")
  check("folder candidates prefer Download/Mods", external.FOLDER_CANDIDATES[1] == "/storage/emulated/0/Download/Mods")
  check("zip candidates include Download/Mods.zip", (function()
    for _, p in ipairs(external.ZIP_CANDIDATES) do
      if p == "/storage/emulated/0/Download/Mods.zip" then return true end
    end
    return false
  end)())
  -- back-compat: BalatroMods names still accepted
  check("folder candidates still include BalatroMods", (function()
    for _, p in ipairs(external.FOLDER_CANDIDATES) do
      if p:find("/BalatroMods$") then return true end
    end
    return false
  end)())
  check("read_binary handles missing file", external._read_binary("/no/such/file/xyz") == nil)
  -- resolve with no love.filesystem reports gracefully
  local saved = _G.love
  _G.love = nil
  local r = external.resolve()
  check("resolve without love is graceful", r.mode == "none" and r.err ~= nil)
  _G.love = saved
end

-- ---------------------------------------------------------------------------
-- diagnostic: short popup, full log file, denied hint
-- ---------------------------------------------------------------------------
section("diagnostic popup / log")
do
  local D = require("mli.diagnostic")
  os.execute("rm -rf /tmp/mli_diag && mkdir -p /tmp/mli_diag")
  D.PUBLIC_DIRS = { "/tmp/mli_diag/" }

  -- success case: concise popup, log written
  local saved_love = _G.love
  _G.love = { filesystem = { getSaveDirectory = function() return "/save/game" end } }
  local popup = D.build_report("STATUS: injector ran OK",
    "mods source: x\nmods (1): HelloMod\nfiles patched: 2\nmodule patches: 1",
    { verbose = false })
  local nlines = select(2, (popup .. "\n"):gsub("\n", ""))
  check("popup is short (<= MAX_POPUP_LINES)", nlines <= D.MAX_POPUP_LINES, nlines)
  check("popup shows status", popup:find("injector ran OK") ~= nil)
  check("popup points to log", popup:find("Log: /tmp/mli_diag/") ~= nil)
  local lf = io.open("/tmp/mli_diag/" .. D.REPORT_NAME)
  check("log file written", lf ~= nil)
  if lf then lf:close() end

  -- verbose with a permission-denied probe: hint shows in popup, probe in file
  local external = require("mli.external")
  local orig_probe = external.read_probe
  external.read_probe = function()
    return { "mountFullPath (LOVE12+): no",
             "[no]      /storage/emulated/0/Download/BalatroMods.zip  (Permission denied)" }
  end
  local popup2 = D.build_report("STATUS: injector ran OK",
    "mods source: none\nmods (0): (none found)", { verbose = true })
  local nlines2 = select(2, (popup2 .. "\n"):gsub("\n", ""))
  check("verbose popup still short", nlines2 <= D.MAX_POPUP_LINES, nlines2)
  check("popup shows All-files-access hint", popup2:find("All files access") ~= nil)
  check("popup does NOT dump full probe", popup2:find("mods source probe") == nil)
  local f = io.open("/tmp/mli_diag/" .. D.REPORT_NAME); local body = f:read("*a"); f:close()
  check("log file contains the probe", body:find("mods source probe") ~= nil)
  check("log file contains Permission denied detail", body:find("Permission denied") ~= nil)
  external.read_probe = orig_probe
  _G.love = saved_love
end

-- ---------------------------------------------------------------------------
-- load_now / module-source patching (runs in its own process: init is one-shot)
-- ---------------------------------------------------------------------------
section("load_now + module-source patch (subprocess)")
do
  local interp = (jit and "luajit") or "lua5.1"
  local ok = os.execute(interp .. " tests/load_now_spec.lua >/dev/null 2>&1")
  ok = (ok == true or ok == 0)
  check("load_now spec passes", ok)
end

section("patched-file cache (subprocess)")
do
  local interp = (jit and "luajit") or "lua5.1"
  local ok = os.execute(interp .. " tests/cache_spec.lua >/dev/null 2>&1")
  check("cache spec passes", ok == true or ok == 0)
end

-- ---------------------------------------------------------------------------
-- backtracking regex engine
-- ---------------------------------------------------------------------------
section("regex engine")
do
  local re = require("mli.regex")
  local function find(pat, txt)
    local c = re.compile(pat)
    if not c then return nil end
    return re.find(c, txt)
  end
  check("alternation", (function() local _,_,_,nm = find("(?<k>foo|bar)", "zzbar"); return nm and nm.k == "bar" end)())
  check("group repetition (.*\\n)* across lines", (function()
    local c = re.compile("A(.*\\n)*B"); return select(1, re.find(c, "A\nx\ny\nB")) == 1 end)())
  check("lazy named capture", (function() local _,_,_,nm = find("a(?<m>.*?)b", "aXbYb"); return nm and nm.m == "X" end)())
  check("non-capturing group", select(1, find("(?:ab)+", "ababab")) == 1)
  check("'.' excludes newline", select(1, find("a.c", "a\ncaxc")) == 4)
  -- big-input: group repetition between RARE anchors (as real SMODS patches
  -- do) must be fast on a large file.
  local big = "RAREBEGIN x\n" .. string.rep("filler middle line here\n", 4000) .. "RAREBEGIN y\nEND\n"
  local c = re.compile("RAREBEGIN (.*\\n)*RAREBEGIN ")
  local t0 = os.clock()
  local s = re.find(c, big)
  check("group repetition across a large file is fast", s ~= nil and (os.clock() - t0) < 3, os.clock() - t0)
  -- full regex_spec subprocess (covers CRT-style removal)
  local interp = (jit and "luajit") or "lua5.1"
  local ok = os.execute(interp .. " tests/regex_spec.lua >/dev/null 2>&1")
  check("regex_spec passes", ok == true or ok == 0)
end

-- ---------------------------------------------------------------------------
io.write(string.format("\n==== %d passed, %d failed ====\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
