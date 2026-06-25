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
  if type(t) ~= "string" then return nil end   -- non-string targets handled by caller
  t = t:gsub("\\", "/"):gsub("^%./", ""):gsub("^/", "")
  return t
end

-- A mod is disabled (its patches skipped) the same two ways native lovely
-- supports, both written into the mod root by Steamodded's in-game toggle:
--   * an entry in `<root>/lovely/blacklist.txt` (folder names, one per line;
--     blank lines and `#` comments ignored), and
--   * a `.lovelyignore` file inside the mod's own folder.
-- Returns a set of blacklisted folder names for one mod root.
local function read_blacklist(fs, root)
  local set = {}
  local text = fs.read(root .. "/lovely/blacklist.txt")
  if not text then return set end
  for line in (text .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\r$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then set[line] = true end
  end
  return set
end

local function mod_is_disabled(fs, mod_dir, name, blacklist)
  if blacklist[name] then return true end
  if fs.exists(mod_dir .. "/.lovelyignore") then return true end
  return false
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

  -- A patch's `target` may be a single string OR an array of paths (lovely's
  -- Target::Single / Target::Multi) -- a multi-target patch applies to EACH
  -- listed file. Emit one descriptor per target so the rest of the pipeline
  -- only ever sees a single string target. Non-string targets are skipped with
  -- a warning rather than crashing the whole loader.
  local function emit(p, kind)
    local raw = p.target
    local list = (type(raw) == "table") and raw or { raw }
    for _, tgt in ipairs(list) do
      local norm = normalize_target(tgt)
      if not norm then
        log.warn("%s patch with non-string target skipped (%s)", kind, type(tgt))
      else
        local d = {}
        for k, v in pairs(p) do d[k] = v end   -- copy so multi-targets don't share .target
        d.kind = kind
        d.target = norm
        d._priority = priority
        d._mod_dir = mod_dir                    -- for {{lovely_hack:patch_dir}}
        if kind == "copy" then d._read_source = read_source end
        out.targeted[#out.targeted + 1] = d
      end
    end
  end

  for _, entry in ipairs(patches) do
    -- each [[patches]] element holds exactly one of these sub-tables
    if entry.pattern then
      emit(entry.pattern, "pattern")
    elseif entry.regex then
      emit(entry.regex, "regex")
    elseif entry.copy then
      emit(entry.copy, "copy")
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
    mods = {},       -- names of discovered (enabled) mods
    disabled = {},   -- names of mods skipped via blacklist.txt / .lovelyignore
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
      local blacklist = read_blacklist(fs, root)
      for _, name in ipairs(fs.list(root)) do
        local mod_dir = root .. "/" .. name
        if fs.is_dir(mod_dir) then
          if mod_is_disabled(fs, mod_dir, name, blacklist) then
            out.disabled[#out.disabled + 1] = name
            log.info("mod '%s' is disabled (blacklist/.lovelyignore), skipping", name)
          else
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
  end

  -- Fold the CONTENT of files pulled in by copy/module patches into the
  -- signature too. The loop above only hashes the .toml files, but a copy
  -- patch's `sources` (e.g. a mod's bootstrap.lua) and a module patch's source
  -- are baked into the patched output and cached. Without this, editing such a
  -- source file would not change the signature, so the patched-file cache would
  -- keep serving stale output (e.g. an old menu watermark) until a .toml
  -- happened to change.
  for _, p in ipairs(out.targeted) do
    if p.kind == "copy" and p._read_source and type(p.sources) == "table" then
      for _, rel in ipairs(p.sources) do
        local c = p._read_source(rel)
        if c then hash_str(rel); hash_str(c) end
      end
    end
  end
  for _, m in ipairs(out.modules) do
    local c = m.read and m.read()
    if c then hash_str(tostring(m.source)); hash_str(c) end
  end

  out.signature = string.format("%08x", sig)

  -- Order patches exactly as lovely-core does (patch/table.rs): the kind
  -- determines the *phase*, which dominates priority. All `copy` patches are
  -- applied first, then `pattern`, then `regex`; within a phase, patches are
  -- stable-sorted by ascending priority, ties broken by discovery order. This
  -- matters because some SMODS `regex` patches only match after a sibling
  -- `pattern` patch (same priority) has already reshaped the source -- e.g. the
  -- Glass Joker scaling `pattern` must collapse a nested block before the
  -- joker_retriggers `regex` can anchor on the result.
  local function phase_rank(p)
    return p.kind == "copy" and 0 or 1            -- copy phase precedes the rest
  end
  local function kind_rank(p)
    return p.kind == "pattern" and 0 or 1         -- pattern before regex in phase 1
  end
  for idx, p in ipairs(out.targeted) do p._order = idx end
  table.sort(out.targeted, function(a, b)
    local pa, pb = phase_rank(a), phase_rank(b)
    if pa ~= pb then return pa < pb end
    if a._priority ~= b._priority then return a._priority < b._priority end
    if pa == 1 then
      local ka, kb = kind_rank(a), kind_rank(b)
      if ka ~= kb then return ka < kb end
    end
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
    disabled = out.disabled,
    signature = out.signature,
  }
end

mod_loader._normalize_target = normalize_target -- for tests
return mod_loader
