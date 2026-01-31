-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-Resources - Resource Bar Management for GCDIndicator
-- ═══════════════════════════════════════════════════════════════════════════

local MAJOR, MINOR = "LibGCDI-Resources", 2
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- Cache frequently used globals
local CreateFrame = CreateFrame
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitPower = UnitPower
local UnitPowerMax = UnitPowerMax
local tonumber = tonumber
local pairs = pairs
local math = math

-- ═══════════════════════════════════════════════════════════════════════════
-- RESOURCE COLORS
-- ═══════════════════════════════════════════════════════════════════════════

lib.RESOURCE_COLORS = {
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

-- ═══════════════════════════════════════════════════════════════════════════
-- RESOURCE BAR CREATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Create a resource bar
-- @param parent: Parent frame
-- @param name: Resource name (key)
-- @param color: {r, g, b} color table
-- @param configs: Configuration table with barHeight, bgPadding
-- @return table: { bar, container, separatorFrame }
function lib:CreateResourceBar(parent, name, color, configs)
	local barSize = configs.barHeight or 8
	local barWidth = 200
	local pad = configs.bgPadding or 2
	
	local container = CreateFrame("Frame", nil, parent)
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

-- ═══════════════════════════════════════════════════════════════════════════
-- RESOURCE BAR UPDATES
-- ═══════════════════════════════════════════════════════════════════════════

-- Update health bar
function lib:UpdateHealthBar(data, previewMode)
	if previewMode then return end
	if not data then return end
	local bar = data.bar
	local rawMax = UnitHealthMax("player")
	local max = tonumber(rawMax) or 100000
	if max > 0 then
		bar:SetMinMaxValues(0, max)
		bar:SetValue(UnitHealth("player"))
	end
end

-- Update a simple continuous resource bar
function lib:UpdateContinuousBar(data, powerType, defaultMax, previewMode)
	if previewMode then return end
	if not data then return end
	local bar = data.bar
	local rawMax = UnitPowerMax("player", powerType)
	local max = tonumber(rawMax) or defaultMax
	bar:SetMinMaxValues(0, math.max(max, 1))
	bar:SetValue(UnitPower("player", powerType))
end

-- Update a charge-based resource bar (like combo points) with separators
-- Now with min-2 display logic for classes that don't have the resource
function lib:UpdateChargeBar(data, powerType, defaultMax, configs, previewMode)
	if previewMode then return end
	if not data then return end
	local bar = data.bar
	local rawMax = UnitPowerMax("player", powerType)
	local actualMax = tonumber(rawMax) or 0
	-- If class doesn't have this resource (max = 0), show minimum 2 indicators for visual consistency
	local max = actualMax == 0 and 2 or math.max(actualMax, 1)
	
	bar:SetMinMaxValues(0, max)
	bar:SetValue(UnitPower("player", powerType))
	
	local totalWidth = 200
	local separatorWidth = 2
	local numSeparators = max - 1
	local totalSeparatorWidth = numSeparators * separatorWidth
	local segmentWidth = (totalWidth - totalSeparatorWidth) / max
	local pad = configs.bgPadding or 2
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

-- Update runes bar (Death Knight specific)
-- Now with min-2 display logic for non-DK classes
function lib:UpdateRunesBar(data, configs, previewMode)
	if previewMode then return end
	if not data then return end
	local bar = data.bar
	
	-- Check actual max runes (6 for DK, 0 for other classes)
	local rawMax = UnitPowerMax("player", Enum.PowerType.Runes)
	local actualMax = tonumber(rawMax) or 0
	-- If class doesn't have runes (max = 0), show minimum 2 indicators for visual consistency
	local max = actualMax == 0 and 2 or actualMax
	local current = UnitPower("player", Enum.PowerType.Runes) or 0
	
	bar:SetMinMaxValues(0, max)
	bar:SetValue(current)
	
	if not data.separators then
		data.separators = {}
	end
	
	-- Fixed total width of 200px, calculate segment width based on max
	local totalWidth = 200
	local separatorWidth = 2
	local numSeparators = max - 1
	local totalSeparatorWidth = numSeparators * separatorWidth
	local segmentWidth = (totalWidth - totalSeparatorWidth) / max
	local pad = configs.bgPadding or 2
	local barHeight = configs.barHeight or 8
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
			sep:SetSize(separatorWidth, barHeight)
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

-- Create separators for a charge bar (call once during init)
function lib:CreateChargeSeparators(data, maxCharges, configs)
	if not data or not data.separatorFrame then return end
	
	local barHeight = configs.barHeight or 8
	data.separators = data.separators or {}
	
	for i = 1, maxCharges - 1 do
		if not data.separators[i] then
			local sep = data.separatorFrame:CreateTexture(nil, "OVERLAY")
			sep:SetColorTexture(0, 0, 0, 1)
			sep:SetSize(2, barHeight)
			data.separators[i] = sep
		end
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RESOURCE DEFINITIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Get all resource definitions with metadata
function lib:GetResourceDefinitions()
	return {
		{ key = "health", name = "Health", barType = "Continuous", powerType = nil, classes = "All" },
		{ key = "mana", name = "Mana", barType = "Continuous", powerType = Enum.PowerType.Mana, classes = "Mage, Priest, Warlock, Paladin, Druid, Shaman, Monk, Evoker" },
		{ key = "rage", name = "Rage", barType = "Continuous", powerType = Enum.PowerType.Rage, classes = "Warrior, Druid (Bear)" },
		{ key = "energy", name = "Energy", barType = "Continuous", powerType = Enum.PowerType.Energy, classes = "Rogue, Druid (Cat), Monk" },
		{ key = "focus", name = "Focus", barType = "Continuous", powerType = Enum.PowerType.Focus, classes = "Hunter" },
		{ key = "runicPower", name = "Runic Power", barType = "Continuous", powerType = Enum.PowerType.RunicPower, classes = "Death Knight" },
		{ key = "runes", name = "Runes", barType = "Charges", powerType = Enum.PowerType.Runes, classes = "Death Knight", maxCharges = 6 },
		{ key = "comboPoints", name = "Combo Points", barType = "Charges", powerType = Enum.PowerType.ComboPoints, classes = "Rogue, Druid (Cat)" },
		{ key = "soulShards", name = "Soul Shards", barType = "Charges", powerType = Enum.PowerType.SoulShards, classes = "Warlock" },
		{ key = "holyPower", name = "Holy Power", barType = "Charges", powerType = Enum.PowerType.HolyPower, classes = "Paladin" },
		{ key = "chi", name = "Chi", barType = "Charges", powerType = Enum.PowerType.Chi, classes = "Monk (Windwalker)" },
		{ key = "arcaneCharges", name = "Arcane Charges", barType = "Charges", powerType = Enum.PowerType.ArcaneCharges, classes = "Mage (Arcane)" },
		{ key = "insanity", name = "Insanity", barType = "Continuous", powerType = Enum.PowerType.Insanity, classes = "Priest (Shadow)" },
		{ key = "maelstrom", name = "Maelstrom", barType = "Continuous", powerType = Enum.PowerType.Maelstrom, classes = "Shaman (Elemental)" },
		{ key = "fury", name = "Fury", barType = "Continuous", powerType = Enum.PowerType.Fury, classes = "Demon Hunter (Havoc)" },
		{ key = "pain", name = "Pain", barType = "Continuous", powerType = Enum.PowerType.Pain, classes = "Demon Hunter (Vengeance)" },
		{ key = "astralPower", name = "Astral Power", barType = "Continuous", powerType = Enum.PowerType.LunarPower, classes = "Druid (Balance)" },
		{ key = "essence", name = "Essence", barType = "Charges", powerType = Enum.PowerType.Essence, classes = "Evoker" },
	}
end

-- Get list of all resource keys in display order
function lib:GetResourceOrder()
	return {
		"health", "mana", "rage", "energy", "focus", "runicPower", "runes",
		"comboPoints", "soulShards", "holyPower", "chi", "arcaneCharges",
		"insanity", "maelstrom", "fury", "pain", "astralPower", "essence"
	}
end
