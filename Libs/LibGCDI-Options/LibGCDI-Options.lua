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
local RANGE_YARDS_ORDER = GCDI.RANGE_YARDS_ORDER or { 0, 5, 8, 10, 12, 13, 15, 20, 25, 30, 35, 40 }

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
local refresh_settings_tab
local switch_tab

-- ═══════════════════════════════════════════════════════════════════════════
-- WIDGET POOL
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WoW never frees Frames, FontStrings or Textures: SetParent(nil) only orphans
-- them. Every tab refresh used to build a fresh widget tree and drop the old one,
-- so each refresh permanently leaked a tree — and refresh runs on tab switch, on
-- rescan, on profile load and after most checkbox clicks. Widgets are pooled by
-- (kind, template) and reused instead.
--
-- Pooling is by type, not by position: a call site always fully configures the
-- widget it gets (size, anchor, text, scripts), so it does not matter which
-- specific widget of that type comes back out of the bucket.

local pooledHost = CreateFrame("Frame")
pooledHost:Hide()

local widgetPool = {}

-- Scripts are cleared on release so a reused widget cannot keep behaviour from
-- whatever it was last time.
local POOL_SCRIPTS = {
	"OnClick", "OnEnter", "OnLeave", "OnUpdate", "OnMouseDown", "OnMouseUp",
	"OnTextChanged", "OnEnterPressed", "OnEscapePressed", "OnValueChanged",
	"OnShow", "OnHide", "OnDragStart", "OnDragStop", "OnEditFocusGained",
	"OnEditFocusLost", "OnChar", "OnKeyDown",
}

-- Widgets acquired while a list is active are registered to it automatically, so
-- every acquire is guaranteed to have a matching release.
local activeTrackList = nil

local function pool_take(key)
	local bucket = widgetPool[key]
	if not bucket then
		bucket = {}
		widgetPool[key] = bucket
		return nil, bucket
	end
	return table.remove(bucket), bucket
end

local function pool_register(w)
	if activeTrackList then
		activeTrackList[#activeTrackList + 1] = w
	end
	return w
end

-- A recycled widget can carry state from its previous use that the new call
-- site never touches (disabled buttons, small reorder-button fonts, cropped
-- icon texcoords, greyed-out description text...). Reset everything a call
-- site might reasonably assume is at its default.
local function acquire_frame(kind, parent, template)
	local key = "F\t" .. kind .. "\t" .. (template or "")
	local w = pool_take(key)
	if w then
		w:SetParent(parent)
	else
		w = CreateFrame(kind, nil, parent, template)
		w.__poolKey = key
		w.__poolKind = "frame"
	end
	w:ClearAllPoints()
	w:SetAlpha(1)
	if w.SetEnabled then w:SetEnabled(true) end
	if w.SetNormalFontObject and _G.GameFontNormal then w:SetNormalFontObject(_G.GameFontNormal) end
	if w.SetHighlightFontObject and _G.GameFontHighlight then w:SetHighlightFontObject(_G.GameFontHighlight) end
	if kind == "EditBox" and w.SetText then w:SetText("") end
	w:Show()
	return pool_register(w)
end

local function acquire_fontstring(parent, layer, template)
	layer = layer or "OVERLAY"
	local key = "S\t" .. layer .. "\t" .. (template or "")
	local fs = pool_take(key)
	if fs then
		fs:SetParent(parent)
		fs:SetDrawLayer(layer)
	else
		fs = parent:CreateFontString(nil, layer, template)
		fs.__poolKey = key
		fs.__poolKind = "fontstring"
	end
	fs:ClearAllPoints()
	fs:SetText("")
	fs:SetJustifyH("LEFT")
	fs:SetWidth(0)
	fs:SetAlpha(1)
	local fontObj = fs:GetFontObject()
	if fontObj then
		fs:SetTextColor(fontObj:GetTextColor())
	end
	fs:Show()
	return pool_register(fs)
end

local function acquire_texture(parent, layer)
	layer = layer or "ARTWORK"
	local key = "T\t" .. layer
	local tex = pool_take(key)
	if tex then
		tex:SetParent(parent)
		tex:SetDrawLayer(layer)
	else
		tex = parent:CreateTexture(nil, layer)
		tex.__poolKey = key
		tex.__poolKind = "texture"
	end
	tex:ClearAllPoints()
	tex:SetTexture(nil)
	tex:SetTexCoord(0, 1, 0, 1)
	tex:SetVertexColor(1, 1, 1, 1)
	tex:SetAlpha(1)
	tex:Show()
	return pool_register(tex)
end

local function release_widget(w)
	if not w then return end
	if not w.__poolKey then
		-- Created before pooling or by a path that is not pooled; orphan as before.
		if w.Hide then w:Hide() end
		if w.SetParent then w:SetParent(nil) end
		return
	end
	w:Hide()
	w:ClearAllPoints()
	if w.__poolKind == "frame" then
		for i = 1, #POOL_SCRIPTS do
			local script = POOL_SCRIPTS[i]
			if w:HasScript(script) then
				w:SetScript(script, nil)
			end
		end
	elseif w.__poolKind == "fontstring" then
		w:SetText("")
	end
	w:SetParent(pooledHost)
	local bucket = widgetPool[w.__poolKey]
	if not bucket then
		bucket = {}
		widgetPool[w.__poolKey] = bucket
	end
	bucket[#bucket + 1] = w
end

-- Release everything in a tracking list and make it the active list for the
-- rebuild that follows.
local function reset_track_list(list)
	for i = 1, #list do
		release_widget(list[i])
	end
	wipe(list)
	activeTrackList = list
	return list
end

-- ═══════════════════════════════════════════════════════════════════════════
-- REORDERABLE ROWS (shared by Spells/Items/Buffs tabs)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Replaces the old per-tab Up/Down/Bottom button triplet with one drag-handle
-- implementation shared by all three tabs. A drag never calls
-- refresh_options_frame()/reset_track_list() - it only SetPoints the row
-- frames already on screen; the catalog is written once, on drop.

-- Every row in every list tab (Resources/Spells/Items/Buffs) is anchored at
-- this same scrollChild x. Column-header FontStrings sit directly on the
-- scrollChild (no row wrapper), so a header aligning with a row control at
-- row-relative offset N must be placed at ROW_BASE_X + N, not N alone - each
-- tab's *_COLUMNS table below stores the row-relative N; header code adds
-- this. Was previously two independently hand-typed numbers per column (one
-- in the header code, one in the row code) that drifted out of sync -
-- several were off by exactly this value.
local ROW_BASE_X = 10

-- Resolves a column-header's absolute x from a *_COLUMNS entry:
--   { x = N }             -- header sits directly above the row control (ROW_BASE_X + N)
--   { x = N, headerX = M } -- header is deliberately nudged (e.g. centered over a
--                             narrow checkbox) - M is an absolute scrollChild x
local function header_x(column)
	return column.headerX or (ROW_BASE_X + column.x)
end

-- A frame created from UIDropDownMenuTemplate and resized via
-- UIDropDownMenu_SetWidth(dropdown, N) actually renders N + 50px wide, not N -
-- verified against Blizzard's own UIDropDownMenu.lua: SetWidth sets
-- `frame:SetWidth(width + UIDROPDOWNMENU_DEFAULT_WIDTH_PADDING * 2)` and that
-- constant is 25. Every dropdown column in this file must budget this true
-- width (not the SetWidth argument) for the next column's start position, or
-- it silently overlaps its neighbor - this is what caused the Charge Pips/GCD
-- and Buffs Max Stacks/Dur/Threshold overlaps.
local DROPDOWN_WIDTH_PADDING = 50

-- Centers a header FontString over a dropdown column's true rendered width
-- (column.width + DROPDOWN_WIDTH_PADDING), rather than guessing a left-nudge
-- to line up with the dropdown's internal (right-justified, variable-length)
-- selected-text label - the dropdown's actual left/right visual edges are the
-- only fixed, computable reference point.
local function center_header_over_dropdown(header, column)
	header:SetWidth(column.width + DROPDOWN_WIDTH_PADDING)
	header:SetJustifyH("CENTER")
end

-- Draws the "— Disabled X —" separator + label immediately before the first
-- disabled row in an ordered list; returns the updated yOffset. Was
-- copy-pasted identically (bar width/label aside) in all three tabs.
local function add_disabled_section_separator(scrollChild, yOffset, width, label)
	yOffset = yOffset - 10
	local sep = acquire_texture(scrollChild, "ARTWORK")
	sep:SetColorTexture(0.4, 0.4, 0.4, 1)
	sep:SetSize(width, 1)
	sep:SetPoint("TOPLEFT", 10, yOffset)
	yOffset = yOffset - 5

	local sepLabel = acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall")
	sepLabel:SetPoint("TOPLEFT", 10, yOffset)
	sepLabel:SetText("|cff888888— Disabled " .. label .. " —|r")
	yOffset = yOffset - 18
	return yOffset
end

-- Finds the fixed row slot (from `slotYs`, captured once at layout time - see
-- below) whose Y is closest to `y`. Slots aren't perfectly evenly spaced (the
-- disabled-section separator inserts an extra gap), so this is a nearest-slot
-- scan rather than arithmetic off a fixed row height - correct regardless of
-- that gap, at the cost of an O(n) scan per drag tick (tab lists are small).
local function nearest_slot_index(slotYs, y)
	local bestIndex, bestDist = 1, math.abs(slotYs[1] - y)
	for k = 2, #slotYs do
		local dist = math.abs(slotYs[k] - y)
		if dist < bestDist then
			bestIndex, bestDist = k, dist
		end
	end
	return bestIndex
end

-- Adds a drag grip to `row` and wires the reorder gesture.
--   rows, ids   - parallel arrays for every row currently in this tab's list
--                 (index i in `rows` <-> index i in `ids`), mutated in place
--                 as the dragged row passes its siblings.
--   index       - this row's starting index into rows/ids.
--   slotYs      - the fixed TOPLEFT y-offset for each visual slot 1..#rows,
--                 captured from the actual yOffset used when each row was
--                 first laid out this refresh (so it already accounts for
--                 the disabled-section gap).
--   commitFn    - GCDI.commit_spell_order/commit_item_order/commit_buff_order;
--                 called once with the final `ids` order on drop.
--   onDropRefresh - the tab's own refresh_*_tab function; called once on drop
--                 to resync everything a drag doesn't update live (disabled-
--                 section placement, row backing data, etc).
local function add_row_drag_handle(row, rows, ids, index, slotYs, commitFn, onDropRefresh)
	local grip = acquire_frame("Button", row)
	grip:SetSize(20, 18)
	grip:EnableMouse(true)
	grip:RegisterForDrag("LeftButton")

	-- Hamburger-style grip icon (3 horizontal bars) instead of a bordered
	-- button with "|||" text. Drawn manually with plain color textures
	-- (no known stable Blizzard hamburger-icon atlas to depend on) and cached
	-- on the button itself so they're created once and just repositioned on
	-- every pool reuse, rather than going through acquire_texture/the tab's
	-- track list - their content never varies row to row.
	local bars = grip.__gripBars
	if not bars then
		bars = {}
		for barIndex = 1, 3 do
			local bar = grip:CreateTexture(nil, "ARTWORK")
			bar:SetSize(12, 2)
			bars[barIndex] = bar
		end
		grip.__gripBars = bars
	end
	for barIndex, bar in ipairs(bars) do
		bar:ClearAllPoints()
		bar:SetPoint("CENTER", grip, "CENTER", 0, 6 - (barIndex - 1) * 6)
		bar:SetColorTexture(0.82, 0.82, 0.82, 1)
	end

	grip:SetScript("OnEnter", function(self)
		for _, bar in ipairs(bars) do bar:SetColorTexture(1, 1, 1, 1) end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Drag to reorder")
		GameTooltip:Show()
	end)
	grip:SetScript("OnLeave", function()
		for _, bar in ipairs(bars) do bar:SetColorTexture(0.82, 0.82, 0.82, 1) end
		GameTooltip:Hide()
	end)

	local currentIndex = index
	local dragging = false
	local liftedFromLevel = nil

	grip:SetScript("OnDragStart", function()
		if dragging then return end
		dragging = true

		local _, cursorY0 = GetCursorPosition()
		local startCursorY = cursorY0 / row:GetEffectiveScale()
		local startSlotY = slotYs[currentIndex]
		liftedFromLevel = row:GetFrameLevel()
		row:SetFrameLevel(math.min(liftedFromLevel + 50, 65535))

		row:SetScript("OnUpdate", function()
			local _, cursorY = GetCursorPosition()
			local localY = cursorY / row:GetEffectiveScale()
			local newY = startSlotY + (localY - startCursorY)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 10, newY)

			local target = nearest_slot_index(slotYs, newY)

			while currentIndex < target do
				local otherRow = rows[currentIndex + 1]
				rows[currentIndex], rows[currentIndex + 1] = rows[currentIndex + 1], rows[currentIndex]
				ids[currentIndex], ids[currentIndex + 1] = ids[currentIndex + 1], ids[currentIndex]
				currentIndex = currentIndex + 1
				otherRow:ClearAllPoints()
				otherRow:SetPoint("TOPLEFT", 10, slotYs[currentIndex - 1])
			end
			while currentIndex > target do
				local otherRow = rows[currentIndex - 1]
				rows[currentIndex], rows[currentIndex - 1] = rows[currentIndex - 1], rows[currentIndex]
				ids[currentIndex], ids[currentIndex - 1] = ids[currentIndex - 1], ids[currentIndex]
				currentIndex = currentIndex - 1
				otherRow:ClearAllPoints()
				otherRow:SetPoint("TOPLEFT", 10, slotYs[currentIndex + 1])
			end
		end)
	end)

	grip:SetScript("OnDragStop", function()
		-- WoW auto-fires OnDragStop a second time if the dragged frame gets
		-- Hidden while still mid-drag (e.g. commitFn's rebuild - via
		-- onDropRefresh below - pool-releasing this very row). Without this
		-- guard the second call re-runs the frame-level restore and
		-- underflows SetFrameLevel below 0.
		if not dragging then return end
		dragging = false

		row:SetScript("OnUpdate", nil)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 10, slotYs[currentIndex])
		if liftedFromLevel then
			row:SetFrameLevel(liftedFromLevel)
			liftedFromLevel = nil
		end
		commitFn(ids)
		if onDropRefresh then onDropRefresh() end
	end)

	return grip
end

-- ═══════════════════════════════════════════════════════════════════════════
-- UTILITY FUNCTIONS
-- ═══════════════════════════════════════════════════════════════════════════

-- Build ordered list of range options (keyed by yards, not index)
-- settings: if provided, appends " (in combat)" for ranges that have a proxy spell
local function get_range_options_list(settings)
	local list = {}
	local proxySpells = settings and settings.rangeProxySpells
	for _, yards in ipairs(RANGE_YARDS_ORDER) do
		local item = RANGE_ITEMS[yards]
		if item then
			local name = item.name
			if proxySpells and proxySpells[yards] then
				name = name .. " (in combat)"
			end
			table.insert(list, { yards = yards, name = name })
		end
	end
	return list
end

-- Only ranges that have a "Range spell (in combat)" set on GCD tab
local function get_range_options_list_proxy_only(settings)
	local list = {}
	local proxySpells = settings and settings.rangeProxySpells
	if not proxySpells then return list end
	for _, yards in ipairs(RANGE_YARDS_ORDER) do
		if yards > 0 and proxySpells[yards] and RANGE_ITEMS[yards] then
			table.insert(list, { yards = yards, name = RANGE_ITEMS[yards].name })
		end
	end
	return list
end

-- Spells tab range override: all brackets when LibRangeCheck handles yard checks; else proxy-only list
local function get_spell_range_override_options(settings)
	if settings and settings.gcdSettings and settings.gcdSettings.useLibRangeCheck then
		local list = {}
		for _, yards in ipairs(RANGE_YARDS_ORDER) do
			if yards > 0 and RANGE_ITEMS[yards] then
				table.insert(list, { yards = yards, name = RANGE_ITEMS[yards].name })
			end
		end
		return list
	end
	return get_range_options_list_proxy_only(settings)
end

local function create_range_dropdown(parent, width, selectedYards, onChange)
	local dropdown = acquire_frame("Frame", parent, "UIDropDownMenuTemplate")
	dropdown:SetPoint("LEFT")
	UIDropDownMenu_SetWidth(dropdown, width)
	
	local options = get_range_options_list(settings)
	
	local function initialize(self, level)
		for listIdx, opt in ipairs(options) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = opt.name
			info.value = opt.yards
			info.checked = (opt.yards == selectedYards)
			info.func = function()
				selectedYards = opt.yards
				UIDropDownMenu_SetSelectedID(dropdown, listIdx)
				if onChange then onChange(opt.yards) end
			end
			UIDropDownMenu_AddButton(info, level)
		end
	end
	
	UIDropDownMenu_Initialize(dropdown, initialize)
	
	for listIdx, opt in ipairs(options) do
		if opt.yards == selectedYards then
			UIDropDownMenu_SetSelectedID(dropdown, listIdx)
			break
		end
	end
	
	return dropdown
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SHARED SECTION HEADER (separator line + title + optional description)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Every tab breaks its content into labeled sections; this used to be a
-- hand-copied separator/title/desc block per section with drifting gaps
-- (25px in one tab, 20px in another). One helper, one set of gap constants.

local SECTION_GAP_SEP_TO_TITLE = 20
local SECTION_GAP_TITLE_TO_DESC = 25
local SECTION_GAP_DESC_TO_ROW = 25
local SECTION_GAP_TITLE_TO_ROW = 25  -- used when there is no description

-- Draws the header starting at yOffset and returns the yOffset for the first
-- control below it. Pass showSep = false for a tab's very first section
-- (nothing above it to separate from).
local function add_section_header(frame, yOffset, title, desc, width, showSep)
	if showSep ~= false then
		local sep = acquire_texture(frame, "ARTWORK")
		sep:SetColorTexture(0.4, 0.4, 0.4, 1)
		sep:SetSize(width or 480, 1)
		sep:SetPoint("TOPLEFT", 5, yOffset)
		yOffset = yOffset - SECTION_GAP_SEP_TO_TITLE
	end

	local titleFS = acquire_fontstring(frame, "OVERLAY", "GameFontNormalLarge")
	titleFS:SetPoint("TOPLEFT", 5, yOffset)
	titleFS:SetText(title)

	if desc then
		yOffset = yOffset - SECTION_GAP_TITLE_TO_DESC
		local descFS = acquire_fontstring(frame, "OVERLAY", "GameFontHighlight")
		descFS:SetPoint("TOPLEFT", 5, yOffset)
		descFS:SetText(desc)
		descFS:SetTextColor(0.7, 0.7, 0.7)
		yOffset = yOffset - SECTION_GAP_DESC_TO_ROW
	else
		yOffset = yOffset - SECTION_GAP_TITLE_TO_ROW
	end

	return yOffset
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TAB BAR
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Used to be 7 copy-pasted CreateFrame blocks with hand-guessed widths (45,
-- 75, 55...) and a background texture only ever touched by hover scripts —
-- switch_tab() never repainted it, so whichever tab was built with the
-- lighter initial alpha looked permanently "selected" no matter which tab
-- was actually open. One table-driven builder sizes each button from its
-- own label and exposes bg/fontstring so switch_tab can set a real active
-- state (see the `tabButtons` loop above).

local TAB_DEFS = {
	{ key = "gcd", text = "GCD" },
	{ key = "resources", text = "Resources" },
	{ key = "spells", text = "Spells" },
	{ key = "items", text = "Items" },
	{ key = "buffs", text = "Buffs" },
	{ key = "settings", text = "Settings" },
	{ key = "profiles", text = "Profiles" },
}

local TAB_HEIGHT = 24
local TAB_TEXT_PADDING = 16
local TAB_GAP = 5
local TAB_BG_INACTIVE = { 0.15, 0.15, 0.15, 0.8 }
local TAB_BG_ACTIVE = { 0.3, 0.3, 0.3, 1 }
local TAB_BG_HOVER = { 0.3, 0.3, 0.3, 0.8 }

local tabButtons = {}  -- key -> button, populated by create_options_frame

local function create_tab_button(parent, def, prevButton)
	local btn = CreateFrame("Button", nil, parent)
	btn:SetHeight(TAB_HEIGHT)
	if prevButton then
		btn:SetPoint("LEFT", prevButton, "RIGHT", TAB_GAP, 0)
	else
		btn:SetPoint("TOPLEFT", 15, -30)
	end
	btn:SetNormalFontObject("GameFontNormal")
	btn:SetHighlightFontObject("GameFontHighlight")

	local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("CENTER")
	fs:SetText(def.text)
	btn:SetFontString(fs)
	btn:SetWidth(math.max(40, fs:GetStringWidth() + TAB_TEXT_PADDING))

	local bg = btn:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(unpack(TAB_BG_INACTIVE))
	btn.bg = bg

	btn:SetScript("OnClick", function() switch_tab(def.key) end)
	btn:SetScript("OnEnter", function()
		if currentTab ~= def.key then
			bg:SetColorTexture(unpack(TAB_BG_HOVER))
		end
	end)
	btn:SetScript("OnLeave", function()
		local color = (currentTab == def.key) and TAB_BG_ACTIVE or TAB_BG_INACTIVE
		bg:SetColorTexture(unpack(color))
	end)

	tabButtons[def.key] = btn
	return btn
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
	{ key = "showDispel", name = "Show Dispel", desc = "Show purple when you have a debuff you can dispel on yourself" },
}

local function refresh_gcd_tab()
	if not optionsFrame or not optionsFrame.gcdScrollChild then return end
	
	local frame = optionsFrame.gcdScrollChild
	
	-- Release existing elements back to the pool and collect the rebuild into the
	-- same list. acquire_* registers automatically, so track() is now a no-op pass
	-- through kept for readability at the call sites.
	reset_track_list(gcdTabElements)

	local function track(element)
		return element
	end

	local yOffset = -10
	
	-- ═══════════════════════════════════════════════════════════════════════════
	-- GCD ROW OPTIONS
	-- ═══════════════════════════════════════════════════════════════════════════
	
	local title = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormalLarge"))
	title:SetPoint("TOPLEFT", 5, yOffset)
	title:SetText("GCD Row Options")
	yOffset = yOffset - 25
	
	local desc = track(acquire_fontstring(frame, "OVERLAY", "GameFontHighlight"))
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
			showMobCount = true,
			showDispel = true,
		}
	end
	
	-- Create toggle for each option
	for _, opt in ipairs(GCD_INDICATOR_OPTIONS) do
		local checkbox = track(acquire_frame("CheckButton", frame, "UICheckButtonTemplate"))
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
		
		local label = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
		label:SetPoint("LEFT", checkbox, "RIGHT", 5, 0)
		label:SetText(opt.name)
		if opt.disabled then
			label:SetTextColor(0.5, 0.5, 0.5)
		end
		
		local descText = track(acquire_fontstring(frame, "OVERLAY", "GameFontHighlightSmall"))
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
	
	yOffset = add_section_header(frame, yOffset, "Mob Count Settings",
		"Configure the nearby mob count indicator. White = at or above threshold, Black = below.")

	-- Mob Count Range dropdown
	local rangeLabel = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
	rangeLabel:SetPoint("TOPLEFT", 10, yOffset)
	rangeLabel:SetText("Detection Range:")

	local rangeDropdown = track(acquire_frame("Frame", frame, "UIDropDownMenuTemplate"))
	rangeDropdown:SetPoint("LEFT", rangeLabel, "RIGHT", -5, -2)
	UIDropDownMenu_SetWidth(rangeDropdown, 100)
	
	-- Mob count range: all brackets when LibRangeCheck is on; else only yards with a Range spell (proxy)
	local function getMobRangeOptions()
		local list = {}
		if settings and settings.gcdSettings and settings.gcdSettings.useLibRangeCheck then
			for _, yards in ipairs(RANGE_YARDS_ORDER) do
				if yards > 0 and RANGE_ITEMS[yards] then
					table.insert(list, yards)
				end
			end
			return list
		end
		local proxySpells = settings and settings.rangeProxySpells
		if proxySpells then
			for _, yards in ipairs(RANGE_YARDS_ORDER) do
				if yards > 0 and proxySpells[yards] and RANGE_ITEMS[yards] then
					table.insert(list, yards)
				end
			end
		end
		return list
	end
	local function getMobRangeLabel(yards)
		return RANGE_ITEMS[yards] and RANGE_ITEMS[yards].name or (tostring(yards) .. " yards")
	end
	local function initRangeDropdown(self, level)
		local mobRangeOptions = getMobRangeOptions()
		local currentRange = settings.gcdSettings.mobCountRange or 8
		if #mobRangeOptions == 0 then
			local info = UIDropDownMenu_CreateInfo()
			info.text = "Set range spells below"
			info.value = nil
			info.checked = true
			info.func = function() end
			UIDropDownMenu_AddButton(info, level)
		else
			for _, range in ipairs(mobRangeOptions) do
				local info = UIDropDownMenu_CreateInfo()
				info.text = getMobRangeLabel(range)
				info.value = range
				info.checked = (currentRange == range)
				info.func = function()
					settings.gcdSettings.mobCountRange = range
					UIDropDownMenu_SetText(rangeDropdown, getMobRangeLabel(range))
					GCDI.auto_save_to_profile()
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end
	end
	UIDropDownMenu_Initialize(rangeDropdown, initRangeDropdown)
	-- Set initial text
	local currentRange = settings.gcdSettings.mobCountRange or 8
	local mobRangeOptions = getMobRangeOptions()
	local inList = false
	for _, r in ipairs(mobRangeOptions) do
		if r == currentRange then inList = true break end
	end
	if inList and RANGE_ITEMS[currentRange] then
		UIDropDownMenu_SetText(rangeDropdown, getMobRangeLabel(currentRange))
	elseif #mobRangeOptions > 0 then
		UIDropDownMenu_SetText(rangeDropdown, getMobRangeLabel(mobRangeOptions[1]))
	else
		UIDropDownMenu_SetText(rangeDropdown, "Set range spells below")
	end
	yOffset = yOffset - 35
	
	-- Mob Count Threshold dropdown
	local thresholdLabel = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
	thresholdLabel:SetPoint("TOPLEFT", 10, yOffset)
	thresholdLabel:SetText("Mob Threshold:")
	
	local thresholdDropdown = track(acquire_frame("Frame", frame, "UIDropDownMenuTemplate"))
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
	local mobHelp = track(acquire_fontstring(frame, "OVERLAY", "GameFontHighlightSmall"))
	mobHelp:SetPoint("TOPLEFT", 15, yOffset)
	mobHelp:SetText("Tip: Counts hostiles on nameplates within the selected range. With LibRangeCheck (below), every bracket is available; without it, only brackets with a Range spell set on this tab. White when count >= threshold.")
	mobHelp:SetTextColor(0.5, 0.5, 0.5)
	yOffset = yOffset - 20
	
	-- ═══════════════════════════════════════════════════════════════════════════
	-- RANGE SETTINGS
	-- ═══════════════════════════════════════════════════════════════════════════
	
	yOffset = add_section_header(frame, yOffset, "Range Settings",
		"Default range for spells without built-in range. Set a spell per range for in-combat checking (assign overrides in Spells tab).")

	if settings.gcdSettings.useLibRangeCheck == nil then
		settings.gcdSettings.useLibRangeCheck = false
	end
	local lrcCheckbox = track(acquire_frame("CheckButton", frame, "UICheckButtonTemplate"))
	lrcCheckbox:SetSize(24, 24)
	lrcCheckbox:SetPoint("TOPLEFT", 10, yOffset)
	lrcCheckbox:SetChecked(settings.gcdSettings.useLibRangeCheck == true)
	lrcCheckbox:SetScript("OnClick", function(self)
		settings.gcdSettings.useLibRangeCheck = self:GetChecked()
		GCDI.UpdateRangeIndicators()
		GCDI.auto_save_to_profile()
		if GCDI.refresh_options_frame then
			GCDI.refresh_options_frame()
		end
	end)
	local lrcLabel = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
	lrcLabel:SetPoint("LEFT", lrcCheckbox, "RIGHT", 5, 0)
	lrcLabel:SetText("Use LibRangeCheck-3.0 for spell range colors")
	local lrcHelp = track(acquire_fontstring(frame, "OVERLAY", "GameFontHighlightSmall"))
	lrcHelp:SetPoint("TOPLEFT", lrcLabel, "BOTTOMLEFT", 0, -4)
	lrcHelp:SetWidth(440)
	lrcHelp:SetJustifyH("LEFT")
	lrcHelp:SetText("Uses the bundled library (WeakAuras fork) for yard-based checks when painting green/red range squares—often more reliable in combat than C_Spell alone. If LibRangeCheck cannot decide, the normal path is used.")
	lrcHelp:SetTextColor(0.55, 0.55, 0.55)
	yOffset = yOffset - 48
	
	-- Global range fallback: label column right-justified so colons align; dropdowns share one width
	local RANGE_DROPDOWN_LEFT = 150
	local RANGE_DROPDOWN_WIDTH = 165
	local RANGE_LABEL_GAP = 8
	local RANGE_LABEL_WIDTH = RANGE_DROPDOWN_LEFT - RANGE_LABEL_GAP - 10

	local globalLabel = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormalSmall"))
	globalLabel:SetWidth(RANGE_LABEL_WIDTH)
	globalLabel:SetJustifyH("RIGHT")
	globalLabel:SetText("Global Range:")

	local globalDropdown = track(create_range_dropdown(frame, RANGE_DROPDOWN_WIDTH, settings.globalRangeFallbackYards or 5, function(yards)
		settings.globalRangeFallbackYards = yards
		GCDI.UpdateRangeIndicators()
	end))
	globalDropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", RANGE_DROPDOWN_LEFT, yOffset - 2)
	globalLabel:SetPoint("RIGHT", globalDropdown, "LEFT", -RANGE_LABEL_GAP, 0)
	yOffset = yOffset - 28
	
	-- Range spells (in combat): one spell per range (keyed by yards)
	local rangeSpellsHeader = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
	rangeSpellsHeader:SetPoint("TOPLEFT", 10, yOffset)
	rangeSpellsHeader:SetText("Range spells (in combat):")
	rangeSpellsHeader:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Range spells (in combat)")
		GameTooltip:AddLine("Optional fallback when LibRangeCheck is off: one spell per range for override/mob-count checks that need C_Spell in combat.", 1, 1, 1, true)
		GameTooltip:AddLine("With LibRangeCheck enabled above, yard checks use the library first; these entries are only used if the library cannot decide.", 0.85, 0.85, 0.85, true)
		GameTooltip:Show()
	end)
	rangeSpellsHeader:SetScript("OnLeave", function() GameTooltip:Hide() end)
	yOffset = yOffset - 22
	
	-- Build spell list for proxy dropdowns (spells that have range)
	local spellOptionsForRange = { { value = nil, name = "-- None --" } }
	do
		local orderedSpells = GCDI.get_all_catalog_spells_ordered()
		for _, spellID in ipairs(orderedSpells) do
			local entry = GCDI.spellCatalog and GCDI.spellCatalog[spellID]
			if entry and C_Spell and C_Spell.SpellHasRange and C_Spell.SpellHasRange(spellID) then
				table.insert(spellOptionsForRange, { value = spellID, name = entry.name or tostring(spellID) })
			end
		end
	end
	
	settings.rangeProxySpells = settings.rangeProxySpells or {}
	local rangeRowCount = 0
	for _, yards in ipairs(RANGE_YARDS_ORDER) do
		if yards > 0 then
			rangeRowCount = rangeRowCount + 1
			local rowY = yOffset - (rangeRowCount - 1) * 20
			local item = RANGE_ITEMS[yards]
			local label = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormalSmall"))
			label:SetWidth(RANGE_LABEL_WIDTH)
			label:SetJustifyH("RIGHT")
			label:SetText((item and item.name or tostring(yards) .. " yd") .. ":")
			local dropdown = track(acquire_frame("Frame", frame, "UIDropDownMenuTemplate"))
			dropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", RANGE_DROPDOWN_LEFT, rowY - 2)
			UIDropDownMenu_SetWidth(dropdown, RANGE_DROPDOWN_WIDTH)
			label:SetPoint("RIGHT", dropdown, "LEFT", -RANGE_LABEL_GAP, 0)
			do
				local y = yards
				local currentProxy = settings.rangeProxySpells[y]
				local function init(self, level)
					for _, opt in ipairs(spellOptionsForRange) do
						local info = UIDropDownMenu_CreateInfo()
						info.text = opt.name
						info.value = opt.value
						info.checked = (opt.value == currentProxy)
						info.func = function()
							settings.rangeProxySpells[y] = opt.value
							currentProxy = opt.value
							UIDropDownMenu_SetText(dropdown, opt.name)
							GCDI.UpdateRangeIndicators()
							if GCDI.refresh_options_frame then GCDI.refresh_options_frame() end
						end
						UIDropDownMenu_AddButton(info, level)
					end
				end
				UIDropDownMenu_Initialize(dropdown, init)
				local displayName = "-- None --"
				for _, opt in ipairs(spellOptionsForRange) do
					if opt.value == currentProxy then displayName = opt.name break end
				end
				UIDropDownMenu_SetText(dropdown, displayName)
			end
		end
	end
	yOffset = yOffset - rangeRowCount * 20 - 15
	
	-- ═══════════════════════════════════════════════════════════════════════════
	-- STANCE/FORM COLORS
	-- ═══════════════════════════════════════════════════════════════════════════
	
	yOffset = add_section_header(frame, yOffset, "Stance/Form Colors",
		"The stance indicator changes color based on your current form or stance.")

	-- Get player's class
	local _, playerClass = UnitClass("player")
	local formColors = GCDI.FORM_COLORS
	
	-- Class name header
	local className = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
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
		local row = track(acquire_frame("Frame", frame))
		row:SetSize(400, 20)
		row:SetPoint("TOPLEFT", 15, yOffset)
		
		-- Color swatch
		local colorSwatch = track(acquire_texture(row, "ARTWORK"))
		colorSwatch:SetSize(16, 16)
		colorSwatch:SetPoint("LEFT", 0, 0)
		colorSwatch:SetColorTexture(formInfo.color[1], formInfo.color[2], formInfo.color[3], 1)
		
		-- Border around swatch
		local swatchBorder = track(acquire_texture(row, "OVERLAY"))
		swatchBorder:SetSize(18, 18)
		swatchBorder:SetPoint("CENTER", colorSwatch, "CENTER", 0, 0)
		swatchBorder:SetColorTexture(0.3, 0.3, 0.3, 1)
		colorSwatch:SetDrawLayer("OVERLAY", 1)
		
		-- Form name
		local formLabel = track(acquire_fontstring(row, "OVERLAY", "GameFontNormal"))
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
	
	yOffset = add_section_header(frame, yOffset, "Indicator Legend")
	
	-- GCD Bar legend
	local gcdLegend = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
	gcdLegend:SetPoint("TOPLEFT", 10, yOffset)
	gcdLegend:SetText("|cffffffffGCD Bar:|r Shows global cooldown progress (white bar)")
	yOffset = yOffset - 20
	
	-- Combat indicator legend
	local combatLegend = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
	combatLegend:SetPoint("TOPLEFT", 10, yOffset)
	combatLegend:SetText("|cffff0000Combat:|r Red = In Combat, |cff333333Black = Out of Combat|r")
	yOffset = yOffset - 20
	
	-- Aggro indicator legend
	local aggroLegend = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
	aggroLegend:SetPoint("TOPLEFT", 10, yOffset)
	aggroLegend:SetText("|cffff8000Aggro:|r Orange = Has Threat, |cff666666Grey = No Threat|r, |cffffffffWhite = No Target|r")
	yOffset = yOffset - 20
	
	-- Update scroll child height
	frame:SetHeight(math.abs(yOffset) + 20)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- RESOURCES TAB
-- ═══════════════════════════════════════════════════════════════════════════

-- classTokens: classFileName values (UnitClass("player")'s 2nd return, e.g.
-- "MAGE"/"DEATHKNIGHT"/"DEMONHUNTER" - verified token spelling, no separators)
-- that can ever use this resource, across all of that class's specs/forms.
-- nil means every class (health only). Used to hide options-UI rows the
-- current character's class can never see, not to gate the HUD display
-- itself - a Druid still gets every listed resource since forms can't be
-- known statically the way class can.
local RESOURCE_NAMES = {
	{ key = "health", name = "Health", color = {0, 0.8, 0}, barType = "continuous", powerType = nil, classes = "All", classTokens = nil },
	{ key = "mana", name = "Mana", color = {0, 0.5, 1}, barType = "continuous", powerType = Enum.PowerType.Mana, classes = "Mage, Priest, Warlock, Paladin, Druid, Shaman, Monk, Evoker", classTokens = { "MAGE", "PRIEST", "WARLOCK", "PALADIN", "DRUID", "SHAMAN", "MONK", "EVOKER" } },
	{ key = "rage", name = "Rage", color = {0.8, 0, 0}, barType = "continuous", powerType = Enum.PowerType.Rage, classes = "Warrior, Druid (Bear)", classTokens = { "WARRIOR", "DRUID" } },
	{ key = "energy", name = "Energy", color = {1, 0.85, 0}, barType = "continuous", powerType = Enum.PowerType.Energy, classes = "Rogue, Druid (Cat), Monk", classTokens = { "ROGUE", "DRUID", "MONK" } },
	{ key = "focus", name = "Focus", color = {1, 0.5, 0.2}, barType = "continuous", powerType = Enum.PowerType.Focus, classes = "Hunter", classTokens = { "HUNTER" } },
	{ key = "runicPower", name = "Runic Power", color = {0, 0.82, 1}, barType = "continuous", powerType = Enum.PowerType.RunicPower, classes = "Death Knight", classTokens = { "DEATHKNIGHT" } },
	{ key = "runes", name = "Runes", color = {0.8, 0.2, 0.2}, barType = "charges", powerType = Enum.PowerType.Runes, classes = "Death Knight", classTokens = { "DEATHKNIGHT" } },
	{ key = "comboPoints", name = "Combo Points", color = {1, 0.5, 0}, barType = "charges", powerType = Enum.PowerType.ComboPoints, classes = "Rogue, Druid (Cat)", classTokens = { "ROGUE", "DRUID" } },
	{ key = "soulShards", name = "Soul Shards", color = {0.58, 0.51, 0.79}, barType = "charges", powerType = Enum.PowerType.SoulShards, classes = "Warlock", classTokens = { "WARLOCK" } },
	{ key = "holyPower", name = "Holy Power", color = {0.95, 0.9, 0.6}, barType = "charges", powerType = Enum.PowerType.HolyPower, classes = "Paladin", classTokens = { "PALADIN" } },
	{ key = "chi", name = "Chi", color = {0.71, 1, 0.92}, barType = "charges", powerType = Enum.PowerType.Chi, classes = "Monk (Windwalker)", classTokens = { "MONK" } },
	{ key = "arcaneCharges", name = "Arcane Charges", color = {0.1, 0.1, 0.98}, barType = "charges", powerType = Enum.PowerType.ArcaneCharges, classes = "Mage (Arcane)", classTokens = { "MAGE" } },
	{ key = "insanity", name = "Insanity", color = {0.4, 0, 0.8}, barType = "continuous", powerType = Enum.PowerType.Insanity, classes = "Priest (Shadow)", classTokens = { "PRIEST" } },
	{ key = "maelstrom", name = "Maelstrom", color = {0, 0.5, 1}, barType = "continuous", powerType = Enum.PowerType.Maelstrom, classes = "Shaman (Elemental)", classTokens = { "SHAMAN" } },
	{ key = "fury", name = "Fury", color = {0.79, 0.26, 0.99}, barType = "continuous", powerType = Enum.PowerType.Fury, classes = "Demon Hunter (Havoc)", classTokens = { "DEMONHUNTER" } },
	{ key = "pain", name = "Pain", color = {1, 0.61, 0}, barType = "continuous", powerType = Enum.PowerType.Pain, classes = "Demon Hunter (Vengeance)", classTokens = { "DEMONHUNTER" } },
	{ key = "astralPower", name = "Astral Power", color = {0.3, 0.52, 0.9}, barType = "continuous", powerType = Enum.PowerType.LunarPower, classes = "Druid (Balance)", classTokens = { "DRUID" } },
	{ key = "essence", name = "Essence", color = {0.27, 0.84, 0.76}, barType = "charges", powerType = Enum.PowerType.Essence, classes = "Evoker", classTokens = { "EVOKER" } },
	{ key = "stagger", name = "Stagger", color = {0.35, 0.90, 0.55}, barType = "continuous", powerType = nil, classes = "Monk (Brewmaster)", classTokens = { "MONK" } },
}

-- true if `resource` applies to `classToken` (UnitClass("player")'s 2nd
-- return value); nil classTokens (health) always applies.
local function resource_applies_to_class(resource, classToken)
	if not resource.classTokens then return true end
	for _, token in ipairs(resource.classTokens) do
		if token == classToken then return true end
	end
	return false
end

local function refresh_resources_tab()
	if not optionsFrame or not optionsFrame.resourcesScrollChild then return end
	
	-- Always sync settings reference
	settings = GCDI.settings
	
	-- Ensure resourceSettings exists
	if not settings.resourceSettings then
		settings.resourceSettings = {}
	end
	
	reset_track_list(resourcesTabElements)

	local scrollChild = optionsFrame.resourcesScrollChild
	local yOffset = -10

	local function track(element)
		return element
	end

	-- Section title
	local sectionTitle = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalLarge"))
	sectionTitle:SetPoint("TOPLEFT", 10, yOffset)
	sectionTitle:SetText("Resource Bars")
	yOffset = yOffset - 25
	
	local sectionDesc = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontHighlight"))
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
	
	-- Single source of truth for this tab's column x-offsets (row-relative -
	-- rows themselves sit at ROW_BASE_X). Both the headers below and the
	-- per-row controls in the loop read from this table, so they cannot
	-- drift out of sync the way independently hand-typed numbers did before.
	local RESOURCES_COLUMNS = {
		checkbox = 0,
		swatch = 29,  -- checkbox (0-24) + 5 gap
		name = 55,    -- swatch (29-45) + 10 gap
		max = 150,
		type = 195,
		class = 255,
	}

	-- Column headers
	local nameHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	nameHeader:SetPoint("TOPLEFT", ROW_BASE_X + RESOURCES_COLUMNS.name, yOffset)
	nameHeader:SetText("Resource")

	local maxHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	maxHeader:SetPoint("TOPLEFT", ROW_BASE_X + RESOURCES_COLUMNS.max, yOffset)
	maxHeader:SetWidth(40)
	maxHeader:SetJustifyH("CENTER")
	maxHeader:SetText("Max")

	local typeHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	typeHeader:SetPoint("TOPLEFT", ROW_BASE_X + RESOURCES_COLUMNS.type, yOffset)
	typeHeader:SetWidth(55)
	typeHeader:SetJustifyH("CENTER")
	typeHeader:SetText("Type")

	local classHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	classHeader:SetPoint("TOPLEFT", ROW_BASE_X + RESOURCES_COLUMNS.class, yOffset)
	classHeader:SetText("Class")
	yOffset = yOffset - 20

	-- Only list resources the current character's class can ever use (across
	-- specs/forms - see resource_applies_to_class); classID is unused here,
	-- only the classFileName token.
	local _, playerClassToken = UnitClass("player")

	-- Create checkbox for each resource this class can use
	for _, resource in ipairs(RESOURCE_NAMES) do
		if resource_applies_to_class(resource, playerClassToken) then
			local row = track(acquire_frame("Frame", scrollChild))
			row:SetSize(520, 30)
			row:SetPoint("TOPLEFT", 10, yOffset)

			-- Enabled checkbox
			local checkbox = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
			checkbox:SetSize(24, 24)
			checkbox:SetPoint("LEFT", RESOURCES_COLUMNS.checkbox, 0)

			-- Default to enabled if not set (stagger defaults off — Brewmaster-only bar)
			local isEnabled = settings.resourceSettings[resource.key]
			if isEnabled == nil then
				isEnabled = (resource.key ~= "stagger")
				settings.resourceSettings[resource.key] = isEnabled
			end
			checkbox:SetChecked(isEnabled)

			checkbox:SetScript("OnClick", function(self)
				settings.resourceSettings[resource.key] = self:GetChecked()
				GCDI.auto_save_to_profile()
				GCDI.reposition_all()
			end)

			-- Color swatch
			local colorSwatch = acquire_texture(row, "ARTWORK")
			colorSwatch:SetSize(16, 16)
			colorSwatch:SetPoint("LEFT", RESOURCES_COLUMNS.swatch, 0)
			colorSwatch:SetColorTexture(resource.color[1], resource.color[2], resource.color[3], 1)

			-- Resource name (width capped so long names can't run into the Max column)
			local nameText = acquire_fontstring(row, "OVERLAY", "GameFontNormal")
			nameText:SetPoint("LEFT", RESOURCES_COLUMNS.name, 0)
			nameText:SetWidth(RESOURCES_COLUMNS.max - RESOURCES_COLUMNS.name - 8)
			nameText:SetJustifyH("LEFT")
			nameText:SetText(resource.name)

			-- Get max value
			local maxValue = 0
			if resource.key == "health" or resource.key == "stagger" then
				local rawMax = UnitHealthMax("player")
				maxValue = tonumber(rawMax) or 0
			elseif resource.powerType then
				local rawMax = UnitPowerMax("player", resource.powerType)
				maxValue = tonumber(rawMax) or 0
			end

			-- Max value display (centered)
			local maxText = acquire_fontstring(row, "OVERLAY", "GameFontNormalSmall")
			maxText:SetPoint("LEFT", RESOURCES_COLUMNS.max, 0)
			maxText:SetWidth(40)
			maxText:SetJustifyH("CENTER")
			if maxValue > 0 then
				maxText:SetText("|cffffffff" .. formatNumber(maxValue) .. "|r")
			else
				maxText:SetText("|cff666666-|r")
			end

			-- Bar type display (centered)
			local typeText = acquire_fontstring(row, "OVERLAY", "GameFontNormalSmall")
			typeText:SetPoint("LEFT", RESOURCES_COLUMNS.type, 0)
			typeText:SetWidth(55)
			typeText:SetJustifyH("CENTER")
			if resource.barType == "charges" then
				typeText:SetText("|cff00ccffCharges|r")
			else
				typeText:SetText("|cff88ff88Bar|r")
			end

			-- Class display
			local classText = acquire_fontstring(row, "OVERLAY", "GameFontNormalSmall")
			classText:SetPoint("LEFT", RESOURCES_COLUMNS.class, 0)
			classText:SetWidth(200)
			classText:SetJustifyH("LEFT")
			classText:SetText("|cff888888" .. (resource.classes or "") .. "|r")

			yOffset = yOffset - 35
		end
	end

	scrollChild:SetHeight(math.abs(yOffset) + 20)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELLS TAB
-- ═══════════════════════════════════════════════════════════════════════════

local spellsTabElements = {}  -- Track all UI elements created in spells tab

local function clear_spells_tab_elements()
	-- Rows and their children are registered by acquire_*, so releasing the tracking
	-- list reclaims the whole tree. spellRows must NOT be released separately or the
	-- same row would be returned to the pool twice.
	reset_track_list(spellsTabElements)
	wipe(spellRows)
end

-- Helper to track created elements (acquire_* registers automatically)
local function track(element)
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
	
	-- Rescan Spells button
	local rescanSpellsBtn = track(acquire_frame("Button", scrollChild, "UIPanelButtonTemplate"))
	rescanSpellsBtn:SetSize(100, 22)
	rescanSpellsBtn:SetPoint("TOPLEFT", 10, yOffset)
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

	-- Single source of truth for this tab's column x-offsets (row-relative -
	-- rows themselves sit at ROW_BASE_X). Both the headers below and the
	-- per-row controls further down read from this table, so they cannot
	-- drift out of sync the way independently hand-typed numbers did before.
	-- headerX overrides are deliberate visual nudges (centering a short label
	-- over a narrow checkbox, or clearing a dropdown's arrow/padding before
	-- its text) - see header_x().
	-- Dropdown columns (range, chargePips) store `width` = the value passed to
	-- UIDropDownMenu_SetWidth, not the dropdown's true rendered width (that's
	-- width + DROPDOWN_WIDTH_PADDING) - see center_header_over_dropdown. Every
	-- column after a dropdown starts DROPDOWN_WIDTH_PADDING further right than
	-- the SetWidth argument alone would suggest, plus an 8px gap.
	local SPELLS_COLUMNS = {
		enabled    = { x = 0,   headerX = 14 },  -- centers "On" over the checkbox
		selfCast   = { x = 28,  headerX = 40 },  -- centers "Self" over the checkbox
		trackIcon  = { x = 56,  headerX = 70 },  -- centers "Ico" over the checkbox
		icon       = { x = 84 },
		name       = { x = 108 },
		native     = { x = 200 },
		range      = { x = 213, width = 110 },   -- true rendered width 160 (213-373)
		chargePips = { x = 381, width = 68 },     -- 373 + 8px gap; true rendered width 118 (381-499)
		gcd        = { x = 507 },                 -- 499 + 8px gap
		drag       = { x = 539 },                 -- 507+24 (checkbox) + 8px gap
	}

	-- Column headers
	local enabledHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	enabledHeader:SetPoint("TOPLEFT", header_x(SPELLS_COLUMNS.enabled), yOffset)
	enabledHeader:SetText("On")

	local selfCastHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	selfCastHeader:SetPoint("TOPLEFT", header_x(SPELLS_COLUMNS.selfCast), yOffset)
	selfCastHeader:SetText("Self")

	local iconTrackHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	iconTrackHeader:SetPoint("TOPLEFT", header_x(SPELLS_COLUMNS.trackIcon), yOffset)
	iconTrackHeader:SetText("Ico")

	local spellNameHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	spellNameHeader:SetPoint("TOPLEFT", header_x(SPELLS_COLUMNS.icon), yOffset)
	spellNameHeader:SetText("Spell")

	local nativeHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	nativeHeader:SetPoint("TOPLEFT", header_x(SPELLS_COLUMNS.native), yOffset)
	nativeHeader:SetText("|cff00ff00N|r")

	local rangeHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	rangeHeader:SetPoint("TOPLEFT", header_x(SPELLS_COLUMNS.range), yOffset)
	center_header_over_dropdown(rangeHeader, SPELLS_COLUMNS.range)
	rangeHeader:SetText("Range Override")

	local chargePipsHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	chargePipsHeader:SetPoint("TOPLEFT", header_x(SPELLS_COLUMNS.chargePips), yOffset)
	center_header_over_dropdown(chargePipsHeader, SPELLS_COLUMNS.chargePips)
	chargePipsHeader:SetText("Charge pips")

	local gcdHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	gcdHeader:SetPoint("TOPLEFT", header_x(SPELLS_COLUMNS.gcd), yOffset)
	gcdHeader:SetText("GCD")

	local orderHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	orderHeader:SetPoint("TOPLEFT", header_x(SPELLS_COLUMNS.drag), yOffset)
	orderHeader:SetText("Order")
	yOffset = yOffset - 20
	
	-- Create rows for each spell
	local orderedSpells = GCDI.get_all_catalog_spells_ordered()
	local disabledSectionStarted = false
	local slotYs = {}

	for i, spellID in ipairs(orderedSpells) do
		local catalogEntry = GCDI.spellCatalog[spellID]
		if not catalogEntry then
			break
		end

		local spellName = catalogEntry.name
		local texture = catalogEntry.texture

		-- Ensure spell has settings entry
		if not settings.spellSettings[spellID] then
			settings.spellSettings[spellID] = { enabled = true, rangeFallbackYards = nil, selfCast = false, hasNativeRange = nil, trackIcon = false, chargePipOverride = nil, offGCD = false }
		end
		local spellSettings = settings.spellSettings[spellID]

		-- Add separator before first disabled spell
		if not GCDI.is_spell_enabled(spellID) and not disabledSectionStarted then
			disabledSectionStarted = true
			yOffset = add_disabled_section_separator(scrollChild, yOffset, 590, "Spells")
		end
		slotYs[i] = yOffset
		
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

		local row = acquire_frame("Frame", scrollChild)
		row:SetSize(600, 30)
		row:SetPoint("TOPLEFT", 10, yOffset)

		-- Enabled checkbox
		local checkbox = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
		checkbox:SetSize(24, 24)
		checkbox:SetPoint("LEFT", SPELLS_COLUMNS.enabled.x, 0)
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
		local selfCastCheckbox = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
		selfCastCheckbox:SetSize(24, 24)
		selfCastCheckbox:SetPoint("LEFT", SPELLS_COLUMNS.selfCast.x, 0)
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
		local trackIconCheckbox = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
		trackIconCheckbox:SetSize(24, 24)
		trackIconCheckbox:SetPoint("LEFT", SPELLS_COLUMNS.trackIcon.x, 0)
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

		-- Off GCD checkbox. Metadata only: doesn't affect the addon's own
		-- display, only feeds the companion-script config export's hasGCD
		-- field (see is_spell_off_gcd in GCDIndicator.lua).
		local offGcdCheckbox = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
		offGcdCheckbox:SetSize(24, 24)
		offGcdCheckbox:SetPoint("LEFT", SPELLS_COLUMNS.gcd.x, 0)
		offGcdCheckbox:SetChecked(spellSettings.offGCD == true)
		offGcdCheckbox:SetScript("OnClick", function(self)
			if not GCDI.settings.spellSettings[spellID] then
				GCDI.settings.spellSettings[spellID] = {}
			end
			GCDI.settings.spellSettings[spellID].offGCD = self:GetChecked()
			GCDI.auto_save_to_profile()
		end)
		offGcdCheckbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Off GCD")
			GameTooltip:AddLine("Check if this spell does NOT trigger the global cooldown.", 1, 1, 1, true)
			GameTooltip:AddLine("Rare - most spells are on GCD. Used only by the companion-script config export (hasGCD field).", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		offGcdCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

		-- Spell icon
		local icon = acquire_texture(row, "ARTWORK")
		icon:SetSize(20, 20)
		icon:SetPoint("LEFT", SPELLS_COLUMNS.icon.x, 0)
		icon:SetTexture(texture)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		local iconTip = acquire_frame("Frame", row)
		iconTip:SetSize(20, 20)
		iconTip:SetPoint("LEFT", SPELLS_COLUMNS.icon.x, 0)
		iconTip:EnableMouse(true)
		iconTip:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetSpellByID(spellID)
			GameTooltip:Show()
		end)
		iconTip:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		-- Spell name
		local nameText = acquire_fontstring(row, "OVERLAY", "GameFontNormal")
		nameText:SetPoint("LEFT", SPELLS_COLUMNS.name.x, 0)
		nameText:SetWidth(90)
		nameText:SetJustifyH("LEFT")
		nameText:SetText(spellName)

		-- Native range indicator
		local rangeIndicatorText = acquire_fontstring(row, "OVERLAY", "GameFontNormalSmall")
		rangeIndicatorText:SetPoint("LEFT", SPELLS_COLUMNS.native.x, 0)
		if spellSettings.hasNativeRange then
			rangeIndicatorText:SetText("|cff00ff00N|r")
		else
			rangeIndicatorText:SetText("|cff888888-|r")
		end

		-- Tooltip for indicator (2px left of the indicator text, to widen the hit area)
		local indicatorTooltip = acquire_frame("Frame", row)
		indicatorTooltip:SetPoint("LEFT", SPELLS_COLUMNS.native.x - 2, 0)
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
		local rangeDropdown = acquire_frame("Frame", row, "UIDropDownMenuTemplate")
		rangeDropdown:SetPoint("LEFT", SPELLS_COLUMNS.range.x, 0)
		UIDropDownMenu_SetWidth(rangeDropdown, SPELLS_COLUMNS.range.width)
		rangeDropdown:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Range override")
			GameTooltip:AddLine("Force this spell to use a specific range bracket for the green/red range square, instead of native or global fallback range checking.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		rangeDropdown:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		local function initSpellRangeDropdown(self, level)
			local info = UIDropDownMenu_CreateInfo()
			local currentSpellSettings = GCDI.settings.spellSettings and GCDI.settings.spellSettings[spellID] or {}
			local rangeOptions = get_spell_range_override_options(GCDI.settings)
			
			if currentSpellSettings.hasNativeRange then
				info.text = "|cff00ff00Native|r"
				info.value = -1
				info.checked = (currentSpellSettings.rangeFallbackYards == nil and currentSpellSettings.rangeFallback == nil)
				info.func = function()
					if not GCDI.settings.spellSettings[spellID] then
						GCDI.settings.spellSettings[spellID] = {}
					end
					GCDI.settings.spellSettings[spellID].rangeFallbackYards = nil
					GCDI.settings.spellSettings[spellID].rangeFallback = nil
					UIDropDownMenu_SetSelectedID(rangeDropdown, 1)
					GCDI.auto_save_to_profile()
					GCDI.UpdateRangeIndicators()
				end
				UIDropDownMenu_AddButton(info, level)
			else
				info.text = "Use Global"
				info.value = -1
				info.checked = (currentSpellSettings.rangeFallbackYards == nil and currentSpellSettings.rangeFallback == nil)
				info.func = function()
					if not GCDI.settings.spellSettings[spellID] then
						GCDI.settings.spellSettings[spellID] = {}
					end
					GCDI.settings.spellSettings[spellID].rangeFallbackYards = nil
					GCDI.settings.spellSettings[spellID].rangeFallback = nil
					UIDropDownMenu_SetSelectedID(rangeDropdown, 1)
					GCDI.auto_save_to_profile()
					GCDI.UpdateRangeIndicators()
				end
				UIDropDownMenu_AddButton(info, level)
			end
			
			for listIdx, opt in ipairs(rangeOptions) do
				info = UIDropDownMenu_CreateInfo()
				info.text = opt.name
				info.value = opt.yards
				local currentYards = currentSpellSettings.rangeFallbackYards
				if currentYards == nil and currentSpellSettings.rangeFallback ~= nil and GCDI.LEGACY_INDEX_TO_YARDS then
					currentYards = GCDI.LEGACY_INDEX_TO_YARDS[currentSpellSettings.rangeFallback]
				end
				info.checked = (currentYards == opt.yards)
				info.func = function()
					if not GCDI.settings.spellSettings[spellID] then
						GCDI.settings.spellSettings[spellID] = {}
					end
					GCDI.settings.spellSettings[spellID].rangeFallbackYards = opt.yards
					UIDropDownMenu_SetSelectedID(rangeDropdown, listIdx + 1)
					GCDI.auto_save_to_profile()
					GCDI.UpdateRangeIndicators()
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end
		
		UIDropDownMenu_Initialize(rangeDropdown, initSpellRangeDropdown)
		
		-- Set selected: 1 = Use Global/Native; 2+ = range option by yards (proxy-only)
		local currentYards = spellSettings.rangeFallbackYards
		if currentYards == nil and spellSettings.rangeFallback ~= nil and GCDI.LEGACY_INDEX_TO_YARDS then
			currentYards = GCDI.LEGACY_INDEX_TO_YARDS[spellSettings.rangeFallback]
		end
		local rangeOptions = get_spell_range_override_options(GCDI.settings)
		if currentYards == nil then
			UIDropDownMenu_SetSelectedID(rangeDropdown, 1)
		else
			local found = false
			for listIdx, opt in ipairs(rangeOptions) do
				if opt.yards == currentYards then
					UIDropDownMenu_SetSelectedID(rangeDropdown, listIdx + 1)
					found = true
					break
				end
			end
			if not found then
				UIDropDownMenu_SetSelectedID(rangeDropdown, 1)
			end
		end
		
		-- Charge pip count override (when max charges are secret or missing; e.g. Keg Smash = 2 pips)
		local chgDropdown = track(acquire_frame("Frame", row, "UIDropDownMenuTemplate"))
		chgDropdown:SetPoint("LEFT", SPELLS_COLUMNS.chargePips.x, 0)
		UIDropDownMenu_SetWidth(chgDropdown, SPELLS_COLUMNS.chargePips.width)
		
		local function initChargePipDropdown(self, level)
			local info = UIDropDownMenu_CreateInfo()
			local cur = GCDI.settings.spellSettings and GCDI.settings.spellSettings[spellID] or {}
			local ov = cur.chargePipOverride
			
			info.text = "Auto"
			info.checked = (ov == nil)
			info.func = function()
				if not GCDI.settings.spellSettings[spellID] then
					GCDI.settings.spellSettings[spellID] = {}
				end
				GCDI.settings.spellSettings[spellID].chargePipOverride = nil
				UIDropDownMenu_SetText(chgDropdown, "Auto")
				GCDI.auto_save_to_profile()
				GCDI.rebuild_spell_bars()
				GCDI.refresh_options_frame()
			end
			UIDropDownMenu_AddButton(info, level)
			
			for n = 2, 6 do
				info = UIDropDownMenu_CreateInfo()
				info.text = tostring(n) .. " pips"
				info.checked = (ov == n)
				info.func = function()
					if not GCDI.settings.spellSettings[spellID] then
						GCDI.settings.spellSettings[spellID] = {}
					end
					GCDI.settings.spellSettings[spellID].chargePipOverride = n
					UIDropDownMenu_SetText(chgDropdown, tostring(n) .. " pips")
					GCDI.auto_save_to_profile()
					GCDI.rebuild_spell_bars()
					GCDI.refresh_options_frame()
				end
				UIDropDownMenu_AddButton(info, level)
			end
		end
		
		UIDropDownMenu_Initialize(chgDropdown, initChargePipDropdown)
		do
			local ov = spellSettings.chargePipOverride
			if ov == nil then
				UIDropDownMenu_SetText(chgDropdown, "Auto")
			else
				UIDropDownMenu_SetText(chgDropdown, tostring(ov) .. " pips")
			end
		end
		chgDropdown:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Charge pip count")
			GameTooltip:AddLine("If the charge stack bar shows the wrong number of segments vs. your action bar, pick the count here.", 1, 1, 1, true)
			GameTooltip:AddLine("Leave Auto when the game reports max charges correctly (often after leaving combat).", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		chgDropdown:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		spellRows[i] = row

		-- Drag handle (replaces the old Up/Down buttons) + Top/Bottom
		-- quick-action arrows for jumping straight to either end of a long list.
		local gripBtn = add_row_drag_handle(row, spellRows, orderedSpells, i, slotYs, GCDI.commit_spell_order, refresh_spells_tab)
		gripBtn:SetPoint("LEFT", SPELLS_COLUMNS.drag.x, 0)

		local topBtn = acquire_frame("Button", row, "UIPanelScrollUpButtonTemplate")
		topBtn:SetSize(18, 16)
		topBtn:SetPoint("LEFT", gripBtn, "RIGHT", 2, 0)
		topBtn:SetEnabled(i > 1)
		topBtn:SetScript("OnClick", function()
			GCDI.move_spell_to_top(spellID)
			GCDI.refresh_options_frame()
		end)
		topBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Move to top")
			GameTooltip:AddLine("Jumps this spell to the start of the list - faster than dragging across a long, scrolled list.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		topBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

		local bottomBtn = acquire_frame("Button", row, "UIPanelScrollDownButtonTemplate")
		bottomBtn:SetSize(18, 16)
		bottomBtn:SetPoint("LEFT", topBtn, "RIGHT", 2, 0)
		bottomBtn:SetEnabled(i < #orderedSpells)
		bottomBtn:SetScript("OnClick", function()
			GCDI.move_spell_to_bottom(spellID)
			GCDI.refresh_options_frame()
		end)
		bottomBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Move to bottom")
			GameTooltip:AddLine("Jumps this spell to the end of the list - faster than dragging across a long, scrolled list.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		bottomBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
	
	-- Rows and their children are registered by acquire_*, so the tracking list owns
	-- the whole tree; itemRows must not be released separately (double free).
	reset_track_list(itemsTabElements)
	wipe(itemRows)

	local scrollChild = optionsFrame.itemsScrollChild
	local yOffset = -10

	local function track(element)
		return element
	end

	-- Rescan Items button
	local rescanItemsBtn = track(acquire_frame("Button", scrollChild, "UIPanelButtonTemplate"))
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
	
	-- Single source of truth for this tab's column x-offsets (row-relative -
	-- rows themselves sit at ROW_BASE_X). See SPELLS_COLUMNS above / header_x()
	-- for how headerX overrides work.
	local ITEMS_COLUMNS = {
		enabled = { x = 0 },
		charges = { x = 28 },
		icon    = { x = 56, headerX = 70 },  -- header nudged toward the name column
		name    = { x = 80, width = 160 },   -- capped so a long item name can't run into the Type column
		type    = { x = 248, width = 90 },   -- name's end (240) + 8px gap
		drag    = { x = 346 },               -- type's end (338) + 8px gap
		gcd     = { x = 420 },
	}

	-- Column headers
	local enabledHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	enabledHeader:SetPoint("TOPLEFT", header_x(ITEMS_COLUMNS.enabled), yOffset)
	enabledHeader:SetText("On")

	local chargesHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	chargesHeader:SetPoint("TOPLEFT", header_x(ITEMS_COLUMNS.charges), yOffset)
	chargesHeader:SetText("Chg")

	local itemNameHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	itemNameHeader:SetPoint("TOPLEFT", header_x(ITEMS_COLUMNS.icon), yOffset)
	itemNameHeader:SetText("Item")

	local itemTypeHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	itemTypeHeader:SetPoint("TOPLEFT", header_x(ITEMS_COLUMNS.type), yOffset)
	itemTypeHeader:SetWidth(ITEMS_COLUMNS.type.width)
	itemTypeHeader:SetJustifyH("CENTER")
	itemTypeHeader:SetText("Type")

	local orderHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	orderHeader:SetPoint("TOPLEFT", header_x(ITEMS_COLUMNS.drag), yOffset)
	orderHeader:SetText("Order")

	local gcdHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	gcdHeader:SetPoint("TOPLEFT", header_x(ITEMS_COLUMNS.gcd), yOffset)  -- clear of the drag handle/Bot button
	gcdHeader:SetText("GCD")
	yOffset = yOffset - 20
	
	-- Create rows
	local orderedItems = GCDI.get_all_catalog_items_ordered()
	local disabledSectionStarted = false
	local slotYs = {}

	if #orderedItems == 0 then
		local noItemsText = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormal"))
		noItemsText:SetPoint("TOPLEFT", 10, yOffset)
		noItemsText:SetText("|cff888888No trinkets equipped or consumables in bags.|r")
		yOffset = yOffset - 30
		
		local tipText = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
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
			settings.itemSettings[itemKey] = { enabled = true, offGCD = false }
			itemSettings = settings.itemSettings[itemKey]
		end
		
		-- Separator before disabled items
		if not GCDI.is_item_enabled(itemKey) and not disabledSectionStarted then
			disabledSectionStarted = true
			yOffset = add_disabled_section_separator(scrollChild, yOffset, 450, "Items")
		end
		slotYs[i] = yOffset

		local row = acquire_frame("Frame", scrollChild)
		row:SetSize(480, 30)
		row:SetPoint("TOPLEFT", 10, yOffset)

		-- Enabled checkbox
		local checkbox = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
		checkbox:SetSize(24, 24)
		checkbox:SetPoint("LEFT", ITEMS_COLUMNS.enabled.x, 0)
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
		local chargesCheckbox = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
		chargesCheckbox:SetSize(24, 24)
		chargesCheckbox:SetPoint("LEFT", ITEMS_COLUMNS.charges.x, 0)
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
		local icon = acquire_texture(row, "ARTWORK")
		icon:SetSize(20, 20)
		icon:SetPoint("LEFT", ITEMS_COLUMNS.icon.x, 0)
		icon:SetTexture(texture)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		local iconTip = acquire_frame("Frame", row)
		iconTip:SetSize(20, 20)
		iconTip:SetPoint("LEFT", ITEMS_COLUMNS.icon.x, 0)
		iconTip:EnableMouse(true)
		iconTip:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if catalogEntry.slot then
				GameTooltip:SetInventoryItem("player", catalogEntry.slot)
			elseif catalogEntry.itemID then
				GameTooltip:SetItemByID(catalogEntry.itemID)
			end
			GameTooltip:Show()
		end)
		iconTip:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		-- Item name (was going right up to the Type column's start - capped so
		-- a long name can't run under it or the drag handle)
		local nameText = acquire_fontstring(row, "OVERLAY", "GameFontNormal")
		nameText:SetPoint("LEFT", ITEMS_COLUMNS.name.x, 0)
		nameText:SetWidth(ITEMS_COLUMNS.name.width)
		nameText:SetJustifyH("LEFT")
		nameText:SetText(itemName)

		-- Type indicator (centered in its own column, was unpositioned/overlapping)
		local typeText = acquire_fontstring(row, "OVERLAY", "GameFontNormalSmall")
		typeText:SetPoint("LEFT", ITEMS_COLUMNS.type.x, 0)
		typeText:SetWidth(ITEMS_COLUMNS.type.width)
		typeText:SetJustifyH("CENTER")
		if catalogEntry.slot then
			typeText:SetText("|cff00ff00Trinket|r")
		else
			typeText:SetText("|cffffcc00Consumable|r")
		end
		
		itemRows[i] = row

		-- Drag handle (replaces the old Up/Down buttons) + Top/Bottom
		-- quick-action arrows for jumping straight to either end of a long list.
		local gripBtn = add_row_drag_handle(row, itemRows, orderedItems, i, slotYs, GCDI.commit_item_order, refresh_items_tab)
		gripBtn:SetPoint("LEFT", ITEMS_COLUMNS.drag.x, 0)

		local topBtn = acquire_frame("Button", row, "UIPanelScrollUpButtonTemplate")
		topBtn:SetSize(18, 16)
		topBtn:SetPoint("LEFT", gripBtn, "RIGHT", 2, 0)
		topBtn:SetEnabled(i > 1)
		topBtn:SetScript("OnClick", function()
			GCDI.move_item_to_top(itemKey)
			GCDI.refresh_options_frame()
		end)
		topBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Move to top")
			GameTooltip:AddLine("Jumps this item to the start of the list - faster than dragging across a long, scrolled list.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		topBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

		local bottomBtn = acquire_frame("Button", row, "UIPanelScrollDownButtonTemplate")
		bottomBtn:SetSize(18, 16)
		bottomBtn:SetPoint("LEFT", topBtn, "RIGHT", 2, 0)
		bottomBtn:SetEnabled(i < #orderedItems)
		bottomBtn:SetScript("OnClick", function()
			GCDI.move_item_to_bottom(itemKey)
			GCDI.refresh_options_frame()
		end)
		bottomBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Move to bottom")
			GameTooltip:AddLine("Jumps this item to the end of the list - faster than dragging across a long, scrolled list.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		bottomBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

		-- Off GCD checkbox. Metadata only: doesn't affect the addon's own
		-- display, only feeds the companion-script config export's hasGCD
		-- field (see is_item_off_gcd in GCDIndicator.lua).
		local offGcdCheckbox = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
		offGcdCheckbox:SetSize(24, 24)
		offGcdCheckbox:SetPoint("LEFT", ITEMS_COLUMNS.gcd.x, 0)
		offGcdCheckbox:SetChecked(itemSettings.offGCD == true)
		offGcdCheckbox:SetScript("OnClick", function(self)
			if not GCDI.settings.itemSettings[itemKey] then
				GCDI.settings.itemSettings[itemKey] = {}
			end
			GCDI.settings.itemSettings[itemKey].offGCD = self:GetChecked()
			GCDI.auto_save_to_profile()
		end)
		offGcdCheckbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Off GCD")
			GameTooltip:AddLine("Check if this item does NOT trigger the global cooldown.", 1, 1, 1, true)
			GameTooltip:AddLine("Rare - most on-use items are on GCD. Used only by the companion-script config export (hasGCD field).", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		offGcdCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
	
	-- Rows and their children are registered by acquire_*, so the tracking list owns
	-- the whole tree; buffRows must not be released separately (double free).
	reset_track_list(buffsTabElements)
	wipe(buffRows)

	local scrollChild = optionsFrame.buffsScrollChild
	local yOffset = -10

	local function track(element)
		return element
	end

	-- Rescan Buffs button
	local rescanBuffsBtn = track(acquire_frame("Button", scrollChild, "UIPanelButtonTemplate"))
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
	local addBuffLabel = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormal"))
	addBuffLabel:SetPoint("TOPLEFT", 10, yOffset)
	addBuffLabel:SetText("Add Buff by Spell ID:")
	
	local addBuffEditBox = track(acquire_frame("EditBox", scrollChild, "InputBoxTemplate"))
	addBuffEditBox:SetSize(80, 20)
	addBuffEditBox:SetPoint("LEFT", addBuffLabel, "RIGHT", 10, 0)
	addBuffEditBox:SetAutoFocus(false)
	addBuffEditBox:SetNumeric(true)
	addBuffEditBox:SetMaxLetters(10)
	
	local addBuffBtn = track(acquire_frame("Button", scrollChild, "UIPanelButtonTemplate"))
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
	
	local helpText = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	helpText:SetPoint("TOPLEFT", 10, yOffset - 25)
	helpText:SetTextColor(0.7, 0.7, 0.7)
	helpText:SetText("Tip: Get spell IDs from Wowhead or addon tooltips. Buffs are auto-detected when applied.")
	yOffset = yOffset - 55
	
	-- Separator
	local sep = track(acquire_texture(scrollChild, "ARTWORK"))
	sep:SetColorTexture(0.4, 0.4, 0.4, 1)
	sep:SetSize(540, 1)
	sep:SetPoint("TOPLEFT", 10, yOffset)
	yOffset = yOffset - 15
	
	-- Single source of truth for this tab's column x-offsets (row-relative -
	-- rows themselves sit at ROW_BASE_X). See SPELLS_COLUMNS above / header_x()
	-- for how headerX overrides work.
	-- maxStacks/threshold store `width` = the value passed to
	-- UIDropDownMenu_SetWidth, not the dropdown's true rendered width (that's
	-- width + DROPDOWN_WIDTH_PADDING) - see center_header_over_dropdown. This
	-- tab previously had maxStacks/duration/threshold/drag all overlapping
	-- each other because that padding wasn't budgeted for.
	local BUFFS_COLUMNS = {
		enabled   = { x = 0 },
		stacks    = { x = 28 },
		icon      = { x = 56, headerX = 70 },   -- header nudged toward the name column
		name      = { x = 80, width = 110 },    -- capped so a long buff name can't run into Max Stacks
		maxStacks = { x = 198, width = 60 },    -- name's end (190) + 8px gap; true rendered width 110 (198-308)
		duration  = { x = 316 },                -- 308 + 8px gap
		threshold = { x = 348, width = 50 },    -- 316+24 (checkbox) + 8px gap; true rendered width 100 (348-448)
		drag      = { x = 456 },                -- 448 + 8px gap
	}

	-- Column headers
	local enabledHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	enabledHeader:SetPoint("TOPLEFT", header_x(BUFFS_COLUMNS.enabled), yOffset)
	enabledHeader:SetText("On")

	local stacksHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	stacksHeader:SetPoint("TOPLEFT", header_x(BUFFS_COLUMNS.stacks), yOffset)
	stacksHeader:SetText("Stk")

	local buffNameHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	buffNameHeader:SetPoint("TOPLEFT", header_x(BUFFS_COLUMNS.icon), yOffset)
	buffNameHeader:SetText("Buff (ID)")

	local maxStacksHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	maxStacksHeader:SetPoint("TOPLEFT", header_x(BUFFS_COLUMNS.maxStacks), yOffset)
	center_header_over_dropdown(maxStacksHeader, BUFFS_COLUMNS.maxStacks)
	maxStacksHeader:SetText("Max Stacks")

	local durationHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	durationHeader:SetPoint("TOPLEFT", header_x(BUFFS_COLUMNS.duration), yOffset)
	durationHeader:SetText("Dur")

	local thresholdHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	thresholdHeader:SetPoint("TOPLEFT", header_x(BUFFS_COLUMNS.threshold), yOffset)
	center_header_over_dropdown(thresholdHeader, BUFFS_COLUMNS.threshold)
	thresholdHeader:SetText("Thr%")

	local orderHeader = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
	orderHeader:SetPoint("TOPLEFT", header_x(BUFFS_COLUMNS.drag), yOffset)
	orderHeader:SetText("Order")
	yOffset = yOffset - 20
	
	-- Create rows
	local orderedBuffs = GCDI.get_all_catalog_buffs_ordered()
	local disabledSectionStarted = false
	local slotYs = {}

	if #orderedBuffs == 0 then
		local noBuffsText = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormal"))
		noBuffsText:SetPoint("TOPLEFT", 10, yOffset)
		noBuffsText:SetText("|cff888888No buffs being tracked.|r")
		yOffset = yOffset - 30
		
		local tipText = track(acquire_fontstring(scrollChild, "OVERLAY", "GameFontNormalSmall"))
		tipText:SetPoint("TOPLEFT", 10, yOffset)
		tipText:SetText("Add buffs by spell ID above, or they'll be auto-detected when applied.")
		yOffset = yOffset - 25
	end
	
	for i, buffKey in ipairs(orderedBuffs) do
		local catalogEntry = GCDI.buffCatalog[buffKey]
		if not catalogEntry then
			break
		end
		
		local buffName = catalogEntry.name
		local texture = catalogEntry.texture
		-- buffKey is cooldownID for CDM entries; show spellID when present (matches CDM/spell IDs)
		local displayID = catalogEntry.spellID or buffKey
		
		local buffSettings = settings.buffSettings and settings.buffSettings[buffKey]
		if not buffSettings then
			if not settings.buffSettings then settings.buffSettings = {} end
			settings.buffSettings[buffKey] = { enabled = true, showStacks = true, maxStacksDisplay = 5 }
			buffSettings = settings.buffSettings[buffKey]
		end
		
		-- Separator before disabled buffs
		if not GCDI.is_buff_enabled(buffKey) and not disabledSectionStarted then
			disabledSectionStarted = true
			yOffset = add_disabled_section_separator(scrollChild, yOffset, 540, "Buffs")
		end
		slotYs[i] = yOffset

		local row = acquire_frame("Frame", scrollChild)
		row:SetSize(540, 30)
		row:SetPoint("TOPLEFT", 10, yOffset)
		
		-- Enabled checkbox
		local checkbox = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
		checkbox:SetSize(24, 24)
		checkbox:SetPoint("LEFT", BUFFS_COLUMNS.enabled.x, 0)
		checkbox:SetChecked(buffSettings.enabled ~= false)
		checkbox:SetScript("OnClick", function(self)
			if not GCDI.settings.buffSettings then
				GCDI.settings.buffSettings = {}
			end
			if not GCDI.settings.buffSettings[buffKey] then
				GCDI.settings.buffSettings[buffKey] = {}
			end
			GCDI.settings.buffSettings[buffKey].enabled = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.rebuild_buff_bars()
			GCDI.reposition_all()
			GCDI.refresh_options_frame()
		end)
		
		-- Show Stacks checkbox
		local stacksCheckbox = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
		stacksCheckbox:SetSize(24, 24)
		stacksCheckbox:SetPoint("LEFT", BUFFS_COLUMNS.stacks.x, 0)
		stacksCheckbox:SetChecked(buffSettings.showStacks ~= false)
		stacksCheckbox:SetScript("OnClick", function(self)
			if not GCDI.settings.buffSettings[buffKey] then
				GCDI.settings.buffSettings[buffKey] = {}
			end
			GCDI.settings.buffSettings[buffKey].showStacks = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.rebuild_buff_bars()
			GCDI.reposition_all()
		end)
		stacksCheckbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Show Stacks")
			GameTooltip:AddLine("Like combo points: one StatusBar, fill = stack count; black lines mark segments.", 1, 1, 1, true)
			GameTooltip:AddLine("Segment count comes from Max Stacks below (options).", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		stacksCheckbox:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		-- Buff icon
		local icon = acquire_texture(row, "ARTWORK")
		icon:SetSize(20, 20)
		icon:SetPoint("LEFT", BUFFS_COLUMNS.icon.x, 0)
		icon:SetTexture(texture)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		local buffTooltipSpellID = catalogEntry.tooltipSpellID or catalogEntry.spellID or buffKey
		local iconTip = acquire_frame("Frame", row)
		iconTip:SetSize(20, 20)
		iconTip:SetPoint("LEFT", BUFFS_COLUMNS.icon.x, 0)
		iconTip:EnableMouse(true)
		iconTip:SetScript("OnEnter", function(self)
			if buffTooltipSpellID and buffTooltipSpellID > 0 then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetSpellByID(buffTooltipSpellID)
				GameTooltip:Show()
			end
		end)
		iconTip:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		-- Buff name with spell ID (displayID = spell ID when from CDM; matches
		-- CDM/spell IDs). Width capped so a long name can't run into Max Stacks.
		local nameText = acquire_fontstring(row, "OVERLAY", "GameFontNormal")
		nameText:SetPoint("LEFT", BUFFS_COLUMNS.name.x, 0)
		nameText:SetWidth(BUFFS_COLUMNS.name.width)
		nameText:SetJustifyH("LEFT")
		nameText:SetText(buffName .. " |cff888888(" .. displayID .. ")|r")
		if catalogEntry.spellID and buffKey ~= catalogEntry.spellID then
			nameText:SetScript("OnEnter", function(self) GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText("Spell: " .. catalogEntry.spellID); GameTooltip:AddLine("CDM cooldownID: " .. buffKey, 0.7, 0.7, 0.7, true); GameTooltip:Show() end)
			nameText:SetScript("OnLeave", function() GameTooltip:Hide() end)
		end
		
		-- Max stacks dropdown
		local maxStacksDropdown = acquire_frame("Frame", row, "UIDropDownMenuTemplate")
		maxStacksDropdown:SetPoint("LEFT", BUFFS_COLUMNS.maxStacks.x, 0)
		UIDropDownMenu_SetWidth(maxStacksDropdown, BUFFS_COLUMNS.maxStacks.width)
		maxStacksDropdown:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Max stacks")
			GameTooltip:AddLine("How many stack segments the stack bar shows for this buff (only matters when Stk is checked).", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		maxStacksDropdown:SetScript("OnLeave", function() GameTooltip:Hide() end)

		local function initMaxStacksDropdown(self, level)
			local currentBuffSettings = GCDI.settings.buffSettings and GCDI.settings.buffSettings[buffKey] or {}
			for stacks = 1, 10 do
				local info = UIDropDownMenu_CreateInfo()
				info.text = tostring(stacks)
				info.value = stacks
				info.checked = (currentBuffSettings.maxStacksDisplay == stacks)
				info.func = function()
					if not GCDI.settings.buffSettings[buffKey] then
						GCDI.settings.buffSettings[buffKey] = {}
					end
					GCDI.settings.buffSettings[buffKey].maxStacksDisplay = stacks
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
		local durationCb = acquire_frame("CheckButton", row, "UICheckButtonTemplate")
		durationCb:SetPoint("LEFT", BUFFS_COLUMNS.duration.x, 0)
		durationCb:SetSize(24, 24)
		durationCb:SetChecked(buffSettings.showDurationBar == true)
		durationCb:SetScript("OnClick", function(self)
			if not GCDI.settings.buffSettings[buffKey] then
				GCDI.settings.buffSettings[buffKey] = {}
			end
			GCDI.settings.buffSettings[buffKey].showDurationBar = self:GetChecked()
			GCDI.auto_save_to_profile()
			GCDI.rebuild_buff_bars()
			GCDI.reposition_all()
		end)
		durationCb:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Show pandemic indicator")
			GameTooltip:AddLine("Adds a small indicator next to this buff/DoT that flips color once its remaining duration drops below the Thr% threshold to the right - the refresh (pandemic) window.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		durationCb:SetScript("OnLeave", function() GameTooltip:Hide() end)
		
		-- Threshold dropdown (5% increments). UIDropDownMenu needs a global name, so
		-- this one cannot come from the type-keyed pool: reuse the frame already
		-- registered under this buff's name instead of creating a second one under
		-- the same name on every refresh.
		local thresholdName = "GCDI_BuffThreshold_" .. buffKey
		local thresholdDropdown = _G[thresholdName]
		if thresholdDropdown then
			thresholdDropdown:SetParent(row)
			thresholdDropdown:ClearAllPoints()
			thresholdDropdown:Show()
		else
			thresholdDropdown = CreateFrame("Frame", thresholdName, row, "UIDropDownMenuTemplate")
		end
		pool_register(thresholdDropdown)
		thresholdDropdown:SetPoint("LEFT", BUFFS_COLUMNS.threshold.x, -3)
		UIDropDownMenu_SetWidth(thresholdDropdown, BUFFS_COLUMNS.threshold.width)
		thresholdDropdown:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Pandemic threshold")
			GameTooltip:AddLine("The pandemic indicator (Dur checkbox) flips color once this buff/DoT has this % or less of its duration remaining - the window where refreshing it doesn't waste time.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		thresholdDropdown:SetScript("OnLeave", function() GameTooltip:Hide() end)

		local function initThresholdDropdown(self, level)
			local currentThreshold = buffSettings.durationThreshold or 30
			for pct = 5, 95, 5 do
				local info = UIDropDownMenu_CreateInfo()
				info.text = pct .. "%"
				info.value = pct
				info.checked = (currentThreshold == pct)
				info.func = function()
					if not GCDI.settings.buffSettings[buffKey] then
						GCDI.settings.buffSettings[buffKey] = {}
					end
					GCDI.settings.buffSettings[buffKey].durationThreshold = pct
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
		
		buffRows[i] = row

		-- Drag handle (replaces the old Up/Down buttons) + Top/Bottom
		-- quick-action arrows for jumping straight to either end of a long list
		-- (buffs previously had no bottom shortcut at all - added here for
		-- parity with Spells/Items).
		local gripBtn = add_row_drag_handle(row, buffRows, orderedBuffs, i, slotYs, GCDI.commit_buff_order, refresh_buffs_tab)
		gripBtn:SetPoint("LEFT", BUFFS_COLUMNS.drag.x, 0)

		local topBtn = acquire_frame("Button", row, "UIPanelScrollUpButtonTemplate")
		topBtn:SetSize(18, 16)
		topBtn:SetPoint("LEFT", gripBtn, "RIGHT", 2, 0)
		topBtn:SetEnabled(i > 1)
		topBtn:SetScript("OnClick", function()
			GCDI.move_buff_to_top(buffKey)
			GCDI.refresh_options_frame()
		end)
		topBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Move to top")
			GameTooltip:AddLine("Jumps this buff to the start of the list - faster than dragging across a long, scrolled list.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		topBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

		local bottomBtn = acquire_frame("Button", row, "UIPanelScrollDownButtonTemplate")
		bottomBtn:SetSize(18, 16)
		bottomBtn:SetPoint("LEFT", topBtn, "RIGHT", 2, 0)
		bottomBtn:SetEnabled(i < #orderedBuffs)
		bottomBtn:SetScript("OnClick", function()
			GCDI.move_buff_to_bottom(buffKey)
			GCDI.refresh_options_frame()
		end)
		bottomBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Move to bottom")
			GameTooltip:AddLine("Jumps this buff to the end of the list - faster than dragging across a long, scrolled list.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		bottomBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

		local removeBtn = acquire_frame("Button", row, "UIPanelButtonTemplate")
		removeBtn:SetSize(24, 18)
		removeBtn:SetPoint("LEFT", bottomBtn, "RIGHT", 2, 0)
		removeBtn:SetText("X")
		removeBtn:SetNormalFontObject("GameFontNormalSmall")
		removeBtn:SetHighlightFontObject("GameFontHighlightSmall")
		removeBtn:SetScript("OnClick", function()
			GCDI.remove_buff_from_catalog(buffKey)
			GCDI.refresh_options_frame()
		end)
		removeBtn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText("Remove Buff")
			GameTooltip:AddLine("Remove this buff from tracking.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		removeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

		yOffset = yOffset - 35
	end

	scrollChild:SetHeight(math.abs(yOffset) + 20)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- TAB SWITCHING
-- ═══════════════════════════════════════════════════════════════════════════

switch_tab = function(tabName)
	if not optionsFrame then return end
	currentTab = tabName

	for _, def in ipairs(TAB_DEFS) do
		local btn = tabButtons[def.key]
		if btn then
			if def.key == tabName then
				btn:SetNormalFontObject("GameFontHighlight")
				btn:GetFontString():SetTextColor(1, 1, 1)
				btn.bg:SetColorTexture(unpack(TAB_BG_ACTIVE))
			else
				btn:SetNormalFontObject("GameFontNormal")
				btn:GetFontString():SetTextColor(0.7, 0.7, 0.7)
				btn.bg:SetColorTexture(unpack(TAB_BG_INACTIVE))
			end
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
	if optionsFrame.settingsScrollFrame then
		optionsFrame.settingsScrollFrame:SetShown(tabName == "settings")
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
	elseif tabName == "settings" then
		refresh_settings_tab()
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

-- Export rotation config: ask which spec slot (Primary/Secondary) this
-- export represents - the addon only ever reflects whichever spec/build is
-- currently active in-game, so the user has to say which companion-script
-- function block (GetPrimaryXList vs GetSecondaryXList) it should replace.
-- Note: Escape (hideOnEscape) triggers OnCancel, same as clicking
-- "Secondary" - there's no true no-op "cancel" option here, but either
-- choice is harmless (just opens a copyable text popup, doesn't change any
-- setting), so this is a rough edge, not a real risk.
StaticPopupDialogs["GCDI_EXPORT_ROTATION_CONFIG"] = {
	text = "Export current spells/items/buffs/resources as which spec slot?",
	button1 = "Primary",
	button2 = "Secondary",
	OnAccept = function()
		if GCDI.export_ahk_config and GCDI.show_export_import_popup then
			GCDI.show_export_import_popup("export", GCDI.export_ahk_config("Primary"), "Rotation Config Export (Primary)")
		end
	end,
	OnCancel = function()
		if GCDI.export_ahk_config and GCDI.show_export_import_popup then
			GCDI.show_export_import_popup("export", GCDI.export_ahk_config("Secondary"), "Rotation Config Export (Secondary)")
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
				globalRangeFallbackYards = s.globalRangeFallbackYards,
				rangeProxySpells = s.rangeProxySpells and deepcopy(s.rangeProxySpells) or {},
				spellSettings = LibProfiles.SpellSettingsForSave(s.spellSettings),
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
		if data.gy ~= nil then s.globalRangeFallbackYards = data.gy end
		if data.rp ~= nil then s.rangeProxySpells = data.rp end
		-- Legacy import
		if data.g ~= nil and GCDI.LEGACY_INDEX_TO_YARDS and GCDI.LEGACY_INDEX_TO_YARDS[data.g] ~= nil then
			s.globalRangeFallbackYards = GCDI.LEGACY_INDEX_TO_YARDS[data.g]
		end
		if data.m ~= nil and not (s.rangeProxySpells and s.rangeProxySpells[5]) then
			s.rangeProxySpells = s.rangeProxySpells or {}
			s.rangeProxySpells[5] = data.m
		end
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
			globalRangeFallbackYards = s.globalRangeFallbackYards,
			rangeProxySpells = s.rangeProxySpells and deepcopy(s.rangeProxySpells) or {},
			spellSettings = LibProfiles.SpellSettingsForSave(s.spellSettings),
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
		globalRangeFallbackYards = s.globalRangeFallbackYards,
		rangeProxySpells = s.rangeProxySpells and deepcopy(s.rangeProxySpells) or {},
		spellSettings = LibProfiles.SpellSettingsForSave(s.spellSettings),
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

local function show_export_import_popup(mode, initialText, titleOverride)
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
	
	exportImportFrame.TitleText:SetText(titleOverride or (mode == "export" and "Export Settings" or "Import Settings"))
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
GCDI.show_export_import_popup = show_export_import_popup

local profilesTabElements = {}

refresh_profiles_tab = function()
	if not optionsFrame or not optionsFrame.profilesFrame then return end
	
	-- Always sync settings reference
	settings = GCDI.settings
	
	reset_track_list(profilesTabElements)

	local frame = optionsFrame.profilesFrame

	local function track(element)
		return element
	end

	local yOffset = -10
	
	-- ═══════════════════════════════════════════════════════════════════════════
	-- PROFILE MANAGEMENT SECTION
	-- ═══════════════════════════════════════════════════════════════════════════
	
	local sectionTitle = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormalLarge"))
	sectionTitle:SetPoint("TOPLEFT", 5, yOffset)
	sectionTitle:SetText("Profile Management")
	yOffset = yOffset - 25
	
	local sectionDesc = track(acquire_fontstring(frame, "OVERLAY", "GameFontHighlight"))
	sectionDesc:SetPoint("TOPLEFT", 5, yOffset)
	sectionDesc:SetText("Load, save, or create profiles to manage different configurations.")
	sectionDesc:SetTextColor(0.7, 0.7, 0.7)
	yOffset = yOffset - 30
	
	-- Current Profile Dropdown
	local profileLabel = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
	profileLabel:SetPoint("TOPLEFT", 5, yOffset)
	profileLabel:SetText("Current Profile:")
	
	local profileNames = GCDI.get_profile_names()
	local profileDropdown = track(acquire_frame("Frame", frame, "UIDropDownMenuTemplate"))
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
	
	local saveBtn = track(acquire_frame("Button", frame, "UIPanelButtonTemplate"))
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
	
	local deleteBtn = track(acquire_frame("Button", frame, "UIPanelButtonTemplate"))
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
	local createLabel = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormal"))
	createLabel:SetPoint("TOPLEFT", 5, yOffset)
	createLabel:SetText("Create New:")
	
	local createEditBox = track(acquire_frame("EditBox", frame, "InputBoxTemplate"))
	createEditBox:SetSize(150, 22)
	createEditBox:SetPoint("LEFT", createLabel, "RIGHT", 10, 0)
	createEditBox:SetAutoFocus(false)
	createEditBox:SetMaxLetters(30)
	
	local createBtn = track(acquire_frame("Button", frame, "UIPanelButtonTemplate"))
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
	
	local sep1 = track(acquire_texture(frame, "ARTWORK"))
	sep1:SetColorTexture(0.4, 0.4, 0.4, 1)
	sep1:SetSize(480, 1)
	sep1:SetPoint("TOPLEFT", 5, yOffset)
	yOffset = yOffset - 20
	
	local exportImportTitle = track(acquire_fontstring(frame, "OVERLAY", "GameFontNormalLarge"))
	exportImportTitle:SetPoint("TOPLEFT", 5, yOffset)
	exportImportTitle:SetText("Export / Import")
	yOffset = yOffset - 25
	
	local exportImportDesc = track(acquire_fontstring(frame, "OVERLAY", "GameFontHighlight"))
	exportImportDesc:SetPoint("TOPLEFT", 5, yOffset)
	exportImportDesc:SetText("Share your settings with others or transfer between characters.")
	exportImportDesc:SetTextColor(0.7, 0.7, 0.7)
	yOffset = yOffset - 30
	
	local exportBtn = track(acquire_frame("Button", frame, "UIPanelButtonTemplate"))
	exportBtn:SetSize(120, 28)
	exportBtn:SetPoint("TOPLEFT", 5, yOffset)
	exportBtn:SetText("Export Settings")
	exportBtn:SetScript("OnClick", function()
		local exportData = {
			v = 1,
			gy = settings.globalRangeFallbackYards,
			rp = settings.rangeProxySpells,
			ss = LibProfiles.SpellSettingsForSave(settings.spellSettings or {}),
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
	
	local importBtn = track(acquire_frame("Button", frame, "UIPanelButtonTemplate"))
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
	elseif currentTab == "settings" then
		refresh_settings_tab()
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
	optionsFrame:SetSize(670, 500)
	optionsFrame:SetPoint("CENTER")
	optionsFrame:SetMovable(true)
	optionsFrame:EnableMouse(true)
	optionsFrame:RegisterForDrag("LeftButton")
	optionsFrame:SetScript("OnDragStart", optionsFrame.StartMoving)
	optionsFrame:SetScript("OnDragStop", optionsFrame.StopMovingOrSizing)
	optionsFrame:SetFrameStrata("DIALOG")
	
	optionsFrame.TitleText:SetText("GCDIndicator Options")
	
	-- TAB BUTTONS: table-driven, see create_tab_button. Width is derived from
	-- each label's own text width instead of hand-picked per-tab numbers.
	local prevTabBtn = nil
	for _, def in ipairs(TAB_DEFS) do
		prevTabBtn = create_tab_button(optionsFrame, def, prevTabBtn)
	end

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
	spellsScrollChild:SetSize(600, 600)
	spellsScrollFrame:SetScrollChild(spellsScrollChild)
	optionsFrame.spellsScrollChild = spellsScrollChild
	
	-- ITEMS SCROLL FRAME
	local itemsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	itemsScrollFrame:SetPoint("TOPLEFT", 10, -60)
	itemsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	itemsScrollFrame:Hide()
	optionsFrame.itemsScrollFrame = itemsScrollFrame
	
	local itemsScrollChild = CreateFrame("Frame", nil, itemsScrollFrame)
	itemsScrollChild:SetSize(480, 600)
	itemsScrollFrame:SetScrollChild(itemsScrollChild)
	optionsFrame.itemsScrollChild = itemsScrollChild
	
	-- BUFFS SCROLL FRAME
	local buffsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	buffsScrollFrame:SetPoint("TOPLEFT", 10, -60)
	buffsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	buffsScrollFrame:Hide()
	optionsFrame.buffsScrollFrame = buffsScrollFrame
	
	local buffsScrollChild = CreateFrame("Frame", nil, buffsScrollFrame)
	buffsScrollChild:SetSize(540, 800)
	buffsScrollFrame:SetScrollChild(buffsScrollChild)
	optionsFrame.buffsScrollChild = buffsScrollChild
	
	-- SETTINGS SCROLL FRAME
	-- Used to be a plain fixed-size Frame (no scrolling), unlike every other
	-- tab - content past the bottom edge just got silently clipped instead of
	-- being reachable. Same ScrollFrame + scroll-child pattern as the other
	-- tabs now; the settings widgets below are unchanged, just reparented.
	local settingsScrollFrame = CreateFrame("ScrollFrame", nil, optionsFrame, "UIPanelScrollFrameTemplate")
	settingsScrollFrame:SetPoint("TOPLEFT", 10, -60)
	settingsScrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
	settingsScrollFrame:Hide()
	optionsFrame.settingsScrollFrame = settingsScrollFrame

	local settingsFrame = CreateFrame("Frame", nil, settingsScrollFrame)
	settingsFrame:SetSize(500, 650)
	settingsScrollFrame:SetScrollChild(settingsFrame)
	optionsFrame.settingsFrame = settingsFrame

	-- Settings tab used to place every widget at a hand-measured absolute Y
	-- (-70, -150, -175, -220...) instead of the yOffset-accumulator pattern
	-- every other tab uses, so gaps between blocks drifted (42px here, 17px
	-- there) purely by feel, and the "Experimental" block was visibly bolted
	-- onto the bottom without adjusting anything around it. Same accumulator
	-- + section-header helper as the other tabs now.
	local SETTINGS_BUTTON_HEIGHT = 28
	local SETTINGS_BUTTON_GAP = 10
	local SETTINGS_BLOCK_GAP = 20

	local sYOffset = -10

	sYOffset = add_section_header(settingsFrame, sYOffset, "Frame Position",
		"Use these buttons to move or reset the GCD indicator bars.", 500, false)

	-- Move Frame Button
	local moveBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
	moveBtn:SetSize(150, SETTINGS_BUTTON_HEIGHT)
	moveBtn:SetPoint("TOPLEFT", 5, sYOffset)
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
	sYOffset = sYOffset - (SETTINGS_BUTTON_HEIGHT + SETTINGS_BUTTON_GAP)

	-- Reset Position Button
	local resetBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
	resetBtn:SetSize(150, SETTINGS_BUTTON_HEIGHT)
	resetBtn:SetPoint("TOPLEFT", 5, sYOffset)
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
	sYOffset = sYOffset - (SETTINGS_BUTTON_HEIGHT + SETTINGS_BLOCK_GAP)

	-- Minimap Button Toggle
	sYOffset = add_section_header(settingsFrame, sYOffset, "Minimap Button", nil, 500)

	local minimapToggleBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
	minimapToggleBtn:SetSize(150, SETTINGS_BUTTON_HEIGHT)
	minimapToggleBtn:SetPoint("TOPLEFT", 5, sYOffset)
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
	sYOffset = sYOffset - (SETTINGS_BUTTON_HEIGHT + SETTINGS_BLOCK_GAP)

	-- Preview Mode Section
	sYOffset = add_section_header(settingsFrame, sYOffset, "Preview Mode",
		"Show all bars filled with visible colors for positioning.", 500)

	local previewBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
	previewBtn:SetSize(150, SETTINGS_BUTTON_HEIGHT)
	previewBtn:SetPoint("TOPLEFT", 5, sYOffset)
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
	sYOffset = sYOffset - (SETTINGS_BUTTON_HEIGHT + SETTINGS_BLOCK_GAP)

	-- Experimental: Native Stack Binding (A/B toggle, see CHANGE-TRACKER.md)
	sYOffset = add_section_header(settingsFrame, sYOffset, "Experimental", nil, 500)

	local nativeStackCheckbox = CreateFrame("CheckButton", nil, settingsFrame, "UICheckButtonTemplate")
	nativeStackCheckbox:SetSize(24, 24)
	nativeStackCheckbox:SetPoint("TOPLEFT", 0, sYOffset)
	nativeStackCheckbox:SetChecked(configs.useNativeStackBinding == true)
	optionsFrame.nativeStackCheckbox = nativeStackCheckbox
	nativeStackCheckbox:SetScript("OnClick", function(self)
		configs.useNativeStackBinding = self:GetChecked() and true or false
		print("|cff00ff00GCDIndicator:|r Native stack binding " .. (configs.useNativeStackBinding and "ON (experimental)" or "OFF (classic)"))
		if GCDI.rebuild_buff_bars then
			GCDI.rebuild_buff_bars()
		end
	end)
	local nativeStackLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	nativeStackLabel:SetPoint("LEFT", nativeStackCheckbox, "RIGHT", 5, 0)
	nativeStackLabel:SetText("Use native engine stack binding (A/B test)")
	local nativeStackHelp = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	nativeStackHelp:SetPoint("TOPLEFT", nativeStackLabel, "BOTTOMLEFT", 0, -4)
	nativeStackHelp:SetWidth(440)
	nativeStackHelp:SetJustifyH("LEFT")
	nativeStackHelp:SetText("Alternate buff stack tracking using the 12.1+ AuraContainer engine API instead of the classic C_UnitAuras query. Experimental and untested in combat - see CHANGE-TRACKER.md.")
	nativeStackHelp:SetTextColor(0.55, 0.55, 0.55)
	sYOffset = sYOffset - (SETTINGS_BUTTON_HEIGHT + 24 + SETTINGS_BLOCK_GAP)

	-- Compact Mode (flow-packed spell/item/buff layout, see CHANGE-TRACKER.md)
	local compactModeCheckbox = CreateFrame("CheckButton", nil, settingsFrame, "UICheckButtonTemplate")
	compactModeCheckbox:SetSize(24, 24)
	compactModeCheckbox:SetPoint("TOPLEFT", 0, sYOffset)
	compactModeCheckbox:SetChecked(configs.compactMode == true)
	optionsFrame.compactModeCheckbox = compactModeCheckbox
	compactModeCheckbox:SetScript("OnClick", function(self)
		configs.compactMode = self:GetChecked() and true or false
		if settings then
			settings.compactMode = configs.compactMode  -- persist (SavedVariablesPerCharacter)
		end
		print("|cff00ff00GCDIndicator:|r Compact mode " .. (configs.compactMode and "ON" or "OFF"))
		-- Box layout (icon square present/absent) is baked in at creation
		-- time, not just position, so toggling needs a full rebuild.
		if GCDI.rebuild_spell_bars then
			GCDI.rebuild_spell_bars()  -- also rebuilds item bars
		end
		if GCDI.rebuild_buff_bars then
			GCDI.rebuild_buff_bars()
		end
	end)
	local compactModeLabel = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	compactModeLabel:SetPoint("LEFT", compactModeCheckbox, "RIGHT", 5, 0)
	compactModeLabel:SetText("Compact layout (flow spells/items and buffs left-to-right)")
	local compactModeHelp = settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	compactModeHelp:SetPoint("TOPLEFT", compactModeLabel, "BOTTOMLEFT", 0, -4)
	compactModeHelp:SetWidth(440)
	compactModeHelp:SetJustifyH("LEFT")
	compactModeHelp:SetText("Packs spell, item, and buff boxes into one continuous left-to-right flow with a 2px gap, wrapping to a new row instead of using 3 fixed columns. Icon squares are dropped to save space. Also update your companion script's compact mode toggle to match, or pixel reads will desync.")
	compactModeHelp:SetTextColor(0.55, 0.55, 0.55)
	sYOffset = sYOffset - (SETTINGS_BUTTON_HEIGHT + 24 + SETTINGS_BLOCK_GAP)

	-- Export bar positions (diagnostic: cross-check against what the
	-- companion script computes for the same spell/item/buff list, see
	-- export_bar_positions() in GCDIndicator.lua)
	local exportBarsBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
	exportBarsBtn:SetSize(180, SETTINGS_BUTTON_HEIGHT)
	exportBarsBtn:SetPoint("TOPLEFT", 0, sYOffset)
	exportBarsBtn:SetText("Export Bar Positions")
	exportBarsBtn:SetScript("OnClick", function()
		if GCDI.export_bar_positions then
			show_export_import_popup("export", GCDI.export_bar_positions(), "Bar Position Export")
		end
	end)
	exportBarsBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Export Bar Positions")
		GameTooltip:AddLine("Dumps every visible bar's position/size for cross-checking against your companion script.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	exportBarsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Export rotation config (generates spell/item/buff/resource array text
	-- from the live catalog/settings state, to paste into a companion
	-- rotation script instead of hand-maintaining it - see
	-- export_ahk_config() in GCDIndicator.lua)
	local exportAhkBtn = CreateFrame("Button", nil, settingsFrame, "UIPanelButtonTemplate")
	exportAhkBtn:SetSize(180, SETTINGS_BUTTON_HEIGHT)
	exportAhkBtn:SetPoint("LEFT", exportBarsBtn, "RIGHT", 10, 0)
	exportAhkBtn:SetText("Export Rotation Config")
	exportAhkBtn:SetScript("OnClick", function()
		StaticPopup_Show("GCDI_EXPORT_ROTATION_CONFIG")
	end)
	exportAhkBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText("Export Rotation Config")
		GameTooltip:AddLine("Generates spell/item/buff array text from your current spells/items/buffs and their order.", 1, 1, 1, true)
		GameTooltip:AddLine("Asks whether to label it Primary or Secondary spec first.", 1, 1, 1, true)
		GameTooltip:AddLine("key/hasGCD fields still need to be filled in by hand - the addon has no concept of rotation keybinds.", 0.8, 0.6, 0.2, true)
		GameTooltip:Show()
	end)
	exportAhkBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Re-syncs the Settings tab's checkbox states from current configs. The
	-- tab's widgets are built once here (not pooled/rebuilt per refresh like
	-- the other tabs), so without this, flipping configs.useNativeStackBinding/
	-- compactMode via slash command while the panel is open left the checkbox
	-- visually stale until the panel was closed and reopened (see
	-- CHANGE-TRACKER.md) - switch_tab/refresh_options_frame now call this like
	-- every other tab's refresh function.
	refresh_settings_tab = function()
		if optionsFrame.nativeStackCheckbox then
			optionsFrame.nativeStackCheckbox:SetChecked(configs.useNativeStackBinding == true)
		end
		if optionsFrame.compactModeCheckbox then
			optionsFrame.compactModeCheckbox:SetChecked(configs.compactMode == true)
		end
	end

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

	switch_tab("gcd")
	optionsFrame:Show()
end

-- Export create function
GCDI.create_options_frame = create_options_frame
