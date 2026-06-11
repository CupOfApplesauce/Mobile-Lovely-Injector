-- Appended to the end of the game's main.lua by the copy patch above. Runs
-- after the game's own main.lua has finished setting up.
local ok, util = pcall(require, "hellomod.util")
if ok then
  print(util.greet("from bootstrap"))
else
  print("[HelloMod] bootstrap ran, but module failed to load: " .. tostring(util))
end
