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

-- Library references
local LibProfiles = LibStub("LibGCDI-Profiles")
local LibResources = LibStub("LibGCDI-Resources")
local LibRange = LibStub("LibGCDI-Range")
local LibScanner = LibStub("LibGCDI-Scanner")
local LibBars = LibStub("LibGCDI-Bars")

-- Utility functions from libraries
local deepcopy = LibProfiles.deepcopy

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
-- Blizzard's CDM frames: cooldownID is readable; auraInstanceID and isActive may be SECRET.
-- Only pass auraInstanceID to APIs (e.g. GetAuraDataByAuraInstanceID); do not read or compare it.
GCDI.buffCatalog = {}
local trackedBuffs = {}
local buffBars = {}
local cdmBuffFrames = {}  -- cooldownID -> CDM frame reference
local lastBuffDebugState = {}  -- buffID -> { isActive, stacks } for debug-on-change only
local cooldownToSpellID = {}  -- Maps CDM cooldownID -> actual spellID (like ArcUI)
local spellIDToCooldownID = {}  -- REVERSE: Maps spellID -> cooldownID for frame lookup

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
	health = { 0.0, 0.8, 0.0 },        -- Green
	mana = { 0.0, 0.5, 1.0 },          -- Blue
	rage = { 0.8, 0.0, 0.0 },          -- Red
	energy = { 1.0, 0.85, 0.0 },       -- Yellow
	focus = { 1.0, 0.5, 0.2 },         -- Orange-brown (Hunter)
	runicPower = { 0.0, 0.82, 1.0 },   -- Cyan (Death Knight)
	runes = { 0.8, 0.2, 0.2 },         -- Dark Red (Death Knight)
	comboPoints = { 1.0, 0.5, 0.0 },   -- Orange
	soulShards = { 0.58, 0.51, 0.79 }, -- Purple (Warlock)
	holyPower = { 0.95, 0.9, 0.6 },    -- Gold (Paladin)
	chi = { 0.71, 1.0, 0.92 },         -- Jade (Monk)
	arcaneCharges = { 0.1, 0.1, 0.98 },-- Deep Blue (Arcane Mage)
	insanity = { 0.4, 0.0, 0.8 },      -- Deep Purple (Shadow Priest)
	maelstrom = { 0.0, 0.5, 1.0 },     -- Blue (Shaman)
	fury = { 0.79, 0.26, 0.99 },       -- Magenta (Havoc DH)
	pain = { 1.0, 0.61, 0.0 },         -- Orange (Vengeance DH)
	astralPower = { 0.3, 0.52, 0.9 },  -- Light Blue (Balance Druid)
	essence = { 0.27, 0.84, 0.76 },    -- Teal (Evoker)
	lunar = { 0.3, 0.52, 0.9 },        -- Blue (Balance Druid alternate)
	solar = { 1.0, 0.85, 0.0 },        -- Yellow (Balance Druid alternate)
}

-- Use range colors and items from library
local RANGE_COLORS = LibRange.RANGE_COLORS
GCDI.RANGE_ITEMS = LibRange.RANGE_ITEMS
local RANGE_ITEMS = GCDI.RANGE_ITEMS

local DEFAULT_SETTINGS = {
	globalRangeFallback = 1,  -- Default to melee (5 yards) for range detection
	spellSettings = {},
	spellOrder = {},
	itemSettings = {},
	itemOrder = {},
	buffSettings = {},
	buffOrder = {},
	profiles = {},
	currentProfile = nil,
	resourceSettings = {
		health = true,
		mana = true,
		rage = true,
		energy = true,
		focus = true,
		runicPower = true,
		runes = true,
		comboPoints = true,
		soulShards = true,
		holyPower = true,
		chi = true,
		arcaneCharges = true,
		insanity = true,
		maelstrom = true,
		fury = true,
		pain = true,
		astralPower = true,
		essence = true,
	},
	gcdSettings = {
		showGcdRow = true,
		showStance = true,
		showGcd = true,
		showCombat = true,
		showAggro = true,
		showMobCount = true,
		mobCountRange = 8,     -- Default range in yards
		mobCountThreshold = 3, -- Default threshold for white indicator
	},
}

-- Settings reference
GCDI.settings = nil
local settings = nil

local FORM_COLORS = {
	[0] = { 0.5, 0.5, 0.5 },   -- Caster (grey)
	[1] = { 0.6, 0.4, 0.2 },   -- Bear (brown)
	[2] = { 1.0, 0.6, 0.2 },   -- Cat (orange)
	[3] = { 0.3, 0.6, 1.0 },   -- Travel (blue)
	[4] = { 0.6, 0.4, 0.8 },   -- Moonkin (purple)
	[5] = { 0.2, 0.8, 0.4 },   -- Tree of Life (green)
	default = { 0.7, 0.7, 0.7 },
}

-- Get form/stance name dynamically from game API
-- Returns the actual spell name for the shapeshift form at given index
function GCDI.GetFormName(formIndex)
	if formIndex == 0 then
		return "No Form"
	end
	
	-- GetShapeshiftFormInfo returns: icon, active, castable, spellID
	local icon, active, castable, spellID = GetShapeshiftFormInfo(formIndex)
	if spellID then
		local name = C_Spell.GetSpellName(spellID)
		if name then
			return name
		end
	end
	
	return "Form " .. formIndex
end

-- Get all available forms for the player
function GCDI.GetAvailableForms()
	local forms = {}
	local numForms = GetNumShapeshiftForms() or 0
	
	-- Always include "No Form" as index 0
	table.insert(forms, { index = 0, name = "No Form", spellID = nil })
	
	for i = 1, numForms do
		local icon, active, castable, spellID = GetShapeshiftFormInfo(i)
		local name = GCDI.GetFormName(i)
		table.insert(forms, { index = i, name = name, spellID = spellID })
	end
	
	return forms
end

-- Export FORM_COLORS for options UI
GCDI.FORM_COLORS = FORM_COLORS

-- Forward declarations
local reposition_all, rebuild_spell_bars, rebuild_item_bars, rebuild_buff_bars

-- Layout bounds (updated by reposition_all, used by preview mode)
local layoutBounds = { width = 200, height = 100 }

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
		-- Must set min/max before SetTimerDuration (like ArcUI)
		bar:SetMinMaxValues(0, 1)
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

-- deepcopy is now provided by LibGCDI-Profiles

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

function GCDI.should_show_duration_bar(spellID)
	local buffSettings = GCDI.get_buff_settings(spellID)
	return buffSettings.showDurationBar == true  -- Default to NOT showing duration bar
end

function GCDI.get_duration_threshold(spellID)
	local buffSettings = GCDI.get_buff_settings(spellID)
	return buffSettings.durationThreshold or 30  -- Default to 30%
end

function GCDI.get_action_slot_for_spell(spellID)
	-- Get override spell ID (for talents that replace base spells)
	local overrideID = C_Spell.GetOverrideSpell(spellID) or spellID
	
	-- Scan all action slots (1-180 covers all action bars)
	for slot = 1, 180 do
		local actionType, id = GetActionInfo(slot)
		
		if actionType == "spell" and id then
			-- Direct spell match
			if id == spellID or id == overrideID then
				return slot
			end
			-- Check if this spell is an override of our target
			local slotOverride = C_Spell.GetOverrideSpell(id)
			if slotOverride and (slotOverride == spellID or slotOverride == overrideID) then
				return slot
			end
		elseif actionType == "macro" and id then
			-- Check macro for spell
			local macroSpell = GetMacroSpell(id)
			if macroSpell then
				if macroSpell == spellID or macroSpell == overrideID then
					return slot
				end
				local macroOverride = C_Spell.GetOverrideSpell(macroSpell)
				if macroOverride and (macroOverride == spellID or macroOverride == overrideID) then
					return slot
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
	local catalogs = {
		spellCatalog = GCDI.spellCatalog,
		itemCatalog = GCDI.itemCatalog,
		buffCatalog = GCDI.buffCatalog,
	}
	local success = LibProfiles:SaveProfile(settings, name, catalogs)
	if success then
		print("|cff00ff00GCDIndicator:|r Profile '" .. name .. "' saved!")
	end
	return success
end

function GCDI.load_profile(name)
	if not settings or not name then return false end
	if not settings.profiles or not settings.profiles[name] then
		print("|cffff0000GCDIndicator:|r Profile '" .. name .. "' not found!")
		return false
	end
	
	local catalogs = {
		spellCatalog = GCDI.spellCatalog,
		itemCatalog = GCDI.itemCatalog,
		buffCatalog = GCDI.buffCatalog,
	}
	local success = LibProfiles:LoadProfile(settings, name, catalogs)
	
	if success then
		rebuild_spell_bars()
		rebuild_item_bars()
		rebuild_buff_bars()
		reposition_all()
		if GCDI.refresh_options_frame then GCDI.refresh_options_frame() end
		print("|cff00ff00GCDIndicator:|r Profile '" .. name .. "' loaded!")
	end
	return success
end

delete_profile = function(name)
	local success = LibProfiles:DeleteProfile(settings, name)
	if success then
		print("|cff00ff00GCDIndicator:|r Profile '" .. name .. "' deleted!")
	end
	return success
end

function GCDI.auto_save_to_profile()
	local catalogs = {
		spellCatalog = GCDI.spellCatalog,
		itemCatalog = GCDI.itemCatalog,
		buffCatalog = GCDI.buffCatalog,
	}
	LibProfiles:AutoSave(settings, catalogs)
end

function GCDI.get_profile_names()
	return LibProfiles:GetProfileNames(settings)
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
	stackEmpty = { 0, 0, 0 },        -- Black for empty stack (0 stacks)
	stackHalf = { 0.4, 0.7, 1.0 },   -- Blue for 1 stack (half filled)
	stackFull = { 0.2, 0.8, 0.2 },   -- Green for 2 stacks (fully filled)
}

local function update_buff_bar(buffID)
	if previewMode then return end  -- Skip updates in preview mode
	if not GCDI.is_buff_enabled(buffID) then return end  -- Skip disabled buffs
	-- buffID can be spellID or cooldownID depending on source
	local data = trackedBuffs[buffID]
	if not data then return end
	
	-- Use Cooldown Manager integration (like ArcUI)
	-- CDM frames: cooldownID readable; auraInstanceID may be secret - pass only to APIs
	local isActive = false
	local stacks = 0
	
	-- Get catalog entry to find cooldownID
	local catalogEntry = GCDI.buffCatalog[buffID]
	local cooldownID = catalogEntry and catalogEntry.cooldownID or buffID
	
	-- Get fresh CDM frame reference from latest scan using cooldownID
	local cdmFrame = cdmBuffFrames[cooldownID]
	local lookupMethod = cdmFrame and "direct" or nil
	
	-- If not found by cooldownID, try reverse lookup (buffID might be spellID)
	if not cdmFrame and spellIDToCooldownID[buffID] then
		local mappedCooldownID = spellIDToCooldownID[buffID]
		cdmFrame = cdmBuffFrames[mappedCooldownID]
		if cdmFrame then
			cooldownID = mappedCooldownID  -- Update for later use
			lookupMethod = "reverse"
		end
	end
	
	-- Also check catalog for stored frame reference as fallback
	if not cdmFrame and catalogEntry and catalogEntry.cdmFrame then
		cdmFrame = catalogEntry.cdmFrame
		lookupMethod = "catalog"
	end
	
	-- Debug: show lookup status if frame not found
	if not cdmFrame and configs.debugMode then
		local hasCatalog = catalogEntry and "yes" or "no"
		local hasReverseMap = spellIDToCooldownID[buffID] and tostring(spellIDToCooldownID[buffID]) or "no"
		local totalFrames = 0
		for _ in pairs(cdmBuffFrames) do totalFrames = totalFrames + 1 end
		debug("LOOKUP FAIL for " .. buffID .. ": catalog=" .. hasCatalog .. " reverseMap=" .. hasReverseMap .. " totalCDMFrames=" .. totalFrames)
	end
	
	-- Helper to auto-detect unit (like ArcUI's GetAuraDataAutoUnit)
	local function GetAuraDataAutoUnit(auraInstanceID)
		if not auraInstanceID then return nil, nil end
		-- Try player first (most common for buffs)
		local auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("player", auraInstanceID)
		if auraData then return auraData, "player" end
		-- Try target (for debuffs like Rip)
		auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("target", auraInstanceID)
		if auraData then return auraData, "target" end
		return nil, nil
	end
	
	local detectedUnit = nil
	
	if cdmFrame then
		-- auraInstanceID may be secret; API errors if passed nil. Only call when present.
		local auraInstanceID = cdmFrame.auraInstanceID
		if auraInstanceID ~= nil then
			-- CDM can show auras on player (buffs) or target (debuffs). Use frame unit if available, else try player then target (like ArcUI).
			local unit = (cdmFrame.GetAuraDataUnit and cdmFrame:GetAuraDataUnit()) or nil
			local auraData
			if unit then
				auraData = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
			end
			if not auraData then
				auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("player", auraInstanceID)
				if auraData then unit = "player" end
			end
			if not auraData then
				auraData = C_UnitAuras.GetAuraDataByAuraInstanceID("target", auraInstanceID)
				if auraData then unit = "target" end
			end
			if auraData then
				isActive = true
				if data.stackDetectors then
					stacks = LibDetector:CheckValue(data.stackDetectors, auraData.applications)
				end
				-- Use resolved unit for duration bar below (so target debuffs get correct duration)
				data._lastAuraUnit = unit
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
	
	-- Debug output only when state changes (do not read auraInstanceID - it may be secret)
	if configs.debugMode then
		local last = lastBuffDebugState[buffID]
		local changed = not last or last.isActive ~= isActive or last.stacks ~= stacks
		if changed then
			lastBuffDebugState[buffID] = { isActive = isActive, stacks = stacks }
			local buffName = data.name or "Unknown"
			local frameInfo = cdmFrame and ("frame:yes hasAura:" .. (isActive and "yes" or "no")) or "no frame"
			local stackInfo = stacks > 0 and (" stacks:" .. stacks) or ""
			debug("Buff " .. buffName .. " (ID:" .. buffID .. ") " .. (isActive and "ACTIVE" or "INACTIVE") .. " " .. frameInfo .. stackInfo)
		end
	end
	
	if isActive then
		-- Buff is active
		data.active = true
		data.activeIndicator:SetColorTexture(BUFF_COLORS.active[1], BUFF_COLORS.active[2], BUFF_COLORS.active[3], 1)
		
		-- Update stack indicators if present
		-- Each indicator represents 2 stacks: blue = 1 stack, green = 2 stacks
		if data.stackIndicators and GCDI.should_show_buff_stacks(buffID) then
			-- Just iterate through all indicators we have (count is already correct)
			for i, indicator in ipairs(data.stackIndicators) do
				-- Indicator i represents stacks (2*i - 1) and (2*i)
				local stacksForThisIndicator = stacks - (2 * (i - 1))
				
				if stacksForThisIndicator >= 2 then
					-- 2 stacks = green (full)
					indicator.bg:SetColorTexture(BUFF_COLORS.stackFull[1], BUFF_COLORS.stackFull[2], BUFF_COLORS.stackFull[3], 1)
					indicator.overlay:Hide()
				elseif stacksForThisIndicator >= 1 then
					-- 1 stack = blue (half)
					indicator.bg:SetColorTexture(BUFF_COLORS.stackHalf[1], BUFF_COLORS.stackHalf[2], BUFF_COLORS.stackHalf[3], 1)
					indicator.overlay:Hide()
				else
					-- 0 stacks = black (empty)
					indicator.overlay:Show()
				end
				indicator.bg:Show()
			end
		end
		
		-- Update duration bar using CDM frame (pass auraInstanceID only when non-nil)
		if data.durationBar and cdmFrame and cdmFrame.auraInstanceID ~= nil then
			local unit = (cdmFrame.GetAuraDataUnit and cdmFrame:GetAuraDataUnit()) or data._lastAuraUnit or "player"
			local durObj = C_UnitAuras.GetAuraDuration(unit, cdmFrame.auraInstanceID)
			if durObj then
				data.durationBar.bar:SetMinMaxValues(0, 1)
				data.durationBar.bar:SetTimerDuration(durObj, Enum.StatusBarInterpolation.ExponentialEaseOut, Enum.StatusBarTimerDirection.RemainingTime)
			end
		end
	else
		-- Buff is not active
		data.active = false
		data.activeIndicator:SetColorTexture(BUFF_COLORS.inactive[1], BUFF_COLORS.inactive[2], BUFF_COLORS.inactive[3], 1)
		
		-- Show all stack indicators as black (empty)
		if data.stackIndicators then
			for _, indicator in ipairs(data.stackIndicators) do
				indicator.bg:SetColorTexture(BUFF_COLORS.stackHalf[1], BUFF_COLORS.stackHalf[2], BUFF_COLORS.stackHalf[3], 1)
				indicator.overlay:Show()  -- Show black overlay
			end
		end
		
		-- Reset duration bar
		if data.durationBar then
			data.durationBar.bar:SetValue(0)
		end
	end
end

local function update_all_buff_bars()
	if previewMode then return end  -- Skip updates in preview mode
	for spellID in pairs(trackedBuffs) do
		update_buff_bar(spellID)
	end
end

local function create_buff_bar(buffKey, spellName, texture, tooltipSpellID)
	local barIndex = #buffBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	-- Check if we should show stacks for this buff
	local showStacks = GCDI.should_show_buff_stacks(buffKey)
	local maxStacks = GCDI.get_buff_max_stacks_display(buffKey)  -- Max stacks setting (e.g., 10)
	-- Each indicator represents 2 stacks, so calculate indicator count
	local indicatorCount = math.ceil(maxStacks / 2)  -- e.g., 10 stacks = 5 indicators
	
	-- Check if we should show duration bar for this buff
	local showDurationBar = GCDI.should_show_duration_bar(buffKey)
	
	-- Layout: [Icon][Active Indicator][Stacks?][Duration Bar?]
	-- Active indicator is a single square that shows green when buff is active
	local stackWidth = showStacks and (indicatorCount * barSize + (indicatorCount - 1) * 2) or 0
	local extraGap = showStacks and 2 or 0
	local durationBarWidth = showDurationBar and (barSize + 2) or 0  -- 8x8 clipped indicator
	local containerWidth = (barSize * 2 + 2) + stackWidth + extraGap + durationBarWidth + pad * 2
	
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
	-- Each indicator represents 2 stacks: blue = 1 stack, green = 2 stacks
	local stackIndicators = nil
	local stackDetectors = nil
	
	local lastElement = activeIndicator  -- Track last element for duration bar positioning
	
	if showStacks and indicatorCount > 0 then
		stackIndicators = {}
		stackDetectors = LibDetector:CreateDetectorArray(maxStacks)  -- Detect up to maxStacks
		local prevElement = activeIndicator
		
		for i = 1, indicatorCount do
			-- Blue background (default color, will be updated based on stacks)
			local stackBg = container:CreateTexture(nil, "ARTWORK")
			stackBg:SetSize(barSize, barSize)
			stackBg:SetPoint("LEFT", prevElement, "RIGHT", 2, 0)
			stackBg:SetColorTexture(BUFF_COLORS.stackHalf[1], BUFF_COLORS.stackHalf[2], BUFF_COLORS.stackHalf[3], 1)
			
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
			lastElement = stackBg
		end
	end
	
	-- Duration bar (10k wide, clipped to 8x8, offset based on threshold)
	local durationBar = nil
	if showDurationBar then
		local threshold = GCDI.get_duration_threshold(buffKey)
		local barWidth = 10000
		local offset = -(threshold / 100) * barWidth  -- e.g., 30% = -3000px
		
		-- Clip container (8x8 visible window)
		local clipFrame = CreateFrame("Frame", nil, container)
		clipFrame:SetSize(barSize, barSize)
		clipFrame:SetPoint("LEFT", lastElement, "RIGHT", 2, 0)
		clipFrame:SetClipsChildren(true)
		
		-- White background (shows when bar has drained past this point)
		local bg = clipFrame:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(1, 1, 1, 1)
		
		-- Wide status bar (black), offset so threshold aligns with visible window
		local bar = CreateFrame("StatusBar", nil, clipFrame)
		bar:SetSize(barWidth, barSize)
		bar:SetPoint("LEFT", clipFrame, "LEFT", offset, 0)
		bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
		bar:SetStatusBarColor(0, 0, 0, 1)
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(1)
		
		durationBar = {
			clipFrame = clipFrame,
			bar = bar,
		}
	end
	
	trackedBuffs[buffKey] = {
		container = container,
		activeIndicator = activeIndicator,
		stackIndicators = stackIndicators,
		stackDetectors = stackDetectors,  -- For ArcUI-style stack detection
		durationBar = durationBar,
		active = false,
		name = spellName,
		icon = texture,
		tooltipSpellID = tooltipSpellID,  -- for tooltip (overrideTooltipSpellID; matches CDM)
	}
	buffBars[barIndex] = buffKey
	-- Tooltip: use tooltipSpellID so it matches CDM (overrideTooltipSpellID)
	if tooltipSpellID and tooltipSpellID > 0 then
		container:SetScript("OnEnter", function(self)
			local data = trackedBuffs[buffKey]
			if data and data.tooltipSpellID then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetSpellByID(data.tooltipSpellID)
				GameTooltip:Show()
			end
		end)
		container:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end
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
-- RANGE INDICATOR (via LibGCDI-Range)
-- ═══════════════════════════════════════════════════════════════════════════

-- Initialize LibRange with callbacks to access addon state
local function init_lib_range()
	LibRange:Init({
		getSettings = function() return settings end,
		getSpellSettings = function(spellID)
			return settings and settings.spellSettings and settings.spellSettings[spellID]
		end,
		setSpellSetting = function(spellID, key, value)
			if not settings then return end
			if not settings.spellSettings then settings.spellSettings = {} end
			if not settings.spellSettings[spellID] then settings.spellSettings[spellID] = {} end
			settings.spellSettings[spellID][key] = value
		end,
		isSpellEnabled = GCDI.is_spell_enabled,
		getTrackedSpells = function() return trackedSpells end,
		getSpellBars = function() return spellBars end,
		getSpellCatalog = function() return GCDI.spellCatalog end,
		isPreviewMode = function() return previewMode end,
		debugPrint = function(msg)
			if configs.debugMode then
				print("|cff00ff00GCDIndicator:|r " .. msg)
			end
		end,
	})
end

-- Wrapper functions for backward compatibility
local function detect_native_range_for_spells()
	LibRange:DetectNativeRangeForSpells()
end

GCDI.detect_native_range_for_spells = detect_native_range_for_spells

local function update_range_indicators()
	LibRange:UpdateRangeIndicators()
end

GCDI.UpdateRangeIndicators = update_range_indicators

-- Helper function used by spell bar creation
local function is_spell_self_cast(spellID)
	return LibRange:IsSpellSelfCast(spellID)
end

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
	if previewMode then return end
	if not resourceBars.rage then return end
	local bar = resourceBars.rage.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Rage)
	local max = tonumber(rawMax) or 100
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", Enum.PowerType.Rage))
end

local function update_energy_bar()
	if previewMode then return end
	if not resourceBars.energy then return end
	local bar = resourceBars.energy.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Energy)
	local max = tonumber(rawMax) or 100
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", Enum.PowerType.Energy))
end

local function update_combo_points_bar()
	if previewMode then return end
	if not resourceBars.comboPoints then return end
	local data = resourceBars.comboPoints
	local bar = data.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.ComboPoints)
	local actualMax = tonumber(rawMax) or 0
	-- If class doesn't have combo points (max = 0), show minimum 2 indicators for visual consistency
	local max = actualMax == 0 and 2 or math.max(actualMax, 1)
	
	bar:SetMinMaxValues(0, max)
	bar:SetValue(UnitPower("player", Enum.PowerType.ComboPoints))
	
	-- Fixed total width of 200px, calculate segment width based on max
	local totalWidth = 200
	local separatorWidth = 2
	local numSeparators = max - 1
	local totalSeparatorWidth = numSeparators * separatorWidth
	local segmentWidth = (totalWidth - totalSeparatorWidth) / max
	local pad = configs.bgPadding
	data.container:SetWidth(totalWidth + pad * 2)
	
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
end

local function update_mana_bar()
	if previewMode then return end
	if not resourceBars.mana then return end
	local bar = resourceBars.mana.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Mana)
	local max = tonumber(rawMax) or 100
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", Enum.PowerType.Mana))
end

local function update_focus_bar()
	if previewMode then return end
	if not resourceBars.focus then return end
	local bar = resourceBars.focus.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Focus)
	local max = tonumber(rawMax) or 100
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", Enum.PowerType.Focus))
end

local function update_runic_power_bar()
	if previewMode then return end
	if not resourceBars.runicPower then return end
	local bar = resourceBars.runicPower.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.RunicPower)
	local max = tonumber(rawMax) or 100
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", Enum.PowerType.RunicPower))
end

local function update_runes_bar()
	if previewMode then return end
	if not resourceBars.runes then return end
	local data = resourceBars.runes
	local bar = data.bar
	
	-- Check actual max runes (6 for DK, 0 for other classes)
	local rawMax = UnitPowerMax("player", Enum.PowerType.Runes)
	local actualMax = tonumber(rawMax) or 0
	-- If class doesn't have runes (max = 0), show minimum 2 indicators for visual consistency
	local max = actualMax == 0 and 2 or actualMax
	local current = UnitPower("player", Enum.PowerType.Runes) or 0
	
	bar:SetMinMaxValues(0, max)
	bar:SetValue(current)
	
	-- Update separators based on max
	if not data.separators then
		data.separators = {}
	end
	
	-- Fixed total width of 200px, calculate segment width based on max
	local totalWidth = 200
	local separatorWidth = 2
	local numSeparators = max - 1
	local totalSeparatorWidth = numSeparators * separatorWidth
	local segmentWidth = (totalWidth - totalSeparatorWidth) / max
	local pad = configs.bgPadding
	data.container:SetWidth(totalWidth + pad * 2)
	
	-- Create separator frame if needed
	if not data.separatorFrame then
		data.separatorFrame = CreateFrame("Frame", nil, data.container)
		data.separatorFrame:SetAllPoints(bar)
		data.separatorFrame:SetFrameLevel(data.container:GetFrameLevel() + 2)
	end
	
	-- Create/update separators
	for i = 1, max - 1 do
		if not data.separators[i] then
			local sep = data.separatorFrame:CreateTexture(nil, "OVERLAY")
			sep:SetColorTexture(0, 0, 0, 1)
			sep:SetSize(separatorWidth, configs.barHeight)
			data.separators[i] = sep
		end
		local xPos = (i * segmentWidth) + ((i - 1) * separatorWidth)
		data.separators[i]:ClearAllPoints()
		data.separators[i]:SetPoint("TOPLEFT", data.separatorFrame, "TOPLEFT", xPos, 0)
		data.separators[i]:Show()
	end
	
	-- Hide extra separators if any
	for i = max, #data.separators do
		if data.separators[i] then
			data.separators[i]:Hide()
		end
	end
end

-- Helper function to update charge-based resource bars with separators
local function update_charge_bar(data, powerType, defaultMax)
	if previewMode then return end
	if not data then return end
	local bar = data.bar
	local rawMax = UnitPowerMax("player", powerType)
	local actualMax = tonumber(rawMax) or 0
	-- If class doesn't have this resource (max = 0), show minimum 2 indicators for visual consistency
	local max = actualMax == 0 and 2 or math.max(actualMax, 1)
	
	bar:SetMinMaxValues(0, max)
	bar:SetValue(UnitPower("player", powerType))
	
	-- Update width and separators like combo points
	local totalWidth = 200
	local separatorWidth = 2
	local numSeparators = max - 1
	local totalSeparatorWidth = numSeparators * separatorWidth
	local segmentWidth = (totalWidth - totalSeparatorWidth) / max
	local pad = configs.bgPadding
	data.container:SetWidth(totalWidth + pad * 2)
	
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
end

local function update_soul_shards_bar()
	update_charge_bar(resourceBars.soulShards, Enum.PowerType.SoulShards, 5)
end

local function update_holy_power_bar()
	update_charge_bar(resourceBars.holyPower, Enum.PowerType.HolyPower, 5)
end

local function update_chi_bar()
	update_charge_bar(resourceBars.chi, Enum.PowerType.Chi, 5)
end

local function update_arcane_charges_bar()
	update_charge_bar(resourceBars.arcaneCharges, Enum.PowerType.ArcaneCharges, 4)
end

local function update_insanity_bar()
	if previewMode then return end
	if not resourceBars.insanity then return end
	local bar = resourceBars.insanity.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Insanity)
	local max = tonumber(rawMax) or 100
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", Enum.PowerType.Insanity))
end

local function update_maelstrom_bar()
	if previewMode then return end
	if not resourceBars.maelstrom then return end
	local bar = resourceBars.maelstrom.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Maelstrom)
	local max = tonumber(rawMax) or 100
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", Enum.PowerType.Maelstrom))
end

local function update_fury_bar()
	if previewMode then return end
	if not resourceBars.fury then return end
	local bar = resourceBars.fury.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Fury)
	local max = tonumber(rawMax) or 100
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", Enum.PowerType.Fury))
end

local function update_pain_bar()
	if previewMode then return end
	if not resourceBars.pain then return end
	local bar = resourceBars.pain.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Pain)
	local max = tonumber(rawMax) or 100
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", Enum.PowerType.Pain))
end

local function update_lunar_power_bar()
	if previewMode then return end
	if not resourceBars.astralPower then return end
	local bar = resourceBars.astralPower.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.LunarPower)
	local max = tonumber(rawMax) or 100
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", Enum.PowerType.LunarPower))
end

local function update_essence_bar()
	update_charge_bar(resourceBars.essence, Enum.PowerType.Essence, 5)
end

local function update_all_resources()
	update_health_bar()
	update_mana_bar()
	update_rage_bar()
	update_energy_bar()
	update_focus_bar()
	update_runic_power_bar()
	update_runes_bar()
	update_combo_points_bar()
	update_soul_shards_bar()
	update_holy_power_bar()
	update_chi_bar()
	update_arcane_charges_bar()
	update_insanity_bar()
	update_maelstrom_bar()
	update_fury_bar()
	update_pain_bar()
	update_lunar_power_bar()
	update_essence_bar()
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
	
	-- Check if target exists and is attackable (hostile). Don't require combat—pre-pull we show grey.
	local validTarget = UnitExists("target") and UnitCanAttack("player", "target")
	
	if not validTarget then
		-- No target or friendly target = white
		main_frame.aggrobar:SetStatusBarColor(1, 1, 1)
		return
	end
	
	-- Have target: grey (no aggro) or orange (has aggro). Only show grey when target is in combat and we don't have aggro.
	local hasAttackableTarget = UnitCanAttack("player", "target")
	local targetInCombat = UnitAffectingCombat("target")
	local threatStatus = UnitThreatSituation("player", "target")
	local hasAggro = threatStatus and threatStatus >= 2
	if not hasAggro and UnitExists("targettarget") and UnitIsUnit("targettarget", "player") then
		hasAggro = true
	end
	
	if hasAggro then
		main_frame.aggrobar:SetStatusBarColor(1, 0.5, 0)  -- Orange = has aggro
	elseif hasAttackableTarget and targetInCombat then
		main_frame.aggrobar:SetStatusBarColor(0.3, 0.3, 0.3)  -- Grey = in combat, no aggro
	else
		main_frame.aggrobar:SetStatusBarColor(0.3, 0.3, 0.3)  -- Grey = target not attackable or not in combat
	end
end

-- Range item IDs for mob counting (same as LibGCDI-Range)
local MOB_RANGE_ITEMS = {
	[5] = 37727,    -- 5 yards (melee)
	[8] = 63427,    -- 8 yards
	[10] = 34368,   -- 10 yards
	[15] = 32321,   -- 15 yards
	[20] = 21519,   -- 20 yards
	[28] = 116139,  -- 25 yards (close to 28)
	[40] = 41509,   -- 40 yards
}

-- Get the best range item for the given range
local function get_range_item_for_distance(range)
	if range <= 5 then return MOB_RANGE_ITEMS[5]
	elseif range <= 8 then return MOB_RANGE_ITEMS[8]
	elseif range <= 10 then return MOB_RANGE_ITEMS[10]
	elseif range <= 15 then return MOB_RANGE_ITEMS[15]
	elseif range <= 20 then return MOB_RANGE_ITEMS[20]
	elseif range <= 28 then return MOB_RANGE_ITEMS[28]
	else return MOB_RANGE_ITEMS[40]
	end
end

-- Count nearby hostile mobs within range using nameplates
local function count_nearby_mobs(range)
	local count = 0
	local nameplates = C_NamePlate.GetNamePlates()
	local rangeItemID = get_range_item_for_distance(range)
	
	if not nameplates then return 0 end
	
	for _, nameplate in pairs(nameplates) do
		-- Get unit token - can be either namePlateUnitToken or unitToken
		local unit = nameplate.namePlateUnitToken or nameplate.unitToken
		if unit and UnitExists(unit) then
			-- Check if hostile and alive
			local isHostile = UnitCanAttack("player", unit)
			local isAlive = not UnitIsDead(unit)
			
			if isHostile and isAlive then
				-- Use item-based range checking (works on hostile units)
				local inRange = C_Item.IsItemInRange(rangeItemID, unit)
				
				if inRange == true then
					count = count + 1
				end
			end
		end
	end
	
	return count
end

local function update_mob_count_indicator()
	if previewMode then return end  -- Skip updates in preview mode
	if not main_frame.mobcountbar then return end
	
	local gcdSettings = settings and settings.gcdSettings or {}
	local range = gcdSettings.mobCountRange or 8
	local threshold = gcdSettings.mobCountThreshold or 3
	
	local mobCount = count_nearby_mobs(range)
	
	if mobCount >= threshold then
		main_frame.mobcountbar:SetStatusBarColor(1, 1, 1)  -- White = at or above threshold
	else
		main_frame.mobcountbar:SetStatusBarColor(0, 0, 0)  -- Black = below threshold
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
	-- Each spell column is 1/3 the life bar width (~67px + padding)
	local columnWidth = math.floor(200 / 3) + pad * 2
	local columnGap = 4  -- Gap between columns
	
	local yOffset = 0
	
	-- Helper to check if a resource is enabled
	local function isResourceEnabled(key)
		if not settings or not settings.resourceSettings then return true end
		local enabled = settings.resourceSettings[key]
		if enabled == nil then return true end  -- Default to enabled
		return enabled
	end
	
	-- 1. GLOBAL CHECKS (GCD container: Stance, GCD, Combat, Aggro) - FIRST ROW
	local gcdSettings = settings.gcdSettings or {}
	if gcdSettings.showGcdRow ~= false then
		main_frame.gcdcontainer:ClearAllPoints()
		main_frame.gcdcontainer:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, yOffset)
		main_frame.gcdcontainer:Show()
		
		-- Show/hide individual elements based on settings
		if main_frame.stanceIndicator then
			main_frame.stanceIndicator:SetShown(gcdSettings.showStance ~= false)
		end
		if main_frame.gcdbar then
			main_frame.gcdbar:GetParent():SetShown(gcdSettings.showGcd ~= false)
		end
		if main_frame.combatbar then
			main_frame.combatbar:SetShown(gcdSettings.showCombat ~= false)
		end
		if main_frame.aggrobar then
			main_frame.aggrobar:SetShown(gcdSettings.showAggro ~= false)
		end
		if main_frame.mobcountbar then
			main_frame.mobcountbar:SetShown(gcdSettings.showMobCount ~= false)
		end
		
		yOffset = yOffset - gcdContainerHeight - spacing
	else
		main_frame.gcdcontainer:Hide()
	end
	
	-- 2. LIFE BAR (health)
	if resourceBars.health then
		if isResourceEnabled("health") then
			resourceBars.health.container:ClearAllPoints()
			resourceBars.health.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, yOffset)
			resourceBars.health.container:Show()
			yOffset = yOffset - resourceBarHeight - spacing
		else
			resourceBars.health.container:Hide()
		end
	end
	
	-- 3. RESOURCE BARS (all class resources)
	local otherResources = { 
		"mana", "rage", "energy", "focus", "runicPower", "runes",
		"comboPoints", "soulShards", "holyPower", "chi", "arcaneCharges",
		"insanity", "maelstrom", "fury", "pain", "astralPower", "essence"
	}
	for _, name in ipairs(otherResources) do
		if resourceBars[name] then
			if isResourceEnabled(name) then
				resourceBars[name].container:ClearAllPoints()
				resourceBars[name].container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, yOffset)
				resourceBars[name].container:Show()
				yOffset = yOffset - resourceBarHeight - spacing
			else
				resourceBars[name].container:Hide()
			end
		end
	end
	
	-- 4. SPELLS AND ITEMS in 2 columns
	-- Combine spells and items into one list
	local allSpellsAndItems = {}
	
	local orderedSpells = get_ordered_spells()
	for _, spellID in ipairs(orderedSpells) do
		local data = trackedSpells[spellID]
		if data and data.container then
			table.insert(allSpellsAndItems, { type = "spell", id = spellID, container = data.container })
		end
	end
	
	local orderedItems = GCDI.get_ordered_items()
	for _, itemKey in ipairs(orderedItems) do
		local data = trackedItems[itemKey]
		if data and data.container then
			table.insert(allSpellsAndItems, { type = "item", id = itemKey, container = data.container })
		end
	end
	
	-- Split into three columns
	local totalCount = #allSpellsAndItems
	local itemsPerColumn = math.ceil(totalCount / 3)
	local splitPoint1 = itemsPerColumn  -- End of first column
	local splitPoint2 = itemsPerColumn * 2  -- End of second column
	
	local col1Y = yOffset
	local col2Y = yOffset
	local col3Y = yOffset
	local col2X = columnWidth + columnGap  -- Second column X position
	local col3X = (columnWidth + columnGap) * 2  -- Third column X position
	
	for i, entry in ipairs(allSpellsAndItems) do
		entry.container:ClearAllPoints()
		if i <= splitPoint1 then
			-- First column (first third)
			entry.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, col1Y)
			col1Y = col1Y - spellBarHeight - spacing
		elseif i <= splitPoint2 then
			-- Second column (second third)
			entry.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", col2X, col2Y)
			col2Y = col2Y - spellBarHeight - spacing
		else
			-- Third column (last third)
			entry.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", col3X, col3Y)
			col3Y = col3Y - spellBarHeight - spacing
		end
		entry.container:Show()
	end
	
	-- Calculate where the columns end (use the lowest of the three)
	local columnsEndY = math.min(col1Y, col2Y, col3Y)
	
	-- 5. BUFFS below the spell/item columns (also in 3 columns)
	local orderedBuffs = get_ordered_buffs()
	local buffCount = #orderedBuffs
	local buffsPerColumn = math.ceil(buffCount / 3)
	local buffSplit1 = buffsPerColumn
	local buffSplit2 = buffsPerColumn * 2
	
	local buffCol1Y = columnsEndY
	local buffCol2Y = columnsEndY
	local buffCol3Y = columnsEndY
	
	for i, spellID in ipairs(orderedBuffs) do
		local data = trackedBuffs[spellID]
		if data and data.container then
			data.container:ClearAllPoints()
			if i <= buffSplit1 then
				-- First column
				data.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, buffCol1Y)
				buffCol1Y = buffCol1Y - spellBarHeight - spacing
			elseif i <= buffSplit2 then
				-- Second column
				data.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", col2X, buffCol2Y)
				buffCol2Y = buffCol2Y - spellBarHeight - spacing
			else
				-- Third column
				data.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", col3X, buffCol3Y)
				buffCol3Y = buffCol3Y - spellBarHeight - spacing
			end
			data.container:Show()
		end
	end
	
	-- Calculate final layout bounds
	-- Height is the lowest Y point reached (most negative)
	local finalY = math.min(buffCol1Y, buffCol2Y, buffCol3Y)
	
	-- Width depends on which columns are actually used
	local maxWidth = resourceBarWidth  -- Start with resource bar width as baseline
	
	-- Check how many columns spells/items use
	if totalCount > 0 then
		if totalCount > splitPoint2 then
			-- Using all 3 columns
			maxWidth = math.max(maxWidth, col3X + columnWidth)
		elseif totalCount > splitPoint1 then
			-- Using 2 columns
			maxWidth = math.max(maxWidth, col2X + columnWidth)
		else
			-- Using 1 column
			maxWidth = math.max(maxWidth, columnWidth)
		end
	end
	
	-- Check how many columns buffs use
	if buffCount > 0 then
		if buffCount > buffSplit2 then
			-- Using all 3 columns
			maxWidth = math.max(maxWidth, col3X + columnWidth)
		elseif buffCount > buffSplit1 then
			-- Using 2 columns
			maxWidth = math.max(maxWidth, col2X + columnWidth)
		else
			-- Using 1 column
			maxWidth = math.max(maxWidth, columnWidth)
		end
	end
	
	-- Store bounds (height is positive, representing total vertical space used)
	layoutBounds.width = maxWidth
	layoutBounds.height = -finalY  -- Convert negative offset to positive height
	
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

-- ═══════════════════════════════════════════════════════════════════════════
-- CDM SPELL INFO HELPER (match ArcUI: icon/tooltip from overrideTooltipSpellID)
-- CDM uses internal cooldownIDs; GetCooldownViewerCooldownInfo returns:
--   .spellID (base), .overrideSpellID (override), .overrideTooltipSpellID (display/tooltip).
-- ArcUI: "For auras, CDM often uses overrideTooltipSpellID for display" - icon and tooltip.
-- Priority: frame.cooldownInfo > C_CooldownViewer API; icon: frame texture > overrideTooltipSpellID > spellID.
-- ═══════════════════════════════════════════════════════════════════════════
local function GetCDMSpellInfo(frame, cooldownID)
	local spellID = nil
	local overrideSpellID = nil
	local overrideTooltipSpellID = nil
	local spellName = nil
	local texture = nil
	local hasCharges = false

	local cooldownInfo = frame and frame.cooldownInfo
	if not cooldownInfo and cooldownID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
		cooldownInfo = C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
	end
	if cooldownInfo then
		spellID = cooldownInfo.spellID
		overrideSpellID = cooldownInfo.overrideSpellID
		overrideTooltipSpellID = cooldownInfo.overrideTooltipSpellID
		hasCharges = cooldownInfo.hasCharges or false
	end
	local displaySpellID = overrideSpellID or spellID  -- for name/APIs

	-- 1) Icon: try frame's Icon first (what CDM actually shows)
	if frame and frame.Icon then
		local iconTex = frame.Icon
		if iconTex.GetTexture then
			local tex = iconTex:GetTexture()
			if tex and (not issecretvalue or not issecretvalue(tex)) and tex ~= 0 and tex ~= "" then
				texture = tex
			end
		end
		if not texture and iconTex.GetTextureFileID then
			local texID = iconTex:GetTextureFileID()
			if texID and (not issecretvalue or not issecretvalue(texID)) and texID > 0 then
				texture = texID
			end
		end
		-- Bar viewer: frame.Icon.Icon
		if not texture and iconTex.Icon then
			local inner = iconTex.Icon
			if inner.GetTexture then
				local tex = inner:GetTexture()
				if tex and (not issecretvalue or not issecretvalue(tex)) and tex ~= 0 and tex ~= "" then
					texture = tex
				end
			end
			if not texture and inner.GetTextureFileID then
				local texID = inner:GetTextureFileID()
				if texID and (not issecretvalue or not issecretvalue(texID)) and texID > 0 then
					texture = texID
				end
			end
		end
	end
	-- 2) Auras: overrideTooltipSpellID is what CDM uses for display (ArcUI)
	if not texture and overrideTooltipSpellID and overrideTooltipSpellID > 0 and C_Spell and C_Spell.GetSpellTexture then
		texture = C_Spell.GetSpellTexture(overrideTooltipSpellID)
	end
	if not texture and displaySpellID and C_Spell and C_Spell.GetSpellTexture then
		texture = C_Spell.GetSpellTexture(displaySpellID)
	end
	if not texture and spellID and spellID > 0 and C_Spell and C_Spell.GetSpellTexture then
		texture = C_Spell.GetSpellTexture(spellID)
	end
	if not texture then texture = 134400 end

	-- Name from same spell as tooltip (overrideTooltipSpellID first) so name matches what tooltip shows
	if overrideTooltipSpellID and overrideTooltipSpellID > 0 and C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(overrideTooltipSpellID)
		if info and info.name then spellName = info.name end
	end
	if not spellName and displaySpellID and C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(displaySpellID)
		if info and info.name then spellName = info.name end
	end
	if not spellName and spellID and spellID > 0 and C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(spellID)
		if info and info.name then spellName = info.name end
	end

	return displaySpellID or spellID, spellName, texture, hasCharges, overrideTooltipSpellID or displaySpellID or spellID
end

-- Scan Blizzard's Cooldown Manager for buff frames
-- Buffs are discovered in two ways:
-- 1) From CDM data provider: full list of buffs you have selected in CDM (TrackedBuff category).
--    This gives all 5 (or N) buffs even when only some have visible frames.
-- 2) From BuffIconCooldownViewer's itemFramePool: only frames that are currently active.
--    We use these for frame references (auraInstanceID, etc.); pool may have fewer than selected.
local function scan_cdm_buff_frames()
	-- Don't wipe - update in place to preserve references
	local foundThisScan = {}
	local foundCount = 0
	local newCount = 0

	-- Helper: add/update catalog from cooldownID; optional frame for refs and frame-based spell info
	local function processCooldownID(cooldownID, frame)
		if not cooldownID then return end
		if frame then
			foundCount = foundCount + 1
			cdmBuffFrames[cooldownID] = frame
			foundThisScan[cooldownID] = true
		end
		-- Get spell info (icon/tooltip match ArcUI: frame texture > overrideTooltipSpellID > spellID)
		local spellID, spellName, texture, hasCharges, tooltipSpellID = GetCDMSpellInfo(frame, cooldownID)
		-- Key by cooldownID so we get one bar per CDM slot (same spell can have multiple cdIDs, e.g. different sources)
		local catalogKey = cooldownID
		if spellID and spellID ~= cooldownID then
			cooldownToSpellID[cooldownID] = spellID
			spellIDToCooldownID[spellID] = cooldownID  -- REVERSE mapping for frame lookup
		end
		
		-- Debug: show each frame found
		if configs.debugMode then
			local catStr = (frame and frame.category) and tostring(frame.category) or "nil"
			local unitStr = (frame and frame.auraDataUnit) or "nil"
			debug("  Found: " .. (spellName or "?") .. " spellID:" .. tostring(spellID) .. " cdID:" .. tostring(cooldownID) .. " cat:" .. catStr .. " unit:" .. unitStr)
		end
		
		-- Detect if this is a target debuff vs player buff (only when we have a frame; otherwise assume player buff)
		-- Use auraDataUnit property OR category (3 = target debuff)
		local unit = (frame and frame.auraDataUnit) or "player"
		if unit == "player" and frame and frame.category == 3 then
			unit = "target"
		end
		local isTargetDebuff = (unit == "target")
		if not GCDI.buffCatalog[catalogKey] then
			GCDI.buffCatalog[catalogKey] = {
				name = spellName or ("Buff " .. catalogKey),
				texture = texture or 134400,
				cooldownID = cooldownID,
				spellID = spellID,
				tooltipSpellID = tooltipSpellID,  -- for tooltip (overrideTooltipSpellID; matches CDM)
				cdmFrame = frame,
				hasStacks = false,
				hasCharges = hasCharges,
				unit = unit,  -- Store unit for proper aura lookups
				isTargetDebuff = isTargetDebuff,
			}
			if settings then
				if not settings.buffSettings then settings.buffSettings = {} end
				if not settings.buffSettings[catalogKey] then
					settings.buffSettings[catalogKey] = { enabled = true, showStacks = true, maxStacksDisplay = 5 }
					newCount = newCount + 1
				end
				-- Append to buffOrder so the buff shows up in the ordered list
				if not settings.buffOrder then settings.buffOrder = {} end
				local inOrder = false
				for _, id in ipairs(settings.buffOrder) do
					if id == catalogKey then inOrder = true break end
				end
				if not inOrder then
					table.insert(settings.buffOrder, catalogKey)
				end
			end
			if configs.debugMode then
				local debuffInfo = isTargetDebuff and " [TARGET]" or ""
				debug("CDM auto-added: " .. (spellName or catalogKey) .. " (spellID:" .. tostring(spellID) .. ", cdID:" .. cooldownID .. ")" .. debuffInfo)
			end
		else
			local entry = GCDI.buffCatalog[catalogKey]
			entry.cdmFrame = frame or entry.cdmFrame
			entry.cooldownID = cooldownID
			if spellID and not entry.spellID then entry.spellID = spellID end
			if tooltipSpellID then entry.tooltipSpellID = tooltipSpellID end
			if spellName and entry.name:match("^Buff %d+$") then entry.name = spellName end
			if texture and entry.texture == 134400 then entry.texture = texture end
		end
	end

	-- Step 1: Get full list of buffs in CDM TrackedBuff (same sources as ArcUI: API + viewer).
	-- ArcUI Placeholders use C_CooldownViewer.GetCooldownViewerCategorySet(categoryNum, true) - no panel, taint-free.
	-- Categories: 0=Essential, 1=Utility, 2=TrackedBuff, 3=TrackedBar. Prefer viewer/data provider (user's exact list) then API.
	local TRACKED_BUFF_CATEGORY = 2
	local viewer = _G["BuffIconCooldownViewer"]
	local orderedIDs = nil
	if viewer and viewer.GetCooldownIDs then
		local ok, ids = pcall(function() return viewer:GetCooldownIDs() end)
		if ok and ids and #ids > 0 then orderedIDs = ids end
	end
	if (not orderedIDs or #orderedIDs == 0) and Enum and Enum.CooldownViewerCategory and Enum.CooldownViewerCategory.TrackedBuff then
		local settingsFrame = _G["CooldownViewerSettings"]
		if settingsFrame and settingsFrame.GetDataProvider then
			local provider = settingsFrame:GetDataProvider()
			if provider and provider.GetOrderedCooldownIDsForCategory then
				local ok, ids = pcall(function() return provider:GetOrderedCooldownIDsForCategory(Enum.CooldownViewerCategory.TrackedBuff) end)
				if ok and ids and #ids > 0 then orderedIDs = ids end
			end
		end
		if (not orderedIDs or #orderedIDs == 0) and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet then
			local ok, ids = pcall(function() return C_CooldownViewer.GetCooldownViewerCategorySet(TRACKED_BUFF_CATEGORY, true) end)
			if ok and ids and #ids > 0 then orderedIDs = ids end
		end
	end
	if orderedIDs and #orderedIDs > 0 then
		for _, cooldownID in ipairs(orderedIDs) do
			if type(cooldownID) == "number" then
				processCooldownID(cooldownID, nil)
			end
		end
	end

	-- Step 2: Scan viewer frames for frame references (and any we might have missed)
	if viewer then
		if viewer.itemFramePool then
			for frame in viewer.itemFramePool:EnumerateActive() do
				processCooldownID(frame.cooldownID, frame)
			end
		end
		if foundCount == 0 then
			local children = {viewer:GetChildren()}
			for _, frame in ipairs(children) do
				if frame and frame.cooldownID then
					processCooldownID(frame.cooldownID, frame)
				end
			end
		end
	end

	-- Clean up stale frame references (keep catalog entries)
	for buffID, frame in pairs(cdmBuffFrames) do
		if not foundThisScan[buffID] then
			cdmBuffFrames[buffID] = nil
		end
	end

	if configs.debugMode and (foundCount > 0 or newCount > 0) then
		debug("CDM scan: " .. foundCount .. " frames, " .. newCount .. " new")
	end

	return newCount
end

local function scan_buffs()
	-- Rebuild buffCatalog from saved settings (only for keys that are real spell IDs, not CDM cooldownIDs)
	if settings and settings.buffSettings then
		for key, _ in pairs(settings.buffSettings) do
			local numKey = tonumber(key)
			if numKey and numKey > 0 then
				-- Skip if this key is a CDM cooldownID (we'll get correct name/icon from scan_cdm_buff_frames)
				local isCDM = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo and C_CooldownViewer.GetCooldownViewerCooldownInfo(numKey)
				if isCDM then
					-- Leave to scan_cdm_buff_frames to add/refresh with correct CDM data
				elseif not GCDI.buffCatalog[numKey] then
					local spellName = C_Spell.GetSpellName(numKey)
					local texture = C_Spell.GetSpellTexture(numKey)
					if spellName and texture then
						GCDI.buffCatalog[numKey] = {
							name = spellName,
							texture = texture,
							spellID = numKey,
							tooltipSpellID = numKey,
							hasStacks = false,
						}
					end
				end
			end
		end
	end

	-- Scan CDM and refresh all buff entries (name/texture/tooltipSpellID from CDM; overwrites stale saved data)
	scan_cdm_buff_frames()
end

-- Export for manual triggering
GCDI.scan_cdm_buff_frames = scan_cdm_buff_frames

-- Helper to get spellID from cooldownID (like ArcUI's SafeGetCDMInfo)
-- Returns spellID if found, otherwise returns the original ID
function GCDI.GetSpellIDFromCooldownID(cooldownID)
	-- Check mapping table first
	local spellID = cooldownToSpellID[cooldownID]
	if spellID then return spellID end
	
	-- Check catalog entry
	local entry = GCDI.buffCatalog[cooldownID]
	if entry and entry.spellID then return entry.spellID end
	
	-- Return original if no mapping found
	return cooldownID
end

-- Get CDM info for a cooldownID (wrapper for C_CooldownViewer API)
function GCDI.GetCDMInfo(cooldownID)
	if type(cooldownID) ~= "number" then return nil end
	if not C_CooldownViewer or not C_CooldownViewer.GetCooldownViewerCooldownInfo then return nil end
	return C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
end

rebuild_buff_bars = function()
	clear_buff_bars()
	
	local orderedBuffs = GCDI.get_ordered_buffs()
	
	for _, buffKey in ipairs(orderedBuffs) do
		local catalogEntry = GCDI.buffCatalog[buffKey]
		if catalogEntry then
			local tooltipSpellID = catalogEntry.tooltipSpellID or catalogEntry.spellID
			create_buff_bar(buffKey, catalogEntry.name, catalogEntry.texture, tooltipSpellID)
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

-- Rebuilds all bars from current catalogs; does not scan. Use options buttons to rescan.
local function scan_action_bars()
	rebuild_spell_bars()
	rebuild_item_bars()
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
		-- Removed auto-scan: use /gcdopt scan to manually rescan
		update_item_charge_indicators()  -- Update charge indicators immediately
		
	elseif event == "UNIT_HEALTH" then
		if arg1 == "player" then
			update_health_bar()
		end
		
	elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_POWER_FREQUENT" then
		if arg1 == "player" then
			if arg2 == "MANA" then
				update_mana_bar()
			elseif arg2 == "RAGE" then
				update_rage_bar()
			elseif arg2 == "ENERGY" then
				update_energy_bar()
			elseif arg2 == "FOCUS" then
				update_focus_bar()
			elseif arg2 == "RUNIC_POWER" then
				update_runic_power_bar()
			elseif arg2 == "COMBO_POINTS" then
				update_combo_points_bar()
			elseif arg2 == "SOUL_SHARDS" then
				update_soul_shards_bar()
			elseif arg2 == "HOLY_POWER" then
				update_holy_power_bar()
			elseif arg2 == "CHI" then
				update_chi_bar()
			elseif arg2 == "ARCANE_CHARGES" then
				update_arcane_charges_bar()
			elseif arg2 == "INSANITY" then
				update_insanity_bar()
			elseif arg2 == "MAELSTROM" then
				update_maelstrom_bar()
			elseif arg2 == "FURY" then
				update_fury_bar()
			elseif arg2 == "PAIN" then
				update_pain_bar()
			elseif arg2 == "LUNAR_POWER" then
				update_lunar_power_bar()
			elseif arg2 == "ESSENCE" then
				update_essence_bar()
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
		-- Removed auto-scan: use /gcdopt scan to manually rescan
		update_all_resources()
		update_gcd()  -- Initialize GCD bar
		-- Try to detect native range after a delay (in case player has a target)
		C_Timer.After(3, detect_native_range_for_spells)
		
	elseif event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_BONUS_ACTIONBAR" then
		-- Only update stance indicator, don't rescan spells
		-- Spells should stay static unless profile is changed
		update_stance_indicator()
		
	elseif event == "RUNE_POWER_UPDATE" then
		update_runes_bar()
		
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		-- Removed auto-scan: use /gcdopt scan to manually rescan
		
	elseif event == "PLAYER_TARGET_CHANGED" then
		update_range_indicators()
		detect_native_range_for_spells()  -- Auto-detect native range when targeting
		update_aggro_indicator()
		
	elseif event == "UNIT_THREAT_SITUATION_UPDATE" then
		update_aggro_indicator()
		
	elseif event == "UNIT_TARGET" then
		if arg1 == "target" then
			update_aggro_indicator()  -- Target's target changed (e.g. mob switched to you)
		end
		
	elseif event == "UNIT_AURA" then
		if arg1 == "player" then
			-- Removed auto-scan: use /gcdopt scan to manually rescan
			-- Just update existing buff bars
			update_all_buff_bars()
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
		
	elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
		-- Channel started - show casting indicator (yellow)
		if arg1 == "player" and main_frame.castingbar then
			main_frame.castingbar:SetStatusBarColor(1, 0.8, 0)  -- Yellow
		end
		
	elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		-- Channel ended - hide casting indicator (black)
		if arg1 == "player" and main_frame.castingbar then
			main_frame.castingbar:SetStatusBarColor(0, 0, 0)  -- Black
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
	if not settings.resourceSettings then
		settings.resourceSettings = {
			health = true,
			mana = true,
			rage = true,
			energy = true,
			focus = true,
			runicPower = true,
			runes = true,
			comboPoints = true,
			soulShards = true,
			holyPower = true,
			chi = true,
			arcaneCharges = true,
			insanity = true,
			maelstrom = true,
			fury = true,
			pain = true,
			astralPower = true,
			essence = true,
		}
	end
	
	-- Initialize gcdSettings
	if not settings.gcdSettings then
		settings.gcdSettings = {
			showGcdRow = true,
			showStance = true,
			showGcd = true,
			showCombat = true,
			showAggro = true,
			showMobCount = true,
			mobCountRange = 8,
			mobCountThreshold = 3,
		}
	end
	-- Ensure new mob count settings exist for existing profiles
	if settings.gcdSettings.showMobCount == nil then
		settings.gcdSettings.showMobCount = true
	end
	if settings.gcdSettings.mobCountRange == nil then
		settings.gcdSettings.mobCountRange = 8
	end
	if settings.gcdSettings.mobCountThreshold == nil then
		settings.gcdSettings.mobCountThreshold = 3
	end
	
	-- Initialize catalog managers now that settings are available
	init_catalog_managers()
	
	-- Initialize range library with callbacks
	init_lib_range()
	
	main_frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 0)
	main_frame:SetSize(1, 1)
	
	local pad = configs.bgPadding
	
	local anchor = CreateFrame("Frame", nil, main_frame)
	anchor:SetSize(1, 1)
	anchor:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -5)  -- Default: top-left, 20px from edge
	main_frame.anchor = anchor
	
	local sepSize = 2
	local containerWidth = (configs.size * 6) + (sepSize * 5) + (pad * 2)  -- 6 indicators: stance, gcd, combat, aggro, casting, mobcount
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
	
	local sep4 = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	sep4:SetSize(sepSize, configs.size)
	sep4:SetPoint("LEFT", aggrobar, "RIGHT", 0, 0)
	sep4:SetColorTexture(0, 0, 0, 1)
	
	local castingbar = CreateFrame("StatusBar", nil, gcdCombatContainer)
	castingbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	castingbar:GetStatusBarTexture():SetHorizTile(false)
	castingbar:SetMinMaxValues(0, 100)
	castingbar:SetValue(100)
	castingbar:SetSize(configs.size, configs.size)
	castingbar:SetStatusBarColor(0, 0, 0)  -- Black = not channeling
	castingbar:SetPoint("LEFT", sep4, "RIGHT", 0, 0)
	main_frame.castingbar = castingbar
	
	local sep5 = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	sep5:SetSize(sepSize, configs.size)
	sep5:SetPoint("LEFT", castingbar, "RIGHT", 0, 0)
	sep5:SetColorTexture(0, 0, 0, 1)
	
	local mobcountbar = CreateFrame("StatusBar", nil, gcdCombatContainer)
	mobcountbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	mobcountbar:GetStatusBarTexture():SetHorizTile(false)
	mobcountbar:SetMinMaxValues(0, 100)
	mobcountbar:SetValue(100)
	mobcountbar:SetSize(configs.size, configs.size)
	mobcountbar:SetStatusBarColor(0, 0, 0)  -- Black = below threshold
	mobcountbar:SetPoint("LEFT", sep5, "RIGHT", 0, 0)
	main_frame.mobcountbar = mobcountbar
	
	GCDIndicator_Positions = GCDIndicator_Positions or {}
	local libGCDI = LibStub and LibStub:GetLibrary("LibGCDI", true)
	if libGCDI then
		libGCDI.load_position(anchor, "GCDIndicator", GCDIndicator_Positions)
	end
	
	local barSize = configs.barHeight
	-- Create all resource bars
	resourceBars.health = create_resource_bar("health", RESOURCE_COLORS.health)
	resourceBars.mana = create_resource_bar("mana", RESOURCE_COLORS.mana)
	resourceBars.rage = create_resource_bar("rage", RESOURCE_COLORS.rage)
	resourceBars.energy = create_resource_bar("energy", RESOURCE_COLORS.energy)
	resourceBars.focus = create_resource_bar("focus", RESOURCE_COLORS.focus)
	resourceBars.runicPower = create_resource_bar("runicPower", RESOURCE_COLORS.runicPower)
	resourceBars.runes = create_resource_bar("runes", RESOURCE_COLORS.runes)
	resourceBars.comboPoints = create_resource_bar("comboPoints", RESOURCE_COLORS.comboPoints)
	resourceBars.soulShards = create_resource_bar("soulShards", RESOURCE_COLORS.soulShards)
	resourceBars.holyPower = create_resource_bar("holyPower", RESOURCE_COLORS.holyPower)
	resourceBars.chi = create_resource_bar("chi", RESOURCE_COLORS.chi)
	resourceBars.arcaneCharges = create_resource_bar("arcaneCharges", RESOURCE_COLORS.arcaneCharges)
	resourceBars.insanity = create_resource_bar("insanity", RESOURCE_COLORS.insanity)
	resourceBars.maelstrom = create_resource_bar("maelstrom", RESOURCE_COLORS.maelstrom)
	resourceBars.fury = create_resource_bar("fury", RESOURCE_COLORS.fury)
	resourceBars.pain = create_resource_bar("pain", RESOURCE_COLORS.pain)
	resourceBars.astralPower = create_resource_bar("astralPower", RESOURCE_COLORS.astralPower)
	resourceBars.essence = create_resource_bar("essence", RESOURCE_COLORS.essence)
	
	-- Helper function to add separators to charge-based resource bars
	local function add_separators(resourceData, maxSeparators)
		resourceData.separators = {}
		local sepFrame = resourceData.separatorFrame
		for i = 1, maxSeparators do
			local sep = sepFrame:CreateTexture(nil, "OVERLAY")
			sep:SetSize(2, barSize)
			sep:SetColorTexture(0, 0, 0, 1)
			sep:Hide()
			resourceData.separators[i] = sep
		end
	end
	
	-- Add separators to all charge-based resources
	add_separators(resourceBars.comboPoints, 9)  -- Up to 10 combo points
	add_separators(resourceBars.soulShards, 4)   -- Up to 5 soul shards
	add_separators(resourceBars.holyPower, 4)    -- Up to 5 holy power
	add_separators(resourceBars.chi, 5)          -- Up to 6 chi
	add_separators(resourceBars.arcaneCharges, 3)-- Up to 4 arcane charges
	add_separators(resourceBars.essence, 5)      -- Up to 6 essence
	
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
		"RUNE_POWER_UPDATE",
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
	main_frame:RegisterUnitEvent("UNIT_TARGET", "target")  -- So aggro indicator updates when target's target changes
	main_frame:SetScript("OnEvent", on_event)

	if UnitAffectingCombat("player") then
		combatbar:SetStatusBarColor(1, 0, 0)
	end
	
	-- Initialize GCD bar immediately (don't wait for events)
	update_gcd()
	
	-- Removed auto-scan: use /gcdopt scan to manually rescan
	-- Spells will only be scanned when you press the scan button
	
	-- Removed auto-ingest: use /gcdopt scan or /gcdopt cdmimport to manually import CDM buffs
	
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
			
			-- Scan CDM frames AFTER profile load to get live frame references
			-- This populates cdmBuffFrames and spellIDToCooldownID mappings
			C_Timer.After(1.0, function()
				scan_cdm_buff_frames()
			end)
			
			print("|cff00ff00GCDIndicator:|r Profile '" .. settings.currentProfile .. "' loaded")
		end)
	end
	
	-- Master update ticker (0.015s / 15ms base interval)
	-- All updates run every tick except native range detection
	local tickCount = 0
	C_Timer.NewTicker(0.015, function()
		tickCount = tickCount + 1
		
		-- Every tick (15ms): All frequent updates
		update_gcd()
		animate_item_bars()
		update_charge_indicators_tick()
		update_range_indicators()
		update_all_buff_bars()
		
		-- Every 10 ticks (~150ms): Update mob count (doesn't need to be every frame)
		if tickCount % 10 == 0 then
			update_mob_count_indicator()
		end
		
		-- Buff scan only on "Rescan Buffs" button (no periodic scan)
		update_spell_icons()
		update_item_charge_indicators()
		
		-- Every 333 ticks (~5s): Native range detection
		if tickCount % 333 == 0 then
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
		
		-- Size and show background to cover all bars based on actual layout
		local bgPad = 10
		previewBackground:ClearAllPoints()
		previewBackground:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", -bgPad, bgPad + 5)
		-- Use calculated layout bounds + padding
		local bgWidth = layoutBounds.width + bgPad * 2
		local bgHeight = layoutBounds.height + bgPad * 2
		previewBackground:SetSize(bgWidth, bgHeight)
		previewBackground:Show()
		
		-- Fill all resource bars with visible colors
		-- IMPORTANT: Set MinMaxValues first, then Value, then Color
		if resourceBars then
			local allResources = {
				"health", "mana", "rage", "energy", "focus", "runicPower", "runes",
				"comboPoints", "soulShards", "holyPower", "chi", "arcaneCharges",
				"insanity", "maelstrom", "fury", "pain", "astralPower", "essence"
			}
			for _, key in ipairs(allResources) do
				local data = resourceBars[key]
				if data and data.bar then
					data.bar:SetMinMaxValues(0, 100)
					data.bar:SetValue(100)
					local color = RESOURCE_COLORS[key]
					if color then
						data.bar:SetStatusBarColor(color[1], color[2], color[3])
					end
				end
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
				for i, indicator in ipairs(data.stackIndicators) do
					-- Alternate colors in preview: odd = green (full), even = blue (half)
					if i % 2 == 1 then
						indicator.bg:SetColorTexture(BUFF_COLORS.stackFull[1], BUFF_COLORS.stackFull[2], BUFF_COLORS.stackFull[3], 1)
					else
						indicator.bg:SetColorTexture(BUFF_COLORS.stackHalf[1], BUFF_COLORS.stackHalf[2], BUFF_COLORS.stackHalf[3], 1)
					end
					indicator.overlay:Hide()
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
		if main_frame.castingbar then
			main_frame.castingbar:SetStatusBarColor(1, 0.8, 0)  -- Yellow = channeling
			main_frame.castingbar:SetValue(100)
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
		-- Call individual update functions to properly restore each resource bar
		update_all_resources()
		
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
		
		-- Reposition to restore proper layout based on settings
		reposition_all()
		
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
		-- Debug range detection for all tracked spells
		print("|cff00ff00GCDIndicator:|r --- Range Detection Debug ---")
		print("|cff888888Global Range Fallback: " .. tostring(settings.globalRangeFallback) .. " (" .. (LibRange.RANGE_ITEMS[settings.globalRangeFallback or 0].name or "Unknown") .. ")|r")
		print("|cff888888Target: " .. (UnitExists("target") and UnitName("target") or "None") .. "|r")
		print("")
		
		for spellID, data in pairs(trackedSpells) do
			local catalogEntry = GCDI.spellCatalog[spellID]
			local spellName = catalogEntry and catalogEntry.name or ("Spell " .. spellID)
			local actionSlot = data.actionSlot
			local spellSettings = settings.spellSettings and settings.spellSettings[spellID] or {}
			
			local rangeMethod = "Fallback Item"
			if spellSettings.selfCast then
				rangeMethod = "Self-Cast (hidden)"
			elseif spellSettings.rangeFallback then
				rangeMethod = "Override: " .. LibRange.RANGE_ITEMS[spellSettings.rangeFallback].name
			elseif spellSettings.hasNativeRange and actionSlot then
				rangeMethod = "Native (IsActionInRange)"
			elseif actionSlot then
				rangeMethod = "Action Slot (will try native)"
			end
			
			local slotInfo = actionSlot and ("|cff00ff00Slot " .. actionSlot .. "|r") or "|cffff0000No slot found|r"
			local rangeResult = "N/A"
			
			if actionSlot and UnitExists("target") then
				local inRange = IsActionInRange(actionSlot)
				if inRange == true then
					rangeResult = "|cff00ff00IN RANGE|r"
				elseif inRange == false then
					rangeResult = "|cffff0000OUT OF RANGE|r"
				else
					rangeResult = "|cff888888nil (no range info)|r"
				end
			end
			
			print("  " .. spellName .. " (ID: " .. spellID .. ")")
			print("    Action: " .. slotInfo .. " | Method: " .. rangeMethod)
			if UnitExists("target") then
				print("    Range Check: " .. rangeResult)
			end
		end
		
		if not UnitExists("target") then
			print("")
			print("|cffffcc00Tip: Target an enemy to see range check results|r")
		end
	
	elseif msg == "rangetest" then
		-- Force all range indicators to bright colors for visibility testing
		print("|cff00ff00GCDIndicator:|r Testing range indicator visibility...")
		local count = 0
		for spellID, data in pairs(trackedSpells) do
			if data.rangeOverlay then
				count = count + 1
				-- Cycle through bright colors
				local colorIndex = count % 3
				if colorIndex == 0 then
					data.rangeOverlay:SetColorTexture(1, 0, 1, 1)  -- Magenta
				elseif colorIndex == 1 then
					data.rangeOverlay:SetColorTexture(0, 1, 1, 1)  -- Cyan
				else
					data.rangeOverlay:SetColorTexture(1, 1, 0, 1)  -- Yellow
				end
				data.rangeOverlay:Show()
				if data.rangeBase then
					data.rangeBase:SetColorTexture(0, 0, 0, 1)  -- Black base for contrast
					data.rangeBase:Show()
				end
				print("  Spell " .. spellID .. ": overlay=" .. tostring(data.rangeOverlay:IsShown()) .. ", visible=" .. tostring(data.rangeOverlay:IsVisible()))
			else
				print("  Spell " .. spellID .. ": |cffff0000NO RANGE OVERLAY|r (self-cast or not created)")
			end
		end
		print("|cff00ff00GCDIndicator:|r Set " .. count .. " range overlays to bright colors")
		print("|cffffcc00Note: Colors will reset on next target change or update tick|r")
		
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
		
		-- Helper to print frame info with spell ID from cooldownInfo (like ArcUI)
		local function printFrameInfo(frame)
			frameCount = frameCount + 1
			local cooldownID = frame.cooldownID
			if not cooldownID then
				print("  [frame without cooldownID]")
				return
			end
			
			-- Get spellID from cooldownInfo (like ArcUI does)
			local spellID = nil
			local spellName = nil
			local cooldownInfo = frame.cooldownInfo
			if cooldownInfo then
				spellID = cooldownInfo.overrideSpellID or cooldownInfo.spellID
			end
			
			-- Try CDM API as fallback
			if not spellID and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
				local cdInfo = C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
				if cdInfo then
					spellID = cdInfo.overrideSpellID or cdInfo.spellID
				end
			end
			
			-- Get spell name
			if spellID and C_Spell and C_Spell.GetSpellInfo then
				local info = C_Spell.GetSpellInfo(spellID)
				if info then spellName = info.name end
			end
			
			-- Active state: pass auraInstanceID only to API when non-nil (API errors on nil)
			local auraData = (frame.auraInstanceID ~= nil) and C_UnitAuras.GetAuraDataByAuraInstanceID("player", frame.auraInstanceID) or nil
			local activeStr = auraData and "|cff00ff00ACTIVE|r" or "|cff888888inactive|r"
			if auraData then activeCount = activeCount + 1 end
			
			-- Print with spellID and name
			local spellStr = spellID and ("|cff88ccffspell:" .. spellID .. "|r") or "|cffff8888no-spell|r"
			local nameStr = spellName and (" |cffffffff\"" .. spellName .. "\"|r") or ""
			print("  cdID: |cffffcc00" .. tostring(cooldownID) .. "|r " .. spellStr .. nameStr .. " - " .. activeStr)
		end
		
		-- Try itemFramePool first
		if viewer.itemFramePool then
			print("Using itemFramePool:EnumerateActive()...")
			for frame in viewer.itemFramePool:EnumerateActive() do
				printFrameInfo(frame)
			end
		end
		
		-- Also check GetChildren if itemFramePool didn't find anything
		if frameCount == 0 then
			print("Using GetChildren()...")
			local children = {viewer:GetChildren()}
			for _, frame in ipairs(children) do
				printFrameInfo(frame)
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
