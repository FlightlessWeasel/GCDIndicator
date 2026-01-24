local configs = {
	size = 10,
	xpoint = 0,
	ypoint = -219,
};

local main_frame = CreateFrame("FRAME", nil, UIParent)

local function on_update()
	local durationinfo = C_Spell.GetSpellCooldownDuration(61304);
	-- Use SetTimerDuration like asGCDBar (this works but fills slowly)
	main_frame.gcdbar:SetTimerDuration(durationinfo, Enum.StatusBarInterpolation.None);
end

local function on_event(self, event)
	if event == "PLAYER_REGEN_DISABLED" then
		-- Entered combat - turn red
		main_frame.combatbar:SetStatusBarColor(1, 0, 0);
	elseif event == "PLAYER_REGEN_ENABLED" then
		-- Left combat - turn black
		main_frame.combatbar:SetStatusBarColor(0, 0, 0);
	elseif event == "PLAYER_ENTERING_WORLD" then
		if UnitAffectingCombat("player") then
			main_frame.combatbar:SetStatusBarColor(1, 0, 0);
		else
			main_frame.combatbar:SetStatusBarColor(0, 0, 0);
		end
	end
end

local function init()
	main_frame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 0)
	main_frame:SetWidth(0)
	main_frame:SetHeight(0)
	main_frame:Show();

	-- GCD indicator container (clips the super-wide bar)
	main_frame.gcdcontainer = CreateFrame("Frame", nil, main_frame)
	main_frame.gcdcontainer:SetSize(configs.size, configs.size)
	main_frame.gcdcontainer:SetPoint("CENTER", UIParent, "CENTER", configs.xpoint - (configs.size / 2), configs.ypoint)
	main_frame.gcdcontainer:SetClipsChildren(true)
	
	-- Background
	main_frame.gcdcontainer.bg = main_frame.gcdcontainer:CreateTexture(nil, "BACKGROUND")
	main_frame.gcdcontainer.bg:SetAllPoints()
	main_frame.gcdcontainer.bg:SetColorTexture(0, 0, 0, 1);

	-- Super wide bar (10000px) - even 0.1% fill covers the 10px visible area
	main_frame.gcdbar = CreateFrame("StatusBar", nil, main_frame.gcdcontainer)
	main_frame.gcdbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	main_frame.gcdbar:GetStatusBarTexture():SetHorizTile(false)
	main_frame.gcdbar:SetMinMaxValues(0, 100)
	main_frame.gcdbar:SetValue(0)
	main_frame.gcdbar:SetHeight(configs.size)
	main_frame.gcdbar:SetWidth(10000)  -- Super wide!
	main_frame.gcdbar:SetStatusBarColor(1, 1, 1);
	main_frame.gcdbar:SetPoint("LEFT", main_frame.gcdcontainer, "LEFT", 0, 0)
	main_frame.gcdbar:Show();

	-- Combat indicator (right square)
	main_frame.combatbar = CreateFrame("StatusBar", nil, main_frame)
	main_frame.combatbar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	main_frame.combatbar:GetStatusBarTexture():SetHorizTile(false)
	main_frame.combatbar:SetMinMaxValues(0, 100)
	main_frame.combatbar:SetValue(100)
	main_frame.combatbar:SetHeight(configs.size)
	main_frame.combatbar:SetWidth(configs.size)
	main_frame.combatbar:SetStatusBarColor(0, 0, 0);

	main_frame.combatbar.bg = main_frame.combatbar:CreateTexture(nil, "BACKGROUND")
	main_frame.combatbar.bg:SetPoint("TOPLEFT", main_frame.combatbar, "TOPLEFT", -1, 1)
	main_frame.combatbar.bg:SetPoint("BOTTOMRIGHT", main_frame.combatbar, "BOTTOMRIGHT", 1, -1)
	main_frame.combatbar.bg:SetColorTexture(0, 0, 0, 1);

	main_frame.combatbar:SetPoint("LEFT", main_frame.gcdcontainer, "RIGHT", 0, 0)
	main_frame.combatbar:Show();

	if GCDIndicator_Positions == nil then
		GCDIndicator_Positions = {};
	end

	local libGCDI = LibStub:GetLibrary("LibGCDI", true);

	if libGCDI then
		libGCDI.load_position(main_frame.gcdcontainer, "GCDIndicator", GCDIndicator_Positions);
	end

	main_frame:RegisterEvent("PLAYER_REGEN_DISABLED");
	main_frame:RegisterEvent("PLAYER_REGEN_ENABLED");
	main_frame:RegisterEvent("PLAYER_ENTERING_WORLD");
	main_frame:SetScript("OnEvent", on_event);
	C_Timer.NewTicker(0.1, on_update);

	main_frame:SetAlpha(1);

	-- Set initial combat state
	if UnitAffectingCombat("player") then
		main_frame.combatbar:SetStatusBarColor(1, 0, 0);
	end
end

C_Timer.After(0.5, init);
