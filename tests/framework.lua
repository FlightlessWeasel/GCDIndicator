-- Minimal describe/it/assert test framework. No external deps (no busted/luarocks
-- available on this machine — see tests/README.md for why). Loaded by tests/runner.lua.

local M = {}
local describeStack = {}
local stats = { pass = 0, fail = 0, failures = {} }

local function currentLabel(name)
	if #describeStack == 0 then return name end
	return table.concat(describeStack, " > ") .. " > " .. name
end

function M.describe(name, fn)
	table.insert(describeStack, name)
	local ok, err = pcall(fn)
	table.remove(describeStack)
	if not ok then
		error("describe(\"" .. name .. "\") errored outside of an it(): " .. tostring(err), 0)
	end
end

function M.it(name, fn)
	local label = currentLabel(name)
	local ok, err = pcall(fn)
	if ok then
		stats.pass = stats.pass + 1
		print("  PASS  " .. label)
	else
		stats.fail = stats.fail + 1
		table.insert(stats.failures, { label = label, err = err })
		print("  FAIL  " .. label)
		print("        " .. tostring(err))
	end
end

local function fmt(v)
	if type(v) == "string" then return string.format("%q", v) end
	if type(v) == "table" then return tostring(v) end
	return tostring(v)
end

function M.assertEqual(actual, expected, msg)
	if actual ~= expected then
		error((msg and (msg .. ": ") or "") .. "expected " .. fmt(expected) .. ", got " .. fmt(actual), 2)
	end
end

function M.assertTrue(v, msg)
	if not v then error(msg or "expected truthy value, got " .. fmt(v), 2) end
end

function M.assertFalse(v, msg)
	if v then error(msg or "expected falsy value, got " .. fmt(v), 2) end
end

function M.assertNil(v, msg)
	if v ~= nil then error((msg and (msg .. ": ") or "") .. "expected nil, got " .. fmt(v), 2) end
end

local function deepEqual(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then return false end
	end
	for k, v in pairs(b) do
		if not deepEqual(v, a[k]) then return false end
	end
	return true
end

function M.assertDeepEqual(actual, expected, msg)
	if not deepEqual(actual, expected) then
		error((msg and (msg .. ": ") or "") .. "tables not deep-equal", 2)
	end
end

function M.stats()
	return stats
end

return M
