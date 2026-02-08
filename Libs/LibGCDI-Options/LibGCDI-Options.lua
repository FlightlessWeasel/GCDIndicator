-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-Options - Options UI for GCDIndicator
-- ═══════════════════════════════════════════════════════════════════════════

local GCDI = _G.GCDI
if not GCDI then
	error("LibGCDI-Options requires GCDI to be loaded first")
	return
end

-- Library references
local LibProfiles = LibStub("LibGCDI-Profiles")

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
local gcdTabElements = {}
local resourcesTabElements = {}
local itemsTabElements = {}
local buffsTabElements = {}
local currentTab = "gcd"

-- Forward declarations
local refresh_profiles_tab

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
-- GCD TAB
-- ═══════════════════════════════════════════════════════════════════════════

local GCD_INDICATOR_OPTIONS = {
	{ key = "showGcdRow", name = "Show GCD Row", desc = "Show the entire GCD indicator row" },
	{ key = "showStance", name = "Show Stance", desc = "Show the stance/form indicator", disabled = true },
	{ key = "showGcd", name = "Show GCD", desc = "Show the global cooldown bar", disabled = true },
	{ key = "showCombat", name = "Show Combat", desc = "Show the combat status indicator", disabled = true },
	{ key = "showAggro", name = "Show Aggro", desc = "Show the threat/aggro indicator", disabled = true },
	{ key = "showMobCount", name = "Show Mob Count", desc = "Show the nearby mob count indicator" },
}

local function refresh_gcd_tab()
	if not optionsFrame or not optionsFrame.gcdScrollChild then return end
	
	local frame = optionsFrame.gcdScrollChild
	
	-- Clear existing elements
	for _, element in ipairs(gcdTabElements) do
		element:Hide()
		element:SetParent(nil)
	end
	wipe(gcdTabElements)
	
	local function track(element)
		table.insert(gcdTabElements, element)
		return element
	end
	
	local yOffset = -10
	
	-- ═══════════════════════════════════════════════════════════════════════════
	-- GCD ROW OPTIONS
	-- ═══════════════════════════════════════════════════════════════════════════
	
	local title = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
	title:SetPoint("TOPLEFT", 5, yOffset)
	title:SetText("GCD Row Options")
	yOffset = yOffset - 25
	
	local desc = track(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	desc:SetPoint("TOPLEFT", 5, yOffset)
	desc:SetText("Toggle which indicators appear in the GCD status row.")
	desc:SetTextColor(0.7, 0.7, 0.7)
	yOffset = yOffset - 25
	
	-- Ensure gcdSettings exists
	if not settings.gcdSettings then
		settings.gcdSettings = {
			showGcdRow = true,
			showStance = true,
			showGcd = true,
			showCombat = true,
			showAggro = true,
		}
	end
	
	-- Create toggle for each option
	for _, opt in ipairs(GCD_INDICATOR_OPTIONS) do
		local checkbox = track(CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate"))
		checkbox:SetSize(24, 24)
		checkbox:SetPoint("TOPLEFT", 10, yOffset)
		checkbox:SetChecked(settings.gcdSettings[opt.key] ~= false)
		
		if opt.disabled then
			checkbox:Disable()
			checkbox:SetAlpha(0.5)
		else
			checkbox:SetScript("OnClick", function(self)
				settings.gcdSettings[opt.key] = self:GetChecked()
				GCDI.reposition_all()
			end)
		end
		
		local label = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
		label:SetPoint("LEFT", checkbox, "RIGHT", 5, 0)
		label:SetText(opt.name)
		if opt.disabled then
			label:SetTextColor(0.5, 0.5, 0.5)
		end
		
		local descText = track(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
		descText:SetPoint("LEFT", label, "RIGHT", 15, 0)
		if opt.disabled then
			descText:SetText("- " .. opt.desc .. " (coming soon)")
			descText:SetTextColor(0.4, 0.4, 0.4)
		else
			descText:SetText("- " .. opt.desc)
			descText:SetTextColor(0.6, 0.6, 0.6)
		end
		
		yOffset = yOffset - 28
	end
	
	yOffset = yOffset - 15
	
	-- ═══════════════════════════════════════════════════════════════════════════
	-- MOB COUNT SETTINGS
	-- ═══════════════════════════════════════════════════════════════════════════
	
	local mobSep = track(frame:CreateTexture(nil, "ARTWORK"))
	mobSep:SetColorTexture(0.4, 0.4, 0.4, 1)
	mobSep:SetSize(480, 1)
	mobSep:SetPoint("TOPLEFT", 5, yOffset)
	yOffset = yOffset - 20
	
	local mobTitle = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
	mobTitle:SetPoint("TOPLEFT", 5, yOffset)
	mobTitle:SetText("Mob Count Settings")
	yOffset = yOffset - 25
	
	local mobDesc = track(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	mobDesc:SetPoint("TOPLEFT", 5, yOffset)
	mobDesc:SetText("Configure the nearby mob count indicator. White = at or above threshold, Black = below.")
	mobDesc:SetTextColor(0.7, 0.7, 0.7)
	yOffset = yOffset - 25
	
	-- Mob Count Range dropdown
	local rangeLabel = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	rangeLabel:SetPoint("TOPLEFT", 10, yOffset)
	rangeLabel:SetText("Detection Range:")
	
	local rangeDropdown = track(CreateFrame("Frame", nil, frame, "UIDropDownMenuTemplate"))
	rangeDropdown:SetPoint("LEFT", rangeLabel, "RIGHT", -5, -2)
	UIDropDownMenu_SetWidth(rangeDropdown, 100)
	
	local rangeOptions = { 5, 8, 10, 15, 20, 28, 40 }
	local rangeLabels = { "5 yards (melee)", "8 yards", "10 yards", "15 yards", "20 yards", "28 yards", "40 yards" }
	
	local function initRangeDropdown(self, level)
		local currentRange = settings.gcdSettings.mobCountRange or 8
		for i, range in ipairs(rangeOptions) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = rangeLabels[i]
			info.value = range
			info.checked = (currentRange == range)
			info.func = function()
				settings.gcdSettings.mobCountRange = range
				UIDropDownMenu_SetText(rangeDropdown, rangeLabels[i])
				GCDI.auto_save_to_profile()
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end
	UIDropDownMenu_Initialize(rangeDropdown, initRangeDropdown)
	
	-- Set initial text
	local currentRange = settings.gcdSettings.mobCountRange or 8
	for i, range in ipairs(rangeOptions) do
		if range == currentRange then
			UIDropDownMenu_SetText(rangeDropdown, rangeLabels[i])
			break
		end
	end
	yOffset = yOffset - 35
	
	-- Mob Count Threshold dropdown
	local thresholdLabel = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	thresholdLabel:SetPoint("TOPLEFT", 10, yOffset)
	thresholdLabel:SetText("Mob Threshold:")
	
	local thresholdDropdown = track(CreateFrame("Frame", nil, frame, "UIDropDownMenuTemplate"))
	thresholdDropdown:SetPoint("LEFT", thresholdLabel, "RIGHT", 5, -2)
	UIDropDownMenu_SetWidth(thresholdDropdown, 80)
	
	local function initThresholdDropdown(self, level)
		local currentThreshold = settings.gcdSettings.mobCountThreshold or 3
		for threshold = 1, 10 do
			local info = UIDropDownMenu_CreateInfo()
			info.text = tostring(threshold) .. (threshold == 1 and " mob" or " mobs")
			info.value = threshold
			info.checked = (currentThreshold == threshold)
			info.func = function()
				settings.gcdSettings.mobCountThreshold = threshold
				UIDropDownMenu_SetText(thresholdDropdown, tostring(threshold) .. (threshold == 1 and " mob" or " mobs"))
				GCDI.auto_save_to_profile()
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end
	UIDropDownMenu_Initialize(thresholdDropdown, initThresholdDropdown)
	
	local currentThreshold = settings.gcdSettings.mobCountThreshold or 3
	UIDropDownMenu_SetText(thresholdDropdown, tostring(currentThreshold) .. (currentThreshold == 1 and " mob" or " mobs"))
	yOffset = yOffset - 35
	
	-- Help text
	local mobHelp = track(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"))
	mobHelp:SetPoint("TOPLEFT", 15, yOffset)
	mobHelp:SetText("Tip: Uses nameplates to count nearby hostile mobs. Indicator turns white when mob count >= threshold.")
	mobHelp:SetTextColor(0.5, 0.5, 0.5)
	yOffset = yOffset - 20
	
	-- ═══════════════════════════════════════════════════════════════════════════
	-- STANCE/FORM COLORS
	-- ═══════════════════════════════════════════════════════════════════════════
	
	local sep1 = track(frame:CreateTexture(nil, "ARTWORK"))
	sep1:SetColorTexture(0.4, 0.4, 0.4, 1)
	sep1:SetSize(480, 1)
	sep1:SetPoint("TOPLEFT", 5, yOffset)
	yOffset = yOffset - 20
	
	local stanceTitle = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
	stanceTitle:SetPoint("TOPLEFT", 5, yOffset)
	stanceTitle:SetText("Stance/Form Colors")
	yOffset = yOffset - 25
	
	local stanceDesc = track(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	stanceDesc:SetPoint("TOPLEFT", 5, yOffset)
	stanceDesc:SetText("The stance indicator changes color based on your current form or stance.")
	stanceDesc:SetTextColor(0.7, 0.7, 0.7)
	yOffset = yOffset - 20
	
	-- Get player's class
	local _, playerClass = UnitClass("player")
	local formColors = GCDI.FORM_COLORS
	
	-- Class name header
	local className = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	className:SetPoint("TOPLEFT", 10, yOffset)
	className:SetText("Your Class: |cffffcc00" .. (playerClass or "Unknown") .. "|r")
	yOffset = yOffset - 25
	
	-- Get available forms dynamically from the game API
	local currentForm = GetShapeshiftForm() or 0
	local formsToShow = GCDI.GetAvailableForms()
	
	-- Add color info to each form
	for _, formInfo in ipairs(formsToShow) do
		formInfo.color = formColors[formInfo.index] or formColors.default
		formInfo.isCurrent = (currentForm == formInfo.index)
	end
	
	-- Display each form
	for _, formInfo in ipairs(formsToShow) do
		local row = track(CreateFrame("Frame", nil, frame))
		row:SetSize(400, 20)
		row:SetPoint("TOPLEFT", 15, yOffset)
		
		-- Color swatch
		local colorSwatch = track(row:CreateTexture(nil, "ARTWORK"))
		colorSwatch:SetSize(16, 16)
		colorSwatch:SetPoint("LEFT", 0, 0)
		colorSwatch:SetColorTexture(formInfo.color[1], formInfo.color[2], formInfo.color[3], 1)
		
		-- Border around swatch
		local swatchBorder = track(row:CreateTexture(nil, "OVERLAY"))
		swatchBorder:SetSize(18, 18)
		swatchBorder:SetPoint("CENTER", colorSwatch, "CENTER", 0, 0)
		swatchBorder:SetColorTexture(0.3, 0.3, 0.3, 1)
		colorSwatch:SetDrawLayer("OVERLAY", 1)
		
		-- Form name
		local formLabel = track(row:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
		formLabel:SetPoint("LEFT", colorSwatch, "RIGHT", 10, 0)
		
		local labelText = string.format("[%d] %s", formInfo.index, formInfo.name)
		if formInfo.isCurrent then
			labelText = labelText .. " |cff00ff00(Current)|r"
		end
		formLabel:SetText(labelText)
		
		yOffset = yOffset - 22
	end
	
	yOffset = yOffset - 15
	
	-- ═══════════════════════════════════════════════════════════════════════════
	-- INDICATOR LEGEND
	-- ═══════════════════════════════════════════════════════════════════════════
	
	local sep2 = track(frame:CreateTexture(nil, "ARTWORK"))
	sep2:SetColorTexture(0.4, 0.4, 0.4, 1)
	sep2:SetSize(480, 1)
	sep2:SetPoint("TOPLEFT", 5, yOffset)
	yOffset = yOffset - 20
	
	local legendTitle = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
	legendTitle:SetPoint("TOPLEFT", 5, yOffset)
	legendTitle:SetText("Indicator Legend")
	yOffset = yOffset - 25
	
	-- GCD Bar legend
	local gcdLegend = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	gcdLegend:SetPoint("TOPLEFT", 10, yOffset)
	gcdLegend:SetText("|cffffffffGCD Bar:|r Shows global cooldown progress (white bar)")
	yOffset = yOffset - 20
	
	-- Combat indicator legend
	local combatLegend = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	combatLegend:SetPoint("TOPLEFT", 10, yOffset)
	combatLegend:SetText("|cffff0000Combat:|r Red = In Combat, |cff333333Black = Out of Combat|r")
	yOffset = yOffset - 20
	
	-- Aggro indicator legend
	local aggroLegend = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	aggroLegend:SetPoint("TOPLEFT", 10, yOffset)
	aggroLegend:SetText("|cffff8000Aggro:|r Orange = Has Threat, |cff666666Grey = No Threat|r, |cffffffffWhite = No Target|r")
	yOffset = yOffset - 20
	
	-- Update scroll child height
	frame:SetHeight(math.abs(yOffset) + 20)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RESOURCES TAB
-- ═══════════════════════════════════════════════════════════════════════════

local RESOURCE_NAMES = {
	{ key = "health", name = "Health", color = {0, 0.8, 0}, barType = "continuous", powerType = nil, classes = "All" },
	{ key = "mana", name = "Mana", color = {0, 0.5, 1}, barType = "continuous", powerType = Enum.PowerType.Mana, classes = "Mage, Priest, Warlock, Paladin, Druid, Shaman, Monk, Evoker" },
	{ key = "rage", name = "Rage", color = {0.8, 0, 0}, barType = "continuous", powerType = Enum.PowerType.Rage, classes = "Warrior, Druid (Bear)" },
	{ key = "energy", name = "Energy", color = {1, 0.85, 0}, barType = "continuous", powerType = Enum.PowerType.Energy, classes = "Rogue, Druid (Cat), Monk" },
	{ key = "focus", name = "Focus", color = {1, 0.5, 0.2}, barType = "continuous", powerType = Enum.PowerType.Focus, classes = "Hunter" },
	{ key = "runicPower", name = "Runic Power", color = {0, 0.82, 1}, barType = "continuous", powerType = Enum.PowerType.RunicPower, classes = "Death Knight" },
	{ key = "runes", name = "Runes", color = {0.8, 0.2, 0.2}, barType = "charges", powerType = Enum.PowerType.Runes, classes = "Death Knight" },
	{ key = "comboPoints", name = "Combo Points", color = {1, 0.5, 0}, barType = "charges", powerType = Enum.PowerType.ComboPoints, classes = "Rogue, Druid (Cat)" },
	{ key = "soulShards", name = "Soul Shards", color = {0.58, 0.51, 0.79}, barType = "charges", powerType = Enum.PowerType.SoulShards, classes = "Warlock" },
	{ key = "holyPower", name = "Holy Power", color = {0.95, 0.9, 0.6}, barType = "charges", powerType = Enum.PowerType.HolyPower, classes = "Paladin" },
	{ key = "chi", name = "Chi", color = {0.71, 1, 0.92}, barType = "charges", powerType = Enum.PowerType.Chi, classes = "Monk (Windwalker)" },
	{ key = "arcaneCharges", name = "Arcane Charges", color = {0.1, 0.1, 0.98}, barType = "charges", powerType = Enum.PowerType.ArcaneCharges, classes = "Mage (Arcane)" },
	{ key = "insanity", name = "Insanity", color = {0.4, 0, 0.8}, barType = "continuous", powerType = Enum.PowerType.Insanity, classes = "Priest (Shadow)" },
	{ key = "maelstrom", name = "Maelstrom", color = {0, 0.5, 1}, barType = "continuous", powerType = Enum.PowerType.Maelstrom, classes = "Shaman (Elemental)" },
	{ key = "fury", name = "Fury", color = {0.79, 0.26, 0.99}, barType = "continuous", powerType = Enum.PowerType.Fury, classes = "Demon Hunter (Havoc)" },
	{ key = "pain", name = "Pain", color = {1, 0.61, 0}, barType = "continuous", powerType = Enum.PowerType.Pain, classes = "Demon Hunter (Vengeance)" },
	{ key = "astralPower", name = "Astral Power", color = {0.3, 0.52, 0.9}, barType = "continuous", powerType = Enum.PowerType.LunarPower, classes = "Druid (Balance)" },
	{ key = "essence", name = "Essence", color = {0.27, 0.84, 0.76}, barType = "charges", powerType = Enum.PowerType.Essence, classes = "Evoker" },
}

local function refresh_resources_tab()
	if not optionsFrame or not optionsFrame.resourcesScrollChild then return end
	
	-- Always sync settings reference
	settings = GCDI.settings
	
	-- Ensure resourceSettings exists
	if not settings.resourceSettings then
		settings.resourceSettings = {}
	end
	
	-- Clear existing elements
	for _, element in pairs(resourcesTabElements) do
		if element.Hide then element:Hide() end
		if element.SetParent then element:SetParent(nil) end
	end
	wipe(resourcesTabElements)
	
	local scrollChild = optionsFrame.resourcesScrollChild
	local yOffset = -10
	
	local function track(element)
		table.insert(resourcesTabElements, element)
		return element
	end
	
	-- Section title
	local sectionTitle = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
	sectionTitle:SetPoint("TOPLEFT", 10, yOffset)
	sectionTitle:SetText("Resource Bars")
	yOffset = yOffset - 25
	
	local sectionDesc = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	sectionDesc:SetPoint("TOPLEFT", 10, yOffset)
	sectionDesc:SetText("Toggle which resource bars are displayed.")
	sectionDesc:SetTextColor(0.7, 0.7, 0.7)
	yOffset = yOffset - 30
	
	-- Helper to format numbers human-readable
	local function formatNumber(num)
		if num >= 1000000 then
			return string.format("%.1fM", num / 1000000)
		elseif num >= 1000 then
			return string.format("%.1fK", num / 1000)
		else
			return tostring(num)
		end
	end
	
	-- Column headers
	local nameHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	nameHeader:SetPoint("TOPLEFT", 55, yOffset)
	nameHeader:SetText("Resource")
	
	local maxHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	maxHeader:SetPoint("TOPLEFT", 160, yOffset)
	maxHeader:SetWidth(40)
	maxHeader:SetJustifyH("CENTER")
	maxHeader:SetText("Max")
	
	local typeHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	typeHeader:SetPoint("TOPLEFT", 205, yOffset)
	typeHeader:SetWidth(55)
	typeHeader:SetJustifyH("CENTER")
	typeHeader:SetText("Type")
	
	local classHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	classHeader:SetPoint("TOPLEFT", 265, yOffset)
	classHeader:SetText("Class")
	yOffset = yOffset - 20
	
	-- Create checkbox for each resource
	for _, resource in ipairs(RESOURCE_NAMES) do
		local row = track(CreateFrame("Frame", nil, scrollChild))
		row:SetSize(520, 30)
		row:SetPoint("TOPLEFT", 10, yOffset)
		
		-- Enabled checkbox
		local checkbox = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		checkbox:SetSize(24, 24)
		checkbox:SetPoint("LEFT", 0, 0)
		
		-- Default to enabled if not set
		local isEnabled = settings.resourceSettings[resource.key]
		if isEnabled == nil then
			isEnabled = true
			settings.resourceSettings[resource.key] = true
		end
		checkbox:SetChecked(isEnabled)
		
		checkbox:SetScript("OnClick", function(self)
			settings.resourceSettings[resource.key] = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.reposition_all()
		end)
		
		-- Color swatch
		local colorSwatch = row:CreateTexture(nil, "ARTWORK")
		colorSwatch:SetSize(16, 16)
		colorSwatch:SetPoint("LEFT", checkbox, "RIGHT", 5, 0)
		colorSwatch:SetColorTexture(resource.color[1], resource.color[2], resource.color[3], 1)
		
		-- Resource name
		local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		nameText:SetPoint("LEFT", colorSwatch, "RIGHT", 10, 0)
		nameText:SetWidth(110)
		nameText:SetJustifyH("LEFT")
		nameText:SetText(resource.name)
		
		-- Get max value
		local maxValue = 0
		if resource.key == "health" then
			local rawMax = UnitHealthMax("player")
			maxValue = tonumber(rawMax) or 0
		elseif resource.powerType then
			local rawMax = UnitPowerMax("player", resource.powerType)
			maxValue = tonumber(rawMax) or 0
		end
		
		-- Max value display (centered)
		local maxText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		maxText:SetPoint("LEFT", 150, 0)
		maxText:SetWidth(40)
		maxText:SetJustifyH("CENTER")
		if maxValue > 0 then
			maxText:SetText("|cffffffff" .. formatNumber(maxValue) .. "|r")
		else
			maxText:SetText("|cff666666-|r")
		end
		
		-- Bar type display (centered)
		local typeText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		typeText:SetPoint("LEFT", 195, 0)
		typeText:SetWidth(55)
		typeText:SetJustifyH("CENTER")
		if resource.barType == "charges" then
			typeText:SetText("|cff00ccffCharges|r")
		else
			typeText:SetText("|cff88ff88Bar|r")
		end
		
		-- Class display
		local classText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		classText:SetPoint("LEFT", 255, 0)
		classText:SetWidth(200)
		classText:SetJustifyH("LEFT")
		classText:SetText("|cff888888" .. (resource.classes or "") .. "|r")
		
		yOffset = yOffset - 35
	end
	
	scrollChild:SetHeight(math.abs(yOffset) + 20)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELLS TAB
-- ═══════════════════════════════════════════════════════════════════════════

local spellsTabElements = {}  -- Track all UI elements created in spells tab

local function clear_spells_tab_elements()
	for _, element in pairs(spellsTabElements) do
		if element.Hide then element:Hide() end
		if element.SetParent then element:SetParent(nil) end
	end
	wipe(spellsTabElements)
	for _, row in pairs(spellRows) do
		row:Hide()
		row:SetParent(nil)
	end
	wipe(spellRows)
end

-- Helper to track created elements
local function track(element)
	table.insert(spellsTabElements, element)
	return element
end

local function refresh_spells_tab()
	if not optionsFrame or not optionsFrame.spellsScrollChild then return end
	
	-- Always sync settings reference
	settings = GCDI.settings
	
	-- Clear ALL existing elements (not just spell rows)
	clear_spells_tab_elements()
	
	local scrollChild = optionsFrame.spellsScrollChild
	local yOffset = -10
	
	-- Global range fallback
	local globalLabel = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	globalLabel:SetPoint("TOPLEFT", 10, yOffset)
	globalLabel:SetText("Global Range:")
	
	local globalDropdown = track(create_range_dropdown(scrollChild, 130, settings.globalRangeFallback or 0, function(index)
		settings.globalRangeFallback = index
		GCDI.UpdateRangeIndicators()
	end))
	globalDropdown:SetPoint("LEFT", globalLabel, "RIGHT", -5, -2)
	
	-- Rescan Spells button
	local rescanSpellsBtn = track(CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate"))
	rescanSpellsBtn:SetSize(100, 22)
	rescanSpellsBtn:SetPoint("LEFT", globalDropdown, "RIGHT", 100, 2)
	rescanSpellsBtn:SetText("Rescan Spells")
	rescanSpellsBtn:SetScript("OnClick", function()
		GCDI.scan_spells()
		C_Timer.After(0.2, refresh_spells_tab)
	end)
	rescanSpellsBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Rescan Spells")
		GameTooltip:AddLine("Re-scan your spellbook for new abilities.", 1, 1, 1, true)
		GameTooltip:AddLine("Only affects spells, not items or buffs.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	rescanSpellsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	
	yOffset = yOffset - 35
	
	-- Column headers (row starts at x=10, so add 10 to row-relative positions)
	local enabledHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	enabledHeader:SetPoint("TOPLEFT", 14, yOffset)  -- checkbox at row LEFT 0, centered
	enabledHeader:SetText("On")
	
	local selfCastHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	selfCastHeader:SetPoint("TOPLEFT", 40, yOffset)  -- checkbox at row LEFT 28, centered
	selfCastHeader:SetText("Self")
	
	local iconTrackHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	iconTrackHeader:SetPoint("TOPLEFT", 70, yOffset)  -- checkbox at row LEFT 56, centered
	iconTrackHeader:SetText("Ico")
	
	local spellNameHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	spellNameHeader:SetPoint("TOPLEFT", 94, yOffset)  -- icon at row LEFT 84
	spellNameHeader:SetText("Spell")
	
	local nativeHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	nativeHeader:SetPoint("TOPLEFT", 210, yOffset)  -- indicator at row LEFT 200
	nativeHeader:SetText("|cff00ff00N|r")
	
	local rangeHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	rangeHeader:SetPoint("TOPLEFT", 240, yOffset)  -- dropdown at row LEFT 213 (+ dropdown padding)
	rangeHeader:SetText("Range Override")
	
	local orderHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	orderHeader:SetPoint("TOPLEFT", 415, yOffset)  -- buttons at row LEFT 405
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
			local disabledSep = track(scrollChild:CreateTexture(nil, "ARTWORK"))
			disabledSep:SetColorTexture(0.4, 0.4, 0.4, 1)
			disabledSep:SetSize(450, 1)
			disabledSep:SetPoint("TOPLEFT", 10, yOffset)
			yOffset = yOffset - 5
			
			local disabledLabel = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
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
			local newValue = self:GetChecked()
			
			-- Update via GCDI.settings to ensure main file sees the change
			if not GCDI.settings.spellSettings then
				GCDI.settings.spellSettings = {}
			end
			if not GCDI.settings.spellSettings[spellID] then
				GCDI.settings.spellSettings[spellID] = {}
			end
			GCDI.settings.spellSettings[spellID].enabled = newValue
			
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
			if not GCDI.settings.spellSettings[spellID] then
				GCDI.settings.spellSettings[spellID] = {}
			end
			GCDI.settings.spellSettings[spellID].selfCast = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.rebuild_spell_bars()
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
			if not GCDI.settings.spellSettings[spellID] then
				GCDI.settings.spellSettings[spellID] = {}
			end
			GCDI.settings.spellSettings[spellID].trackIcon = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.rebuild_spell_bars()
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
		
		-- Tooltip for indicator (same position as the indicator text)
		local indicatorTooltip = CreateFrame("Frame", nil, row)
		indicatorTooltip:SetPoint("LEFT", 198, 0)
		indicatorTooltip:SetSize(24, 24)
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
			local currentSpellSettings = GCDI.settings.spellSettings and GCDI.settings.spellSettings[spellID] or {}
			
			if currentSpellSettings.hasNativeRange then
				info.text = "|cff00ff00Native|r"
				info.value = -1
				info.checked = (currentSpellSettings.rangeFallback == nil)
				info.func = function()
					if not GCDI.settings.spellSettings[spellID] then
						GCDI.settings.spellSettings[spellID] = {}
					end
					GCDI.settings.spellSettings[spellID].rangeFallback = nil
					UIDropDownMenu_SetSelectedID(rangeDropdown, 1)
					GCDI.auto_save_to_profile()
					GCDI.UpdateRangeIndicators()
				end
				UIDropDownMenu_AddButton(info, level)
			else
				info.text = "Use Global"
				info.value = -1
				info.checked = (currentSpellSettings.rangeFallback == nil)
				info.func = function()
					if not GCDI.settings.spellSettings[spellID] then
						GCDI.settings.spellSettings[spellID] = {}
					end
					GCDI.settings.spellSettings[spellID].rangeFallback = nil
					UIDropDownMenu_SetSelectedID(rangeDropdown, 1)
					GCDI.auto_save_to_profile()
					GCDI.UpdateRangeIndicators()
				end
				UIDropDownMenu_AddButton(info, level)
			end
			
			local options = get_range_options_list()
			for listIdx, opt in ipairs(options) do
				info = UIDropDownMenu_CreateInfo()
				info.text = opt.name
				info.value = opt.index
				info.checked = (currentSpellSettings.rangeFallback == opt.index)
				info.func = function()
					if not GCDI.settings.spellSettings[spellID] then
						GCDI.settings.spellSettings[spellID] = {}
					end
					GCDI.settings.spellSettings[spellID].rangeFallback = opt.index
					UIDropDownMenu_SetSelectedID(rangeDropdown, listIdx + 1)
					GCDI.auto_save_to_profile()
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
	
	-- Always sync settings reference
	settings = GCDI.settings
	
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
	
	-- Rescan Items button
	local rescanItemsBtn = track(CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate"))
	rescanItemsBtn:SetSize(100, 22)
	rescanItemsBtn:SetPoint("TOPLEFT", 10, yOffset)
	rescanItemsBtn:SetText("Rescan Items")
	rescanItemsBtn:SetScript("OnClick", function()
		GCDI.scan_items()
		C_Timer.After(0.2, refresh_items_tab)
	end)
	rescanItemsBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Rescan Items")
		GameTooltip:AddLine("Re-scan for trinkets and consumables.", 1, 1, 1, true)
		GameTooltip:AddLine("Only affects items, not spells or buffs.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	rescanItemsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	yOffset = yOffset - 30
	
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
			local newValue = self:GetChecked()
			-- Update via GCDI.settings to ensure main file sees the change
			if not GCDI.settings.itemSettings then
				GCDI.settings.itemSettings = {}
			end
			if not GCDI.settings.itemSettings[itemKey] then
				GCDI.settings.itemSettings[itemKey] = {}
			end
			GCDI.settings.itemSettings[itemKey].enabled = newValue
			
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
			if not GCDI.settings.itemSettings[itemKey] then
				GCDI.settings.itemSettings[itemKey] = {}
			end
			GCDI.settings.itemSettings[itemKey].showCharges = self:GetChecked()
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
	
	-- Always sync settings reference
	settings = GCDI.settings
	
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
	
	-- Rescan Buffs button
	local rescanBuffsBtn = track(CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate"))
	rescanBuffsBtn:SetSize(100, 22)
	rescanBuffsBtn:SetPoint("TOPLEFT", 10, yOffset)
	rescanBuffsBtn:SetText("Rescan Buffs")
	rescanBuffsBtn:SetScript("OnClick", function()
		GCDI.scan_buffs()
		C_Timer.After(0.2, refresh_buffs_tab)
	end)
	rescanBuffsBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Rescan Buffs")
		GameTooltip:AddLine("Re-scan for tracked buffs from CDM.", 1, 1, 1, true)
		GameTooltip:AddLine("Only affects buffs, not spells or items.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	rescanBuffsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	yOffset = yOffset - 30
	
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
	
	local durationHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	durationHeader:SetPoint("TOPLEFT", 295, yOffset)
	durationHeader:SetText("Dur")
	
	local thresholdHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	thresholdHeader:SetPoint("TOPLEFT", 325, yOffset)
	thresholdHeader:SetText("Thr%")
	
	local orderHeader = track(scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"))
	orderHeader:SetPoint("TOPLEFT", 400, yOffset)
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
			if not GCDI.settings.buffSettings then
				GCDI.settings.buffSettings = {}
			end
			if not GCDI.settings.buffSettings[spellID] then
				GCDI.settings.buffSettings[spellID] = {}
			end
			GCDI.settings.buffSettings[spellID].enabled = self:GetChecked()
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
			if not GCDI.settings.buffSettings[spellID] then
				GCDI.settings.buffSettings[spellID] = {}
			end
			GCDI.settings.buffSettings[spellID].showStacks = self:GetChecked()
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
			local currentBuffSettings = GCDI.settings.buffSettings and GCDI.settings.buffSettings[spellID] or {}
			for stacks = 1, 10 do
				local info = UIDropDownMenu_CreateInfo()
				info.text = tostring(stacks)
				info.value = stacks
				info.checked = (currentBuffSettings.maxStacksDisplay == stacks)
				info.func = function()
					if not GCDI.settings.buffSettings[spellID] then
						GCDI.settings.buffSettings[spellID] = {}
					end
					GCDI.settings.buffSettings[spellID].maxStacksDisplay = stacks
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
		
		-- Duration bar checkbox
		local durationCb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		durationCb:SetPoint("LEFT", 290, 0)
		durationCb:SetSize(24, 24)
		durationCb:SetChecked(buffSettings.showDurationBar == true)
		durationCb:SetScript("OnClick", function(self)
			if not GCDI.settings.buffSettings[spellID] then
				GCDI.settings.buffSettings[spellID] = {}
			end
			GCDI.settings.buffSettings[spellID].showDurationBar = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.rebuild_buff_bars()
			GCDI.reposition_all()
		end)
		
		-- Threshold dropdown (5% increments)
		local thresholdDropdown = CreateFrame("Frame", "GCDI_BuffThreshold_" .. spellID, row, "UIDropDownMenuTemplate")
		thresholdDropdown:SetPoint("LEFT", 305, -3)
		UIDropDownMenu_SetWidth(thresholdDropdown, 50)
		
		local function initThresholdDropdown(self, level)
			local currentThreshold = buffSettings.durationThreshold or 30
			for pct = 5, 95, 5 do
				local info = UIDropDownMenu_CreateInfo()
				info.text = pct .. "%"
				info.value = pct
				info.checked = (currentThreshold == pct)
				info.func = function()
					if not GCDI.settings.buffSettings[spellID] then
						GCDI.settings.buffSettings[spellID] = {}
					end
					GCDI.settings.buffSettings[spellID].durationThreshold = pct
					UIDropDownMenu_SetText(thresholdDropdown, pct .. "%")
					GCDI.auto_save_to_profile()
					GCDI.rebuild_buff_bars()
					GCDI.reposition_all()
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end
		UIDropDownMenu_Initialize(thresholdDropdown, initThresholdDropdown)
		UIDropDownMenu_SetText(thresholdDropdown, (buffSettings.durationThreshold or 30) .. "%")
		
		-- Reorder buttons
		local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		upBtn:SetSize(22, 18)
		upBtn:SetPoint("LEFT", 395, 0)
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
	
	if optionsFrame.gcdTabBtn then
		if tabName == "gcd" then
			optionsFrame.gcdTabBtn:SetNormalFontObject("GameFontHighlight")
			optionsFrame.gcdTabBtn:GetFontString():SetTextColor(1, 1, 1)
		else
			optionsFrame.gcdTabBtn:SetNormalFontObject("GameFontNormal")
			optionsFrame.gcdTabBtn:GetFontString():SetTextColor(0.7, 0.7, 0.7)
		end
	end
	if optionsFrame.resourcesTabBtn then
		if tabName == "resources" then
			optionsFrame.resourcesTabBtn:SetNormalFontObject("GameFontHighlight")
			optionsFrame.resourcesTabBtn:GetFontString():SetTextColor(1, 1, 1)
		else
			optionsFrame.resourcesTabBtn:SetNormalFontObject("GameFontNormal")
			optionsFrame.resourcesTabBtn:GetFontString():SetTextColor(0.7, 0.7, 0.7)
		end
	end
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
	if optionsFrame.profilesTabBtn then
		if tabName == "profiles" then
			optionsFrame.profilesTabBtn:SetNormalFontObject("GameFontHighlight")
			optionsFrame.profilesTabBtn:GetFontString():SetTextColor(1, 1, 1)
		else
			optionsFrame.profilesTabBtn:SetNormalFontObject("GameFontNormal")
			optionsFrame.profilesTabBtn:GetFontString():SetTextColor(0.7, 0.7, 0.7)
		end
	end

	if optionsFrame.gcdScrollFrame then
		optionsFrame.gcdScrollFrame:SetShown(tabName == "gcd")
	end
	if optionsFrame.resourcesScrollFrame then
		optionsFrame.resourcesScrollFrame:SetShown(tabName == "resources")
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
	if optionsFrame.profilesFrame then
		optionsFrame.profilesFrame:SetShown(tabName == "profiles")
	end
	
	if tabName == "gcd" then
		refresh_gcd_tab()
	elseif tabName == "resources" then
		refresh_resources_tab()
	elseif tabName == "spells" then
		refresh_spells_tab()
	elseif tabName == "items" then
		refresh_items_tab()
	elseif tabName == "buffs" then
		refresh_buffs_tab()
	elseif tabName == "profiles" then
		refresh_profiles_tab()
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PROFILES SECTION
-- ═══════════════════════════════════════════════════════════════════════════

-- Delete confirmation dialog
StaticPopupDialogs["GCDI_DELETE_PROFILE_CONFIRM"] = {
	text = "Delete profile '%s'?\n\nThis cannot be undone.",
	button1 = "Delete",
	button2 = "Cancel",
	OnAccept = function(self, profileName)
		local settings = GCDI.settings
		if settings and settings.profiles and settings.profiles[profileName] then
			settings.profiles[profileName] = nil
			if settings.currentProfile == profileName then
				settings.currentProfile = nil
			end
			print("|cff00ff00GCDIndicator:|r Profile '" .. profileName .. "' deleted!")
			if GCDI.refresh_options_frame then
				GCDI.refresh_options_frame()
			end
		end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Save confirmation dialog
StaticPopupDialogs["GCDI_SAVE_PROFILE_CONFIRM"] = {
	text = "Overwrite profile '%s' with current settings?",
	button1 = "Save",
	button2 = "Cancel",
	OnAccept = function(self, profileName)
		if profileName and profileName ~= "" then
			-- Perform the save (inline version of do_save_profile)
			local s = GCDI.settings
			if not s then return end
			
			s.profiles = s.profiles or {}
			
			local function deepcopy(orig, seen)
				if type(orig) ~= 'table' then return orig end
				seen = seen or {}
				if seen[orig] then return seen[orig] end
				local copy = {}
				seen[orig] = copy
				for k, v in pairs(orig) do
					local vtype = type(v)
					if vtype ~= 'function' and vtype ~= 'userdata' then
						if vtype == 'table' and type(v.GetObjectType) == 'function' then
							-- skip WoW frames
						else
							copy[k] = deepcopy(v, seen)
						end
					end
				end
				return copy
			end
			
			s.profiles[profileName] = {
				globalRangeFallback = s.globalRangeFallback,
				spellSettings = deepcopy(s.spellSettings),
				spellOrder = deepcopy(s.spellOrder),
				itemSettings = deepcopy(s.itemSettings or {}),
				itemOrder = deepcopy(s.itemOrder or {}),
				buffSettings = deepcopy(s.buffSettings or {}),
				buffOrder = deepcopy(s.buffOrder or {}),
				resourceSettings = deepcopy(s.resourceSettings or {}),
				gcdSettings = deepcopy(s.gcdSettings or {}),
				spellCatalog = deepcopy(GCDI.spellCatalog),
				itemCatalog = deepcopy(GCDI.itemCatalog),
				buffCatalog = deepcopy(GCDI.buffCatalog),
			}
			s.currentProfile = profileName
			
			print("|cff00ff00GCDIndicator:|r Profile '" .. profileName .. "' saved!")
			
			GCDI.rebuild_spell_bars()
			GCDI.rebuild_item_bars()
			GCDI.rebuild_buff_bars()
			GCDI.reposition_all()
			if GCDI.refresh_options_frame then
				GCDI.refresh_options_frame()
			end
		end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Import profile name dialog
StaticPopupDialogs["GCDI_IMPORT_PROFILE_NAME"] = {
	text = "Enter a name for the imported profile:",
	button1 = "Save",
	button2 = "Cancel",
	hasEditBox = true,
	editBoxWidth = 200,
	OnShow = function(self)
		local editBox = self.editBox or self.EditBox or _G[self:GetName().."EditBox"]
		if editBox then
			editBox:SetText("Imported Profile")
			editBox:HighlightText()
			editBox:SetFocus()
		end
	end,
	OnAccept = function(self, data)
		local editBox = self.editBox or self.EditBox or _G[self:GetName().."EditBox"]
		local name = editBox and editBox:GetText() or ""
		if name == "" then
			print("|cffff0000GCDIndicator:|r Profile name required!")
			return
		end
		
		if not data then
			print("|cffff0000GCDIndicator:|r No import data found!")
			return
		end
		
		-- Apply the imported settings
		local s = GCDI.settings
		if data.g ~= nil then s.globalRangeFallback = data.g end
		if data.ss then s.spellSettings = data.ss end
		if data.so then s.spellOrder = data.so end
		if data.is then s.itemSettings = data.is end
		if data.io then s.itemOrder = data.io end
		if data.bs then s.buffSettings = data.bs end
		if data.bo then s.buffOrder = data.bo end
		if data.rs then s.resourceSettings = data.rs end
		if data.gs then s.gcdSettings = data.gs end
		
		-- Save as new profile
		s.profiles = s.profiles or {}
		s.profiles[name] = {
			globalRangeFallback = s.globalRangeFallback,
			spellSettings = s.spellSettings,
			spellOrder = s.spellOrder,
			itemSettings = s.itemSettings or {},
			itemOrder = s.itemOrder or {},
			buffSettings = s.buffSettings or {},
			buffOrder = s.buffOrder or {},
			resourceSettings = s.resourceSettings or {},
			gcdSettings = s.gcdSettings or {},
		}
		s.currentProfile = name
		
		GCDI.rebuild_spell_bars()
		GCDI.rebuild_item_bars()
		GCDI.rebuild_buff_bars()
		GCDI.reposition_all()
		
		print("|cff00ff00GCDIndicator:|r Imported as profile '" .. name .. "'!")
		if GCDI.refresh_options_frame then GCDI.refresh_options_frame() end
	end,
	EditBoxOnEnterPressed = function(self)
		-- self here is the editbox, get the dialog parent
		local parent = self:GetParent()
		-- Find the actual dialog frame (may be nested)
		while parent and not parent.data do
			parent = parent:GetParent()
		end
		if parent then
			local data = parent.data
			StaticPopupDialogs["GCDI_IMPORT_PROFILE_NAME"].OnAccept(parent, data)
			parent:Hide()
		end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Local function to save profile (calls into main addon)
local function do_save_profile(name)
	if not name or name == "" then return false end
	
	-- Always use GCDI.settings directly to ensure we have the latest
	local s = GCDI.settings
	if not s then return false end
	
	s.profiles = s.profiles or {}
	
	-- Deep copy function (handles circular refs and skips frames)
	local function deepcopy(orig, seen)
		if type(orig) ~= 'table' then
			return orig
		end
		seen = seen or {}
		if seen[orig] then return seen[orig] end
		local copy = {}
		seen[orig] = copy
		for k, v in pairs(orig) do
			local vtype = type(v)
			if vtype ~= 'function' and vtype ~= 'userdata' then
				if vtype == 'table' and type(v.GetObjectType) == 'function' then
					-- skip WoW frames
				else
					copy[k] = deepcopy(v, seen)
				end
			end
		end
		return copy
	end
	
	s.profiles[name] = {
		globalRangeFallback = s.globalRangeFallback,
		spellSettings = deepcopy(s.spellSettings),
		spellOrder = deepcopy(s.spellOrder),
		itemSettings = deepcopy(s.itemSettings or {}),
		itemOrder = deepcopy(s.itemOrder or {}),
		buffSettings = deepcopy(s.buffSettings or {}),
		buffOrder = deepcopy(s.buffOrder or {}),
		resourceSettings = deepcopy(s.resourceSettings or {}),
		gcdSettings = deepcopy(s.gcdSettings or {}),
		spellCatalog = deepcopy(GCDI.spellCatalog),
		itemCatalog = deepcopy(GCDI.itemCatalog),
		buffCatalog = deepcopy(GCDI.buffCatalog),
	}
	s.currentProfile = name
	
	-- Update local settings reference
	settings = s
	
	print("|cff00ff00GCDIndicator:|r Profile '" .. name .. "' saved!")
	return true
end

-- Serialization functions from LibGCDI-Profiles
local serialize_compact = LibProfiles.serialize
local deserialize_compact = LibProfiles.deserialize

-- Export/Import popup window
local exportImportFrame = nil

local function show_export_import_popup(mode, initialText)
	if not exportImportFrame then
		exportImportFrame = CreateFrame("Frame", "GCDIExportImport", UIParent, "BasicFrameTemplateWithInset")
		exportImportFrame:SetSize(500, 350)
		exportImportFrame:SetPoint("CENTER")
		exportImportFrame:SetMovable(true)
		exportImportFrame:EnableMouse(true)
		exportImportFrame:RegisterForDrag("LeftButton")
		exportImportFrame:SetScript("OnDragStart", exportImportFrame.StartMoving)
		exportImportFrame:SetScript("OnDragStop", exportImportFrame.StopMovingOrSizing)
		exportImportFrame:SetFrameStrata("DIALOG")
		exportImportFrame:SetFrameLevel(100)
		
		-- Background for text area
		local editBg = exportImportFrame:CreateTexture(nil, "BACKGROUND", nil, 1)
		editBg:SetPoint("TOPLEFT", 12, -32)
		editBg:SetPoint("BOTTOMRIGHT", -12, 70)
		editBg:SetColorTexture(0, 0, 0, 0.8)
		
		-- Create scroll frame
		local scrollFrame = CreateFrame("ScrollFrame", "GCDIExportImportScroll", exportImportFrame, "UIPanelScrollFrameTemplate")
		scrollFrame:SetPoint("TOPLEFT", 14, -34)
		scrollFrame:SetPoint("BOTTOMRIGHT", -32, 72)
		exportImportFrame.scrollFrame = scrollFrame
		
		-- Create scroll child to hold the edit box
		local scrollChild = CreateFrame("Frame", nil, scrollFrame)
		scrollChild:SetSize(430, 220)
		scrollFrame:SetScrollChild(scrollChild)
		
		-- Create edit box - use InputBoxTemplate's child approach for clipboard support
		local editBox = CreateFrame("EditBox", "GCDIExportImportEditBox", scrollChild)
		editBox:SetAllPoints(scrollChild)
		editBox:SetMultiLine(true)
		editBox:SetFontObject("GameFontHighlight")
		editBox:SetAutoFocus(false)
		editBox:SetTextInsets(5, 5, 5, 5)
		editBox:SetMaxLetters(99999)
		editBox:EnableMouse(true)
		
		-- Critical for copy/paste to work
		editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		editBox:SetScript("OnTextChanged", function(self)
			local text = self:GetText() or ""
			local numLines = select(2, text:gsub("\n", "\n")) + 1
			local lineHeight = 14
			local newHeight = math.max(220, numLines * lineHeight + 20)
			scrollChild:SetHeight(newHeight)
		end)
		
		-- Make the scroll child clickable to focus the edit box
		scrollChild:EnableMouse(true)
		scrollChild:SetScript("OnMouseDown", function()
			editBox:SetFocus()
		end)
		
		exportImportFrame.editBox = editBox
		
		local importBtn = CreateFrame("Button", nil, exportImportFrame, "UIPanelButtonTemplate")
		importBtn:SetSize(100, 25)
		importBtn:SetPoint("BOTTOMLEFT", 10, 15)
		importBtn:SetText("Import")
		importBtn:SetScript("OnClick", function()
			local str = exportImportFrame.editBox:GetText()
			if not str or str == "" then
				print("|cffff0000GCDIndicator:|r Paste settings first!")
				return
			end
			
			local data, err = deserialize_compact(str)
			if not data then
				print("|cffff0000GCDIndicator:|r Import failed: " .. tostring(err))
				return
			end
			
			-- Hide export/import frame and show name dialog
			-- Pass data as 4th parameter to StaticPopup_Show
			exportImportFrame:Hide()
			StaticPopup_Show("GCDI_IMPORT_PROFILE_NAME", nil, nil, data)
		end)
		exportImportFrame.importBtn = importBtn
		
		local closeBtn = CreateFrame("Button", nil, exportImportFrame, "UIPanelButtonTemplate")
		closeBtn:SetSize(100, 25)
		closeBtn:SetPoint("BOTTOMRIGHT", -10, 15)
		closeBtn:SetText("Close")
		closeBtn:SetScript("OnClick", function() exportImportFrame:Hide() end)
		
		-- Select All button for export mode
		local selectAllBtn = CreateFrame("Button", nil, exportImportFrame, "UIPanelButtonTemplate")
		selectAllBtn:SetSize(100, 25)
		selectAllBtn:SetPoint("BOTTOM", 0, 15)
		selectAllBtn:SetText("Select All")
		selectAllBtn:SetScript("OnClick", function()
			exportImportFrame.editBox:SetFocus()
			exportImportFrame.editBox:HighlightText()
		end)
		exportImportFrame.selectAllBtn = selectAllBtn
		
		local helpText = exportImportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		helpText:SetPoint("BOTTOM", 0, 48)
		exportImportFrame.helpText = helpText
	end
	
	exportImportFrame.TitleText:SetText(mode == "export" and "Export Settings" or "Import Settings")
	exportImportFrame.editBox:SetText(initialText or "")
	
	if mode == "export" then
		exportImportFrame.importBtn:Hide()
		exportImportFrame.selectAllBtn:Show()
		exportImportFrame.helpText:SetText("Click 'Select All' then Ctrl+C to copy")
		exportImportFrame.editBox:SetFocus()
		exportImportFrame.editBox:HighlightText()
	else
		exportImportFrame.importBtn:Show()
		exportImportFrame.selectAllBtn:Hide()
		exportImportFrame.helpText:SetText("Click in box, Ctrl+V to paste, then Import")
		exportImportFrame.editBox:SetFocus()
	end
	
	exportImportFrame:Show()
end

local profilesTabElements = {}

refresh_profiles_tab = function()
	if not optionsFrame or not optionsFrame.profilesFrame then return end
	
	-- Always sync settings reference
	settings = GCDI.settings
	
	-- Clear existing elements
	for _, element in pairs(profilesTabElements) do
		if element.Hide then element:Hide() end
		if element.SetParent then element:SetParent(nil) end
	end
	wipe(profilesTabElements)
	
	local frame = optionsFrame.profilesFrame
	
	local function track(element)
		table.insert(profilesTabElements, element)
		return element
	end
	
	local yOffset = -10
	
	-- ═══════════════════════════════════════════════════════════════════════════
	-- PROFILE MANAGEMENT SECTION
	-- ═══════════════════════════════════════════════════════════════════════════
	
	local sectionTitle = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
	sectionTitle:SetPoint("TOPLEFT", 5, yOffset)
	sectionTitle:SetText("Profile Management")
	yOffset = yOffset - 25
	
	local sectionDesc = track(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	sectionDesc:SetPoint("TOPLEFT", 5, yOffset)
	sectionDesc:SetText("Load, save, or create profiles to manage different configurations.")
	sectionDesc:SetTextColor(0.7, 0.7, 0.7)
	yOffset = yOffset - 30
	
	-- Current Profile Dropdown
	local profileLabel = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	profileLabel:SetPoint("TOPLEFT", 5, yOffset)
	profileLabel:SetText("Current Profile:")
	
	local profileNames = GCDI.get_profile_names()
	local profileDropdown = track(CreateFrame("Frame", nil, frame, "UIDropDownMenuTemplate"))
	profileDropdown:SetPoint("LEFT", profileLabel, "RIGHT", -5, -2)
	UIDropDownMenu_SetWidth(profileDropdown, 150)
	
	local function initProfileDropdown(self, level)
		local info = UIDropDownMenu_CreateInfo()
		info.text = "-- None --"
		info.value = nil
		info.notCheckable = true
		info.func = function()
			GCDI.settings.currentProfile = nil
			UIDropDownMenu_SetText(profileDropdown, "-- None --")
			refresh_profiles_tab()
		end
		UIDropDownMenu_AddButton(info, level)
		
		for _, name in ipairs(profileNames) do
			info = UIDropDownMenu_CreateInfo()
			info.text = name
			info.value = name
			info.notCheckable = true
			info.func = function()
				GCDI.load_profile(name)
				UIDropDownMenu_SetText(profileDropdown, name)
				settings = GCDI.settings
				refresh_profiles_tab()
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end
	UIDropDownMenu_Initialize(profileDropdown, initProfileDropdown)
	UIDropDownMenu_SetText(profileDropdown, settings.currentProfile or "-- None --")
	yOffset = yOffset - 35
	
	-- Buttons row
	local hasCurrentProfile = settings.currentProfile and settings.currentProfile ~= ""
	
	local saveBtn = track(CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"))
	saveBtn:SetSize(80, 24)
	saveBtn:SetPoint("TOPLEFT", 5, yOffset)
	saveBtn:SetText("Save")
	saveBtn:SetEnabled(hasCurrentProfile)
	saveBtn:SetScript("OnClick", function()
		if GCDI.settings.currentProfile then
			local dialog = StaticPopup_Show("GCDI_SAVE_PROFILE_CONFIRM", GCDI.settings.currentProfile)
			if dialog then dialog.data = GCDI.settings.currentProfile end
		end
	end)
	saveBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Save Profile")
		if hasCurrentProfile then
			GameTooltip:AddLine("Overwrite '" .. settings.currentProfile .. "' with current settings.", 1, 1, 1, true)
		else
			GameTooltip:AddLine("Select a profile first.", 1, 0.5, 0.5, true)
		end
		GameTooltip:Show()
	end)
	saveBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	
	local deleteBtn = track(CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"))
	deleteBtn:SetSize(80, 24)
	deleteBtn:SetPoint("LEFT", saveBtn, "RIGHT", 5, 0)
	deleteBtn:SetText("Delete")
	deleteBtn:SetEnabled(hasCurrentProfile)
	deleteBtn:SetScript("OnClick", function()
		if settings.currentProfile then
			local dialog = StaticPopup_Show("GCDI_DELETE_PROFILE_CONFIRM", settings.currentProfile)
			if dialog then dialog.data = settings.currentProfile end
		end
	end)
	deleteBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Delete Profile")
		if hasCurrentProfile then
			GameTooltip:AddLine("Delete '" .. settings.currentProfile .. "'.", 1, 0.5, 0.5, true)
		end
		GameTooltip:Show()
	end)
	deleteBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
	yOffset = yOffset - 35
	
	-- Create New Profile
	local createLabel = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"))
	createLabel:SetPoint("TOPLEFT", 5, yOffset)
	createLabel:SetText("Create New:")
	
	local createEditBox = track(CreateFrame("EditBox", nil, frame, "InputBoxTemplate"))
	createEditBox:SetSize(150, 22)
	createEditBox:SetPoint("LEFT", createLabel, "RIGHT", 10, 0)
	createEditBox:SetAutoFocus(false)
	createEditBox:SetMaxLetters(30)
	
	local createBtn = track(CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"))
	createBtn:SetSize(80, 24)
	createBtn:SetPoint("LEFT", createEditBox, "RIGHT", 5, 0)
	createBtn:SetText("Create")
	createBtn:SetScript("OnClick", function()
		local name = createEditBox:GetText()
		if name and name ~= "" then
			do_save_profile(name)
			createEditBox:SetText("")
			createEditBox:ClearFocus()
			settings = GCDI.settings
			GCDI.rebuild_spell_bars()
			GCDI.rebuild_item_bars()
			GCDI.rebuild_buff_bars()
			GCDI.reposition_all()
			refresh_profiles_tab()
		else
			print("|cffff0000GCDIndicator:|r Enter a profile name!")
		end
	end)
	createEditBox:SetScript("OnEnterPressed", function() createBtn:Click() end)
	yOffset = yOffset - 45
	
	-- ═══════════════════════════════════════════════════════════════════════════
	-- EXPORT SECTION
	-- ═══════════════════════════════════════════════════════════════════════════
	
	local sep1 = track(frame:CreateTexture(nil, "ARTWORK"))
	sep1:SetColorTexture(0.4, 0.4, 0.4, 1)
	sep1:SetSize(480, 1)
	sep1:SetPoint("TOPLEFT", 5, yOffset)
	yOffset = yOffset - 20
	
	local exportImportTitle = track(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge"))
	exportImportTitle:SetPoint("TOPLEFT", 5, yOffset)
	exportImportTitle:SetText("Export / Import")
	yOffset = yOffset - 25
	
	local exportImportDesc = track(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight"))
	exportImportDesc:SetPoint("TOPLEFT", 5, yOffset)
	exportImportDesc:SetText("Share your settings with others or transfer between characters.")
	exportImportDesc:SetTextColor(0.7, 0.7, 0.7)
	yOffset = yOffset - 30
	
	local exportBtn = track(CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"))
	exportBtn:SetSize(120, 28)
	exportBtn:SetPoint("TOPLEFT", 5, yOffset)
	exportBtn:SetText("Export Settings")
	exportBtn:SetScript("OnClick", function()
		local exportData = {
			v = 1,
			g = settings.globalRangeFallback,
			ss = settings.spellSettings or {},
			so = settings.spellOrder or {},
			is = settings.itemSettings or {},
			io = settings.itemOrder or {},
			bs = settings.buffSettings or {},
			bo = settings.buffOrder or {},
			rs = settings.resourceSettings or {},
			gs = settings.gcdSettings or {},
		}
		
		local ok, str = pcall(serialize_compact, exportData)
		if ok and str then
			show_export_import_popup("export", str)
		else
			print("|cffff0000GCDIndicator:|r Export failed: " .. tostring(str))
		end
	end)
	
	local importBtn = track(CreateFrame("Button", nil, frame, "UIPanelButtonTemplate"))
	importBtn:SetSize(120, 28)
	importBtn:SetPoint("LEFT", exportBtn, "RIGHT", 10, 0)
	importBtn:SetText("Import Settings")
	importBtn:SetScript("OnClick", function()
		show_export_import_popup("import", "")
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
	
	if currentTab == "gcd" then
		refresh_gcd_tab()
	elseif currentTab == "resources" then
		refresh_resources_tab()
	elseif currentTab == "spells" then
		refresh_spells_tab()
	elseif currentTab == "items" then
		refresh_items_tab()
	elseif currentTab == "buffs" then
		refresh_buffs_tab()
	elseif currentTab == "profiles" then
		refresh_profiles_tab()
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
	
	-- TAB BUTTONS (moved up since profiles is now a tab)
	local tabY = -30
	
	-- GCD TAB (first tab)
	local gcdTabBtn = CreateFrame("Button", nil, optionsFrame)
	gcdTabBtn:SetSize(45, 24)
	gcdTabBtn:SetPoint("TOPLEFT", 15, tabY)
	gcdTabBtn:SetNormalFontObject("GameFontHighlight")
	gcdTabBtn:SetHighlightFontObject("GameFontHighlight")
	
	local gcdTabText = gcdTabBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	gcdTabText:SetPoint("CENTER")
	gcdTabText:SetText("GCD")
	gcdTabBtn:SetFontString(gcdTabText)
	
	local gcdTabBg = gcdTabBtn:CreateTexture(nil, "BACKGROUND")
	gcdTabBg:SetAllPoints()
	gcdTabBg:SetColorTexture(0.2, 0.2, 0.2, 0.8)
	
	gcdTabBtn:SetScript("OnClick", function() switch_tab("gcd") end)
	gcdTabBtn:SetScript("OnEnter", function() gcdTabBg:SetColorTexture(0.3, 0.3, 0.3, 0.8) end)
	gcdTabBtn:SetScript("OnLeave", function() gcdTabBg:SetColorTexture(0.2, 0.2, 0.2, 0.8) end)
	optionsFrame.gcdTabBtn = gcdTabBtn
	
	-- RESOURCES TAB (second tab)
	local resourcesTabBtn = CreateFrame("Button", nil, optionsFrame)
	resourcesTabBtn:SetSize(75, 24)
	resourcesTabBtn:SetPoint("LEFT", gcdTabBtn, "RIGHT", 5, 0)
	resourcesTabBtn:SetNormalFontObject("GameFontNormal")
	resourcesTabBtn:SetHighlightFontObject("GameFontHighlight")
	
	local resourcesTabText = resourcesTabBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	resourcesTabText:SetPoint("CENTER")
	resourcesTabText:SetText("Resources")
	resourcesTabBtn:SetFontString(resourcesTabText)
	
	local resourcesTabBg = resourcesTabBtn:CreateTexture(nil, "BACKGROUND")
	resourcesTabBg:SetAllPoints()
	resourcesTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
	
	resourcesTabBtn:SetScript("OnClick", function() switch_tab("resources") end)
	resourcesTabBtn:SetScript("OnEnter", function() resourcesTabBg:SetColorTexture(0.3, 0.3, 0.3, 0.8) end)
	resourcesTabBtn:SetScript("OnLeave", function() resourcesTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8) end)
	optionsFrame.resourcesTabBtn = resourcesTabBtn
	
	local spellsTabBtn = CreateFrame("Button", nil, optionsFrame)
	spellsTabBtn:SetSize(55, 24)
	spellsTabBtn:SetPoint("LEFT", resourcesTabBtn, "RIGHT", 5, 0)
	spellsTabBtn:SetNormalFontObject("GameFontNormal")
	spellsTabBtn:SetHighlightFontObject("GameFontHighlight")
	
	local spellsTabText = spellsTabBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	spellsTabText:SetPoint("CENTER")
	spellsTabText:SetText("Spells")
	spellsTabBtn:SetFontString(spellsTabText)
	
	local spellsTabBg = spellsTabBtn:CreateTexture(nil, "BACKGROUND")
	spellsTabBg:SetAllPoints()
	spellsTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
	
	spellsTabBtn:SetScript("OnClick", function() switch_tab("spells") end)
	spellsTabBtn:SetScript("OnEnter", function() spellsTabBg:SetColorTexture(0.3, 0.3, 0.3, 0.8) end)
	spellsTabBtn:SetScript("OnLeave", function() spellsTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8) end)
	optionsFrame.spellsTabBtn = spellsTabBtn
	
	local itemsTabBtn = CreateFrame("Button", nil, optionsFrame)
	itemsTabBtn:SetSize(50, 24)
	itemsTabBtn:SetPoint("LEFT", spellsTabBtn, "RIGHT", 5, 0)
	itemsTabBtn:SetNormalFontObject("GameFontNormal")
	itemsTabBtn:SetHighlightFontObject("GameFontHighlight")
	
	local itemsTabText = itemsTabBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	itemsTabText:SetPoint("CENTER")
	itemsTabText:SetText("Items")
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
	
	-- PROFILES TAB
	local profilesTabBtn = CreateFrame("Button", nil, optionsFrame)
	profilesTabBtn:SetSize(70, 24)
	profilesTabBtn:SetPoint("LEFT", settingsTabBtn, "RIGHT", 5, 0)
	profilesTabBtn:SetNormalFontObject("GameFontNormal")
	profilesTabBtn:SetHighlightFontObject("GameFontHighlight")
	
	local profilesTabText = profilesTabBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	profilesTabText:SetPoint("CENTER")
	profilesTabText:SetText("Profiles")
	profilesTabBtn:SetFontString(profilesTabText)
	
	local profilesTabBg = profilesTabBtn:CreateTexture(nil, "BACKGROUND")
	profilesTabBg:SetAllPoints()
	profilesTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
	
	profilesTabBtn:SetScript("OnClick", function() switch_tab("profiles") end)
	profilesTabBtn:SetScript("OnEnter", function() profilesTabBg:SetColorTexture(0.3, 0.3, 0.3, 0.8) end)
	profilesTabBtn:SetScript("OnLeave", function() profilesTabBg:SetColorTexture(0.15, 0.15, 0.15, 0.8) end)
	optionsFrame.profilesTabBtn = profilesTabBtn
	
	-- GCD SCROLL FRAME (shown by default)
	local gcdScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	gcdScrollFrame:SetPoint("TOPLEFT", 10, -60)
	gcdScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	optionsFrame.gcdScrollFrame = gcdScrollFrame
	
	local gcdScrollChild = CreateFrame("Frame", nil, gcdScrollFrame)
	gcdScrollChild:SetSize(450, 600)
	gcdScrollFrame:SetScrollChild(gcdScrollChild)
	optionsFrame.gcdScrollChild = gcdScrollChild
	
	-- RESOURCES SCROLL FRAME
	local resourcesScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	resourcesScrollFrame:SetPoint("TOPLEFT", 10, -60)
	resourcesScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	resourcesScrollFrame:Hide()
	optionsFrame.resourcesScrollFrame = resourcesScrollFrame
	
	local resourcesScrollChild = CreateFrame("Frame", nil, resourcesScrollFrame)
	resourcesScrollChild:SetSize(450, 400)
	resourcesScrollFrame:SetScrollChild(resourcesScrollChild)
	optionsFrame.resourcesScrollChild = resourcesScrollChild
	
	-- SPELLS SCROLL FRAME
	local spellsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	spellsScrollFrame:SetPoint("TOPLEFT", 10, -60)
	spellsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	spellsScrollFrame:Hide()
	optionsFrame.spellsScrollFrame = spellsScrollFrame
	
	local spellsScrollChild = CreateFrame("Frame", nil, spellsScrollFrame)
	spellsScrollChild:SetSize(450, 600)
	spellsScrollFrame:SetScrollChild(spellsScrollChild)
	optionsFrame.spellsScrollChild = spellsScrollChild
	
	-- ITEMS SCROLL FRAME
	local itemsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	itemsScrollFrame:SetPoint("TOPLEFT", 10, -60)
	itemsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	itemsScrollFrame:Hide()
	optionsFrame.itemsScrollFrame = itemsScrollFrame
	
	local itemsScrollChild = CreateFrame("Frame", nil, itemsScrollFrame)
	itemsScrollChild:SetSize(450, 600)
	itemsScrollFrame:SetScrollChild(itemsScrollChild)
	optionsFrame.itemsScrollChild = itemsScrollChild
	
	-- BUFFS SCROLL FRAME
	local buffsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	buffsScrollFrame:SetPoint("TOPLEFT", 10, -60)
	buffsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	buffsScrollFrame:Hide()
	optionsFrame.buffsScrollFrame = buffsScrollFrame
	
	local buffsScrollChild = CreateFrame("Frame", nil, buffsScrollFrame)
	buffsScrollChild:SetSize(450, 800)
	buffsScrollFrame:SetScrollChild(buffsScrollChild)
	optionsFrame.buffsScrollChild = buffsScrollChild
	
	-- SETTINGS FRAME
	local settingsFrame = CreateFrame("Frame", nil, optionsFrame)
	settingsFrame:SetPoint("TOPLEFT", 10, -60)
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
	
	-- PROFILES FRAME
	local profilesFrame = CreateFrame("Frame", nil, optionsFrame)
	profilesFrame:SetPoint("TOPLEFT", 10, -60)
	profilesFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	profilesFrame:Hide()
	optionsFrame.profilesFrame = profilesFrame
	
	-- BOTTOM BUTTONS
	local closeBtn = CreateFrame("Button", nil, optionsFrame, "UIPanelButtonTemplate")
	closeBtn:SetSize(80, 22)
	closeBtn:SetPoint("BOTTOMRIGHT", -10, 10)
	closeBtn:SetText("Close")
	closeBtn:SetScript("OnClick", function() optionsFrame:Hide() end)
	
	table.insert(UISpecialFrames, "GCDIndicatorOptions")
	
	currentTab = "gcd"
	refresh_options_frame()
	optionsFrame:Show()
end

-- Export create function
GCDI.create_options_frame = create_options_frame
