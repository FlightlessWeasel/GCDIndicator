-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-Range - Range Indicator Management for GCDIndicator
-- ═══════════════════════════════════════════════════════════════════════════

local MAJOR, MINOR = "LibGCDI-Range", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- Cache frequently used globals
local UnitExists = UnitExists
local UnitCanAttack = UnitCanAttack
local IsActionInRange = IsActionInRange
local C_Item = C_Item
local pairs = pairs
local ipairs = ipairs

-- ═══════════════════════════════════════════════════════════════════════════
-- RANGE COLORS
-- ═══════════════════════════════════════════════════════════════════════════

lib.RANGE_COLORS = {
	inRange = { 0.0, 0.8, 0.0 },    -- Green
	outOfRange = { 0.8, 0.0, 0.0 }, -- Red
	noTarget = { 0.3, 0.3, 0.3 },   -- Grey
}

-- ═══════════════════════════════════════════════════════════════════════════
-- RANGE ITEMS (for fallback range detection)
-- ═══════════════════════════════════════════════════════════════════════════

lib.RANGE_ITEMS = {
	[0] = { id = nil, name = "No Range (Grey)", yards = 0 },
	[1] = { id = 37727,  name = "Melee (5 yards)", yards = 5 },
	[2] = { id = 63427,  name = "Close (8 yards)", yards = 8 },
	[3] = { id = 34368,  name = "Short (10 yards)", yards = 10 },
	[4] = { id = 32321,  name = "Medium (15 yards)", yards = 15 },
	[5] = { id = 21519,  name = "Mid-Range (20 yards)", yards = 20 },
	[6] = { id = 116139, name = "Long (25 yards)", yards = 25 },
	[7] = { id = 33069,  name = "Ranged (30 yards)", yards = 30 },
	[8] = { id = 35278,  name = "Far (35 yards)", yards = 35 },
	[9] = { id = 41509,  name = "Max Range (40 yards)", yards = 40 },
}

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

-- Get range fallback index for a spell
-- @param spellID: The spell ID
-- @return number: Range item index (0-9)
function lib:GetRangeFallbackIndex(spellID)
	local getSettings = lib.callbacks.getSettings
	if not getSettings then return 0 end
	
	local settings = getSettings()
	if not settings then return 0 end
	
	local spellSettings = settings.spellSettings and settings.spellSettings[spellID]
	if spellSettings and spellSettings.rangeFallback ~= nil then
		return spellSettings.rangeFallback
	end
	
	return settings.globalRangeFallback or 0
end

-- Check if target is in fallback range for a spell
-- @param spellID: The spell ID
-- @return boolean or nil: true if in range, false if out, nil if no check possible
function lib:IsInFallbackRange(spellID)
	local rangeIndex = lib:GetRangeFallbackIndex(spellID)
	local item = lib.RANGE_ITEMS[rangeIndex]
	
	if not item or not item.id then
		return nil
	end
	
	local result = C_Item.IsItemInRange(item.id, "target")
	return result == true
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
	return spellSettings and spellSettings.rangeFallback ~= nil
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
-- RANGE INDICATOR UPDATES
-- ═══════════════════════════════════════════════════════════════════════════

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
	
	for i, spellID in ipairs(spellBars) do
		local spellData = trackedSpells[spellID]
		if spellData and spellData.rangeOverlay and isSpellEnabled(spellID) then
			local overlay = spellData.rangeOverlay
			local actionSlot = spellData.actionSlot
			
			if lib:IsSpellSelfCast(spellID) then
				-- Hide both base and overlay for self-cast spells
				if spellData.rangeBase then spellData.rangeBase:Hide() end
				overlay:Hide()
			else
				-- Show both for non-self-cast spells
				if spellData.rangeBase then spellData.rangeBase:Show() end
				overlay:Show()
				
				if not UnitExists("target") then
					overlay:SetColorTexture(colors.noTarget[1], colors.noTarget[2], colors.noTarget[3], 1)
				else
					local useOverride = lib:HasRangeOverride(spellID)
					local inRange = nil
					
					if useOverride then
						-- User has explicitly set a range fallback for this spell
						local fallbackResult = lib:IsInFallbackRange(spellID)
						if fallbackResult ~= nil then
							inRange = fallbackResult
						end
					elseif actionSlot then
						-- Try native range detection first if we have an action slot
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
								if spellData.rangeBase then spellData.rangeBase:Hide() end
								overlay:Hide()
								inRange = "selfcast"
							end
						end
					end
					
					-- Fallback to item-based range if native didn't work
					if inRange == nil then
						local fallbackResult = lib:IsInFallbackRange(spellID)
						if fallbackResult ~= nil then
							inRange = fallbackResult
						end
					end
					
					-- Apply the color based on result
					if inRange == "selfcast" then
						-- Already handled above (hidden)
					elseif inRange == true then
						overlay:SetColorTexture(colors.inRange[1], colors.inRange[2], colors.inRange[3], 1)
					elseif inRange == false then
						overlay:SetColorTexture(colors.outOfRange[1], colors.outOfRange[2], colors.outOfRange[3], 1)
					else
						-- No range info available - use grey
						overlay:SetColorTexture(colors.noTarget[1], colors.noTarget[2], colors.noTarget[3], 1)
					end
				end
			end
		end
	end
end
