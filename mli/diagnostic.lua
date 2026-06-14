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
-- `opts.verbose` (default false) adds the save-dir path and the per-folder
-- write probe -- useful when troubleshooting (no mods found / injector error).
-- The full report is always persisted to the first writable public folder so
-- it's retrievable in a file manager even when the popup is concise.
-- Returns the on-screen string.
function D.build_report(status_line, detail, opts)
  opts = opts or {}
  local L = {}
  local function add(s) L[#L + 1] = s end

  add("== Mobile Lovely Injector ==")
  add(status_line or "(no status)")
  if detail and detail ~= "" then
    add("")
    add(detail)
  end

  -- Always build the full (verbose) text for the persisted file.
  local full = { unpack and unpack(L) or table.unpack(L) }
  local function addf(s) full[#full + 1] = s end
  addf("")
  if love and love.filesystem and love.filesystem.getSaveDirectory then
    local ok, sd = pcall(love.filesystem.getSaveDirectory)
    addf("save dir:")
    addf("  " .. (ok and tostring(sd) or "?"))
  end

  -- Persist (without the probe results, which would be circular).
  local persisted = table.concat(full, "\n")
  local saved_to
  local probe_lines = {}
  for _, dir in ipairs(D.PUBLIC_DIRS) do
    local ok, err = try_write(dir .. D.REPORT_NAME, persisted)
    probe_lines[#probe_lines + 1] = ("  %s %s%s"):format(
      ok and "[OK]" or "[NO]", dir, ok and "" or ("  (" .. tostring(err) .. ")"))
    if ok and not saved_to then saved_to = dir end
  end

  -- On-screen: verbose adds save dir + probe; otherwise just where the log went.
  if opts.verbose then
    add("")
    if love and love.filesystem and love.filesystem.getSaveDirectory then
      local ok, sd = pcall(love.filesystem.getSaveDirectory)
      add("save dir:")
      add("  " .. (ok and tostring(sd) or "?"))
    end
    add("")
    add("public folder write test:")
    for _, line in ipairs(probe_lines) do add(line) end

    -- Own-file readback: can the app read a file it just wrote? (Proves read
    -- works for its OWN files, isolating the scoped-storage ownership issue.)
    if saved_to then
      local rf = io.open(saved_to .. D.REPORT_NAME, "rb")
      add("")
      add("read own file back: " .. (rf and "OK" or "FAIL"))
      if rf then rf:close() end
    end

    -- Mods-source read probe: why external mods weren't found.
    local ok_ext, external = pcall(require, "mli.external")
    if ok_ext and external.read_probe then
      add("")
      add("mods source probe:")
      for _, line in ipairs(external.read_probe()) do add("  " .. line) end
    end
  end

  add("")
  if saved_to then
    add("Log: " .. saved_to .. D.REPORT_NAME)
  else
    add("No public folder writable (needs storage permission).")
  end

  return table.concat(L, "\n")
end

return D
