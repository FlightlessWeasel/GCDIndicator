-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-Detector - Secret value detection using StatusBar pattern
-- Uses hidden StatusBars to safely read WoW's secret values (charges, stacks)
-- ═══════════════════════════════════════════════════════════════════════════

local MAJOR, MINOR = "LibGCDI-Detector", 3
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- Pool of detector bars (reuse when possible)
lib.detectorPool = lib.detectorPool or {}
lib.activeDetectors = lib.activeDetectors or {}

-- Y offset for positioning detectors off-screen
local nextYOffset = 500

-- After SetValue(secret), texture GetWidth() can be a secret — comparing it errors.
-- For plain values (e.g. 0 from inactive UI), width > 0 detects fill more reliably than IsShown().
local function DetectorThresholdMet(detector, valueFed)
	local tex = detector:GetStatusBarTexture()
	if not tex or not tex:IsShown() then
		return false
	end
	local useWidth = true
	if valueFed ~= nil and issecretvalue and issecretvalue(valueFed) then
		useWidth = false
	end
	if useWidth then
		local w = tex:GetWidth()
		if w ~= nil and issecretvalue and issecretvalue(w) then
			useWidth = false
		else
			return (w or 0) > 0.5
		end
	end
	return tex:IsShown()
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DETECTOR CREATION
-- ═══════════════════════════════════════════════════════════════════════════

-- Create a single detector bar for a specific threshold
-- threshold: The value at which this detector becomes "active"
-- Returns: detector frame
local function CreateDetectorBar(threshold)
	local detector = CreateFrame("StatusBar", nil, UIParent)
	detector:SetSize(100, 10)
	detector:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -500, nextYOffset)
	nextYOffset = nextYOffset - 15  -- Stagger positions
	
	detector:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	detector:SetStatusBarColor(1, 1, 1, 1)
	-- StatusBar shows texture when value > min
	-- So min=threshold-1, max=threshold means: shows when value >= threshold
	detector:SetMinMaxValues(threshold - 1, threshold)
	detector:SetValue(0)
	detector:SetAlpha(0)  -- Invisible but functional
	detector:Show()
	
	detector.threshold = threshold
	return detector
end

-- ═══════════════════════════════════════════════════════════════════════════
-- PUBLIC API
-- ═══════════════════════════════════════════════════════════════════════════

-- Create an array of detectors for thresholds 1 to maxValue
-- Returns: array of detector frames indexed by threshold
function lib:CreateDetectorArray(maxValue)
	local detectors = {}
	for i = 1, maxValue do
		detectors[i] = CreateDetectorBar(i)
	end
	return detectors
end

-- Feed a secret value to a single detector and check if threshold is met
-- detector: The detector frame
-- secretValue: The secret value from WoW API
-- Returns: true if value >= threshold, false otherwise
function lib:CheckThreshold(detector, secretValue)
	detector:SetValue(secretValue)
	return DetectorThresholdMet(detector, secretValue)
end

-- Feed a secret value to all detectors and count how many thresholds are met
-- detectors: Array of detector frames (from CreateDetectorArray)
-- secretValue: The secret value from WoW API
-- Returns: The highest threshold met (0 if none)
function lib:CheckValue(detectors, secretValue)
	local result = 0
	
	-- Feed value to all detectors first
	for i, detector in ipairs(detectors) do
		detector:SetValue(secretValue)
	end
	
	-- Then check which ones show their texture
	for i, detector in ipairs(detectors) do
		if DetectorThresholdMet(detector, secretValue) then
			result = i
		else
			break
		end
	end
	
	return result
end

-- Update visual indicators based on a secret value
-- detectors: Array of detector frames
-- indicators: Array of indicator tables with .overlay field
-- secretValue: The secret value from WoW API
-- invertOverlay: If true, show overlay when threshold NOT met (default: true for "empty" state)
function lib:UpdateIndicators(detectors, indicators, secretValue, invertOverlay)
	if invertOverlay == nil then invertOverlay = true end
	
	-- Feed value to all detectors
	for i, detector in ipairs(detectors) do
		detector:SetValue(secretValue)
	end
	
	-- Update indicators based on detector state
	for i, detector in ipairs(detectors) do
		local indicator = indicators[i]
		if indicator and indicator.overlay then
			local thresholdMet = DetectorThresholdMet(detector, secretValue)
			if invertOverlay then
				-- Standard: overlay hides when value is sufficient (show underlying "active" color)
				if thresholdMet then
					indicator.overlay:Hide()
				else
					indicator.overlay:Show()
				end
			else
				-- Inverted: overlay shows when value is sufficient
				if thresholdMet then
					indicator.overlay:Show()
				else
					indicator.overlay:Hide()
				end
			end
		end
	end
end

-- Clean up detectors (hide and release)
function lib:ReleaseDetectors(detectors)
	if not detectors then return end
	for i, detector in ipairs(detectors) do
		detector:Hide()
		detector:SetParent(nil)
	end
end
