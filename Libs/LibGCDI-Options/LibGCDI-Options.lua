-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-Options - Options UI for GCDIndicator
-- ═══════════════════════════════════════════════════════════════════════════

local GCDI = _G.GCDI
if not GCDI then
	error("LibGCDI-Options requires GCDI to be loaded first")
	return
end

-- Local references to GCDI data
local settings = nil  -- Set during init
local configs = GCDI.configs
local RANGE_ITEMS = GCDI.RANGE_ITEMS

-- Local state for options frame
local optionsFrame = nil
local spellRows = {}
local itemRows = {}
local optionsElements = {}
local itemsTabElements = {}
local currentTab = "spells"

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Build ordered list of range options for dropdowns
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
			info.value = opt.index
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
	
	for listIdx, opt in ipairs(options) do
		if opt.index == selectedIndex then
			UIDropDownMenu_SetSelectedID(dropdown, listIdx)
			break
		end
	end
	
	return dropdown
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELLS TAB
-- ═══════════════════════════════════════════════════════════════════════════

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
	
	-- Global range fallback
	local globalLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	globalLabel:SetPoint("TOPLEFT", 10, yOffset)
	globalLabel:SetText("Global Range:")
	
	local globalDropdown = create_range_dropdown(scrollChild, 130, settings.globalRangeFallback or 0, function(index)
		settings.globalRangeFallback = index
		GCDI.UpdateRangeIndicators()
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
	nativeHeader:SetText("|cff00ff00N|r")
	
	local rangeHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	rangeHeader:SetPoint("TOPLEFT", 200, yOffset)
	rangeHeader:SetText("Range Override")
	
	local orderHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	orderHeader:SetPoint("TOPLEFT", 385, yOffset)
	orderHeader:SetText("Order")
	yOffset = yOffset - 20
	
	-- Create rows for each spell
	local orderedSpells = GCDI.get_all_catalog_spells_ordered()
	local disabledSectionStarted = false
	
	for i, spellID in ipairs(orderedSpells) do
		local catalogEntry = GCDI.spellCatalog[spellID]
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
		if not GCDI.is_spell_enabled(spellID) and not disabledSectionStarted then
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
		
		-- Check native range
		local spellData = GCDI.trackedSpells[spellID]
		local actionSlot = spellData and spellData.actionSlot or GCDI.get_action_slot_for_spell(spellID)
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
			GCDI.auto_save_to_profile()
			GCDI.rebuild_spell_bars()
			GCDI.refresh_options_frame()
		end)
		
		-- Self-Cast checkbox
		local selfCastCheckbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		selfCastCheckbox:SetSize(24, 24)
		selfCastCheckbox:SetPoint("LEFT", 28, 0)
		selfCastCheckbox:SetChecked(spellSettings.selfCast == true)
		selfCastCheckbox:SetScript("OnClick", function(self)
			spellSettings.selfCast = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.UpdateRangeIndicators()
		end)
		selfCastCheckbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Self-Cast Spell")
			GameTooltip:AddLine("Check if this spell only targets yourself.", 1, 1, 1, true)
			GameTooltip:AddLine("Self-cast spells will always show gray (no range check).", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		selfCastCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
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
		
		-- Tooltip for indicator
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
		indicatorTooltip:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
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
					GCDI.UpdateRangeIndicators()
				end
				UIDropDownMenu_AddButton(info, level)
			else
				info.text = "Use Global"
				info.value = -1
				info.checked = (spellSettings.rangeFallback == nil)
				info.func = function()
					spellSettings.rangeFallback = nil
					UIDropDownMenu_SetSelectedID(rangeDropdown, 1)
					GCDI.UpdateRangeIndicators()
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
					GCDI.UpdateRangeIndicators()
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
		
		-- Reorder buttons
		local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		upBtn:SetSize(22, 18)
		upBtn:SetPoint("LEFT", 380, 0)
		upBtn:SetText("Up")
		upBtn:SetNormalFontObject("GameFontNormalSmall")
		upBtn:SetHighlightFontObject("GameFontHighlightSmall")
		upBtn:SetEnabled(i > 1)
		upBtn:SetScript("OnClick", function()
			GCDI.move_spell_in_order(spellID, -1)
			GCDI.refresh_options_frame()
		end)
		
		local downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		downBtn:SetSize(22, 18)
		downBtn:SetPoint("LEFT", upBtn, "RIGHT", 2, 0)
		downBtn:SetText("Dn")
		downBtn:SetNormalFontObject("GameFontNormalSmall")
		downBtn:SetHighlightFontObject("GameFontHighlightSmall")
		downBtn:SetEnabled(i < #orderedSpells)
		downBtn:SetScript("OnClick", function()
			GCDI.move_spell_in_order(spellID, 1)
			GCDI.refresh_options_frame()
		end)
		
		local bottomBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		bottomBtn:SetSize(24, 18)
		bottomBtn:SetPoint("LEFT", downBtn, "RIGHT", 2, 0)
		bottomBtn:SetText("Bot")
		bottomBtn:SetNormalFontObject("GameFontNormalSmall")
		bottomBtn:SetHighlightFontObject("GameFontHighlightSmall")
		bottomBtn:SetEnabled(i < #orderedSpells)
		bottomBtn:SetScript("OnClick", function()
			GCDI.move_spell_to_bottom(spellID)
			GCDI.refresh_options_frame()
		end)
		
		spellRows[i] = row
		yOffset = yOffset - 35
	end
	
	scrollChild:SetHeight(math.abs(yOffset) + 20)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ITEMS TAB
-- ═══════════════════════════════════════════════════════════════════════════

local function refresh_items_tab()
	if not optionsFrame or not optionsFrame.itemsScrollChild then return end
	
	-- Clear existing item rows
	for _, row in pairs(itemRows) do
		row:Hide()
		row:SetParent(nil)
	end
	wipe(itemRows)
	
	-- Clear items tab elements
	for _, element in pairs(itemsTabElements) do
		if element.Hide then element:Hide() end
		if element.SetParent then element:SetParent(nil) end
	end
	wipe(itemsTabElements)
	
	local scrollChild = optionsFrame.itemsScrollChild
	local yOffset = -10
	
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
	
	-- Create rows
	local orderedItems = GCDI.get_all_catalog_items_ordered()
	local disabledSectionStarted = false
	
	if #orderedItems == 0 then
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
		local catalogEntry = GCDI.itemCatalog[itemKey]
		if not catalogEntry then
			break
		end
		
		local itemName = catalogEntry.name
		local texture = catalogEntry.texture
		
		local itemSettings = settings.itemSettings and settings.itemSettings[itemKey]
		if not itemSettings then
			if not settings.itemSettings then settings.itemSettings = {} end
			settings.itemSettings[itemKey] = { enabled = true }
			itemSettings = settings.itemSettings[itemKey]
		end
		
		-- Separator before disabled items
		if not GCDI.is_item_enabled(itemKey) and not disabledSectionStarted then
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
			GCDI.auto_save_to_profile()
			GCDI.rebuild_item_bars()
			GCDI.reposition_all()
			GCDI.refresh_options_frame()
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
		
		-- Type indicator
		local typeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		typeText:SetPoint("LEFT", 260, 0)
		if catalogEntry.slot then
			typeText:SetText("|cff00ff00Trinket|r")
		else
			typeText:SetText("|cffffcc00Consumable|r")
		end
		
		-- Reorder buttons
		local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		upBtn:SetSize(22, 18)
		upBtn:SetPoint("LEFT", 315, 0)
		upBtn:SetText("Up")
		upBtn:SetNormalFontObject("GameFontNormalSmall")
		upBtn:SetHighlightFontObject("GameFontHighlightSmall")
		upBtn:SetEnabled(i > 1)
		upBtn:SetScript("OnClick", function()
			GCDI.move_item_in_order(itemKey, -1)
			GCDI.refresh_options_frame()
		end)
		
		local downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		downBtn:SetSize(22, 18)
		downBtn:SetPoint("LEFT", upBtn, "RIGHT", 2, 0)
		downBtn:SetText("Dn")
		downBtn:SetNormalFontObject("GameFontNormalSmall")
		downBtn:SetHighlightFontObject("GameFontHighlightSmall")
		downBtn:SetEnabled(i < #orderedItems)
		downBtn:SetScript("OnClick", function()
			GCDI.move_item_in_order(itemKey, 1)
			GCDI.refresh_options_frame()
		end)
		
		local bottomBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		bottomBtn:SetSize(24, 18)
		bottomBtn:SetPoint("LEFT", downBtn, "RIGHT", 2, 0)
		bottomBtn:SetText("Bot")
		bottomBtn:SetNormalFontObject("GameFontNormalSmall")
		bottomBtn:SetHighlightFontObject("GameFontHighlightSmall")
		bottomBtn:SetEnabled(i < #orderedItems)
		bottomBtn:SetScript("OnClick", function()
			GCDI.move_item_to_bottom(itemKey)
			GCDI.refresh_options_frame()
		end)
		
		itemRows[i] = row
		yOffset = yOffset - 35
	end
	
	scrollChild:SetHeight(math.abs(yOffset) + 20)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TAB SWITCHING
-- ═══════════════════════════════════════════════════════════════════════════

local function switch_tab(tabName)
	if not optionsFrame then return end
	currentTab = tabName
	
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
	
	if optionsFrame.spellsScrollFrame then
		optionsFrame.spellsScrollFrame:SetShown(tabName == "spells")
	end
	if optionsFrame.itemsScrollFrame then
		optionsFrame.itemsScrollFrame:SetShown(tabName == "items")
	end
	
	if tabName == "spells" then
		refresh_spells_tab()
	else
		refresh_items_tab()
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PROFILES SECTION
-- ═══════════════════════════════════════════════════════════════════════════

local function refresh_profiles_section()
	if not optionsFrame or not optionsFrame.profilesContainer then return end
	
	for _, element in pairs(optionsElements) do
		if element.Hide then element:Hide() end
		if element.SetParent then element:SetParent(nil) end
	end
	wipe(optionsElements)
	
	local container = optionsFrame.profilesContainer
	
	local function track(element)
		table.insert(optionsElements, element)
		return element
	end
	
	local profileNames = GCDI.get_profile_names()
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
				GCDI.load_profile(name)
				UIDropDownMenu_SetText(profileDropdown, name)
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end
	UIDropDownMenu_Initialize(profileDropdown, initProfileDropdown)
	local currentProfileText = settings.currentProfile or "-- Select Profile --"
	UIDropDownMenu_SetText(profileDropdown, currentProfileText)
	
	local saveBtn = track(CreateFrame("Button", nil, container, "UIPanelButtonTemplate"))
	saveBtn:SetSize(50, 22)
	saveBtn:SetPoint("LEFT", profileDropdown, "RIGHT", 0, 2)
	saveBtn:SetText("Save")
	saveBtn:SetScript("OnClick", function()
		StaticPopup_Show("GCDI_SAVE_PROFILE")
	end)
	
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

-- ═══════════════════════════════════════════════════════════════════════════
-- MAIN REFRESH FUNCTION
-- ═══════════════════════════════════════════════════════════════════════════

local function refresh_options_frame()
	if not optionsFrame then return end
	if not optionsFrame:IsShown() then return end
	
	-- Update settings reference
	settings = GCDI.settings
	
	refresh_profiles_section()
	
	if currentTab == "spells" then
		refresh_spells_tab()
	else
		refresh_items_tab()
	end
end

-- Export refresh function
GCDI.refresh_options_frame = refresh_options_frame

-- ═══════════════════════════════════════════════════════════════════════════
-- CREATE OPTIONS FRAME
-- ═══════════════════════════════════════════════════════════════════════════

local function create_options_frame()
	-- Update settings reference
	settings = GCDI.settings
	
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
	
	optionsFrame.TitleText:SetText("GCDIndicator Options")
	
	-- PROFILES SECTION
	local profilesLabel = optionsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	profilesLabel:SetPoint("TOPLEFT", 15, -30)
	profilesLabel:SetText("Profiles:")
	
	local profilesContainer = CreateFrame("Frame", nil, optionsFrame)
	profilesContainer:SetSize(400, 30)
	profilesContainer:SetPoint("TOPLEFT", 10, -50)
	optionsFrame.profilesContainer = profilesContainer
	
	local profileSep = optionsFrame:CreateTexture(nil, "ARTWORK")
	profileSep:SetColorTexture(0.3, 0.3, 0.3, 1)
	profileSep:SetSize(480, 1)
	profileSep:SetPoint("TOPLEFT", 10, -85)
	
	-- TAB BUTTONS
	local tabY = -95
	
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
	
	spellsTabBtn:SetScript("OnClick", function() switch_tab("spells") end)
	spellsTabBtn:SetScript("OnEnter", function() spellsTabBg:SetColorTexture(0.3, 0.3, 0.3, 0.8) end)
	spellsTabBtn:SetScript("OnLeave", function() spellsTabBg:SetColorTexture(0.2, 0.2, 0.2, 0.8) end)
	optionsFrame.spellsTabBtn = spellsTabBtn
	
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
	
	itemsTabBtn:SetScript("OnClick", function() switch_tab("items") end)
	itemsTabBtn:SetScript("OnEnter", function() itemsTabBg:SetColorTexture(0.3, 0.3, 0.3, 0.8) end)
	itemsTabBtn:SetScript("OnLeave", function() itemsTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8) end)
	optionsFrame.itemsTabBtn = itemsTabBtn
	
	-- SPELLS SCROLL FRAME
	local spellsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	spellsScrollFrame:SetPoint("TOPLEFT", 10, -125)
	spellsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	optionsFrame.spellsScrollFrame = spellsScrollFrame
	
	local spellsScrollChild = CreateFrame("Frame", nil, spellsScrollFrame)
	spellsScrollChild:SetSize(450, 600)
	spellsScrollFrame:SetScrollChild(spellsScrollChild)
	optionsFrame.spellsScrollChild = spellsScrollChild
	
	-- ITEMS SCROLL FRAME
	local itemsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	itemsScrollFrame:SetPoint("TOPLEFT", 10, -125)
	itemsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	itemsScrollFrame:Hide()
	optionsFrame.itemsScrollFrame = itemsScrollFrame
	
	local itemsScrollChild = CreateFrame("Frame", nil, itemsScrollFrame)
	itemsScrollChild:SetSize(450, 600)
	itemsScrollFrame:SetScrollChild(itemsScrollChild)
	optionsFrame.itemsScrollChild = itemsScrollChild
	
	-- BOTTOM BUTTONS
	local rescanBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
	rescanBtn:SetSize(100, 22)
	rescanBtn:SetPoint("BOTTOMLEFT", 15, 10)
	rescanBtn:SetText("Rescan Bars")
	rescanBtn:SetScript("OnClick", function()
		GCDI.scan_action_bars()
		C_Timer.After(0.2, refresh_options_frame)
	end)
	
	local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
	closeBtn:SetSize(80, 22)
	closeBtn:SetPoint("BOTTOMRIGHT", -10, 10)
	closeBtn:SetText("Close")
	closeBtn:SetScript("OnClick", function() optionsFrame:Hide() end)
	
	table.insert(UISpecialFrames, "GCDIndicatorOptions")
	
	currentTab = "spells"
	refresh_options_frame()
	optionsFrame:Show()
end

-- Export create function
GCDI.create_options_frame = create_options_frame
