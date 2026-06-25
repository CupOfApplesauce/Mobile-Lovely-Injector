-- Mobile Lovely Injector: logging
-- Writes to the LÖVE save directory (mli/log.txt) when love.filesystem is
-- available, and always echoes to stdout/print so it shows up in `adb logcat`.

local log = {}

local LEVELS = { trace = 1, debug = 2, info = 3, warn = 4, error = 5 }

log.level = LEVELS.info
log.path = "mli/log.txt"
log._buffer = {}
log._flushed = false

local function timestamp()
  if os and os.date then
    return os.date("%H:%M:%S")
  end
  return "--:--:--"
end

-- Public mirror: on locked-down devices the save-dir log is unreadable, so we
-- also append every line to a file in a public folder via raw io.*. Resolved
-- lazily to the first writable candidate; the file is truncated once per run.
local PUBLIC_CANDIDATES = {
  "/storage/emulated/0/Download/BalatroMLI_log.txt",
  "/storage/emulated/0/Documents/BalatroMLI_log.txt",
  "/sdcard/Download/BalatroMLI_log.txt",
}
log._public_path = nil
log._public_init = false

local function public_append(line)
  if not log._public_init then
    log._public_init = true
    for _, p in ipairs(PUBLIC_CANDIDATES) do
      local f = io.open(p, "w")          -- truncate/create once per run
      if f then f:write("== Mobile Lovely Injector log ==\n"); f:close(); log._public_path = p; break end
    end
  end
  if log._public_path then
    local f = io.open(log._public_path, "a")
    if f then f:write(line .. "\n"); f:close() end
  end
end

local function write_line(line)
  print(line)
  pcall(public_append, line)
  -- Defer save-dir writes until love.filesystem is ready; buffer meanwhile.
  if love and love.filesystem and love.filesystem.append then
    if not log._flushed and #log._buffer > 0 then
      love.filesystem.append(log.path, table.concat(log._buffer, "\n") .. "\n")
      log._buffer = {}
      log._flushed = true
    end
    love.filesystem.append(log.path, line .. "\n")
  else
    table.insert(log._buffer, line)
  end
end

local function emit(level_name, level_value, fmt, ...)
  if level_value < log.level then return end
  local msg = fmt
  if select("#", ...) > 0 then
    local ok, formatted = pcall(string.format, fmt, ...)
    msg = ok and formatted or fmt
  end
  write_line(string.format("[MLI %s %s] %s", timestamp(), level_name:upper(), msg))
end

function log.trace(fmt, ...) emit("trace", LEVELS.trace, fmt, ...) end
function log.debug(fmt, ...) emit("debug", LEVELS.debug, fmt, ...) end
function log.info(fmt, ...)  emit("info",  LEVELS.info,  fmt, ...) end
function log.warn(fmt, ...)  emit("warn",  LEVELS.warn,  fmt, ...) end
function log.error(fmt, ...) emit("error", LEVELS.error, fmt, ...) end

function log.set_level(name)
  log.level = LEVELS[name] or log.level
end

return log
