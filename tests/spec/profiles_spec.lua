-- Tests for Libs/LibGCDI-Profiles/LibGCDI-Profiles.lua — deep-copy, compact
-- serialize/deserialize, and profile save/load round-tripping. Pure table
-- logic, no WoW API surface, so no mocking is needed beyond LibStub itself.

dofile("Libs/LibGCDI-Profiles/LibGCDI-Profiles.lua")
local lib = LibStub("LibGCDI-Profiles")

describe("LibGCDI-Profiles deepcopy", function()
	it("copies nested tables by value, not reference", function()
		local orig = { a = 1, nested = { b = 2 } }
		local copy = lib.deepcopy(orig)
		copy.nested.b = 99
		assertEqual(orig.nested.b, 2, "mutating the copy must not affect the original")
		assertEqual(copy.nested.b, 99)
	end)

	it("handles self-referential tables without infinite recursion", function()
		local orig = {}
		orig.self = orig
		local copy = lib.deepcopy(orig)
		assertTrue(copy.self == copy, "cycle must resolve to the copy, not the original")
	end)

	it("skips functions and WoW frame-like objects", function()
		local fakeFrame = setmetatable({}, { __index = function() return function() end end })
		local orig = { fn = function() end, frame = fakeFrame, value = 42 }
		local copy = lib.deepcopy(orig)
		assertNil(copy.fn)
		assertNil(copy.frame)
		assertEqual(copy.value, 42)
	end)
end)

describe("LibGCDI-Profiles serialize/deserialize", function()
	it("round-trips a table of mixed value types", function()
		local orig = { n = 5, s = "hello", b = true, f = false, nested = { 1, 2, 3 } }
		local str = lib.serialize(orig)
		local result, err = lib.deserialize(str)
		assertNil(err)
		assertDeepEqual(result, orig)
	end)

	it("escapes quotes and backslashes in strings", function()
		local orig = { s = [[a "quoted" \ value]] }
		local result = lib.deserialize(lib.serialize(orig))
		assertEqual(result.s, orig.s)
	end)

	it("returns nil plus an error message for garbage input", function()
		local result, err = lib.deserialize("not valid lua {{{")
		assertNil(result)
		assertTrue(err ~= nil, "expected an error message for unparseable input")
	end)
end)

describe("LibGCDI-Profiles SaveProfile/LoadProfile", function()
	it("round-trips settings through a named profile", function()
		local settings = {
			globalRangeFallbackYards = 8,
			spellSettings = { [123] = { rangeFallbackYards = 10 } },
			spellOrder = { 123, 456 },
		}
		assertTrue(lib:SaveProfile(settings, "Retribution", nil))
		assertEqual(settings.currentProfile, "Retribution")

		-- Mutate live settings after saving; loading the profile back must restore the saved snapshot.
		settings.globalRangeFallbackYards = 40
		settings.spellOrder = {}

		assertTrue(lib:LoadProfile(settings, "Retribution", nil))
		assertEqual(settings.globalRangeFallbackYards, 8)
		assertDeepEqual(settings.spellOrder, { 123, 456 })
	end)

	it("SaveProfile rejects a nil or empty name", function()
		local settings = {}
		assertFalse(lib:SaveProfile(settings, nil, nil))
		assertFalse(lib:SaveProfile(settings, "", nil))
	end)

	it("LoadProfile fails for an unknown profile name", function()
		local settings = { profiles = {} }
		assertFalse(lib:LoadProfile(settings, "DoesNotExist", nil))
	end)

	it("DeleteProfile clears currentProfile only when it was the active one", function()
		local settings = {}
		lib:SaveProfile(settings, "A", nil)
		lib:SaveProfile(settings, "B", nil) -- currentProfile is now "B"
		assertTrue(lib:DeleteProfile(settings, "A"))
		assertEqual(settings.currentProfile, "B", "deleting a non-active profile must not clear currentProfile")

		assertTrue(lib:DeleteProfile(settings, "B"))
		assertNil(settings.currentProfile, "deleting the active profile must clear currentProfile")
	end)

	it("GetProfileNames returns names sorted alphabetically", function()
		local settings = {}
		lib:SaveProfile(settings, "Zeta", nil)
		lib:SaveProfile(settings, "Alpha", nil)
		lib:SaveProfile(settings, "Mu", nil)
		assertDeepEqual(lib:GetProfileNames(settings), { "Alpha", "Mu", "Zeta" })
	end)

	it("SpellSettingsForSave strips the legacy rangeFallback index field", function()
		local ss = { [1] = { rangeFallback = 3, rangeFallbackYards = 10, selfCast = true } }
		local out = lib.SpellSettingsForSave(ss)
		assertNil(out[1].rangeFallback)
		assertEqual(out[1].rangeFallbackYards, 10)
		assertTrue(out[1].selfCast)
	end)
end)

describe("LibGCDI-Profiles ExportSettings/ImportSettings", function()
	it("round-trips exported settings", function()
		local settings = {
			globalRangeFallbackYards = 12,
			spellSettings = {},
			spellOrder = { 1, 2, 3 },
			itemSettings = {},
			itemOrder = {},
			buffSettings = {},
			buffOrder = {},
			resourceSettings = {},
			gcdSettings = { useLibRangeCheck = true },
		}
		local exported = lib:ExportSettings(settings)
		assertTrue(type(exported) == "string")
		local imported = lib:ImportSettings(exported)
		assertEqual(imported.gy, 12)
		assertDeepEqual(imported.so, { 1, 2, 3 })
		assertTrue(imported.gs.useLibRangeCheck)
	end)
end)
