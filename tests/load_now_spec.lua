package.path = "./?.lua;" .. package.path

-- in-memory fs + fake love
local FS = {}
local function dirp(p) if FS[p]~=nil then return false end for k in pairs(FS) do if k:sub(1,#p+1)==p.."/" then return true end end return false end
local function list(p) local s,o={},{} for k in pairs(FS) do if k:sub(1,#p+1)==p.."/" then local c=k:sub(#p+2):match("^([^/]+)") if c and not s[c] then s[c]=true o[#o+1]=c end end end table.sort(o) return o end
_G.love = { filesystem = {
  read=function(p) return FS[p] end,
  load=function(p) local c=FS[p]; if not c then return nil,"nf" end return loadstring(c,"@"..p) end,
  getInfo=function(p) if FS[p]~=nil then return {type="file"} end if dirp(p) then return {type="directory"} end return nil end,
  getDirectoryItems=list, write=function(p,d) FS[p]=d return true end, append=function(p,d) FS[p]=(FS[p] or "")..d return true end, createDirectory=function() return true end,
  getSaveDirectory=function() return "/save/game" end,
}}
local fs = { read=function(p) return FS[p] end, exists=function(p) return FS[p]~=nil or dirp(p) end, is_dir=dirp, list=list }

FS["mli/main_original.lua"] = "MAIN_OK = (MYMOD and MYMOD.path) and true or false\n"
-- A mod mirroring SMODS preflight: load_now module whose source is patched to
-- inject the patch_dir, setting MYMOD.path.
FS["Mods/TestSM/lovely.toml"] = table.concat({
  '[manifest]','version="1.0.0"','priority=-11','',
  '[[patches]]','[patches.module]','source="pf/core.lua"','name="TestSM.core"','before="main.lua"','load_now=true','',
  '[[patches]]','[patches.pattern]',
  'target = \'=[lovely TestSM.core "pf/core.lua"]\'',
  "pattern = \"local lovely_path = false\"", 'position="at"',
  'payload = """local lovely_path = [[{{lovely_hack:patch_dir}}/]]"""',
}, "\n")
FS["Mods/TestSM/pf/core.lua"] = table.concat({
  "MYMOD = {}",
  "local lovely_path = false",
  "MYMOD.path = assert(lovely_path, 'not found')",
}, "\n")

local injector = require("mli.injector")
injector.init({ fs = fs, mod_roots = { "Mods" }, log_level = "error" })

-- load_now should have executed TestSM.core during init, setting MYMOD.path
assert(MYMOD ~= nil, "load_now module did not execute (MYMOD nil)")
print("MYMOD.path =", MYMOD.path)
assert(MYMOD.path == "Mods/TestSM/", "patch_dir not injected into module source: "..tostring(MYMOD.path))

-- main.lua then sees the global set up
injector.run()
assert(MAIN_OK == true, "main.lua did not see MYMOD.path after preflight")

print("LOAD_NOW + MODULE-SOURCE PATCH + patch_dir: PASSED")
os.exit(0)
