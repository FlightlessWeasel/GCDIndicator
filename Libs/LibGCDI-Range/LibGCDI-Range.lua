-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-Range - Range Indicator Management for GCDIndicator
-- ═══════════════════════════════════════════════════════════════════════════

local MAJOR, MINOR = "LibGCDI-Range", 5
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- Cache frequently used globals
local UnitExists = UnitExists
local UnitCanAttack = UnitCanAttack
local IsActionInRange = IsActionInRange
local InCombatLockdown = InCombatLockdown
local C_Spell = C_Spell
local pairs = pairs
local ipairs = ipairs

-- ═══════════════════════════════════════════════════════════════════════════
-- LIBRANGECHECK HANDLE (resolved once, not per spell per update)
-- ═══════════════════════════════════════════════════════════════════════════

-- LibStub lookup + rc:init() used to run inside the per-spell loop, i.e. once per
-- spell per tick. Both are idempotent, so resolve them a single time.
local rangeCheckLib = nil
local rangeCheckResolved = false

local function get_range_check()
	if not rangeCheckResolved then
		rangeCheckResolved = true
		local rc = LibStub("LibGCDI-RangeCheck", true)
		if rc then
			rc:init()
			rangeCheckLib = rc
		end
	end
	return rangeCheckLib
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELL RANGE METADATA CACHE
-- ═══════════════════════════════════════════════════════════════════════════

-- C_Spell.GetSpellInfo allocates a fresh table on every call; it was being called
-- once per spell per tick purely to read maxRange. maxRange / SpellHasRange only
-- change when the spellbook does, so cache them and clear on SPELLS_CHANGED.
local spellHasRangeCache = {}
local spellMaxRangeCache = {}

function lib:InvalidateSpellRangeCache()
	wipe(spellHasRangeCache)
	wipe(spellMaxRangeCache)
end

local function spell_has_range(spellID)
	local cached = spellHasRangeCache[spellID]
	if cached == nil then
		cached = C_Spell.SpellHasRange(spellID) and true or false
		spellHasRangeCache[spellID] = cached
	end
	return cached
end

local function spell_max_range(spellID)
	local cached = spellMaxRangeCache[spellID]
	if cached == nil then
		cached = false
		if spell_has_range(spellID) then
			local si = C_Spell.GetSpellInfo(spellID)
			if si and si.maxRange and si.maxRange > 0 then
				cached = si.maxRange
			end
		end
		spellMaxRangeCache[spellID] = cached
	end
	if cached == false then return nil end
	return cached
end

lib.SpellHasRangeCached = function(_, spellID) return spell_has_range(spellID) end

-- ═══════════════════════════════════════════════════════════════════════════
-- RANGE COLORS
-- ═══════════════════════════════════════════════════════════════════════════

lib.RANGE_COLORS = {
	inRange = { 0.0, 0.8, 0.0 },    -- Green
	outOfRange = { 0.8, 0.0, 0.0 }, -- Red
	noTarget = { 0.3, 0.3, 0.3 },   -- Grey
}

-- ═══════════════════════════════════════════════════════════════════════════
-- RANGE BRACKETS keyed by yards (display names only; range checked via proxy spells in combat)
-- ═══════════════════════════════════════════════════════════════════════════

lib.RANGE_ITEMS = {
	[0]  = { name = "No Range (Grey)", yards = 0 },
	[5]  = { name = "Melee (5 yards)", yards = 5 },
	[8]  = { name = "8 yards", yards = 8 },
	[10] = { name = "10 yards", yards = 10 },
	[12] = { name = "12 yards", yards = 12 },
	[13] = { name = "13 yards", yards = 13 },
	[15] = { name = "15 yards", yards = 15 },
	[20] = { name = "20 yards", yards = 20 },
	[25] = { name = "25 yards", yards = 25 },
	[30] = { name = "30 yards", yards = 30 },
	[35] = { name = "35 yards", yards = 35 },
	[40] = { name = "40 yards", yards = 40 },
}

-- Display order (pairs iteration order not guaranteed)
lib.RANGE_YARDS_ORDER = { 0, 5, 8, 10, 12, 13, 15, 20, 25, 30, 35, 40 }

-- Legacy: convert old index (0-11) to yards for migration
lib.LEGACY_INDEX_TO_YARDS = { [0]=0, [1]=5, [2]=8, [3]=10, [4]=12, [5]=13, [6]=15, [7]=20, [8]=25, [9]=30, [10]=35, [11]=40 }

-- ═══════════════════════════════════════════════════════════════════════════
-- INTERNAL STATE
-- ═══════════════════════════════════════════════════════════════════════════

-- Callbacks for accessing addon state
lib.callbacks = {
	getSettings = nil,       -- function() return settings end
	getSpellSettings = nil,  -- function(spellID) return settings.spellSettings[spellID] end
	setSpellSetting = nil,   -- function(spellID, key, value)
	isSpellEnabled = nil,    -- function(spellID) return bool end
	getTrackedSpells = nil,  -- function() return trackedSpells end
	getSpellBars = nil,      -- function() return spellBars end
	getSpellCatalog = nil,   -- function() return spellCatalog end
	isPreviewMode = nil,     -- function() return previewMode end
	debugPrint = nil,        -- function(msg) end
}

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Valid callback keys
local VALID_CALLBACKS = {
	getSettings = true,
	getSpellSettings = true,
	setSpellSetting = true,
	isSpellEnabled = true,
	getTrackedSpells = true,
	getSpellBars = true,
	getSpellCatalog = true,
	isPreviewMode = true,
	debugPrint = true,
}

-- Initialize the library with callbacks to access addon state
-- @param callbacks: Table of callback functions
function lib:Init(callbacks)
	if callbacks then
		for key, func in pairs(callbacks) do
			if VALID_CALLBACKS[key] then
				lib.callbacks[key] = func
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RANGE HELPER FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Get range fallback yards for a spell (stable key; no index)
-- @param spellID: The spell ID
-- @return number: Yards (0, 5, 8, 10, ... 40); nil means use global
function lib:GetRangeFallbackYards(spellID)
	local getSettings = lib.callbacks.getSettings
	if not getSettings then return 5 end
	
	local settings = getSettings()
	if not settings then return 5 end
	
	local spellSettings = settings.spellSettings and settings.spellSettings[spellID]
	if spellSettings then
		if spellSettings.rangeFallbackYards ~= nil then
			return spellSettings.rangeFallbackYards
		end
		-- Legacy: index -> yards
		if spellSettings.rangeFallback ~= nil and lib.LEGACY_INDEX_TO_YARDS[spellSettings.rangeFallback] ~= nil then
			return lib.LEGACY_INDEX_TO_YARDS[spellSettings.rangeFallback]
		end
	end
	
	if settings.globalRangeFallbackYards ~= nil then
		return settings.globalRangeFallbackYards
	end
	-- Legacy
	if settings.globalRangeFallback ~= nil and lib.LEGACY_INDEX_TO_YARDS[settings.globalRangeFallback] ~= nil then
		return lib.LEGACY_INDEX_TO_YARDS[settings.globalRangeFallback]
	end
	return 5
end

-- Check if spell is self-cast (no target needed)
-- @param spellID: The spell ID
-- @return boolean
function lib:IsSpellSelfCast(spellID)
	local getSettings = lib.callbacks.getSettings
	if not getSettings then return false end
	
	local settings = getSettings()
	if not settings then return false end
	
	local spellSettings = settings.spellSettings and settings.spellSettings[spellID]
	if spellSettings and spellSettings.selfCast == true then
		return true
	end
	return false
end

-- Auto-detect if a spell is self-cast based on IsActionInRange returning nil
-- @param spellID: The spell ID
-- @param actionSlot: The action bar slot
-- @return boolean: true if detected as self-cast
function lib:AutoDetectSelfCast(spellID, actionSlot)
	local getSettings = lib.callbacks.getSettings
	local setSpellSetting = lib.callbacks.setSpellSetting
	
	if not getSettings or not actionSlot then return false end
	
	local settings = getSettings()
	if not settings then return false end
	
	local spellSettings = settings.spellSettings and settings.spellSettings[spellID]
	if spellSettings and spellSettings.selfCast ~= nil then
		return spellSettings.selfCast == true
	end
	
	if not UnitExists("target") or not UnitCanAttack("player", "target") then
		return false
	end
	
	local inRange = IsActionInRange(actionSlot)
	if inRange == nil then
		-- Mark as self-cast
		if setSpellSetting then
			setSpellSetting(spellID, "selfCast", true)
		end
		return true
	end
	return false
end

-- Check if spell has a range override set
-- @param spellID: The spell ID
-- @return boolean
function lib:HasRangeOverride(spellID)
	local getSettings = lib.callbacks.getSettings
	if not getSettings then return false end
	
	local settings = getSettings()
	if not settings then return false end
	
	local spellSettings = settings.spellSettings and settings.spellSettings[spellID]
	if not spellSettings then return false end
	if spellSettings.rangeFallbackYards ~= nil then return true end
	-- Legacy
	return spellSettings.rangeFallback ~= nil
end

-- Check if spell has native range setting detected
-- @param spellID: The spell ID
-- @return boolean
function lib:HasNativeRangeSetting(spellID)
	local getSettings = lib.callbacks.getSettings
	if not getSettings then return false end
	
	local settings = getSettings()
	if not settings then return false end
	
	local spellSettings = settings.spellSettings and settings.spellSettings[spellID]
	return spellSettings and spellSettings.hasNativeRange == true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RANGE DETECTION
-- ═══════════════════════════════════════════════════════════════════════════

-- Auto-detect native range for all tracked spells
-- Should be called on PLAYER_TARGET_CHANGED
function lib:DetectNativeRangeForSpells()
	if not UnitExists("target") then return end
	
	local getTrackedSpells = lib.callbacks.getTrackedSpells
	local isSpellEnabled = lib.callbacks.isSpellEnabled
	local getSettings = lib.callbacks.getSettings
	local setSpellSetting = lib.callbacks.setSpellSetting
	local getSpellCatalog = lib.callbacks.getSpellCatalog
	local debugPrint = lib.callbacks.debugPrint
	
	if not getTrackedSpells or not isSpellEnabled or not getSettings then return end
	
	local trackedSpells = getTrackedSpells()
	local settings = getSettings()
	local spellCatalog = getSpellCatalog and getSpellCatalog() or {}
	
	for spellID, data in pairs(trackedSpells) do
		if isSpellEnabled(spellID) then
			local actionSlot = data.actionSlot
			if actionSlot then
				local rangeResult = IsActionInRange(actionSlot)
				if rangeResult ~= nil then
					-- This spell has native range detection
					local spellSettings = settings.spellSettings and settings.spellSettings[spellID]
					if not spellSettings or spellSettings.hasNativeRange ~= true then
						if setSpellSetting then
							setSpellSetting(spellID, "hasNativeRange", true)
						end
						if debugPrint then
							local name = spellCatalog[spellID] and spellCatalog[spellID].name or spellID
							debugPrint("Native range detected for: " .. tostring(name))
						end
					end
				end
			end
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-RangeCheck (optional; first-party, trimmed fork of LibRangeCheck-3.0)
-- ═══════════════════════════════════════════════════════════════════════════

-- Collapse LibRangeCheck:GetRange() min/max band to boolean vs a yard cap (like RangeDisplay's estimate, but binary).
-- GetSmartMaxChecker alone can return non-boolean; GetRange() uses the full checker ladder (more granular).
local function rangeBandVersusYardLimit(minR, maxR, yardLimit)
	if not yardLimit or yardLimit <= 0 then
		return nil
	end
	if minR == nil and maxR == nil then
		return nil
	end
	-- Entirely past the cap
	if minR ~= nil and minR > yardLimit then
		return false
	end
	-- Entire band at or inside the cap
	if maxR ~= nil and maxR <= yardLimit then
		return true
	end
	-- Band is from yardLimit upward (e.g. 5–8 yd vs 5 yd melee): treat as out, not grey
	if minR ~= nil and maxR ~= nil and maxR > yardLimit and minR >= yardLimit then
		return false
	end
	-- Coarse band straddles the cap (e.g. 0–8 yd while cap is 5): unknown
	if minR ~= nil and maxR ~= nil and minR < yardLimit and maxR > yardLimit then
		return nil
	end
	if maxR == nil and minR ~= nil and minR <= yardLimit then
		return nil
	end
	return nil
end

-- When enabled in settings.gcdSettings.useLibRangeCheck, uses LibRangeCheck's
-- GetSmartMaxChecker (spell/item/interact ladder) so range colors stay accurate in combat
-- when C_Spell / action range is missing or unreliable.
-- @return true|false if determined, nil to continue with the default pipeline
function lib:TryRangeWithLibRangeCheck(spellID, useOverride, inCombat)
	local getSettings = lib.callbacks.getSettings
	local settings = getSettings and getSettings()
	if not settings or not settings.gcdSettings or not settings.gcdSettings.useLibRangeCheck then
		return nil
	end
	local rc = get_range_check()
	if not rc then
		return nil
	end

	local yardLimit = nil
	if useOverride then
		local ry = lib:GetRangeFallbackYards(spellID)
		if ry and ry > 0 then
			yardLimit = ry
		end
	end
	if yardLimit == nil then
		yardLimit = spell_max_range(spellID)
	end
	if not yardLimit or yardLimit <= 0 then
		return nil
	end

	local checker = rc:GetSmartMaxChecker(yardLimit, inCombat)
	if not checker then
		return nil
	end
	local ok = checker("target")
	if type(ok) == "boolean" then
		return ok
	end
	-- Match RangeDisplay-style granularity: full checker ladder via GetRange(), not only SmartMaxChecker
	local minR, maxR = rc:GetRange("target", false, false, 0.05)
	local band = rangeBandVersusYardLimit(minR, maxR, yardLimit)
	if type(band) == "boolean" then
		return band
	end
	return nil
end

-- When settings.gcdSettings.useLibRangeCheck is enabled: yard check via LibRangeCheck (e.g. nameplate units).
-- @return true|false if determined, nil if disabled, library missing, or checker cannot decide
function lib:IsUnitInRangeYardsLRC(unit, yards, inCombat)
	if not unit or not yards or yards <= 0 then
		return nil
	end
	local getSettings = lib.callbacks.getSettings
	local settings = getSettings and getSettings()
	if not settings or not settings.gcdSettings or not settings.gcdSettings.useLibRangeCheck then
		return nil
	end
	local rc = get_range_check()
	if not rc then
		return nil
	end
	local checker = rc:GetSmartMaxChecker(yards, inCombat)
	if not checker then
		return nil
	end
	local ok = checker(unit)
	if type(ok) == "boolean" then
		return ok
	end
	local minR, maxR = rc:GetRange(unit, false, false, 0.05)
	local band = rangeBandVersusYardLimit(minR, maxR, yards)
	if type(band) == "boolean" then
		return band
	end
	return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RANGE INDICATOR UPDATES
-- ═══════════════════════════════════════════════════════════════════════════

-- Indicator writes are dirty-checked: this runs on the shared update ticker, and
-- unconditional Show/Hide/SetColorTexture calls were the bulk of its cost even
-- when nothing about the range state had actually changed.

local function set_range_shown(spellData, shown)
	if spellData.rangeShownState == shown then return end
	spellData.rangeShownState = shown
	if shown then
		if spellData.rangeBase then spellData.rangeBase:Show() end
		spellData.rangeOverlay:Show()
	else
		if spellData.rangeBase then spellData.rangeBase:Hide() end
		spellData.rangeOverlay:Hide()
	end
end

local function set_range_color(spellData, state, color)
	if spellData.rangeColorState == state then return end
	spellData.rangeColorState = state
	spellData.rangeOverlay:SetColorTexture(color[1], color[2], color[3], 1)
end

-- Anything that writes rangeOverlay outside this file (preview mode) must clear the
-- cached state, or the next update will believe the indicator is already correct.
function lib:ResetIndicatorState()
	local getTrackedSpells = lib.callbacks.getTrackedSpells
	if not getTrackedSpells then return end
	local trackedSpells = getTrackedSpells()
	if not trackedSpells then return end
	for _, spellData in pairs(trackedSpells) do
		spellData.rangeShownState = nil
		spellData.rangeColorState = nil
		-- Also drop the stale fallback range cache: leaving it set here let a
		-- prior in-range/out-of-range reading survive a retarget or a preview
		-- toggle and get silently reused as if it were fresh (see the
		-- cachedFallbackInRange usage in UpdateRangeIndicators below).
		spellData.cachedFallbackInRange = nil
	end
end

-- Update all range indicators for tracked spells
function lib:UpdateRangeIndicators()
	local isPreviewMode = lib.callbacks.isPreviewMode
	if isPreviewMode and isPreviewMode() then return end

	local getSpellBars = lib.callbacks.getSpellBars
	local getTrackedSpells = lib.callbacks.getTrackedSpells
	local isSpellEnabled = lib.callbacks.isSpellEnabled

	if not getSpellBars or not getTrackedSpells or not isSpellEnabled then return end

	local spellBars = getSpellBars()
	local trackedSpells = getTrackedSpells()
	local colors = lib.RANGE_COLORS

	-- Loop invariants: these were re-evaluated once per spell per tick.
	local getSettings = lib.callbacks.getSettings
	local settings = getSettings and getSettings()
	local useLRC = settings and settings.gcdSettings and settings.gcdSettings.useLibRangeCheck == true
	local inCombat = InCombatLockdown()
	local hasTarget = UnitExists("target") and true or false

	for i, spellID in ipairs(spellBars) do
		local spellData = trackedSpells[spellID]
		if spellData and spellData.rangeOverlay and isSpellEnabled(spellID) then
			local overlay = spellData.rangeOverlay
			local actionSlot = spellData.actionSlot

			if lib:IsSpellSelfCast(spellID) then
				-- Hide both base and overlay for self-cast spells
				set_range_shown(spellData, false)
			else
				-- Show both for non-self-cast spells
				set_range_shown(spellData, true)

				if not hasTarget then
					set_range_color(spellData, "none", colors.noTarget)
				else
					local useOverride = lib:HasRangeOverride(spellID)
					local inRange = nil

					local lrcVal = lib:TryRangeWithLibRangeCheck(spellID, useOverride, inCombat)
					if type(lrcVal) == "boolean" then
						inRange = lrcVal
						if useOverride then
							spellData.cachedFallbackInRange = lrcVal
						end
					elseif useLRC and useOverride then
						-- LibRangeCheck often returns nil when it cannot evaluate a tick; keeping an old
						-- cached true here reused "in range" green until retarget (RangeDisplay avoids this).
						spellData.cachedFallbackInRange = nil
					end
					
					-- Only use spell's native range when user has NOT set a range override
					if inRange == nil and not useOverride and spell_has_range(spellID) then
						local spellInRange = C_Spell.IsSpellInRange(spellID, "target")
						if spellInRange ~= nil then
							inRange = spellInRange
						end
					end
					
					-- User chose a range override: proxy spell only, then cache (cache not used with LRC; see below)
					if inRange == nil and useOverride then
						local rangeYards = lib:GetRangeFallbackYards(spellID)
						local proxySpells = settings and settings.rangeProxySpells
						local proxyID = proxySpells and proxySpells[rangeYards]
						-- Legacy: fall back to rangeProxySpellIDs[index]
						if not proxyID and settings and settings.rangeProxySpellIDs then
							for idx, yards in pairs(lib.LEGACY_INDEX_TO_YARDS) do
								if yards == rangeYards then
									proxyID = settings.rangeProxySpellIDs[idx]
									break
								end
							end
						end
						if proxyID and rangeYards and rangeYards > 0 and spell_has_range(proxyID) then
							local proxyInRange = C_Spell.IsSpellInRange(proxyID, "target")
							if proxyInRange ~= nil then
								inRange = proxyInRange
								spellData.cachedFallbackInRange = proxyInRange
							end
						end
						-- Stale cache caused stuck green in combat when LRC returned nil after a prior true.
						if inRange == nil and spellData.cachedFallbackInRange ~= nil and not useLRC then
							inRange = spellData.cachedFallbackInRange
						end
					end
					
					if inRange == nil and actionSlot and not inCombat then
						-- IsActionInRange is protected in combat; use only when safe
						local nativeRange = IsActionInRange(actionSlot)
						if nativeRange ~= nil then
							inRange = nativeRange
							-- Mark as having native range if not already
							if not lib:HasNativeRangeSetting(spellID) then
								local setSpellSetting = lib.callbacks.setSpellSetting
								if setSpellSetting then
									setSpellSetting(spellID, "hasNativeRange", true)
								end
							end
						else
							-- Native range returned nil (self-cast or no range)
							-- Try auto-detect self-cast
							if lib:AutoDetectSelfCast(spellID, actionSlot) then
								set_range_shown(spellData, false)
								inRange = "selfcast"
							end
						end
					end

					-- Apply the color based on result
					if inRange == "selfcast" then
						-- Already handled above (hidden)
					elseif inRange == true then
						set_range_color(spellData, "in", colors.inRange)
					elseif inRange == false then
						set_range_color(spellData, "out", colors.outOfRange)
					else
						-- No range info available - use grey
						set_range_color(spellData, "none", colors.noTarget)
					end
				end
			end
		end
	end
end
