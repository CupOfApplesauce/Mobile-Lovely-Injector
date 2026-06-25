-- HelloMod utility module, exposed to the game as require("hellomod.util").
local util = {}

function util.greet(name)
  return "[HelloMod] hello, " .. tostring(name or "Balatro")
end

util.loaded_at = os and os.time and os.time() or 0

return util
