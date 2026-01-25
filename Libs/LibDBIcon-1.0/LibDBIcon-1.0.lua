--[[
LibDBIcon-1.0 - A library to display minimap icons
License: Public Domain
]]

local DBICON10 = "LibDBIcon-1.0"
local DBICON10_MINOR = 47

local lib = LibStub:NewLibrary(DBICON10, DBICON10_MINOR)
if not lib then return end

lib.objects = lib.objects or {}
lib.callbackRegistered = lib.callbackRegistered or nil
lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)
lib.radius = lib.radius or 80
local next, Minimap, CreateFrame = next, Minimap, CreateFrame

local function getAnchors(frame)
	local x, y = frame:GetCenter()
	if not x or not y then return "CENTER" end
	local hhalf = (x > UIParent:GetWidth()*2/3) and "RIGHT" or (x < UIParent:GetWidth()/3) and "LEFT" or ""
	local vhalf = (y > UIParent:GetHeight()/2) and "TOP" or "BOTTOM"
	return vhalf..hhalf, frame, (vhalf == "TOP" and "BOTTOM" or "TOP")..hhalf
end

local function onEnter(self)
	if self.isMoving then return end
	local obj = self.dataObject
	if obj.OnTooltipShow then
		GameTooltip:SetOwner(self, "ANCHOR_NONE")
		GameTooltip:SetPoint(getAnchors(self))
		obj.OnTooltipShow(GameTooltip)
		GameTooltip:Show()
	elseif obj.OnEnter then
		obj.OnEnter(self)
	end
end

local function onLeave(self)
	local obj = self.dataObject
	GameTooltip:Hide()
	if obj.OnLeave then obj.OnLeave(self) end
end

local function onClick(self, b)
	local obj = self.dataObject
	if obj.OnClick then
		obj.OnClick(self, b)
	end
end

local function onDragStart(self)
	self:LockHighlight()
	self.isMoving = true
	GameTooltip:Hide()
end

local function onDragStop(self)
	self:UnlockHighlight()
	self.isMoving = nil
end

local function updatePosition(button, db)
	local angle = math.rad(db.minimapPos or 220)
	local x, y = math.cos(angle) * lib.radius, math.sin(angle) * lib.radius
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function onUpdate(self)
	if not self.isMoving then return end
	local mx, my = Minimap:GetCenter()
	local px, py = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	px, py = px / scale, py / scale
	local angle = math.deg(math.atan2(py - my, px - mx))
	if self.db then
		self.db.minimapPos = angle
		updatePosition(self, self.db)
	end
end

local function createButton(name, object, db)
	local button = CreateFrame("Button", "LibDBIcon10_"..name, Minimap)
	button:SetFrameStrata("MEDIUM")
	button:SetSize(31, 31)
	button:SetFrameLevel(8)
	button:RegisterForClicks("anyUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture(136477) -- Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight

	local overlay = button:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture(136430) -- Interface\\Minimap\\MiniMap-TrackingBorder
	overlay:SetPoint("TOPLEFT")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetSize(21, 21)
	background:SetTexture(136467) -- Interface\\Minimap\\UI-Minimap-Background
	background:SetPoint("TOPLEFT", 7, -5)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(17, 17)
	icon:SetPoint("TOPLEFT", 7, -6)
	button.icon = icon

	button.dataObject = object
	button.db = db

	button:SetScript("OnEnter", onEnter)
	button:SetScript("OnLeave", onLeave)
	button:SetScript("OnClick", onClick)
	button:SetScript("OnDragStart", onDragStart)
	button:SetScript("OnDragStop", onDragStop)
	button:SetScript("OnUpdate", onUpdate)

	if object.icon then
		icon:SetTexture(object.icon)
	end

	lib.objects[name] = button

	if db and not db.hide then
		updatePosition(button, db)
		button:Show()
	else
		button:Hide()
	end

	lib.callbacks:Fire("LibDBIcon_IconCreated", button, name)

	return button
end

function lib:Register(name, object, db)
	if not object.icon then
		error("LibDBIcon-1.0: Can't register an object without an icon")
	end
	if lib.objects[name] then return end

	db = db or {}
	if db.minimapPos == nil then db.minimapPos = 220 end
	if db.hide == nil then db.hide = false end

	local button = createButton(name, object, db)

	return button
end

function lib:Unregister(name)
	if lib.objects[name] then
		lib.objects[name]:Hide()
		lib.objects[name] = nil
	end
end

function lib:IsRegistered(name)
	return lib.objects[name] and true or false
end

function lib:Refresh(name, db)
	local button = lib.objects[name]
	if button then
		if db then button.db = db end
		if button.db and not button.db.hide then
			updatePosition(button, button.db)
			button:Show()
		else
			button:Hide()
		end
	end
end

function lib:GetMinimapButton(name)
	return lib.objects[name]
end

function lib:Hide(name)
	if lib.objects[name] then
		lib.objects[name]:Hide()
	end
end

function lib:Show(name)
	local button = lib.objects[name]
	if button then
		updatePosition(button, button.db)
		button:Show()
	end
end

function lib:Lock(name)
	local button = lib.objects[name]
	if button then
		button:SetScript("OnDragStart", nil)
		button:SetScript("OnDragStop", nil)
	end
end

function lib:Unlock(name)
	local button = lib.objects[name]
	if button then
		button:SetScript("OnDragStart", onDragStart)
		button:SetScript("OnDragStop", onDragStop)
	end
end

function lib:GetButtonList()
	local list = {}
	for name in next, lib.objects do
		list[#list+1] = name
	end
	return list
end

function lib:SetButtonRadius(radius)
	if type(radius) == "number" then
		lib.radius = radius
		for name, button in next, lib.objects do
			updatePosition(button, button.db)
		end
	end
end

function lib:SetButtonToPosition(name, position)
	local button = lib.objects[name]
	if button and button.db then
		button.db.minimapPos = position
		updatePosition(button, button.db)
	end
end
