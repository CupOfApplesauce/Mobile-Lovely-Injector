-- HelloMod's Steamodded entry point.
--
-- HelloMod's actual demo patches (module / copy / pattern) are applied from
-- lovely.toml by MLI; this file only registers a small "Credits" tab with a
-- button that opens the project's GitHub page -- an example of how a mod
-- surfaces a clickable link in the Steamodded mods menu.

local mod = SMODS.current_mod

function G.FUNCS.mli_open_github(e)
  love.system.openURL("https://github.com/CupOfApplesauce/Mobile-Lovely-Injector")
end

-- Returns the tab's UI tree (same ROOT/row shape Steamodded uses for its own
-- mod tabs). Only rendered when the player opens the Credits tab.
mod.credits_tab = function()
  return {
    n = G.UIT.ROOT,
    config = { emboss = 0.05, minh = 6, minw = 6, r = 0.1, align = "tm", padding = 0.2, colour = G.C.BLACK },
    nodes = {
      { n = G.UIT.R, config = { align = "cm", padding = 0.1 }, nodes = {
        { n = G.UIT.T, config = { text = "Mobile Lovely Injector", scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
      } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
        { n = G.UIT.T, config = { text = "by CupOfApplesauce", scale = 0.4, colour = G.C.UI.TEXT_LIGHT } },
      } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
        { n = G.UIT.T, config = { text = "Run Balatro mods on Android, no PC needed.", scale = 0.32, colour = G.C.UI.TEXT_LIGHT } },
      } },
      { n = G.UIT.R, config = { align = "cm", padding = 0.2 }, nodes = {
        UIBox_button({ button = "mli_open_github", label = { "GitHub" }, colour = G.C.BLUE, minw = 4, minh = 0.8, scale = 0.5 }),
      } },
    },
  }
end

return true
