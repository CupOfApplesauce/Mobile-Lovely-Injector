-- HelloMod bootstrap: appended to the end of main.lua by the copy patch above.
-- Runs after the game's own main.lua has finished setting up.

local ok, util = pcall(require, "hellomod.util")
print(ok and util.greet("from bootstrap")
         or ("[HelloMod] module failed to load: " .. tostring(util)))

-- A small, personalized touch: tag the version string shown in the CORNER of
-- the main menu (this is essentially what Steamodded does to show it loaded).
-- This is intentionally NOT a full-screen overlay -- it appears only with the
-- version text on the menu, never drawn over gameplay. Change the text below
-- to make it your own. G.VERSION is set by globals.lua, required before this
-- appended code runs.
if G and type(G.VERSION) == "string" and not G._hellomod_tagged then
  G.VERSION = G.VERSION .. "\n+HelloMod (MLI)"
  G._hellomod_tagged = true
end
