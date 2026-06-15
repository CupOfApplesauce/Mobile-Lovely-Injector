-- Mobile Lovely Injector: mod discovery and patch collection.
--
-- Scans one or more mod root directories for mods that ship lovely patches
-- (either a `lovely.toml` file or a `lovely/` directory of `.toml` files),
-- parses them, and produces:
--   * patches_by_target : { [target] = sorted array of patch descriptors }
--   * module_patches     : array of { name, source (absolute path), before }
--   * vars               : merged [vars] table for {{lovely:...}} interpolation
--   * dump               : true if any manifest requested dump_lua
--
-- Patch ordering follows lovely: ascending manifest `priority`, then the order
-- discovered. Each patch descriptor carries `.kind` and, for copy patches, a
-- `_read_source` closure bound to its owning mod directory.

local toml = require("mli.toml")
local log  = require("mli.log")

local mod_loader = {}

local function normalize_target(t)
  if not t then return t end
  t = t:gsub("\\", "/"):gsub("^%./", ""):gsub("^/", "")
  return t
end

-- Collect the toml patch-file paths contributed by a single mod directory.
local function mod_toml_files(fs, mod_dir)
  local files = {}
  local single = mod_dir .. "/lovely.toml"
  if fs.exists(single) then
    files[#files + 1] = single
  end
  local lovely_dir = mod_dir .. "/lovely"
  if fs.is_dir(lovely_dir) then
    for _, name in ipairs(fs.list(lovely_dir)) do
      if name:sub(-5) == ".toml" then
        files[#files + 1] = lovely_dir .. "/" .. name
      end
    end
  end
  table.sort(files) -- deterministic order within a mod
  return files
end

-- Extract patch descriptors from one parsed toml document.
local function collect_from_doc(doc, mod_dir, fs, priority, out)
  local patches = doc.patches
  if not patches then return end
  local read_source = function(rel)
    return fs.read(mod_dir .. "/" .. rel)
  end
  for _, entry in ipairs(patches) do
    -- each [[patches]] element holds exactly one of these sub-tables
    if entry.pattern then
      local p = entry.pattern
      p.kind = "pattern"
      p.target = normalize_target(p.target)
      p._priority = priority
      p._mod_dir = mod_dir          -- for {{lovely_hack:patch_dir}}
      out.targeted[#out.targeted + 1] = p
    elseif entry.regex then
      local p = entry.regex
      p.kind = "regex"
      p.target = normalize_target(p.target)
      p._priority = priority
      p._mod_dir = mod_dir
      out.targeted[#out.targeted + 1] = p
    elseif entry.copy then
      local p = entry.copy
      p.kind = "copy"
      p.target = normalize_target(p.target)
      p._priority = priority
      p._mod_dir = mod_dir
      p._read_source = read_source
      out.targeted[#out.targeted + 1] = p
    elseif entry.module then
      local m = entry.module
      local rel = m.source
      out.modules[#out.modules + 1] = {
        name = m.name,
        source = mod_dir .. "/" .. rel,
        rel = rel,                   -- relative source (for lovely target name)
        mod_dir = mod_dir,           -- owning mod dir (for patch_dir var)
        before = normalize_target(m.before),
        load_now = m.load_now and true or false,
        priority = priority,
        read = function() return read_source(rel) end, -- bound to this mod's fs
      }
    end
  end
end

-- mod_loader.load(fs, mod_roots) -> result table
function mod_loader.load(fs, mod_roots)
  local out = {
    targeted = {},   -- flat list, sorted later
    modules = {},
    vars = {},
    dump = false,
    mods = {},       -- names of discovered mods
  }

  -- Content signature of the patch set, used as a cache key so patched files
  -- are reused until the mods change. Lua 5.1 has no bitwise ops, so this is a
  -- multiply-add rolling hash (djb2-style) over each toml's path + content.
  local sig = 5381
  local function hash_str(s)
    for i = 1, #s do sig = (sig * 33 + s:byte(i)) % 4294967296 end
  end

  for _, root in ipairs(mod_roots) do
    if fs.is_dir(root) then
      for _, name in ipairs(fs.list(root)) do
        local mod_dir = root .. "/" .. name
        if fs.is_dir(mod_dir) then
          local files = mod_toml_files(fs, mod_dir)
          if #files > 0 then
            out.mods[#out.mods + 1] = name
            for _, file in ipairs(files) do
              local text = fs.read(file)
              if text then
                hash_str(file); hash_str(text)
                local doc, err = toml.parse(text)
                if not doc then
                  log.error("failed to parse %s: %s", file, tostring(err))
                else
                  local manifest = doc.manifest or {}
                  local priority = manifest.priority or 0
                  if manifest.dump_lua then out.dump = true end
                  if doc.vars then
                    for k, v in pairs(doc.vars) do out.vars[k] = v end
                  end
                  collect_from_doc(doc, mod_dir, fs, priority, out)
                  log.debug("loaded patches from %s (priority %d)", file, priority)
                end
              end
            end
          end
        end
      end
    end
  end
  out.signature = string.format("%08x", sig)

  -- Stable sort the flat patch list by ascending priority, preserving
  -- discovery order within equal priorities.
  for idx, p in ipairs(out.targeted) do p._order = idx end
  table.sort(out.targeted, function(a, b)
    if a._priority ~= b._priority then return a._priority < b._priority end
    return a._order < b._order
  end)

  -- Group by target.
  local by_target = {}
  for _, p in ipairs(out.targeted) do
    local t = p.target
    if t then
      by_target[t] = by_target[t] or {}
      table.insert(by_target[t], p)
    else
      log.warn("patch with no target skipped (kind=%s)", tostring(p.kind))
    end
  end

  -- Sort module patches by priority too.
  table.sort(out.modules, function(a, b) return (a.priority or 0) < (b.priority or 0) end)

  return {
    patches_by_target = by_target,
    module_patches = out.modules,
    vars = out.vars,
    dump = out.dump,
    mods = out.mods,
    signature = out.signature,
  }
end

mod_loader._normalize_target = normalize_target -- for tests
return mod_loader
