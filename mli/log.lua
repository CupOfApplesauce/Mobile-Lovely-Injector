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

local function write_line(line)
  print(line)
  -- Defer file writes until love.filesystem is ready; buffer in the meantime.
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
