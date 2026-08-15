-- ═══════════════════════════════════════════════════════════════════════════
-- WoW API mocks — Lua 5.1 test runtime only, never shipped in the addon.
--
-- CONTRACT: every stub here must reflect real WoW API behavior (signature,
-- return values, nil semantics), verified against https://warcraft.wiki.gg or
-- the wow-addon-architect agent (.claude/agents/wow-addon-architect.md) —
-- never guessed. If a test needs behavior this file doesn't cover yet, verify
-- the real API first, then extend the stub. Code must be corrected to fit an
-- accurate mock; never loosen a mock to fit a shortcut in the addon code.
--
-- This file is dofile'd by tests/runner.lua BEFORE any addon/Lib file, since
-- those files cache WoW globals into upvalues at chunk-load time
-- (e.g. `local UnitExists = UnitExists` in LibGCDI-Range.lua) — a global that
-- doesn't exist yet at load time never gets picked up later.
-- ═══════════════════════════════════════════════════════════════════════════

-- wipe(): WoW-provided table helper, not stock Lua 5.1. Clears in place, returns the table.
function wipe(t)
	for k in pairs(t) do
		t[k] = nil
	end
	return t
end

-- GetTime(): seconds since login, monotonic-ish float. Tests can override via
-- `_G.GetTime = function() return <fixed value> end` for deterministic timing.
function GetTime()
	return os.clock()
end

-- Unit/combat/range APIs default to "no target, out of combat, no addon frames" —
-- override per-test with _G.<Name> = function(...) ... end when a spec needs a
-- specific game-state response.
function UnitExists(unit)
	return false
end

function UnitCanAttack(srcUnit, dstUnit)
	return false
end

function InCombatLockdown()
	return false
end

function IsActionInRange(actionSlot)
	return nil
end

C_Spell = {
	SpellHasRange = function(spellID) return false end,
	GetSpellInfo = function(spellID) return nil end,
	IsSpellInRange = function(spellID, unit) return nil end,
}

C_Timer = {
	After = function(delay, fn) end,
	NewTicker = function(delay, fn, iterations) return { Cancel = function() end } end,
}
