-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-Bars - Bar Creation Utilities for GCDIndicator
-- ═══════════════════════════════════════════════════════════════════════════

local MAJOR, MINOR = "LibGCDI-Bars", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- Cache frequently used globals
local CreateFrame = CreateFrame

-- ═══════════════════════════════════════════════════════════════════════════
-- COLORS
-- ═══════════════════════════════════════════════════════════════════════════

lib.RANGE_COLORS = {
	inRange = { 0.0, 0.8, 0.0 },
	outOfRange = { 0.8, 0.0, 0.0 },
	noTarget = { 0.3, 0.3, 0.3 },
}

lib.BUFF_COLORS = {
	active = { 0.2, 0.8, 0.2 },
	inactive = { 0.3, 0.3, 0.3 },
	stackEmpty = { 0, 0, 0 },
	stackHalf = { 0.4, 0.7, 1.0 },
	stackFull = { 0.2, 0.8, 0.2 },
}

-- ═══════════════════════════════════════════════════════════════════════════
-- BASE BAR CREATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Create a base cooldown bar container with icon
-- @param parent: Parent frame
-- @param configs: { barHeight, bgPadding }
-- @param texture: Icon texture path
-- @return table: { container, icon, clipContainer, bar, bg }
function lib:CreateBaseCooldownBar(parent, configs, texture)
	local barSize = configs.barHeight or 8
	local pad = configs.bgPadding or 2
	
	local container = CreateFrame("Frame", nil, parent)
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
	
	return {
		container = container,
		icon = icon,
		clipContainer = clipContainer,
		bar = bar,
		bg = bg,
	}
end

-- Create a range indicator square
-- @param parent: Parent container
-- @param anchorTo: Frame to anchor to (LEFT of anchorTo's RIGHT)
-- @param size: Size of the square
-- @return table: { base, overlay }
function lib:CreateRangeIndicator(parent, anchorTo, size)
	local rangeBase = parent:CreateTexture(nil, "ARTWORK")
	rangeBase:SetSize(size, size)
	rangeBase:SetPoint("LEFT", anchorTo, "RIGHT", 2, 0)
	rangeBase:SetColorTexture(1, 1, 1, 1)
	
	local rangeOverlay = parent:CreateTexture(nil, "OVERLAY")
	rangeOverlay:SetSize(size, size)
	rangeOverlay:SetPoint("CENTER", rangeBase, "CENTER", 0, 0)
	rangeOverlay:SetColorTexture(lib.RANGE_COLORS.noTarget[1], lib.RANGE_COLORS.noTarget[2], lib.RANGE_COLORS.noTarget[3], 1)
	
	return {
		base = rangeBase,
		overlay = rangeOverlay,
	}
end

-- Create charge indicators
-- @param parent: Parent container
-- @param anchorTo: Frame to anchor to
-- @param maxCharges: Number of charge indicators
-- @param size: Size of each indicator
-- @return table: Array of { bg, overlay } for each charge
function lib:CreateChargeIndicators(parent, anchorTo, maxCharges, size)
	local indicators = {}
	local prevElement = anchorTo
	
	for i = 1, maxCharges do
		local chargeBg = parent:CreateTexture(nil, "ARTWORK")
		chargeBg:SetSize(size, size)
		chargeBg:SetPoint("LEFT", prevElement, "RIGHT", 2, 0)
		chargeBg:SetColorTexture(0, 0.5, 1, 1)  -- Blue = available
		
		local chargeOverlay = parent:CreateTexture(nil, "OVERLAY")
		chargeOverlay:SetSize(size, size)
		chargeOverlay:SetPoint("CENTER", chargeBg, "CENTER", 0, 0)
		chargeOverlay:SetColorTexture(0, 0, 0, 1)  -- Black = on cooldown
		chargeOverlay:Hide()
		
		indicators[i] = {
			bg = chargeBg,
			overlay = chargeOverlay,
		}
		
		prevElement = chargeBg
	end
	
	return indicators
end

-- Create an icon change indicator
-- @param parent: Parent container
-- @param anchorTo: Frame to anchor to
-- @param size: Size of the indicator
-- @return table: { bg, overlay }
function lib:CreateIconChangeIndicator(parent, anchorTo, size)
	local iconChangeBg = parent:CreateTexture(nil, "ARTWORK")
	iconChangeBg:SetSize(size, size)
	iconChangeBg:SetPoint("LEFT", anchorTo, "RIGHT", 2, 0)
	iconChangeBg:SetColorTexture(0.3, 0.3, 0.3, 1)  -- Grey = normal
	
	local iconChangeOverlay = parent:CreateTexture(nil, "OVERLAY")
	iconChangeOverlay:SetSize(size, size)
	iconChangeOverlay:SetPoint("CENTER", iconChangeBg, "CENTER", 0, 0)
	iconChangeOverlay:SetColorTexture(0.8, 0.2, 0.2, 1)  -- Red = changed
	iconChangeOverlay:Hide()
	
	return {
		bg = iconChangeBg,
		overlay = iconChangeOverlay,
	}
end

-- Create a buff active indicator
-- @param parent: Parent container
-- @param anchorTo: Frame to anchor to
-- @param size: Size of the indicator
-- @return table: { bg, overlay }
function lib:CreateActiveIndicator(parent, anchorTo, size)
	local activeBg = parent:CreateTexture(nil, "ARTWORK")
	activeBg:SetSize(size, size)
	activeBg:SetPoint("LEFT", anchorTo, "RIGHT", 2, 0)
	activeBg:SetColorTexture(lib.BUFF_COLORS.active[1], lib.BUFF_COLORS.active[2], lib.BUFF_COLORS.active[3], 1)
	
	local activeOverlay = parent:CreateTexture(nil, "OVERLAY")
	activeOverlay:SetSize(size, size)
	activeOverlay:SetPoint("CENTER", activeBg, "CENTER", 0, 0)
	activeOverlay:SetColorTexture(lib.BUFF_COLORS.inactive[1], lib.BUFF_COLORS.inactive[2], lib.BUFF_COLORS.inactive[3], 1)
	
	return {
		bg = activeBg,
		overlay = activeOverlay,
	}
end

-- Create stack indicators for buffs
-- @param parent: Parent container
-- @param anchorTo: Frame to anchor to
-- @param numIndicators: Number of indicators
-- @param size: Size of each indicator
-- @return table: Array of { bg, overlay } for each stack indicator
function lib:CreateStackIndicators(parent, anchorTo, numIndicators, size)
	local indicators = {}
	local prevElement = anchorTo
	
	for i = 1, numIndicators do
		local stackBg = parent:CreateTexture(nil, "ARTWORK")
		stackBg:SetSize(size, size)
		stackBg:SetPoint("LEFT", prevElement, "RIGHT", 2, 0)
		stackBg:SetColorTexture(lib.BUFF_COLORS.stackHalf[1], lib.BUFF_COLORS.stackHalf[2], lib.BUFF_COLORS.stackHalf[3], 1)
		
		local stackOverlay = parent:CreateTexture(nil, "OVERLAY")
		stackOverlay:SetSize(size, size)
		stackOverlay:SetPoint("CENTER", stackBg, "CENTER", 0, 0)
		stackOverlay:SetColorTexture(lib.BUFF_COLORS.stackEmpty[1], lib.BUFF_COLORS.stackEmpty[2], lib.BUFF_COLORS.stackEmpty[3], 1)
		
		indicators[i] = {
			bg = stackBg,
			overlay = stackOverlay,
		}
		
		prevElement = stackBg
	end
	
	return indicators
end

-- ═══════════════════════════════════════════════════════════════════════════
-- GCD CONTAINER CREATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Create the GCD container with stance, GCD bar, combat, and aggro indicators
-- @param parent: Parent frame
-- @param configs: { size, bgPadding }
-- @return table: { container, stanceIndicator, gcdbar, combatbar, aggrobar }
function lib:CreateGCDContainer(parent, configs)
	local size = configs.size or 10
	local pad = configs.bgPadding or 2
	local sepSize = 2
	
	-- Calculate total width: [stance][sep][gcd][sep][combat][sep][aggro]
	local gcdBarWidth = size * 10
	local totalWidth = (size * 3) + gcdBarWidth + (sepSize * 3)
	
	local gcdCombatContainer = CreateFrame("Frame", nil, parent)
	gcdCombatContainer:SetSize(totalWidth + pad * 2, size + pad * 2)
	
	local gcdCombatBg = gcdCombatContainer:CreateTexture(nil, "BACKGROUND")
	gcdCombatBg:SetAllPoints()
	gcdCombatBg:SetColorTexture(0, 0, 0, 1)
	
	local stanceIndicator = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	stanceIndicator:SetSize(size, size)
	stanceIndicator:SetPoint("LEFT", pad, 0)
	stanceIndicator:SetColorTexture(0.5, 0.5, 0.5, 1)
	
	local sep1 = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	sep1:SetSize(sepSize, size)
	sep1:SetPoint("LEFT", stanceIndicator, "RIGHT", 0, 0)
	sep1:SetColorTexture(0, 0, 0, 1)
	
	-- GCD bar with clipping container
	local gcdClip = CreateFrame("Frame", nil, gcdCombatContainer)
	gcdClip:SetSize(gcdBarWidth, size)
	gcdClip:SetPoint("LEFT", sep1, "RIGHT", 0, 0)
	gcdClip:SetClipsChildren(true)
	gcdClip:SetFrameLevel(gcdCombatContainer:GetFrameLevel() + 1)
	
	local gcdbar = CreateFrame("StatusBar", nil, gcdClip)
	gcdbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	gcdbar:GetStatusBarTexture():SetHorizTile(false)
	gcdbar:SetMinMaxValues(0, 1)
	gcdbar:SetValue(0)
	gcdbar:SetSize(10000, size)
	gcdbar:SetStatusBarColor(0, 0, 0)
	gcdbar:SetPoint("LEFT")
	
	local sep2 = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	sep2:SetSize(sepSize, size)
	sep2:SetPoint("LEFT", gcdClip, "RIGHT", 0, 0)
	sep2:SetColorTexture(0, 0, 0, 1)
	
	local combatbar = CreateFrame("StatusBar", nil, gcdCombatContainer)
	combatbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	combatbar:GetStatusBarTexture():SetHorizTile(false)
	combatbar:SetMinMaxValues(0, 100)
	combatbar:SetValue(100)
	combatbar:SetSize(size, size)
	combatbar:SetStatusBarColor(0, 0, 0)
	combatbar:SetPoint("LEFT", sep2, "RIGHT", 0, 0)
	
	local sep3 = gcdCombatContainer:CreateTexture(nil, "ARTWORK")
	sep3:SetSize(sepSize, size)
	sep3:SetPoint("LEFT", combatbar, "RIGHT", 0, 0)
	sep3:SetColorTexture(0, 0, 0, 1)
	
	local aggrobar = CreateFrame("StatusBar", nil, gcdCombatContainer)
	aggrobar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	aggrobar:GetStatusBarTexture():SetHorizTile(false)
	aggrobar:SetMinMaxValues(0, 100)
	aggrobar:SetValue(100)
	aggrobar:SetSize(size, size)
	aggrobar:SetStatusBarColor(0.3, 0.3, 0.3)
	aggrobar:SetPoint("LEFT", sep3, "RIGHT", 0, 0)
	
	return {
		container = gcdCombatContainer,
		stanceIndicator = stanceIndicator,
		gcdClip = gcdClip,
		gcdbar = gcdbar,
		combatbar = combatbar,
		aggrobar = aggrobar,
	}
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Calculate container width for a spell bar
-- @param configs: { barHeight }
-- @param hasRange: Whether to include range indicator
-- @param maxCharges: Number of charges (0 for none)
-- @param hasIconChange: Whether to include icon change indicator
-- @return number: Total container width
function lib:CalculateSpellBarWidth(configs, hasRange, maxCharges, hasIconChange)
	local barSize = configs.barHeight or 8
	local pad = configs.bgPadding or 2
	
	local chargeWidth = maxCharges > 1 and (maxCharges * barSize + (maxCharges - 1) * 2) or 0
	local extraGap = maxCharges > 1 and 2 or 0
	local iconChangeWidth = hasIconChange and (barSize + 2) or 0
	local rangeWidth = hasRange and (barSize + 2) or 0
	
	return (barSize * 2 + 2) + rangeWidth + chargeWidth + extraGap + iconChangeWidth + pad * 2
end

-- Clear all bars from a tracking table
-- @param trackedTable: Table of tracked bars
-- @param barsArray: Array of bar IDs/keys
function lib:ClearBars(trackedTable, barsArray)
	for _, data in pairs(trackedTable) do
		if data.container then
			data.container:Hide()
			data.container:SetParent(nil)
		end
	end
	wipe(trackedTable)
	wipe(barsArray)
end
