-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-Profiles - Profile Management for GCDIndicator
-- ═══════════════════════════════════════════════════════════════════════════

local MAJOR, MINOR = "LibGCDI-Profiles", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Deep copy a table, skipping frames and functions
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
			-- skip functions
		elseif vtype == 'table' and type(v.GetObjectType) == 'function' then
			-- skip WoW frame objects
		elseif vtype == 'userdata' then
			-- skip userdata
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

-- ═══════════════════════════════════════════════════════════════════════════
-- SERIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Compact serialization for export (one line, minimal whitespace)
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

-- Deserialize compact format back to a table
local function deserialize_compact(str)
	str = str:gsub("=t,", "=true,"):gsub("=t}", "=true}")
	str = str:gsub("=f,", "=false,"):gsub("=f}", "=false}")
	
	local func, err = loadstring("return " .. str)
	if not func then
		return nil, "Parse error: " .. tostring(err)
	end
	setfenv(func, {})
	local ok, result = pcall(func)
	if not ok then
		return nil, "Execution error: " .. tostring(result)
	end
	if type(result) ~= "table" then
		return nil, "Invalid data"
	end
	return result
end

lib.deserialize = deserialize_compact

-- ═══════════════════════════════════════════════════════════════════════════
-- PROFILE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

-- Save a profile
-- @param settings: The settings table to save to
-- @param name: Profile name
-- @param catalogs: Table containing {spellCatalog, itemCatalog, buffCatalog}
-- @return boolean: Success
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
	
	-- Save catalogs if provided
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

-- Load a profile
-- @param settings: The settings table to load into
-- @param name: Profile name
-- @param catalogs: Table to load catalogs into (optional)
-- @return boolean: Success
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
	
	-- Load catalogs if container provided
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

-- Delete a profile
-- @param settings: The settings table
-- @param name: Profile name to delete
-- @return boolean: Success
function lib:DeleteProfile(settings, name)
	if not settings or not name then return false end
	if not settings.profiles or not settings.profiles[name] then return false end
	
	settings.profiles[name] = nil
	if settings.currentProfile == name then
		settings.currentProfile = nil
	end
	return true
end

-- Auto-save to current profile
-- @param settings: The settings table
-- @param catalogs: Table containing {spellCatalog, itemCatalog, buffCatalog}
function lib:AutoSave(settings, catalogs)
	if not settings or not settings.currentProfile then return end
	self:SaveProfile(settings, settings.currentProfile, catalogs)
end

-- Get list of profile names
-- @param settings: The settings table
-- @return table: Sorted list of profile names
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

-- Export settings to string
-- @param settings: Settings to export
-- @return string: Serialized settings string, or nil on error
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

-- Import settings from string
-- @param str: Serialized settings string
-- @return table: Deserialized settings, or nil and error message
function lib:ImportSettings(str)
	return deserialize_compact(str)
end
