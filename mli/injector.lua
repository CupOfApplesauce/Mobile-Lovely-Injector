-- Mobile Lovely Injector: runtime entry point.
--
-- This is the pure-Lua, on-device replacement for the native Lovely injector.
-- Because Android has no way to detour the LÖVE/LuaJIT runtime from the
-- outside, we instead run FIRST (via a shim main.lua written by the installer)
-- and patch game source as it is loaded:
--
--   1. init()  - discover mods, parse their lovely patches, register module
--                patches into package.preload, and hook the Lua loaders so
--                that every subsequently loaded game file is patched in place.
--   2. run()   - load the original main.lua (moved aside to
--                mli/main_original.lua by the installer), apply any main.lua
--                patches, and execute it. The real game starts here.
--
-- Supported patch kinds: pattern, copy, module, and best-effort regex.

local log        = require("mli.log")
local engine     = require("mli.patch_engine")
local mod_loader = require("mli.mod_loader")

local injector = {}

injector.VERSION = "0.1.0"
injector.ORIGINAL_MAIN = "mli/main_original.lua"
injector.DUMP_DIR = "mli/dump"

-- Candidate love.filesystem-relative roots to search for mods. The mobile
-- maker places the save directory such that these resolve under
-- .../files/save/<identity>/. We try a few common spellings.
injector.DEFAULT_MOD_ROOTS = { "Mods", "mods" }

local state = {
  initialized = false,
  fs = nil,
  patches_by_target = {},
  vars = {},
  dump = false,
  orig_load = nil,
}

-- ---- filesystem adapter --------------------------------------------------
-- Wraps love.filesystem so the rest of the code (and tests) can use a small,
-- stable interface.
local function love_fs_adapter()
  assert(love and love.filesystem, "love.filesystem is not available")
  local lf = love.filesystem
  local getInfo = lf.getInfo
  return {
    exists = function(path)
      if getInfo then return getInfo(path) ~= nil end
      return lf.exists and lf.exists(path)
    end,
    is_dir = function(path)
      if getInfo then
        local info = getInfo(path)
        return info ~= nil and info.type == "directory"
      end
      return lf.isDirectory and lf.isDirectory(path)
    end,
    read = function(path)
      local ok, content = pcall(lf.read, path)
      if ok then return content end
      return nil
    end,
    list = function(path)
      return lf.getDirectoryItems(path)
    end,
  }
end

local function normalize_path(path)
  return (path:gsub("\\", "/"):gsub("^%./", ""):gsub("^/", ""))
end

-- ---- dumping -------------------------------------------------------------
local function dump_patched(target, source)
  if not (love and love.filesystem and love.filesystem.write) then return end
  local path = injector.DUMP_DIR .. "/" .. target
  local dir = path:match("^(.*)/[^/]+$")
  if dir and love.filesystem.createDirectory then
    love.filesystem.createDirectory(dir)
  end
  love.filesystem.write(path, source)
end

-- ---- core patch application ----------------------------------------------
-- Reads, patches, and compiles a single file. Returns chunk, err (mirroring
-- love.filesystem.load's contract). Falls back to the original loader when
-- there is nothing to do or something goes wrong.
local function load_patched(path)
  local target = normalize_path(path)
  local patches = state.patches_by_target[target]
  if not patches then
    return state.orig_load(path)
  end

  local source = state.fs.read(path)
  if not source then
    log.warn("could not read %s for patching; using original", path)
    return state.orig_load(path)
  end

  local ok, patched = pcall(engine.apply, target, source, patches, {
    vars = state.vars,
  })
  if not ok then
    log.error("patch engine failed on %s: %s", target, tostring(patched))
    return state.orig_load(path)
  end

  if state.dump then
    pcall(dump_patched, target, patched)
  end

  log.debug("applied %d patch(es) to %s", #patches, target)
  local chunk, err = loadstring(patched, "@" .. path)
  if not chunk then
    log.error("compile error in patched %s: %s", target, tostring(err))
    return state.orig_load(path)
  end
  return chunk
end

-- ---- loader hooks --------------------------------------------------------
local function install_hooks()
  state.orig_load = love.filesystem.load

  -- 1) Wrap love.filesystem.load: Balatro loads many files directly through
  --    this, and (depending on LÖVE version) so does the require searcher.
  love.filesystem.load = function(path, ...)
    return load_patched(path)
  end

  -- 2) Add a high-priority require searcher that routes through our patched
  --    loader, so `require "functions/common_events"` etc. are patched even on
  --    LÖVE builds whose internal searcher captured a private load reference.
  local searchers = package.loaders or package.searchers
  local function lovely_searcher(name)
    local fname = name:gsub("%.", "/")
    for _, tmpl in ipairs({ "?.lua", "?/init.lua" }) do
      local p = tmpl:gsub("%?", fname)
      if state.fs.exists(p) then
        return love.filesystem.load(p)
      end
    end
    return ("\n\t[mli] no file for module '%s'"):format(name)
  end
  -- insert after package.preload (index 1) so preload still wins
  table.insert(searchers, 2, lovely_searcher)
end

-- ---- module patches ------------------------------------------------------
local function register_modules(modules)
  for _, m in ipairs(modules) do
    if not m.name or not m.source then
      log.warn("skipping malformed module patch")
    else
      local src = state.fs.read(m.source)
      if not src then
        log.warn("module patch '%s': source not found at %s", m.name, m.source)
      else
        package.preload[m.name] = function(...)
          local chunk, err = loadstring(src, "@" .. m.source)
          if not chunk then
            error(("[mli] module '%s' failed to compile: %s"):format(m.name, tostring(err)))
          end
          return chunk(...)
        end
        log.debug("registered module '%s' from %s", m.name, m.source)
      end
    end
  end
end

-- ---- public API ----------------------------------------------------------
-- injector.init(opts)
--   opts.fs         : optional filesystem adapter (defaults to love.filesystem)
--   opts.mod_roots  : optional list of mod root dirs (defaults to "Mods")
--   opts.log_level  : optional log level name
function injector.init(opts)
  opts = opts or {}
  if state.initialized then
    log.warn("injector.init called twice; ignoring")
    return
  end

  if opts.log_level then log.set_level(opts.log_level) end
  state.fs = opts.fs or love_fs_adapter()
  local mod_roots = opts.mod_roots or injector.DEFAULT_MOD_ROOTS

  log.info("Mobile Lovely Injector v%s starting", injector.VERSION)

  local result = mod_loader.load(state.fs, mod_roots)
  state.patches_by_target = result.patches_by_target
  state.vars = result.vars
  state.dump = result.dump or opts.dump or false

  local target_count = 0
  for _ in pairs(state.patches_by_target) do target_count = target_count + 1 end
  log.info("discovered %d mod(s): %s", #result.mods, table.concat(result.mods, ", "))
  log.info("collected patches for %d target file(s); %d module patch(es)",
           target_count, #result.module_patches)

  -- Modules must be available before the game (and main.lua) require them.
  register_modules(result.module_patches)

  if love and love.filesystem then
    install_hooks()
  else
    log.warn("love.filesystem unavailable; loader hooks not installed (test mode?)")
  end

  state.initialized = true
end

-- injector.run() loads, patches, and executes the original main.lua. Returns
-- whatever the original main.lua returns.
function injector.run()
  if not state.fs.exists(injector.ORIGINAL_MAIN) then
    error("[mli] " .. injector.ORIGINAL_MAIN .. " not found. Was the installer run?")
  end
  log.info("loading original main from %s", injector.ORIGINAL_MAIN)

  local source = state.fs.read(injector.ORIGINAL_MAIN)
  if not source then
    error("[mli] failed to read " .. injector.ORIGINAL_MAIN)
  end

  -- Patches authored against "main.lua" must apply to the original main body,
  -- even though it now lives at a different path.
  local patches = state.patches_by_target["main.lua"]
  if patches then
    local ok, patched = pcall(engine.apply, "main.lua", source, patches, { vars = state.vars })
    if ok then
      source = patched
      if state.dump then pcall(dump_patched, "main.lua", source) end
      log.info("applied %d patch(es) to main.lua", #patches)
    else
      log.error("failed to patch main.lua: %s", tostring(patched))
    end
  end

  local chunk, err = loadstring(source, "@main.lua")
  if not chunk then
    error("[mli] compile error in main.lua: " .. tostring(err))
  end
  return chunk()
end

-- Convenience: init + run in one call (used by the shim).
function injector.boot(opts)
  injector.init(opts)
  return injector.run()
end

injector._state = state              -- exposed for tests
injector._normalize_path = normalize_path
injector._love_fs_adapter = love_fs_adapter

return injector
