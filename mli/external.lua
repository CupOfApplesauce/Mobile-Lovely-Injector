-- Mobile Lovely Injector: external (public-folder) mod loading.
--
-- The LÖVE save directory lives under /sdcard/Android/data/<pkg>/... which, on
-- locked-down devices, no file manager can write to. With All-files-access
-- granted, the app CAN read public folders like Download/. This module makes
-- the user's mods (in a public folder) usable by the mod loader, preferring a
-- real folder so mods can be organized in one place without re-zipping:
--
--   1. FOLDER via FFI (mli.osfs): list/read a real directory such as
--      Download/Mods/ directly. Works on any LÖVE because Balatro is LuaJIT.
--      Returned as a dedicated fs adapter + absolute mod root.
--   2. FOLDER via love.filesystem.mountFullPath (LÖVE 12+): mounts the folder
--      at the virtual "Mods" path.
--   3. ZIP: a single Download/Mods.zip (or BalatroMods.zip) read with io.open
--      and mounted from memory (LÖVE 11+).
--
-- resolve() returns a table describing what to use:
--   { mode = "folder"|"zip"|"none", source, method,
--     mod_fs = <adapter>|nil,   -- nil means "use love.filesystem"
--     mod_roots = { ... }|nil,
--     err, tried = { ... } }

local log = require("mli.log")

local M = {}

M.MOUNT_POINT = "Mods"

-- Real-folder candidates (absolute). "Mods" first per user preference, then the
-- older "BalatroMods" name for back-compat, under Download then Documents.
M.FOLDER_CANDIDATES = {
  "/storage/emulated/0/Download/Mods",
  "/storage/emulated/0/Download/BalatroMods",
  "/storage/emulated/0/Documents/Mods",
  "/storage/emulated/0/Documents/BalatroMods",
  "/sdcard/Download/Mods",
}

M.ZIP_CANDIDATES = {
  "/storage/emulated/0/Download/Mods.zip",
  "/storage/emulated/0/Download/BalatroMods.zip",
  "/storage/emulated/0/Documents/Mods.zip",
  "/storage/emulated/0/Documents/BalatroMods.zip",
  "/sdcard/Download/Mods.zip",
}

local function read_binary(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end
M._read_binary = read_binary

-- Try strategy 1: a real folder via FFI.
local function try_folder_ffi(result)
  local ok, osfs = pcall(require, "mli.osfs")
  if not ok or not osfs.available() then return nil end
  local fs = osfs.adapter()
  for _, dir in ipairs(M.FOLDER_CANDIDATES) do
    result.tried[#result.tried + 1] = dir
    if fs.is_dir(dir) and #fs.list(dir) > 0 then
      result.mode, result.source, result.method = "folder", dir, "ffi"
      result.mod_fs, result.mod_roots = fs, { dir }
      log.info("using external mods folder (ffi): %s", dir)
      return true
    end
  end
  return nil
end

-- Try strategy 2: a real folder via love.filesystem.mountFullPath (LÖVE 12+).
local function try_folder_mountfullpath(result)
  local lf = love and love.filesystem
  if not (lf and lf.mountFullPath) then return nil end
  for _, dir in ipairs(M.FOLDER_CANDIDATES) do
    local ok, mounted = pcall(lf.mountFullPath, dir, M.MOUNT_POINT, "read")
    if ok and mounted then
      result.mode, result.source, result.method = "folder", dir, "mountFullPath"
      result.mod_roots = { M.MOUNT_POINT } -- mod_fs nil => use love.filesystem
      log.info("mounted external mods folder (mountFullPath): %s", dir)
      return true
    end
  end
  return nil
end

-- Try strategy 3: a zip mounted from memory (LÖVE 11+).
local function try_zip(result)
  local lf = love and love.filesystem
  if not lf then return nil end
  for _, zip in ipairs(M.ZIP_CANDIDATES) do
    result.tried[#result.tried + 1] = zip
    local bytes = read_binary(zip)
    if bytes then
      local ok_fd, fd = pcall(lf.newFileData, bytes, "balatromods.zip")
      if not (ok_fd and fd) then
        result.err = "newFileData failed for " .. zip .. ": " .. tostring(fd)
        return nil
      end
      local ok_m, mounted = pcall(lf.mount, fd, M.MOUNT_POINT)
      if ok_m and mounted then
        M._mounted_data = fd -- keep alive while mounted
        result.mode, result.source, result.method = "zip", zip, "zip"
        result.mod_roots = { M.MOUNT_POINT } -- mod_fs nil => use love.filesystem
        log.info("mounted external mods zip: %s", zip)
        return true
      else
        result.err = "mount failed for " .. zip .. ": " .. tostring(mounted)
        return nil
      end
    end
  end
  return nil
end

-- Resolve where mods come from. See header for the returned shape.
function M.resolve()
  local result = { mode = "none", tried = {} }
  if not (love and love.filesystem) then
    result.err = "love.filesystem unavailable"
    return result
  end
  if try_folder_ffi(result) then return result end
  if try_folder_mountfullpath(result) then return result end
  if try_zip(result) then return result end
  result.err = result.err or
    "no Mods folder or Mods.zip found in Download/Documents"
  return result
end

-- Diagnostic: report what's readable and why, distinguishing 'No such file'
-- (wrong path/name) from 'Permission denied' (scoped storage). Returns strings.
function M.read_probe()
  local out = {}
  local ok_osfs, osfs = pcall(require, "mli.osfs")
  out[#out + 1] = "FFI dir listing: " .. ((ok_osfs and osfs.available()) and "yes" or "no")
  local mfp = (love and love.filesystem and love.filesystem.mountFullPath) and true or false
  out[#out + 1] = "mountFullPath (LOVE12+): " .. (mfp and "yes" or "no")
  -- folders
  if ok_osfs and osfs.available() then
    local fs = osfs.adapter()
    for _, dir in ipairs(M.FOLDER_CANDIDATES) do
      if fs.is_dir(dir) then
        out[#out + 1] = "[DIR " .. #fs.list(dir) .. "] " .. dir
      end
    end
  end
  -- zips
  for _, p in ipairs(M.ZIP_CANDIDATES) do
    local f, err = io.open(p, "rb")
    if f then f:close(); out[#out + 1] = "[READ OK] " .. p
    else out[#out + 1] = "[no] " .. p .. "  (" .. tostring(err) .. ")" end
  end
  return out
end

return M
