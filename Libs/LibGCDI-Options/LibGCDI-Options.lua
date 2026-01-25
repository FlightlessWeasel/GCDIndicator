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
local buffRows = {}
local optionsElements = {}
local itemsTabElements = {}
local buffsTabElements = {}
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
	
	local iconTrackHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	iconTrackHeader:SetPoint("TOPLEFT", 66, yOffset)
	iconTrackHeader:SetText("Ico")
	
	local spellNameHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	spellNameHeader:SetPoint("TOPLEFT", 98, yOffset)
	spellNameHeader:SetText("Spell")
	
	local nativeHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	nativeHeader:SetPoint("TOPLEFT", 198, yOffset)
	nativeHeader:SetText("|cff00ff00N|r")
	
	local rangeHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	rangeHeader:SetPoint("TOPLEFT", 228, yOffset)
	rangeHeader:SetText("Range Override")
	
	local orderHeader = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	orderHeader:SetPoint("TOPLEFT", 410, yOffset)
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
			settings.spellSettings[spellID] = { enabled = true, rangeFallback = nil, selfCast = false, hasNativeRange = nil, trackIcon = false }
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
		
		-- Track Icon checkbox
		local trackIconCheckbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		trackIconCheckbox:SetSize(24, 24)
		trackIconCheckbox:SetPoint("LEFT", 56, 0)
		trackIconCheckbox:SetChecked(spellSettings.trackIcon == true)
		trackIconCheckbox:SetScript("OnClick", function(self)
			spellSettings.trackIcon = self:GetChecked()
			GCDI.auto_save_to_profile()
		end)
		trackIconCheckbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Track Icon Changes")
			GameTooltip:AddLine("Enable for proc abilities that change icons.", 1, 1, 1, true)
			GameTooltip:AddLine("Example: Shred -> Ravage when Sudden Ambush procs.", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		trackIconCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		-- Spell icon
		local icon = row:CreateTexture(nil, "ARTWORK")
		icon:SetSize(20, 20)
		icon:SetPoint("LEFT", 84, 0)
		icon:SetTexture(texture)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		
		-- Spell name
		local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		nameText:SetPoint("LEFT", 108, 0)
		nameText:SetWidth(90)
		nameText:SetJustifyH("LEFT")
		nameText:SetText(spellName)
		
		-- Native range indicator
		local rangeIndicatorText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		rangeIndicatorText:SetPoint("LEFT", 200, 0)
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
		rangeDropdown:SetPoint("LEFT", 213, 0)
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
		upBtn:SetPoint("LEFT", 405, 0)
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
	
	local chargesHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	chargesHeader:SetPoint("TOPLEFT", 38, yOffset)
	chargesHeader:SetText("Chg")
	
	local itemNameHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	itemNameHeader:SetPoint("TOPLEFT", 70, yOffset)
	itemNameHeader:SetText("Item")
	
	local orderHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	orderHeader:SetPoint("TOPLEFT", 350, yOffset)
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
		row:SetSize(450, 30)
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
		
		-- Show Charges checkbox
		local chargesCheckbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		chargesCheckbox:SetSize(24, 24)
		chargesCheckbox:SetPoint("LEFT", 28, 0)
		chargesCheckbox:SetChecked(itemSettings.showCharges == true)
		chargesCheckbox:SetScript("OnClick", function(self)
			itemSettings.showCharges = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.rebuild_item_bars()
			GCDI.reposition_all()
		end)
		chargesCheckbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Show Charges")
			GameTooltip:AddLine("Show a charge indicator for this item.", 1, 1, 1, true)
			GameTooltip:AddLine("Blue = has item, Black = out of stock.", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		chargesCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		-- Item icon
		local icon = row:CreateTexture(nil, "ARTWORK")
		icon:SetSize(20, 20)
		icon:SetPoint("LEFT", 56, 0)
		icon:SetTexture(texture)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		
		-- Item name
		local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		nameText:SetPoint("LEFT", 80, 0)
		nameText:SetWidth(220)
		nameText:SetJustifyH("LEFT")
		nameText:SetText(itemName)
		
		-- Type indicator
		local typeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		typeText:SetPoint("LEFT", 290, 0)
		if catalogEntry.slot then
			typeText:SetText("|cff00ff00Trinket|r")
		else
			typeText:SetText("|cffffcc00Consumable|r")
		end
		
		-- Reorder buttons
		local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		upBtn:SetSize(22, 18)
		upBtn:SetPoint("LEFT", 345, 0)
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
-- BUFFS TAB
-- ═══════════════════════════════════════════════════════════════════════════

local function refresh_buffs_tab()
	if not optionsFrame or not optionsFrame.buffsScrollChild then return end
	
	-- Clear existing buff rows
	for _, row in pairs(buffRows) do
		row:Hide()
		row:SetParent(nil)
	end
	wipe(buffRows)
	
	-- Clear buffs tab elements
	for _, element in pairs(buffsTabElements) do
		if element.Hide then element:Hide() end
		if element.SetParent then element:SetParent(nil) end
	end
	wipe(buffsTabElements)
	
	local scrollChild = optionsFrame.buffsScrollChild
	local yOffset = -10
	
	local function track(element)
		table.insert(buffsTabElements, element)
		return element
	end
	
	-- Add Buff section
	local addBuffLabel = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	addBuffLabel:SetPoint("TOPLEFT", 10, yOffset)
	addBuffLabel:SetText("Add Buff by Spell ID:")
	
	local addBuffEditBox = track(CreateFrame("EditBox", nil, scrollChild, "InputBoxTemplate"))
	addBuffEditBox:SetSize(80, 20)
	addBuffEditBox:SetPoint("LEFT", addBuffLabel, "RIGHT", 10, 0)
	addBuffEditBox:SetAutoFocus(false)
	addBuffEditBox:SetNumeric(true)
	addBuffEditBox:SetMaxLetters(10)
	
	local addBuffBtn = track(CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate"))
	addBuffBtn:SetSize(60, 22)
	addBuffBtn:SetPoint("LEFT", addBuffEditBox, "RIGHT", 5, 0)
	addBuffBtn:SetText("Add")
	addBuffBtn:SetScript("OnClick", function()
		local spellID = tonumber(addBuffEditBox:GetText())
		if spellID and spellID > 0 then
			if GCDI.add_buff_to_catalog(spellID) then
				if not settings.buffSettings then settings.buffSettings = {} end
				settings.buffSettings[spellID] = { enabled = true, showStacks = true, maxStacksDisplay = 5 }
				GCDI.rebuild_buff_bars()
				addBuffEditBox:SetText("")
				refresh_buffs_tab()
				print("|cff00ff00GCDIndicator:|r Buff added: " .. (C_Spell.GetSpellName(spellID) or spellID))
			else
				print("|cffff0000GCDIndicator:|r Could not find spell ID: " .. spellID)
			end
		end
	end)
	addBuffEditBox:SetScript("OnEnterPressed", function(self)
		addBuffBtn:Click()
	end)
	
	local helpText = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	helpText:SetPoint("TOPLEFT", 10, yOffset - 25)
	helpText:SetTextColor(0.7, 0.7, 0.7)
	helpText:SetText("Tip: Get spell IDs from Wowhead or addon tooltips. Buffs are auto-detected when applied.")
	yOffset = yOffset - 55
	
	-- Separator
	local sep = track(scrollChild:CreateTexture(nil, "ARTWORK"))
	sep:SetColorTexture(0.4, 0.4, 0.4, 1)
	sep:SetSize(450, 1)
	sep:SetPoint("TOPLEFT", 10, yOffset)
	yOffset = yOffset - 15
	
	-- Column headers
	local enabledHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	enabledHeader:SetPoint("TOPLEFT", 10, yOffset)
	enabledHeader:SetText("On")
	
	local stacksHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	stacksHeader:SetPoint("TOPLEFT", 38, yOffset)
	stacksHeader:SetText("Stk")
	
	local buffNameHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	buffNameHeader:SetPoint("TOPLEFT", 70, yOffset)
	buffNameHeader:SetText("Buff (ID)")
	
	local maxStacksHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	maxStacksHeader:SetPoint("TOPLEFT", 220, yOffset)
	maxStacksHeader:SetText("Max Stacks")
	
	local orderHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	orderHeader:SetPoint("TOPLEFT", 350, yOffset)
	orderHeader:SetText("Order")
	yOffset = yOffset - 20
	
	-- Create rows
	local orderedBuffs = GCDI.get_all_catalog_buffs_ordered()
	local disabledSectionStarted = false
	
	if #orderedBuffs == 0 then
		local noBuffsText = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
		noBuffsText:SetPoint("TOPLEFT", 10, yOffset)
		noBuffsText:SetText("|cff888888No buffs being tracked.|r")
		yOffset = yOffset - 30
		
		local tipText = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
		tipText:SetPoint("TOPLEFT", 10, yOffset)
		tipText:SetText("Add buffs by spell ID above, or they'll be auto-detected when applied.")
		yOffset = yOffset - 25
	end
	
	for i, spellID in ipairs(orderedBuffs) do
		local catalogEntry = GCDI.buffCatalog[spellID]
		if not catalogEntry then
			break
		end
		
		local buffName = catalogEntry.name
		local texture = catalogEntry.texture
		
		local buffSettings = settings.buffSettings and settings.buffSettings[spellID]
		if not buffSettings then
			if not settings.buffSettings then settings.buffSettings = {} end
			settings.buffSettings[spellID] = { enabled = true, showStacks = true, maxStacksDisplay = 5 }
			buffSettings = settings.buffSettings[spellID]
		end
		
		-- Separator before disabled buffs
		if not GCDI.is_buff_enabled(spellID) and not disabledSectionStarted then
			disabledSectionStarted = true
			yOffset = yOffset - 10
			local disabledSep = track(scrollChild:CreateTexture(nil, "ARTWORK"))
			disabledSep:SetColorTexture(0.4, 0.4, 0.4, 1)
			disabledSep:SetSize(450, 1)
			disabledSep:SetPoint("TOPLEFT", 10, yOffset)
			yOffset = yOffset - 5
			
			local disabledLabel = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
			disabledLabel:SetPoint("TOPLEFT", 10, yOffset)
			disabledLabel:SetText("|cff888888— Disabled Buffs —|r")
			yOffset = yOffset - 18
		end
		
		local row = CreateFrame("Frame", nil, scrollChild)
		row:SetSize(450, 30)
		row:SetPoint("TOPLEFT", 10, yOffset)
		
		-- Enabled checkbox
		local checkbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		checkbox:SetSize(24, 24)
		checkbox:SetPoint("LEFT", 0, 0)
		checkbox:SetChecked(buffSettings.enabled ~= false)
		checkbox:SetScript("OnClick", function(self)
			buffSettings.enabled = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.rebuild_buff_bars()
			GCDI.reposition_all()
			GCDI.refresh_options_frame()
		end)
		
		-- Show Stacks checkbox
		local stacksCheckbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		stacksCheckbox:SetSize(24, 24)
		stacksCheckbox:SetPoint("LEFT", 28, 0)
		stacksCheckbox:SetChecked(buffSettings.showStacks ~= false)
		stacksCheckbox:SetScript("OnClick", function(self)
			buffSettings.showStacks = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.rebuild_buff_bars()
			GCDI.reposition_all()
		end)
		stacksCheckbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Show Stacks")
			GameTooltip:AddLine("Display stack indicators for this buff.", 1, 1, 1, true)
			GameTooltip:AddLine("Blue = stack present, Black = stack empty.", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		stacksCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		-- Buff icon
		local icon = row:CreateTexture(nil, "ARTWORK")
		icon:SetSize(20, 20)
		icon:SetPoint("LEFT", 56, 0)
		icon:SetTexture(texture)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		
		-- Buff name with spell ID
		local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		nameText:SetPoint("LEFT", 80, 0)
		nameText:SetWidth(130)
		nameText:SetJustifyH("LEFT")
		nameText:SetText(buffName .. " |cff888888(" .. spellID .. ")|r")
		
		-- Max stacks dropdown
		local maxStacksDropdown = CreateFrame("Frame", nil, row, "UIDropDownMenuTemplate")
		maxStacksDropdown:SetPoint("LEFT", 200, 0)
		UIDropDownMenu_SetWidth(maxStacksDropdown, 60)
		
		local function initMaxStacksDropdown(self, level)
			for stacks = 1, 10 do
				local info = UIDropDownMenu_CreateInfo()
				info.text = tostring(stacks)
				info.value = stacks
				info.checked = (buffSettings.maxStacksDisplay == stacks)
				info.func = function()
					buffSettings.maxStacksDisplay = stacks
					UIDropDownMenu_SetSelectedID(maxStacksDropdown, stacks)
					GCDI.auto_save_to_profile()
					GCDI.rebuild_buff_bars()
					GCDI.reposition_all()
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end
		UIDropDownMenu_Initialize(maxStacksDropdown, initMaxStacksDropdown)
		UIDropDownMenu_SetSelectedID(maxStacksDropdown, buffSettings.maxStacksDisplay or 5)
		
		-- Reorder buttons
		local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		upBtn:SetSize(22, 18)
		upBtn:SetPoint("LEFT", 345, 0)
		upBtn:SetText("Up")
		upBtn:SetNormalFontObject("GameFontNormalSmall")
		upBtn:SetHighlightFontObject("GameFontHighlightSmall")
		upBtn:SetEnabled(i > 1)
		upBtn:SetScript("OnClick", function()
			GCDI.move_buff_in_order(spellID, -1)
			GCDI.refresh_options_frame()
		end)
		
		local downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		downBtn:SetSize(22, 18)
		downBtn:SetPoint("LEFT", upBtn, "RIGHT", 2, 0)
		downBtn:SetText("Dn")
		downBtn:SetNormalFontObject("GameFontNormalSmall")
		downBtn:SetHighlightFontObject("GameFontHighlightSmall")
		downBtn:SetEnabled(i < #orderedBuffs)
		downBtn:SetScript("OnClick", function()
			GCDI.move_buff_in_order(spellID, 1)
			GCDI.refresh_options_frame()
		end)
		
		local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		removeBtn:SetSize(24, 18)
		removeBtn:SetPoint("LEFT", downBtn, "RIGHT", 2, 0)
		removeBtn:SetText("X")
		removeBtn:SetNormalFontObject("GameFontNormalSmall")
		removeBtn:SetHighlightFontObject("GameFontHighlightSmall")
		removeBtn:SetScript("OnClick", function()
			GCDI.remove_buff_from_catalog(spellID)
			GCDI.refresh_options_frame()
		end)
		removeBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Remove Buff")
			GameTooltip:AddLine("Remove this buff from tracking.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		removeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		buffRows[i] = row
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
	if optionsFrame.buffsTabBtn then
		if tabName == "buffs" then
			optionsFrame.buffsTabBtn:SetNormalFontObject("GameFontHighlight")
			optionsFrame.buffsTabBtn:GetFontString():SetTextColor(1, 1, 1)
		else
			optionsFrame.buffsTabBtn:SetNormalFontObject("GameFontNormal")
			optionsFrame.buffsTabBtn:GetFontString():SetTextColor(0.7, 0.7, 0.7)
		end
	end
	if optionsFrame.settingsTabBtn then
		if tabName == "settings" then
			optionsFrame.settingsTabBtn:SetNormalFontObject("GameFontHighlight")
			optionsFrame.settingsTabBtn:GetFontString():SetTextColor(1, 1, 1)
		else
			optionsFrame.settingsTabBtn:SetNormalFontObject("GameFontNormal")
			optionsFrame.settingsTabBtn:GetFontString():SetTextColor(0.7, 0.7, 0.7)
		end
	end
	
	if optionsFrame.spellsScrollFrame then
		optionsFrame.spellsScrollFrame:SetShown(tabName == "spells")
	end
	if optionsFrame.itemsScrollFrame then
		optionsFrame.itemsScrollFrame:SetShown(tabName == "items")
	end
	if optionsFrame.buffsScrollFrame then
		optionsFrame.buffsScrollFrame:SetShown(tabName == "buffs")
	end
	if optionsFrame.settingsFrame then
		optionsFrame.settingsFrame:SetShown(tabName == "settings")
	end
	
	if tabName == "spells" then
		refresh_spells_tab()
	elseif tabName == "items" then
		refresh_items_tab()
	elseif tabName == "buffs" then
		refresh_buffs_tab()
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
	elseif currentTab == "items" then
		refresh_items_tab()
	else
		refresh_buffs_tab()
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
	optionsFrame:SetSize(570, 500)
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
	
	-- BUFFS TAB
	local buffsTabBtn = CreateFrame("Button", nil, optionsFrame)
	buffsTabBtn:SetSize(60, 24)
	buffsTabBtn:SetPoint("LEFT", itemsTabBtn, "RIGHT", 5, 0)
	buffsTabBtn:SetNormalFontObject("GameFontNormal")
	buffsTabBtn:SetHighlightFontObject("GameFontHighlight")
	
	local buffsTabText = buffsTabBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	buffsTabText:SetPoint("CENTER")
	buffsTabText:SetText("Buffs")
	buffsTabBtn:SetFontString(buffsTabText)
	
	local buffsTabBg = buffsTabBtn:CreateTexture(nil, "BACKGROUND")
	buffsTabBg:SetAllPoints()
	buffsTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
	
	buffsTabBtn:SetScript("OnClick", function() switch_tab("buffs") end)
	buffsTabBtn:SetScript("OnEnter", function() buffsTabBg:SetColorTexture(0.3, 0.3, 0.3, 0.8) end)
	buffsTabBtn:SetScript("OnLeave", function() buffsTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8) end)
	optionsFrame.buffsTabBtn = buffsTabBtn
	
	-- SETTINGS TAB
	local settingsTabBtn = CreateFrame("Button", nil, optionsFrame)
	settingsTabBtn:SetSize(70, 24)
	settingsTabBtn:SetPoint("LEFT", buffsTabBtn, "RIGHT", 5, 0)
	settingsTabBtn:SetNormalFontObject("GameFontNormal")
	settingsTabBtn:SetHighlightFontObject("GameFontHighlight")
	
	local settingsTabText = settingsTabBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	settingsTabText:SetPoint("CENTER")
	settingsTabText:SetText("Settings")
	settingsTabBtn:SetFontString(settingsTabText)
	
	local settingsTabBg = settingsTabBtn:CreateTexture(nil, "BACKGROUND")
	settingsTabBg:SetAllPoints()
	settingsTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
	
	settingsTabBtn:SetScript("OnClick", function() switch_tab("settings") end)
	settingsTabBtn:SetScript("OnEnter", function() settingsTabBg:SetColorTexture(0.3, 0.3, 0.3, 0.8) end)
	settingsTabBtn:SetScript("OnLeave", function() settingsTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8) end)
	optionsFrame.settingsTabBtn = settingsTabBtn
	
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
	
	-- BUFFS SCROLL FRAME
	local buffsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	buffsScrollFrame:SetPoint("TOPLEFT", 10, -125)
	buffsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	buffsScrollFrame:Hide()
	optionsFrame.buffsScrollFrame = buffsScrollFrame
	
	local buffsScrollChild = CreateFrame("Frame", nil, buffsScrollFrame)
	buffsScrollChild:SetSize(450, 800)
	buffsScrollFrame:SetScrollChild(buffsScrollChild)
	optionsFrame.buffsScrollChild = buffsScrollChild
	
	-- SETTINGS FRAME
	local settingsFrame = CreateFrame("Frame", nil, optionsFrame)
	settingsFrame:SetPoint("TOPLEFT", 10, -125)
	settingsFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	settingsFrame:Hide()
	optionsFrame.settingsFrame = settingsFrame
	
	local settingsTitle = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	settingsTitle:SetPoint("TOPLEFT", 5, -10)
	settingsTitle:SetText("Frame Position")
	
	local settingsDesc = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	settingsDesc:SetPoint("TOPLEFT", 5, -35)
	settingsDesc:SetText("Use these buttons to move or reset the GCD indicator bars.")
	settingsDesc:SetTextColor(0.8, 0.8, 0.8)
	
	-- Move Frame Button
	local moveBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
	moveBtn:SetSize(150, 28)
	moveBtn:SetPoint("TOPLEFT", 5, -70)
	moveBtn:SetText("Move Frame")
	moveBtn:SetScript("OnClick", function()
		if GCDI.toggle_move_mode then
			GCDI.toggle_move_mode()
			optionsFrame:Hide()
		end
	end)
	moveBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Move Frame")
		GameTooltip:AddLine("Click to enable move mode.", 1, 1, 1, true)
		GameTooltip:AddLine("Drag the frame to reposition it.", 0.7, 0.7, 0.7, true)
		GameTooltip:AddLine("Click again or use /gcdi to lock.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	moveBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	
	-- Reset Position Button
	local resetBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
	resetBtn:SetSize(150, 28)
	resetBtn:SetPoint("TOPLEFT", moveBtn, "BOTTOMLEFT", 0, -10)
	resetBtn:SetText("Reset Position")
	resetBtn:SetScript("OnClick", function()
		if GCDI.reset_position then
			GCDI.reset_position()
			print("|cff00ff00GCDIndicator:|r Frame position reset to center")
		end
	end)
	resetBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Reset Position")
		GameTooltip:AddLine("Reset the frame to the default center position.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	resetBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	
	-- Minimap Button Toggle
	local minimapTitle = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	minimapTitle:SetPoint("TOPLEFT", 5, -150)
	minimapTitle:SetText("Minimap Button")
	
	local minimapToggleBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
	minimapToggleBtn:SetSize(150, 28)
	minimapToggleBtn:SetPoint("TOPLEFT", 5, -175)
	minimapToggleBtn:SetText("Toggle Minimap Icon")
	minimapToggleBtn:SetScript("OnClick", function()
		if GCDI.ToggleMinimapButton then
			GCDI.ToggleMinimapButton()
			local hidden = settings.minimap and settings.minimap.hide
			print("|cff00ff00GCDIndicator:|r Minimap button " .. (hidden and "hidden" or "shown"))
		end
	end)
	minimapToggleBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Toggle Minimap Icon")
		GameTooltip:AddLine("Show or hide the minimap button.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	minimapToggleBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	
	-- Preview Mode Section
	local previewTitle = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	previewTitle:SetPoint("TOPLEFT", 5, -220)
	previewTitle:SetText("Preview Mode")
	
	local previewDesc = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	previewDesc:SetPoint("TOPLEFT", 5, -245)
	previewDesc:SetText("Show all bars filled with visible colors for positioning.")
	previewDesc:SetTextColor(0.8, 0.8, 0.8)
	
	local previewBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
	previewBtn:SetSize(150, 28)
	previewBtn:SetPoint("TOPLEFT", 5, -270)
	previewBtn:SetText("Toggle Preview")
	previewBtn:SetScript("OnClick", function()
		if GCDI.toggle_preview_mode then
			GCDI.toggle_preview_mode()
		end
	end)
	previewBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Toggle Preview Mode")
		GameTooltip:AddLine("Fill all bars and show indicators.", 1, 1, 1, true)
		GameTooltip:AddLine("Useful for positioning the frame.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	previewBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	
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
