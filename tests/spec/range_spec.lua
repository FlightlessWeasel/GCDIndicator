-- Tests for Libs/LibGCDI-Range/LibGCDI-Range.lua — settings-table logic only
-- (GetRangeFallbackYards, IsSpellSelfCast, HasRangeOverride, HasNativeRangeSetting).
-- UpdateRangeIndicators / DetectNativeRangeForSpells / AutoDetectSelfCast touch
-- live WoW state (UnitExists, C_Spell, IsActionInRange, frame Show/Hide) and are
-- not covered here — see tests/mocks/wow_api.lua before adding coverage for those.

dofile("Libs/LibGCDI-Range/LibGCDI-Range.lua")
local lib = LibStub("LibGCDI-Range")

local function with_settings(settings)
	lib:Init({ getSettings = function() return settings end })
end

describe("LibGCDI-Range GetRangeFallbackYards", function()
	it("returns the spell-specific override when set", function()
		with_settings({ spellSettings = { [1] = { rangeFallbackYards = 30 } } })
		assertEqual(lib:GetRangeFallbackYards(1), 30)
	end)

	it("maps a legacy per-spell index to yards when rangeFallbackYards is absent", function()
		with_settings({ spellSettings = { [1] = { rangeFallback = 6 } } }) -- index 6 -> 15 yards
		assertEqual(lib:GetRangeFallbackYards(1), 15)
	end)

	it("falls back to the global yards setting when no per-spell setting exists", function()
		with_settings({ spellSettings = {}, globalRangeFallbackYards = 20 })
		assertEqual(lib:GetRangeFallbackYards(1), 20)
	end)

	it("maps a legacy global index to yards when globalRangeFallbackYards is absent", function()
		with_settings({ spellSettings = {}, globalRangeFallback = 2 }) -- index 2 -> 8 yards
		assertEqual(lib:GetRangeFallbackYards(1), 8)
	end)

	it("defaults to 5 yards when nothing is configured", function()
		with_settings({ spellSettings = {} })
		assertEqual(lib:GetRangeFallbackYards(1), 5)
	end)
end)

describe("LibGCDI-Range IsSpellSelfCast / HasRangeOverride / HasNativeRangeSetting", function()
	it("IsSpellSelfCast is true only when explicitly set true", function()
		with_settings({ spellSettings = { [1] = { selfCast = true }, [2] = { selfCast = false } } })
		assertTrue(lib:IsSpellSelfCast(1))
		assertFalse(lib:IsSpellSelfCast(2))
		assertFalse(lib:IsSpellSelfCast(3)) -- no entry at all
	end)

	it("HasRangeOverride is true for a yards override or a legacy index override", function()
		with_settings({
			spellSettings = {
				[1] = { rangeFallbackYards = 10 },
				[2] = { rangeFallback = 3 },
				[3] = {},
			},
		})
		assertTrue(lib:HasRangeOverride(1))
		assertTrue(lib:HasRangeOverride(2))
		assertFalse(lib:HasRangeOverride(3))
	end)

	it("HasNativeRangeSetting reflects the hasNativeRange flag", function()
		with_settings({ spellSettings = { [1] = { hasNativeRange = true } } })
		assertTrue(lib:HasNativeRangeSetting(1))
		assertFalse(lib:HasNativeRangeSetting(2))
	end)
end)
