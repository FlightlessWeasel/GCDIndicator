-- ═══════════════════════════════════════════════════════════════════════════
-- GCDIndicator - GCD and Spell Cooldown Tracker
-- ═══════════════════════════════════════════════════════════════════════════

-- Global namespace for module access
GCDI = {}

-- Configuration
GCDI.configs = {
	size = 10,
	xpoint = 0,
	ypoint = -219,
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

-- Forward declare functions for popups
local save_profile, delete_profile

-- Static popup dialogs (must be global)
StaticPopupDialogs["GCDI_SAVE_PROFILE"] = {
	text = "Enter profile name:",
	button1 = "Save",
	button2 = "Cancel",
	hasEditBox = true,
	OnAccept = function(self)
		local name = self.editBox:GetText()
		if name and name ~= "" and save_profile then
			save_profile(name)
			C_Timer.After(0.2, function()
				if GCDI.refresh_options_frame then GCDI.refresh_options_frame() end
			end)
		end
	end,
	OnShow = function(self)
		self.editBox:SetText("")
		self.editBox:SetFocus()
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		local name = self:GetText()
		if name and name ~= "" and save_profile then
			save_profile(name)
			C_Timer.After(0.2, function()
				if GCDI.refresh_options_frame then GCDI.refresh_options_frame() end
			end)
		end
		parent:Hide()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs["GCDI_DELETE_PROFILE"] = {
	text = "Delete profile '%s'?",
	button1 = "Delete",
	button2 = "Cancel",
	OnAccept = function(self, data)
		if data and delete_profile then
			delete_profile(data)
			C_Timer.After(0.2, function()
				if GCDI.refresh_options_frame then GCDI.refresh_options_frame() end
			end)
		end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

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

-- Known item types
local TRACKED_ITEM_TYPES = {
	trinket1 = { slot = 13, name = "Trinket 1" },
	trinket2 = { slot = 14, name = "Trinket 2" },
}

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
local reposition_all, rebuild_spell_bars, rebuild_item_bars

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
		bar:SetValue(0)
	end
end

local function deepcopy(orig)
	local copy
	if type(orig) == 'table' then
		copy = {}
		for k, v in pairs(orig) do
			copy[k] = deepcopy(v)
		end
	else
		copy = orig
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

function GCDI.get_action_slot_for_spell(spellID)
	for i = 1, 12 do
		local button = _G["ActionButton" .. i]
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
	settings.currentProfile = name
	
	rebuild_spell_bars()
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
-- SPELL/ITEM ORDERING
-- ═══════════════════════════════════════════════════════════════════════════

local function get_ordered_spells()
	if not settings then return spellBars end
	
	local ordered = {}
	local inOrder = {}
	
	for _, spellID in ipairs(settings.spellOrder or {}) do
		if trackedSpells[spellID] then
			table.insert(ordered, spellID)
			inOrder[spellID] = true
		end
	end
	
	for _, spellID in ipairs(spellBars) do
		if not inOrder[spellID] then
			table.insert(ordered, spellID)
		end
	end
	
	return ordered
end

function GCDI.get_all_catalog_spells_ordered()
	if not settings then return {} end
	
	local enabledOrdered = {}
	local disabledOrdered = {}
	local inOrder = {}
	
	for _, spellID in ipairs(settings.spellOrder or {}) do
		if GCDI.spellCatalog[spellID] then
			inOrder[spellID] = true
			if GCDI.is_spell_enabled(spellID) then
				table.insert(enabledOrdered, spellID)
			else
				table.insert(disabledOrdered, spellID)
			end
		end
	end
	
	local unsortedEnabled = {}
	local unsortedDisabled = {}
	for spellID, data in pairs(GCDI.spellCatalog) do
		if not inOrder[spellID] then
			if GCDI.is_spell_enabled(spellID) then
				table.insert(unsortedEnabled, { spellID = spellID, name = data.name })
			else
				table.insert(unsortedDisabled, { spellID = spellID, name = data.name })
			end
		end
	end
	table.sort(unsortedEnabled, function(a, b) return a.name < b.name end)
	table.sort(unsortedDisabled, function(a, b) return a.name < b.name end)
	
	for _, entry in ipairs(unsortedEnabled) do
		table.insert(enabledOrdered, entry.spellID)
	end
	for _, entry in ipairs(unsortedDisabled) do
		table.insert(disabledOrdered, entry.spellID)
	end
	
	local result = {}
	for _, spellID in ipairs(enabledOrdered) do
		table.insert(result, spellID)
	end
	for _, spellID in ipairs(disabledOrdered) do
		table.insert(result, spellID)
	end
	
	return result
end

local function save_spell_order(orderedList)
	if not settings then return end
	settings.spellOrder = {}
	for i, spellID in ipairs(orderedList) do
		settings.spellOrder[i] = spellID
	end
end

function GCDI.move_spell_in_order(spellID, direction)
	local ordered = GCDI.get_all_catalog_spells_ordered()
	local currentIndex = nil
	
	for i, id in ipairs(ordered) do
		if id == spellID then
			currentIndex = i
			break
		end
	end
	
	if not currentIndex then return end
	
	local newIndex = currentIndex + direction
	if newIndex < 1 or newIndex > #ordered then return end
	
	ordered[currentIndex], ordered[newIndex] = ordered[newIndex], ordered[currentIndex]
	save_spell_order(ordered)
	GCDI.auto_save_to_profile()
	rebuild_spell_bars()
end

function GCDI.move_spell_to_bottom(spellID)
	local ordered = GCDI.get_all_catalog_spells_ordered()
	local currentIndex = nil
	
	for i, id in ipairs(ordered) do
		if id == spellID then
			currentIndex = i
			break
		end
	end
	
	if not currentIndex or currentIndex == #ordered then return end
	
	table.remove(ordered, currentIndex)
	table.insert(ordered, spellID)
	save_spell_order(ordered)
	GCDI.auto_save_to_profile()
	rebuild_spell_bars()
end

function GCDI.get_ordered_items()
	if not settings then return {} end
	
	local ordered = {}
	local inOrder = {}
	
	for _, itemKey in ipairs(settings.itemOrder or {}) do
		if GCDI.itemCatalog[itemKey] and GCDI.is_item_enabled(itemKey) then
			table.insert(ordered, itemKey)
			inOrder[itemKey] = true
		end
	end
	
	for itemKey in pairs(GCDI.itemCatalog) do
		if not inOrder[itemKey] and GCDI.is_item_enabled(itemKey) then
			table.insert(ordered, itemKey)
		end
	end
	
	return ordered
end

function GCDI.get_all_catalog_items_ordered()
	if not settings then return {} end
	
	local enabledOrdered = {}
	local disabledOrdered = {}
	local inOrder = {}
	
	for _, itemKey in ipairs(settings.itemOrder or {}) do
		if GCDI.itemCatalog[itemKey] then
			inOrder[itemKey] = true
			if GCDI.is_item_enabled(itemKey) then
				table.insert(enabledOrdered, itemKey)
			else
				table.insert(disabledOrdered, itemKey)
			end
		end
	end
	
	local unsortedEnabled = {}
	local unsortedDisabled = {}
	for itemKey, data in pairs(GCDI.itemCatalog) do
		if not inOrder[itemKey] then
			if GCDI.is_item_enabled(itemKey) then
				table.insert(unsortedEnabled, { itemKey = itemKey, name = data.name })
			else
				table.insert(unsortedDisabled, { itemKey = itemKey, name = data.name })
			end
		end
	end
	table.sort(unsortedEnabled, function(a, b) return a.name < b.name end)
	table.sort(unsortedDisabled, function(a, b) return a.name < b.name end)
	
	for _, entry in ipairs(unsortedEnabled) do
		table.insert(enabledOrdered, entry.itemKey)
	end
	for _, entry in ipairs(unsortedDisabled) do
		table.insert(disabledOrdered, entry.itemKey)
	end
	
	local result = {}
	for _, itemKey in ipairs(enabledOrdered) do
		table.insert(result, itemKey)
	end
	for _, itemKey in ipairs(disabledOrdered) do
		table.insert(result, itemKey)
	end
	
	return result
end

local function save_item_order(orderedList)
	if not settings then return end
	settings.itemOrder = {}
	for i, itemKey in ipairs(orderedList) do
		settings.itemOrder[i] = itemKey
	end
end

function GCDI.move_item_in_order(itemKey, direction)
	local ordered = GCDI.get_all_catalog_items_ordered()
	local currentIndex = nil
	
	for i, key in ipairs(ordered) do
		if key == itemKey then
			currentIndex = i
			break
		end
	end
	
	if not currentIndex then return end
	
	local newIndex = currentIndex + direction
	if newIndex < 1 or newIndex > #ordered then return end
	
	ordered[currentIndex], ordered[newIndex] = ordered[newIndex], ordered[currentIndex]
	save_item_order(ordered)
	GCDI.auto_save_to_profile()
	rebuild_item_bars()
	reposition_all()
end

function GCDI.move_item_to_bottom(itemKey)
	local ordered = GCDI.get_all_catalog_items_ordered()
	local currentIndex = nil
	
	for i, key in ipairs(ordered) do
		if key == itemKey then
			currentIndex = i
			break
		end
	end
	
	if not currentIndex or currentIndex == #ordered then return end
	
	table.remove(ordered, currentIndex)
	table.insert(ordered, itemKey)
	save_item_order(ordered)
	GCDI.auto_save_to_profile()
	rebuild_item_bars()
	reposition_all()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GCD BAR UPDATE
-- ═══════════════════════════════════════════════════════════════════════════

local gcdInitialized = false

local function update_gcd()
	if not gcdInitialized then
		if UnitAffectingCombat("player") then
			gcdInitialized = true
		else
			main_frame.gcdbar:SetValue(0)
			return
		end
	end
	
	local durObj = C_Spell.GetSpellCooldownDuration(GCD_SPELL_ID)
	applyTimerToBar(main_frame.gcdbar, durObj)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELL COOLDOWN BAR
-- ═══════════════════════════════════════════════════════════════════════════

local function update_spell_bar(spellID)
	local data = trackedSpells[spellID]
	if not data then return end
	
	local cdInfo = C_Spell.GetSpellCooldown(spellID)
	if not cdInfo then
		data.bar:SetValue(0)
		return
	end
	
	local isOnGCD = cdInfo.isOnGCD == true
	local chargeInfo = C_Spell.GetSpellCharges(spellID)
	local durObj
	
	if chargeInfo then
		durObj = isOnGCD and C_Spell.GetSpellCooldownDuration(GCD_SPELL_ID) 
		                  or C_Spell.GetSpellChargeDuration(spellID)
	else
		durObj = C_Spell.GetSpellCooldownDuration(spellID)
	end
	
	applyTimerToBar(data.bar, durObj)
end

local function update_all_spell_bars()
	for spellID in pairs(trackedSpells) do
		update_spell_bar(spellID)
	end
end

local function create_spell_bar(spellID, spellName, texture, actionSlot)
	local barIndex = #spellBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	local container = CreateFrame("Frame", nil, main_frame)
	container:SetSize((barSize * 3 + 4) + pad * 2, barSize + pad * 2)
	
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
	
	local rangeBase = container:CreateTexture(nil, "ARTWORK")
	rangeBase:SetSize(barSize, barSize)
	rangeBase:SetPoint("LEFT", clipContainer, "RIGHT", 2, 0)
	rangeBase:SetColorTexture(1, 1, 1, 1)
	
	local rangeOverlay = container:CreateTexture(nil, "OVERLAY")
	rangeOverlay:SetSize(barSize, barSize)
	rangeOverlay:SetPoint("CENTER", rangeBase, "CENTER", 0, 0)
	rangeOverlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
	
	trackedSpells[spellID] = { 
		bar = bar, 
		container = container, 
		actionSlot = actionSlot,
		rangeOverlay = rangeOverlay
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
	for itemKey in pairs(trackedItems) do
		update_item_bar(itemKey)
	end
end

local function animate_item_bars()
	local currentTime = GetTime()
	for itemKey, data in pairs(trackedItems) do
		if data.cdStartTime and data.cdDuration then
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

local function create_item_bar(itemKey, itemName, texture, itemID, slot)
	local barIndex = #itemBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	local container = CreateFrame("Frame", nil, main_frame)
	container:SetSize((barSize * 2 + 2) + pad * 2, barSize + pad * 2)
	
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
	
	trackedItems[itemKey] = { 
		bar = bar, 
		container = container, 
		itemID = itemID,
		slot = slot,
		name = itemName
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

local function is_spell_self_cast(spellID)
	if not settings then return false end
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.selfCast == true then
		return true
	end
	return false
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

local function update_range_indicators()
	for i, spellID in ipairs(spellBars) do
		local spellData = trackedSpells[spellID]
		if spellData and spellData.rangeOverlay then
			local overlay = spellData.rangeOverlay
			local actionSlot = spellData.actionSlot
			
			if is_spell_self_cast(spellID) then
				overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
			elseif not UnitExists("target") then
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
						overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
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
	if not main_frame.stanceIndicator then return end
	
	local formIndex = GetShapeshiftForm() or 0
	local color = FORM_COLORS[formIndex] or FORM_COLORS.default
	main_frame.stanceIndicator:SetColorTexture(color[1], color[2], color[3], 1)
end

reposition_all = function()
	local barSize = configs.barHeight
	local spacing = configs.barSpacing
	local pad = configs.bgPadding
	
	local resourceBarHeight = barSize + pad * 2
	local gcdContainerHeight = configs.size + pad * 2
	local spellBarHeight = barSize + pad * 2
	
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
	update_range_indicators()
	reposition_all()
end

GCDI.rebuild_spell_bars = rebuild_spell_bars

local function scan_action_bars()
	scan_spellbook()
	scan_items()
	rebuild_spell_bars()
end

GCDI.scan_action_bars = scan_action_bars

local function schedule_scan(delay)
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
		update_all_item_bars()
		
	elseif event == "BAG_UPDATE" or event == "PLAYER_EQUIPMENT_CHANGED" then
		schedule_scan(0.5)
		
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
		schedule_scan(0.5)
		update_all_resources()
		
	elseif event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_BONUS_ACTIONBAR" then
		schedule_scan(0.1)
		update_stance_indicator()
		
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		schedule_scan(0.5)
		
	elseif event == "PLAYER_TARGET_CHANGED" then
		update_range_indicators()
		
	elseif not InCombatLockdown() then
		schedule_scan(0.3)
	end
end

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
	if not settings.profiles then
		settings.profiles = {}
	end
	
	main_frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 0)
	main_frame:SetSize(1, 1)
	
	local pad = configs.bgPadding
	
	local anchor = CreateFrame("Frame", nil, main_frame)
	anchor:SetSize(1, 1)
	anchor:SetPoint("CENTER", UIParent, "CENTER", configs.xpoint, configs.ypoint)
	main_frame.anchor = anchor
	
	local sepSize = 2
	local containerWidth = (configs.size * 3) + (sepSize * 2) + (pad * 2)
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
	
	local gcdClip = CreateFrame("Frame", nil, gcdCombatContainer)
	gcdClip:SetSize(configs.size, configs.size)
	gcdClip:SetPoint("LEFT", sep1, "RIGHT", 0, 0)
	gcdClip:SetClipsChildren(true)
	
	local gcdBg = gcdClip:CreateTexture(nil, "BACKGROUND")
	gcdBg:SetAllPoints()
	gcdBg:SetColorTexture(1, 1, 1, 1)
	
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
	
	local events = {
		"SPELL_UPDATE_COOLDOWN",
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
	}
	for _, event in ipairs(events) do
		main_frame:RegisterEvent(event)
	end
	main_frame:RegisterUnitEvent("UNIT_HEALTH", "player")
	main_frame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
	main_frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
	main_frame:RegisterUnitEvent("UNIT_MAXPOWER", "player")
	main_frame:SetScript("OnEvent", on_event)

	if UnitAffectingCombat("player") then
		combatbar:SetStatusBarColor(1, 0, 0)
	end
	
	schedule_scan(0.1)
	C_Timer.After(1.0, function()
		if #spellBars == 0 then
			scan_action_bars()
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
			rebuild_spell_bars()
			print("|cff00ff00GCDIndicator:|r Profile '" .. settings.currentProfile .. "' loaded")
		end)
	end
	
	C_Timer.NewTicker(0.1, update_range_indicators)
	C_Timer.NewTicker(0.05, animate_item_bars)
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
