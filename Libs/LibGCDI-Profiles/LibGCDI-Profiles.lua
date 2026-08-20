local MAJOR, MINOR = "LibGCDI-Profiles", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

local function deepcopy(orig, seen)
	if type(orig) ~= 'table' then
		return orig
	end
	
	seen = seen or {}
	if seen[orig] then
		return seen[orig]
	end
	
	local copy = {}
	seen[orig] = copy
	
	for k, v in pairs(orig) do
		local vtype = type(v)
		if vtype == 'function' then
		elseif vtype == 'table' and type(v.GetObjectType) == 'function' then
			-- skip WoW frame objects
		elseif vtype == 'userdata' then
		else
			copy[k] = deepcopy(v, seen)
		end
	end
	
	return copy
end

lib.deepcopy = deepcopy

-- Copy spell settings for save/export; strips legacy rangeFallback (index) so only rangeFallbackYards is persisted
local function spell_settings_for_save(ss)
	if not ss or type(ss) ~= "table" then return {} end
	local out = {}
	for spellID, opts in pairs(ss) do
		local copy = deepcopy(opts)
		copy.rangeFallback = nil
		out[spellID] = copy
	end
	return out
end
lib.SpellSettingsForSave = spell_settings_for_save

local function serialize_compact(tbl)
	local parts = {}
	for k, v in pairs(tbl) do
		local key = type(k) == "number" and "[" .. k .. "]" or k
		local val
		if type(v) == "table" then
			val = serialize_compact(v)
		elseif type(v) == "string" then
			val = "\"" .. v:gsub("\\", "\\\\"):gsub("\"", "\\\"") .. "\""
		elseif type(v) == "boolean" then
			val = v and "t" or "f"
		elseif type(v) == "number" then
			val = tostring(v)
		else
			val = "nil"
		end
		table.insert(parts, key .. "=" .. val)
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

lib.serialize = serialize_compact

local function deserialize_compact(str)
	if type(str) ~= "string" then
		return nil, "Invalid data"
	end

	local MAX_INPUT_LENGTH = 1024 * 1024
	local MAX_DEPTH = 64
	local MAX_ENTRIES = 10000
	if #str > MAX_INPUT_LENGTH then
		return nil, "Parse error: input too large"
	end

	local pos = 1
	local entries = 0
	local length = #str
	local nil_value = {}

	local function fail(message)
		return nil, "Parse error: " .. message
	end

	local function skip_whitespace()
		while pos <= length do
			local c = str:sub(pos, pos)
			if c ~= " " and c ~= "\t" and c ~= "\r" and c ~= "\n" then
				break
			end
			pos = pos + 1
		end
	end

	local function is_identifier_start(c)
		return c:match("^[%a_]$") ~= nil
	end

	local function is_identifier_continue(c)
		return c:match("^[%w_]$") ~= nil
	end

	local function parse_number()
		local start = pos
		if str:sub(pos, pos) == "-" then
			pos = pos + 1
		end

		local integer_start = pos
		while str:sub(pos, pos):match("^%d$") do
			pos = pos + 1
		end
		local has_integer = pos > integer_start

		if str:sub(pos, pos) == "." then
			pos = pos + 1
			local fraction_start = pos
			while str:sub(pos, pos):match("^%d$") do
				pos = pos + 1
			end
			if not has_integer and pos == fraction_start then
				return nil
			end
		elseif not has_integer then
			return nil
		end

		local exponent = str:sub(pos, pos)
		if exponent == "e" or exponent == "E" then
			pos = pos + 1
			local sign = str:sub(pos, pos)
			if sign == "+" or sign == "-" then
				pos = pos + 1
			end
			local exponent_start = pos
			while str:sub(pos, pos):match("^%d$") do
				pos = pos + 1
			end
			if pos == exponent_start then
				return nil
			end
		end

		local value = tonumber(str:sub(start, pos - 1))
		if value == nil then
			return nil
		end
		return value
	end

	local function parse_string()
		pos = pos + 1
		local parts = {}
		while pos <= length do
			local c = str:sub(pos, pos)
			if c == "\"" then
				pos = pos + 1
				return table.concat(parts)
			elseif c == "\\" then
				local escaped = str:sub(pos + 1, pos + 1)
				if escaped ~= "\\" and escaped ~= "\"" then
					return nil
				end
				table.insert(parts, escaped)
				pos = pos + 2
			else
				table.insert(parts, c)
				pos = pos + 1
			end
		end
		return nil
	end

	local parse_value
	local function parse_key()
		skip_whitespace()
		local c = str:sub(pos, pos)
		if c == "[" then
			pos = pos + 1
			skip_whitespace()
			local key = parse_number()
			if key == nil then
				return nil
			end
			skip_whitespace()
			if str:sub(pos, pos) ~= "]" then
				return nil
			end
			pos = pos + 1
			return key
		end
		if not is_identifier_start(c) then
			return nil
		end

		local start = pos
		pos = pos + 1
		while is_identifier_continue(str:sub(pos, pos)) do
			pos = pos + 1
		end
		return str:sub(start, pos - 1)
	end

	local function parse_table(depth)
		if depth > MAX_DEPTH then
			return fail("nesting limit exceeded")
		end
		pos = pos + 1
		local result = {}
		skip_whitespace()
		if str:sub(pos, pos) == "}" then
			pos = pos + 1
			return result
		end

		while true do
			entries = entries + 1
			if entries > MAX_ENTRIES then
				return fail("entry limit exceeded")
			end
			local key = parse_key()
			if key == nil then
				return fail("expected identifier or numeric key at position " .. pos)
			end
			skip_whitespace()
			if str:sub(pos, pos) ~= "=" then
				return fail("expected '=' at position " .. pos)
			end
			pos = pos + 1
			local value, err = parse_value(depth + 1)
			if err then
				return nil, err
			end
			if value == nil then
				return fail("expected value at position " .. pos)
			end
			if value ~= nil_value then
				result[key] = value
			end
			skip_whitespace()
			local separator = str:sub(pos, pos)
			if separator == "}" then
				pos = pos + 1
				return result
			elseif separator ~= "," then
				return fail("expected ',' or '}' at position " .. pos)
			end
			pos = pos + 1
			skip_whitespace()
		end
	end

	parse_value = function(depth)
		skip_whitespace()
		local c = str:sub(pos, pos)
		if c == "{" then
			return parse_table(depth)
		elseif c == "\"" then
			local value = parse_string()
			if value == nil then
				return fail("unterminated or invalid string at position " .. pos)
			end
			return value
		elseif c == "t" then
			if str:sub(pos, pos + 3) == "true" then
				pos = pos + 4
			elseif not str:sub(pos + 1, pos + 1):match("[%w_]") then
				pos = pos + 1
			else
				return fail("expected value at position " .. pos)
			end
			return true
		elseif c == "f" then
			if str:sub(pos, pos + 4) == "false" then
				pos = pos + 5
			elseif not str:sub(pos + 1, pos + 1):match("[%w_]") then
				pos = pos + 1
			else
				return fail("expected value at position " .. pos)
			end
			return false
		elseif str:sub(pos, pos + 2) == "nil" then
			pos = pos + 3
			return nil_value
		elseif c == "-" or c:match("^%d$") then
			local value = parse_number()
			if value ~= nil then
				return value
			end
		end
		return fail("expected value at position " .. pos)
	end

	local result, err = parse_value(1)
	if err then
		return nil, err
	end
	if result == nil or type(result) ~= "table" then
		return nil, "Invalid data"
	end
	skip_whitespace()
	if pos <= length then
		return fail("unexpected data at position " .. pos)
	end
	return result
end

lib.deserialize = deserialize_compact

function lib:SaveProfile(settings, name, catalogs)
	if not settings or not name or name == "" then return false end
	
	settings.profiles = settings.profiles or {}
	settings.profiles[name] = {
		globalRangeFallbackYards = settings.globalRangeFallbackYards,
		rangeProxySpells = settings.rangeProxySpells and deepcopy(settings.rangeProxySpells) or {},
		spellSettings = spell_settings_for_save(settings.spellSettings),
		spellOrder = deepcopy(settings.spellOrder),
		itemSettings = deepcopy(settings.itemSettings or {}),
		itemOrder = deepcopy(settings.itemOrder or {}),
		buffSettings = deepcopy(settings.buffSettings or {}),
		buffOrder = deepcopy(settings.buffOrder or {}),
		resourceSettings = deepcopy(settings.resourceSettings or {}),
		gcdSettings = deepcopy(settings.gcdSettings or {}),
	}

	if catalogs then
		if catalogs.spellCatalog then
			settings.profiles[name].spellCatalog = deepcopy(catalogs.spellCatalog)
		end
		if catalogs.itemCatalog then
			settings.profiles[name].itemCatalog = deepcopy(catalogs.itemCatalog)
		end
		if catalogs.buffCatalog then
			settings.profiles[name].buffCatalog = deepcopy(catalogs.buffCatalog)
		end
	end
	
	settings.currentProfile = name
	return true
end

function lib:LoadProfile(settings, name, catalogs)
	if not settings or not name then return false end
	if not settings.profiles or not settings.profiles[name] then
		return false
	end
	
	local profile = settings.profiles[name]
	settings.globalRangeFallbackYards = profile.globalRangeFallbackYards or 5
	settings.rangeProxySpells = profile.rangeProxySpells and deepcopy(profile.rangeProxySpells) or {}
	-- Legacy profile compat
	if profile.globalRangeFallbackYards == nil and profile.globalRangeFallback ~= nil then
		local leg = LibStub("LibGCDI-Range", true)
		if leg and leg.LEGACY_INDEX_TO_YARDS and leg.LEGACY_INDEX_TO_YARDS[profile.globalRangeFallback] then
			settings.globalRangeFallbackYards = leg.LEGACY_INDEX_TO_YARDS[profile.globalRangeFallback]
		end
	end
	if profile.rangeProxySpellIDs and type(profile.rangeProxySpellIDs) == "table" then
		local leg = LibStub("LibGCDI-Range", true)
		if leg and leg.LEGACY_INDEX_TO_YARDS then
			for idx, yards in pairs(leg.LEGACY_INDEX_TO_YARDS) do
				if profile.rangeProxySpellIDs[idx] and not settings.rangeProxySpells[yards] then
					settings.rangeProxySpells[yards] = profile.rangeProxySpellIDs[idx]
				end
			end
		end
	end
	settings.spellSettings = deepcopy(profile.spellSettings or {})
	settings.spellOrder = deepcopy(profile.spellOrder or {})
	settings.itemSettings = deepcopy(profile.itemSettings or {})
	settings.itemOrder = deepcopy(profile.itemOrder or {})
	settings.buffSettings = deepcopy(profile.buffSettings or {})
	settings.buffOrder = deepcopy(profile.buffOrder or {})
	settings.resourceSettings = deepcopy(profile.resourceSettings or {})
	settings.gcdSettings = deepcopy(profile.gcdSettings or {})
	settings.currentProfile = name

	if catalogs then
		if profile.spellCatalog then
			for k in pairs(catalogs.spellCatalog or {}) do
				catalogs.spellCatalog[k] = nil
			end
			for k, v in pairs(profile.spellCatalog) do
				catalogs.spellCatalog[k] = deepcopy(v)
			end
		end
		if profile.itemCatalog then
			for k in pairs(catalogs.itemCatalog or {}) do
				catalogs.itemCatalog[k] = nil
			end
			for k, v in pairs(profile.itemCatalog) do
				catalogs.itemCatalog[k] = deepcopy(v)
			end
		end
		if profile.buffCatalog then
			for k in pairs(catalogs.buffCatalog or {}) do
				catalogs.buffCatalog[k] = nil
			end
			for k, v in pairs(profile.buffCatalog) do
				catalogs.buffCatalog[k] = deepcopy(v)
			end
		end
	end
	
	return true
end

function lib:DeleteProfile(settings, name)
	if not settings or not name then return false end
	if not settings.profiles or not settings.profiles[name] then return false end
	
	settings.profiles[name] = nil
	if settings.currentProfile == name then
		settings.currentProfile = nil
	end
	return true
end

function lib:AutoSave(settings, catalogs)
	if not settings or not settings.currentProfile then return end
	self:SaveProfile(settings, settings.currentProfile, catalogs)
end

-- key -> classFileName tokens (UnitClass("player")'s 2nd return) that can use
-- this resource across all of that class's specs/forms; a key absent from
-- this table (health) applies to every class. Mirrors LibGCDI-Options's
-- RESOURCE_NAMES.classTokens, which drives the Resources tab checkbox rows.
local RESOURCE_CLASS_TOKENS = {
	mana = { "MAGE", "PRIEST", "WARLOCK", "PALADIN", "DRUID", "SHAMAN", "MONK", "EVOKER" },
	rage = { "WARRIOR", "DRUID" },
	energy = { "ROGUE", "DRUID", "MONK" },
	focus = { "HUNTER" },
	runicPower = { "DEATHKNIGHT" },
	runes = { "DEATHKNIGHT" },
	comboPoints = { "ROGUE", "DRUID" },
	soulShards = { "WARLOCK" },
	holyPower = { "PALADIN" },
	chi = { "MONK" },
	arcaneCharges = { "MAGE" },
	insanity = { "PRIEST" },
	maelstrom = { "SHAMAN" },
	fury = { "DEMONHUNTER" },
	pain = { "DEMONHUNTER" },
	astralPower = { "DRUID" },
	essence = { "EVOKER" },
	stagger = { "MONK" },
}
lib.RESOURCE_CLASS_TOKENS = RESOURCE_CLASS_TOKENS

local function resource_applies_to_class(key, classToken)
	local tokens = RESOURCE_CLASS_TOKENS[key]
	if not tokens then return true end
	for _, token in ipairs(tokens) do
		if token == classToken then return true end
	end
	return false
end
lib.ResourceAppliesToClass = resource_applies_to_class

-- Fresh resourceSettings table for `classToken`: enabled for health and every
-- resource that class can use, disabled for everything else. Stagger always
-- starts disabled even for Monks, matching the pre-existing standalone default.
function lib:GetClassResourceDefaults(classToken)
	local defaults = { health = true, stagger = false }
	for key in pairs(RESOURCE_CLASS_TOKENS) do
		if key ~= "stagger" then
			defaults[key] = resource_applies_to_class(key, classToken)
		end
	end
	return defaults
end

-- Disables any resourceSettings entry `classToken` can't use (e.g. leftover
-- Mana=true after switching to a Rogue). Returns true if it changed anything,
-- so callers can prompt the user to resave the profile with the fix applied.
function lib:EnforceClassResources(settings, classToken)
	if not settings or not settings.resourceSettings then return false end
	local changed = false
	for key, enabled in pairs(settings.resourceSettings) do
		if enabled and not resource_applies_to_class(key, classToken) then
			settings.resourceSettings[key] = false
			changed = true
		end
	end
	return changed
end

function lib:GetProfileNames(settings)
	local names = {}
	if settings and settings.profiles then
		for name in pairs(settings.profiles) do
			table.insert(names, name)
		end
		table.sort(names)
	end
	return names
end

function lib:ExportSettings(settings)
	local exportData = {
		v = 1,
		gy = settings.globalRangeFallbackYards,
		rp = settings.rangeProxySpells,
		ss = spell_settings_for_save(settings.spellSettings or {}),
		so = settings.spellOrder or {},
		is = settings.itemSettings or {},
		io = settings.itemOrder or {},
		bs = settings.buffSettings or {},
		bo = settings.buffOrder or {},
		rs = settings.resourceSettings or {},
		gs = settings.gcdSettings or {},
	}
	
	local ok, str = pcall(serialize_compact, exportData)
	if ok then
		return str
	end
	return nil
end

function lib:ImportSettings(str)
	return deserialize_compact(str)
end
