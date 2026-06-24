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

-- Raw references to the Lua loaders, captured before we hook the globals.
-- Internal compilation MUST use these so that (a) we never re-patch source we
-- have already patched, and (b) hooking the global `load`/`loadstring` cannot
-- recurse back into the injector.
local raw_load = _G.load
local raw_loadstring = _G.loadstring or _G.load

local injector = {}

injector.VERSION = "0.3.1"
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

-- ---- thread-aware patching ----------------------------------------------
-- LÖVE threads run in their OWN Lua state, where our loader hooks are not
-- installed -- so a thread that does love.thread.newThread('engine/X.lua')
-- loads the UNPATCHED X.lua and misses every mod patch (native lovely avoids
-- this by hooking at the C loadbuffer level, which is shared across states).
-- Balatro's sound/save/http managers are threads, and Steamodded patches all
-- three (e.g. mod sound playback). We rewrite newThread calls that take a
-- literal file path so the thread loads our PATCHED source instead. The global
-- MLI_thread_chunk (installed in init) returns a FileData of the patched file.
local function rewrite_thread_creators(source)
  if not source:find("newThread", 1, true) then return source end
  return (source:gsub("love%.thread%.newThread(%b())", function(args)
    local inner = args:sub(2, -2)
    local trimmed = (inner:gsub("^%s+", ""):gsub("%s+$", ""))
    if trimmed:match("^'[^']+%.lua'$") or trimmed:match('^"[^"]+%.lua"$') then
      return ("love.thread.newThread((MLI_thread_chunk and MLI_thread_chunk(%s)) or %s)")
        :format(inner, inner)
    end
    return "love.thread.newThread" .. args
  end))
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

-- Public dump: write a couple of key patched files to a public folder (via
-- io.*) so they can be inspected on locked-down devices. Used for debugging
-- mod integration; only fires for a small allowlist to keep it cheap.
local PUBLIC_DUMP = { ["game.lua"] = "BalatroMLI_dump_game.lua",
                      ["main.lua"] = "BalatroMLI_dump_main.lua" }
local PUBLIC_DUMP_DIRS = { "/storage/emulated/0/Download/", "/storage/emulated/0/Documents/", "/sdcard/Download/" }
local function public_dump(target, source)
  local name = PUBLIC_DUMP[target]
  if not name then return end
  for _, dir in ipairs(PUBLIC_DUMP_DIRS) do
    local f = io.open(dir .. name, "w")
    if f then f:write(source); f:close(); log.info("dumped %s -> %s%s", target, dir, name); return end
  end
end

-- ---- core patch application ----------------------------------------------
-- Reads, patches, and compiles a single file. Returns chunk, err (mirroring
-- love.filesystem.load's contract). Falls back to the original loader when
-- there is nothing to do or something goes wrong.
-- Cache path for a patched target (flattened so no subdirs are needed).
local function cache_path(target)
  if not state.cache_dir then return nil end
  return state.cache_dir .. "/" .. (target:gsub("[/\\]", "__"))
end

-- Try to load a target's patched source from the cache. Returns chunk or nil.
local function load_from_cache(target, path)
  local cp = cache_path(target)
  if not cp or not (love and love.filesystem) then return nil end
  local ok, cached = pcall(function() return love.filesystem.read(cp) end)
  if not (ok and cached) then return nil end
  local chunk = raw_loadstring(cached, "@" .. path)
  if chunk then
    log.info("cache hit: %s", target)
    return chunk
  end
  return nil -- corrupt/stale cache entry: fall through to re-patch
end

local function write_cache(target, patched)
  local cp = cache_path(target)
  if not cp or not (love and love.filesystem and love.filesystem.write) then return end
  pcall(function() love.filesystem.write(cp, patched) end)
end

local function load_patched(path)
  local target = normalize_path(path)
  local patches = state.patches_by_target[target]
  if not patches then
    return state.orig_load(path)
  end

  -- Fast path: reuse the patched file from a previous boot.
  local cached_chunk = load_from_cache(target, path)
  if cached_chunk then return cached_chunk end

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

  -- Make any threads this file spawns load patched code too (see above).
  patched = rewrite_thread_creators(patched)

  log.info("patched %s (%d patch set)", target, #patches)
  local chunk, err = raw_loadstring(patched, "@" .. path)
  if not chunk then
    -- A patch produced invalid Lua. Rather than discard ALL patches for this
    -- file (which would drop critical ones like Steamodded's init injection),
    -- re-apply patch-by-patch keeping only those that stay compilable.
    log.warn("patched %s did not compile (%s); re-applying patches individually",
             target, tostring(err))
    patched = engine.apply_safe(target, source, patches, { vars = state.vars },
                                function(s) return (raw_loadstring(s)) end)
    patched = rewrite_thread_creators(patched)
    chunk, err = raw_loadstring(patched, "@" .. path)
  end

  if state.dump then pcall(dump_patched, target, patched) end
  pcall(public_dump, target, patched)

  if not chunk then
    log.error("compile error in patched %s even after safe re-apply: %s", target, tostring(err))
    return state.orig_load(path)
  end
  write_cache(target, patched)        -- speed up the next boot
  -- First boot patches ~30 files (some huge); reclaim each file's source,
  -- patched text and engine scratch before requiring the next so peak memory
  -- stays low on memory-tight devices. The compiled `chunk` is returned and
  -- survives. Skipped if a host opts out (tests).
  patched, source = nil, nil
  if collectgarbage then collectgarbage("collect") end
  return chunk
end

-- Patch a chunk identified by its (load/loadstring) chunk name. Frameworks
-- like Steamodded compile their own source via `load(src, '=[SMODS _ "..."]')`
-- rather than love.filesystem.load, so the only handle we get on those files is
-- the chunk name. Native lovely matches chunk names at the C loadbuffer level;
-- we approximate it by matching the name against our patch targets. Mirrors
-- lovely's `needs_patching` (it strips a leading '@' before comparing). Returns
-- the (possibly patched) source string; non-matching chunks pass through.
local function patch_by_chunkname(src, chunkname)
  if type(src) ~= "string" or type(chunkname) ~= "string" then return src end
  local patches = state.patches_by_target[chunkname]
  if not patches then
    local stripped = chunkname:gsub("^@", "")
    patches = state.patches_by_target[stripped]
  end
  if not patches then return src end
  local ok, patched = pcall(engine.apply, chunkname, src, patches, { vars = state.vars })
  if not ok then
    log.error("failed to patch chunk %s: %s", chunkname, tostring(patched))
    return src
  end
  if not raw_loadstring(patched, chunkname) then
    -- a patch produced invalid Lua; keep only the patches that stay compilable
    patched = engine.apply_safe(chunkname, src, patches, { vars = state.vars },
                                function(s) return (raw_loadstring(s)) end)
  end
  log.info("patched chunk %s (%d patch set)", chunkname, #patches)
  pcall(public_dump, chunkname, patched)
  return patched
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
  state.searcher = lovely_searcher
  -- insert after package.preload (index 1) so preload still wins
  table.insert(searchers, 2, lovely_searcher)

  -- 3) Wrap the global load/loadstring so chunks that frameworks compile
  --    themselves (Steamodded's src/*.lua, mod files loaded via `load`) are
  --    patched by chunk name. Non-matching chunks are passed straight through.
  state.orig_global_load = _G.load
  _G.load = function(chunk, chunkname, ...)
    if type(chunk) == "string" then chunk = patch_by_chunkname(chunk, chunkname) end
    return state.orig_global_load(chunk, chunkname, ...)
  end
  if _G.loadstring then
    state.orig_global_loadstring = _G.loadstring
    _G.loadstring = function(s, chunkname)
      if type(s) == "string" then s = patch_by_chunkname(s, chunkname) end
      return state.orig_global_loadstring(s, chunkname)
    end
  end
end

-- Restore the original loaders. Used by the shim's fallback so that, if the
-- injector errors mid-boot, the unmodified game runs TRULY clean -- otherwise
-- our hook would keep applying mod patches to files (e.g. cardarea.lua) while
-- the mod that defines their globals (e.g. SMODS) never initialized, crashing
-- the "unmodified" fallback.
function injector.uninstall_hooks()
  if state.orig_load and love and love.filesystem then
    love.filesystem.load = state.orig_load
  end
  if state.orig_global_load then _G.load = state.orig_global_load; state.orig_global_load = nil end
  if state.orig_global_loadstring then _G.loadstring = state.orig_global_loadstring; state.orig_global_loadstring = nil end
  local searchers = package.loaders or package.searchers
  if state.searcher and searchers then
    for i, s in ipairs(searchers) do
      if s == state.searcher then table.remove(searchers, i); break end
    end
    state.searcher = nil
  end
end

-- ---- module patches ------------------------------------------------------
-- A module patch's source can itself be patched: lovely lets other patches
-- target the injected module via the chunk name `=[lovely <name> "<rel>"]`.
-- We compile modules with exactly that chunk name so (a) those source patches
-- apply and (b) tracebacks read the way SMODS' crash handler expects.
local function module_source(m)
  local src = (m.read and m.read()) or state.fs.read(m.source)
  if not src then return nil, "source not found at " .. tostring(m.source) end
  local chunkname = string.format('=[lovely %s "%s"]', m.name, m.rel or m.source)
  -- Other patches can target this module's source by the same string (lovely's
  -- module chunk name, including the leading '=').
  local patches = state.patches_by_target[chunkname]
  if patches then
    local ok, patched = pcall(engine.apply, chunkname, src, patches, { vars = state.vars })
    if ok then
      src = patched
      log.debug("patched module source %s (%d patch set)", m.name, #patches)
    else
      log.error("failed to patch module %s: %s", m.name, tostring(patched))
    end
  end
  return src, chunkname
end

local function compile_module(m)
  local src, chunkname = module_source(m)
  if not src then return nil, chunkname end       -- chunkname holds the error here
  -- raw_loadstring: the module-source patches above are already applied, and
  -- this chunk name IS a patch target, so the hooked loadstring would re-patch.
  local chunk, err = raw_loadstring(src, chunkname)
  if not chunk then return nil, "compile error: " .. tostring(err) end
  return chunk
end

-- Mirror module-patch sources into the LÖVE save directory so they can be
-- `require`d from OTHER Lua states -- specifically background threads. A LÖVE
-- thread is a fresh state with no `package.preload`, and (after it does
-- `require("love.filesystem")`) it can only resolve `require` through
-- love.filesystem's search path, which includes the save dir but NOT our
-- external mods folder. Steamodded registers libs like `json` only into the
-- main state's preload, so a mod's networking/worker thread doing
-- `require("json")` would fail. Writing those modules' source to the save dir
-- (write dir) lets such requires resolve. The main state still uses
-- package.preload (it has priority), so this only affects fresh states.
local function mirror_modules_to_savedir(modules)
  if not (love and love.filesystem and love.filesystem.write) then return end
  for _, m in ipairs(modules) do
    if m.name then
      local path = (m.name:gsub("%.", "/")) .. ".lua"
      local src = module_source(m)
      if src then
        local dir = path:match("^(.*)/[^/]+$")
        if dir and love.filesystem.createDirectory then pcall(love.filesystem.createDirectory, dir) end
        pcall(love.filesystem.write, path, src)
      end
    end
  end
end

-- Register all module patches into package.preload (lazy). Modules that other
-- modules require during load_now must already be here, so we register all
-- before executing any load_now module.
local function register_modules(modules)
  for _, m in ipairs(modules) do
    if not m.name or not m.source then
      log.warn("skipping malformed module patch")
    else
      package.preload[m.name] = function(...)
        local chunk, err = compile_module(m)
        if not chunk then
          error(("[mli] module '%s': %s"):format(m.name, tostring(err)))
        end
        return chunk(...)
      end
      log.debug("registered module '%s' from %s", m.name, m.source)
    end
  end
end

-- Execute `load_now` modules immediately, in priority order, BEFORE main.lua --
-- this is how SMODS' preflight runs and creates the SMODS global. Errors
-- propagate so a failed preflight surfaces (and the shim falls back safely).
local function run_load_now(modules)
  for _, m in ipairs(modules) do
    if m.load_now and m.name then
      log.info("load_now: executing module '%s'", m.name)
      require(m.name)
    end
  end
end

-- ---- lovely compatibility shim -------------------------------------------
-- Steamodded and lovely-aware mods do `require "lovely"` and expect the native
-- injector's API. We provide a pure-Lua equivalent backed by our patch engine.
-- `apply_patches(filename, code)` is the important one: SMODS calls it to patch
-- code it loads itself (mod files, shaders), so those get patched too.
local function install_lovely_shim(mod_dir)
  if mod_dir and not mod_dir:match("/$") then mod_dir = mod_dir .. "/" end
  local lovely = {
    version = "0.9.0",                  -- reported to mods; not the native build
    mod_dir = mod_dir or "Mods/",
    reload_patches = function() return true end,
    apply_patches = function(filename, code)
      if type(code) ~= "string" then return code end
      local target = normalize_path(filename or "")
      local patches = state.patches_by_target[target]
      if not patches then return code end
      local ok, patched = pcall(engine.apply, target, code, patches, { vars = state.vars })
      return ok and patched or code        -- assert()-safe: always non-nil
    end,
    set_var = function(name, value)
      if name then state.vars[name] = value end
    end,
    remove_var = function(name)
      local had = name ~= nil and state.vars[name] ~= nil
      if name then state.vars[name] = nil end
      return had
    end,
  }
  injector.lovely = lovely
  package.preload["lovely"] = function() return lovely end
  log.debug("registered lovely shim (mod_dir=%s)", tostring(lovely.mod_dir))
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

  -- Decide where mods come from. By default the love.filesystem save-dir
  -- "Mods". On device we prefer a public folder (Download/Mods) the user can
  -- actually reach. Skipped in test mode (when a custom fs adapter is given).
  local mod_fs = state.fs
  local mod_roots = opts.mod_roots or injector.DEFAULT_MOD_ROOTS
  injector.mount_info = { mode = "none" }
  if love and love.filesystem and not opts.fs and opts.mount_external ~= false then
    local ok, external = pcall(require, "mli.external")
    if ok then
      local r = external.resolve()
      injector.mount_info = r
      if r.mode ~= "none" then
        mod_fs = r.mod_fs or state.fs          -- nil => mods are in love.filesystem
        mod_roots = r.mod_roots or mod_roots
        log.info("external mods: %s via %s (%s)", r.mode, tostring(r.source), tostring(r.method))
      else
        log.info("no external mods: %s", tostring(r.err))
      end
    end
  end

  local result = mod_loader.load(mod_fs, mod_roots)
  state.patches_by_target = result.patches_by_target
  state.vars = result.vars
  state.dump = result.dump or opts.dump or false

  -- Installed globally so rewritten love.thread.newThread(path) calls can fetch
  -- a PATCHED copy of the thread's source (threads run in their own Lua state
  -- without our hooks). Returns a FileData of the patched file, or nil to let
  -- the caller fall back to the original path.
  _G.MLI_thread_chunk = function(path)
    if type(path) ~= "string" then return nil end
    local target = normalize_path(path)
    local patches = state.patches_by_target[target]
    if not patches then return nil end
    local source = state.fs.read(path)
    if not source then return nil end
    local ok, patched = pcall(engine.apply, target, source, patches, { vars = state.vars })
    if not ok or type(patched) ~= "string" then return nil end
    if not raw_loadstring(patched, "@" .. path) then
      patched = engine.apply_safe(target, source, patches, { vars = state.vars },
                                  function(s) return (raw_loadstring(s)) end)
    end
    patched = rewrite_thread_creators(patched)   -- in case the thread spawns threads
    log.info("thread chunk: serving patched %s (%d patches)", target, #patches)
    if love and love.filesystem and love.filesystem.newFileData then
      local ok2, fd = pcall(love.filesystem.newFileData, patched, path)
      if ok2 and fd then return fd end
    end
    return patched
  end

  -- Patched-file cache: first boot patches and writes results to the save dir;
  -- later boots load the patched files directly (turning a multi-minute boot
  -- into seconds). Keyed by the mod-set signature AND a hash of the engine
  -- source, so the cache invalidates automatically both when mods change and
  -- when MLI itself is updated (otherwise an engine fix wouldn't take effect
  -- until the mods happened to change).
  if love and love.filesystem and opts.cache ~= false then
    local code = 5381
    for _, m in ipairs({ "mli/patch_engine.lua", "mli/regex.lua", "mli/toml.lua",
                         "mli/mod_loader.lua", "mli/glob.lua", "mli/injector.lua" }) do
      local s = state.fs.read(m)
      if s then for k = 1, #s do code = (code * 33 + s:byte(k)) % 4294967296 end end
    end
    state.cache_dir = string.format("mli/cache/%s_%s_%08x",
      injector.VERSION, tostring(result.signature), code)
    -- LÖVE's love.filesystem.write does not reliably create intermediate
    -- directories on Android, so make the cache dir up front or writes (and
    -- thus the whole cache) silently no-op.
    if love.filesystem.createDirectory then
      pcall(love.filesystem.createDirectory, state.cache_dir)
    end
    log.info("patch cache: %s", state.cache_dir)
  end

  local target_count = 0
  for _ in pairs(state.patches_by_target) do target_count = target_count + 1 end
  log.info("discovered %d mod(s): %s", #result.mods, table.concat(result.mods, ", "))
  log.info("collected patches for %d target file(s); %d module patch(es)",
           target_count, #result.module_patches)

  -- Structured stats for the status popup / callers.
  injector.stats = {
    mods = result.mods,
    mod_count = #result.mods,
    targets = target_count,
    modules = #result.module_patches,
    mount = injector.mount_info,
  }

  -- Human-readable one-screen summary (used by the on-device diagnostic popup).
  local mount_line
  if injector.mount_info.mode and injector.mount_info.mode ~= "none" then
    mount_line = "mods source: " .. tostring(injector.mount_info.source)
  else
    mount_line = "mods source: none (make Download/Mods/ or Mods.zip)"
  end
  injector.summary = table.concat({
    mount_line,
    "mods (" .. #result.mods .. "): " ..
      (#result.mods > 0 and table.concat(result.mods, ", ") or "(none found)"),
    "files patched: " .. target_count,
    "module patches: " .. #result.module_patches,
  }, "\n")

  -- Order matters for Steamodded's preflight: the lovely shim and loader hooks
  -- must be live, and all module patches registered, BEFORE we execute any
  -- load_now module (preflight requires "lovely", "SMODS.nativefs", etc.).
  install_lovely_shim(mod_roots[1])

  if love and love.filesystem then
    install_hooks()
  else
    log.warn("love.filesystem unavailable; loader hooks not installed (test mode?)")
  end

  register_modules(result.module_patches)
  mirror_modules_to_savedir(result.module_patches)  -- make mod libs (json, ...) requireable from threads
  run_load_now(result.module_patches)

  state.initialized = true
end

-- injector.run() loads, patches, and executes the original main.lua. Returns
-- whatever the original main.lua returns.
function injector.run()
  if not state.fs.exists(injector.ORIGINAL_MAIN) then
    error("[mli] " .. injector.ORIGINAL_MAIN .. " not found. Was the installer run?")
  end
  log.info("loading original main from %s", injector.ORIGINAL_MAIN)

  -- Fast path: reuse the patched main.lua from a previous boot.
  local cached = load_from_cache("main.lua", "main.lua")
  if cached then return cached() end

  local source = state.fs.read(injector.ORIGINAL_MAIN)
  if not source then
    error("[mli] failed to read " .. injector.ORIGINAL_MAIN)
  end

  -- Patches authored against "main.lua" must apply to the original main body,
  -- even though it now lives at a different path.
  local patches = state.patches_by_target["main.lua"]
  if patches then
    local ok, patched = pcall(engine.apply, "main.lua", source, patches, { vars = state.vars })
    if ok and patched and raw_loadstring(patched) then
      source = patched
      log.info("applied %d patch(es) to main.lua", #patches)
    elseif ok and patched then
      log.warn("patched main.lua did not compile; re-applying patches individually")
      source = engine.apply_safe("main.lua", source, patches, { vars = state.vars },
                                 function(s) return (raw_loadstring(s)) end)
    else
      log.error("failed to patch main.lua: %s", tostring(patched))
    end
    if state.dump then pcall(dump_patched, "main.lua", source) end
  end
  pcall(public_dump, "main.lua", source)

  local chunk, err = raw_loadstring(source, "@main.lua")
  if not chunk then
    error("[mli] compile error in main.lua: " .. tostring(err))
  end
  write_cache("main.lua", source)     -- speed up the next boot
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
