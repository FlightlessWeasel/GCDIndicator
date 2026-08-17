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
	useNativeStackBinding = false,  -- experimental A/B toggle, see CHANGE-TRACKER.md
	compactMode = true,  -- flow-packed spell/item/buff layout, see CHANGE-TRACKER.md
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
local CreateUnitHealPredictionCalculator = CreateUnitHealPredictionCalculator
local UnitGetDetailedHealPrediction = UnitGetDetailedHealPrediction
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
local LibRange = LibStub("LibGCDI-Range")

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
-- Blizzard's CDM frames: cooldownID is readable; auraInstanceID may be SECRET.
-- 12.1+: GetAuraDataByAuraInstanceID Lua-errors when auras are secret while tainted.
-- Active = auraInstanceID ~= nil. Stacks/duration: use auraDataCached / GetAuraDuration (tainted-safe).
GCDI.buffCatalog = {}
local trackedBuffs = {}
local buffBars = {}
local cdmBuffFrames = {}  -- cooldownID -> CDM frame reference
local lastBuffDebugState = {}  -- buffID -> { isActive } for debug-on-change only
-- Interface 120100+ (12.1): instance-ID aura data APIs throw under secrecy for addons.
local GCDI_AURAS_INSTANCE_API_UNSAFE = (tonumber((select(4, GetBuildInfo()))) or 0) >= 120100
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
	-- Fixed mint (not Blizzard green/yellow/red) for a stable, distinct in-range color
	stagger = { 0.35, 0.90, 0.55 },   -- Brewmaster stagger vs max health
}

local WHITE_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local function init_status_bar_texture(bar) bar:SetStatusBarTexture(WHITE_TEXTURE) local tex = bar:GetStatusBarTexture() if tex and tex.SetHorizTile then tex:SetHorizTile(false) end end
local GCDI_PREFIX = "|cff00ff00GCDIndicator:|r "

-- Use range colors and items from library
local RANGE_COLORS = LibRange.RANGE_COLORS
GCDI.RANGE_ITEMS = LibRange.RANGE_ITEMS
GCDI.RANGE_YARDS_ORDER = LibRange.RANGE_YARDS_ORDER
GCDI.LEGACY_INDEX_TO_YARDS = LibRange.LEGACY_INDEX_TO_YARDS
local RANGE_ITEMS = GCDI.RANGE_ITEMS
local RANGE_YARDS_ORDER = GCDI.RANGE_YARDS_ORDER

local DEFAULT_SETTINGS = {
	globalRangeFallbackYards = 5,  -- Default melee (5 yards)
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
local reposition_all, rebuild_spell_bars, rebuild_item_bars, rebuild_buff_bars, update_dispel_indicator

-- Layout bounds (updated by reposition_all, used by preview mode)
local layoutBounds = { width = 200, height = 100 }

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

local function debug(msg)
	if configs.debugMode then
		print(GCDI_PREFIX .. msg)
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

-- deepcopy is now provided by LibGCDI-Profiles

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELL/ITEM HELPERS (exposed to GCDI)
-- ═══════════════════════════════════════════════════════════════════════════

local function make_enabled_checker(category) return function(key) if not settings then return true end local catSettings = settings[category] if catSettings and catSettings[key] and catSettings[key].enabled == false then return false end return true end end
GCDI.is_spell_enabled = make_enabled_checker("spellSettings")
GCDI.is_item_enabled = make_enabled_checker("itemSettings")
GCDI.is_buff_enabled = make_enabled_checker("buffSettings")

function GCDI.get_setting(category, key, field, default) if not settings then return default end local catSettings = settings[category] if not catSettings then return default end local entry = catSettings[key] if not entry then return default end return entry[field] or default end

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

-- spellID -> action slot, built by one pass over the 180 slots.
--
-- This used to be a linear scan run once per spell, so a rebuild with N spells did
-- 180*N GetActionInfo calls plus as many GetOverrideSpell calls. Both the base ID and
-- the override ID of each slot are indexed, so a spell is found by either.
local actionSlotBySpell = {}
local actionSlotMapDirty = true

local function gcdi_index_slot(map, id, slot)
	if id and map[id] == nil then
		map[id] = slot
	end
end

local function gcdi_rebuild_action_slot_map()
	actionSlotMapDirty = false
	wipe(actionSlotBySpell)

	-- Scan all action slots (1-180 covers all action bars)
	for slot = 1, 180 do
		local actionType, id = GetActionInfo(slot)

		if actionType == "spell" and id then
			gcdi_index_slot(actionSlotBySpell, id, slot)
			gcdi_index_slot(actionSlotBySpell, C_Spell.GetOverrideSpell(id), slot)
		elseif actionType == "macro" and id then
			local macroSpell = GetMacroSpell(id)
			if macroSpell then
				gcdi_index_slot(actionSlotBySpell, macroSpell, slot)
				gcdi_index_slot(actionSlotBySpell, C_Spell.GetOverrideSpell(macroSpell), slot)
			end
		end
	end
end

local function gcdi_invalidate_action_slot_map()
	actionSlotMapDirty = true
end

GCDI.invalidate_action_slot_map = gcdi_invalidate_action_slot_map

function GCDI.get_action_slot_for_spell(spellID)
	if actionSlotMapDirty then
		gcdi_rebuild_action_slot_map()
	end

	local slot = actionSlotBySpell[spellID]
	if slot then return slot end

	-- Talent replacements: the catalog may hold the base ID while the bar holds the override.
	local overrideID = C_Spell.GetOverrideSpell(spellID)
	if overrideID and overrideID ~= spellID then
		return actionSlotBySpell[overrideID]
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
		print("GCDI_PREFIXProfile '" .. name .. "' saved!")
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
		rebuild_spell_bars() -- also rebuilds item bars
		rebuild_buff_bars()
		reposition_all()
		if GCDI.refresh_options_frame then GCDI.refresh_options_frame() end
		print("GCDI_PREFIXProfile '" .. name .. "' loaded!")
	end
	return success
end

delete_profile = function(name)
	local success = LibProfiles:DeleteProfile(settings, name)
	if success then
		print("GCDI_PREFIXProfile '" .. name .. "' deleted!")
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
			print("GCDI_PREFIXSpell bars rebuilt")
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
			print("GCDI_PREFIXItem bars rebuilt")
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
			print("GCDI_PREFIXBuff bars rebuilt")
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

function GCDI.move_spell_to_top(spellID)
	if spellCatalogManager then spellCatalogManager:MoveToTop(spellID) end
end

-- Persists a full drag-reordered list in one shot (vs. repeated MoveInOrder
-- calls) - used by the options UI's drag-to-reorder gesture.
function GCDI.commit_spell_order(orderedSpellIDs)
	if spellCatalogManager then spellCatalogManager:CommitOrder(orderedSpellIDs) end
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

function GCDI.move_item_to_top(itemKey)
	if itemCatalogManager then itemCatalogManager:MoveToTop(itemKey) end
end

function GCDI.commit_item_order(orderedItemKeys)
	if itemCatalogManager then itemCatalogManager:CommitOrder(orderedItemKeys) end
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

function GCDI.move_buff_to_top(spellID)
	if buffCatalogManager then buffCatalogManager:MoveToTop(spellID) end
end

function GCDI.commit_buff_order(orderedBuffKeys)
	if buffCatalogManager then buffCatalogManager:CommitOrder(orderedBuffKeys) end
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
	
	-- Charge and non-charge spells both read the spell's own cooldown duration: a
	-- charge spell reports GCD while charges remain and the real cooldown otherwise.
	applyTimerToBar(data.bar, C_Spell.GetSpellCooldownDuration(spellID))
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

-- Off-GCD is rare (most spells trigger the GCD), so this defaults false
-- (on-GCD) unless the user explicitly flags a spell otherwise. Metadata
-- only - doesn't affect the addon's own cooldown-swipe display (that's
-- already GCD-agnostic); exists so the companion-script config export
-- (export_companion_config) can generate an accurate hasGCD field instead of
-- leaving it manual.
local function is_spell_off_gcd(spellID)
	if not settings then return false end
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.offGCD == true then
		return true
	end
	return false
end

GCDI.is_spell_off_gcd = is_spell_off_gcd

-- Same as is_spell_off_gcd but for the Items tab/catalog.
local function is_item_off_gcd(itemKey)
	if not settings then return false end
	local itemSettings = settings.itemSettings[itemKey]
	if itemSettings and itemSettings.offGCD == true then
		return true
	end
	return false
end

GCDI.is_item_off_gcd = is_item_off_gcd

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

-- True if this charge table represents a real charge spell (max > 0, or max secret / nil for API quirks)
local function gcdi_charge_info_is_usable(info)
	if not info then
		return false
	end
	local m = info.maxCharges
	if m == nil then
		return true
	end
	if issecretvalue and issecretvalue(m) then
		return true
	end
	return (tonumber(m) or 0) > 0
end

-- Charge info: prefer action slot (same as Blizzard ActionButton) so bar/catalog spell ID matches the bar.
local function gcdi_get_spell_charge_info(spellID, actionSlot)
	if actionSlot and C_ActionBar and C_ActionBar.GetActionCharges then
		local ok, info = pcall(C_ActionBar.GetActionCharges, actionSlot)
		if ok and info and gcdi_charge_info_is_usable(info) then
			return info
		end
	end
	local info = C_Spell.GetSpellCharges(spellID)
	if info and gcdi_charge_info_is_usable(info) then
		return info
	end
	local oid = C_Spell.GetOverrideSpell(spellID)
	if oid and oid ~= spellID then
		info = C_Spell.GetSpellCharges(oid)
		if info and gcdi_charge_info_is_usable(info) then
			return info
		end
	end
	return nil
end

local function gcdi_resolve_max_charges(chargeInfo)
	if not chargeInfo then
		return 0
	end
	local m = chargeInfo.maxCharges
	if m == nil then
		return 0
	end
	if issecretvalue and issecretvalue(m) then
		return 0
	end
	return math.max(0, math.floor(tonumber(m) or 0))
end

-- Pip count for layout: optional per-spell override when API max is secret or missing.
local function gcdi_effective_max_charge_pips(spellID, chargeInfo)
	local st = settings and settings.spellSettings and settings.spellSettings[spellID]
	local ov = st and st.chargePipOverride
	if type(ov) == "number" then
		ov = math.floor(ov)
		if ov >= 2 and ov <= 6 then
			return ov
		end
	end
	return gcdi_resolve_max_charges(chargeInfo)
end

-- Spell charge display: same pattern as buff stacks — one StatusBar, black separators, currentCharges passed through to SetValue.
local SPELL_CHARGE_STACK_COLOR = { 0.4, 0.7, 1.0 }

local function compute_separator_layout(maxSegments, totalWidth, separatorWidth)
	local numSeps = maxSegments - 1
	local totalSepWidth = numSeps * separatorWidth
	local segmentWidth = (totalWidth - totalSepWidth) / maxSegments
	return segmentWidth, totalSepWidth, numSeps
end

local function layout_spell_charge_stack_separators(data)
	if not data or not data.chargeStackBar then return end
	local maxStacks = math.max(data.chargeStackMax or 1, 1)
	local barSize = configs.barHeight
	local separatorWidth = 2
	local totalWidth = maxStacks * barSize + (maxStacks - 1) * separatorWidth
	local segmentWidth = compute_separator_layout(maxStacks, totalWidth, separatorWidth)
	local sf = data.chargeStackBar.separatorFrame
	if not sf then return end
	if not data.chargeStackBar.separators then
		data.chargeStackBar.separators = {}
	end
	for i = 1, maxStacks - 1 do
		if not data.chargeStackBar.separators[i] then
			local sep = sf:CreateTexture(nil, "OVERLAY")
			sep:SetSize(separatorWidth, barSize)
			sep:SetColorTexture(0, 0, 0, 1)
			data.chargeStackBar.separators[i] = sep
		end
		local xPos = (i * segmentWidth) + ((i - 1) * separatorWidth)
		data.chargeStackBar.separators[i]:ClearAllPoints()
		data.chargeStackBar.separators[i]:SetPoint("TOPLEFT", sf, "TOPLEFT", xPos, 0)
		data.chargeStackBar.separators[i]:Show()
	end
	for i = maxStacks, #data.chargeStackBar.separators do
		local sep = data.chargeStackBar.separators[i]
		if sep then
			sep:Hide()
		end
	end
end

-- After leaving combat, rebuild if charge API now reports a numeric max (or override changed effective layout).
local function gcdi_needs_charge_layout_rebuild()
	if not settings or not settings.spellSettings then
		return false
	end
	for spellID, data in pairs(trackedSpells) do
		if data.isChargeSpell and GCDI.is_spell_enabled(spellID) then
			local info = gcdi_get_spell_charge_info(spellID, data.actionSlot)
			local effectiveMax = gcdi_effective_max_charge_pips(spellID, info)
			local wantPips = effectiveMax > 1
			local hasPips = (data.chargeStackBar ~= nil)
			if wantPips ~= hasPips then
				return true
			end
			if wantPips and hasPips and (data.maxCharges or 0) ~= effectiveMax then
				return true
			end
		end
	end
	return false
end

-- Membership only changes when bars are rebuilt or a spell is enabled/disabled, but
-- this list is walked on the update ticker; building + sorting it per tick was pure
-- garbage. Built once and invalidated explicitly.
local chargeSpellIDList = {}
local chargeSpellIDListDirty = true

local function gcdi_invalidate_charge_spell_list()
	chargeSpellIDListDirty = true
end

GCDI.invalidate_charge_spell_list = gcdi_invalidate_charge_spell_list

local function gcdi_charge_spell_id_list()
	if chargeSpellIDListDirty then
		chargeSpellIDListDirty = false
		wipe(chargeSpellIDList)
		for spellID, data in pairs(trackedSpells) do
			if data.chargeStackBar and GCDI.is_spell_enabled(spellID) then
				chargeSpellIDList[#chargeSpellIDList + 1] = spellID
			end
		end
		table.sort(chargeSpellIDList)
	end
	return chargeSpellIDList
end

local function gcdi_update_spell_charge_stack(spellID)
	local data = trackedSpells[spellID]
	if not data or not data.chargeStackBar or not data.chargeStackBar.bar then return end
	if not GCDI.is_spell_enabled(spellID) then return end
	local chargeInfo = gcdi_get_spell_charge_info(spellID, data.actionSlot)
	if not chargeInfo or chargeInfo.currentCharges == nil then return end
	local maxS = math.max(data.chargeStackMax or 1, 1)
	data.chargeStackBar.bar:SetMinMaxValues(0, maxS)
	data.chargeStackBar.bar:SetValue(chargeInfo.currentCharges)
end

local function update_charge_indicators_tick()
	if previewMode then return end
	for _, spellID in ipairs(gcdi_charge_spell_id_list()) do
		gcdi_update_spell_charge_stack(spellID)
	end
end

local function update_all_charge_indicators()
	update_charge_indicators_tick()
end

local function create_bar_container(parent, texture, compact, barSize, pad)
	local containerWidth = compact and barSize or (barSize * 4 + pad * 2)
	local container = CreateFrame("Frame", nil, parent)
	container:SetSize(containerWidth, barSize + pad * 2)
	local bg = container:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)
	local icon = container:CreateTexture(nil, "ARTWORK")
	icon:SetSize(barSize, barSize)
	icon:SetPoint("LEFT", pad, 0)
	icon:SetTexture(texture)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	if compact then icon:Hide() end
	local clipContainer = CreateFrame("Frame", nil, container)
	clipContainer:SetSize(barSize, barSize)
	if compact then clipContainer:SetPoint("LEFT", pad, 0) else clipContainer:SetPoint("LEFT", icon, "RIGHT", 2, 0) end
	clipContainer:SetClipsChildren(true)
	local cdBg = clipContainer:CreateTexture(nil, "BACKGROUND")
	cdBg:SetAllPoints()
	cdBg:SetColorTexture(1, 1, 1, 1)
	local bar = CreateFrame("StatusBar", nil, clipContainer)
	init_status_bar_texture(bar)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	bar:SetSize(10000, barSize)
	bar:SetStatusBarColor(0, 0, 0)
	bar:SetPoint("LEFT")
	return container, icon, clipContainer, bar
end

local function create_stack_separator_area(parent, anchorElement, maxStacks, barSize, color, initialValue)
	local separatorWidth = 2
	local stackBarWidth = maxStacks * barSize + (maxStacks - 1) * separatorWidth
	local stackArea = CreateFrame("Frame", nil, parent)
	stackArea:SetSize(stackBarWidth, barSize)
	stackArea:SetPoint("LEFT", anchorElement, "RIGHT", 2, 0)
	local sb = CreateFrame("StatusBar", nil, stackArea)
	sb:SetPoint("TOPLEFT", stackArea, "TOPLEFT", 0, 0)
	sb:SetPoint("BOTTOMRIGHT", stackArea, "BOTTOMRIGHT", 0, 0)
	init_status_bar_texture(sb)
	sb:SetStatusBarColor(color[1], color[2], color[3], 1)
	sb:SetMinMaxValues(0, maxStacks)
	sb:SetValue(initialValue)
	local separatorFrame = CreateFrame("Frame", nil, stackArea)
	separatorFrame:SetAllPoints(stackArea)
	separatorFrame:SetFrameLevel(stackArea:GetFrameLevel() + 10)
	return stackArea, {
		bar = sb,
		separatorFrame = separatorFrame,
		separators = {},
	}
end

local function create_spell_bar(spellID, spellName, texture, actionSlot)
	local barIndex = #spellBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	-- Check if spell has charges (action slot first — catalog spell ID often != bar spell ID in Midnight)
	local chargeInfo = gcdi_get_spell_charge_info(spellID, actionSlot)
	local isChargeSpell = (chargeInfo ~= nil)
	local maxCharges = gcdi_effective_max_charge_pips(spellID, chargeInfo)
	
	-- Only show charge INDICATORS if > 1 charge (visual boxes)
	local showChargeIndicators = maxCharges > 1
	
	-- Check if icon tracking is enabled
	local trackIcon = should_track_spell_icon(spellID)
	
	-- Check if spell is self-cast (no range indicator needed)
	local isSelfCast = is_spell_self_cast(spellID)

	-- Compact mode drops the icon square entirely (not just hidden) to
	-- maximize density - the cooldown-clip square becomes the first box
	-- instead of the second. See CHANGE-TRACKER.md.
	local compact = configs.compactMode

	-- Calculate container width based on spell settings
	-- Layout: [pad][icon?][2?][cooldown][2][range?][2][charge stack?][2][iconChange?][pad]
	local chargeWidth = showChargeIndicators and (maxCharges * barSize + (maxCharges - 1) * 2) or 0  -- squares + gaps
	local extraGap = showChargeIndicators and 2 or 0  -- gap before charges section
	local iconChangeWidth = trackIcon and (barSize + 2) or 0  -- icon change indicator + gap
	local rangeWidth = isSelfCast and 0 or (barSize + 2)  -- range indicator + gap (or 0 for self-cast)
	local iconWidth = compact and 0 or (barSize + 2)  -- icon square + gap before cooldown (0 in compact mode)
	local containerWidth = barSize + iconWidth + rangeWidth + chargeWidth + extraGap + iconChangeWidth + pad * 2

	local container, icon, clipContainer, bar = create_bar_container(main_frame, texture, compact, barSize, pad)
	container:SetSize(containerWidth, barSize + pad * 2)
	
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
	
	-- Charge stack bar (buff-style: one StatusBar + segment separators; value pass-through)
	local chargeStackBar = nil
	local chargeStackMax = nil
	
	if showChargeIndicators then
		chargeStackMax = maxCharges
		local stackArea, csb = create_stack_separator_area(container, lastElement, maxCharges, barSize, SPELL_CHARGE_STACK_COLOR, maxCharges)
		chargeStackBar = csb
		lastElement = stackArea
		layout_spell_charge_stack_separators({ chargeStackBar = chargeStackBar, chargeStackMax = chargeStackMax })
	end
	
	-- Icon change indicator (after charges, or after range/cooldown if no charges)
	local iconChangeIndicator = nil
	if trackIcon then
		local anchorElement = lastElement
		
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
	
	trackedSpells[spellID] = { 
		bar = bar, 
		container = container, 
		actionSlot = actionSlot,
		rangeBase = rangeBase,  -- White background for range
		rangeOverlay = rangeOverlay,  -- Colored overlay for range
		chargeStackBar = chargeStackBar,
		chargeStackMax = chargeStackMax,
		maxCharges = showChargeIndicators and maxCharges or nil,
		isChargeSpell = isChargeSpell,  -- Whether this spell uses charges (for cooldown logic)
		icon = icon,  -- Store icon reference for icon change detection
		originalTexture = texture,  -- Store original texture for comparison
		currentTexture = texture,  -- Track current texture for change detection
		iconChangeIndicator = iconChangeIndicator,  -- Icon change state indicator
	}
	spellBars[barIndex] = spellID
	gcdi_invalidate_charge_spell_list()
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
	gcdi_invalidate_charge_spell_list()
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

-- Update item charge indicators (spell charge color if has item, black if not)
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
				data.chargeOverlay:Hide()  -- Reveal spell-charge-colored bg
			else
				data.chargeOverlay:Show()  -- Black overlay
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

local function create_item_bar(itemKey, itemName, texture, itemID, slot)
	local barIndex = #itemBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	-- Check if we should show charges for this item
	local showCharges = should_show_item_charges(itemKey)

	-- Compact mode drops the icon square entirely (see create_spell_bar).
	local compact = configs.compactMode

	-- Layout: [Icon][Cooldown] or [Icon][Cooldown][Charge] (icon dropped in compact mode)
	local numSquares = 1 + (compact and 0 or 1) + (showCharges and 1 or 0)  -- cooldown + icon? + charge?
	local numGaps = ((compact and 0 or 1) + (showCharges and 1 or 0)) * 2  -- one 2px gap per boundary present
	local container, icon, clipContainer, bar = create_bar_container(main_frame, texture, compact, barSize, pad)
	container:SetSize((barSize * numSquares + numGaps) + pad * 2, barSize + pad * 2)

	-- Charge indicator (only if enabled)
	local chargeOverlay = nil
	if showCharges then
		local chargeBg = container:CreateTexture(nil, "ARTWORK")
		chargeBg:SetSize(barSize, barSize)
		chargeBg:SetPoint("LEFT", clipContainer, "RIGHT", 2, 0)
		chargeBg:SetColorTexture(SPELL_CHARGE_STACK_COLOR[1], SPELL_CHARGE_STACK_COLOR[2], SPELL_CHARGE_STACK_COLOR[3], 1)  -- Same as spell charge stack
		
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
	stackSegment = { 0.4, 0.7, 1.0 }, -- Stack StatusBar fill thresholds
}

-- Delimiter lines from options Max Stacks only (width/segment count — not derived from live stack value)
local function layout_buff_stack_separators(data)
	if not data or not data.stackBar then return end
	local maxStacks = math.max(data.stackBarMax or 1, 1)
	local barSize = configs.barHeight
	local separatorWidth = 2
	local totalWidth = maxStacks * barSize + (maxStacks - 1) * separatorWidth
	local segmentWidth = compute_separator_layout(maxStacks, totalWidth, separatorWidth)
	local sf = data.stackBar.separatorFrame
	if not sf then return end
	if not data.stackBar.separators then
		data.stackBar.separators = {}
	end
	for i = 1, maxStacks - 1 do
		if not data.stackBar.separators[i] then
			local sep = sf:CreateTexture(nil, "OVERLAY")
			sep:SetSize(separatorWidth, barSize)
			sep:SetColorTexture(0, 0, 0, 1)
			data.stackBar.separators[i] = sep
		end
		local xPos = (i * segmentWidth) + ((i - 1) * separatorWidth)
		data.stackBar.separators[i]:ClearAllPoints()
		data.stackBar.separators[i]:SetPoint("TOPLEFT", sf, "TOPLEFT", xPos, 0)
		data.stackBar.separators[i]:Show()
	end
	for i = maxStacks, #data.stackBar.separators do
		local sep = data.stackBar.separators[i]
		if sep then
			sep:Hide()
		end
	end
end

-- Live stack counts while auras are secret: prefer spell-ID APIs when they
-- return data; else CDM auraDataCached. AuraContainer/ApplicationBar cannot be
-- used from tainted code (ChangeParent / AddSecretAspect forbidden).
-- Reading .applications can throw when the aura is secret, so it needs a pcall.
-- Hoisted to file scope: as a nested closure this allocated twice per buff per tick.
local function gcdi_read_applications(auraData)
	return auraData.applications
end

local function apps_from_aura(auraData)
	if auraData == nil then return nil end
	local ok, apps = pcall(gcdi_read_applications, auraData)
	if ok and apps ~= nil then
		return apps
	end
	return nil
end

local function gcdi_try_aura_apps_for_spell(spellID, unit)
	if not spellID or not C_UnitAuras then return nil end
	if unit == "player" and C_UnitAuras.GetPlayerAuraBySpellID then
		local ok, result = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
		if ok then
			local apps = apps_from_aura(result)
			if apps ~= nil then return apps end
		end
	end
	if C_UnitAuras.GetUnitAuraBySpellID then
		local ok, result = pcall(C_UnitAuras.GetUnitAuraBySpellID, unit, spellID)
		if ok then
			local apps = apps_from_aura(result)
			if apps ~= nil then return apps end
		end
	end
	return nil
end

local function gcdi_get_buff_stack_applications(cdmFrame, catalogEntry, data)
	local unit = (cdmFrame and ((cdmFrame.GetAuraDataUnit and cdmFrame:GetAuraDataUnit()) or cdmFrame.auraDataUnit))
		or (catalogEntry and catalogEntry.isTargetDebuff and "target")
		or "player"

	-- CDM's tracked spellID (the ability/button) and its overrideTooltipSpellID can point
	-- at different spells for procs where the displayed ability isn't what actually stacks.
	-- Try both live IDs before falling back to the cached (possibly stale) CDM aura data.
	local primaryID = catalogEntry and catalogEntry.spellID
	local secondaryID = (catalogEntry and catalogEntry.tooltipSpellID) or (data and data.tooltipSpellID)

	local apps = gcdi_try_aura_apps_for_spell(primaryID, unit)
	if apps ~= nil then return apps end
	if secondaryID and secondaryID ~= primaryID then
		apps = gcdi_try_aura_apps_for_spell(secondaryID, unit)
		if apps ~= nil then return apps end
	end

	if cdmFrame then
		apps = apps_from_aura(cdmFrame.auraDataCached)
		if apps ~= nil then return apps end
	end
	return nil
end

local function gcdi_set_stack_bar_value(bar, maxS, apps)
	if not bar then return end
	maxS = math.max(maxS or 1, 1)
	bar:SetMinMaxValues(0, maxS)
	-- Do not clear-to-0 before setting: a non-secret 0 can prevent a following
	-- secret applications value from displaying (stacks looked permanently empty).
	if apps ~= nil then
		bar:SetValue(apps)
	end
end

local buffAuraUpdateGeneration = 0

local function update_buff_bar(buffID)
	if previewMode then return end  -- Skip updates in preview mode
	if not GCDI.is_buff_enabled(buffID) then return end  -- Skip disabled buffs
	-- buffID can be spellID or cooldownID depending on source
	local data = trackedBuffs[buffID]
	if not data then return end
	
	-- Use Cooldown Manager integration (like ArcUI)
	-- CDM frames: cooldownID readable; auraInstanceID may be secret (presence = active).
	local isActive = false
	
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

	-- CDM's itemFramePool reassigns frame objects to other cooldownIDs as buffs come and
	-- go; a cached reference can outlive that reassignment (RefreshData hook narrows but
	-- doesn't close the window). If the frame's own cooldownID no longer matches the one we
	-- looked it up under, it belongs to a different buff now - do not read state off it.
	if cdmFrame and cdmFrame.cooldownID and cdmFrame.cooldownID ~= cooldownID then
		cdmFrame = nil
		lookupMethod = "stale-discarded"
	end

	-- Debug: show lookup status if frame not found
	if not cdmFrame and configs.debugMode then
		local hasCatalog = catalogEntry and "yes" or "no"
		local hasReverseMap = spellIDToCooldownID[buffID] and tostring(spellIDToCooldownID[buffID]) or "no"
		local totalFrames = 0
		for _ in pairs(cdmBuffFrames) do totalFrames = totalFrames + 1 end
		debug("LOOKUP FAIL for " .. buffID .. ": catalog=" .. hasCatalog .. " reverseMap=" .. hasReverseMap .. " totalCDMFrames=" .. totalFrames)
	end
	
	-- Never call GetAuraDataByAuraInstanceID from tainted code: secret auraInstanceIDs throw.
	if cdmFrame then
		-- Presence only: secret auraInstanceID is still non-nil while the aura is up.
		local auraInstanceID = cdmFrame.auraInstanceID
		if auraInstanceID ~= nil then
			isActive = true
			data._lastAuraUnit = (cdmFrame.GetAuraDataUnit and cdmFrame:GetAuraDataUnit())
				or cdmFrame.auraDataUnit
				or "player"
		end
	end
	
	-- Manual tracking fallback (for buffs not in CDM)
	if not isActive and data.manualTracking then
		local now = GetTime()
		if data.expirationTime and data.expirationTime > now then
			isActive = true
		else
			data.expirationTime = nil
			data.stacks = 0
		end
	end
	
	-- Debug: active/inactive only — do not parse or log stack counts (may be secret)
	if configs.debugMode then
		local last = lastBuffDebugState[buffID]
		local changed = not last or last.isActive ~= isActive
		if changed then
			lastBuffDebugState[buffID] = { isActive = isActive }
			local buffName = data.name or "Unknown"
			local frameInfo = cdmFrame and ("frame:yes hasAura:" .. (isActive and "yes" or "no")) or "no frame"
			debug("Buff " .. buffName .. " (ID:" .. buffID .. ") " .. (isActive and "ACTIVE" or "INACTIVE") .. " " .. frameInfo)
		end
	end
	
	if isActive then
		-- Buff is active
		-- Recolor only on transition: this runs on the update ticker and the texture
		-- write is otherwise repeated every tick for every tracked buff.
		if not data.active then
			data.active = true
			data.activeIndicator:SetColorTexture(BUFF_COLORS.active[1], BUFF_COLORS.active[2], BUFF_COLORS.active[3], 1)
		end

		-- data.nativeStackActive: engine ApplicationBar binding owns this bar's fill
		-- (configs.useNativeStackBinding path) - don't fight it with a manual write.
		if data.stackBar and GCDI.should_show_buff_stacks(buffID) and not data.nativeStackActive then
			local apps
			if data.manualTracking and not cdmFrame then
				apps = data.stacks or 0
			else
				apps = gcdi_get_buff_stack_applications(cdmFrame, catalogEntry, data)
			end
			-- Only write when we have a value. If applications are unreadable this
			-- tick, keep the last displayed fill instead of blanking the bar.
			if apps ~= nil then
				gcdi_set_stack_bar_value(data.stackBar.bar, data.stackBarMax, apps)
			end
		end
		
		-- Duration: GetAuraDuration accepts secret IDs when tainted; pcall in case 12.1+ throws under secrecy.
		-- Arm the timer once per aura update generation. SetTimerDuration hands the
		-- bar a duration the client animates itself; re-arming every tick both restarts
		-- the ExponentialEaseOut interpolation and re-does the work for nothing.
		if data.durationBar and cdmFrame and cdmFrame.auraInstanceID ~= nil then
			if data.durationArmedGeneration ~= buffAuraUpdateGeneration then
				local unit = (cdmFrame.GetAuraDataUnit and cdmFrame:GetAuraDataUnit())
					or data._lastAuraUnit
					or cdmFrame.auraDataUnit
					or "player"
				local ok, durObj = pcall(C_UnitAuras.GetAuraDuration, unit, cdmFrame.auraInstanceID)
				if ok and durObj then
					data.durationArmedGeneration = buffAuraUpdateGeneration
					data.durationBar.bar:SetMinMaxValues(0, 1)
					data.durationBar.bar:SetTimerDuration(durObj, Enum.StatusBarInterpolation.ExponentialEaseOut, Enum.StatusBarTimerDirection.RemainingTime)
				end
			end
		end
	else
		-- Buff is not active
		if data.active ~= false then
			data.active = false
			data.activeIndicator:SetColorTexture(BUFF_COLORS.inactive[1], BUFF_COLORS.inactive[2], BUFF_COLORS.inactive[3], 1)

			if data.stackBar and GCDI.should_show_buff_stacks(buffID) then
				data.stackBar.bar:SetMinMaxValues(0, math.max(data.stackBarMax or 1, 1))
				data.stackBar.bar:SetValue(0)
			end

			-- Reset duration bar
			if data.durationBar then
				data.durationArmedGeneration = nil
				data.durationBar.bar:SetValue(0)
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

-- CDM only writes auraDataCached inside SetAuraInstanceInfo when instance/spell ID
-- changes, so stack decay on the same ID can leave a stale high applications value.
-- Force-cache the auraInfo argument whenever SetAuraInstanceInfo runs (still called
-- with fresh data from RefreshAuraInstance → GetAuraData).
local gcdi_cdm_stack_hooks_installed = false
local function gcdi_install_cdm_stack_hooks()
	if gcdi_cdm_stack_hooks_installed then return end
	local mixin = _G.CooldownViewerItemDataMixin
	if not mixin or not mixin.SetAuraInstanceInfo then return end
	gcdi_cdm_stack_hooks_installed = true
	hooksecurefunc(mixin, "SetAuraInstanceInfo", function(self, auraInfo, unit)
		-- Clear as well as set: CDM calls this with nil when the aura instance goes away,
		-- and our own fallback cache must not keep returning stale application counts
		-- after that happens (was previously only writing on a truthy auraInfo).
		self.auraDataCached = auraInfo or nil
		if auraInfo and unit ~= nil then
			self.auraDataUnit = unit
		end
	end)
	if mixin.RefreshData then
		hooksecurefunc(mixin, "RefreshData", function(self)
			if previewMode then return end
			local cdID = self.cooldownID
			if not cdID then return end
			-- CDM's itemFramePool reassigns the same frame object to different cooldownIDs
			-- as buffs come and go, and RefreshData is what (re)binds a pooled frame to its
			-- current cooldownID. Keep our map in sync here so it self-heals instead of only
			-- refreshing on the next full scan_cdm_buff_frames() (login/profile-load/manual).
			cdmBuffFrames[cdID] = self
			if not trackedBuffs[cdID] then return end
			C_Timer.After(0, function()
				if trackedBuffs[cdID] then
					update_buff_bar(cdID)
				end
			end)
		end)
	end
end

-- Defer buff bar work out of UNIT_AURA: running addon code in the same call chain as Blizzard's
-- BuffIconCooldownViewer aura handlers taints execution; CooldownViewer then errors when comparing spellID.
local buffBarsAfterAuraScheduled = false
local function schedule_update_all_buff_bars_after_aura()
	buffAuraUpdateGeneration = buffAuraUpdateGeneration + 1
	if buffBarsAfterAuraScheduled or previewMode then return end
	buffBarsAfterAuraScheduled = true
	C_Timer.After(0, function()
		buffBarsAfterAuraScheduled = false
		update_all_buff_bars()
		update_dispel_indicator()
		-- Proc icon swaps are aura-driven; keeps them instant now that the ticker
		-- only polls icons at a low rate.
		update_spell_icons()
	end)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EXPERIMENTAL: native AuraContainer/AddAuraSlot stack binding
-- ═══════════════════════════════════════════════════════════════════════════
-- Alternate to the C_UnitAuras spell-ID query path above (gcdi_get_buff_stack_
-- applications). Gated by configs.useNativeStackBinding (default OFF) so both
-- methods can be A/B tested without ripping either one out. See
-- CHANGE-TRACKER.md for exactly what this touches and how to fully remove it.
--
-- Must only be called from a clean (non-tainted) context - bar creation/
-- rebuild - never from inside UNIT_AURA. SetApplicationBar only accepts a
-- StatusBar the engine-created AuraButton itself owns (like SetDurationBar),
-- so this overlays an invisible native button's own bar exactly on top of our
-- existing stack StatusBar and hides ours once the engine confirms the bind.
local nativeStackContainers = {}  -- [unit] -> AuraContainer

-- Tears down every native AuraContainer created so far and drops our Lua
-- references to them. There is no documented/verified AddAuraSlot removal
-- API (checked warcraft.wiki.gg's AuraContainer:AddAuraSlot page and this
-- codebase for an existing precedent - neither has one), so rather than
-- fabricate an unverified removal call, this destroys the whole container
-- frame instead: Hide() + SetParent(nil) is the same teardown pattern this
-- file already uses elsewhere (clear_buff_bars) to release frames, and
-- gcdi_ensure_native_stack_container's own comment notes a container must be
-- shown+enabled to self-register aura updates, so hiding/unparenting it
-- should stop that registration along with every slot bound to it. Must be
-- called before gcdi_setup_all_native_stack_slots() creates fresh containers
-- on rebuild, otherwise the old containers' bindings would keep accumulating
-- alongside the new ones.
local function gcdi_teardown_native_stack_containers()
	for unit, container in pairs(nativeStackContainers) do
		if container then
			container:Hide()
			container:SetParent(nil)
		end
	end
	wipe(nativeStackContainers)
end

local function gcdi_ensure_native_stack_container(unit)
	local existing = nativeStackContainers[unit]
	if existing then return existing end
	if InCombatLockdown() then
		debug("native stacks: container(" .. tostring(unit) .. ") deferred, in combat")
		return nil
	end
	local ok, c = pcall(CreateFrame, "AuraContainer", nil, main_frame, "CustomAuraContainerTemplate")
	if not ok or not c then
		debug("native stacks: CreateFrame(AuraContainer) failed - " .. tostring(c))
		return nil
	end
	if c.SetUnit then c:SetUnit(unit) end
	if c.SetEnabled then c:SetEnabled(true) end
	c:SetSize(1, 1)
	c:Show()  -- must be shown+enabled to self-register aura updates
	nativeStackContainers[unit] = c
	debug("native stacks: container(" .. tostring(unit) .. ") created, AddAuraSlot=" .. tostring(c.AddAuraSlot ~= nil))
	return c
end

local function gcdi_setup_native_stack_slot(buffKey, data, catalogEntry)
	if not (data and data.stackBar and data.stackBar.bar) then return end
	local unit = (catalogEntry and catalogEntry.isTargetDebuff) and "target" or "player"
	local container = gcdi_ensure_native_stack_container(unit)
	if not container then return end
	if not container.AddAuraSlot then
		debug("native stacks: " .. tostring(buffKey) .. " - AddAuraSlot not available on this client")
		return
	end

	local ids, seen = {}, {}
	local function addID(id)
		if id and not seen[id] then seen[id] = true; ids[#ids + 1] = id end
	end
	addID(catalogEntry and catalogEntry.spellID)
	addID(catalogEntry and catalogEntry.tooltipSpellID)
	if #ids == 0 then
		debug("native stacks: " .. tostring(buffKey) .. " - no spellID/tooltipSpellID, skipped")
		return
	end

	local filter = (unit == "player") and "HELPFUL" or "HARMFUL"
	local sourceBar = data.stackBar.bar
	local maxApplications = data.stackBarMax or 1

	debug("native stacks: " .. tostring(buffKey) .. " - AddAuraSlot ids=" .. table.concat(ids, ",") .. " filter=" .. filter)
	local addOK, addErr = pcall(function()
		container:AddAuraSlot("gcdi_stack_" .. tostring(buffKey), filter, {
			candidateFilters = { includeSpellIDs = ids },
			templateNames = { "GCDINativeStackButtonTemplate" },
			initializeFrame = function(button)
				debug("native stacks: " .. tostring(buffKey) .. " - initializeFrame fired, ArcBar=" ..
					tostring(button and button.ArcBar ~= nil) .. " SetApplicationBar=" .. tostring(button and button.SetApplicationBar ~= nil))
				if not (button and button.ArcBar and button.SetApplicationBar) then return end
				-- Anchor+level the button itself over our bar: ArcBar is a child region,
				-- so it only draws while its owning button is shown/positioned.
				button:ClearAllPoints()
				button:SetAllPoints(sourceBar)
				button:SetFrameStrata(sourceBar:GetFrameStrata())
				button:SetFrameLevel((sourceBar:GetFrameLevel() or 1) + 1)
				local ab = button.ArcBar
				-- SetApplicationBar resets the widget it's given (anchors/texture/color get
				-- wiped back to defaults as it takes ownership) - bind FIRST, style AFTER,
				-- matching ArcUI's order. Doing it the other way around silently discards
				-- every style call below and leaves the bar blank/invisible.
				button:SetApplicationBar(ab, {
					maxApplications = maxApplications,
					interpolation = Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.Immediate or nil,
				})
				ab:ClearAllPoints()
				ab:SetAllPoints(sourceBar)
				local srcTex = sourceBar.GetStatusBarTexture and sourceBar:GetStatusBarTexture()
				ab:SetStatusBarTexture((srcTex and srcTex.GetTexture and srcTex:GetTexture()) or "Interface\\Buttons\\WHITE8X8")
				local r, g, b, a = sourceBar:GetStatusBarColor()
				ab:SetStatusBarColor(r, g, b, a or 1)
				if sourceBar.GetOrientation and ab.SetOrientation then ab:SetOrientation(sourceBar:GetOrientation()) end
				if sourceBar.GetReverseFill and ab.SetReverseFill then ab:SetReverseFill(sourceBar:GetReverseFill()) end
				ab:Show()
				-- Engine-driven bar is now the real fill; stop writing to and hide the classic one.
				data.nativeStackActive = true
				sourceBar:Hide()
				-- Note: do NOT read state back off ab/button here (GetSize, IsShown,
				-- GetMinMaxValues, etc.) - once the engine owns this widget those reads can
				-- come back as secret/opaque values and poison the whole debug string into
				-- "<SECRET>" with no error. Only report what WE told it to be.
				debug("native stacks: " .. tostring(buffKey) .. " - bound, classic bar hidden, maxApplications=" .. tostring(maxApplications))
			end,
		})
	end)
	if not addOK then
		debug("native stacks: " .. tostring(buffKey) .. " - AddAuraSlot pcall failed: " .. tostring(addErr))
		return
	end
	-- Without this, the slot only binds on the NEXT aura change event - a
	-- buff already active when the slot registers (the common case: toggling
	-- the option, or rebuilding bars mid-buff) would never call initializeFrame
	-- and the bar would silently show nothing until the buff refreshes.
	if container.UpdateAllAuras then
		local ok, err = pcall(container.UpdateAllAuras, container)
		if not ok then
			debug("native stacks: " .. tostring(buffKey) .. " - UpdateAllAuras failed: " .. tostring(err))
		end
	end
end

local function gcdi_setup_all_native_stack_slots()
	if not configs.useNativeStackBinding then return end
	for buffKey, data in pairs(trackedBuffs) do
		gcdi_setup_native_stack_slot(buffKey, data, GCDI.buffCatalog[buffKey])
	end
end

local function create_buff_bar(buffKey, spellName, texture, tooltipSpellID)
	local barIndex = #buffBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	-- Check if we should show stacks for this buff
	local showStacks = GCDI.should_show_buff_stacks(buffKey)
	-- Max segments + bar width: options only. Live stack count is never used to size the bar.
	local maxStacks = GCDI.get_buff_max_stacks_display(buffKey)

	-- Check if we should show duration bar for this buff
	local showDurationBar = GCDI.should_show_duration_bar(buffKey)

	-- Compact mode drops the icon square entirely (see create_spell_bar).
	local compact = configs.compactMode

	-- Layout: [Icon?][Active Indicator][Stack bar segments?][Duration Bar?] (icon dropped in compact mode)
	local stackWidth = showStacks and maxStacks > 0 and (maxStacks * barSize + (maxStacks - 1) * 2) or 0
	local extraGap = showStacks and 2 or 0
	local durationBarWidth = showDurationBar and (barSize + 2) or 0  -- 8x8 clipped indicator
	local iconWidth = compact and 0 or (barSize + 2)  -- icon square + gap before active indicator (0 in compact mode)
	local containerWidth = barSize + iconWidth + stackWidth + extraGap + durationBarWidth + pad * 2

	local container, icon, clipContainer, bar = create_bar_container(main_frame, texture, compact, barSize, pad)
	container:SetSize(containerWidth, barSize + pad * 2)

	-- Active indicator (shows if buff is active)
	local activeIndicator = container:CreateTexture(nil, "ARTWORK")
	activeIndicator:SetSize(barSize, barSize)
	if compact then
		activeIndicator:SetPoint("LEFT", pad, 0)
	else
		activeIndicator:SetPoint("LEFT", icon, "RIGHT", 2, 0)
	end
	activeIndicator:SetColorTexture(BUFF_COLORS.inactive[1], BUFF_COLORS.inactive[2], BUFF_COLORS.inactive[3], 1)
	
	-- Stack bar: StatusBar fill from applications (spell-ID API or CDM cache).
	local stackBar = nil
	local stackBarMax = nil
	local lastElement = activeIndicator

	if showStacks and maxStacks > 0 then
		stackBarMax = maxStacks
		local stackArea, csb = create_stack_separator_area(container, activeIndicator, maxStacks, barSize, BUFF_COLORS.stackSegment, 0)
		for i = 1, 9 do
			local sep = csb.separatorFrame:CreateTexture(nil, "OVERLAY")
			sep:SetSize(2, barSize)
			sep:SetColorTexture(0, 0, 0, 1)
			sep:Hide()
			csb.separators[i] = sep
		end
		stackBar = csb
		lastElement = stackArea
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
		init_status_bar_texture(bar)
		bar:SetStatusBarColor(0, 0, 0, 1)
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(1)
		
		durationBar = {
			clipFrame = clipFrame,
			bar = bar,
		}
	end
	
	local buffData = {
		container = container,
		activeIndicator = activeIndicator,
		stackBar = stackBar,
		stackBarMax = stackBarMax,
		durationBar = durationBar,
		active = false,
		name = spellName,
		icon = texture,
		tooltipSpellID = tooltipSpellID,  -- for tooltip (overrideTooltipSpellID; matches CDM)
	}
	trackedBuffs[buffKey] = buffData
	if stackBar then
		layout_buff_stack_separators(buffData)
	end
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
	gcdi_teardown_native_stack_containers()
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
				print(GCDI_PREFIX .. msg)
			end
		end,
	})
end

-- Wrapper functions for backward compatibility
local function detect_native_range_for_spells()
	LibRange:DetectNativeRangeForSpells()
end

local function update_range_indicators()
	LibRange:UpdateRangeIndicators()
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
	init_status_bar_texture(bar)
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

-- Heal absorb: Retail calculator + StatusBar (oUF/ElvUI-style) so values can stay secret-safe on SetValue
local function setup_health_heal_absorb_bar(data)
	if not CreateUnitHealPredictionCalculator or not UnitGetDetailedHealPrediction then
		return
	end
	local healthBar = data.bar
	healthBar:SetClipsChildren(true)
	local absorbBar = CreateFrame("StatusBar", nil, healthBar)
	absorbBar:SetFrameLevel(healthBar:GetFrameLevel() + 3)
	init_status_bar_texture(absorbBar)
	absorbBar:SetStatusBarColor(0, 0, 0, 1)
	absorbBar:SetMinMaxValues(0, 100)
	absorbBar:SetValue(0)
	absorbBar:SetReverseFill(true)
	absorbBar:Hide()
	data.healAbsorbBar = absorbBar
	data.healPredictionValues = CreateUnitHealPredictionCalculator()
	local calc = data.healPredictionValues
	calc:SetDamageAbsorbClampMode(Enum.UnitDamageAbsorbClampMode.MissingHealth)
	calc:SetHealAbsorbClampMode(Enum.UnitHealAbsorbClampMode.CurrentHealth)
	calc:SetIncomingHealClampMode(Enum.UnitIncomingHealClampMode.MissingHealth)
	calc:SetHealAbsorbMode(Enum.UnitHealAbsorbMode.ReducedByIncomingHeals)
	calc:SetIncomingHealOverflowPercent(1.05)
end

-- Shared layout for heal absorb StatusBar (maxHealth / absorb may be secret when from APIs)
local function layout_heal_absorb_bar(data, maxHealth, absorbAmount)
	local absorbBar = data.healAbsorbBar
	local bar = data.bar
	if not absorbBar or not maxHealth or maxHealth <= 0 then
		return false
	end
	local hbTex = bar:GetStatusBarTexture()
	if not hbTex then
		return false
	end
	local w, h = bar:GetSize()
	if not w or w <= 0 or not h or h <= 0 then
		return false
	end
	absorbBar:SetMinMaxValues(0, maxHealth)
	absorbBar:SetValue(absorbAmount)
	absorbBar:ClearAllPoints()
	absorbBar:SetSize(w, h)
	absorbBar:SetPoint("RIGHT", hbTex, "RIGHT", 0, 0)
	absorbBar:SetPoint("TOP", bar, "TOP", 0, 0)
	absorbBar:Show()
	return true
end

local function update_health_bar()
	if previewMode then return end  -- Skip updates in preview mode
	if not resourceBars.health then return end
	local data = resourceBars.health
	local bar = data.bar
	local rawMax = UnitHealthMax("player")
	local max = tonumber(rawMax) or 100000
	if max > 0 then
		bar:SetMinMaxValues(0, max)
		bar:SetValue(UnitHealth("player"))
	end
	local absorbBar = data.healAbsorbBar
	local calc = data.healPredictionValues
	if absorbBar and calc and max > 0 then
		UnitGetDetailedHealPrediction("player", "player", calc)
		local healAbsorbAmount = select(1, calc:GetHealAbsorbs())
		if not layout_heal_absorb_bar(data, max, healAbsorbAmount) then
			absorbBar:Hide()
		end
	end
end

local function create_simple_resource_updater(key, powerType)
	return function()
		if previewMode then return end
		if not resourceBars[key] then return end
		local bar = resourceBars[key].bar
		local rawMax = UnitPowerMax("player", powerType)
		local max = tonumber(rawMax) or 100
		bar:SetMinMaxValues(0, math.max(max, 1))
		bar:SetValue(UnitPower("player", powerType))
	end
end

local update_rage_bar = create_simple_resource_updater("rage", Enum.PowerType.Rage)
local update_energy_bar = create_simple_resource_updater("energy", Enum.PowerType.Energy)

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

	-- Separator geometry depends only on max; skip the relayout when it is unchanged.
	if data.lastSeparatorMax == max then return end
	data.lastSeparatorMax = max

	-- Fixed total width of 200px, calculate segment width based on max
	local totalWidth = 200
	local separatorWidth = 2
	local segmentWidth = compute_separator_layout(max, totalWidth, separatorWidth)
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

local update_mana_bar = create_simple_resource_updater("mana", Enum.PowerType.Mana)
local update_focus_bar = create_simple_resource_updater("focus", Enum.PowerType.Focus)
local update_runic_power_bar = create_simple_resource_updater("runicPower", Enum.PowerType.RunicPower)

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

	-- Separator geometry depends only on max; skip the relayout when it is unchanged.
	if data.lastSeparatorMax == max then return end
	data.lastSeparatorMax = max

	-- Update separators based on max
	if not data.separators then
		data.separators = {}
	end

	-- Fixed total width of 200px, calculate segment width based on max
	local totalWidth = 200
	local separatorWidth = 2
	local segmentWidth = compute_separator_layout(max, totalWidth, separatorWidth)
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

	-- Separator geometry depends only on max, which changes rarely (talents/spec).
	-- Re-anchoring every pip on every power tick was the bulk of this function.
	if data.lastSeparatorMax == max then return end
	data.lastSeparatorMax = max

	-- Update width and separators like combo points
	local totalWidth = 200
	local separatorWidth = 2
	local segmentWidth = compute_separator_layout(max, totalWidth, separatorWidth)
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

local update_insanity_bar = create_simple_resource_updater("insanity", Enum.PowerType.Insanity)
local update_maelstrom_bar = create_simple_resource_updater("maelstrom", Enum.PowerType.Maelstrom)
local update_fury_bar = create_simple_resource_updater("fury", Enum.PowerType.Fury)
local update_pain_bar = create_simple_resource_updater("pain", Enum.PowerType.Pain)
local update_lunar_power_bar = create_simple_resource_updater("astralPower", Enum.PowerType.LunarPower)

local function update_essence_bar()
	update_charge_bar(resourceBars.essence, Enum.PowerType.Essence, 5)
end

-- Brewmaster only; max = max health (same scale as default UI). Values may be secret — pass through to the bar only.
-- Class never changes and spec changes fire PLAYER_SPECIALIZATION_CHANGED, so the
-- lookup is cached: this runs on the update ticker and every non-Brewmaster was
-- paying for UnitClass + GetSpecialization every tick just to bail out.
local staggerIsBrewmaster = nil

local function gcdi_refresh_stagger_spec()
	local _, class = UnitClass("player")
	if class ~= "MONK" then
		staggerIsBrewmaster = false
		return
	end
	staggerIsBrewmaster = (C_SpecializationInfo.GetSpecialization() == 1)
end

local function update_stagger_bar()
	if previewMode then return end
	if not resourceBars.stagger then return end
	if staggerIsBrewmaster == nil then
		gcdi_refresh_stagger_spec()
	end
	local bar = resourceBars.stagger.bar
	if not staggerIsBrewmaster then
		-- Only write once on transition; the bar is already parked at 0 afterwards.
		if resourceBars.stagger.staggerParked then return end
		resourceBars.stagger.staggerParked = true
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(0)
		return
	end
	resourceBars.stagger.staggerParked = nil
	bar:SetMinMaxValues(0, UnitHealthMax("player"))
	bar:SetValue(UnitStagger("player"))
end

-- Resource key -> updater, so the sweep can skip bars the user has disabled instead
-- of hitting UnitPowerMax/UnitPower and relaying separators for all 19 every time.
local RESOURCE_UPDATERS = {
	{ "health", update_health_bar },
	{ "mana", update_mana_bar },
	{ "rage", update_rage_bar },
	{ "energy", update_energy_bar },
	{ "focus", update_focus_bar },
	{ "runicPower", update_runic_power_bar },
	{ "runes", update_runes_bar },
	{ "comboPoints", update_combo_points_bar },
	{ "soulShards", update_soul_shards_bar },
	{ "holyPower", update_holy_power_bar },
	{ "chi", update_chi_bar },
	{ "arcaneCharges", update_arcane_charges_bar },
	{ "insanity", update_insanity_bar },
	{ "maelstrom", update_maelstrom_bar },
	{ "fury", update_fury_bar },
	{ "pain", update_pain_bar },
	{ "astralPower", update_lunar_power_bar },
	{ "essence", update_essence_bar },
	{ "stagger", update_stagger_bar },
}

local function gcdi_is_resource_enabled(key)
	if not settings or not settings.resourceSettings then return true end
	local enabled = settings.resourceSettings[key]
	if enabled == nil then return true end  -- Default to enabled
	return enabled and true or false
end

GCDI.is_resource_enabled = gcdi_is_resource_enabled

local function update_all_resources()
	for i = 1, #RESOURCE_UPDATERS do
		local entry = RESOURCE_UPDATERS[i]
		if gcdi_is_resource_enabled(entry[1]) then
			entry[2]()
		end
	end
end

local function update_stance_indicator()
	if previewMode then return end  -- Skip updates in preview mode
	if not main_frame.stanceIndicator then return end
	
	local formIndex = GetShapeshiftForm() or 0
	local color = FORM_COLORS[formIndex] or FORM_COLORS.default
	main_frame.stanceIndicator:SetColorTexture(color[1], color[2], color[3], 1)
end

-- Midnight: UnitAffectingCombat may return a secret boolean — do not branch on it raw.
local function gcdi_safe_unit_affecting_combat(unit)
	local v = UnitAffectingCombat(unit)
	if v == nil then
		return false
	end
	if issecretvalue and issecretvalue(v) then
		return false
	end
	return v and true or false
end

-- Midnight+: Unit* APIs may return secret booleans/numbers — never use them in if/and/not; coerce first.
-- File scope, not nested: update_aggro_indicator runs off UNIT_THREAT_SITUATION_UPDATE
-- and UNIT_TARGET, so nesting these allocated two closures per threat event.
local function aggro_safe_bool(v, default)
	if v == nil then
		return default
	end
	if issecretvalue and issecretvalue(v) then
		return default
	end
	return v and true or false
end

local function aggro_safe_tonumber(v)
	if v == nil then
		return nil
	end
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return tonumber(v)
end

local function update_aggro_indicator()
	if previewMode then return end  -- Skip updates in preview mode
	if not main_frame.aggrobar then return end

	-- Check if target exists and is attackable (hostile). Don't require combat—pre-pull we show grey.
	local exists = UnitExists("target")
	local canAttack = UnitCanAttack("player", "target")
	local validTarget = aggro_safe_bool(exists, false) and aggro_safe_bool(canAttack, false)
	
	if not validTarget then
		-- No target or friendly target = white
		main_frame.aggrobar:SetStatusBarColor(1, 1, 1)
		return
	end
	
	-- Have target: grey (no aggro) or orange (has aggro). Only show grey when target is in combat and we don't have aggro.
	local hasAttackableTarget = aggro_safe_bool(canAttack, false)
	local targetInCombat = aggro_safe_bool(UnitAffectingCombat("target"), false)
	local threatNum = aggro_safe_tonumber(UnitThreatSituation("player", "target"))
	local hasAggro = threatNum ~= nil and threatNum >= 2
	if not hasAggro then
		local ttExists = UnitExists("targettarget")
		if aggro_safe_bool(ttExists, false) then
			local isSelf = UnitIsUnit("targettarget", "player")
			if aggro_safe_bool(isSelf, false) then
				hasAggro = true
			end
		end
	end
	
	if hasAggro then
		main_frame.aggrobar:SetStatusBarColor(1, 0.5, 0)  -- Orange = has aggro
	else
		-- Grey covers both "in combat, no aggro" and "target not attackable / not in combat"
		main_frame.aggrobar:SetStatusBarColor(0.3, 0.3, 0.3)
	end
end

-- Count nearby hostile mobs within range (nameplates). LibRangeCheck when enabled; else proxy spell per bracket.
local function count_nearby_mobs(range)
	local count = 0
	if not settings or not range or range <= 0 then return 0 end

	local gcdSettings = settings.gcdSettings or {}
	local useLRC = gcdSettings.useLibRangeCheck == true
	local inCombat = InCombatLockdown()

	local nameplates = C_NamePlate and C_NamePlate.GetNamePlates and C_NamePlate.GetNamePlates()
	if not nameplates or type(nameplates) ~= "table" then return 0 end

	local proxySpellID = settings.rangeProxySpells and settings.rangeProxySpells[range]
	-- Invariant across the nameplate loop; was re-checked for every unit.
	local proxyUsable = (type(proxySpellID) == "number") and C_Spell and C_Spell.SpellHasRange(proxySpellID)

	for _, nameplate in pairs(nameplates) do
		if type(nameplate) == "table" then
			local unit = (type(nameplate.GetUnit) == "function" and nameplate:GetUnit()) or nameplate.unitToken or nameplate.namePlateUnitToken
			if unit and UnitExists(unit) then
				if UnitCanAttack("player", unit) and not UnitIsDead(unit) then
					local inRange = nil
					if useLRC then
						inRange = LibRange:IsUnitInRangeYardsLRC(unit, range, inCombat)
					end
					if inRange == nil and proxyUsable then
						inRange = C_Spell.IsSpellInRange(proxySpellID, unit)
					end
					if inRange == true then
						count = count + 1
					end
				end
			end
		end
	end
	return count
end

local function update_mob_count_indicator()
	if previewMode then return end
	if not main_frame or not main_frame.mobcountbar then return end
	local gcdSettings = settings and settings.gcdSettings or {}
	local range = gcdSettings.mobCountRange or 8
	local threshold = gcdSettings.mobCountThreshold or 3
	local mobCount = count_nearby_mobs(range)
	local aboveThreshold = mobCount >= threshold
	-- Polled on the update ticker; only repaint on transition.
	if main_frame.mobCountState == aboveThreshold then return end
	main_frame.mobCountState = aboveThreshold
	if aboveThreshold then
		main_frame.mobcountbar:SetStatusBarColor(1, 1, 1)  -- White = at or above threshold
	else
		main_frame.mobcountbar:SetStatusBarColor(0, 0, 0)  -- Black = below threshold
	end
end

-- Player debuff the active character can dispel. Purple = need dispel; grey = idle.
-- Dispel indicator purple (0x9933CC → 0.6, 0.2, 0.8).
--
-- Midnight / restricted auras: canActivePlayerDispel on AuraData may be unusable (secret). Matches Decursive’s
-- C_UnitAuras.GetDebuffDataByIndex(unit, i, "RAID_PLAYER_DISPELLABLE") (see ../Decursive/Decursive.lua scanning block).
local DISPEL_DEBUFF_FILTER = "RAID_PLAYER_DISPELLABLE"
local DISPEL_DEBUFF_SCAN_MAX = 40

local function gcdi_safe_can_dispel_flag(v)
	if v == nil then
		return false
	end
	if issecretvalue and issecretvalue(v) then
		return false
	end
	return v and true or false
end

-- Scan bodies hoisted to file scope; as nested closures these were reallocated on
-- every poll (three per call, counting the ForEachAura callback).
local function gcdi_scan_dispellable_by_index()
	for i = 1, DISPEL_DEBUFF_SCAN_MAX do
		local aura = C_UnitAuras.GetDebuffDataByIndex("player", i, DISPEL_DEBUFF_FILTER)
		if aura then
			return true
		end
	end
	return false
end

local gcdi_dispel_scan_hit = false

local function gcdi_dispel_aura_visitor(auraData)
	if auraData and gcdi_safe_can_dispel_flag(auraData.canActivePlayerDispel) then
		gcdi_dispel_scan_hit = true
		return true
	end
end

local function gcdi_scan_dispellable_foreach()
	gcdi_dispel_scan_hit = false
	AuraUtil.ForEachAura("player", "HARMFUL", DISPEL_DEBUFF_SCAN_MAX, gcdi_dispel_aura_visitor, true)
	return gcdi_dispel_scan_hit
end

local function player_has_dispellable_debuff_on_self()
	-- 12.1+: GetDebuffDataByIndex / GetAuraSlots / ForEachAura Lua-error when auras are secret
	-- while tainted. No legal self-dispel scan — leave indicator idle.
	if GCDI_AURAS_INSTANCE_API_UNSAFE then
		return false
	end
	if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
		local ok, has = pcall(gcdi_scan_dispellable_by_index)
		if ok and has then
			return true
		end
	end
	-- Fallback: full HARMFUL scan + canActivePlayerDispel (older clients / if API fails)
	if AuraUtil and AuraUtil.ForEachAura then
		local ok, found = pcall(gcdi_scan_dispellable_foreach)
		if ok and found then
			return true
		end
	end
	return false
end

update_dispel_indicator = function()
	if previewMode then return end
	if not main_frame or not main_frame.dispelbar then return end

	local hasDispel = player_has_dispellable_debuff_on_self()

	-- Driven by UNIT_AURA plus a low-rate safety poll; only repaint on transition.
	if main_frame.dispelState == hasDispel then return end
	main_frame.dispelState = hasDispel

	if hasDispel then
		main_frame.dispelbar:SetStatusBarColor(0.6, 0.2, 0.8)
	else
		main_frame.dispelbar:SetStatusBarColor(0.28, 0.28, 0.32)
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
	
	local isResourceEnabled = gcdi_is_resource_enabled

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
		local showDispel = gcdSettings.showDispel ~= false
		if main_frame.gcdRowSep6 then
			main_frame.gcdRowSep6:SetShown(showDispel)
		end
		if main_frame.dispelbar then
			main_frame.dispelbar:SetShown(showDispel)
		end
		-- Refresh mob count bar so AOE detection is correct as soon as the row is visible
		update_mob_count_indicator()
		update_dispel_indicator()
		
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
		"insanity", "maelstrom", "fury", "pain", "astralPower", "essence",
		"stagger",
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
	
	local columnsEndY
	local finalY
	local maxWidth = resourceBarWidth  -- Start with resource bar width as baseline

	if configs.compactMode then
		-- COMPACT MODE: flow boxes left-to-right, wrapping once a row would
		-- exceed the resource-bar width (200px), with a fixed 2px gap between
		-- every adjacent box (both within a row and between wrapped rows).
		-- Spells, items, and buffs are ONE continuous sequence here (buffs do
		-- not start a new section) - icon squares are also dropped from each
		-- box in this mode (see create_spell_bar/create_item_bar/
		-- create_buff_bar). See CHANGE-TRACKER.md.
		local compactGap = 2
		local compactRowMaxWidth = 200

		local allEntries = {}
		for _, entry in ipairs(allSpellsAndItems) do
			table.insert(allEntries, entry.container)
		end
		local orderedBuffs = get_ordered_buffs()
		for _, spellID in ipairs(orderedBuffs) do
			local data = trackedBuffs[spellID]
			if data and data.container then
				table.insert(allEntries, data.container)
			end
		end

		local rowX, rowY, rowWidthUsed = 0, yOffset, 0
		for _, container in ipairs(allEntries) do
			local w = container:GetWidth()
			if rowX > 0 and rowX + w > compactRowMaxWidth then
				maxWidth = math.max(maxWidth, rowWidthUsed)
				rowX = 0
				rowY = rowY - spellBarHeight - compactGap
			end
			container:ClearAllPoints()
			container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", rowX, rowY)
			container:Show()
			rowX = rowX + w + compactGap
			rowWidthUsed = rowX - compactGap
		end
		if #allEntries > 0 then
			maxWidth = math.max(maxWidth, rowWidthUsed)
			finalY = rowY - spellBarHeight
		else
			finalY = yOffset
		end
	else
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
		columnsEndY = math.min(col1Y, col2Y, col3Y)

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
		finalY = math.min(buffCol1Y, buffCol2Y, buffCol3Y)

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
	end

	-- Store bounds (height is positive, representing total vertical space used)
	layoutBounds.width = maxWidth
	layoutBounds.height = -finalY  -- Convert negative offset to positive height
	
	update_all_resources()
	update_stance_indicator()
end

GCDI.reposition_all = reposition_all

-- Debug/cross-check export: dumps every currently-shown bar's position
-- (relative to main_frame.anchor, same coordinate space reposition_all()
-- positions everything in) and size, so it can be diffed against what the
-- companion script computes for the same spell/item/buff list. Not for
-- general use - purely a diagnostic added to track down compact-mode
-- companion-script/addon drift.
local function export_bar_positions()
	local lines = {}
	table.insert(lines, "GCDIndicator bar position export")
	table.insert(lines, string.format(
		"compactMode=%s size=%d barHeight=%d bgPadding=%d barSpacing=%d",
		tostring(configs.compactMode), configs.size, configs.barHeight, configs.bgPadding, configs.barSpacing))
	table.insert(lines, "kind\tname\tx\ty\tw\th")

	local anchor = main_frame.anchor
	local anchorLeft = anchor and anchor:GetLeft() or 0
	local anchorTop = anchor and anchor:GetTop() or 0

	local function add_line(kind, name, frame)
		if not frame or not frame:IsShown() then return end
		local left, top = frame:GetLeft(), frame:GetTop()
		if not left or not top then return end
		local w, h = frame:GetSize()
		table.insert(lines, string.format("%s\t%s\tx=%.1f\ty=%.1f\tw=%.1f\th=%.1f",
			kind, name, left - anchorLeft, anchorTop - top, w, h))
	end

	if main_frame.gcdcontainer then
		add_line("gcdrow", "gcdcontainer", main_frame.gcdcontainer)
	end

	if resourceBars.health then
		add_line("resource", "health", resourceBars.health.container)
	end
	local otherResources = {
		"mana", "rage", "energy", "focus", "runicPower", "runes",
		"comboPoints", "soulShards", "holyPower", "chi", "arcaneCharges",
		"insanity", "maelstrom", "fury", "pain", "astralPower", "essence",
		"stagger",
	}
	for _, name in ipairs(otherResources) do
		if resourceBars[name] then
			add_line("resource", name, resourceBars[name].container)
		end
	end

	for _, spellID in ipairs(get_ordered_spells()) do
		local data = trackedSpells[spellID]
		if data then
			local catalogEntry = GCDI.spellCatalog[spellID]
			add_line("spell", (catalogEntry and catalogEntry.name) or tostring(spellID), data.container)
		end
	end

	for _, itemKey in ipairs(GCDI.get_ordered_items()) do
		local data = trackedItems[itemKey]
		if data then
			local catalogEntry = GCDI.itemCatalog[itemKey]
			add_line("item", (catalogEntry and catalogEntry.name) or tostring(itemKey), data.container)
		end
	end

	for _, buffKey in ipairs(get_ordered_buffs()) do
		local data = trackedBuffs[buffKey]
		if data then
			local catalogEntry = GCDI.buffCatalog[buffKey]
			add_line("buff", (catalogEntry and catalogEntry.name) or tostring(buffKey), data.container)
		end
	end

	return table.concat(lines, "\n")
end
GCDI.export_bar_positions = export_bar_positions

local function companion_string_escape(s)
	return (tostring(s or ""):gsub('"', '\\"'))
end

-- Companion-script names are squished CamelCase with no punctuation (e.g.
-- "SunderingRoar", "FrenziedRegen"), and buffs are suffixed "Buff" to avoid
-- colliding with a same-named spell's cooldown entry (e.g. "IronfurBuff" vs.
-- the "Ironfur" spell, both of which would otherwise share the bare name
-- "Ironfur" in the companion script's per-name pixel-state tracking). The
-- addon's catalog names are full WoW spell/item names with spaces and
-- punctuation ("Sundering Roar", "Incarnation: Guardian of Ursoc"), so
-- normalize them to match before exporting.
local function companion_normalize_name(name, isBuff)
	local clean = tostring(name or ""):gsub("[^%w]", "")
	if isBuff and not clean:find("Buff") then
		clean = clean .. "Buff"
	end
	return clean
end

-- Resource bars: name -> live power-type lookup, reusing the exact
-- Enum.PowerType each resource's own update function already uses elsewhere
-- in this file (search "Enum.PowerType." to cross-check), so this doesn't
-- risk misremembering an enum ID. "stagger" (Brewmaster Monk) has no power
-- type at all - it's computed as a % of max health - so it's left out here.
local GCDI_RESOURCE_POWER_TYPE = {
	rage = Enum.PowerType.Rage,
	energy = Enum.PowerType.Energy,
	mana = Enum.PowerType.Mana,
	focus = Enum.PowerType.Focus,
	runicPower = Enum.PowerType.RunicPower,
	insanity = Enum.PowerType.Insanity,
	maelstrom = Enum.PowerType.Maelstrom,
	fury = Enum.PowerType.Fury,
	pain = Enum.PowerType.Pain,
	astralPower = Enum.PowerType.LunarPower,
	comboPoints = Enum.PowerType.ComboPoints,
	runes = Enum.PowerType.Runes,
	soulShards = Enum.PowerType.SoulShards,
	holyPower = Enum.PowerType.HolyPower,
	chi = Enum.PowerType.Chi,
	arcaneCharges = Enum.PowerType.ArcaneCharges,
	essence = Enum.PowerType.Essence,
}
-- Resources the companion script's resource-type map reads as discrete
-- segments/pips (config shape { name, charges }) rather than a continuous
-- fill (config shape { name, min, max }) - mirrors that map's "type" field.
local GCDI_RESOURCE_IS_CHARGES = {
	runes = true, comboPoints = true, soulShards = true, holyPower = true,
	chi = true, arcaneCharges = true, essence = true,
}
-- Same fixed display order reposition_all() uses (health first, then this list).
local GCDI_RESOURCE_ORDER = {
	"mana", "rage", "energy", "focus", "runicPower", "runes",
	"comboPoints", "soulShards", "holyPower", "chi", "arcaneCharges",
	"insanity", "maelstrom", "fury", "pain", "astralPower", "essence",
	"stagger",
}

-- Workflow export: generates companion-script array-literal text matching
-- the companion script's spell/buff/resource list shape, from the live
-- addon state - paste over the companion script's config to keep it in
-- sync instead of hand-editing every time spells, items, buffs, resources,
-- or their order change. Order matches get_ordered_spells()/
-- GCDI.get_ordered_items()/get_ordered_buffs() - the same order
-- reposition_all() uses, so this also fixes the class of order-mismatch bug
-- documented in CHANGE-TRACKER.md's compact-mode entry.
--
-- What this CANNOT derive (the addon has no concept of these - fill in by
-- hand after pasting):
--   - key: the physical keybind the rotation script presses.
--   - chargeColor/chargeBlackThreshold per-item overrides (e.g. dim charge
--     pips on some potions/trinkets) - pure companion-script-side
--     pixel-brightness tuning with no addon-side equivalent at all. If your
--     existing config has these on an item, copy them back in after pasting
--     or you'll lose that item's charge detection.
--   - Global bar / stance list (GetXGlobalBarConfig) - not exported. It's
--     static per class/spec (doesn't change with your settings), so
--     there's little to keep in sync there.
-- What this derives from a user-set per-spell/item flag ("Off GCD" checkbox
-- on the Spells/Items tabs, settings.spellSettings[spellID].offGCD /
-- settings.itemSettings[itemKey].offGCD - defaults false/on-GCD, since
-- off-GCD is rare): hasGCD (spells and items) - emitted as `hasGCD: false`
-- only for entries flagged off-GCD; omitted otherwise (the companion
-- script's own default is true). There's no reliable static WoW API for
-- "does this spell trigger the GCD" - the only real detection is
-- retroactive (cast it, then check if the GCD spell's cooldown started at
-- the same moment), which isn't useful for a one-shot config generator -
-- so this is game-knowledge you flag by hand once, not something
-- auto-detected.
-- What this infers, not confirms (see CHANGE-TRACKER.md - the mapping
-- between should_track_spell_icon()/should_show_duration_bar() and the
-- companion script's hasProc/hasPandemic fields is a structural guess based
-- on box ordering, not verified in-game):
--   - hasProc (spells): from should_track_spell_icon(spellID).
--   - hasPandemic (buffs): from GCDI.should_show_duration_bar(buffKey).
-- What's a live snapshot, not a stable config value: resource max/charge
-- counts below reflect UnitPowerMax() at the moment you export - some (rage
-- especially, via talents like Vengeance) can change with talents/buffs, so
-- treat these as a starting point to verify, not gospel.
-- Name normalization (see companion_normalize_name): the addon's catalog names
-- are full WoW names with spaces/punctuation ("Sundering Roar"); exported
-- names strip everything but letters/digits to match the companion
-- script's squished-CamelCase convention, and buffs get a "Buff" suffix
-- (if not already present) so a buff never collides with a same-named
-- spell's entry (e.g. "IronfurBuff" vs. the "Ironfur" spell).
-- variant: "Primary" or "Secondary" - which spec slot this dump represents
-- (the companion script's dual-spec structure: GetPrimaryXList() vs.
-- GetSecondaryXList()/GetSecondaryResourceConfig()). The addon only ever
-- reflects whatever spec/build is currently active in-game, so the caller
-- must say which slot that corresponds to; defaults to "Primary" if omitted
-- or unrecognized.
local function export_companion_config(variant)
	if variant ~= "Primary" and variant ~= "Secondary" then
		variant = "Primary"
	end
	local lines = {}
	table.insert(lines, "; Generated by GCDIndicator /gcdopt exportrotation (" .. variant .. ") - paste over Get" .. variant .. "SpellList()/Get" .. variant .. "BuffList()/Get" .. variant .. "ResourceConfig() in your companion script.")
	table.insert(lines, "; key/chargeColor/chargeBlackThreshold are NOT derived from the addon - fill them in by hand.")
	table.insert(lines, "; hasGCD: false is only emitted for spells/items flagged 'Off GCD' in the Spells/Items tabs - defaults true (on-GCD) otherwise.")
	table.insert(lines, "; Names are stripped of spaces/punctuation to match your companion script's naming style; buffs get a 'Buff' suffix so they don't collide with a same-named spell.")
	table.insert(lines, "; hasProc/hasPandemic are inferred (trackIcon/duration-bar), not confirmed - see CHANGE-TRACKER.md.")
	table.insert(lines, "; Resource max/charges values are a live snapshot (e.g. rage max can change with talents) - verify, don't assume stable.")
	table.insert(lines, "")
	table.insert(lines, "Get" .. variant .. "SpellList() {")
	table.insert(lines, "\treturn [")

	for _, spellID in ipairs(get_ordered_spells()) do
		local catalogEntry = GCDI.spellCatalog[spellID]
		if catalogEntry and GCDI.is_spell_enabled(spellID) then
			local actionSlot = GCDI.get_action_slot_for_spell(spellID)
			local chargeInfo = gcdi_get_spell_charge_info(spellID, actionSlot)
			local maxCharges = gcdi_effective_max_charge_pips(spellID, chargeInfo)
			local isSelfCast = is_spell_self_cast(spellID)
			local trackIcon = should_track_spell_icon(spellID)

			local parts = {
				string.format('name: "%s"', companion_string_escape(companion_normalize_name(catalogEntry.name, false))),
				'key: "TODO"',
				"hasRange: " .. tostring(not isSelfCast),
			}
			if maxCharges > 1 then
				table.insert(parts, "hasCharges: true")
				table.insert(parts, "maxCharges: " .. maxCharges)
			end
			if trackIcon then
				table.insert(parts, "hasProc: true")
			end
			if is_spell_off_gcd(spellID) then
				table.insert(parts, "hasGCD: false")
			end
			table.insert(lines, "\t\t{ " .. table.concat(parts, ", ") .. " },")
		end
	end

	for _, itemKey in ipairs(GCDI.get_ordered_items()) do
		local catalogEntry = GCDI.itemCatalog[itemKey]
		if catalogEntry then
			local parts = {
				string.format('name: "%s"', companion_string_escape(companion_normalize_name(catalogEntry.name, false))),
				'key: "TODO"',
				"hasRange: false",
				"isItem: true",
			}
			if should_show_item_charges(itemKey) then
				table.insert(parts, "hasCharges: true")
				table.insert(parts, "maxCharges: 1")
			end
			if is_item_off_gcd(itemKey) then
				table.insert(parts, "hasGCD: false")
			end
			table.insert(lines, "\t\t{ " .. table.concat(parts, ", ") .. " },")
		end
	end

	table.insert(lines, "\t]")
	table.insert(lines, "}")
	table.insert(lines, "")
	table.insert(lines, "Get" .. variant .. "BuffList() {")
	table.insert(lines, "\treturn [")

	for _, buffKey in ipairs(get_ordered_buffs()) do
		local catalogEntry = GCDI.buffCatalog[buffKey]
		if catalogEntry then
			local showStacks = GCDI.should_show_buff_stacks(buffKey)
			local maxStacks = GCDI.get_buff_max_stacks_display(buffKey)

			local parts = { string.format('name: "%s"', companion_string_escape(companion_normalize_name(catalogEntry.name, true))) }
			if showStacks and maxStacks > 0 then
				table.insert(parts, "hasStacks: true")
				table.insert(parts, "maxStacks: " .. maxStacks)
			end
			if GCDI.should_show_duration_bar(buffKey) then
				table.insert(parts, "hasPandemic: true")
			end
			table.insert(lines, "\t\t{ " .. table.concat(parts, ", ") .. " },")
		end
	end

	table.insert(lines, "\t]")
	table.insert(lines, "}")
	table.insert(lines, "")
	table.insert(lines, "Get" .. variant .. "ResourceConfig() {")
	table.insert(lines, "\treturn [")

	if gcdi_is_resource_enabled("health") then
		table.insert(lines, '\t\t{ name: "health", min: 0, max: 100 },')
	end
	for _, name in ipairs(GCDI_RESOURCE_ORDER) do
		if gcdi_is_resource_enabled(name) then
			if name == "stagger" then
				-- No power type - computed as a % of max health, not exportable as min/max/charges.
				table.insert(lines, string.format('\t\t{ name: "%s" },  ; TODO stagger has no power type, fill in manually', name))
			else
				local powerType = GCDI_RESOURCE_POWER_TYPE[name]
				local liveMax = powerType and UnitPowerMax("player", powerType) or nil
				if GCDI_RESOURCE_IS_CHARGES[name] then
					table.insert(lines, string.format('\t\t{ name: "%s", charges: %s },  ; live snapshot, verify',
						name, liveMax and tostring(liveMax) or '"TODO"'))
				else
					table.insert(lines, string.format('\t\t{ name: "%s", min: 0, max: %s },  ; live snapshot, verify',
						name, liveMax and tostring(liveMax) or '"TODO"'))
				end
			end
		end
	end

	table.insert(lines, "\t]")
	table.insert(lines, "}")

	return table.concat(lines, "\n")
end
GCDI.export_companion_config = export_companion_config

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
-- Midnights+: these fields may be secret values — never compare with >, use as table keys, or chain into
-- Blizzard UI code from UNIT_AURA; strip secrets and rely on frame icon when needed.
-- ═══════════════════════════════════════════════════════════════════════════
local function CDMSpellIdForAddonUse(id)
	if id == nil then return nil end
	if issecretvalue and issecretvalue(id) then return nil end
	return id
end

local function CDMIsUsableSpellId(id)
	if id == nil then return false end
	if issecretvalue and issecretvalue(id) then return false end
	return type(id) == "number" and id > 0
end

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
		spellID = CDMSpellIdForAddonUse(cooldownInfo.spellID)
		overrideSpellID = CDMSpellIdForAddonUse(cooldownInfo.overrideSpellID)
		overrideTooltipSpellID = CDMSpellIdForAddonUse(cooldownInfo.overrideTooltipSpellID)
		hasCharges = cooldownInfo.hasCharges or false
	end
	local displaySpellID = overrideSpellID or spellID  -- for name/APIs (never secret after strip)

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
	if not texture and CDMIsUsableSpellId(overrideTooltipSpellID) and C_Spell and C_Spell.GetSpellTexture then
		texture = C_Spell.GetSpellTexture(overrideTooltipSpellID)
	end
	if not texture and CDMIsUsableSpellId(displaySpellID) and C_Spell and C_Spell.GetSpellTexture then
		texture = C_Spell.GetSpellTexture(displaySpellID)
	end
	if not texture and CDMIsUsableSpellId(spellID) and C_Spell and C_Spell.GetSpellTexture then
		texture = C_Spell.GetSpellTexture(spellID)
	end
	if not texture then texture = 134400 end

	-- Name from same spell as tooltip (overrideTooltipSpellID first) so name matches what tooltip shows
	if CDMIsUsableSpellId(overrideTooltipSpellID) and C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(overrideTooltipSpellID)
		if info and info.name then spellName = info.name end
	end
	if not spellName and CDMIsUsableSpellId(displaySpellID) and C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(displaySpellID)
		if info and info.name then spellName = info.name end
	end
	if not spellName and CDMIsUsableSpellId(spellID) and C_Spell and C_Spell.GetSpellInfo then
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
	gcdi_install_cdm_stack_hooks()
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

	gcdi_setup_all_native_stack_slots()
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
-- rebuild_spell_bars already rebuilds item bars, so it is not repeated here.
local function scan_action_bars()
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
		-- Removed auto-scan: use /gcdopt scan to manually rescan
		update_item_charge_indicators()  -- Update charge indicators immediately
		
	elseif event == "UNIT_HEALTH" then
		if arg1 == "player" then
			update_health_bar()
			update_stagger_bar()
		end
		
	elseif event == "UNIT_MAXHEALTH" then
		if arg1 == "player" then
			update_health_bar()
			update_stagger_bar()
		end
		
	elseif event == "UNIT_HEAL_ABSORB_AMOUNT_CHANGED" then
		if arg1 == "player" then
			update_health_bar()
		end
		
	elseif event == "UNIT_HEAL_PREDICTION" then
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
		C_Timer.After(0.5, function()
			if previewMode or InCombatLockdown() then return end
			if gcdi_needs_charge_layout_rebuild() then
				rebuild_spell_bars()
			end
			-- Native stack binding can only bind out of combat (AuraContainer creation
			-- is combat-lockdown gated); retry any buffs left on the classic path
			-- because combat started before they ever got a chance to bind.
			if configs.useNativeStackBinding then
				gcdi_setup_all_native_stack_slots()
			end
		end)
		
	elseif event == "PLAYER_ENTERING_WORLD" then
		main_frame.combatbar:SetStatusBarColor(gcdi_safe_unit_affecting_combat("player") and 1 or 0, 0, 0)
		update_aggro_indicator()
		update_dispel_indicator()
		-- Removed auto-scan: use /gcdopt scan to manually rescan
		update_all_resources()
		update_gcd()  -- Initialize GCD bar
		-- Try to detect native range after a delay (in case player has a target)
		C_Timer.After(3, detect_native_range_for_spells)
		
	elseif event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_BONUS_ACTIONBAR" then
		-- Only update stance indicator, don't rescan spells
		-- Spells should stay static unless profile is changed
		update_stance_indicator()
		-- Bonus bar swaps repoint action slots.
		gcdi_invalidate_action_slot_map()
		
	elseif event == "RUNE_POWER_UPDATE" then
		update_runes_bar()

	elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "UPDATE_MACROS" then
		-- Cached spellID -> action slot map is now stale.
		gcdi_invalidate_action_slot_map()

	elseif event == "SPELLS_CHANGED" then
		gcdi_invalidate_action_slot_map()
		LibRange:InvalidateSpellRangeCache()

	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		-- Removed auto-scan: use /gcdopt scan to manually rescan
		gcdi_invalidate_action_slot_map()
		LibRange:InvalidateSpellRangeCache()
		gcdi_refresh_stagger_spec()

	elseif event == "PLAYER_TARGET_CHANGED" then
		-- Retargeting can otherwise leave a stale fallback range reading (see
		-- LibGCDI-Range.lua's ResetIndicatorState/cachedFallbackInRange) shown
		-- as green/red until a fresh sample happens to overwrite it.
		LibRange:ResetIndicatorState()
		update_range_indicators()
		detect_native_range_for_spells()  -- Auto-detect native range when targeting
		update_aggro_indicator()
		update_dispel_indicator()
		-- Refresh target-debuff bars so a new target doesn't show stale data
		-- left over from the previous one; deferred like the UNIT_AURA path.
		schedule_update_all_buff_bars_after_aura()
		
	elseif event == "UNIT_THREAT_SITUATION_UPDATE" then
		update_aggro_indicator()
		
	elseif event == "UNIT_TARGET" then
		if arg1 == "target" then
			update_aggro_indicator()  -- Target's target changed (e.g. mob switched to you)
		end

	elseif event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
		update_mob_count_indicator()  -- Nameplate appeared or disappeared
		
	elseif event == "UNIT_AURA" then
		if arg1 == "player" or arg1 == "target" then
			-- Defer: see schedule_update_all_buff_bars_after_aura (CooldownViewer taint / secret spellID
			-- compare). This also covers update_dispel_indicator(), scheduled inside the same deferred
			-- callback, so it must not be called synchronously here too.
			schedule_update_all_buff_bars_after_aura()
		end
		
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		-- Manual buff tracking for buffs not in CDM
		if arg1 == "player" then
			local spellID = arg2
			if issecretvalue and issecretvalue(spellID) then
				return
			end
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
	
	-- Range: use yards-keyed; migrate from legacy index/proxyIDs
	if not settings.rangeProxySpells or type(settings.rangeProxySpells) ~= "table" then
		settings.rangeProxySpells = {}
	end
	if settings.globalRangeFallbackYards == nil then
		if settings.globalRangeFallback ~= nil and LibRange.LEGACY_INDEX_TO_YARDS[settings.globalRangeFallback] ~= nil then
			settings.globalRangeFallbackYards = LibRange.LEGACY_INDEX_TO_YARDS[settings.globalRangeFallback]
		else
			settings.globalRangeFallbackYards = DEFAULT_SETTINGS.globalRangeFallbackYards or 5
		end
	end
	if settings.rangeProxySpellIDs and type(settings.rangeProxySpellIDs) == "table" then
		for idx, yards in pairs(LibRange.LEGACY_INDEX_TO_YARDS) do
			if settings.rangeProxySpellIDs[idx] and not settings.rangeProxySpells[yards] then
				settings.rangeProxySpells[yards] = settings.rangeProxySpellIDs[idx]
			end
		end
	end
	if settings.meleeRangeProxySpellID and not settings.rangeProxySpells[5] then
		settings.rangeProxySpells[5] = settings.meleeRangeProxySpellID
	end

	local function ensure_settings_entry(category, key)
		if not settings[category] then settings[category] = {} end
		if key and not settings[category][key] then settings[category][key] = {} end
		if key then return settings[category][key] end
		return settings[category]
	end
	ensure_settings_entry("spellSettings")
	ensure_settings_entry("spellOrder")
	ensure_settings_entry("itemSettings")
	ensure_settings_entry("itemOrder")
	ensure_settings_entry("buffSettings")
	ensure_settings_entry("buffOrder")
	ensure_settings_entry("profiles")
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
			stagger = false,
		}
	end
	if settings.resourceSettings.stagger == nil then
		settings.resourceSettings.stagger = false
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
			showDispel = true,
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
	-- Legacy: 28 was an item bracket; we now use proxy spells (no 28 yd bracket)
	if settings.gcdSettings.mobCountRange == 28 then
		settings.gcdSettings.mobCountRange = 30
	end
	if settings.gcdSettings.mobCountThreshold == nil then
		settings.gcdSettings.mobCountThreshold = 3
	end
	if settings.gcdSettings.showDispel == nil then
		settings.gcdSettings.showDispel = true
	end
	if settings.gcdSettings.useLibRangeCheck == nil then
		settings.gcdSettings.useLibRangeCheck = false
	end

	-- Compact mode persists per-character (shared across all profiles/specs,
	-- matching its "global, not per-profile" design) via GCDIndicator_Settings
	-- (SavedVariablesPerCharacter). GCDI.configs itself is not saved, so
	-- bootstrap the live runtime flag from the persisted value here; the
	-- slash command and options checkbox write both configs.compactMode and
	-- settings.compactMode so the choice survives reload/logout.
	configs.compactMode = (settings.compactMode == true)

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
	local containerWidth = (configs.size * 7) + (sepSize * 6) + (pad * 2)  -- 7: stance, gcd, combat, aggro, casting, mobcount, dispel
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
	init_status_bar_texture(gcdbar)
	gcdbar:SetMinMaxValues(0, 1)
	gcdbar:SetValue(0)
	gcdbar:SetSize(10000, configs.size)
	gcdbar:SetStatusBarColor(0, 0, 0)
	gcdbar:SetPoint("LEFT")
	main_frame.gcdbar = gcdbar
	
	local gcdIndicatorDefs = {
		{"combatbar", {0, 0, 0}},
		{"aggrobar", {0.3, 0.3, 0.3}},
		{"castingbar", {0, 0, 0}},
		{"mobcountbar", {0, 0, 0}},
		{"dispelbar", {0.28, 0.28, 0.32}},
	}
	local prevAnchor = gcdClip
	local lastSep
	for _, def in ipairs(gcdIndicatorDefs) do
		local name, color = def[1], def[2]
		local sep = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
		sep:SetSize(sepSize, configs.size)
		sep:SetPoint("LEFT", prevAnchor, "RIGHT", 0, 0)
		sep:SetColorTexture(0, 0, 0, 1)
		lastSep = sep
		local bar = CreateFrame("StatusBar", nil, gcdCombatContainer)
		init_status_bar_texture(bar)
		bar:SetMinMaxValues(0, 100)
		bar:SetValue(100)
		bar:SetSize(configs.size, configs.size)
		bar:SetStatusBarColor(color[1], color[2], color[3])
		bar:SetPoint("LEFT", sep, "RIGHT", 0, 0)
		main_frame[name] = bar
		prevAnchor = bar
	end
	main_frame.gcdRowSep6 = lastSep
	
	GCDIndicator_Positions = GCDIndicator_Positions or {}
	local libGCDI = LibStub and LibStub:GetLibrary("LibGCDI", true)
	if libGCDI then
		libGCDI.load_position(anchor, "GCDIndicator", GCDIndicator_Positions)
	end
	
	local barSize = configs.barHeight
	-- Create all resource bars
	resourceBars.health = create_resource_bar("health", RESOURCE_COLORS.health)
	setup_health_heal_absorb_bar(resourceBars.health)
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
	resourceBars.stagger = create_resource_bar("stagger", RESOURCE_COLORS.stagger)
	
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
	update_dispel_indicator()
	
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
		"NAME_PLATE_UNIT_ADDED",
		"NAME_PLATE_UNIT_REMOVED",
	}
	for _, event in ipairs(events) do
		main_frame:RegisterEvent(event)
	end
	main_frame:RegisterUnitEvent("UNIT_HEALTH", "player")
	main_frame:RegisterUnitEvent("UNIT_MAXHEALTH", "player")
	main_frame:RegisterUnitEvent("UNIT_HEAL_ABSORB_AMOUNT_CHANGED", "player")
	main_frame:RegisterUnitEvent("UNIT_HEAL_PREDICTION", "player")
	main_frame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
	main_frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
	main_frame:RegisterUnitEvent("UNIT_MAXPOWER", "player")
	main_frame:RegisterUnitEvent("UNIT_AURA", "player", "target")
	main_frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")  -- For manual buff tracking
	main_frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")  -- Casting bar yellow while channeling
	main_frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")   -- Casting bar black when done
	main_frame:RegisterUnitEvent("UNIT_TARGET", "target")  -- So aggro indicator updates when target's target changes
	main_frame:SetScript("OnEvent", on_event)

	if gcdi_safe_unit_affecting_combat("player") then
		combatbar:SetStatusBarColor(1, 0, 0)
	end
	
	-- Initialize GCD bar immediately (don't wait for events)
	update_gcd()
	
	-- Removed auto-scan: use /gcdopt scan to manually rescan
	-- Spells will only be scanned when you press the scan button
	
	-- Removed auto-ingest: use /gcdopt scan or /gcdopt cdmimport to manually import CDM buffs
	
	if settings.currentProfile and settings.profiles and settings.profiles[settings.currentProfile] then
		C_Timer.After(0.5, function()
			-- Reuse the same LoadProfile path the Options UI uses (GCDI.load_profile)
			-- so the active profile loads identically on login and on re-selection --
			-- an ad hoc field-by-field copy here previously omitted
			-- resourceSettings/gcdSettings that LoadProfile does copy.
			local catalogs = {
				spellCatalog = GCDI.spellCatalog,
				itemCatalog = GCDI.itemCatalog,
				buffCatalog = GCDI.buffCatalog,
			}
			LibProfiles:LoadProfile(settings, settings.currentProfile, catalogs)

			rebuild_spell_bars()
			rebuild_buff_bars()
			
			-- Scan CDM frames AFTER profile load to get live frame references
			-- This populates cdmBuffFrames and spellIDToCooldownID mappings
			C_Timer.After(1.0, function()
				scan_cdm_buff_frames()
			end)
			
			print("GCDI_PREFIXProfile '" .. settings.currentProfile .. "' loaded")
		end)
	end
	
	-- Master update ticker (0.05s / 50ms base interval).
	--
	-- This was 0.015s with every update running on every tick, i.e. once per frame at
	-- 60fps. Anything reachable from a game event now runs on that event and keeps only
	-- a low-rate safety poll here; what stays at full rate is bar animation the client
	-- does not drive itself.
	local TICK_INTERVAL = 0.05
	local tickCount = 0
	C_Timer.NewTicker(TICK_INTERVAL, function()
		tickCount = tickCount + 1

		-- Every tick (20 Hz): manual cooldown animation + charge pips
		animate_item_bars()
		update_charge_indicators_tick()

		-- Every 2 ticks (10 Hz): range colors, stagger
		if tickCount % 2 == 0 then
			update_range_indicators()
			update_stagger_bar()
		end

		-- Every 4 ticks (5 Hz): nameplate sweep, proc icon swaps
		-- Also driven by NAME_PLATE_UNIT_ADDED/REMOVED and UNIT_AURA respectively.
		if tickCount % 4 == 0 then
			pcall(update_mob_count_indicator)
			update_spell_icons()
		end

		-- Every 10 ticks (2 Hz): safety polls for state that is primarily event-driven.
		-- GCD/cooldown bars self-animate via SetTimerDuration once armed; buffs come from
		-- UNIT_AURA and the CDM RefreshData hook; item charges from BAG_UPDATE.
		if tickCount % 10 == 0 then
			update_gcd()
			update_all_buff_bars()
			update_item_charge_indicators()
			pcall(update_dispel_indicator)
		end

		-- Every 100 ticks (5s): Native range detection
		if tickCount % 100 == 0 then
			detect_native_range_for_spells()
			tickCount = 0  -- Reset to prevent overflow
		end
	end)

	-- Initial mob count + dispel (nameplates / auras may not be ready at load)
	C_Timer.After(1, function()
		update_mob_count_indicator()
		update_dispel_indicator()
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
				"insanity", "maelstrom", "fury", "pain", "astralPower", "essence",
				"stagger",
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
					-- Plain-number fake absorb for layout only; cannot mimic real "secret" userdata from Lua
					if key == "health" and configs.debugMode and data.healAbsorbBar then
						data.bar:SetValue(100)
						if not layout_heal_absorb_bar(data, 100, 25) then
							data.healAbsorbBar:Hide()
						end
					elseif data.healAbsorbBar then
						data.healAbsorbBar:Hide()
					end
				end
			end
		end
		
		-- Set all spell bar indicators to visible colors
		for spellID, data in pairs(trackedSpells) do
			if data.rangeOverlay then
				data.rangeOverlay:SetColorTexture(0, 1, 0, 1)  -- Green = in range
			end
			if data.chargeStackBar and data.chargeStackBar.bar then
				local m = math.max(data.chargeStackMax or 2, 1)
				data.chargeStackBar.bar:SetMinMaxValues(0, m)
				data.chargeStackBar.bar:SetValue(m)
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
				data.chargeOverlay:Hide()  -- Hide overlay to show spell charge color (has charge)
			end
		end
		
		-- Set all buff indicators to active
		for buffID, data in pairs(trackedBuffs) do
			if data.activeIndicator then
				data.activeIndicator:SetColorTexture(0, 0.8, 0, 1)  -- Green = active
			end
			if data.stackBar then
				local m = math.max(data.stackBarMax or 1, 1)
				data.stackBar.bar:SetMinMaxValues(0, m)
				data.stackBar.bar:SetValue(math.max(1, math.floor(m * 0.5)))
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
		if main_frame.mobcountbar then
			main_frame.mobcountbar:SetStatusBarColor(1, 1, 1)
			main_frame.mobcountbar:SetValue(100)
		end
		if main_frame.dispelbar then
			main_frame.dispelbar:SetStatusBarColor(0.6, 0.2, 0.8)  -- Sample: dispel-active purple
			main_frame.dispelbar:SetValue(100)
		end
		if main_frame.stanceIndicator then
			main_frame.stanceIndicator:SetColorTexture(0.5, 0.3, 0, 1)  -- Bear form color
		end

		print("GCDI_PREFIXPreview mode |cff00ff00ON|r - All bars filled")
		if configs.debugMode and resourceBars.health and resourceBars.health.healAbsorbBar then
			print("|cff888888GCDIndicator:|r Debug: health 60/100 + heal absorb 25 (plain numbers for layout; real secrets only come from combat APIs)|r")
		end
	else
		-- Hide background
		if previewBackground then
			previewBackground:Hide()
		end

		-- Preview wrote indicator textures directly, bypassing the change-detection
		-- caches. Clear them so the updates below actually repaint instead of
		-- concluding everything is already correct and leaving preview colors up.
		LibRange:ResetIndicatorState()
		for _, data in pairs(trackedBuffs) do
			data.active = nil
			data.durationArmedGeneration = nil
		end
		if resourceBars.stagger then
			resourceBars.stagger.staggerParked = nil
		end
		main_frame.mobCountState = nil
		main_frame.dispelState = nil
		gcdi_invalidate_charge_spell_list()

		-- Force update all bars to restore real values
		-- Call individual update functions to properly restore each resource bar
		update_all_resources()
		
		-- Reset GCD and combat bars
		if main_frame.gcdbar then
			main_frame.gcdbar:SetStatusBarColor(0, 0, 0)
			main_frame.gcdbar:SetValue(0)
		end
		if main_frame.combatbar then
			main_frame.combatbar:SetStatusBarColor(gcdi_safe_unit_affecting_combat("player") and 1 or 0, 0, 0)
		end
		
		-- Update stance indicator
		local formIndex = GetShapeshiftForm() or 0
		local color = FORM_COLORS[formIndex] or FORM_COLORS.default
		if main_frame.stanceIndicator then
			main_frame.stanceIndicator:SetColorTexture(color[1], color[2], color[3], 1)
		end
		
		-- Update aggro indicator
		update_aggro_indicator()
		update_mob_count_indicator()
		update_dispel_indicator()
		
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
		
		print("GCDI_PREFIXPreview mode |cffff0000OFF|r - Normal display restored")
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
		print("GCDI_PREFIXDebug mode " .. (configs.debugMode and "ON" or "OFF"))
	elseif msg == "nativestacks" then
		-- A/B toggle for buff stack tracking: classic (C_UnitAuras query) vs
		-- experimental (native AuraContainer/SetApplicationBar). See CHANGE-TRACKER.md.
		configs.useNativeStackBinding = not configs.useNativeStackBinding
		print("GCDI_PREFIXNative stack binding " .. (configs.useNativeStackBinding and "ON (experimental)" or "OFF (classic)"))
		rebuild_buff_bars()
	elseif msg == "compact" then
		-- Flow-packed spell/item/buff layout toggle. See CHANGE-TRACKER.md.
		configs.compactMode = not configs.compactMode
		settings.compactMode = configs.compactMode  -- persist (SavedVariablesPerCharacter)
		print("GCDI_PREFIXCompact mode " .. (configs.compactMode and "ON" or "OFF"))
		-- Box layout (icon square present/absent) is baked in at creation
		-- time, not just position, so toggling needs a full rebuild.
		rebuild_spell_bars()  -- also rebuilds item bars
		rebuild_buff_bars()
	elseif msg == "exportbars" then
		-- Diagnostic dump of every visible bar's position/size, for
		-- cross-checking against what the companion script computes. See
		-- export_bar_positions() above reposition_all().
		local text = export_bar_positions()
		if GCDI.show_export_import_popup then
			GCDI.show_export_import_popup("export", text, "Bar Position Export")
		else
			print(GCDI_PREFIX .. text)
		end
	elseif msg == "exportrotation" then
		-- Companion-script config export: generates SpellList/BuffList
		-- array text from the live catalog/settings state. See
		-- export_companion_config() above reposition_all(). Asks Primary vs.
		-- Secondary first (see the GCDI_EXPORT_ROTATION_CONFIG popup in
		-- LibGCDI-Options.lua) since the addon only reflects whichever
		-- spec/build is currently active.
		StaticPopup_Show("GCDI_EXPORT_ROTATION_CONFIG")
	elseif msg == "items" then
		print("GCDI_PREFIX--- Item Catalog ---")
		local count = 0
		for key, data in pairs(GCDI.itemCatalog) do
			count = count + 1
			print("  " .. key .. " = " .. tostring(data.name) .. " (ID: " .. tostring(data.itemID) .. ")")
		end
		print(GCDI_PREFIX .. count .. " items in catalog")
	elseif msg == "buffs" then
		-- List tracked buffs and their status
		print("GCDI_PREFIX--- Tracked Buffs Status ---")
		print("|cff888888Note: Buff spell IDs are secret. Get IDs from Wowhead or tooltip addons.|r")
		local count = 0
		for spellID, data in pairs(GCDI.buffCatalog) do
			count = count + 1
			local ok, hasAura = pcall(function()
				return C_UnitAuras.GetUnitAuraBySpellID("player", spellID) ~= nil
			end)
			local status = ok and hasAura and "|cff00ff00ACTIVE|r" or "|cff888888inactive|r"
			print("  " .. data.name .. " (ID: |cffffcc00" .. spellID .. "|r) - " .. status)
		end
		if count == 0 then
			print("  No buffs being tracked. Add buffs in /gcdopt -> Buffs tab")
		end
	elseif msg == "buffdebug" then
		-- Debug: show what's saved in settings.buffSettings
		print("GCDI_PREFIX--- Buff Settings Debug ---")
		if settings and settings.buffSettings then
			local count = 0
			for key, val in pairs(settings.buffSettings) do
				count = count + 1
				local keyType = type(key)
				print("  Key: " .. tostring(key) .. " (type: " .. keyType .. "), enabled: " .. tostring(val.enabled))
			end
			print(GCDI_PREFIX .. count .. " entries in buffSettings")
		else
			print("  settings.buffSettings is nil or empty")
		end
		print("GCDI_PREFIX--- Buff Catalog ---")
		local catCount = 0
		for spellID, data in pairs(GCDI.buffCatalog) do
			catCount = catCount + 1
			-- Test if this buff can be detected
			local ok, hasAura = pcall(function()
				return C_UnitAuras.GetPlayerAuraBySpellID(spellID) ~= nil
			end)
			local canDetect = ok and hasAura and "YES" or "maybe-secret"
			print("  " .. tostring(spellID) .. " = " .. tostring(data.name) .. " (detectable: " .. canDetect .. ")")
		end
		print(GCDI_PREFIX .. catCount .. " entries in buffCatalog")
	elseif msg == "cdmimport" then
		-- Force import from CDM
		print("GCDI_PREFIXImporting buffs from Cooldown Manager...")
		local newBuffs = scan_cdm_buff_frames()
		rebuild_buff_bars()
		local totalBuffs = 0
		for _ in pairs(GCDI.buffCatalog) do totalBuffs = totalBuffs + 1 end
		print("GCDI_PREFIXImported " .. newBuffs .. " new buffs (" .. totalBuffs .. " total)")
	
	elseif msg == "range" then
		-- Debug range detection for all tracked spells
		print("GCDI_PREFIX--- Range Detection Debug ---")
		local globalYards = settings.globalRangeFallbackYards or 5
		print("|cff888888Global Range Fallback: " .. tostring(globalYards) .. " yd (" .. (LibRange.RANGE_ITEMS[globalYards] and LibRange.RANGE_ITEMS[globalYards].name or "Unknown") .. ")|r")
		print("|cff888888Target: " .. (UnitExists("target") and UnitName("target") or "None") .. "|r")
		print("")
		
		for spellID, data in pairs(trackedSpells) do
			local catalogEntry = GCDI.spellCatalog[spellID]
			local spellName = catalogEntry and catalogEntry.name or ("Spell " .. spellID)
			local actionSlot = data.actionSlot
			local spellSettings = settings.spellSettings and settings.spellSettings[spellID] or {}
			
			local rangeMethod = "Global fallback (proxy)"
			if spellSettings.selfCast then
				rangeMethod = "Self-Cast (hidden)"
			elseif spellSettings.rangeFallbackYards ~= nil or spellSettings.rangeFallback ~= nil then
				local yards = spellSettings.rangeFallbackYards
				if yards == nil and spellSettings.rangeFallback ~= nil and LibRange.LEGACY_INDEX_TO_YARDS[spellSettings.rangeFallback] then
					yards = LibRange.LEGACY_INDEX_TO_YARDS[spellSettings.rangeFallback]
				end
				rangeMethod = "Override: " .. (yards and LibRange.RANGE_ITEMS[yards] and LibRange.RANGE_ITEMS[yards].name or tostring(yards) .. " yd")
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
		print("GCDI_PREFIXTesting range indicator visibility...")
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
		print("GCDI_PREFIXSet " .. count .. " range overlays to bright colors")
		print("|cffffcc00Note: Colors will reset on next target change or update tick|r")
		
	elseif msg == "minimap" then
		-- Toggle minimap button visibility
		GCDI.ToggleMinimapButton()
		local hidden = settings.minimap and settings.minimap.hide
		print("GCDI_PREFIXMinimap button " .. (hidden and "hidden" or "shown"))
		
	elseif msg == "testbuffs" or msg == "cdm" then
		-- Scan Blizzard's Cooldown Manager for buff frames
		print("GCDI_PREFIX--- Scanning Cooldown Manager ---")
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
		
		-- Helper to print frame info without materializing secret-capable spell IDs.
		local function printFrameInfo(frame)
			frameCount = frameCount + 1
			local cooldownID = frame.cooldownID
			if not cooldownID then
				print("  [frame without cooldownID]")
				return
			end
			
			-- Probe CDM info only for presence. Spell IDs can be secret and must not
			-- be retained or formatted in debug output.
			local infoOK, hasCooldownInfo = pcall(function()
				return frame.cooldownInfo ~= nil
			end)
			if (not infoOK or not hasCooldownInfo) and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
				pcall(function()
					return C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID) ~= nil
				end)
			end
			
			-- Active = auraInstanceID present (do not call GetAuraDataByAuraInstanceID; throws when secret/tainted on 12.1+)
			local auraOK, hasAura = pcall(function()
				return frame.auraInstanceID ~= nil
			end)
			hasAura = auraOK and hasAura
			local activeStr = hasAura and "|cff00ff00ACTIVE|r" or "|cff888888inactive|r"
			if hasAura then activeCount = activeCount + 1 end
			
			print("  cdID: |cffffcc00" .. tostring(cooldownID) .. "|r - " .. activeStr)
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
		
		print(GCDI_PREFIX .. frameCount .. " frames, " .. activeCount .. " active")
	else
		if GCDI.create_options_frame then
			GCDI.create_options_frame()
		else
			print("|cffff0000GCDIndicator:|r Options module not loaded!")
		end
	end
end

C_Timer.After(2, function()
	print("GCDI_PREFIXType |cffffcc00/gcdopt|r to open options, |cffffcc00/gcdi|r to move bars")
end)

C_Timer.After(0.5, init)
