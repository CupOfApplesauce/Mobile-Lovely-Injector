-- HelloMod bootstrap: appended to the end of main.lua by the copy patch above.
-- Runs after the game's own main.lua has finished setting up. Demonstrates a
-- VISIBLE change so you can confirm at a glance that mods are running.

local ok, util = pcall(require, "hellomod.util")
print(ok and util.greet("from bootstrap")
         or ("[HelloMod] module failed to load: " .. tostring(util)))

-- 1) Tag the version string shown on the main menu (this is essentially what
--    Steamodded does to show it loaded). G.VERSION is set by globals.lua, which
--    main.lua requires before this appended code runs.
if G and type(G.VERSION) == "string" and not G._hellomod_tagged then
  G.VERSION = G.VERSION .. "\n+HelloMod (MLI)"
  G._hellomod_tagged = true
end

-- 2) Draw a small watermark over everything, as a guaranteed-visible proof that
--    works regardless of game internals. love.draw is defined earlier in
--    main.lua, so wrapping it here is safe.
if love and type(love.draw) == "function" and not love._hellomod_hooked then
  love._hellomod_hooked = true
  local _orig_draw = love.draw
  love.draw = function(...)
    if _orig_draw then _orig_draw(...) end
    pcall(function()
      love.graphics.push()
      love.graphics.origin()
      love.graphics.setColor(1, 1, 1, 1)
      love.graphics.print("HelloMod loaded via MLI", 8, 8)
      love.graphics.pop()
    end)
  end
end
