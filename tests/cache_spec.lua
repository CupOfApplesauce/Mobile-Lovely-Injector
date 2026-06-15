package.path = "./?.lua;" .. package.path

-- Shared in-memory FS so a "second boot" sees what the first wrote (the cache).
local FS = {}
local function dirp(p) if FS[p]~=nil then return false end for k in pairs(FS) do if k:sub(1,#p+1)==p.."/" then return true end end return false end
local function list(p) local s,o={},{} for k in pairs(FS) do if k:sub(1,#p+1)==p.."/" then local c=k:sub(#p+2):match("^([^/]+)") if c and not s[c] then s[c]=true o[#o+1]=c end end end table.sort(o) return o end
local function make_love()
  return { filesystem = {
    read=function(p) return FS[p] end,
    load=function(p) local c=FS[p]; if not c then return nil,"nf" end return loadstring(c,"@"..p) end,
    getInfo=function(p) if FS[p]~=nil then return {type="file"} end if dirp(p) then return {type="directory"} end return nil end,
    getDirectoryItems=list, write=function(p,d) FS[p]=d return true end,
    append=function(p,d) FS[p]=(FS[p] or "")..d return true end, createDirectory=function() return true end,
    getSaveDirectory=function() return "/save/game" end,
  }}
end
local fs = { read=function(p) return FS[p] end, exists=function(p) return FS[p]~=nil or dirp(p) end, is_dir=dirp, list=list }

FS["mli/main_original.lua"] = "MAIN_RAN = true\n"
FS["game.lua"] = "GAME_LOADED = true\nreturn true\n"
FS["Mods/CacheMod/lovely.toml"] = table.concat({
  '[manifest]','version="1.0.0"','',
  '[[patches]]','[patches.pattern]','target="game.lua"','pattern="GAME_LOADED = true"','position="after"','payload="CACHE_MARKER = true"',
}, "\n")

local function fresh_injector()
  for _, m in ipairs({"mli.injector","mli.mod_loader","mli.patch_engine","mli.regex","mli.glob","mli.toml","mli.log","mli.external","mli.osfs","mli.diagnostic"}) do
    package.loaded[m] = nil
  end
  return require("mli.injector")
end

-- ---- first boot: patches game.lua and writes the cache ----
_G.love = make_love()
local inj1 = fresh_injector()
inj1.init({ mod_roots = { "Mods" }, log_level = "error" })
local sig_dir = inj1._state.cache_dir
assert(sig_dir, "cache_dir not set")
assert(not sig_dir:find("_nil$"), "signature is nil: " .. sig_dir)
local chunk1 = love.filesystem.load("game.lua")
assert(type(chunk1) == "function", "first load failed")
chunk1()
assert(GAME_LOADED == true, "game.lua did not run")
assert(CACHE_MARKER == true, "patch did not apply on first boot")
assert(FS[sig_dir .. "/game.lua"], "cache file was not written")
assert(FS[sig_dir .. "/game.lua"]:find("CACHE_MARKER"), "cache content not patched")
print("first boot: cache written ->", sig_dir .. "/game.lua")

-- ---- second boot: REMOVE the original game.lua so only the cache can serve it ----
FS["game.lua"] = nil
_G.GAME_LOADED, _G.CACHE_MARKER = nil, nil
_G.love = make_love()
local inj2 = fresh_injector()
inj2.init({ mod_roots = { "Mods" }, log_level = "error" })
assert(inj2._state.cache_dir == sig_dir, "signature changed between boots")
local chunk2 = love.filesystem.load("game.lua")
assert(type(chunk2) == "function", "cache miss: original gone and no cache used")
chunk2()
assert(CACHE_MARKER == true, "cached patched code did not run")
print("second boot: served from cache with original removed; marker set")

-- ---- changing the mod set changes the cache key ----
FS["Mods/CacheMod/lovely.toml"] = FS["Mods/CacheMod/lovely.toml"] .. "\n# tweak\n"
_G.love = make_love()
local inj3 = fresh_injector()
inj3.init({ mod_roots = { "Mods" }, log_level = "error" })
assert(inj3._state.cache_dir ~= sig_dir, "cache key did not change when mods changed")
print("mod change invalidates cache key:", inj3._state.cache_dir)

print("CACHE SPEC PASSED")
os.exit(0)
