package.path = "./?.lua;" .. package.path
local re = require("mli.regex")
local pass, fail = 0, 0
local function ck(name, cond) if cond then pass=pass+1 else fail=fail+1; print("FAIL: "..name) end end

local function find(pat, text)
  local c, err = re.compile(pat); if not c then return nil, err end
  return re.find(c, text)
end

-- basics
do local s,e = find("abc", "xxabcxx"); ck("literal", s==3 and e==5) end
do local s,e = find("a.c", "a\ncaxc"); ck(". excludes newline", s==4 and e==6) end
do local s,e,arr = find("a(?<m>.*?)b", "aXbYb"); ck("lazy named cap", arr and arr[1]=="X") end
do local s,e = find("x{2,3}", "xxxx"); ck("{2,3} greedy", s==1 and e==3) end
do local s,e,a,nm = find("(?<k>foo|bar)", "zzbar"); ck("alternation", nm and nm.k=="bar") end
do local s,e = find("(?:ab)+", "ababab"); ck("non-capturing group +", s==1 and e==6) end

-- THE critical SMODS CRT pattern (group repetition across lines)
do
  local text = [[
keep_above
    G.SETTINGS.GRAPHICS.crt = G.SETTINGS.GRAPHICS.crt*0.3
    G.SHADERS['CRT']:send('time',400)
    G.SHADERS['CRT']:send('noise_fac',0.001)
    G.SETTINGS.GRAPHICS.crt = G.SETTINGS.GRAPHICS.crt/0.3
keep_below
]]
  local c = re.compile([[G.SETTINGS.GRAPHICS.crt =(.*\n)*\s*G.SETTINGS.GRAPHICS.crt =.*]])
  local s,e = re.find(c, text)
  ck("CRT block matches", s ~= nil)
  if s then
    local removed = re.gsub(text, c, function() return "" end)
    ck("CRT block removable (noise_fac gone)", not removed:find("noise_fac"))
    ck("CRT block removal keeps surrounding", removed:find("keep_above") and removed:find("keep_below"))
  end
end

-- another SMODS multiline idiom: (\n.*){N}
do
  local c = re.compile([[start(\n.*){2}]])
  local s,e = re.find(c, "start\nl1\nl2\nl3")
  ck("(\\n.*){2} counted lines", s==1 and select(2, re.find(c,"start\nl1\nl2\nl3")) >= 5)
end

print(string.format("regex engine: %d passed, %d failed", pass, fail))
os.exit(fail==0 and 0 or 1)
