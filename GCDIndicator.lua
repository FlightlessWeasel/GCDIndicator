-- ═══════════════════════════════════════════════════════════════════════════
-- GCDIndicator - GCD and Spell Cooldown Tracker
-- ═══════════════════════════════════════════════════════════════════════════

-- Global namespace for module access
GCDI = {}

-- Configuration
GCDI.configs = {
	size = 10,
	xpoint = 20,  -- Default X offset from left edge
	ypoint = -5,  -- Default Y offset from top edge
	barSpacing = 0,
	barHeight = 8,
	bgPadding = 2,
	debugMode = false,
}
local configs = GCDI.configs

-- Cache frequently used globals
local CreateFrame = CreateFrame
local GetActionInfo = GetActionInfo
local GetMacroSpell = GetMacroSpell
local InCombatLockdown = InCombatLockdown
local UnitAffectingCombat = UnitAffectingCombat
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local C_Spell = C_Spell
local C_Timer = C_Timer
local pairs = pairs
local wipe = wipe

-- Forward declare functions
local save_profile, delete_profile

-- Constants
local GCD_SPELL_ID = 61304
local INTERPOLATION = Enum.StatusBarInterpolation.ExponentialEaseOut
local DIRECTION = Enum.StatusBarTimerDirection.RemainingTime

-- State
local main_frame = CreateFrame("Frame", "GCDIndicatorFrame", UIParent)
GCDI.trackedSpells = {}
GCDI.spellCatalog = {}
GCDI.itemCatalog = {}
local trackedSpells = GCDI.trackedSpells
local spellBars = {}
local trackedItems = {}
local itemBars = {}
local pendingScanTimer = nil
local resourceBars = {}
local previewMode = false  -- Preview mode state for positioning

-- Known item types
local TRACKED_ITEM_TYPES = {
	trinket1 = { slot = 13, name = "Trinket 1" },
	trinket2 = { slot = 14, name = "Trinket 2" },
}

-- Buff tracking via Cooldown Manager integration
-- Blizzard's CDM frames have non-secret properties we can read:
-- frame.cooldownID, frame.auraInstanceID (isActive is SECRET - don't use!)
GCDI.buffCatalog = {}
local trackedBuffs = {}
local buffBars = {}
local cdmBuffFrames = {}  -- cooldownID -> CDM frame reference

local CONSUMABLE_ITEM_IDS = {
	[5512] = "Healthstone",
	[191380] = "Refreshing Healing Potion",
	[191381] = "Potion of Withering Dreams",
	[211878] = "Algari Healing Potion",
	[212241] = "Cavedweller's Delight",
	[224464] = "Potion of Unwavering Focus",
}

local actionBarItems = {}

local RESOURCE_COLORS = {
	health = { 0.0, 0.8, 0.0 },
	rage = { 0.8, 0.0, 0.0 },
	energy = { 1.0, 0.85, 0.0 },
	comboPoints = { 1.0, 0.5, 0.0 },
}

local RANGE_COLORS = {
	inRange = { 0.0, 0.8, 0.0 },
	outOfRange = { 0.8, 0.0, 0.0 },
	noTarget = { 0.3, 0.3, 0.3 },
}

GCDI.RANGE_ITEMS = {
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
local RANGE_ITEMS = GCDI.RANGE_ITEMS

local DEFAULT_SETTINGS = {
	globalRangeFallback = 0,
	spellSettings = {},
	spellOrder = {},
	itemSettings = {},
	itemOrder = {},
	buffSettings = {},
	buffOrder = {},
	profiles = {},
	currentProfile = nil,
}

-- Settings reference
GCDI.settings = nil
local settings = nil

local FORM_COLORS = {
	[0] = { 0.5, 0.5, 0.5 },
	[1] = { 0.6, 0.4, 0.2 },
	[2] = { 1.0, 0.6, 0.2 },
	[3] = { 0.3, 0.6, 1.0 },
	[4] = { 0.2, 0.8, 0.4 },
	[5] = { 0.8, 0.8, 1.0 },
	default = { 0.7, 0.7, 0.7 },
}

-- Forward declarations
local reposition_all, rebuild_spell_bars, rebuild_item_bars, rebuild_buff_bars

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

local function debug(msg)
	if configs.debugMode then
		print("|cff00ff00GCDIndicator:|r " .. msg)
	end
end

local function applyTimerToBar(bar, durObj)
	if durObj then
		bar:SetTimerDuration(durObj, INTERPOLATION, DIRECTION)
		bar:SetToTargetValue()
	else
		-- Stop any running timer animation and reset bar
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(0)
	end
end

-- Force stop a timer bar animation
local function stopTimerBar(bar)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
end

local function deepcopy(orig, seen)
	if type(orig) ~= 'table' then
		return orig
	end
	
	-- Handle circular references
	seen = seen or {}
	if seen[orig] then
		return seen[orig]
	end
	
	local copy = {}
	seen[orig] = copy
	
	for k, v in pairs(orig) do
		-- Skip frame objects and functions (they can't be deep copied)
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

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELL/ITEM HELPERS (exposed to GCDI)
-- ═══════════════════════════════════════════════════════════════════════════

function GCDI.is_spell_enabled(spellID)
	if not settings then return true end
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.enabled == false then
		return false
	end
	return true
end

function GCDI.is_item_enabled(itemKey)
	if not settings then return true end
	local itemSettings = settings.itemSettings and settings.itemSettings[itemKey]
	if itemSettings and itemSettings.enabled == false then
		return false
	end
	return true
end

function GCDI.is_buff_enabled(spellID)
	if not settings then return true end
	local buffSettings = settings.buffSettings and settings.buffSettings[spellID]
	if buffSettings and buffSettings.enabled == false then
		return false
	end
	return true
end

function GCDI.get_buff_settings(spellID)
	if not settings or not settings.buffSettings then return {} end
	return settings.buffSettings[spellID] or {}
end

function GCDI.should_show_buff_stacks(spellID)
	local buffSettings = GCDI.get_buff_settings(spellID)
	return buffSettings.showStacks ~= false  -- Default to showing stacks
end

function GCDI.get_buff_max_stacks_display(spellID)
	local buffSettings = GCDI.get_buff_settings(spellID)
	return buffSettings.maxStacksDisplay or 5  -- Default to 5 stacks
end

function GCDI.get_action_slot_for_spell(spellID)
	-- Search all action bar button types
	local barPrefixes = {
		"ActionButton",           -- Main action bar (1-12)
		"MultiBarBottomLeftButton",  -- Bottom left bar
		"MultiBarBottomRightButton", -- Bottom right bar
		"MultiBarRightButton",       -- Right bar 1
		"MultiBarLeftButton",        -- Right bar 2 (left of right bar 1)
		"MultiBar5Button",           -- Additional bars (retail)
		"MultiBar6Button",
		"MultiBar7Button",
		"MultiBar8Button",
	}
	
	for _, prefix in ipairs(barPrefixes) do
		for i = 1, 12 do
			local button = _G[prefix .. i]
			if button and button.action then
				local actionType, id = GetActionInfo(button.action)
				local slotSpellID
				if actionType == "spell" then
					slotSpellID = id
				elseif actionType == "macro" and id then
					slotSpellID = GetMacroSpell(id)
				end
				if slotSpellID == spellID then
					return button.action
				end
			end
		end
	end
	return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PROFILE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

save_profile = function(name)
	if not settings or not name or name == "" then return false end
	
	settings.profiles = settings.profiles or {}
	settings.profiles[name] = {
		globalRangeFallback = settings.globalRangeFallback,
		spellSettings = deepcopy(settings.spellSettings),
		spellOrder = deepcopy(settings.spellOrder),
		itemSettings = deepcopy(settings.itemSettings or {}),
		itemOrder = deepcopy(settings.itemOrder or {}),
		buffSettings = deepcopy(settings.buffSettings or {}),
		buffOrder = deepcopy(settings.buffOrder or {}),
		-- Save catalogs so we don't need to rescan
		spellCatalog = deepcopy(GCDI.spellCatalog),
		itemCatalog = deepcopy(GCDI.itemCatalog),
		buffCatalog = deepcopy(GCDI.buffCatalog),
	}
	settings.currentProfile = name
	
	print("|cff00ff00GCDIndicator:|r Profile '" .. name .. "' saved!")
	return true
end

function GCDI.load_profile(name)
	if not settings or not name then return false end
	if not settings.profiles or not settings.profiles[name] then
		print("|cffff0000GCDIndicator:|r Profile '" .. name .. "' not found!")
		return false
	end
	
	local profile = settings.profiles[name]
	settings.globalRangeFallback = profile.globalRangeFallback or 0
	settings.spellSettings = deepcopy(profile.spellSettings or {})
	settings.spellOrder = deepcopy(profile.spellOrder or {})
	settings.itemSettings = deepcopy(profile.itemSettings or {})
	settings.itemOrder = deepcopy(profile.itemOrder or {})
	settings.buffSettings = deepcopy(profile.buffSettings or {})
	settings.buffOrder = deepcopy(profile.buffOrder or {})
	settings.currentProfile = name
	
	-- Load saved catalogs if available (avoids rescanning)
	if profile.spellCatalog then
		GCDI.spellCatalog = deepcopy(profile.spellCatalog)
	end
	if profile.itemCatalog then
		GCDI.itemCatalog = deepcopy(profile.itemCatalog)
	end
	if profile.buffCatalog then
		GCDI.buffCatalog = deepcopy(profile.buffCatalog)
	end
	
	rebuild_spell_bars()
	rebuild_item_bars()
	rebuild_buff_bars()
	reposition_all()
	if GCDI.refresh_options_frame then GCDI.refresh_options_frame() end
	
	print("|cff00ff00GCDIndicator:|r Profile '" .. name .. "' loaded!")
	return true
end

delete_profile = function(name)
	if not settings or not name then return false end
	if not settings.profiles or not settings.profiles[name] then return false end
	
	settings.profiles[name] = nil
	if settings.currentProfile == name then
		settings.currentProfile = nil
	end
	print("|cff00ff00GCDIndicator:|r Profile '" .. name .. "' deleted!")
	return true
end

function GCDI.auto_save_to_profile()
	if not settings or not settings.currentProfile then return end
	if not settings.profiles then settings.profiles = {} end
	
	settings.profiles[settings.currentProfile] = {
		globalRangeFallback = settings.globalRangeFallback,
		spellSettings = deepcopy(settings.spellSettings),
		spellOrder = deepcopy(settings.spellOrder),
		itemSettings = deepcopy(settings.itemSettings or {}),
		itemOrder = deepcopy(settings.itemOrder or {}),
		buffSettings = deepcopy(settings.buffSettings or {}),
		buffOrder = deepcopy(settings.buffOrder or {}),
		-- Save catalogs so we don't need to rescan
		spellCatalog = deepcopy(GCDI.spellCatalog),
		itemCatalog = deepcopy(GCDI.itemCatalog),
		buffCatalog = deepcopy(GCDI.buffCatalog),
	}
end

function GCDI.get_profile_names()
	local names = {}
	if settings and settings.profiles then
		for name in pairs(settings.profiles) do
			table.insert(names, name)
		end
		table.sort(names)
	end
	return names
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CATALOG ORDERING (via LibGCDI-Catalog)
-- ═══════════════════════════════════════════════════════════════════════════

local LibCatalog = LibStub("LibGCDI-Catalog")
local LibDetector = LibStub("LibGCDI-Detector")

-- Catalog managers (initialized after settings load)
local spellCatalogManager, itemCatalogManager, buffCatalogManager

-- Initialize catalog managers (called after settings are available)
local function init_catalog_managers()
	spellCatalogManager = LibCatalog:NewCatalog({
		name = "spells",
		getCatalog = function() return GCDI.spellCatalog end,
		getSettings = function() return settings end,
		getOrderKey = function() return settings and settings.spellOrder end,
		setOrderKey = function(order) if settings then settings.spellOrder = order end end,
		isEnabled = GCDI.is_spell_enabled,
		onReorder = function() 
			rebuild_spell_bars()
			print("|cff00ff00GCDIndicator:|r Spell bars rebuilt")
		end,
	})
	
	itemCatalogManager = LibCatalog:NewCatalog({
		name = "items",
		getCatalog = function() return GCDI.itemCatalog end,
		getSettings = function() return settings end,
		getOrderKey = function() return settings and settings.itemOrder end,
		setOrderKey = function(order) if settings then settings.itemOrder = order end end,
		isEnabled = GCDI.is_item_enabled,
		onReorder = function() 
			rebuild_item_bars()
			reposition_all()
			print("|cff00ff00GCDIndicator:|r Item bars rebuilt")
		end,
	})
	
	buffCatalogManager = LibCatalog:NewCatalog({
		name = "buffs",
		getCatalog = function() return GCDI.buffCatalog end,
		getSettings = function() return settings end,
		getOrderKey = function() return settings and settings.buffOrder end,
		setOrderKey = function(order) if settings then settings.buffOrder = order end end,
		isEnabled = GCDI.is_buff_enabled,
		onReorder = function() 
			rebuild_buff_bars()
			reposition_all()
			print("|cff00ff00GCDIndicator:|r Buff bars rebuilt")
		end,
	})
end

-- Wrapper functions for backward compatibility (used by options UI and internal code)
local function get_ordered_spells()
	if not spellCatalogManager then return spellBars end
	return spellCatalogManager:GetEnabledOrdered()
end

function GCDI.get_all_catalog_spells_ordered()
	if not spellCatalogManager then return {} end
	return spellCatalogManager:GetAllOrdered()
end

function GCDI.move_spell_in_order(spellID, direction)
	if spellCatalogManager then spellCatalogManager:MoveInOrder(spellID, direction) end
end

function GCDI.move_spell_to_bottom(spellID)
	if spellCatalogManager then spellCatalogManager:MoveToBottom(spellID) end
end

function GCDI.get_ordered_items()
	if not itemCatalogManager then return {} end
	return itemCatalogManager:GetEnabledOrdered()
end

function GCDI.get_all_catalog_items_ordered()
	if not itemCatalogManager then return {} end
	return itemCatalogManager:GetAllOrdered()
end

function GCDI.move_item_in_order(itemKey, direction)
	if itemCatalogManager then itemCatalogManager:MoveInOrder(itemKey, direction) end
end

function GCDI.move_item_to_bottom(itemKey)
	if itemCatalogManager then itemCatalogManager:MoveToBottom(itemKey) end
end

local function get_ordered_buffs()
	if not buffCatalogManager then return buffBars end
	return buffCatalogManager:GetEnabledOrdered()
end

function GCDI.get_ordered_buffs()
	if not buffCatalogManager then return {} end
	return buffCatalogManager:GetEnabledOrdered()
end

function GCDI.get_all_catalog_buffs_ordered()
	if not buffCatalogManager then return {} end
	return buffCatalogManager:GetAllOrdered()
end

function GCDI.move_buff_in_order(spellID, direction)
	if buffCatalogManager then buffCatalogManager:MoveInOrder(spellID, direction) end
end

function GCDI.move_buff_to_bottom(spellID)
	if buffCatalogManager then buffCatalogManager:MoveToBottom(spellID) end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GCD BAR UPDATE
-- ═══════════════════════════════════════════════════════════════════════════

local function update_gcd()
	if previewMode then return end  -- Skip updates in preview mode
	
	-- Use duration object (safe API for secret values)
	local durObj = C_Spell.GetSpellCooldownDuration(GCD_SPELL_ID)
	applyTimerToBar(main_frame.gcdbar, durObj)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELL COOLDOWN BAR
-- ═══════════════════════════════════════════════════════════════════════════

local function update_spell_bar(spellID)
	if previewMode then return end  -- Skip updates in preview mode
	if not GCDI.is_spell_enabled(spellID) then return end  -- Skip disabled spells
	local data = trackedSpells[spellID]
	if not data then return end
	
	local durObj
	
	if data.isChargeSpell then
		-- For charge spells, use the spell's own cooldown duration
		-- This should show GCD when on GCD, and nothing when charges are available
		durObj = C_Spell.GetSpellCooldownDuration(spellID)
		applyTimerToBar(data.bar, durObj)
	else
		-- Non-charge spell - show normal cooldown
		durObj = C_Spell.GetSpellCooldownDuration(spellID)
		applyTimerToBar(data.bar, durObj)
	end
end

local function update_all_spell_bars()
	if previewMode then return end  -- Skip updates in preview mode
	for spellID in pairs(trackedSpells) do
		update_spell_bar(spellID)
	end
end

-- Check if spell should track icon changes
local function should_track_spell_icon(spellID)
	if not settings then return false end
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.trackIcon == true then
		return true
	end
	return false
end

GCDI.should_track_spell_icon = should_track_spell_icon

-- Check if spell is configured as self-cast (no range indicator needed)
local function is_spell_self_cast(spellID)
	if not settings then return false end
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.selfCast == true then
		return true
	end
	return false
end

-- Update spell icons when they change (for proc abilities that transform)
local function update_spell_icons()
	if previewMode then return end  -- Skip updates in preview mode
	for spellID, data in pairs(trackedSpells) do
		if data.icon and GCDI.is_spell_enabled(spellID) and should_track_spell_icon(spellID) then
			local newTexture = C_Spell.GetSpellTexture(spellID)
			if newTexture then
				-- Update icon texture
				if newTexture ~= data.currentTexture then
					data.icon:SetTexture(newTexture)
					data.currentTexture = newTexture
					
					-- Also update catalog entry
					if GCDI.spellCatalog[spellID] then
						GCDI.spellCatalog[spellID].texture = newTexture
					end
				end
				
				-- Update icon change indicator (red if changed, grey if normal)
				if data.iconChangeIndicator then
					local isChanged = (newTexture ~= data.originalTexture)
					if isChanged then
						data.iconChangeIndicator.overlay:Show()  -- Show red
					else
						data.iconChangeIndicator.overlay:Hide()  -- Show grey (base)
					end
				end
			end
		end
	end
end

-- Update charge indicators using LibDetector
local function update_charge_indicators_tick()
	if previewMode then return end  -- Skip updates in preview mode
	for spellID, data in pairs(trackedSpells) do
		if data.chargeIndicators and data.chargeDetectors and GCDI.is_spell_enabled(spellID) then
			local chargeInfo = C_Spell.GetSpellCharges(spellID)
			if chargeInfo then
				-- Use LibDetector to update indicators from secret value
				LibDetector:UpdateIndicators(data.chargeDetectors, data.chargeIndicators, chargeInfo.currentCharges)
			end
		end
	end
end

-- Alias for event-based calls (maintains compatibility)
local function update_all_charge_indicators()
	update_charge_indicators_tick()
end

local function create_spell_bar(spellID, spellName, texture, actionSlot)
	local barIndex = #spellBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	-- Check if spell has charges
	-- chargeInfo being non-nil means it's a charge spell (safe check, no secret reading)
	local chargeInfo = C_Spell.GetSpellCharges(spellID)
	local isChargeSpell = (chargeInfo ~= nil)  -- Does this spell use charges at all?
	local maxCharges = 0
	
	if isChargeSpell and chargeInfo.maxCharges then
		-- Only read maxCharges if NOT a secret value
		if not issecretvalue or not issecretvalue(chargeInfo.maxCharges) then
			maxCharges = chargeInfo.maxCharges
		else
			-- Secret value - default to 2 (most charge spells have 2)
			maxCharges = 2
		end
	end
	
	-- Only show charge INDICATORS if > 1 charge (visual boxes)
	local showChargeIndicators = maxCharges > 1
	
	-- Check if icon tracking is enabled
	local trackIcon = should_track_spell_icon(spellID)
	
	-- Check if spell is self-cast (no range indicator needed)
	local isSelfCast = is_spell_self_cast(spellID)
	
	-- Calculate container width based on spell settings
	-- Layout: [pad][icon][2][cooldown][2][range?][2][charges?][2][iconChange?][pad]
	local chargeWidth = showChargeIndicators and (maxCharges * barSize + (maxCharges - 1) * 2) or 0  -- squares + gaps
	local extraGap = showChargeIndicators and 2 or 0  -- gap before charges section
	local iconChangeWidth = trackIcon and (barSize + 2) or 0  -- icon change indicator + gap
	local rangeWidth = isSelfCast and 0 or (barSize + 2)  -- range indicator + gap (or 0 for self-cast)
	local containerWidth = (barSize * 2 + 2) + rangeWidth + chargeWidth + extraGap + iconChangeWidth + pad * 2
	
	local container = CreateFrame("Frame", nil, main_frame)
	container:SetSize(containerWidth, barSize + pad * 2)
	
	local bg = container:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)
	
	local icon = container:CreateTexture(nil, "ARTWORK")
	icon:SetSize(barSize, barSize)
	icon:SetPoint("LEFT", pad, 0)
	icon:SetTexture(texture)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	
	local clipContainer = CreateFrame("Frame", nil, container)
	clipContainer:SetSize(barSize, barSize)
	clipContainer:SetPoint("LEFT", icon, "RIGHT", 2, 0)
	clipContainer:SetClipsChildren(true)
	
	local cdBg = clipContainer:CreateTexture(nil, "BACKGROUND")
	cdBg:SetAllPoints()
	cdBg:SetColorTexture(1, 1, 1, 1)
	
	local bar = CreateFrame("StatusBar", nil, clipContainer)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:GetStatusBarTexture():SetHorizTile(false)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	bar:SetSize(10000, barSize)
	bar:SetStatusBarColor(0, 0, 0)
	bar:SetPoint("LEFT")
	
	-- Range indicator (after cooldown bar) - only for non-self-cast spells
	local rangeBase = nil
	local rangeOverlay = nil
	local lastElement = clipContainer  -- Track what to anchor next element to
	
	if not isSelfCast then
		rangeBase = container:CreateTexture(nil, "ARTWORK")
		rangeBase:SetSize(barSize, barSize)
		rangeBase:SetPoint("LEFT", clipContainer, "RIGHT", 2, 0)
		rangeBase:SetColorTexture(1, 1, 1, 1)
		
		rangeOverlay = container:CreateTexture(nil, "OVERLAY")
		rangeOverlay:SetSize(barSize, barSize)
		rangeOverlay:SetPoint("CENTER", rangeBase, "CENTER", 0, 0)
		rangeOverlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
		
		lastElement = rangeBase
	end
	
	-- Create charge indicators if spell has charges (to the right of range, or cooldown if self-cast)
	local chargeIndicators = nil
	local chargeDetectors = nil
	
	if showChargeIndicators then
		chargeIndicators = {}
		chargeDetectors = LibDetector:CreateDetectorArray(maxCharges)
		local prevElement = lastElement
		
		for i = 1, maxCharges do
			-- Blue background (charge available)
			local chargeBg = container:CreateTexture(nil, "ARTWORK")
			chargeBg:SetSize(barSize, barSize)
			chargeBg:SetPoint("LEFT", prevElement, "RIGHT", 2, 0)
			chargeBg:SetColorTexture(0, 0.5, 1, 1)  -- Blue = available
			
			-- Black overlay (charge on cooldown) - shown when charge is NOT available
			local chargeOverlay = container:CreateTexture(nil, "OVERLAY")
			chargeOverlay:SetSize(barSize, barSize)
			chargeOverlay:SetPoint("CENTER", chargeBg, "CENTER", 0, 0)
			chargeOverlay:SetColorTexture(0, 0, 0, 1)  -- Black = on cooldown
			chargeOverlay:Hide()  -- Start hidden (charge available)
			
			chargeIndicators[i] = {
				bg = chargeBg,
				overlay = chargeOverlay,
			}
			
			prevElement = chargeBg
		end
	end
	
	-- Icon change indicator (after charges, or after range/cooldown if no charges)
	local iconChangeIndicator = nil
	if trackIcon then
		local anchorElement = lastElement  -- Default to last element (range or cooldown)
		if showChargeIndicators and chargeIndicators then
			anchorElement = chargeIndicators[maxCharges].bg
		end
		
		-- Grey background (normal state)
		local iconChangeBg = container:CreateTexture(nil, "ARTWORK")
		iconChangeBg:SetSize(barSize, barSize)
		iconChangeBg:SetPoint("LEFT", anchorElement, "RIGHT", 2, 0)
		iconChangeBg:SetColorTexture(0.3, 0.3, 0.3, 1)  -- Grey = normal
		
		-- Red overlay (changed state) - shown when icon has changed
		local iconChangeOverlay = container:CreateTexture(nil, "OVERLAY")
		iconChangeOverlay:SetSize(barSize, barSize)
		iconChangeOverlay:SetPoint("CENTER", iconChangeBg, "CENTER", 0, 0)
		iconChangeOverlay:SetColorTexture(0.8, 0.2, 0.2, 1)  -- Red = changed
		iconChangeOverlay:Hide()  -- Start hidden (normal state)
		
		iconChangeIndicator = {
			bg = iconChangeBg,
			overlay = iconChangeOverlay,
		}
	end
	
	-- Create a single detector for checking if ANY charges are available (for cooldown bar logic)
	local chargeCheckDetector = nil
	if isChargeSpell then
		-- Creates a detector that returns true when currentCharges >= 1
		local detectorArray = LibDetector:CreateDetectorArray(1)
		chargeCheckDetector = detectorArray[1]
	end
	
	trackedSpells[spellID] = { 
		bar = bar, 
		container = container, 
		actionSlot = actionSlot,
		rangeBase = rangeBase,  -- White background for range
		rangeOverlay = rangeOverlay,  -- Colored overlay for range
		chargeIndicators = chargeIndicators,
		chargeDetectors = chargeDetectors,  -- LibDetector array for charge indicator display
		chargeCheckDetector = chargeCheckDetector,  -- Single detector to check if charges available
		maxCharges = showChargeIndicators and maxCharges or nil,
		isChargeSpell = isChargeSpell,  -- Whether this spell uses charges (for cooldown logic)
		icon = icon,  -- Store icon reference for icon change detection
		originalTexture = texture,  -- Store original texture for comparison
		currentTexture = texture,  -- Track current texture for change detection
		iconChangeIndicator = iconChangeIndicator,  -- Icon change state indicator
	}
	spellBars[barIndex] = spellID
end

local function clear_spell_bars()
	for _, data in pairs(trackedSpells) do
		if data.container then
			data.container:Hide()
			data.container:SetParent(nil)
		end
	end
	wipe(trackedSpells)
	wipe(spellBars)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ITEM COOLDOWN BAR
-- ═══════════════════════════════════════════════════════════════════════════

local function update_item_bar(itemKey)
	if previewMode then return end  -- Skip updates in preview mode
	local data = trackedItems[itemKey]
	if not data then return end
	
	local startTime, duration, enable = C_Item.GetItemCooldown(data.itemID)
	
	if startTime and startTime > 0 and duration and duration > 1.5 then
		local currentTime = GetTime()
		local remaining = (startTime + duration) - currentTime
		if remaining > 0 then
			data.cdStartTime = startTime
			data.cdDuration = duration
			data.bar:SetMinMaxValues(0, duration)
			data.bar:SetValue(remaining)
			return
		end
	end
	
	data.cdStartTime = nil
	data.cdDuration = nil
	data.bar:SetMinMaxValues(0, 1)
	data.bar:SetValue(0)
end

local function update_all_item_bars()
	if previewMode then return end  -- Skip updates in preview mode
	for itemKey in pairs(trackedItems) do
		update_item_bar(itemKey)
	end
end

local function animate_item_bars()
	if previewMode then return end  -- Skip updates in preview mode
	local currentTime = GetTime()
	for itemKey, data in pairs(trackedItems) do
		if GCDI.is_item_enabled(itemKey) and data.cdStartTime and data.cdDuration then
			local remaining = (data.cdStartTime + data.cdDuration) - currentTime
			if remaining > 0 then
				data.bar:SetValue(remaining)
			else
				data.cdStartTime = nil
				data.cdDuration = nil
				data.bar:SetMinMaxValues(0, 1)
				data.bar:SetValue(0)
			end
		end
	end
end

-- Update item charge indicators (blue if has item, black if not)
local function update_item_charge_indicators()
	if previewMode then return end  -- Skip updates in preview mode
	for itemKey, data in pairs(trackedItems) do
		if GCDI.is_item_enabled(itemKey) and data.chargeOverlay then
			local hasCharge = false
			
			if data.slot then
				-- Equipped item (trinket) - always has charge if equipped
				hasCharge = (GetInventoryItemID("player", data.slot) ~= nil)
			else
				-- Consumable - check bag count
				local count = C_Item.GetItemCount(data.itemID, false, false)
				hasCharge = (count and count > 0)
			end
			
			if hasCharge then
				data.chargeOverlay:Hide()  -- Show blue
			else
				data.chargeOverlay:Show()  -- Show black
			end
		end
	end
end

-- Check if item should show charges
local function should_show_item_charges(itemKey)
	if not settings or not settings.itemSettings then return false end
	local itemSettings = settings.itemSettings[itemKey]
	if itemSettings and itemSettings.showCharges == true then
		return true
	end
	return false  -- Default to not showing charges
end

-- Export for options UI
GCDI.should_show_item_charges = should_show_item_charges

local function create_item_bar(itemKey, itemName, texture, itemID, slot)
	local barIndex = #itemBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	-- Check if we should show charges for this item
	local showCharges = should_show_item_charges(itemKey)
	
	-- Layout: [Icon][Cooldown] or [Icon][Cooldown][Charge]
	local numSquares = showCharges and 3 or 2
	local numGaps = showCharges and 4 or 2
	local container = CreateFrame("Frame", nil, main_frame)
	container:SetSize((barSize * numSquares + numGaps) + pad * 2, barSize + pad * 2)
	
	local bg = container:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)
	
	local icon = container:CreateTexture(nil, "ARTWORK")
	icon:SetSize(barSize, barSize)
	icon:SetPoint("LEFT", pad, 0)
	icon:SetTexture(texture)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	
	local clipContainer = CreateFrame("Frame", nil, container)
	clipContainer:SetSize(barSize, barSize)
	clipContainer:SetPoint("LEFT", icon, "RIGHT", 2, 0)
	clipContainer:SetClipsChildren(true)
	
	local barBg = clipContainer:CreateTexture(nil, "BACKGROUND")
	barBg:SetAllPoints()
	barBg:SetColorTexture(1, 1, 1, 1)
	barBg:SetDrawLayer("BACKGROUND", -1)
	
	local bar = CreateFrame("StatusBar", nil, clipContainer)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:GetStatusBarTexture():SetHorizTile(false)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	bar:SetSize(10000, barSize)
	bar:SetStatusBarColor(0, 0, 0)
	bar:SetPoint("LEFT")
	
	-- Charge indicator (only if enabled)
	local chargeOverlay = nil
	if showCharges then
		local chargeBg = container:CreateTexture(nil, "ARTWORK")
		chargeBg:SetSize(barSize, barSize)
		chargeBg:SetPoint("LEFT", clipContainer, "RIGHT", 2, 0)
		chargeBg:SetColorTexture(0, 0.5, 1, 1)  -- Blue = has charges
		
		chargeOverlay = container:CreateTexture(nil, "OVERLAY")
		chargeOverlay:SetSize(barSize, barSize)
		chargeOverlay:SetPoint("CENTER", chargeBg, "CENTER", 0, 0)
		chargeOverlay:SetColorTexture(0, 0, 0, 1)  -- Black = no charges
		chargeOverlay:Hide()  -- Start with charge available
	end
	
	trackedItems[itemKey] = { 
		bar = bar, 
		container = container, 
		itemID = itemID,
		slot = slot,
		name = itemName,
		chargeOverlay = chargeOverlay,
	}
	itemBars[barIndex] = itemKey
	container:Show()
end

local function clear_item_bars()
	for _, data in pairs(trackedItems) do
		if data.container then
			data.container:Hide()
			data.container:SetParent(nil)
		end
	end
	wipe(trackedItems)
	wipe(itemBars)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- BUFF TRACKING BAR
-- ═══════════════════════════════════════════════════════════════════════════

-- Colors for buff bars
local BUFF_COLORS = {
	active = { 0.2, 0.8, 0.2 },     -- Green when buff is active
	inactive = { 0.3, 0.3, 0.3 },   -- Grey when buff is not active
	stackActive = { 0.4, 0.7, 1.0 }, -- Blue for active stack
	stackEmpty = { 0, 0, 0 },        -- Black for empty stack
}

local function update_buff_bar(buffID)
	if previewMode then return end  -- Skip updates in preview mode
	if not GCDI.is_buff_enabled(buffID) then return end  -- Skip disabled buffs
	-- buffID can be spellID or cooldownID depending on source
	local data = trackedBuffs[buffID]
	if not data then return end
	
	-- Use Cooldown Manager integration (like ArcUI)
	-- CDM frames: cooldownID and auraInstanceID are readable, isActive is SECRET
	local isActive = false
	local stacks = 0
	
	-- Get fresh CDM frame reference from latest scan
	local cdmFrame = cdmBuffFrames[buffID]
	
	-- Also check catalog for stored frame reference
	local catalogEntry = GCDI.buffCatalog[buffID]
	if not cdmFrame and catalogEntry and catalogEntry.cdmFrame then
		cdmFrame = catalogEntry.cdmFrame
	end
	
	if cdmFrame then
		-- Check auraInstanceID - non-zero means buff is active
		local auraID = cdmFrame.auraInstanceID
		if auraID and type(auraID) == "number" and auraID > 0 then
			isActive = true
			
			-- Get stacks using LibDetector to read secret applications value
			local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("player", auraID)
			if auraData and data.stackDetectors then
				stacks = LibDetector:CheckValue(data.stackDetectors, auraData.applications)
			end
		end
	end
	
	-- Manual tracking fallback (for buffs not in CDM)
	if not isActive and data.manualTracking then
		local now = GetTime()
		if data.expirationTime and data.expirationTime > now then
			isActive = true
			stacks = data.stacks or 0
		else
			data.expirationTime = nil
			data.stacks = 0
		end
	end
	
	-- Debug output
	if configs.debugMode then
		local buffName = data.name or "Unknown"
		local frameInfo = cdmFrame and ("auraID:" .. tostring(cdmFrame.auraInstanceID)) or "no frame"
		local stackInfo = stacks > 0 and (" stacks:" .. stacks) or ""
		debug("Buff " .. buffName .. " (ID:" .. buffID .. ") " .. (isActive and "ACTIVE" or "INACTIVE") .. " " .. frameInfo .. stackInfo)
	end
	
	if isActive then
		-- Buff is active
		data.active = true
		data.activeIndicator:SetColorTexture(BUFF_COLORS.active[1], BUFF_COLORS.active[2], BUFF_COLORS.active[3], 1)
		
		-- Update stack indicators if present
		if data.stackIndicators and GCDI.should_show_buff_stacks(buffID) then
			local maxDisplay = GCDI.get_buff_max_stacks_display(buffID)
			
			for i, indicator in ipairs(data.stackIndicators) do
				if i <= maxDisplay then
					if i <= stacks then
						indicator.overlay:Hide()  -- Show blue (stack active)
					else
						indicator.overlay:Show()  -- Show black (stack empty)
					end
					indicator.bg:Show()
				else
					indicator.bg:Hide()
					indicator.overlay:Hide()
				end
			end
			
			-- Stack text removed - only show colored boxes
		end
	else
		-- Buff is not active
		data.active = false
		data.activeIndicator:SetColorTexture(BUFF_COLORS.inactive[1], BUFF_COLORS.inactive[2], BUFF_COLORS.inactive[3], 1)
		
		-- Show all stack indicators as black (empty)
		if data.stackIndicators then
			for _, indicator in ipairs(data.stackIndicators) do
				indicator.overlay:Show()  -- Show black
			end
		end
	end
end

local function update_all_buff_bars()
	if previewMode then return end  -- Skip updates in preview mode
	for spellID in pairs(trackedBuffs) do
		update_buff_bar(spellID)
	end
end

local function create_buff_bar(spellID, spellName, texture)
	local barIndex = #buffBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	-- Check if we should show stacks for this buff
	local showStacks = GCDI.should_show_buff_stacks(spellID)
	local maxStacksDisplay = GCDI.get_buff_max_stacks_display(spellID)
	
	-- Layout: [Icon][Active Indicator][Stacks?]
	-- Active indicator is a single square that shows green when buff is active
	local stackWidth = showStacks and (maxStacksDisplay * barSize + (maxStacksDisplay - 1) * 2) or 0
	local extraGap = showStacks and 2 or 0
	local containerWidth = (barSize * 2 + 2) + stackWidth + extraGap + pad * 2
	
	local container = CreateFrame("Frame", nil, main_frame)
	container:SetSize(containerWidth, barSize + pad * 2)
	
	local bg = container:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)
	
	-- Icon
	local icon = container:CreateTexture(nil, "ARTWORK")
	icon:SetSize(barSize, barSize)
	icon:SetPoint("LEFT", pad, 0)
	icon:SetTexture(texture)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	
	-- Active indicator (shows if buff is active)
	local activeIndicator = container:CreateTexture(nil, "ARTWORK")
	activeIndicator:SetSize(barSize, barSize)
	activeIndicator:SetPoint("LEFT", icon, "RIGHT", 2, 0)
	activeIndicator:SetColorTexture(BUFF_COLORS.inactive[1], BUFF_COLORS.inactive[2], BUFF_COLORS.inactive[3], 1)
	
	-- Stack indicators (optional) - colored boxes only, no text
	local stackIndicators = nil
	local stackDetectors = nil
	
	if showStacks and maxStacksDisplay > 0 then
		stackIndicators = {}
		stackDetectors = LibDetector:CreateDetectorArray(maxStacksDisplay)
		local prevElement = activeIndicator
		
		for i = 1, maxStacksDisplay do
			-- Blue background (stack active)
			local stackBg = container:CreateTexture(nil, "ARTWORK")
			stackBg:SetSize(barSize, barSize)
			stackBg:SetPoint("LEFT", prevElement, "RIGHT", 2, 0)
			stackBg:SetColorTexture(BUFF_COLORS.stackActive[1], BUFF_COLORS.stackActive[2], BUFF_COLORS.stackActive[3], 1)
			
			-- Black overlay (stack empty) - shown when stack is NOT present
			local stackOverlay = container:CreateTexture(nil, "OVERLAY")
			stackOverlay:SetSize(barSize, barSize)
			stackOverlay:SetPoint("CENTER", stackBg, "CENTER", 0, 0)
			stackOverlay:SetColorTexture(BUFF_COLORS.stackEmpty[1], BUFF_COLORS.stackEmpty[2], BUFF_COLORS.stackEmpty[3], 1)
			stackOverlay:Show()  -- Start shown (no stacks)
			
			stackIndicators[i] = {
				bg = stackBg,
				overlay = stackOverlay,
			}
			
			prevElement = stackBg
		end
	end
	
	trackedBuffs[spellID] = {
		container = container,
		activeIndicator = activeIndicator,
		stackIndicators = stackIndicators,
		stackDetectors = stackDetectors,  -- For ArcUI-style stack detection
		active = false,
		name = spellName,
		icon = texture,
	}
	buffBars[barIndex] = spellID
	container:Show()
end

local function clear_buff_bars()
	for _, data in pairs(trackedBuffs) do
		if data.container then
			data.container:Hide()
			data.container:SetParent(nil)
		end
	end
	wipe(trackedBuffs)
	wipe(buffBars)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RANGE INDICATOR
-- ═══════════════════════════════════════════════════════════════════════════

local function get_range_fallback_index(spellID)
	if not settings then return 0 end
	
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.rangeFallback ~= nil then
		return spellSettings.rangeFallback
	end
	
	return settings.globalRangeFallback or 0
end

local function is_in_fallback_range(spellID)
	local rangeIndex = get_range_fallback_index(spellID)
	local item = RANGE_ITEMS[rangeIndex]
	
	if not item or not item.id then
		return nil
	end
	
	local result = C_Item.IsItemInRange(item.id, "target")
	return result == true
end

local function auto_detect_self_cast(spellID, actionSlot)
	if not settings or not actionSlot then return false end
	
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.selfCast ~= nil then
		return spellSettings.selfCast == true
	end
	
	if not UnitExists("target") or not UnitCanAttack("player", "target") then
		return false
	end
	
	local inRange = IsActionInRange(actionSlot)
	if inRange == nil then
		if not settings.spellSettings[spellID] then
			settings.spellSettings[spellID] = {}
		end
		settings.spellSettings[spellID].selfCast = true
		return true
	end
	return false
end

local function has_range_override(spellID)
	if not settings then return false end
	local spellSettings = settings.spellSettings[spellID]
	return spellSettings and spellSettings.rangeFallback ~= nil
end

local function has_native_range_setting(spellID)
	if not settings then return false end
	local spellSettings = settings.spellSettings[spellID]
	return spellSettings and spellSettings.hasNativeRange == true
end

-- Auto-detect native range for all tracked spells
local function detect_native_range_for_spells()
	if not UnitExists("target") then return end
	
	for spellID, data in pairs(trackedSpells) do
		if GCDI.is_spell_enabled(spellID) then
			local actionSlot = data.actionSlot
			if actionSlot then
				local rangeResult = IsActionInRange(actionSlot)
				if rangeResult ~= nil then
					-- This spell has native range detection
					if not settings.spellSettings[spellID] then
						settings.spellSettings[spellID] = {}
					end
					if settings.spellSettings[spellID].hasNativeRange ~= true then
						settings.spellSettings[spellID].hasNativeRange = true
						if configs.debugMode then
							local name = GCDI.spellCatalog[spellID] and GCDI.spellCatalog[spellID].name or spellID
							print("|cff00ff00GCDIndicator:|r Native range detected for: " .. name)
						end
					end
				end
			end
		end
	end
end

GCDI.detect_native_range_for_spells = detect_native_range_for_spells

local function update_range_indicators()
	if previewMode then return end  -- Skip updates in preview mode
	for i, spellID in ipairs(spellBars) do
		local spellData = trackedSpells[spellID]
		if spellData and spellData.rangeOverlay and GCDI.is_spell_enabled(spellID) then
			local overlay = spellData.rangeOverlay
			local actionSlot = spellData.actionSlot
			
			if is_spell_self_cast(spellID) then
				-- Hide both base and overlay for self-cast spells
				if spellData.rangeBase then spellData.rangeBase:Hide() end
				overlay:Hide()
			else
				-- Show both for non-self-cast spells
				if spellData.rangeBase then spellData.rangeBase:Show() end
				overlay:Show()
				
				if not UnitExists("target") then
					overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
				else
					local useOverride = has_range_override(spellID)
					
					if useOverride then
						local fallbackResult = is_in_fallback_range(spellID)
						if fallbackResult == nil then
							overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
						elseif fallbackResult then
							overlay:SetColorTexture(RANGE_COLORS.inRange[1], RANGE_COLORS.inRange[2], RANGE_COLORS.inRange[3], 1)
						else
							overlay:SetColorTexture(RANGE_COLORS.outOfRange[1], RANGE_COLORS.outOfRange[2], RANGE_COLORS.outOfRange[3], 1)
						end
					elseif has_native_range_setting(spellID) then
						local inRange
						if actionSlot then
							inRange = IsActionInRange(actionSlot)
						end
						
						if inRange == true then
							overlay:SetColorTexture(RANGE_COLORS.inRange[1], RANGE_COLORS.inRange[2], RANGE_COLORS.inRange[3], 1)
						elseif inRange == false then
							overlay:SetColorTexture(RANGE_COLORS.outOfRange[1], RANGE_COLORS.outOfRange[2], RANGE_COLORS.outOfRange[3], 1)
						else
							overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
						end
					else
						if auto_detect_self_cast(spellID, actionSlot) then
							-- Hide both for auto-detected self-cast
							if spellData.rangeBase then spellData.rangeBase:Hide() end
							overlay:Hide()
						else
							local fallbackResult = is_in_fallback_range(spellID)
							if fallbackResult == nil then
								overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
							elseif fallbackResult then
								overlay:SetColorTexture(RANGE_COLORS.inRange[1], RANGE_COLORS.inRange[2], RANGE_COLORS.inRange[3], 1)
							else
								overlay:SetColorTexture(RANGE_COLORS.outOfRange[1], RANGE_COLORS.outOfRange[2], RANGE_COLORS.outOfRange[3], 1)
							end
						end
					end
				end
			end
		end
	end
end

GCDI.UpdateRangeIndicators = update_range_indicators

-- ═══════════════════════════════════════════════════════════════════════════
-- RESOURCE BARS
-- ═══════════════════════════════════════════════════════════════════════════

local function create_resource_bar(name, color)
	local barSize = configs.barHeight
	local barWidth = 200
	local pad = configs.bgPadding
	
	local container = CreateFrame("Frame", nil, main_frame)
	container:SetSize(barWidth + pad * 2, barSize + pad * 2)
	
	local bg = container:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)
	
	local bar = CreateFrame("StatusBar", nil, container)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:SetMinMaxValues(0, 100)
	bar:SetValue(0)
	bar:SetPoint("TOPLEFT", pad, -pad)
	bar:SetPoint("BOTTOMRIGHT", -pad, pad)
	bar:SetStatusBarColor(color[1], color[2], color[3])
	
	local separatorFrame = CreateFrame("Frame", nil, container)
	separatorFrame:SetPoint("TOPLEFT", pad, -pad)
	separatorFrame:SetPoint("BOTTOMRIGHT", -pad, pad)
	separatorFrame:SetFrameLevel(container:GetFrameLevel() + 10)
	
	container:Hide()
	
	return { bar = bar, container = container, separatorFrame = separatorFrame }
end

local function update_health_bar()
	if previewMode then return end  -- Skip updates in preview mode
	if not resourceBars.health then return end
	local bar = resourceBars.health.bar
	local rawMax = UnitHealthMax("player")
	local max = tonumber(rawMax) or 100000
	if max > 0 then
		bar:SetMinMaxValues(0, max)
		bar:SetValue(UnitHealth("player"))
	end
end

local function update_rage_bar()
	if previewMode then return end  -- Skip updates in preview mode
	if not resourceBars.rage then return end
	local bar = resourceBars.rage.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Rage)
	local max = tonumber(rawMax) or 100
	if max > 0 then
		bar:SetMinMaxValues(0, max)
		bar:SetValue(UnitPower("player", Enum.PowerType.Rage))
		resourceBars.rage.container:Show()
	else
		resourceBars.rage.container:Hide()
	end
end

local function update_energy_bar()
	if previewMode then return end  -- Skip updates in preview mode
	if not resourceBars.energy then return end
	local bar = resourceBars.energy.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Energy)
	local max = tonumber(rawMax) or 100
	if max > 0 then
		bar:SetMinMaxValues(0, max)
		bar:SetValue(UnitPower("player", Enum.PowerType.Energy))
		resourceBars.energy.container:Show()
	else
		resourceBars.energy.container:Hide()
	end
end

local function update_combo_points_bar()
	if previewMode then return end  -- Skip updates in preview mode
	if not resourceBars.comboPoints then return end
	local data = resourceBars.comboPoints
	local bar = data.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.ComboPoints)
	local max = tonumber(rawMax) or 8
	if max > 0 then
		bar:SetMinMaxValues(0, max)
		bar:SetValue(UnitPower("player", Enum.PowerType.ComboPoints))
		
		local segmentWidth = 8
		local separatorWidth = 2
		local numSeparators = max - 1
		local barWidth = (max * segmentWidth) + (numSeparators * separatorWidth)
		local pad = configs.bgPadding
		data.container:SetWidth(barWidth + pad * 2)
		
		if data.separators and data.separatorFrame then
			for i, sep in ipairs(data.separators) do
				if i < max then
					local xPos = (i * segmentWidth) + ((i - 1) * separatorWidth)
					sep:ClearAllPoints()
					sep:SetPoint("TOPLEFT", data.separatorFrame, "TOPLEFT", xPos, 0)
					sep:Show()
				else
					sep:Hide()
				end
			end
		end
		
		data.container:Show()
	else
		data.container:Hide()
	end
end

local function update_all_resources()
	update_health_bar()
	update_rage_bar()
	update_energy_bar()
	update_combo_points_bar()
end

local function update_stance_indicator()
	if previewMode then return end  -- Skip updates in preview mode
	if not main_frame.stanceIndicator then return end
	
	local formIndex = GetShapeshiftForm() or 0
	local color = FORM_COLORS[formIndex] or FORM_COLORS.default
	main_frame.stanceIndicator:SetColorTexture(color[1], color[2], color[3], 1)
end

local function update_aggro_indicator()
	if previewMode then return end  -- Skip updates in preview mode
	if not main_frame.aggrobar then return end
	
	-- Check if target is a valid hostile in combat
	local validTarget = UnitExists("target") and 
	                    UnitCanAttack("player", "target") and 
	                    UnitAffectingCombat("target")
	
	if not validTarget then
		-- No target, friendly target, or target not in combat = white
		main_frame.aggrobar:SetStatusBarColor(1, 1, 1)
		return
	end
	
	-- Check threat situation on current target
	local threatStatus = UnitThreatSituation("player", "target")
	-- 3 = tanking and highest threat (has aggro)
	local hasAggro = threatStatus and threatStatus >= 3
	
	if hasAggro then
		main_frame.aggrobar:SetStatusBarColor(1, 0.5, 0)  -- Orange = has aggro
	else
		main_frame.aggrobar:SetStatusBarColor(0.3, 0.3, 0.3)  -- Grey = no aggro
	end
end

reposition_all = function()
	local barSize = configs.barHeight
	local spacing = configs.barSpacing
	local pad = configs.bgPadding
	
	local resourceBarHeight = barSize + pad * 2
	local gcdContainerHeight = configs.size + pad * 2
	local spellBarHeight = barSize + pad * 2
	
	-- Resource bar width (200 + padding)
	local resourceBarWidth = 200 + pad * 2
	local buffXOffset = resourceBarWidth + 5  -- 5 pixel gap to the right of resource bars
	
	local yOffset = 0
	local resources = { "health", "rage", "energy", "comboPoints" }
	for _, name in ipairs(resources) do
		if resourceBars[name] then
			resourceBars[name].container:ClearAllPoints()
			resourceBars[name].container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, yOffset)
			resourceBars[name].container:Show()
			yOffset = yOffset - resourceBarHeight - spacing
		end
	end
	
	main_frame.gcdcontainer:ClearAllPoints()
	main_frame.gcdcontainer:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, yOffset)
	yOffset = yOffset - gcdContainerHeight - spacing
	
	local orderedSpells = get_ordered_spells()
	for i, spellID in ipairs(orderedSpells) do
		local data = trackedSpells[spellID]
		if data and data.container then
			data.container:ClearAllPoints()
			data.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, yOffset)
			yOffset = yOffset - spellBarHeight - spacing
		end
	end
	
	local orderedItems = GCDI.get_ordered_items()
	for i, itemKey in ipairs(orderedItems) do
		local data = trackedItems[itemKey]
		if data and data.container then
			data.container:ClearAllPoints()
			data.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, yOffset)
			data.container:Show()
			yOffset = yOffset - spellBarHeight - spacing
		end
	end
	
	-- Position buff bars to the RIGHT of resource bars, starting from top
	local buffYOffset = 0  -- Start at top
	local orderedBuffs = get_ordered_buffs()
	for i, spellID in ipairs(orderedBuffs) do
		local data = trackedBuffs[spellID]
		if data and data.container then
			data.container:ClearAllPoints()
			data.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", buffXOffset, buffYOffset)
			data.container:Show()
			buffYOffset = buffYOffset - spellBarHeight - spacing
		end
	end
	
	update_all_resources()
	update_stance_indicator()
end

GCDI.reposition_all = reposition_all

-- ═══════════════════════════════════════════════════════════════════════════
-- SCANNING
-- ═══════════════════════════════════════════════════════════════════════════

local function scan_spellbook()
	wipe(GCDI.spellCatalog)
	
	local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()
	
	for skillIndex = 1, numSkillLines do
		local skillInfo = C_SpellBook.GetSpellBookSkillLineInfo(skillIndex)
		if skillInfo then
			local isGeneral = skillInfo.name == "General"
			if not skillInfo.isGuild and not skillInfo.shouldHide and not isGeneral then
				if skillInfo.specID ~= nil or skillInfo.offSpecID == nil then
					local startIndex = skillInfo.itemIndexOffset + 1
					local endIndex = startIndex + skillInfo.numSpellBookItems - 1
					
					for i = startIndex, endIndex do
						local spellBookItemInfo = C_SpellBook.GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Player)
						if spellBookItemInfo then
							local baseSpellID = spellBookItemInfo.actionID or spellBookItemInfo.spellID
							if baseSpellID and not spellBookItemInfo.isPassive and not spellBookItemInfo.isOffSpec then
								local spellID = C_Spell.GetOverrideSpell(baseSpellID) or baseSpellID
								
								local cdInfo = C_Spell.GetSpellCooldown(spellID)
								if cdInfo and spellID ~= GCD_SPELL_ID then
									local spellName = C_Spell.GetSpellName(spellID)
									local texture = C_Spell.GetSpellTexture(spellID)
									if spellName and texture and not GCDI.spellCatalog[spellID] then
										GCDI.spellCatalog[spellID] = {
											name = spellName,
											texture = texture,
											spellID = spellID
										}
									end
								end
							end
						end
					end
				end
			end
		end
	end
end

local function add_item_to_catalog(itemID, key, slot, isEquipped, defaultName)
	if not itemID then return false end
	
	local itemName, _, _, _, _, _, _, _, _, texture = C_Item.GetItemInfo(itemID)
	
	if not texture then
		texture = C_Item.GetItemIconByID(itemID)
	end
	
	if not texture then
		texture = "Interface\\Icons\\INV_Misc_QuestionMark"
	end
	
	if not itemName and defaultName then
		itemName = defaultName
	end
	
	GCDI.itemCatalog[key] = {
		name = itemName or ("Item " .. itemID),
		texture = texture,
		itemID = itemID,
		slot = slot,
		isEquipped = isEquipped,
		itemKey = key
	}
	return true
end

local function scan_action_bars_for_items()
	wipe(actionBarItems)
	
	for slot = 1, 120 do
		local actionType, id = GetActionInfo(slot)
		if actionType == "item" and id then
			actionBarItems[id] = true
		end
	end
end

-- Scan Blizzard's Cooldown Manager for buff frames
local function scan_cdm_buff_frames()
	-- Don't wipe - update in place to preserve references
	-- Mark all existing as not found, then update those we find
	local foundThisScan = {}
	
	local viewer = _G["BuffIconCooldownViewer"]
	if not viewer then
		if configs.debugMode then
			debug("CDM BuffIconCooldownViewer not found")
		end
		return 0
	end
	
	local foundCount = 0
	local newCount = 0
	
	-- Method 1: Use itemFramePool if available (proper CDM way)
	if viewer.itemFramePool then
		for frame in viewer.itemFramePool:EnumerateActive() do
			local cooldownID = frame.cooldownID
			if cooldownID then
				foundCount = foundCount + 1
				cdmBuffFrames[cooldownID] = frame
				foundThisScan[cooldownID] = true
				
				-- Try to get spell info from the frame
				local spellName = nil
				local texture = nil
				
				-- CDM frames often have Icon child
				if frame.Icon then
					texture = frame.Icon:GetTexture()
				end
				
				-- Get name from tooltip or spell lookup
				if frame.GetTooltipText then
					spellName = frame:GetTooltipText()
				end
				
				-- Store by cooldownID
				if not GCDI.buffCatalog[cooldownID] then
					GCDI.buffCatalog[cooldownID] = {
						name = spellName or ("Buff " .. cooldownID),
						texture = texture or 134400,  -- Default question mark
						cooldownID = cooldownID,
						cdmFrame = frame,
						hasStacks = false,
					}
					
					-- Save to settings
					if settings then
						if not settings.buffSettings then
							settings.buffSettings = {}
						end
						if not settings.buffSettings[cooldownID] then
							settings.buffSettings[cooldownID] = {
								enabled = true,
								showStacks = true,
								maxStacksDisplay = 5,
							}
							newCount = newCount + 1
						end
					end
					
					if configs.debugMode then
						debug("CDM auto-added: " .. (spellName or cooldownID) .. " (cdID:" .. cooldownID .. ")")
					end
				else
					-- Update frame reference
					GCDI.buffCatalog[cooldownID].cdmFrame = frame
				end
			end
		end
	end
	
	-- Method 2: Fallback to GetChildren if itemFramePool not available or empty
	if foundCount == 0 then
		local children = {viewer:GetChildren()}
		for _, frame in ipairs(children) do
			local cooldownID = frame.cooldownID
			if cooldownID then
				foundCount = foundCount + 1
				cdmBuffFrames[cooldownID] = frame
				foundThisScan[cooldownID] = true
				
				if not GCDI.buffCatalog[cooldownID] then
					local texture = frame.Icon and frame.Icon:GetTexture() or 134400
					GCDI.buffCatalog[cooldownID] = {
						name = "Buff " .. cooldownID,
						texture = texture,
						cooldownID = cooldownID,
						cdmFrame = frame,
						hasStacks = false,
					}
					
					if settings then
						if not settings.buffSettings then settings.buffSettings = {} end
						if not settings.buffSettings[cooldownID] then
							settings.buffSettings[cooldownID] = {
								enabled = true,
								showStacks = true,
								maxStacksDisplay = 5,
							}
							newCount = newCount + 1
						end
					end
				else
					GCDI.buffCatalog[cooldownID].cdmFrame = frame
				end
			end
		end
	end
	
	-- Clean up stale frame references (but keep catalog entries)
	for buffID, frame in pairs(cdmBuffFrames) do
		if not foundThisScan[buffID] then
			cdmBuffFrames[buffID] = nil  -- Remove stale frame reference
			-- Keep catalog entry so bar stays visible
		end
	end
	
	if configs.debugMode and (foundCount > 0 or newCount > 0) then
		debug("CDM scan: " .. foundCount .. " frames, " .. newCount .. " new")
	end
	
	return newCount
end

local function scan_buffs()
	-- Rebuild buffCatalog from saved settings
	if settings and settings.buffSettings then
		for key, _ in pairs(settings.buffSettings) do
			-- Handle both number and string keys (SavedVariables can store either)
			local spellID = tonumber(key)
			if spellID and spellID > 0 then
				-- Add to catalog if not already there
				if not GCDI.buffCatalog[spellID] then
					local spellName = C_Spell.GetSpellName(spellID)
					local texture = C_Spell.GetSpellTexture(spellID)
					if spellName and texture then
						GCDI.buffCatalog[spellID] = {
							name = spellName,
							texture = texture,
							spellID = spellID,
							hasStacks = false,
						}
					end
				end
			end
		end
	end
	
	-- Also scan CDM viewer for buff frames
	scan_cdm_buff_frames()
end

-- Export for manual triggering
GCDI.scan_cdm_buff_frames = scan_cdm_buff_frames

rebuild_buff_bars = function()
	clear_buff_bars()
	
	local orderedBuffs = GCDI.get_ordered_buffs()
	
	for _, spellID in ipairs(orderedBuffs) do
		local catalogEntry = GCDI.buffCatalog[spellID]
		if catalogEntry then
			create_buff_bar(spellID, catalogEntry.name, catalogEntry.texture)
		end
	end
	
	update_all_buff_bars()
	reposition_all()
end

GCDI.rebuild_buff_bars = rebuild_buff_bars

-- Add a buff to the catalog manually (for buffs not currently active)
function GCDI.add_buff_to_catalog(spellID)
	if not spellID or spellID <= 0 then return false end
	if GCDI.buffCatalog[spellID] then return true end  -- Already exists
	
	local spellName = C_Spell.GetSpellName(spellID)
	local texture = C_Spell.GetSpellTexture(spellID)
	
	if spellName and texture then
		GCDI.buffCatalog[spellID] = {
			name = spellName,
			texture = texture,
			spellID = spellID,
			hasStacks = false,  -- Will be detected when buff is active
		}
		-- Save to settings for persistence
		if settings then
			if not settings.buffSettings then
				settings.buffSettings = {}
			end
			if not settings.buffSettings[spellID] then
				settings.buffSettings[spellID] = {
					enabled = true,
					showStacks = true,
					maxStacksDisplay = 5,
				}
			end
		end
		return true
	end
	return false
end

-- Remove a buff from the catalog
function GCDI.remove_buff_from_catalog(spellID)
	if GCDI.buffCatalog[spellID] then
		GCDI.buffCatalog[spellID] = nil
		if settings and settings.buffSettings then
			settings.buffSettings[spellID] = nil
		end
		rebuild_buff_bars()
		return true
	end
	return false
end

local function scan_items()
	wipe(GCDI.itemCatalog)
	
	scan_action_bars_for_items()
	
	for key, info in pairs(TRACKED_ITEM_TYPES) do
		local itemID = GetInventoryItemID("player", info.slot)
		if itemID then
			C_Item.RequestLoadItemDataByID(itemID)
			add_item_to_catalog(itemID, key, info.slot, true, info.name)
		end
	end
	
	for itemID in pairs(actionBarItems) do
		local isTrinket = false
		for _, data in pairs(GCDI.itemCatalog) do
			if data.itemID == itemID then
				isTrinket = true
				break
			end
		end
		
		if not isTrinket then
			C_Item.RequestLoadItemDataByID(itemID)
			local key = "actionbar_" .. itemID
			add_item_to_catalog(itemID, key, nil, false, nil)
		end
	end
	
	for itemID, defaultName in pairs(CONSUMABLE_ITEM_IDS) do
		local alreadyFound = false
		for _, data in pairs(GCDI.itemCatalog) do
			if data.itemID == itemID then
				alreadyFound = true
				break
			end
		end
		
		if not alreadyFound then
			local count = C_Item.GetItemCount(itemID, false, false)
			if count > 0 then
				C_Item.RequestLoadItemDataByID(itemID)
				local key = "consumable_" .. itemID
				add_item_to_catalog(itemID, key, nil, false, defaultName)
			end
		end
	end
	
	C_Timer.After(0.5, function()
		local needsRebuild = false
		for key, data in pairs(GCDI.itemCatalog) do
			local newName, _, _, _, _, _, _, _, _, newTexture = C_Item.GetItemInfo(data.itemID)
			
			if data.name:match("^Item %d+$") or data.name:match("^Trinket %d$") then
				if newName and newName ~= data.name then
					data.name = newName
					needsRebuild = true
				end
			end
			
			if data.texture == "Interface\\Icons\\INV_Misc_QuestionMark" and newTexture then
				data.texture = newTexture
				needsRebuild = true
			end
		end
		if needsRebuild then
			rebuild_item_bars()
			reposition_all()
		end
	end)
end

rebuild_item_bars = function()
	clear_item_bars()
	
	local orderedItems = GCDI.get_ordered_items()
	
	for _, itemKey in ipairs(orderedItems) do
		local catalogEntry = GCDI.itemCatalog[itemKey]
		if catalogEntry then
			create_item_bar(itemKey, catalogEntry.name, catalogEntry.texture, catalogEntry.itemID, catalogEntry.slot)
		end
	end
end

GCDI.rebuild_item_bars = rebuild_item_bars

rebuild_spell_bars = function()
	clear_spell_bars()
	
	local orderedSpells = get_ordered_spells()
	
	for _, spellID in ipairs(orderedSpells) do
		local catalogEntry = GCDI.spellCatalog[spellID]
		if catalogEntry and GCDI.is_spell_enabled(spellID) then
			local actionSlot = GCDI.get_action_slot_for_spell(spellID)
			create_spell_bar(spellID, catalogEntry.name, catalogEntry.texture, actionSlot)
		end
	end
	
	for spellID, catalogEntry in pairs(GCDI.spellCatalog) do
		if not trackedSpells[spellID] and GCDI.is_spell_enabled(spellID) then
			local actionSlot = GCDI.get_action_slot_for_spell(spellID)
			create_spell_bar(spellID, catalogEntry.name, catalogEntry.texture, actionSlot)
		end
	end
	
	rebuild_item_bars()
	update_all_spell_bars()
	update_all_charge_indicators()
	update_range_indicators()
	reposition_all()
end

GCDI.rebuild_spell_bars = rebuild_spell_bars

local function scan_action_bars()
	scan_spellbook()
	scan_items()
	scan_buffs()
	rebuild_spell_bars()
	rebuild_buff_bars()
end

GCDI.scan_action_bars = scan_action_bars
GCDI.scan_spells = function()
	scan_spellbook()
	rebuild_spell_bars()
end
GCDI.scan_items = function()
	scan_items()
	rebuild_item_bars()
end
GCDI.scan_buffs = function()
	scan_buffs()
	rebuild_buff_bars()
end

local function schedule_scan(delay)
	if previewMode then return end  -- Don't scan/rebuild in preview mode
	if pendingScanTimer then
		pendingScanTimer:Cancel()
	end
	pendingScanTimer = C_Timer.NewTimer(delay, function()
		pendingScanTimer = nil
		scan_action_bars()
	end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EVENT HANDLING
-- ═══════════════════════════════════════════════════════════════════════════

local function on_event(self, event, arg1, arg2, ...)
	if event == "SPELL_UPDATE_COOLDOWN" then
		update_gcd()
		update_all_spell_bars()
		update_all_charge_indicators()
		update_all_item_bars()
		
	elseif event == "SPELL_UPDATE_CHARGES" then
		-- Fires immediately when charges change - update both charge indicators AND cooldown bars
		update_all_charge_indicators()
		update_all_spell_bars()  -- Update cooldown bars (charge spells show no cooldown when charges available)
		
	elseif event == "BAG_UPDATE" or event == "PLAYER_EQUIPMENT_CHANGED" then
		schedule_scan(0.5)
		update_item_charge_indicators()  -- Update charge indicators immediately
		
	elseif event == "UNIT_HEALTH" then
		if arg1 == "player" then
			update_health_bar()
		end
		
	elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" then
		if arg1 == "player" then
			if arg2 == "RAGE" then
				update_rage_bar()
			elseif arg2 == "ENERGY" then
				update_energy_bar()
			elseif arg2 == "COMBO_POINTS" then
				update_combo_points_bar()
			end
		end
		
	elseif event == "UNIT_MAXPOWER" then
		if arg1 == "player" then
			update_all_resources()
		end
		
	elseif event == "PLAYER_REGEN_DISABLED" then
		main_frame.combatbar:SetStatusBarColor(1, 0, 0)
		
	elseif event == "PLAYER_REGEN_ENABLED" then
		main_frame.combatbar:SetStatusBarColor(0, 0, 0)
		
	elseif event == "PLAYER_ENTERING_WORLD" then
		main_frame.combatbar:SetStatusBarColor(UnitAffectingCombat("player") and 1 or 0, 0, 0)
		update_aggro_indicator()
		schedule_scan(0.5)
		update_all_resources()
		update_gcd()  -- Initialize GCD bar
		-- Try to detect native range after a delay (in case player has a target)
		C_Timer.After(3, detect_native_range_for_spells)
		
	elseif event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_BONUS_ACTIONBAR" then
		-- Only update stance indicator, don't rescan spells
		-- Spells should stay static unless profile is changed
		update_stance_indicator()
		
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		schedule_scan(0.5)
		
	elseif event == "PLAYER_TARGET_CHANGED" then
		update_range_indicators()
		detect_native_range_for_spells()  -- Auto-detect native range when targeting
		update_aggro_indicator()
		
	elseif event == "UNIT_THREAT_SITUATION_UPDATE" then
		update_aggro_indicator()
		
	elseif event == "UNIT_AURA" then
		if arg1 == "player" then
			-- Rescan CDM frames (they update on aura changes)
			local newBuffs = scan_cdm_buff_frames()
			if newBuffs > 0 then
				-- New buffs found, rebuild bars
				rebuild_buff_bars()
			else
				update_all_buff_bars()
			end
		end
		
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- Manual buff tracking for buffs not in CDM
		if arg1 == "player" then
			local spellID = arg2
			-- Check if this spell triggers a manual buff
			if settings and settings.buffSettings then
				local buffSetting = settings.buffSettings[spellID]
				if buffSetting and buffSetting.manualTracking and buffSetting.triggerSpellID then
					-- This spell triggers a buff
					local buffData = trackedBuffs[buffSetting.triggerSpellID]
					if buffData then
						buffData.expirationTime = GetTime() + (buffSetting.duration or 10)
						buffData.stacks = (buffData.stacks or 0) + (buffSetting.stacksPerCast or 1)
						if buffSetting.maxStacks then
							buffData.stacks = math.min(buffData.stacks, buffSetting.maxStacks)
						end
						update_buff_bar(buffSetting.triggerSpellID)
					end
				end
			end
		end
		
	-- Other events: don't rescan automatically
	-- Spells should only change on profile change, spec change, or manual /gcdopt scan
	end
end

-- Forward declaration for minimap button (defined below)
local create_minimap_button

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

local function init()
	if not GCDIndicator_Settings then
		GCDIndicator_Settings = {}
	end
	settings = GCDIndicator_Settings
	GCDI.settings = settings
	
	if settings.globalRangeFallback == nil then
		settings.globalRangeFallback = DEFAULT_SETTINGS.globalRangeFallback
	end
	if not settings.spellSettings then
		settings.spellSettings = {}
	end
	if not settings.spellOrder then
		settings.spellOrder = {}
	end
	if not settings.itemSettings then
		settings.itemSettings = {}
	end
	if not settings.itemOrder then
		settings.itemOrder = {}
	end
	if not settings.buffSettings then
		settings.buffSettings = {}
	end
	if not settings.buffOrder then
		settings.buffOrder = {}
	end
	if not settings.profiles then
		settings.profiles = {}
	end
	
	-- Initialize catalog managers now that settings are available
	init_catalog_managers()
	
	main_frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 0)
	main_frame:SetSize(1, 1)
	
	local pad = configs.bgPadding
	
	local anchor = CreateFrame("Frame", nil, main_frame)
	anchor:SetSize(1, 1)
	anchor:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -5)  -- Default: top-left, 20px from edge
	main_frame.anchor = anchor
	
	local sepSize = 2
	local containerWidth = (configs.size * 4) + (sepSize * 3) + (pad * 2)  -- 4 indicators: stance, gcd, combat, aggro
	local gcdCombatContainer = CreateFrame("Frame", nil, main_frame)
	gcdCombatContainer:SetSize(containerWidth, configs.size + pad * 2)
	main_frame.gcdcontainer = gcdCombatContainer
	
	local gcdCombatBg = gcdCombatContainer:CreateTexture(nil, "BACKGROUND")
	gcdCombatBg:SetAllPoints()
	gcdCombatBg:SetColorTexture(0, 0, 0, 1)
	
	local stanceIndicator = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	stanceIndicator:SetSize(configs.size, configs.size)
	stanceIndicator:SetPoint("LEFT", pad, 0)
	stanceIndicator:SetColorTexture(0.5, 0.5, 0.5, 1)
	main_frame.stanceIndicator = stanceIndicator
	
	local sep1 = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	sep1:SetSize(sepSize, configs.size)
	sep1:SetPoint("LEFT", stanceIndicator, "RIGHT", 0, 0)
	sep1:SetColorTexture(0, 0, 0, 1)
	
	-- White background for GCD (outside clip, ensures visibility)
	local gcdWhiteBg = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	gcdWhiteBg:SetSize(configs.size, configs.size)
	gcdWhiteBg:SetPoint("LEFT", sep1, "RIGHT", 0, 0)
	gcdWhiteBg:SetColorTexture(1, 1, 1, 1)
	
	local gcdClip = CreateFrame("Frame", nil, gcdCombatContainer)
	gcdClip:SetSize(configs.size, configs.size)
	gcdClip:SetPoint("LEFT", sep1, "RIGHT", 0, 0)
	gcdClip:SetClipsChildren(true)
	gcdClip:SetFrameLevel(gcdCombatContainer:GetFrameLevel() + 1)
	
	local gcdbar = CreateFrame("StatusBar", nil, gcdClip)
	gcdbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	gcdbar:GetStatusBarTexture():SetHorizTile(false)
	gcdbar:SetMinMaxValues(0, 1)
	gcdbar:SetValue(0)
	gcdbar:SetSize(10000, configs.size)
	gcdbar:SetStatusBarColor(0, 0, 0)
	gcdbar:SetPoint("LEFT")
	main_frame.gcdbar = gcdbar
	
	local sep2 = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	sep2:SetSize(sepSize, configs.size)
	sep2:SetPoint("LEFT", gcdClip, "RIGHT", 0, 0)
	sep2:SetColorTexture(0, 0, 0, 1)
	
	local combatbar = CreateFrame("StatusBar", nil, gcdCombatContainer)
	combatbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	combatbar:GetStatusBarTexture():SetHorizTile(false)
	combatbar:SetMinMaxValues(0, 100)
	combatbar:SetValue(100)
	combatbar:SetSize(configs.size, configs.size)
	combatbar:SetStatusBarColor(0, 0, 0)
	combatbar:SetPoint("LEFT", sep2, "RIGHT", 0, 0)
	main_frame.combatbar = combatbar
	
	local sep3 = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	sep3:SetSize(sepSize, configs.size)
	sep3:SetPoint("LEFT", combatbar, "RIGHT", 0, 0)
	sep3:SetColorTexture(0, 0, 0, 1)
	
	local aggrobar = CreateFrame("StatusBar", nil, gcdCombatContainer)
	aggrobar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	aggrobar:GetStatusBarTexture():SetHorizTile(false)
	aggrobar:SetMinMaxValues(0, 100)
	aggrobar:SetValue(100)
	aggrobar:SetSize(configs.size, configs.size)
	aggrobar:SetStatusBarColor(0.3, 0.3, 0.3)  -- Grey = no aggro
	aggrobar:SetPoint("LEFT", sep3, "RIGHT", 0, 0)
	main_frame.aggrobar = aggrobar
	
	GCDIndicator_Positions = GCDIndicator_Positions or {}
	local libGCDI = LibStub and LibStub:GetLibrary("LibGCDI", true)
	if libGCDI then
		libGCDI.load_position(anchor, "GCDIndicator", GCDIndicator_Positions)
	end
	
	local barSize = configs.barHeight
	resourceBars.health = create_resource_bar("health", RESOURCE_COLORS.health)
	resourceBars.rage = create_resource_bar("rage", RESOURCE_COLORS.rage)
	resourceBars.energy = create_resource_bar("energy", RESOURCE_COLORS.energy)
	resourceBars.comboPoints = create_resource_bar("comboPoints", RESOURCE_COLORS.comboPoints)
	
	resourceBars.comboPoints.separators = {}
	local sepFrame = resourceBars.comboPoints.separatorFrame
	for i = 1, 7 do
		local sep = sepFrame:CreateTexture(nil, "OVERLAY")
		sep:SetSize(2, barSize)
		sep:SetColorTexture(0, 0, 0, 1)
		sep:Hide()
		resourceBars.comboPoints.separators[i] = sep
	end
	
	local yOffset = 0
	local resourceBarHeight = barSize + pad * 2
	local resources = { "health", "rage", "energy", "comboPoints" }
	for _, name in ipairs(resources) do
		if resourceBars[name] then
			resourceBars[name].container:ClearAllPoints()
			resourceBars[name].container:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, yOffset)
			resourceBars[name].container:Show()
			yOffset = yOffset - resourceBarHeight - configs.barSpacing
		end
	end
	update_all_resources()
	update_stance_indicator()
	update_aggro_indicator()
	
	local events = {
		"SPELL_UPDATE_COOLDOWN",
		"SPELL_UPDATE_CHARGES",
		"PLAYER_REGEN_DISABLED",
		"PLAYER_REGEN_ENABLED", 
		"PLAYER_ENTERING_WORLD",
		"ACTIONBAR_SLOT_CHANGED",
		"UPDATE_MACROS",
		"BAG_UPDATE",
		"PLAYER_EQUIPMENT_CHANGED",
		"SPELLS_CHANGED",
		"PLAYER_SPECIALIZATION_CHANGED",
		"UPDATE_SHAPESHIFT_FORM",
		"UPDATE_BONUS_ACTIONBAR",
		"PLAYER_TARGET_CHANGED",
		"UNIT_THREAT_SITUATION_UPDATE",
	}
	for _, event in ipairs(events) do
		main_frame:RegisterEvent(event)
	end
	main_frame:RegisterUnitEvent("UNIT_HEALTH", "player")
	main_frame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
	main_frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
	main_frame:RegisterUnitEvent("UNIT_MAXPOWER", "player")
	main_frame:RegisterUnitEvent("UNIT_AURA", "player")
	main_frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")  -- For manual buff tracking
	main_frame:SetScript("OnEvent", on_event)

	if UnitAffectingCombat("player") then
		combatbar:SetStatusBarColor(1, 0, 0)
	end
	
	-- Initialize GCD bar immediately (don't wait for events)
	update_gcd()
	
	schedule_scan(0.1)
	C_Timer.After(1.0, function()
		if #spellBars == 0 then
			scan_action_bars()
		end
	end)
	
	-- Auto-ingest buffs from CDM after it loads
	C_Timer.After(1.5, function()
		local viewer = _G["BuffIconCooldownViewer"]
		if not viewer then
			print("|cff00ff00GCDIndicator:|r CDM BuffIconCooldownViewer not found - enable in Edit Mode")
			return
		end
		local children = {viewer:GetChildren()}
		local newBuffs = scan_cdm_buff_frames()
		rebuild_buff_bars()
		local totalBuffs = 0
		for _ in pairs(GCDI.buffCatalog) do totalBuffs = totalBuffs + 1 end
		if newBuffs > 0 or totalBuffs > 0 then
			print("|cff00ff00GCDIndicator:|r CDM scan: " .. #children .. " frames, " .. newBuffs .. " new, " .. totalBuffs .. " total buffs")
		end
	end)
	-- Second pass in case CDM loads slowly
	C_Timer.After(4.0, function()
		local newBuffs = scan_cdm_buff_frames()
		if newBuffs > 0 then
			rebuild_buff_bars()
			print("|cff00ff00GCDIndicator:|r CDM late scan: found " .. newBuffs .. " additional buffs")
		end
	end)
	
	if settings.currentProfile and settings.profiles and settings.profiles[settings.currentProfile] then
		C_Timer.After(0.5, function()
			local profile = settings.profiles[settings.currentProfile]
			
			settings.globalRangeFallback = profile.globalRangeFallback or 0
			settings.spellSettings = deepcopy(profile.spellSettings or {})
			settings.spellOrder = deepcopy(profile.spellOrder or {})
			settings.itemSettings = deepcopy(profile.itemSettings or {})
			settings.itemOrder = deepcopy(profile.itemOrder or {})
			settings.buffSettings = deepcopy(profile.buffSettings or {})
			settings.buffOrder = deepcopy(profile.buffOrder or {})
			
			-- Load saved catalogs (avoids rescanning and proc issues)
			if profile.spellCatalog then
				GCDI.spellCatalog = deepcopy(profile.spellCatalog)
			end
			if profile.itemCatalog then
				GCDI.itemCatalog = deepcopy(profile.itemCatalog)
			end
			if profile.buffCatalog then
				GCDI.buffCatalog = deepcopy(profile.buffCatalog)
			end
			
			rebuild_spell_bars()
			rebuild_buff_bars()
			print("|cff00ff00GCDIndicator:|r Profile '" .. settings.currentProfile .. "' loaded")
		end)
	end
	
	-- Master update ticker (0.05s base interval)
	-- Consolidates all periodic updates with counters for different frequencies
	local tickCount = 0
	C_Timer.NewTicker(0.05, function()
		tickCount = tickCount + 1
		
		-- Every tick (0.05s): GCD, Item cooldown animation, charge indicators
		update_gcd()
		animate_item_bars()
		update_charge_indicators_tick()
		
		-- Every 2 ticks (0.1s): Range indicators
		if tickCount % 2 == 0 then
			update_range_indicators()
		end
		
		-- Every 4 ticks (0.2s): Buff/icon updates
		if tickCount % 4 == 0 then
			scan_cdm_buff_frames()
			update_all_buff_bars()
			update_spell_icons()
		end
		
		-- Every 10 ticks (0.5s): Item charge indicators
		if tickCount % 10 == 0 then
			update_item_charge_indicators()
		end
		
		-- Every 100 ticks (5s): Native range detection
		if tickCount % 100 == 0 then
			detect_native_range_for_spells()
			tickCount = 0  -- Reset to prevent overflow
		end
	end)
	
	-- Create minimap button
	create_minimap_button()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- MINIMAP BUTTON (via LibDBIcon)
-- ═══════════════════════════════════════════════════════════════════════════

local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")

-- Create the LDB data object
local GCDILauncher = LDB:NewDataObject("GCDIndicator", {
	type = "launcher",
	label = "GCD Indicator",
	icon = "Interface\\Icons\\Inv_10_inscription3_darkmoondeckbox_black",
	OnClick = function(self, button)
		local optFrame = _G["GCDIndicatorOptions"]
		if optFrame and optFrame:IsShown() then
			optFrame:Hide()
		elseif GCDI.create_options_frame then
			GCDI.create_options_frame()
		end
	end,
	OnTooltipShow = function(tooltip)
		tooltip:AddLine("GCD Indicator")
		tooltip:AddLine("|cffffffffLeft-click:|r Open/close options", 1, 1, 1)
		tooltip:AddLine("|cffffffffDrag:|r Move button", 0.7, 0.7, 0.7)
	end,
})

GCDI.LDBObject = GCDILauncher

create_minimap_button = function()
	-- Initialize minimap settings if not present
	if not settings.minimap then
		settings.minimap = {
			hide = false,
			minimapPos = 220,
		}
	end
	
	-- Register with LibDBIcon (handles HidingBar automatically)
	if not LDBIcon:IsRegistered("GCDIndicator") then
		LDBIcon:Register("GCDIndicator", GCDILauncher, settings.minimap)
	end
end

GCDI.create_minimap_button = create_minimap_button

-- Function to show/hide minimap button
function GCDI.ToggleMinimapButton()
	if settings.minimap then
		settings.minimap.hide = not settings.minimap.hide
		if settings.minimap.hide then
			LDBIcon:Hide("GCDIndicator")
		else
			LDBIcon:Show("GCDIndicator")
		end
	end
end

-- Function to enter move mode (calls LibGCDI's /gcdi)
function GCDI.toggle_move_mode()
	-- Trigger the /gcdi command which shows the move popup
	SlashCmdList['gcdi']()
end

-- Function to reset position (calls LibGCDI's /gcdr)
function GCDI.reset_position()
	-- Trigger the /gcdr command which shows the reset popup
	SlashCmdList['gcdr']()
end

-- Preview mode background
local previewBackground = nil

-- Function to toggle preview mode
function GCDI.toggle_preview_mode()
	previewMode = not previewMode
	
	if previewMode then
		-- Create background if it doesn't exist
		if not previewBackground then
			previewBackground = main_frame:CreateTexture(nil, "BACKGROUND", nil, -8)
			previewBackground:SetColorTexture(0, 0, 0, 1)  -- Pitch black, fully opaque
		end
		
		-- Size and show background to cover all bars
		local pad = 10
		previewBackground:ClearAllPoints()
		previewBackground:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", -pad, pad + 5)
		previewBackground:SetPoint("BOTTOMRIGHT", main_frame.anchor, "BOTTOMRIGHT", 400, -300)
		previewBackground:Show()
		
		-- Fill resource bars with visible colors
		-- IMPORTANT: Set MinMaxValues first, then Value, then Color
		if resourceBars then
			if resourceBars.health and resourceBars.health.bar then
				resourceBars.health.bar:SetMinMaxValues(0, 100)
				resourceBars.health.bar:SetValue(100)
				resourceBars.health.bar:SetStatusBarColor(0, 0.8, 0)  -- Green
				resourceBars.health.container:Show()
			end
			if resourceBars.rage and resourceBars.rage.bar then
				resourceBars.rage.bar:SetMinMaxValues(0, 100)
				resourceBars.rage.bar:SetValue(100)
				resourceBars.rage.bar:SetStatusBarColor(0.8, 0, 0)  -- Red
				resourceBars.rage.container:Show()
			end
			if resourceBars.energy and resourceBars.energy.bar then
				resourceBars.energy.bar:SetMinMaxValues(0, 100)
				resourceBars.energy.bar:SetValue(100)
				resourceBars.energy.bar:SetStatusBarColor(1, 0.85, 0)  -- Yellow
				resourceBars.energy.container:Show()
			end
			if resourceBars.comboPoints and resourceBars.comboPoints.bar then
				resourceBars.comboPoints.bar:SetMinMaxValues(0, 100)
				resourceBars.comboPoints.bar:SetValue(100)
				resourceBars.comboPoints.bar:SetStatusBarColor(1, 0.5, 0)  -- Orange
				resourceBars.comboPoints.container:Show()
			end
		end
		
		-- Set all spell bar indicators to visible colors
		for spellID, data in pairs(trackedSpells) do
			if data.rangeOverlay then
				data.rangeOverlay:SetColorTexture(0, 1, 0, 1)  -- Green = in range
			end
			if data.chargeIndicators then
				for _, indicator in ipairs(data.chargeIndicators) do
					indicator.overlay:Hide()  -- Show blue (available)
				end
			end
			if data.iconChangeIndicator then
				data.iconChangeIndicator.overlay:Show()  -- Show red (changed)
			end
		end
		
		-- Set all item bar indicators
		for itemKey, data in pairs(trackedItems) do
			if data.rangeOverlay then
				data.rangeOverlay:SetColorTexture(0, 1, 0, 1)  -- Green
			end
			if data.chargeOverlay then
				data.chargeOverlay:Hide()  -- Hide overlay to show blue (has charge)
			end
		end
		
		-- Set all buff indicators to active
		for buffID, data in pairs(trackedBuffs) do
			if data.activeIndicator then
				data.activeIndicator:SetColorTexture(0, 0.8, 0, 1)  -- Green = active
			end
			if data.stackIndicators then
				for _, indicator in ipairs(data.stackIndicators) do
					indicator.overlay:Hide()  -- Show blue (stack present)
				end
			end
		end
		
		-- Show GCD and combat indicators with visible colors
		if main_frame.gcdbar then
			main_frame.gcdbar:SetStatusBarColor(1, 1, 1)  -- White (visible)
			main_frame.gcdbar:SetValue(100)
		end
		if main_frame.combatbar then
			main_frame.combatbar:SetStatusBarColor(1, 0, 0)  -- Red = in combat
			main_frame.combatbar:SetValue(100)
		end
		if main_frame.aggrobar then
			main_frame.aggrobar:SetStatusBarColor(1, 0.5, 0)  -- Orange = has aggro
			main_frame.aggrobar:SetValue(100)
		end
		if main_frame.stanceIndicator then
			main_frame.stanceIndicator:SetColorTexture(0.5, 0.3, 0, 1)  -- Bear form color
		end
		
		print("|cff00ff00GCDIndicator:|r Preview mode |cff00ff00ON|r - All bars filled")
	else
		-- Hide background
		if previewBackground then
			previewBackground:Hide()
		end
		
		-- Force update all bars to restore real values
		-- Resource bars need MinMaxValues reset and real values applied
		if resourceBars then
			if resourceBars.health and resourceBars.health.bar then
				local max = tonumber(UnitHealthMax("player")) or 100000
				resourceBars.health.bar:SetMinMaxValues(0, max)
				resourceBars.health.bar:SetValue(UnitHealth("player"))
				resourceBars.health.bar:SetStatusBarColor(RESOURCE_COLORS.health[1], RESOURCE_COLORS.health[2], RESOURCE_COLORS.health[3])
			end
			if resourceBars.rage and resourceBars.rage.bar then
				local max = tonumber(UnitPowerMax("player", Enum.PowerType.Rage)) or 100
				resourceBars.rage.bar:SetMinMaxValues(0, max)
				resourceBars.rage.bar:SetValue(UnitPower("player", Enum.PowerType.Rage))
				resourceBars.rage.bar:SetStatusBarColor(RESOURCE_COLORS.rage[1], RESOURCE_COLORS.rage[2], RESOURCE_COLORS.rage[3])
			end
			if resourceBars.energy and resourceBars.energy.bar then
				local max = tonumber(UnitPowerMax("player", Enum.PowerType.Energy)) or 100
				resourceBars.energy.bar:SetMinMaxValues(0, max)
				resourceBars.energy.bar:SetValue(UnitPower("player", Enum.PowerType.Energy))
				resourceBars.energy.bar:SetStatusBarColor(RESOURCE_COLORS.energy[1], RESOURCE_COLORS.energy[2], RESOURCE_COLORS.energy[3])
			end
			if resourceBars.comboPoints and resourceBars.comboPoints.bar then
				local max = tonumber(UnitPowerMax("player", Enum.PowerType.ComboPoints)) or 8
				resourceBars.comboPoints.bar:SetMinMaxValues(0, max)
				resourceBars.comboPoints.bar:SetValue(UnitPower("player", Enum.PowerType.ComboPoints))
				resourceBars.comboPoints.bar:SetStatusBarColor(RESOURCE_COLORS.comboPoints[1], RESOURCE_COLORS.comboPoints[2], RESOURCE_COLORS.comboPoints[3])
			end
		end
		
		-- Reset GCD and combat bars
		if main_frame.gcdbar then
			main_frame.gcdbar:SetStatusBarColor(0, 0, 0)
			main_frame.gcdbar:SetValue(0)
		end
		if main_frame.combatbar then
			main_frame.combatbar:SetStatusBarColor(UnitAffectingCombat("player") and 1 or 0, 0, 0)
		end
		
		-- Update stance indicator
		local formIndex = GetShapeshiftForm() or 0
		local color = FORM_COLORS[formIndex] or FORM_COLORS.default
		if main_frame.stanceIndicator then
			main_frame.stanceIndicator:SetColorTexture(color[1], color[2], color[3], 1)
		end
		
		-- Update aggro indicator
		update_aggro_indicator()
		
		-- Force update all tracked elements
		update_all_spell_bars()
		update_range_indicators()
		update_all_charge_indicators()
		update_all_item_bars()
		update_item_charge_indicators()
		update_all_buff_bars()
		update_spell_icons()
		
		print("|cff00ff00GCDIndicator:|r Preview mode |cffff0000OFF|r - Normal display restored")
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SLASH COMMANDS
-- ═══════════════════════════════════════════════════════════════════════════

SLASH_GCDOPT1 = "/gcdopt"
SLASH_GCDOPT2 = "/gcdiopt"
SLASH_GCDOPT3 = "/gcdioptions"
SlashCmdList["GCDOPT"] = function(msg)
	if msg == "scan" then
		scan_action_bars()
	elseif msg == "debug" then
		configs.debugMode = not configs.debugMode
		print("|cff00ff00GCDIndicator:|r Debug mode " .. (configs.debugMode and "ON" or "OFF"))
	elseif msg == "items" then
		print("|cff00ff00GCDIndicator:|r --- Item Catalog ---")
		local count = 0
		for key, data in pairs(GCDI.itemCatalog) do
			count = count + 1
			print("  " .. key .. " = " .. tostring(data.name) .. " (ID: " .. tostring(data.itemID) .. ")")
		end
		print("|cff00ff00GCDIndicator:|r " .. count .. " items in catalog")
	elseif msg == "buffs" then
		-- List tracked buffs and their status
		print("|cff00ff00GCDIndicator:|r --- Tracked Buffs Status ---")
		print("|cff888888Note: Buff spell IDs are secret. Get IDs from Wowhead or tooltip addons.|r")
		local count = 0
		for spellID, data in pairs(GCDI.buffCatalog) do
			count = count + 1
			local auraData = C_UnitAuras.GetUnitAuraBySpellID("player", spellID)
			local status = auraData and "|cff00ff00ACTIVE|r" or "|cff888888inactive|r"
			local stacks = auraData and auraData.applications or 0
			print("  " .. data.name .. " (ID: |cffffcc00" .. spellID .. "|r) - " .. status .. " [" .. stacks .. " stacks]")
		end
		if count == 0 then
			print("  No buffs being tracked. Add buffs in /gcdopt -> Buffs tab")
		end
	elseif msg == "buffdebug" then
		-- Debug: show what's saved in settings.buffSettings
		print("|cff00ff00GCDIndicator:|r --- Buff Settings Debug ---")
		if settings and settings.buffSettings then
			local count = 0
			for key, val in pairs(settings.buffSettings) do
				count = count + 1
				local keyType = type(key)
				print("  Key: " .. tostring(key) .. " (type: " .. keyType .. "), enabled: " .. tostring(val.enabled))
			end
			print("|cff00ff00GCDIndicator:|r " .. count .. " entries in buffSettings")
		else
			print("  settings.buffSettings is nil or empty")
		end
		print("|cff00ff00GCDIndicator:|r --- Buff Catalog ---")
		local catCount = 0
		for spellID, data in pairs(GCDI.buffCatalog) do
			catCount = catCount + 1
			-- Test if this buff can be detected
			local aura = C_UnitAuras.GetPlayerAuraBySpellID(spellID)
			local canDetect = aura ~= nil and "YES" or "maybe-secret"
			print("  " .. tostring(spellID) .. " = " .. tostring(data.name) .. " (detectable: " .. canDetect .. ")")
		end
		print("|cff00ff00GCDIndicator:|r " .. catCount .. " entries in buffCatalog")
	elseif msg == "cdmimport" then
		-- Force import from CDM
		print("|cff00ff00GCDIndicator:|r Importing buffs from Cooldown Manager...")
		local newBuffs = scan_cdm_buff_frames()
		rebuild_buff_bars()
		local totalBuffs = 0
		for _ in pairs(GCDI.buffCatalog) do totalBuffs = totalBuffs + 1 end
		print("|cff00ff00GCDIndicator:|r Imported " .. newBuffs .. " new buffs (" .. totalBuffs .. " total)")
	
	elseif msg == "range" then
		-- Force detect native range for all spells
		if not UnitExists("target") then
			print("|cff00ff00GCDIndicator:|r Target an enemy first to detect native range")
		else
			detect_native_range_for_spells()
			print("|cff00ff00GCDIndicator:|r Native range detection complete")
			-- Show results
			local nativeCount = 0
			for spellID, _ in pairs(trackedSpells) do
				if settings.spellSettings[spellID] and settings.spellSettings[spellID].hasNativeRange then
					nativeCount = nativeCount + 1
				end
			end
			print("|cff00ff00GCDIndicator:|r " .. nativeCount .. " spells have native range")
		end
	
	elseif msg == "minimap" then
		-- Toggle minimap button visibility
		GCDI.ToggleMinimapButton()
		local hidden = settings.minimap and settings.minimap.hide
		print("|cff00ff00GCDIndicator:|r Minimap button " .. (hidden and "hidden" or "shown"))
		
	elseif msg == "testbuffs" or msg == "cdm" then
		-- Scan Blizzard's Cooldown Manager for buff frames
		print("|cff00ff00GCDIndicator:|r --- Scanning Cooldown Manager ---")
		local viewer = _G["BuffIconCooldownViewer"]
		if not viewer then
			print("|cffff0000BuffIconCooldownViewer not found!|r")
			print("Make sure Blizzard's Cooldown Manager is enabled in Edit Mode.")
			return
		end
		
		print("Viewer found: " .. tostring(viewer))
		print("Has itemFramePool: " .. tostring(viewer.itemFramePool ~= nil))
		
		local activeCount = 0
		local frameCount = 0
		
		-- Try itemFramePool first
		if viewer.itemFramePool then
			print("Using itemFramePool:EnumerateActive()...")
			for frame in viewer.itemFramePool:EnumerateActive() do
				frameCount = frameCount + 1
				local cooldownID = frame.cooldownID
				local auraInstanceID = frame.auraInstanceID
				-- Note: frame.isActive is SECRET - cannot read it!
				
				local texture = frame.Icon and frame.Icon:GetTexture() or "none"
				local activeStr = ""
				if auraInstanceID and type(auraInstanceID) == "number" and auraInstanceID > 0 then
					activeStr = "|cff00ff00ACTIVE|r (auraID: " .. auraInstanceID .. ")"
					activeCount = activeCount + 1
				else
					activeStr = "|cff888888inactive|r (auraID: " .. tostring(auraInstanceID) .. ")"
				end
				print("  cdID: |cffffcc00" .. tostring(cooldownID) .. "|r - " .. activeStr .. " (tex: " .. tostring(texture) .. ")")
			end
		else
			-- Fallback to GetChildren
			print("Using GetChildren()...")
			local children = {viewer:GetChildren()}
			for _, frame in ipairs(children) do
				frameCount = frameCount + 1
				local cooldownID = frame.cooldownID
				if cooldownID then
					local auraInstanceID = frame.auraInstanceID
					local activeStr = ""
					if auraInstanceID and type(auraInstanceID) == "number" and auraInstanceID > 0 then
						activeStr = "|cff00ff00ACTIVE|r (auraID: " .. auraInstanceID .. ")"
						activeCount = activeCount + 1
					else
						activeStr = "|cff888888inactive|r"
					end
					print("  cdID: |cffffcc00" .. tostring(cooldownID) .. "|r - " .. activeStr)
				else
					print("  [frame without cooldownID]")
				end
			end
		end
		
		print("|cff00ff00GCDIndicator:|r " .. frameCount .. " frames, " .. activeCount .. " active")
	else
		if GCDI.create_options_frame then
			GCDI.create_options_frame()
		else
			print("|cffff0000GCDIndicator:|r Options module not loaded!")
		end
	end
end

C_Timer.After(2, function()
	print("|cff00ff00GCDIndicator:|r Type |cffffcc00/gcdopt|r to open options, |cffffcc00/gcdi|r to move bars")
end)

C_Timer.After(0.5, init)
