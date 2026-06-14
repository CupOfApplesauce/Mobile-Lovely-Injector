-- Mobile Lovely Injector: OS filesystem adapter (LuaJIT FFI).
--
-- Lua's io.* can open files but cannot list directories, and love.filesystem is
-- sandboxed to the save dir + game source. To read mods from a real public
-- folder (e.g. /storage/emulated/0/Download/Mods) we list directories with
-- POSIX opendir/readdir via LuaJIT's FFI and read files with io.open. This
-- requires the app to have read access to the path (All-files-access on
-- Android 11+); Balatro always runs on LuaJIT, so FFI is available.
--
-- Returns an fs adapter with the same interface mod_loader expects
-- (exists/is_dir/read/list), operating on ABSOLUTE OS paths.

local osfs = {}

-- Returns the FFI C namespace with dir functions declared, or nil if FFI is
-- unavailable (e.g. plain Lua during tests).
local _C
local function get_C()
  if _C ~= nil then return _C end
  local ok, ffi = pcall(require, "ffi")
  if not ok then _C = false; return nil end
  -- struct dirent layout is the same on 64-bit Linux glibc and Android bionic.
  pcall(ffi.cdef, [[
    typedef struct __dirstream MLI_DIR;
    MLI_DIR *opendir(const char *name);
    int closedir(MLI_DIR *dirp);
    struct mli_dirent {
      uint64_t d_ino;
      int64_t  d_off;
      unsigned short d_reclen;
      unsigned char d_type;
      char d_name[256];
    };
    struct mli_dirent *readdir(MLI_DIR *dirp);
  ]])
  osfs._ffi = ffi
  _C = ffi.C
  return _C
end

osfs.available = function()
  return get_C() ~= nil
end

local function ffi_is_dir(path)
  local C = get_C()
  if not C then return false end
  local ok, res = pcall(function()
    local d = C.opendir(path)
    if d == nil then return false end
    C.closedir(d)
    return true
  end)
  return ok and res
end

local function ffi_list(path)
  local C = get_C()
  if not C then return {} end
  local ffi = osfs._ffi
  local ok, res = pcall(function()
    local d = C.opendir(path)
    if d == nil then return {} end
    local out = {}
    while true do
      local e = C.readdir(d)
      if e == nil then break end
      local name = ffi.string(e.d_name)
      if name ~= "." and name ~= ".." then out[#out + 1] = name end
    end
    C.closedir(d)
    table.sort(out)
    return out
  end)
  return ok and res or {}
end

local function file_read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close(); return true end
  return false
end

-- osfs.adapter() -> fs table for mod_loader (absolute OS paths)
function osfs.adapter()
  return {
    is_dir = ffi_is_dir,
    list = ffi_list,
    read = file_read,
    exists = function(p) return file_exists(p) or ffi_is_dir(p) end,
  }
end

osfs._ffi_is_dir = ffi_is_dir   -- exposed for tests
osfs._ffi_list = ffi_list
osfs._file_read = file_read

return osfs
