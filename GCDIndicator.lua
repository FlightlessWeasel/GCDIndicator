-- ═══════════════════════════════════════════════════════════════════════════
-- GCDIndicator - GCD and Spell Cooldown Tracker
-- ═══════════════════════════════════════════════════════════════════════════

-- Configuration
local configs = {
	size = 10,           -- GCD indicator size
	xpoint = 0,
	ypoint = -219,
	barSpacing = 0,      -- Space between cooldown bars (0 = connected)
	barHeight = 8,       -- Height/width of spell cooldown bars
	bgPadding = 2,       -- Background extends this many pixels beyond bars
	debugMode = false,   -- Set to true to see scan output
}

-- Cache frequently used globals for performance
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
local save_profile, delete_profile, refresh_options_frame

-- Static popup dialogs for profile management (must be global)
StaticPopupDialogs["GCDI_SAVE_PROFILE"] = {
	text = "Enter profile name:",
	button1 = "Save",
	button2 = "Cancel",
	hasEditBox = true,
	OnAccept = function(self)
		local name = self.editBox:GetText()
		if name and name ~= "" and save_profile then
			save_profile(name)
			-- Delay refresh to allow popup to close fully
			C_Timer.After(0.2, function()
				if refresh_options_frame then refresh_options_frame() end
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
				if refresh_options_frame then refresh_options_frame() end
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
				if refresh_options_frame then refresh_options_frame() end
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
local trackedSpells = {}  -- { spellID = barData }
local spellBars = {}      -- Ordered list of spellIDs
local trackedItems = {}   -- { itemKey = barData }
local itemBars = {}       -- Ordered list of item keys
local pendingScanTimer = nil  -- Throttle scans
local resourceBars = {}   -- { health, rage, energy, comboPoints }

-- Known item types for tracking
local TRACKED_ITEM_TYPES = {
	trinket1 = { slot = 13, name = "Trinket 1" },
	trinket2 = { slot = 14, name = "Trinket 2" },
}

-- Common consumable item IDs (will be scanned from bags)
-- These are fallback items - we also scan action bars for any items
local CONSUMABLE_ITEM_IDS = {
	-- Healthstones
	[5512] = "Healthstone",
	-- Dragonflight Health Potions
	[191380] = "Refreshing Healing Potion",
	[191381] = "Potion of Withering Dreams",
	-- War Within / Midnight Health Potions
	[211878] = "Algari Healing Potion",
	[212241] = "Cavedweller's Delight",
	[224464] = "Potion of Unwavering Focus",
}

-- Track items found on action bars (populated during scan)
local actionBarItems = {}

-- Resource bar colors
local RESOURCE_COLORS = {
	health = { 0.0, 0.8, 0.0 },       -- Green
	rage = { 0.8, 0.0, 0.0 },         -- Red
	energy = { 1.0, 0.85, 0.0 },      -- Yellow
	comboPoints = { 1.0, 0.5, 0.0 },  -- Orange
}

-- Range indicator colors
local RANGE_COLORS = {
	inRange = { 0.0, 0.8, 0.0 },     -- Green - in range
	outOfRange = { 0.8, 0.0, 0.0 },  -- Red - out of range
	noTarget = { 0.3, 0.3, 0.3 },    -- Gray - no target
}

-- Range fallback options (itemID, description, approximate yards)
-- Index 0 = No Range (always grey)
local RANGE_ITEMS = {
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

-- Default settings
local DEFAULT_SETTINGS = {
	globalRangeFallback = 0,  -- Index into RANGE_ITEMS (0 = No Range/Grey)
	spellSettings = {},       -- Per-spell overrides: { [spellID] = { enabled = true, rangeFallback = nil, selfCast = nil } }
	spellOrder = {},          -- Custom spell order: array of spellIDs
	itemSettings = {},        -- Per-item overrides: { [itemKey] = { enabled = true } }
	itemOrder = {},           -- Custom item order: array of item keys
	profiles = {},            -- Named profiles: { ["ProfileName"] = { spellSettings, spellOrder, globalRangeFallback, itemSettings, itemOrder } }
	currentProfile = nil,     -- Name of currently loaded profile
}

-- Settings reference (initialized in init())
local settings = nil

-- Spell catalog: all available spells from spellbook (must be declared before functions that use it)
local spellCatalog = {}  -- { spellID = { name, texture, hasCooldown } }

-- Item catalog: tracked items (trinkets + consumables)
local itemCatalog = {}  -- { itemKey = { name, texture, itemID, slot, isEquipped } }

-- Forward declarations for functions used before definition
local reposition_all
local refresh_options_frame
local rebuild_spell_bars
local rebuild_item_bars
local get_action_slot_for_spell
local get_all_catalog_spells_ordered
local get_ordered_items
local is_spell_enabled

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

local function debug(msg)
	if configs.debugMode then
		print("|cff00ff00GCDIndicator:|r " .. msg)
	end
end

-- Apply timer duration to a bar (reusable helper)
local function applyTimerToBar(bar, durObj)
	if durObj then
		bar:SetTimerDuration(durObj, INTERPOLATION, DIRECTION)
		bar:SetToTargetValue()
	else
		bar:SetValue(0)
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PROFILE MANAGEMENT
-- ═══════════════════════════════════════════════════════════════════════════

-- Deep copy a table
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

-- Save current settings to a named profile
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
	settings.currentProfile = name  -- Track current profile
	
	print("|cff00ff00GCDIndicator:|r Profile '" .. name .. "' saved!")
	return true
end

-- Load a named profile
local function load_profile(name)
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
	settings.currentProfile = name  -- Track current profile
	
	-- Rebuild UI with new settings
	rebuild_spell_bars()  -- This also rebuilds item bars
	refresh_options_frame()
	
	print("|cff00ff00GCDIndicator:|r Profile '" .. name .. "' loaded!")
	return true
end

-- Delete a named profile
delete_profile = function(name)
	if not settings or not name then return false end
	if not settings.profiles or not settings.profiles[name] then return false end
	
	settings.profiles[name] = nil
	-- Clear current profile if it was deleted
	if settings.currentProfile == name then
		settings.currentProfile = nil
	end
	print("|cff00ff00GCDIndicator:|r Profile '" .. name .. "' deleted!")
	return true
end

-- Auto-save current settings to the active profile (called when user makes changes)
local function auto_save_to_profile()
	if not settings or not settings.currentProfile then return end
	if not settings.profiles then settings.profiles = {} end
	
	-- Update the current profile with current settings
	settings.profiles[settings.currentProfile] = {
		globalRangeFallback = settings.globalRangeFallback,
		spellSettings = deepcopy(settings.spellSettings),
		spellOrder = deepcopy(settings.spellOrder),
		itemSettings = deepcopy(settings.itemSettings or {}),
		itemOrder = deepcopy(settings.itemOrder or {}),
	}
end

-- Get list of profile names
local function get_profile_names()
	local names = {}
	if settings and settings.profiles then
		for name in pairs(settings.profiles) do
			table.insert(names, name)
		end
		table.sort(names)
	end
	return names
end

-- Get ordered list of spell IDs for bars (only enabled spells)
local function get_ordered_spells()
	if not settings then return spellBars end
	
	-- Build ordered list from settings, only including enabled spells
	local ordered = {}
	local inOrder = {}
	
	-- First, add spells in saved order (if they still exist and are enabled)
	for _, spellID in ipairs(settings.spellOrder or {}) do
		if trackedSpells[spellID] then
			table.insert(ordered, spellID)
			inOrder[spellID] = true
		end
	end
	
	-- Then add any new spells not in saved order
	for _, spellID in ipairs(spellBars) do
		if not inOrder[spellID] then
			table.insert(ordered, spellID)
		end
	end
	
	return ordered
end

-- Get ALL spells from catalog for options menu (includes disabled spells)
-- Enabled spells come first (in order), then disabled spells at the bottom
get_all_catalog_spells_ordered = function()
	if not settings then return {} end
	
	local enabledOrdered = {}
	local disabledOrdered = {}
	local inOrder = {}
	
	-- First, add spells in saved order (if they exist in catalog)
	for _, spellID in ipairs(settings.spellOrder or {}) do
		if spellCatalog[spellID] then
			inOrder[spellID] = true
			if is_spell_enabled(spellID) then
				table.insert(enabledOrdered, spellID)
			else
				table.insert(disabledOrdered, spellID)
			end
		end
	end
	
	-- Then add any catalog spells not in saved order (sorted by name)
	local unsortedEnabled = {}
	local unsortedDisabled = {}
	for spellID, data in pairs(spellCatalog) do
		if not inOrder[spellID] then
			if is_spell_enabled(spellID) then
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
	
	-- Combine: enabled first, then disabled
	local result = {}
	for _, spellID in ipairs(enabledOrdered) do
		table.insert(result, spellID)
	end
	for _, spellID in ipairs(disabledOrdered) do
		table.insert(result, spellID)
	end
	
	return result
end

-- Save current spell order to settings
local function save_spell_order(orderedList)
	if not settings then return end
	settings.spellOrder = {}
	for i, spellID in ipairs(orderedList) do
		settings.spellOrder[i] = spellID
	end
end

-- Move a spell in the order (direction: -1 = up, 1 = down)
local function move_spell_in_order(spellID, direction)
	-- Use all catalog spells for ordering (includes disabled)
	local ordered = get_all_catalog_spells_ordered()
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
	
	-- Swap
	ordered[currentIndex], ordered[newIndex] = ordered[newIndex], ordered[currentIndex]
	
	-- Save the new order
	save_spell_order(ordered)
	auto_save_to_profile()  -- Save changes to current profile
	
	-- Rebuild bars with new order
	rebuild_spell_bars()
end

-- Move a spell to the bottom of the order
local function move_spell_to_bottom(spellID)
	local ordered = get_all_catalog_spells_ordered()
	local currentIndex = nil
	
	for i, id in ipairs(ordered) do
		if id == spellID then
			currentIndex = i
			break
		end
	end
	
	if not currentIndex or currentIndex == #ordered then return end
	
	-- Remove from current position and add to end
	table.remove(ordered, currentIndex)
	table.insert(ordered, spellID)
	
	-- Save the new order
	save_spell_order(ordered)
	auto_save_to_profile()  -- Save changes to current profile
	
	-- Rebuild bars with new order
	rebuild_spell_bars()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GCD BAR UPDATE
-- ═══════════════════════════════════════════════════════════════════════════

local gcdInitialized = false

local function update_gcd()
	-- Skip first update on load - bar starts white, wait for actual GCD
	if not gcdInitialized then
		if UnitAffectingCombat("player") then
			gcdInitialized = true
		else
			-- Not in combat yet, keep bar white
			main_frame.gcdbar:SetValue(0)
			return
		end
	end
	
	local durObj = C_Spell.GetSpellCooldownDuration(GCD_SPELL_ID)
	applyTimerToBar(main_frame.gcdbar, durObj)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELL COOLDOWN BAR UPDATE
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
		-- Charge spell: GCD timer if charges available, else recharge timer
		durObj = isOnGCD and C_Spell.GetSpellCooldownDuration(GCD_SPELL_ID) 
		                  or C_Spell.GetSpellChargeDuration(spellID)
	else
		-- Normal spell: use spell's cooldown duration
		durObj = C_Spell.GetSpellCooldownDuration(spellID)
	end
	
	applyTimerToBar(data.bar, durObj)
end

local function update_all_spell_bars()
	for spellID in pairs(trackedSpells) do
		update_spell_bar(spellID)
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELL BAR CREATION
-- ═══════════════════════════════════════════════════════════════════════════

local function create_spell_bar(spellID, spellName, texture, actionSlot)
	local barIndex = #spellBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	-- Main container: [Icon] [Cooldown] [Range] with padding
	-- Width = icon(barSize) + gap(2) + cooldown(barSize) + gap(2) + range(barSize) + padding
	local container = CreateFrame("Frame", nil, main_frame)
	container:SetSize((barSize * 3 + 4) + pad * 2, barSize + pad * 2)
	
	-- Background
	local bg = container:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)
	
	-- Icon (leftmost)
	local icon = container:CreateTexture(nil, "ARTWORK")
	icon:SetSize(barSize, barSize)
	icon:SetPoint("LEFT", pad, 0)
	icon:SetTexture(texture)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	
	-- Clipping container for cooldown bar (middle)
	local clipContainer = CreateFrame("Frame", nil, container)
	clipContainer:SetSize(barSize, barSize)
	clipContainer:SetPoint("LEFT", icon, "RIGHT", 2, 0)
	clipContainer:SetClipsChildren(true)
	
	-- White background (shows when ready/bar is empty)
	local cdBg = clipContainer:CreateTexture(nil, "BACKGROUND")
	cdBg:SetAllPoints()
	cdBg:SetColorTexture(1, 1, 1, 1)  -- White
	
	-- Super wide cooldown bar (black - shows when on cooldown)
	local bar = CreateFrame("StatusBar", nil, clipContainer)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:GetStatusBarTexture():SetHorizTile(false)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	bar:SetSize(10000, barSize)
	bar:SetStatusBarColor(0, 0, 0)  -- Black bar
	bar:SetPoint("LEFT")
	
	-- Range indicator (rightmost, white base + colored overlay)
	local rangeBase = container:CreateTexture(nil, "ARTWORK")
	rangeBase:SetSize(barSize, barSize)
	rangeBase:SetPoint("LEFT", clipContainer, "RIGHT", 2, 0)
	rangeBase:SetColorTexture(1, 1, 1, 1)  -- White base
	
	local rangeOverlay = container:CreateTexture(nil, "OVERLAY")
	rangeOverlay:SetSize(barSize, barSize)
	rangeOverlay:SetPoint("CENTER", rangeBase, "CENTER", 0, 0)
	rangeOverlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
	
	-- Store data (include actionSlot and range indicator for range checking)
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
-- ITEM COOLDOWN BAR CREATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Check if item is enabled in settings
local function is_item_enabled(itemKey)
	if not settings then return true end
	local itemSettings = settings.itemSettings and settings.itemSettings[itemKey]
	if itemSettings and itemSettings.enabled == false then
		return false
	end
	return true  -- Enabled by default
end

local function update_item_bar(itemKey)
	local data = trackedItems[itemKey]
	if not data then return end
	
	-- Always use C_Item.GetItemCooldown - works for all items by ID
	local startTime, duration, enable = C_Item.GetItemCooldown(data.itemID)
	debug("Item " .. itemKey .. " (ID " .. tostring(data.itemID) .. "): start=" .. tostring(startTime) .. " dur=" .. tostring(duration) .. " enable=" .. tostring(enable))
	
	if startTime and startTime > 0 and duration and duration > 1.5 then
		-- Item is on cooldown (ignore GCD-only cooldowns)
		local currentTime = GetTime()
		local remaining = (startTime + duration) - currentTime
		if remaining > 0 then
			-- Store cooldown info for animation
			data.cdStartTime = startTime
			data.cdDuration = duration
			data.bar:SetMinMaxValues(0, duration)
			-- Bar shows remaining time - high value = lots of black (on cooldown)
			-- As remaining decreases, black shrinks from left
			data.bar:SetValue(remaining)
			debug("  -> On cooldown! remaining=" .. remaining)
			return
		end
	end
	
	-- Not on cooldown - show white (ready) - empty bar shows white background
	data.cdStartTime = nil
	data.cdDuration = nil
	data.bar:SetMinMaxValues(0, 1)
	data.bar:SetValue(0)  -- Empty bar = ready (white background shows)
end

local function update_all_item_bars()
	local count = 0
	for itemKey in pairs(trackedItems) do
		count = count + 1
		update_item_bar(itemKey)
	end
	if count > 0 then
		debug("Updated " .. count .. " item bars")
	end
end

-- Animate item cooldown bars (called frequently for smooth animation)
local function animate_item_bars()
	local currentTime = GetTime()
	for itemKey, data in pairs(trackedItems) do
		if data.cdStartTime and data.cdDuration then
			local remaining = (data.cdStartTime + data.cdDuration) - currentTime
			if remaining > 0 then
				-- Bar shows remaining time - shrinks from left as time passes
				-- High value = full black bar (on cooldown)
				-- Low value = mostly white (almost ready)
				data.bar:SetValue(remaining)
			else
				-- Cooldown finished - show ready state
				data.cdStartTime = nil
				data.cdDuration = nil
				data.bar:SetMinMaxValues(0, 1)
				data.bar:SetValue(0)  -- Empty = ready (white background shows)
			end
		end
	end
end

local function create_item_bar(itemKey, itemName, texture, itemID, slot)
	local barIndex = #itemBars + 1
	local barSize = configs.barHeight
	local pad = configs.bgPadding
	
	-- Main container: [Icon] [Cooldown] with padding (no range for items)
	local container = CreateFrame("Frame", nil, main_frame)
	container:SetSize((barSize * 2 + 2) + pad * 2, barSize + pad * 2)
	
	-- Background
	local bg = container:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)
	
	-- Icon (leftmost)
	local icon = container:CreateTexture(nil, "ARTWORK")
	icon:SetSize(barSize, barSize)
	icon:SetPoint("LEFT", pad, 0)
	icon:SetTexture(texture)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	
	-- Clipping container for cooldown bar
	local clipContainer = CreateFrame("Frame", nil, container)
	clipContainer:SetSize(barSize, barSize)
	clipContainer:SetPoint("LEFT", icon, "RIGHT", 2, 0)
	clipContainer:SetClipsChildren(true)
	
	-- White background (shows when ready/bar is empty)
	local barBg = clipContainer:CreateTexture(nil, "BACKGROUND")
	barBg:SetAllPoints()
	barBg:SetColorTexture(1, 1, 1, 1)
	barBg:SetDrawLayer("BACKGROUND", -1)
	
	-- Cooldown bar (fills when on cooldown, same as spell bars)
	local bar = CreateFrame("StatusBar", nil, clipContainer)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:GetStatusBarTexture():SetHorizTile(false)
	bar:SetMinMaxValues(0, 1)
	bar:SetValue(0)
	bar:SetSize(10000, barSize)
	bar:SetStatusBarColor(0, 0, 0)  -- Black bar
	bar:SetPoint("LEFT")
	-- Note: NO ReverseFill - bar fills from left to right like spell bars
	
	-- Store data
	trackedItems[itemKey] = { 
		bar = bar, 
		container = container, 
		itemID = itemID,
		slot = slot,
		name = itemName
	}
	itemBars[barIndex] = itemKey
	
	-- Make sure container is visible
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
-- RANGE INDICATOR UPDATE
-- ═══════════════════════════════════════════════════════════════════════════

-- Get range fallback index for a spell (per-spell or global setting)
-- Returns the index into RANGE_ITEMS, or nil for "No Range"
local function get_range_fallback_index(spellID)
	if not settings then return 0 end  -- Default to No Range
	
	-- Check for per-spell override (rangeFallback can be 0 for "No Range")
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.rangeFallback ~= nil then
		return spellSettings.rangeFallback
	end
	
	-- Fall back to global setting
	return settings.globalRangeFallback or 0
end

-- Check if target is in fallback range using item
-- Returns: true = in range, false = out of range, nil = no range check (always grey)
local function is_in_fallback_range(spellID)
	local rangeIndex = get_range_fallback_index(spellID)
	local item = RANGE_ITEMS[rangeIndex]
	
	-- No Range option (index 0) or no item = always grey
	if not item or not item.id then
		return nil
	end
	
	local result = C_Item.IsItemInRange(item.id, "target")
	return result == true
end

-- Check if spell is enabled in settings
is_spell_enabled = function(spellID)
	if not settings then return true end
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.enabled == false then
		return false
	end
	return true
end

-- Check if spell is marked as self-cast (always gray)
-- Only returns true if explicitly set to true (not auto-detected if user set to false)
local function is_spell_self_cast(spellID)
	if not settings then return false end
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.selfCast == true then
		return true
	end
	return false
end

-- Auto-detect self-cast spells: if we have a valid attackable target but the spell
-- returns nil for range, it's likely a self-cast spell
-- ONLY auto-detects if user hasn't explicitly set selfCast to false
local function auto_detect_self_cast(spellID, actionSlot)
	if not settings or not actionSlot then return false end
	
	-- Check if user has explicitly set selfCast (true OR false) - respect their choice
	local spellSettings = settings.spellSettings[spellID]
	if spellSettings and spellSettings.selfCast ~= nil then
		-- User has made a choice, don't auto-detect
		return spellSettings.selfCast == true
	end
	
	-- Only auto-detect if we have a valid enemy target (self-cast spells return nil even then)
	if not UnitExists("target") or not UnitCanAttack("player", "target") then
		return false
	end
	
	local inRange = IsActionInRange(actionSlot)
	if inRange == nil then
		-- Spell returns nil even with a valid attackable target = likely self-cast
		-- Auto-mark it in settings (user can override later)
		if not settings.spellSettings[spellID] then
			settings.spellSettings[spellID] = {}
		end
		settings.spellSettings[spellID].selfCast = true
		local spellName = C_Spell.GetSpellName(spellID) or spellID
		debug("Auto-detected self-cast: " .. spellName)
		return true
	end
	return false
end

-- Check if spell has an explicit range override set
local function has_range_override(spellID)
	if not settings then return false end
	local spellSettings = settings.spellSettings[spellID]
	-- rangeFallback being explicitly set (including 0 for "No Range") means override
	return spellSettings and spellSettings.rangeFallback ~= nil
end

-- Check if spell has native range enabled in settings
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
			
			-- Check if spell is marked as self-cast (always gray)
			if is_spell_self_cast(spellID) then
				overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
			elseif not UnitExists("target") then
				-- No target - show gray
				overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
			else
				-- Check if user has set an explicit range override
				local useOverride = has_range_override(spellID)
				
				if useOverride then
					-- User override - use their fallback setting instead of native range
					local fallbackResult = is_in_fallback_range(spellID)
					if fallbackResult == nil then
						-- "No Range" option selected - always grey
						overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
					elseif fallbackResult then
						overlay:SetColorTexture(RANGE_COLORS.inRange[1], RANGE_COLORS.inRange[2], RANGE_COLORS.inRange[3], 1)
					else
						overlay:SetColorTexture(RANGE_COLORS.outOfRange[1], RANGE_COLORS.outOfRange[2], RANGE_COLORS.outOfRange[3], 1)
					end
				elseif has_native_range_setting(spellID) then
					-- Spell marked as having native range - use IsActionInRange
					local inRange
					if actionSlot then
						inRange = IsActionInRange(actionSlot)
					end
					
					if inRange == true then
						overlay:SetColorTexture(RANGE_COLORS.inRange[1], RANGE_COLORS.inRange[2], RANGE_COLORS.inRange[3], 1)
					elseif inRange == false then
						overlay:SetColorTexture(RANGE_COLORS.outOfRange[1], RANGE_COLORS.outOfRange[2], RANGE_COLORS.outOfRange[3], 1)
					else
						-- Native range setting but IsActionInRange returned nil - show gray
						overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
					end
				else
					-- No native range - use fallback
					if auto_detect_self_cast(spellID, actionSlot) then
						overlay:SetColorTexture(RANGE_COLORS.noTarget[1], RANGE_COLORS.noTarget[2], RANGE_COLORS.noTarget[3], 1)
					else
						-- Use global fallback range setting
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

-- Store reference for access from options callbacks
main_frame.UpdateRangeIndicators = update_range_indicators

-- ═══════════════════════════════════════════════════════════════════════════
-- RESOURCE BAR CREATION & UPDATE
-- ═══════════════════════════════════════════════════════════════════════════

local function create_resource_bar(name, color)
	local barSize = configs.barHeight
	local barWidth = 200
	local pad = configs.bgPadding
	
	-- Main container (includes padding)
	local container = CreateFrame("Frame", nil, main_frame)
	container:SetSize(barWidth + pad * 2, barSize + pad * 2)
	
	-- Background (fills container with padding)
	local bg = container:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 1)
	
	-- Status bar (inset by padding)
	local bar = CreateFrame("StatusBar", nil, container)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:SetMinMaxValues(0, 100)
	bar:SetValue(0)
	bar:SetPoint("TOPLEFT", pad, -pad)
	bar:SetPoint("BOTTOMRIGHT", -pad, pad)
	bar:SetStatusBarColor(color[1], color[2], color[3])
	
	-- Separator overlay frame (higher strata so separators appear on top)
	local separatorFrame = CreateFrame("Frame", nil, container)
	separatorFrame:SetPoint("TOPLEFT", pad, -pad)
	separatorFrame:SetPoint("BOTTOMRIGHT", -pad, pad)
	separatorFrame:SetFrameLevel(container:GetFrameLevel() + 10)
	
	-- Hide until positioned
	container:Hide()
	
	return { bar = bar, container = container, separatorFrame = separatorFrame }
end

-- Secret-safe resource bar updates
-- Key: SetMinMaxValues with actual max, then SetValue with secret value directly (no arithmetic!)
-- Use tonumber() to safely handle secret values from UnitPowerMax/UnitHealthMax
local function update_health_bar()
	if not resourceBars.health then return end
	local bar = resourceBars.health.bar
	local rawMax = UnitHealthMax("player")
	local max = tonumber(rawMax) or 100000  -- Health can be very high
	if max > 0 then
		bar:SetMinMaxValues(0, max)
		bar:SetValue(UnitHealth("player"))  -- Secret value passed directly
	end
end

local function update_rage_bar()
	if not resourceBars.rage then return end
	local bar = resourceBars.rage.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Rage)
	local max = tonumber(rawMax) or 100  -- Rage is typically 100
	if max > 0 then
		bar:SetMinMaxValues(0, max)
		bar:SetValue(UnitPower("player", Enum.PowerType.Rage))  -- Secret value passed directly
		resourceBars.rage.container:Show()
	else
		resourceBars.rage.container:Hide()
	end
end

local function update_energy_bar()
	if not resourceBars.energy then return end
	local bar = resourceBars.energy.bar
	local rawMax = UnitPowerMax("player", Enum.PowerType.Energy)
	local max = tonumber(rawMax) or 100  -- Energy is typically 100
	if max > 0 then
		bar:SetMinMaxValues(0, max)
		bar:SetValue(UnitPower("player", Enum.PowerType.Energy))  -- Secret value passed directly
		resourceBars.energy.container:Show()
	else
		resourceBars.energy.container:Hide()
	end
end

local function update_combo_points_bar()
	if not resourceBars.comboPoints then return end
	local data = resourceBars.comboPoints
	local bar = data.bar
	-- Combo points max can be 5-8 depending on talents
	-- UnitPowerMax may return secret value, so use tonumber() for safe fallback
	local rawMax = UnitPowerMax("player", Enum.PowerType.ComboPoints)
	local max = tonumber(rawMax) or 8  -- Default to 8 to handle all talent cases
	if max > 0 then
		bar:SetMinMaxValues(0, max)
		bar:SetValue(UnitPower("player", Enum.PowerType.ComboPoints))  -- Secret value passed directly
		
		-- Resize bar: 8px per segment + 2px per separator
		local segmentWidth = 8
		local separatorWidth = 2
		local numSeparators = max - 1
		local barWidth = (max * segmentWidth) + (numSeparators * separatorWidth)
		local pad = configs.bgPadding
		data.container:SetWidth(barWidth + pad * 2)
		
		-- Update separators based on current max
		if data.separators and data.separatorFrame then
			for i, sep in ipairs(data.separators) do
				if i < max then
					-- Position after segment i: (i segments * segmentWidth) + (i-1 separators * separatorWidth)
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

-- ═══════════════════════════════════════════════════════════════════════════
-- STANCE/FORM INDICATOR
-- ═══════════════════════════════════════════════════════════════════════════

-- Form colors (Druid forms as example, can be customized)
local FORM_COLORS = {
	[0] = { 0.5, 0.5, 0.5 },   -- No form (gray)
	[1] = { 0.6, 0.4, 0.2 },   -- Bear Form (brown)
	[2] = { 1.0, 0.6, 0.2 },   -- Cat Form (orange)
	[3] = { 0.3, 0.6, 1.0 },   -- Travel Form (blue)
	[4] = { 0.2, 0.8, 0.4 },   -- Moonkin Form (green)
	[5] = { 0.8, 0.8, 1.0 },   -- Flight Form (light blue)
	default = { 0.7, 0.7, 0.7 },  -- Unknown form (light gray)
}

local function update_stance_indicator()
	if not main_frame.stanceIndicator then return end
	
	local formIndex = GetShapeshiftForm() or 0
	local color = FORM_COLORS[formIndex] or FORM_COLORS.default
	main_frame.stanceIndicator:SetColorTexture(color[1], color[2], color[3], 1)
end

-- Count visible resource bars (for positioning)
local function count_visible_resource_bars()
	local count = 0
	-- Health always visible
	count = count + 1
	-- Rage visible if player has rage
	local rageMax = tonumber(UnitPowerMax("player", Enum.PowerType.Rage)) or 0
	if rageMax > 0 then count = count + 1 end
	-- Energy visible if player has energy
	local energyMax = tonumber(UnitPowerMax("player", Enum.PowerType.Energy)) or 0
	if energyMax > 0 then count = count + 1 end
	-- Combo points visible if player has combo points
	local cpMax = tonumber(UnitPowerMax("player", Enum.PowerType.ComboPoints)) or 0
	if cpMax > 0 then count = count + 1 end
	return count
end

reposition_all = function()
	local barSize = configs.barHeight
	local spacing = configs.barSpacing
	local pad = configs.bgPadding
	
	-- Container heights include padding
	local resourceBarHeight = barSize + pad * 2
	local gcdContainerHeight = configs.size + pad * 2
	local spellBarHeight = barSize + pad * 2
	
	-- 1. Position resource bars at the top (starting at anchor)
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
	
	-- 2. Position GCD/Combat indicators below resource bars
	main_frame.gcdcontainer:ClearAllPoints()
	main_frame.gcdcontainer:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, yOffset)
	yOffset = yOffset - gcdContainerHeight - spacing
	
	-- 3. Position spell cooldown bars below GCD/Combat (using custom order)
	local orderedSpells = get_ordered_spells()
	for i, spellID in ipairs(orderedSpells) do
		local data = trackedSpells[spellID]
		if data and data.container then
			data.container:ClearAllPoints()
			data.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, yOffset)
			yOffset = yOffset - spellBarHeight - spacing
		end
	end
	
	-- 4. Position item cooldown bars below spell bars
	local orderedItems = get_ordered_items()
	for i, itemKey in ipairs(orderedItems) do
		local data = trackedItems[itemKey]
		if data and data.container then
			data.container:ClearAllPoints()
			data.container:SetPoint("TOPLEFT", main_frame.anchor, "TOPLEFT", 0, yOffset)
			data.container:Show()
			yOffset = yOffset - spellBarHeight - spacing
		end
	end
	
	-- Update resource values and stance
	update_all_resources()
	update_stance_indicator()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELLBOOK SCANNING
-- ═══════════════════════════════════════════════════════════════════════════

local function scan_spellbook()
	wipe(spellCatalog)
	
	debug("Scanning spellbook...")
	
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
								-- Get the override/talented version of the spell
								local spellID = C_Spell.GetOverrideSpell(baseSpellID) or baseSpellID
								
								-- Check if spell has a cooldown (not just GCD)
								local cdInfo = C_Spell.GetSpellCooldown(spellID)
								if cdInfo and spellID ~= GCD_SPELL_ID then
									local spellName = C_Spell.GetSpellName(spellID)
									local texture = C_Spell.GetSpellTexture(spellID)
									if spellName and texture and not spellCatalog[spellID] then
										spellCatalog[spellID] = {
											name = spellName,
											texture = texture,
											spellID = spellID
										}
										debug("  Found: " .. spellName .. " (override of " .. baseSpellID .. ")")
									end
								end
							end
						end
					end
				end
			end
		end
	end
	
	debug("Spellbook scan complete: " .. (function() local c=0 for _ in pairs(spellCatalog) do c=c+1 end return c end)() .. " spells")
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ITEM SCANNING
-- ═══════════════════════════════════════════════════════════════════════════

-- Helper to add an item to the catalog (handles async item info loading)
local function add_item_to_catalog(itemID, key, slot, isEquipped, defaultName)
	if not itemID then return false end
	
	-- Request item info (may need to be loaded from server)
	local itemName, _, _, _, _, _, _, _, _, texture = C_Item.GetItemInfo(itemID)
	
	-- If item info not loaded yet, try icon directly
	if not texture then
		texture = C_Item.GetItemIconByID(itemID)
	end
	
	-- Last resort: use a default question mark icon
	if not texture then
		texture = "Interface\\Icons\\INV_Misc_QuestionMark"
	end
	
	-- Use default name if we have one and item info isn't loaded
	if not itemName and defaultName then
		itemName = defaultName
	end
	
	-- Always add with at least a placeholder
	itemCatalog[key] = {
		name = itemName or ("Item " .. itemID),
		texture = texture,
		itemID = itemID,
		slot = slot,
		isEquipped = isEquipped,
		itemKey = key
	}
	debug("  Added item: " .. (itemName or key) .. " (ID: " .. itemID .. ")")
	return true
end

-- Scan all action bars for items (trinkets, potions, etc.)
local function scan_action_bars_for_items()
	wipe(actionBarItems)
	
	-- Scan all action bar slots (1-120 covers all bars)
	for slot = 1, 120 do
		local actionType, id = GetActionInfo(slot)
		if actionType == "item" and id then
			actionBarItems[id] = true
			debug("  Found item on action bar: " .. id)
		end
	end
end

local function scan_items()
	wipe(itemCatalog)
	
	debug("Scanning items...")
	
	-- First, scan action bars to find items placed there
	scan_action_bars_for_items()
	
	-- Scan equipped trinkets (slots 13 and 14)
	for key, info in pairs(TRACKED_ITEM_TYPES) do
		local itemID = GetInventoryItemID("player", info.slot)
		if itemID then
			-- Request item info to cache it
			C_Item.RequestLoadItemDataByID(itemID)
			add_item_to_catalog(itemID, key, info.slot, true, info.name)
		end
	end
	
	-- Scan for items on action bars
	for itemID in pairs(actionBarItems) do
		-- Skip if it's already added as a trinket
		local isTrinket = false
		for _, data in pairs(itemCatalog) do
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
	
	-- Scan bags for known consumables (as backup)
	for itemID, defaultName in pairs(CONSUMABLE_ITEM_IDS) do
		-- Skip if already found on action bar
		local alreadyFound = false
		for _, data in pairs(itemCatalog) do
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
	
	local itemCount = 0
	for _ in pairs(itemCatalog) do itemCount = itemCount + 1 end
	debug("Item scan complete: " .. itemCount .. " items")
	
	-- Schedule a delayed rescan to pick up async item info
	C_Timer.After(0.5, function()
		-- Update names and icons for items that didn't have them yet
		local needsRebuild = false
		for key, data in pairs(itemCatalog) do
			local newName, _, _, _, _, _, _, _, _, newTexture = C_Item.GetItemInfo(data.itemID)
			
			-- Update name if it was a placeholder
			if data.name:match("^Item %d+$") or data.name:match("^Trinket %d$") then
				if newName and newName ~= data.name then
					data.name = newName
					needsRebuild = true
					debug("  Updated item name: " .. newName)
				end
			end
			
			-- Update texture if it was a placeholder
			if data.texture == "Interface\\Icons\\INV_Misc_QuestionMark" and newTexture then
				data.texture = newTexture
				needsRebuild = true
				debug("  Updated item icon for: " .. data.name)
			end
		end
		if needsRebuild then
			rebuild_item_bars()
			reposition_all()
		end
	end)
end

-- Get ordered list of item keys for bars (only enabled items)
get_ordered_items = function()
	if not settings then return {} end
	
	local ordered = {}
	local inOrder = {}
	
	-- First, add items in saved order
	for _, itemKey in ipairs(settings.itemOrder or {}) do
		if itemCatalog[itemKey] and is_item_enabled(itemKey) then
			table.insert(ordered, itemKey)
			inOrder[itemKey] = true
		end
	end
	
	-- Then add any new items not in saved order
	for itemKey in pairs(itemCatalog) do
		if not inOrder[itemKey] and is_item_enabled(itemKey) then
			table.insert(ordered, itemKey)
		end
	end
	
	return ordered
end

-- Get ALL items from catalog for options menu (includes disabled items)
local function get_all_catalog_items_ordered()
	if not settings then return {} end
	
	local enabledOrdered = {}
	local disabledOrdered = {}
	local inOrder = {}
	
	-- First, add items in saved order
	for _, itemKey in ipairs(settings.itemOrder or {}) do
		if itemCatalog[itemKey] then
			inOrder[itemKey] = true
			if is_item_enabled(itemKey) then
				table.insert(enabledOrdered, itemKey)
			else
				table.insert(disabledOrdered, itemKey)
			end
		end
	end
	
	-- Then add catalog items not in saved order
	local unsortedEnabled = {}
	local unsortedDisabled = {}
	for itemKey, data in pairs(itemCatalog) do
		if not inOrder[itemKey] then
			if is_item_enabled(itemKey) then
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
	
	-- Combine: enabled first, then disabled
	local result = {}
	for _, itemKey in ipairs(enabledOrdered) do
		table.insert(result, itemKey)
	end
	for _, itemKey in ipairs(disabledOrdered) do
		table.insert(result, itemKey)
	end
	
	return result
end

-- Save current item order to settings
local function save_item_order(orderedList)
	if not settings then return end
	settings.itemOrder = {}
	for i, itemKey in ipairs(orderedList) do
		settings.itemOrder[i] = itemKey
	end
end

-- Move an item in the order (direction: -1 = up, 1 = down)
local function move_item_in_order(itemKey, direction)
	local ordered = get_all_catalog_items_ordered()
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
	
	-- Swap
	ordered[currentIndex], ordered[newIndex] = ordered[newIndex], ordered[currentIndex]
	
	-- Save the new order
	save_item_order(ordered)
	auto_save_to_profile()  -- Save changes to current profile
	
	-- Rebuild bars with new order
	rebuild_item_bars()
	reposition_all()
end

-- Move an item to the bottom of the order
local function move_item_to_bottom(itemKey)
	local ordered = get_all_catalog_items_ordered()
	local currentIndex = nil
	
	for i, key in ipairs(ordered) do
		if key == itemKey then
			currentIndex = i
			break
		end
	end
	
	if not currentIndex or currentIndex == #ordered then return end
	
	-- Remove from current position and add to end
	table.remove(ordered, currentIndex)
	table.insert(ordered, itemKey)
	
	-- Save the new order
	save_item_order(ordered)
	auto_save_to_profile()  -- Save changes to current profile
	
	-- Rebuild bars with new order
	rebuild_item_bars()
	reposition_all()
end

rebuild_item_bars = function()
	clear_item_bars()
	
	-- Get ordered list of items (only enabled items)
	local orderedItems = get_ordered_items()
	
	-- Create bars for enabled items only
	for _, itemKey in ipairs(orderedItems) do
		local catalogEntry = itemCatalog[itemKey]
		if catalogEntry then
			create_item_bar(itemKey, catalogEntry.name, catalogEntry.texture, catalogEntry.itemID, catalogEntry.slot)
			debug("  Item bar created: " .. catalogEntry.name .. " (ID: " .. tostring(catalogEntry.itemID) .. ")")
		end
	end
	
	-- Debug: list all tracked items
	local trackedCount = 0
	for itemKey, data in pairs(trackedItems) do
		trackedCount = trackedCount + 1
		debug("  Tracked item: " .. itemKey .. " -> bar=" .. tostring(data.bar) .. ", itemID=" .. tostring(data.itemID))
	end
	debug("Created " .. #itemBars .. " item bars, " .. trackedCount .. " in trackedItems")
end

-- Build action slot lookup for range checking
get_action_slot_for_spell = function(spellID)
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

rebuild_spell_bars = function()
	clear_spell_bars()
	
	-- Get ordered list of spells
	local orderedSpells = get_ordered_spells()
	
	-- Create bars for enabled spells only
	for _, spellID in ipairs(orderedSpells) do
		local catalogEntry = spellCatalog[spellID]
		if catalogEntry and is_spell_enabled(spellID) then
			local actionSlot = get_action_slot_for_spell(spellID)
			create_spell_bar(spellID, catalogEntry.name, catalogEntry.texture, actionSlot)
			debug("  Bar created: " .. catalogEntry.name)
		end
	end
	
	-- Add any new spells from catalog that aren't in the order yet
	for spellID, catalogEntry in pairs(spellCatalog) do
		if not trackedSpells[spellID] and is_spell_enabled(spellID) then
			local actionSlot = get_action_slot_for_spell(spellID)
			create_spell_bar(spellID, catalogEntry.name, catalogEntry.texture, actionSlot)
			debug("  Bar created (new): " .. catalogEntry.name)
		end
	end
	
	debug("Created " .. #spellBars .. " spell bars")
	
	-- Also rebuild item bars
	rebuild_item_bars()
	update_all_spell_bars()
	update_range_indicators()
	reposition_all()
end

local function scan_action_bars()
	-- Full rescan: spellbook + items + rebuild bars
	scan_spellbook()
	scan_items()
	rebuild_spell_bars()  -- This also calls rebuild_item_bars()
end

-- Throttled scan - prevents multiple rapid rescans
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
		-- Rescan items when inventory changes
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
		-- ACTIONBAR_SLOT_CHANGED, UPDATE_MACROS, SPELLS_CHANGED
		schedule_scan(0.3)
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- INITIALIZATION
-- ═══════════════════════════════════════════════════════════════════════════

local function init()
	-- Initialize settings from SavedVariables or use defaults
	if not GCDIndicator_Settings then
		GCDIndicator_Settings = {}
	end
	-- Merge defaults with saved settings
	settings = GCDIndicator_Settings
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
	
	-- Debug: Show how many item settings were loaded
	local savedItemCount = 0
	local disabledItemCount = 0
	for key, itemSetting in pairs(settings.itemSettings) do
		savedItemCount = savedItemCount + 1
		if itemSetting.enabled == false then
			disabledItemCount = disabledItemCount + 1
		end
	end
	if savedItemCount > 0 then
		debug("Loaded " .. savedItemCount .. " item settings (" .. disabledItemCount .. " disabled)")
	end
	
	main_frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 0)
	main_frame:SetSize(1, 1)
	
	local pad = configs.bgPadding
	
	-- Anchor frame - this is the reference point for all positioning
	local anchor = CreateFrame("Frame", nil, main_frame)
	anchor:SetSize(1, 1)
	anchor:SetPoint("CENTER", UIParent, "CENTER", configs.xpoint, configs.ypoint)
	main_frame.anchor = anchor
	
	-- Separator size between indicators
	local sepSize = 2
	
	-- Stance + GCD + Combat container (3 indicators + 2 separators + padding)
	-- Layout: [pad][Stance][sep][GCD][sep][Combat][pad]
	local containerWidth = (configs.size * 3) + (sepSize * 2) + (pad * 2)
	local gcdCombatContainer = CreateFrame("Frame", nil, main_frame)
	gcdCombatContainer:SetSize(containerWidth, configs.size + pad * 2)
	main_frame.gcdcontainer = gcdCombatContainer  -- Used for positioning reference
	
	-- Background for all indicators
	local gcdCombatBg = gcdCombatContainer:CreateTexture(nil, "BACKGROUND")
	gcdCombatBg:SetAllPoints()
	gcdCombatBg:SetColorTexture(0, 0, 0, 1)
	
	-- Stance indicator (leftmost)
	local stanceIndicator = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	stanceIndicator:SetSize(configs.size, configs.size)
	stanceIndicator:SetPoint("LEFT", pad, 0)
	stanceIndicator:SetColorTexture(0.5, 0.5, 0.5, 1)  -- Gray default (no form)
	main_frame.stanceIndicator = stanceIndicator
	
	-- Separator 1 (between Stance and GCD)
	local sep1 = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	sep1:SetSize(sepSize, configs.size)
	sep1:SetPoint("LEFT", stanceIndicator, "RIGHT", 0, 0)
	sep1:SetColorTexture(0, 0, 0, 1)  -- Black separator
	
	-- GCD clipping container
	local gcdClip = CreateFrame("Frame", nil, gcdCombatContainer)
	gcdClip:SetSize(configs.size, configs.size)
	gcdClip:SetPoint("LEFT", sep1, "RIGHT", 0, 0)
	gcdClip:SetClipsChildren(true)
	
	-- White background for GCD (shows when ready/bar is empty)
	local gcdBg = gcdClip:CreateTexture(nil, "BACKGROUND")
	gcdBg:SetAllPoints()
	gcdBg:SetColorTexture(1, 1, 1, 1)  -- White
	
	-- GCD bar (super wide, black - shows when on GCD)
	local gcdbar = CreateFrame("StatusBar", nil, gcdClip)
	gcdbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	gcdbar:GetStatusBarTexture():SetHorizTile(false)
	gcdbar:SetMinMaxValues(0, 1)
	gcdbar:SetValue(0)
	gcdbar:SetSize(10000, configs.size)
	gcdbar:SetStatusBarColor(0, 0, 0)  -- Black bar
	gcdbar:SetPoint("LEFT")
	main_frame.gcdbar = gcdbar
	
	-- Separator 2 (between GCD and Combat)
	local sep2 = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	sep2:SetSize(sepSize, configs.size)
	sep2:SetPoint("LEFT", gcdClip, "RIGHT", 0, 0)
	sep2:SetColorTexture(0, 0, 0, 1)  -- Black separator
	
	-- Combat indicator (rightmost)
	local combatbar = CreateFrame("StatusBar", nil, gcdCombatContainer)
	combatbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	combatbar:GetStatusBarTexture():SetHorizTile(false)
	combatbar:SetMinMaxValues(0, 100)
	combatbar:SetValue(100)
	combatbar:SetSize(configs.size, configs.size)
	combatbar:SetStatusBarColor(0, 0, 0)
	combatbar:SetPoint("LEFT", sep2, "RIGHT", 0, 0)
	main_frame.combatbar = combatbar
	
	-- Load saved position (apply to anchor)
	GCDIndicator_Positions = GCDIndicator_Positions or {}
	local libGCDI = LibStub and LibStub:GetLibrary("LibGCDI", true)
	if libGCDI then
		libGCDI.load_position(anchor, "GCDIndicator", GCDIndicator_Positions)
	end
	
	-- Create resource bars (will be positioned after spell bars are scanned)
	local barSize = configs.barHeight
	resourceBars.health = create_resource_bar("health", RESOURCE_COLORS.health)
	resourceBars.rage = create_resource_bar("rage", RESOURCE_COLORS.rage)
	resourceBars.energy = create_resource_bar("energy", RESOURCE_COLORS.energy)
	resourceBars.comboPoints = create_resource_bar("comboPoints", RESOURCE_COLORS.comboPoints)
	
	-- Add separators to combo points bar (max 7 separators for up to 8 combo points)
	-- Use separatorFrame so they appear above the StatusBar
	resourceBars.comboPoints.separators = {}
	local sepFrame = resourceBars.comboPoints.separatorFrame
	for i = 1, 7 do
		local sep = sepFrame:CreateTexture(nil, "OVERLAY")
		sep:SetSize(2, barSize)
		sep:SetColorTexture(0, 0, 0, 1)
		sep:Hide()
		resourceBars.comboPoints.separators[i] = sep
	end
	
	-- Show and position resource bars immediately (don't wait for scan)
	-- This ensures they're visible even if the initial scan has issues
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
	
	-- Register events
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
	-- Resource events (unit-filtered for efficiency)
	main_frame:RegisterUnitEvent("UNIT_HEALTH", "player")
	main_frame:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
	main_frame:RegisterUnitEvent("UNIT_POWER_FREQUENT", "player")
	main_frame:RegisterUnitEvent("UNIT_MAXPOWER", "player")
	main_frame:SetScript("OnEvent", on_event)

	-- Set initial combat state
	if UnitAffectingCombat("player") then
		combatbar:SetStatusBarColor(1, 0, 0)
	end
	
	-- Initial scan - this will also position and update resource bars
	schedule_scan(0.1)
	C_Timer.After(1.0, function()
		if #spellBars == 0 then
			scan_action_bars()
		end
	end)
	
	-- GCD bar is already initialized to value 0 (white/ready) on creation
	-- Don't call update_gcd() here as it may trigger timer animation
	
	-- Auto-load last used profile if one was saved
	if settings.currentProfile and settings.profiles and settings.profiles[settings.currentProfile] then
		C_Timer.After(0.5, function()
			local profile = settings.profiles[settings.currentProfile]
			settings.globalRangeFallback = profile.globalRangeFallback or 0
			settings.spellSettings = deepcopy(profile.spellSettings or {})
			settings.spellOrder = deepcopy(profile.spellOrder or {})
			settings.itemSettings = deepcopy(profile.itemSettings or {})
			settings.itemOrder = deepcopy(profile.itemOrder or {})
			rebuild_spell_bars()  -- This also rebuilds item bars
			print("|cff00ff00GCDIndicator:|r Profile '" .. settings.currentProfile .. "' loaded")
		end)
	end
	
	-- Range indicator ticker (updates every 0.1s for responsive range checking)
	C_Timer.NewTicker(0.1, update_range_indicators)
	
	-- Item cooldown animation ticker (updates every 0.05s for smooth animation)
	C_Timer.NewTicker(0.05, animate_item_bars)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- OPTIONS FRAME
-- ═══════════════════════════════════════════════════════════════════════════

local optionsFrame = nil
local spellRows = {}
local itemRows = {}
local optionsElements = {}  -- All dynamically created elements to clean up
local currentTab = "spells"  -- "spells" or "items"

-- Build ordered list of range options for dropdowns (from 0-indexed RANGE_ITEMS)
local function get_range_options_list()
	local list = {}
	for i = 0, 9 do
		if RANGE_ITEMS[i] then
			table.insert(list, { index = i, name = RANGE_ITEMS[i].name })
		end
	end
	return list
end

local function create_range_dropdown(parent, width, selectedIndex, onChange)
	local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
	dropdown:SetPoint("LEFT")
	UIDropDownMenu_SetWidth(dropdown, width)
	
	local options = get_range_options_list()
	
	local function initialize(self, level)
		for listIdx, opt in ipairs(options) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = opt.name
			info.value = opt.index  -- Actual RANGE_ITEMS index (0-9)
			info.checked = (opt.index == selectedIndex)
			info.func = function()
				selectedIndex = opt.index
				UIDropDownMenu_SetSelectedID(dropdown, listIdx)
				if onChange then onChange(opt.index) end
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end
	
	UIDropDownMenu_Initialize(dropdown, initialize)
	
	-- Find which list position corresponds to the selected index
	for listIdx, opt in ipairs(options) do
		if opt.index == selectedIndex then
			UIDropDownMenu_SetSelectedID(dropdown, listIdx)
			break
		end
	end
	
	return dropdown
end

-- Generic dropdown for other uses
local function create_dropdown(parent, width, items, selectedIndex, onChange)
	local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
	dropdown:SetPoint("LEFT")
	UIDropDownMenu_SetWidth(dropdown, width)
	
	local function initialize(self, level)
		for i, item in ipairs(items) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = item.name or item
			info.value = i
			info.checked = (i == selectedIndex)
			info.func = function()
				selectedIndex = i
				UIDropDownMenu_SetSelectedID(dropdown, i)
				if onChange then onChange(i) end
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end
	
	UIDropDownMenu_Initialize(dropdown, initialize)
	UIDropDownMenu_SetSelectedID(dropdown, selectedIndex or 1)
	
	return dropdown
end

-- Refresh the spells tab content
local function refresh_spells_tab()
	if not optionsFrame or not optionsFrame.spellsScrollChild then return end
	
	-- Clear existing spell rows
	for _, row in pairs(spellRows) do
		row:Hide()
		row:SetParent(nil)
	end
	wipe(spellRows)
	
	local scrollChild = optionsFrame.spellsScrollChild
	local yOffset = -10
	
	-- Global range fallback (compact - label and dropdown on same line)
	local globalLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	globalLabel:SetPoint("TOPLEFT", 10, yOffset)
	globalLabel:SetText("Global Range:")
	
	local globalDropdown = create_range_dropdown(scrollChild, 130, settings.globalRangeFallback or 0, function(index)
		settings.globalRangeFallback = index
		main_frame.UpdateRangeIndicators()  -- Apply immediately
	end)
	globalDropdown:SetPoint("LEFT", globalLabel, "RIGHT", -5, -2)
	yOffset = yOffset - 35
	
	-- Column headers
	local enabledHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	enabledHeader:SetPoint("TOPLEFT", 10, yOffset)
	enabledHeader:SetText("On")
	
	local selfCastHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	selfCastHeader:SetPoint("TOPLEFT", 38, yOffset)
	selfCastHeader:SetText("Self")
	
	local spellNameHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	spellNameHeader:SetPoint("TOPLEFT", 70, yOffset)
	spellNameHeader:SetText("Spell")
	
	local nativeHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	nativeHeader:SetPoint("TOPLEFT", 170, yOffset)
	nativeHeader:SetText("|cff00ff00N|r")  -- "N" for Native column
	
	local rangeHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	rangeHeader:SetPoint("TOPLEFT", 200, yOffset)
	rangeHeader:SetText("Range Override")
	
	local orderHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	orderHeader:SetPoint("TOPLEFT", 385, yOffset)
	orderHeader:SetText("Order")
	yOffset = yOffset - 20
	
	-- Create rows for each spell in catalog (using custom order)
	local orderedSpells = get_all_catalog_spells_ordered()
	local disabledSectionStarted = false
	
	for i, spellID in ipairs(orderedSpells) do
		local catalogEntry = spellCatalog[spellID]
		if not catalogEntry then
			break
		end
		
		local spellName = catalogEntry.name
		local texture = catalogEntry.texture
		
		-- Ensure spell has settings entry
		if not settings.spellSettings[spellID] then
			settings.spellSettings[spellID] = { enabled = true, rangeFallback = nil, selfCast = false, hasNativeRange = nil }
		end
		local spellSettings = settings.spellSettings[spellID]
		
		-- Add separator before first disabled spell
		if not is_spell_enabled(spellID) and not disabledSectionStarted then
			disabledSectionStarted = true
			yOffset = yOffset - 10
			local disabledSep = scrollChild:CreateTexture(nil, "ARTWORK")
			disabledSep:SetColorTexture(0.4, 0.4, 0.4, 1)
			disabledSep:SetSize(450, 1)
			disabledSep:SetPoint("TOPLEFT", 10, yOffset)
			yOffset = yOffset - 5
			
			local disabledLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			disabledLabel:SetPoint("TOPLEFT", 10, yOffset)
			disabledLabel:SetText("|cff888888— Disabled Spells —|r")
			yOffset = yOffset - 18
		end
		
		-- Check if spell has native range detection (and cache the result)
		local spellData = trackedSpells[spellID]
		local actionSlot = spellData and spellData.actionSlot or get_action_slot_for_spell(spellID)
		local hasNativeRange = spellSettings.hasNativeRange
		
		if hasNativeRange == nil and actionSlot and UnitExists("target") then
			local rangeResult = IsActionInRange(actionSlot)
			hasNativeRange = (rangeResult ~= nil)
			spellSettings.hasNativeRange = hasNativeRange
		end
		
		hasNativeRange = hasNativeRange or false
		
		local row = CreateFrame("Frame", nil, scrollChild)
		row:SetSize(470, 30)
		row:SetPoint("TOPLEFT", 10, yOffset)
		
		-- Enabled checkbox
		local checkbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		checkbox:SetSize(24, 24)
		checkbox:SetPoint("LEFT", 0, 0)
		checkbox:SetChecked(spellSettings.enabled ~= false)
		checkbox:SetScript("OnClick", function(self)
			spellSettings.enabled = self:GetChecked()
			auto_save_to_profile()  -- Save changes to current profile
			rebuild_spell_bars()
			refresh_options_frame()
		end)
		
		-- Self-Cast checkbox
		local selfCastCheckbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		selfCastCheckbox:SetSize(24, 24)
		selfCastCheckbox:SetPoint("LEFT", 28, 0)
		selfCastCheckbox:SetChecked(spellSettings.selfCast == true)
		selfCastCheckbox:SetScript("OnClick", function(self)
			spellSettings.selfCast = self:GetChecked()
			auto_save_to_profile()  -- Save changes to current profile
			main_frame.UpdateRangeIndicators()
		end)
		selfCastCheckbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Self-Cast Spell")
			GameTooltip:AddLine("Check if this spell only targets yourself.", 1, 1, 1, true)
			GameTooltip:AddLine("Self-cast spells will always show gray (no range check).", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		selfCastCheckbox:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		
		-- Spell icon
		local icon = row:CreateTexture(nil, "ARTWORK")
		icon:SetSize(20, 20)
		icon:SetPoint("LEFT", 56, 0)
		icon:SetTexture(texture)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		
		-- Spell name
		local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		nameText:SetPoint("LEFT", 80, 0)
		nameText:SetWidth(90)
		nameText:SetJustifyH("LEFT")
		nameText:SetText(spellName)
		
		-- Native range indicator
		local rangeIndicatorText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		rangeIndicatorText:SetPoint("LEFT", 172, 0)
		if spellSettings.hasNativeRange then
			rangeIndicatorText:SetText("|cff00ff00N|r")
		else
			rangeIndicatorText:SetText("|cff888888-|r")
		end
		
		-- Tooltip frame for indicator
		local indicatorTooltip = CreateFrame("Frame", nil, row)
		indicatorTooltip:SetPoint("LEFT", 168, 0)
		indicatorTooltip:SetSize(20, 20)
		indicatorTooltip:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if spellSettings.hasNativeRange then
				GameTooltip:SetText("|cff00ff00Native Range: ON|r")
				GameTooltip:AddLine("This spell uses built-in range checking.", 1, 1, 1, true)
			else
				GameTooltip:SetText("|cff888888Native Range: OFF|r")
				GameTooltip:AddLine("This spell uses fallback range checking.", 1, 1, 1, true)
				GameTooltip:AddLine("Target an enemy and reopen options to auto-detect.", 0.7, 0.7, 0.7, true)
			end
			GameTooltip:Show()
		end)
		indicatorTooltip:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		
		-- Range dropdown
		local rangeDropdown = CreateFrame("Frame", nil, row, "UIDropDownMenuTemplate")
		rangeDropdown:SetPoint("LEFT", 185, 0)
		UIDropDownMenu_SetWidth(rangeDropdown, 120)
		
		local function initSpellRangeDropdown(self, level)
			local info = UIDropDownMenu_CreateInfo()
			
			if spellSettings.hasNativeRange then
				info.text = "|cff00ff00Native|r"
				info.value = -1
				info.checked = (spellSettings.rangeFallback == nil)
				info.func = function()
					spellSettings.rangeFallback = nil
					UIDropDownMenu_SetSelectedID(rangeDropdown, 1)
					main_frame.UpdateRangeIndicators()
				end
				UIDropDownMenu_AddButton(info, level)
			else
				info.text = "Use Global"
				info.value = -1
				info.checked = (spellSettings.rangeFallback == nil)
				info.func = function()
					spellSettings.rangeFallback = nil
					UIDropDownMenu_SetSelectedID(rangeDropdown, 1)
					main_frame.UpdateRangeIndicators()
				end
				UIDropDownMenu_AddButton(info, level)
			end
			
			local options = get_range_options_list()
			for listIdx, opt in ipairs(options) do
				info = UIDropDownMenu_CreateInfo()
				info.text = opt.name
				info.value = opt.index
				info.checked = (spellSettings.rangeFallback == opt.index)
				info.func = function()
					spellSettings.rangeFallback = opt.index
					UIDropDownMenu_SetSelectedID(rangeDropdown, listIdx + 1)
					main_frame.UpdateRangeIndicators()
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end
		
		UIDropDownMenu_Initialize(rangeDropdown, initSpellRangeDropdown)
		
		if spellSettings.rangeFallback == nil then
			UIDropDownMenu_SetSelectedID(rangeDropdown, 1)
		else
			local options = get_range_options_list()
			for listIdx, opt in ipairs(options) do
				if opt.index == spellSettings.rangeFallback then
					UIDropDownMenu_SetSelectedID(rangeDropdown, listIdx + 1)
					break
				end
			end
		end
		
		-- Up/Down/Bottom reorder buttons
		local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		upBtn:SetSize(22, 18)
		upBtn:SetPoint("LEFT", 380, 0)
		upBtn:SetText("Up")
		upBtn:SetNormalFontObject("GameFontNormalSmall")
		upBtn:SetHighlightFontObject("GameFontHighlightSmall")
		upBtn:SetEnabled(i > 1)
		upBtn:SetScript("OnClick", function()
			move_spell_in_order(spellID, -1)
			refresh_options_frame()
		end)
		
		local downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		downBtn:SetSize(22, 18)
		downBtn:SetPoint("LEFT", upBtn, "RIGHT", 2, 0)
		downBtn:SetText("Dn")
		downBtn:SetNormalFontObject("GameFontNormalSmall")
		downBtn:SetHighlightFontObject("GameFontHighlightSmall")
		downBtn:SetEnabled(i < #orderedSpells)
		downBtn:SetScript("OnClick", function()
			move_spell_in_order(spellID, 1)
			refresh_options_frame()
		end)
		
		local bottomBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		bottomBtn:SetSize(24, 18)
		bottomBtn:SetPoint("LEFT", downBtn, "RIGHT", 2, 0)
		bottomBtn:SetText("Bot")
		bottomBtn:SetNormalFontObject("GameFontNormalSmall")
		bottomBtn:SetHighlightFontObject("GameFontHighlightSmall")
		bottomBtn:SetEnabled(i < #orderedSpells)
		bottomBtn:SetScript("OnClick", function()
			move_spell_to_bottom(spellID)
			refresh_options_frame()
		end)
		
		spellRows[i] = row
		yOffset = yOffset - 35
	end
	
	scrollChild:SetHeight(math.abs(yOffset) + 20)
end

-- Refresh the items tab content
local itemsTabElements = {}  -- Track all UI elements for cleanup

local function refresh_items_tab()
	if not optionsFrame or not optionsFrame.itemsScrollChild then return end
	
	-- Clear existing item rows
	for _, row in pairs(itemRows) do
		row:Hide()
		row:SetParent(nil)
	end
	wipe(itemRows)
	
	-- Clear all items tab elements (headers, separators, etc.)
	for _, element in pairs(itemsTabElements) do
		if element.Hide then element:Hide() end
		if element.SetParent then element:SetParent(nil) end
	end
	wipe(itemsTabElements)
	
	local scrollChild = optionsFrame.itemsScrollChild
	local yOffset = -10
	
	-- Helper to track created elements
	local function track(element)
		table.insert(itemsTabElements, element)
		return element
	end
	
	-- Column headers
	local enabledHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	enabledHeader:SetPoint("TOPLEFT", 10, yOffset)
	enabledHeader:SetText("On")
	
	local itemNameHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	itemNameHeader:SetPoint("TOPLEFT", 45, yOffset)
	itemNameHeader:SetText("Item")
	
	local orderHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	orderHeader:SetPoint("TOPLEFT", 320, yOffset)
	orderHeader:SetText("Order")
	yOffset = yOffset - 20
	
	-- Create rows for each item in catalog
	local orderedItems = get_all_catalog_items_ordered()
	local disabledSectionStarted = false
	
	if #orderedItems == 0 then
		-- No items found message
		local noItemsText = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
		noItemsText:SetPoint("TOPLEFT", 10, yOffset)
		noItemsText:SetText("|cff888888No trinkets equipped or consumables in bags.|r")
		yOffset = yOffset - 30
		
		local tipText = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
		tipText:SetPoint("TOPLEFT", 10, yOffset)
		tipText:SetText("Equip trinkets or get consumables to see them here.")
		yOffset = yOffset - 25
	end
	
	for i, itemKey in ipairs(orderedItems) do
		local catalogEntry = itemCatalog[itemKey]
		if not catalogEntry then
			break
		end
		
		local itemName = catalogEntry.name
		local texture = catalogEntry.texture
		
		-- Get existing settings (don't create new entry - it should already exist from is_item_enabled check)
		local itemSettings = settings.itemSettings and settings.itemSettings[itemKey]
		if not itemSettings then
			-- Only create if truly doesn't exist
			if not settings.itemSettings then settings.itemSettings = {} end
			settings.itemSettings[itemKey] = { enabled = true }
			itemSettings = settings.itemSettings[itemKey]
		end
		
		-- Add separator before first disabled item
		if not is_item_enabled(itemKey) and not disabledSectionStarted then
			disabledSectionStarted = true
			yOffset = yOffset - 10
			local disabledSep = track(scrollChild:CreateTexture(nil, "ARTWORK"))
			disabledSep:SetColorTexture(0.4, 0.4, 0.4, 1)
			disabledSep:SetSize(450, 1)
			disabledSep:SetPoint("TOPLEFT", 10, yOffset)
			yOffset = yOffset - 5
			
			local disabledLabel = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
			disabledLabel:SetPoint("TOPLEFT", 10, yOffset)
			disabledLabel:SetText("|cff888888— Disabled Items —|r")
			yOffset = yOffset - 18
		end
		
		local row = CreateFrame("Frame", nil, scrollChild)
		row:SetSize(420, 30)
		row:SetPoint("TOPLEFT", 10, yOffset)
		
		-- Enabled checkbox
		local checkbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		checkbox:SetSize(24, 24)
		checkbox:SetPoint("LEFT", 0, 0)
		checkbox:SetChecked(itemSettings.enabled ~= false)
		checkbox:SetScript("OnClick", function(self)
			itemSettings.enabled = self:GetChecked()
			auto_save_to_profile()  -- Save changes to current profile
			rebuild_item_bars()
			reposition_all()
			refresh_options_frame()
		end)
		
		-- Item icon
		local icon = row:CreateTexture(nil, "ARTWORK")
		icon:SetSize(20, 20)
		icon:SetPoint("LEFT", 28, 0)
		icon:SetTexture(texture)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		
		-- Item name
		local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		nameText:SetPoint("LEFT", 52, 0)
		nameText:SetWidth(250)
		nameText:SetJustifyH("LEFT")
		nameText:SetText(itemName)
		
		-- Item type indicator (trinket vs consumable)
		local typeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		typeText:SetPoint("LEFT", 260, 0)
		if catalogEntry.slot then
			typeText:SetText("|cff00ff00Trinket|r")
		else
			typeText:SetText("|cffffcc00Consumable|r")
		end
		
		-- Up/Down/Bottom reorder buttons
		local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		upBtn:SetSize(22, 18)
		upBtn:SetPoint("LEFT", 315, 0)
		upBtn:SetText("Up")
		upBtn:SetNormalFontObject("GameFontNormalSmall")
		upBtn:SetHighlightFontObject("GameFontHighlightSmall")
		upBtn:SetEnabled(i > 1)
		upBtn:SetScript("OnClick", function()
			move_item_in_order(itemKey, -1)
			refresh_options_frame()
		end)
		
		local downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		downBtn:SetSize(22, 18)
		downBtn:SetPoint("LEFT", upBtn, "RIGHT", 2, 0)
		downBtn:SetText("Dn")
		downBtn:SetNormalFontObject("GameFontNormalSmall")
		downBtn:SetHighlightFontObject("GameFontHighlightSmall")
		downBtn:SetEnabled(i < #orderedItems)
		downBtn:SetScript("OnClick", function()
			move_item_in_order(itemKey, 1)
			refresh_options_frame()
		end)
		
		local bottomBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		bottomBtn:SetSize(24, 18)
		bottomBtn:SetPoint("LEFT", downBtn, "RIGHT", 2, 0)
		bottomBtn:SetText("Bot")
		bottomBtn:SetNormalFontObject("GameFontNormalSmall")
		bottomBtn:SetHighlightFontObject("GameFontHighlightSmall")
		bottomBtn:SetEnabled(i < #orderedItems)
		bottomBtn:SetScript("OnClick", function()
			move_item_to_bottom(itemKey)
			refresh_options_frame()
		end)
		
		itemRows[i] = row
		yOffset = yOffset - 35
	end
	
	scrollChild:SetHeight(math.abs(yOffset) + 20)
end

-- Switch between tabs
local function switch_tab(tabName)
	if not optionsFrame then return end
	currentTab = tabName
	
	-- Update tab button appearance
	if optionsFrame.spellsTabBtn then
		if tabName == "spells" then
			optionsFrame.spellsTabBtn:SetNormalFontObject("GameFontHighlight")
			optionsFrame.spellsTabBtn:GetFontString():SetTextColor(1, 1, 1)
		else
			optionsFrame.spellsTabBtn:SetNormalFontObject("GameFontNormal")
			optionsFrame.spellsTabBtn:GetFontString():SetTextColor(0.7, 0.7, 0.7)
		end
	end
	if optionsFrame.itemsTabBtn then
		if tabName == "items" then
			optionsFrame.itemsTabBtn:SetNormalFontObject("GameFontHighlight")
			optionsFrame.itemsTabBtn:GetFontString():SetTextColor(1, 1, 1)
		else
			optionsFrame.itemsTabBtn:SetNormalFontObject("GameFontNormal")
			optionsFrame.itemsTabBtn:GetFontString():SetTextColor(0.7, 0.7, 0.7)
		end
	end
	
	-- Show/hide scroll frames
	if optionsFrame.spellsScrollFrame then
		optionsFrame.spellsScrollFrame:SetShown(tabName == "spells")
	end
	if optionsFrame.itemsScrollFrame then
		optionsFrame.itemsScrollFrame:SetShown(tabName == "items")
	end
	
	-- Refresh the active tab
	if tabName == "spells" then
		refresh_spells_tab()
	else
		refresh_items_tab()
	end
end

-- Refresh the profiles section (shared between tabs)
local function refresh_profiles_section()
	if not optionsFrame or not optionsFrame.profilesContainer then return end
	
	-- Clear existing profile elements
	for _, element in pairs(optionsElements) do
		if element.Hide then element:Hide() end
		if element.SetParent then element:SetParent(nil) end
	end
	wipe(optionsElements)
	
	local container = optionsFrame.profilesContainer
	
	-- Helper to track created elements
	local function track(element)
		table.insert(optionsElements, element)
		return element
	end
	
	-- Profile dropdown
	local profileNames = get_profile_names()
	local profileDropdown = track(CreateFrame("Frame", nil, container, "UIDropDownMenuTemplate"))
	profileDropdown:SetPoint("TOPLEFT", 0, 0)
	UIDropDownMenu_SetWidth(profileDropdown, 150)
	
	local function initProfileDropdown(self, level)
		local info = UIDropDownMenu_CreateInfo()
		
		info.text = "-- Select Profile --"
		info.value = nil
		info.notCheckable = true
		info.func = function() end
		UIDropDownMenu_AddButton(info, level)
		
		for _, name in ipairs(profileNames) do
			info = UIDropDownMenu_CreateInfo()
			info.text = name
			info.value = name
			info.notCheckable = true
			info.func = function()
				load_profile(name)
				UIDropDownMenu_SetText(profileDropdown, name)
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end
	UIDropDownMenu_Initialize(profileDropdown, initProfileDropdown)
	local currentProfileText = settings.currentProfile or "-- Select Profile --"
	UIDropDownMenu_SetText(profileDropdown, currentProfileText)
	
	-- Save button
	local saveBtn = track(CreateFrame("Button", nil, container, "UIPanelButtonTemplate"))
	saveBtn:SetSize(50, 22)
	saveBtn:SetPoint("LEFT", profileDropdown, "RIGHT", 0, 2)
	saveBtn:SetText("Save")
	saveBtn:SetScript("OnClick", function()
		StaticPopup_Show("GCDI_SAVE_PROFILE")
	end)
	
	-- Delete button
	local deleteBtn = track(CreateFrame("Button", nil, container, "UIPanelButtonTemplate"))
	deleteBtn:SetSize(50, 22)
	deleteBtn:SetPoint("LEFT", saveBtn, "RIGHT", 5, 0)
	deleteBtn:SetText("Del")
	deleteBtn:SetScript("OnClick", function()
		if settings.currentProfile then
			StaticPopup_Show("GCDI_DELETE_PROFILE", settings.currentProfile, nil, settings.currentProfile)
		else
			print("|cffff0000GCDIndicator:|r No profile selected to delete!")
		end
	end)
end

refresh_options_frame = function()
	if not optionsFrame then return end
	if not optionsFrame:IsShown() then return end
	
	-- Refresh profiles section
	refresh_profiles_section()
	
	-- Refresh the active tab
	if currentTab == "spells" then
		refresh_spells_tab()
	else
		refresh_items_tab()
	end
end

local function create_options_frame()
	if optionsFrame then
		optionsFrame:Show()
		refresh_options_frame()
		return
	end
	
	-- Main frame
	optionsFrame = CreateFrame("Frame", "GCDIndicatorOptions", UIParent, "BasicFrameTemplateWithInset")
	optionsFrame:SetSize(510, 500)
	optionsFrame:SetPoint("CENTER")
	optionsFrame:SetMovable(true)
	optionsFrame:EnableMouse(true)
	optionsFrame:RegisterForDrag("LeftButton")
	optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
	optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
	optionsFrame:SetFrameStrata("DIALOG")
	
	-- Title
	optionsFrame.TitleText:SetText("GCDIndicator Options")
	
	-- ═══════════════════════════════════════════════════════════════════════
	-- PROFILES SECTION (always visible at top)
	-- ═══════════════════════════════════════════════════════════════════════
	
	local profilesLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	profilesLabel:SetPoint("TOPLEFT", 15, -30)
	profilesLabel:SetText("Profiles:")
	
	local profilesContainer = CreateFrame("Frame", nil, optionsFrame)
	profilesContainer:SetSize(400, 30)
	profilesContainer:SetPoint("TOPLEFT", 10, -50)
	optionsFrame.profilesContainer = profilesContainer
	
	-- Separator after profiles
	local profileSep = optionsFrame:CreateTexture(nil, "ARTWORK")
	profileSep:SetColorTexture(0.3, 0.3, 0.3, 1)
	profileSep:SetSize(480, 1)
	profileSep:SetPoint("TOPLEFT", 10, -85)
	
	-- ═══════════════════════════════════════════════════════════════════════
	-- TAB BUTTONS
	-- ═══════════════════════════════════════════════════════════════════════
	
	local tabY = -95
	
	-- Spells tab button
	local spellsTabBtn = CreateFrame("Button", nil, optionsFrame)
	spellsTabBtn:SetSize(80, 24)
	spellsTabBtn:SetPoint("TOPLEFT", 15, tabY)
	spellsTabBtn:SetNormalFontObject("GameFontHighlight")
	spellsTabBtn:SetHighlightFontObject("GameFontHighlight")
	
	local spellsTabText = spellsTabBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	spellsTabText:SetPoint("CENTER")
	spellsTabText:SetText("Spells")
	spellsTabBtn:SetFontString(spellsTabText)
	
	local spellsTabBg = spellsTabBtn:CreateTexture(nil, "BACKGROUND")
	spellsTabBg:SetAllPoints()
	spellsTabBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)
	
	spellsTabBtn:SetScript("OnClick", function()
		switch_tab("spells")
	end)
	spellsTabBtn:SetScript("OnEnter", function(self)
		spellsTabBg:SetColorTexture(0.3, 0.3, 0.3, 0.8)
	end)
	spellsTabBtn:SetScript("OnLeave", function(self)
		spellsTabBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)
	end)
	optionsFrame.spellsTabBtn = spellsTabBtn
	
	-- Items tab button
	local itemsTabBtn = CreateFrame("Button", nil, optionsFrame)
	itemsTabBtn:SetSize(100, 24)
	itemsTabBtn:SetPoint("LEFT", spellsTabBtn, "RIGHT", 5, 0)
	itemsTabBtn:SetNormalFontObject("GameFontNormal")
	itemsTabBtn:SetHighlightFontObject("GameFontHighlight")
	
	local itemsTabText = itemsTabBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	itemsTabText:SetPoint("CENTER")
	itemsTabText:SetText("Items/Trinkets")
	itemsTabBtn:SetFontString(itemsTabText)
	
	local itemsTabBg = itemsTabBtn:CreateTexture(nil, "BACKGROUND")
	itemsTabBg:SetAllPoints()
	itemsTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
	
	itemsTabBtn:SetScript("OnClick", function()
		switch_tab("items")
	end)
	itemsTabBtn:SetScript("OnEnter", function(self)
		itemsTabBg:SetColorTexture(0.3, 0.3, 0.3, 0.8)
	end)
	itemsTabBtn:SetScript("OnLeave", function(self)
		itemsTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
	end)
	optionsFrame.itemsTabBtn = itemsTabBtn
	
	-- ═══════════════════════════════════════════════════════════════════════
	-- SPELLS SCROLL FRAME
	-- ═══════════════════════════════════════════════════════════════════════
	
	local spellsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	spellsScrollFrame:SetPoint("TOPLEFT", 10, -125)
	spellsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	optionsFrame.spellsScrollFrame = spellsScrollFrame
	
	local spellsScrollChild = CreateFrame("Frame", nil, spellsScrollFrame)
	spellsScrollChild:SetSize(450, 600)
	spellsScrollFrame:SetScrollChild(spellsScrollChild)
	optionsFrame.spellsScrollChild = spellsScrollChild
	
	-- ═══════════════════════════════════════════════════════════════════════
	-- ITEMS SCROLL FRAME
	-- ═══════════════════════════════════════════════════════════════════════
	
	local itemsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	itemsScrollFrame:SetPoint("TOPLEFT", 10, -125)
	itemsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	itemsScrollFrame:Hide()  -- Hidden by default
	optionsFrame.itemsScrollFrame = itemsScrollFrame
	
	local itemsScrollChild = CreateFrame("Frame", nil, itemsScrollFrame)
	itemsScrollChild:SetSize(450, 600)
	itemsScrollFrame:SetScrollChild(itemsScrollChild)
	optionsFrame.itemsScrollChild = itemsScrollChild
	
	-- ═══════════════════════════════════════════════════════════════════════
	-- BOTTOM BUTTONS
	-- ═══════════════════════════════════════════════════════════════════════
	
	-- Rescan button
	local rescanBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
	rescanBtn:SetSize(100, 22)
	rescanBtn:SetPoint("BOTTOMLEFT", 15, 10)
	rescanBtn:SetText("Rescan Bars")
	rescanBtn:SetScript("OnClick", function()
		scan_action_bars()
		C_Timer.After(0.2, refresh_options_frame)
	end)
	
	-- Close button
	local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
	closeBtn:SetSize(80, 22)
	closeBtn:SetPoint("BOTTOMRIGHT", -10, 10)
	closeBtn:SetText("Close")
	closeBtn:SetScript("OnClick", function()
		optionsFrame:Hide()
	end)
	
	-- ESC to close
	table.insert(UISpecialFrames, "GCDIndicatorOptions")
	
	-- Initialize with spells tab
	currentTab = "spells"
	refresh_options_frame()
	optionsFrame:Show()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SLASH COMMANDS
-- ═══════════════════════════════════════════════════════════════════════════

-- Note: /gcdi is used by LibGCDI for position config
-- Use /gcdopt for options window
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
		-- Show tracked items for debugging
		print("|cff00ff00GCDIndicator:|r --- Item Catalog ---")
		local count = 0
		for key, data in pairs(itemCatalog) do
			count = count + 1
			print("  " .. key .. " = " .. tostring(data.name) .. " (ID: " .. tostring(data.itemID) .. ", slot: " .. tostring(data.slot) .. ")")
		end
		print("|cff00ff00GCDIndicator:|r " .. count .. " items in catalog")
		print("|cff00ff00GCDIndicator:|r --- Tracked Items (bars) ---")
		local trackedCount = 0
		for key, data in pairs(trackedItems) do
			trackedCount = trackedCount + 1
			local startTime, duration = C_Item.GetItemCooldown(data.itemID)
			print("  " .. key .. " = " .. tostring(data.name) .. " (ID: " .. tostring(data.itemID) .. "), CD: start=" .. tostring(startTime) .. " dur=" .. tostring(duration))
		end
		print("|cff00ff00GCDIndicator:|r " .. trackedCount .. " items with bars")
	else
		create_options_frame()
	end
end

-- Print help on load
C_Timer.After(2, function()
	print("|cff00ff00GCDIndicator:|r Type |cffffcc00/gcdopt|r to open options, |cffffcc00/gcdi|r to move bars")
end)

C_Timer.After(0.5, init)
