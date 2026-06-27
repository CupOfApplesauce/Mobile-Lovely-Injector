-- Amulet Score Guard — keeps one Amulet edge case from bricking a save.
--
-- Amulet (the Talisman successor that Cryptid depends on) represents big
-- numbers internally as cdata. A value can still come back from a save in the
-- older Talisman *table* form ({sign, array, __talisman, val, ...}). Amulet's
-- is_big() only recognizes its own cdata, so when check_and_set_high_score()
-- runs `amt = math.floor(amt)` on such a table, the native floor rejects the
-- table and the run crashes -- typically while CONTINUING a Cryptid ascension
-- run, which can leave that save unable to load at all.
--
-- We deliberately do NOT try to reconstruct the number from outside Amulet:
-- only Amulet's own code knows how to turn that table back into an accurate
-- big number, and guessing could silently corrupt a score. So this is a SAFETY
-- NET, not a true fix. We wrap check_and_set_high_score so that if it errors,
-- we skip the (non-critical, purely cosmetic) high-score update instead of
-- crashing the game. The crash happens on the function's first line, before it
-- mutates any state, so skipping is clean.
--
-- With no Amulet installed, the vanilla check_and_set_high_score only ever sees
-- plain numbers and never errors, so this wrapper is a transparent no-op.
--
-- The real fix belongs upstream in Amulet (recognize/re-inflate table-form big
-- numbers in check_and_set_high_score); this just stops it from costing a save.

if not _G.MLI_amulet_score_guard then
  _G.MLI_amulet_score_guard = true

  if type(_G.check_and_set_high_score) == "function" then
    local original = _G.check_and_set_high_score
    function _G.check_and_set_high_score(score, amt)
      local ok, err = pcall(original, score, amt)
      if not ok and _G.sendWarnMessage then
        pcall(_G.sendWarnMessage,
          ("skipped high-score update for '%s': %s"):format(tostring(score), tostring(err)),
          "AmuletScoreGuard")
      end
    end
  elseif _G.sendWarnMessage then
    -- Defined by Amulet's boot code before any mod's main.lua runs; if it's
    -- somehow absent, install nothing rather than capture a nil.
    pcall(_G.sendWarnMessage,
      "check_and_set_high_score not found at load; guard not installed", "AmuletScoreGuard")
  end
end

return true
