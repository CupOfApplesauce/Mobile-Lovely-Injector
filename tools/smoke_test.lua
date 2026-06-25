-- Mobile Lovely Injector: offline smoke test.
--
-- Dry-runs your mods against extracted game source on a PC, so you can catch
-- broken patches before installing anything on a device.
--
-- Usage:
--   lua5.1 tools/smoke_test.lua <game_src_dir> [mods_dir]
--
--   <game_src_dir>  directory containing the game's main.lua, game.lua, ...
--                   (e.g. an extracted game.love)
--   [mods_dir]      your Mods directory (default: <game_src_dir>/Mods)
--
-- For every patch target it reports: how many patches applied, how many
-- pattern/regex patches matched ZERO times (almost always a bug or a version
-- mismatch), and whether the patched file still compiles. Module patch
-- sources are compile-checked too. Exit code is non-zero if anything failed.
--
-- Run from the repo root (it needs the mli/ modules on package.path).

package.path = "./?.lua;" .. package.path

local toml       = require("mli.toml")
local engine     = require("mli.patch_engine")
local mod_loader = require("mli.mod_loader")
local log        = require("mli.log")

log.set_level("error") -- the smoke test reports zero-matches itself

local game_dir = arg[1]
if not game_dir then
  io.stderr:write("usage: lua tools/smoke_test.lua <game_src_dir> [mods_dir]\n")
  os.exit(2)
end
game_dir = game_dir:gsub("[/\\]+$", "")
local mods_dir = (arg[2] or (game_dir .. "/Mods")):gsub("[/\\]+$", "")

-- ---- disk filesystem adapter ----------------------------------------------
-- Pure Lua cannot list directories; shell out (ls on POSIX, dir on Windows).
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function is_dir(path)
  -- A directory can't be opened for read, but renaming-to-self trick is
  -- unreliable; use the shell.
  local probe = IS_WINDOWS
    and ('if exist "' .. path .. '\\*" (echo y) else (echo n)')
    or  ('[ -d "' .. path .. '" ] && echo y || echo n')
  local p = io.popen(probe)
  if not p then return false end
  local out = p:read("*l")
  p:close()
  return out == "y"
end

local function list_dir(path)
  local cmd = IS_WINDOWS and ('dir /b "' .. path .. '" 2>nul')
                          or ('ls -1 "' .. path .. '" 2>/dev/null')
  local p = io.popen(cmd)
  if not p then return {} end
  local items = {}
  for line in p:lines() do
    if line ~= "" then items[#items + 1] = line end
  end
  p:close()
  return items
end

local fs = {
  read = read_file,
  exists = function(p) return read_file(p) ~= nil or is_dir(p) end,
  is_dir = is_dir,
  list = list_dir,
}

-- ---- run --------------------------------------------------------------------
local failures, warnings = 0, 0
local function fail(fmt, ...) failures = failures + 1; print("  FAIL  " .. string.format(fmt, ...)) end
local function warn(fmt, ...) warnings = warnings + 1; print("  warn  " .. string.format(fmt, ...)) end
local function ok(fmt, ...)   print("  ok    " .. string.format(fmt, ...)) end

print("game source : " .. game_dir)
print("mods dir    : " .. mods_dir)

if not fs.exists(game_dir .. "/main.lua") then
  print("FATAL: no main.lua in " .. game_dir .. " — is this the extracted game source?")
  os.exit(2)
end
if not is_dir(mods_dir) then
  print("FATAL: mods dir not found: " .. mods_dir)
  os.exit(2)
end

local result = mod_loader.load(fs, { mods_dir })
print(string.format("\ndiscovered %d mod(s): %s", #result.mods, table.concat(result.mods, ", ")))
if #result.mods == 0 then
  print("FATAL: no mods with lovely patches found in " .. mods_dir)
  os.exit(2)
end

-- module patches: sources must exist and compile
print("\n# module patches")
for _, m in ipairs(result.module_patches) do
  local src = fs.read(m.source)
  if not src then
    fail("module '%s': source missing: %s", tostring(m.name), m.source)
  else
    local chunk, err = loadstring(src, "@" .. m.source)
    if chunk then
      ok("module '%s' compiles (%s)", m.name, m.source)
    else
      fail("module '%s' does not compile: %s", m.name, tostring(err))
    end
  end
end

-- targeted patches: apply to the real file, compile the result
print("\n# targeted patches")
-- Track per-patch match counts by intercepting log warnings? Simpler: rerun
-- pattern matching per patch via engine and inspect deltas.
local targets = {}
for t in pairs(result.patches_by_target) do targets[#targets + 1] = t end
table.sort(targets)

for _, target in ipairs(targets) do
  local patches = result.patches_by_target[target]
  local path = game_dir .. "/" .. target
  local src = fs.read(path)
  if not src then
    fail("%s: target file not found in game source (%d patch(es) will not apply)",
         target, #patches)
  else
    -- Apply one patch at a time so zero-match patches are attributable.
    local cur = src
    local zero = 0
    for pi, p in ipairs(patches) do
      local before = cur
      local applied_ok, res = pcall(engine.apply, target, cur, { p }, { vars = result.vars })
      if not applied_ok then
        fail("%s: patch #%d (%s) raised: %s", target, pi, p.kind, tostring(res))
      else
        if (p.kind == "pattern" or p.kind == "regex") and res == before then
          zero = zero + 1
          warn("%s: patch #%d (%s) matched 0 times: %s",
               target, pi, p.kind, tostring(p.pattern):sub(1, 70))
        end
        cur = res
      end
    end
    local chunk, err = loadstring(cur, "@" .. target)
    if chunk then
      ok("%s: %d patch(es) applied, %d zero-match, compiles", target, #patches, zero)
    else
      fail("%s: patched file does NOT compile: %s", target, tostring(err))
    end
  end
end

print(string.format("\n==== smoke test: %d failure(s), %d warning(s) ====", failures, warnings))
print(failures == 0
  and "Looks good. Install the APK and push these mods to the device."
  or  "Fix the failures above before installing on the device.")
os.exit(failures == 0 and 0 or 1)
