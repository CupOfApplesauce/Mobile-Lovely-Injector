-- Mobile Lovely Injector: main.lua shim.
--
-- The installer renames the game's original main.lua to mli/main_original.lua
-- and drops this file in its place. LÖVE runs main.lua automatically after
-- boot, so this is our earliest pure-Lua entry point. We boot the injector,
-- which sets up patching hooks and then loads + runs the (patched) original
-- main.lua. If anything in the injector fails, we fall back to running the
-- game unmodified so a bad mod cannot brick the install.

-- DIAGNOSTIC: show a popup on launch reporting injector status + where the log
-- was written. Leave true while getting things working; set false for normal
-- play once you've confirmed mods load.
local DIAGNOSTIC = true

local injector = require("mli.injector")

local status_line, detail
local ok, err = pcall(function() injector.boot() end)
if ok then
  status_line = "STATUS: injector ran OK"
  detail = injector.summary or ""
else
  status_line = "STATUS: injector FAILED -- game running UNMODIFIED"
  detail = tostring(err)
  print("[MLI] " .. status_line .. ": " .. detail)
  -- Persist inside the sandbox too (in case the public-folder write fails).
  pcall(function()
    if love.filesystem.createDirectory then love.filesystem.createDirectory("mli") end
    love.filesystem.append("mli/boot_error.txt",
      (os.date and os.date("%Y-%m-%d %H:%M:%S ") or "") .. detail .. "\n")
  end)
  -- Fall back to the untouched original main.lua so the game still starts.
  local chunk = love.filesystem.load("mli/main_original.lua")
  if chunk then chunk() end
end

if DIAGNOSTIC then
  -- Show the report after the game's love.load runs (so the window exists).
  local ok_diag, diagnostic = pcall(require, "mli.diagnostic")
  local orig_load = love.load
  love.load = function(...)
    if orig_load then orig_load(...) end
    pcall(function()
      local report
      if ok_diag then
        report = diagnostic.build_report(status_line, detail)
      else
        report = status_line .. "\n\n" .. (detail or "")
      end
      love.window.showMessageBox("Mobile Lovely Injector", report, "info")
    end)
  end
end
