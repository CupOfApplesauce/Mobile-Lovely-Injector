-- Mobile Lovely Injector: on-device diagnostics.
--
-- On locked-down devices (e.g. Samsung One UI) the LÖVE save directory lives
-- under /sdcard/Android/data/<pkg>/... which no-root file managers and even
-- `adb shell` cannot read. This module sidesteps that:
--
--   * It writes a FULL report (status, mods, save dir, and when troubleshooting
--     the storage/read probes) to a PUBLIC folder (Download/Documents) via raw
--     io.*, so it can be opened with any file manager.
--   * It returns a SHORT popup string for love.window.showMessageBox. The popup
--     is deliberately kept to a handful of lines: on some devices a tall
--     message box pushes its OK button off-screen and soft-locks the launch.
--
-- All file access is via io.* (not love.filesystem), because the whole point is
-- to reach locations outside the LÖVE sandbox.

local D = {}

-- Candidate public locations, most-preferred first. Trailing slash required.
D.PUBLIC_DIRS = {
  "/storage/emulated/0/Download/",
  "/storage/emulated/0/Documents/",
  "/storage/emulated/0/",
  "/sdcard/Download/",
}

D.REPORT_NAME = "BalatroMLI_report.txt"

-- Hard cap on popup lines so the OK button is always reachable on-device.
D.MAX_POPUP_LINES = 14

local function try_write(path, text)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  local ok = pcall(function() f:write(text) end)
  f:close()
  if not ok then return false, "write failed" end
  return true
end

local function save_dir()
  if love and love.filesystem and love.filesystem.getSaveDirectory then
    local ok, sd = pcall(love.filesystem.getSaveDirectory)
    if ok then return tostring(sd) end
  end
  return "?"
end

-- Cap a multi-line string to at most n lines, adding an ellipsis marker.
local function cap_lines(s, n)
  local lines = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  if #lines <= n then return s end
  local kept = {}
  for i = 1, n - 1 do kept[i] = lines[i] end
  kept[n] = "  ... (full details in the log file)"
  return table.concat(kept, "\n")
end

-- Build the report. `status_line` is a short headline; `detail` is the injector
-- summary or an error message. `opts.verbose` adds the save dir + storage/read
-- probes to the FILE (used when troubleshooting). Always persists the full
-- report to the first writable public folder. Returns the SHORT popup string.
function D.build_report(status_line, detail, opts)
  opts = opts or {}

  -- ---- assemble the FULL report (for the log file) ----
  local F = {}
  local function addf(s) F[#F + 1] = s end
  addf("== Mobile Lovely Injector ==")
  addf(status_line or "(no status)")
  if detail and detail ~= "" then addf(""); addf(detail) end
  addf("")
  addf("save dir:")
  addf("  " .. save_dir())

  local denied = false
  if opts.verbose then
    -- read probe: why external mods weren't found
    local ok_ext, external = pcall(require, "mli.external")
    if ok_ext and external.read_probe then
      addf("")
      addf("mods source probe:")
      for _, line in ipairs(external.read_probe()) do
        addf("  " .. line)
        if line:find("[Pp]ermission denied") then denied = true end
      end
    end
  end

  -- ---- persist the full report ----
  local persisted = table.concat(F, "\n") .. "\n"
  local saved_to
  for _, dir in ipairs(D.PUBLIC_DIRS) do
    if try_write(dir .. D.REPORT_NAME, persisted) then saved_to = dir; break end
  end

  -- ---- assemble the SHORT popup ----
  local P = {}
  local function add(s) P[#P + 1] = s end
  add("== Mobile Lovely Injector ==")
  add(status_line or "(no status)")
  if detail and detail ~= "" then
    add("")
    add(detail)
  end
  if denied then
    add("")
    add("A mod file can't be read.")
    add("Enable 'All files access' for this")
    add("app in Settings, then relaunch.")
  end
  add("")
  if saved_to then
    add("Log: " .. saved_to .. D.REPORT_NAME)
  else
    add("(could not write a log file)")
  end

  return cap_lines(table.concat(P, "\n"), D.MAX_POPUP_LINES)
end

return D
