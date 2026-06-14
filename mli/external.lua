-- Mobile Lovely Injector: external (public-folder) mod loading.
--
-- The LÖVE save directory lives under /sdcard/Android/data/<pkg>/... which, on
-- locked-down devices, no file manager can write to. But the app CAN read
-- public folders like Download/ and Documents/ via io.* (verified on device).
--
-- This module makes the user's mods (placed in a public folder) visible to the
-- normal love.filesystem-based mod loader by MOUNTING them at the virtual path
-- "Mods". Two strategies, tried in order:
--
--   1. Folder mount via love.filesystem.mountFullPath (LÖVE 12+): mounts a real
--      directory (e.g. Download/BalatroMods) directly. Best UX -- drop mod
--      folders straight in.
--   2. Zip-from-memory via io.open + love.filesystem.newFileData + .mount
--      (LÖVE 11+): the user drops a single BalatroMods.zip; we read its bytes
--      and mount the archive. Works on older LÖVE where mountFullPath is absent.
--
-- After a successful mount, love.filesystem.getDirectoryItems("Mods") lists the
-- mods, so the existing mod_loader works unchanged.

local log = require("mli.log")

local M = {}

M.MOUNT_POINT = "Mods"

-- Public folders to look in. The base name "BalatroMods" is used for both a
-- folder and a <name>.zip.
M.FOLDER_CANDIDATES = {
  "/storage/emulated/0/Download/BalatroMods",
  "/storage/emulated/0/Documents/BalatroMods",
  "/sdcard/Download/BalatroMods",
}
M.ZIP_CANDIDATES = {
  "/storage/emulated/0/Download/BalatroMods.zip",
  "/storage/emulated/0/Documents/BalatroMods.zip",
  "/sdcard/Download/BalatroMods.zip",
}

local function read_binary(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end
M._read_binary = read_binary

-- Attempt to mount external mods. Returns a result table:
--   { mounted = bool, source = string|nil, method = "folder"|"zip"|nil,
--     err = string|nil, tried = { ... } }
function M.mount()
  local lf = love and love.filesystem
  local result = { mounted = false, tried = {} }
  if not lf then
    result.err = "love.filesystem unavailable"
    return result
  end

  -- Strategy 1: real folder mount (LÖVE 12+).
  if lf.mountFullPath then
    for _, dir in ipairs(M.FOLDER_CANDIDATES) do
      result.tried[#result.tried + 1] = dir
      local ok, mounted = pcall(lf.mountFullPath, dir, M.MOUNT_POINT, "read")
      if ok and mounted then
        result.mounted, result.source, result.method = true, dir, "folder"
        log.info("mounted external mods folder: %s", dir)
        return result
      end
    end
  end

  -- Strategy 2: zip from memory (LÖVE 11+).
  for _, zip in ipairs(M.ZIP_CANDIDATES) do
    result.tried[#result.tried + 1] = zip
    local bytes = read_binary(zip)
    if bytes then
      local ok_fd, fd = pcall(lf.newFileData, bytes, "balatromods.zip")
      if not (ok_fd and fd) then
        result.err = "newFileData failed for " .. zip .. ": " .. tostring(fd)
        return result
      end
      local ok_m, mounted = pcall(lf.mount, fd, M.MOUNT_POINT)
      if ok_m and mounted then
        -- Keep a reference so the FileData isn't garbage-collected while mounted.
        M._mounted_data = fd
        result.mounted, result.source, result.method = true, zip, "zip"
        log.info("mounted external mods zip: %s", zip)
        return result
      else
        result.err = "mount failed for " .. zip .. ": " .. tostring(mounted)
        return result
      end
    end
  end

  result.err = "no BalatroMods folder or BalatroMods.zip found in Download/Documents"
  return result
end

return M
