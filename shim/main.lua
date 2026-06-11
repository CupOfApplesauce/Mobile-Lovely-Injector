-- Mobile Lovely Injector: main.lua shim.
--
-- The installer renames the game's original main.lua to mli/main_original.lua
-- and drops this file in its place. LÖVE runs main.lua automatically after
-- boot, so this is our earliest pure-Lua entry point. We boot the injector,
-- which sets up patching hooks and then loads + runs the (patched) original
-- main.lua. If anything in the injector fails, we fall back to running the
-- game unmodified so a bad mod cannot brick the install.

local ok, err = pcall(function()
  local injector = require("mli.injector")
  injector.boot({
    -- Uncomment to increase verbosity while debugging mods:
    -- log_level = "debug",
  })
end)

if not ok then
  print("[MLI] fatal injector error, launching game unmodified: " .. tostring(err))
  -- Fall back to the untouched original main.lua so the game still starts.
  local chunk = love.filesystem.load("mli/main_original.lua")
  if chunk then chunk() end
end
