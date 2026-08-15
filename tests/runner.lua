-- Test entry point. Run from the repo root:
--   luajit tests/runner.lua
--
-- Why LuaJIT and not "real" Lua 5.1: this dev machine has no C compiler, and
-- getting a Lua 5.1 interpreter here otherwise means either an admin-elevated
-- system install or a hand-built one. LuaJIT 2.1 ships as a single binary with
-- _VERSION == "Lua 5.1" and matches WoW's actual Lua 5.1 semantics for
-- everything these tests exercise. If that stops being true for some future
-- test, that is a reason to revisit this choice, not to ignore it.
if _VERSION ~= "Lua 5.1" then
	io.stderr:write("FATAL: tests must run under Lua 5.1 semantics (got " ..
		tostring(_VERSION) .. "). GCDIndicator ships on WoW's Lua 5.1 runtime; " ..
		"results from any other runtime don't validate anything this suite claims to.\n")
	os.exit(1)
end

local root = (arg and arg[0] or "tests/runner.lua"):match("^(.*[/\\])") or "./"

-- WoW globals must exist before any addon/Lib file is dofile'd — see
-- tests/mocks/wow_api.lua's header comment for why.
dofile(root .. "mocks/wow_api.lua")
dofile(root .. "../Libs/LibStub/LibStub.lua")

local framework = dofile(root .. "framework.lua")
_G.describe = framework.describe
_G.it = framework.it
_G.assertEqual = framework.assertEqual
_G.assertTrue = framework.assertTrue
_G.assertFalse = framework.assertFalse
_G.assertNil = framework.assertNil
_G.assertDeepEqual = framework.assertDeepEqual

-- Explicit manifest rather than directory discovery — stock Lua 5.1 has no
-- filesystem listing (that's what the compiled lfs extension is for, and this
-- machine has no compiler to build it). Add new spec files here.
local SPEC_FILES = {
	"spec/profiles_spec.lua",
	"spec/catalog_spec.lua",
	"spec/range_spec.lua",
}

for _, relPath in ipairs(SPEC_FILES) do
	print("\n-- " .. relPath .. " " .. string.rep("-", 60 - #relPath))
	dofile(root .. relPath)
end

local stats = framework.stats()
print(("\n%d passed, %d failed"):format(stats.pass, stats.fail))
if stats.fail > 0 then
	os.exit(1)
end
