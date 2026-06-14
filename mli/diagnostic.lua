-- Mobile Lovely Injector: on-device diagnostics.
--
-- On locked-down devices (e.g. Samsung One UI) the LÖVE save directory lives
-- under /sdcard/Android/data/<pkg>/... which no-root file managers and even
-- `adb shell` cannot read. This module sidesteps that completely:
--
--   * It builds a one-screen status report (injector OK/failed, mods found,
--     and the absolute save-dir path) for display via love.window.showMessageBox.
--   * It tries to write that report to a PUBLIC folder (Download, Documents,
--     storage root) using raw io.open, so the report can be retrieved with any
--     file manager. The list of which folders were writable is itself the
--     recon we need to decide where mods should live on this device.
--
-- All file access is via io.* (not love.filesystem), because the whole point
-- is to reach locations outside the LÖVE sandbox.

local D = {}

-- Candidate public locations, most-preferred first. Trailing slash required.
D.PUBLIC_DIRS = {
  "/storage/emulated/0/Download/",
  "/storage/emulated/0/Documents/",
  "/storage/emulated/0/",
  "/sdcard/Download/",
}

D.REPORT_NAME = "BalatroMLI_report.txt"

local function try_write(path, text)
  local f, err = io.open(path, "w")
  if not f then return false, err end
  local ok = pcall(function() f:write(text) end)
  f:close()
  if not ok then return false, "write failed" end
  return true
end

-- Build the report text. `status_line` is a short headline; `detail` is an
-- optional multi-line block (e.g. the injector summary or an error+traceback).
-- Returns the on-screen string; also writes it to the first writable public
-- folder so it persists somewhere reachable.
function D.build_report(status_line, detail)
  local L = {}
  local function add(s) L[#L + 1] = s end

  add("== Mobile Lovely Injector ==")
  add(status_line or "(no status)")
  if detail and detail ~= "" then
    add("")
    add(detail)
  end
  add("")

  if love and love.filesystem and love.filesystem.getSaveDirectory then
    local ok, sd = pcall(love.filesystem.getSaveDirectory)
    add("save dir:")
    add("  " .. (ok and tostring(sd) or "?"))
    add("")
  end

  -- The text we persist to disk is everything gathered so far (the probe
  -- results below would be circular to include in the written file).
  local persisted = table.concat(L, "\n")

  add("public folder write test:")
  local saved_to
  for _, dir in ipairs(D.PUBLIC_DIRS) do
    local ok, err = try_write(dir .. D.REPORT_NAME, persisted)
    add(("  %s %s%s"):format(ok and "[OK]" or "[NO]", dir,
        ok and "" or ("  (" .. tostring(err) .. ")")))
    if ok and not saved_to then saved_to = dir end
  end
  add("")
  if saved_to then
    add("Report written to:")
    add("  " .. saved_to .. D.REPORT_NAME)
    add("Open that in your file manager.")
  else
    add("No public folder was writable.")
    add("(App likely needs All-files-access permission.)")
  end

  return table.concat(L, "\n")
end

return D
