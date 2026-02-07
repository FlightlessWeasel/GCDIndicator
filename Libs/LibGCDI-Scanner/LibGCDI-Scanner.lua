-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-Scanner - Spell/Item/Buff Scanning for GCDIndicator
-- ═══════════════════════════════════════════════════════════════════════════

local MAJOR, MINOR = "LibGCDI-Scanner", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- Cache frequently used globals
local C_Spell = C_Spell
local C_SpellBook = C_SpellBook
local C_Item = C_Item
local GetActionInfo = GetActionInfo
local GetInventoryItemID = GetInventoryItemID
local pairs = pairs
local wipe = wipe

-- GCD spell ID constant
local GCD_SPELL_ID = 61304

-- ═══════════════════════════════════════════════════════════════════════════
-- SPELLBOOK SCANNING
-- ═══════════════════════════════════════════════════════════════════════════

-- Scan spellbook and populate spell catalog
-- @param catalog: Table to populate with spells
-- @param debugFn: Optional debug function
function lib:ScanSpellbook(catalog, debugFn)
	wipe(catalog)
	
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
								local spellID = C_Spell.GetOverrideSpell(baseSpellID) or baseSpellID
								
								local cdInfo = C_Spell.GetSpellCooldown(spellID)
								if cdInfo and spellID ~= GCD_SPELL_ID then
									local spellName = C_Spell.GetSpellName(spellID)
									local texture = C_Spell.GetSpellTexture(spellID)
									if spellName and texture and not catalog[spellID] then
										catalog[spellID] = {
											name = spellName,
											texture = texture,
											spellID = spellID
										}
									end
								end
							end
						end
					end
				end
			end
		end
	end
	
	if debugFn then
		local count = 0
		for _ in pairs(catalog) do count = count + 1 end
		debugFn("Scanned " .. count .. " spells from spellbook")
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ACTION BAR SCANNING
-- ═══════════════════════════════════════════════════════════════════════════

-- Scan action bars for items
-- @return table: Set of item IDs found on action bars
function lib:ScanActionBarsForItems()
	local actionBarItems = {}
	
	for slot = 1, 120 do
		local actionType, id = GetActionInfo(slot)
		if actionType == "item" and id then
			actionBarItems[id] = true
		end
	end
	
	return actionBarItems
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ITEM SCANNING
-- ═══════════════════════════════════════════════════════════════════════════

-- Add item to catalog
-- @param catalog: Catalog to add to
-- @param itemID: Item ID
-- @param key: Unique key for the item
-- @param slot: Equipment slot (if equipped)
-- @param isEquipped: Whether item is equipped
-- @param defaultName: Fallback name
-- @return boolean: Success
function lib:AddItemToCatalog(catalog, itemID, key, slot, isEquipped, defaultName)
	if not itemID then return false end
	
	local itemName, _, _, _, _, _, _, _, _, texture = C_Item.GetItemInfo(itemID)
	
	if not texture then
		texture = C_Item.GetItemIconByID(itemID)
	end
	
	if not texture then
		texture = "Interface\\Icons\\INV_Misc_QuestionMark"
	end
	
	if not itemName and defaultName then
		itemName = defaultName
	end
	
	catalog[key] = {
		name = itemName or ("Item " .. itemID),
		texture = texture,
		itemID = itemID,
		slot = slot,
		isEquipped = isEquipped,
		itemKey = key
	}
	return true
end

-- Scan items (equipped and action bar)
-- @param catalog: Catalog to populate
-- @param trackedTypes: Table of { key = { slot, name } } for equipment slots
-- @param consumableIDs: Table of { [itemID] = defaultName } for consumables
-- @param debugFn: Optional debug function
function lib:ScanItems(catalog, trackedTypes, consumableIDs, debugFn)
	wipe(catalog)
	
	local actionBarItems = self:ScanActionBarsForItems()
	
	-- Scan equipped items
	for key, info in pairs(trackedTypes) do
		local itemID = GetInventoryItemID("player", info.slot)
		if itemID then
			C_Item.RequestLoadItemDataByID(itemID)
			self:AddItemToCatalog(catalog, itemID, key, info.slot, true, info.name)
		end
	end
	
	-- Scan action bar items (excluding already found equipment)
	for itemID in pairs(actionBarItems) do
		local isTrackedEquipment = false
		for _, data in pairs(catalog) do
			if data.itemID == itemID then
				isTrackedEquipment = true
				break
			end
		end
		
		if not isTrackedEquipment then
			C_Item.RequestLoadItemDataByID(itemID)
			local key = "actionbar_" .. itemID
			self:AddItemToCatalog(catalog, itemID, key, nil, false, nil)
		end
	end
	
	-- Scan consumables
	if consumableIDs then
		for itemID, defaultName in pairs(consumableIDs) do
			local alreadyFound = false
			for _, data in pairs(catalog) do
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
					self:AddItemToCatalog(catalog, itemID, key, nil, false, defaultName)
				end
			end
		end
	end
	
	if debugFn then
		local count = 0
		for _ in pairs(catalog) do count = count + 1 end
		debugFn("Scanned " .. count .. " items")
	end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CDM BUFF SCANNING
-- ═══════════════════════════════════════════════════════════════════════════

-- Scan Blizzard's Cooldown Manager for buff frames
-- @param catalog: Buff catalog to populate
-- @param cdmFrames: Table to store CDM frame references
-- @param settings: Settings table for saving buff settings
-- @param debugFn: Optional debug function
-- @return number: Count of new buffs found
function lib:ScanCDMBuffFrames(catalog, cdmFrames, settings, debugFn)
	local foundThisScan = {}
	
	local viewer = _G["BuffIconCooldownViewer"]
	if not viewer then
		if debugFn then
			debugFn("CDM BuffIconCooldownViewer not found")
		end
		return 0
	end
	
	local foundCount = 0
	local newCount = 0
	
	-- Method 1: Use itemFramePool if available
	if viewer.itemFramePool then
		for frame in viewer.itemFramePool:EnumerateActive() do
			local cooldownID = frame.cooldownID
			if cooldownID then
				foundCount = foundCount + 1
				cdmFrames[cooldownID] = frame
				foundThisScan[cooldownID] = true
				
				local spellName = nil
				local texture = nil
				
				if frame.Icon then
					texture = frame.Icon:GetTexture()
				end
				
				if frame.GetTooltipText then
					spellName = frame:GetTooltipText()
				end
				
				if not catalog[cooldownID] then
					catalog[cooldownID] = {
						name = spellName or ("Buff " .. cooldownID),
						texture = texture or 134400,
						cooldownID = cooldownID,
						cdmFrame = frame,
						hasStacks = false,
					}
					
					if settings then
						if not settings.buffSettings then
							settings.buffSettings = {}
						end
						if not settings.buffSettings[cooldownID] then
							settings.buffSettings[cooldownID] = {
								enabled = true,
								showStacks = true,
								maxStacksDisplay = 5,
							}
							newCount = newCount + 1
						end
					end
					
					if debugFn then
						debugFn("CDM auto-added: " .. (spellName or cooldownID) .. " (cdID:" .. cooldownID .. ")")
					end
				else
					catalog[cooldownID].cdmFrame = frame
				end
			end
		end
	end
	
	-- Method 2: Fallback to GetChildren
	if foundCount == 0 then
		local children = {viewer:GetChildren()}
		for _, frame in ipairs(children) do
			local cooldownID = frame.cooldownID
			if cooldownID then
				foundCount = foundCount + 1
				cdmFrames[cooldownID] = frame
				foundThisScan[cooldownID] = true
				
				if not catalog[cooldownID] then
					local texture = frame.Icon and frame.Icon:GetTexture() or 134400
					catalog[cooldownID] = {
						name = "Buff " .. cooldownID,
						texture = texture,
						cooldownID = cooldownID,
						cdmFrame = frame,
						hasStacks = false,
					}
					
					if settings then
						if not settings.buffSettings then settings.buffSettings = {} end
						if not settings.buffSettings[cooldownID] then
							settings.buffSettings[cooldownID] = {
								enabled = true,
								showStacks = true,
								maxStacksDisplay = 5,
							}
							newCount = newCount + 1
						end
					end
				else
					catalog[cooldownID].cdmFrame = frame
				end
			end
		end
	end
	
	-- Clean up stale frame references
	for buffID, frame in pairs(cdmFrames) do
		if not foundThisScan[buffID] then
			cdmFrames[buffID] = nil
		end
	end
	
	if debugFn and (foundCount > 0 or newCount > 0) then
		debugFn("CDM scan: " .. foundCount .. " frames, " .. newCount .. " new")
	end
	
	return newCount
end

-- Scan buffs from settings and CDM
-- @param catalog: Buff catalog
-- @param cdmFrames: CDM frame references
-- @param settings: Settings table
-- @param debugFn: Optional debug function
function lib:ScanBuffs(catalog, cdmFrames, settings, debugFn)
	-- Rebuild buffCatalog from saved settings
	if settings and settings.buffSettings then
		for key, _ in pairs(settings.buffSettings) do
			local spellID = tonumber(key)
			if spellID and spellID > 0 then
				if not catalog[spellID] then
					local spellName = C_Spell.GetSpellName(spellID)
					local texture = C_Spell.GetSpellTexture(spellID)
					if spellName and texture then
						catalog[spellID] = {
							name = spellName,
							texture = texture,
							spellID = spellID,
							hasStacks = false,
						}
					end
				end
			end
		end
	end
	
	-- Also scan CDM viewer
	self:ScanCDMBuffFrames(catalog, cdmFrames, settings, debugFn)
end

-- Add a buff to catalog manually
-- @param catalog: Buff catalog
-- @param settings: Settings table
-- @param spellID: Spell ID to add
-- @return boolean: Success
function lib:AddBuffToCatalog(catalog, settings, spellID)
	if not spellID or spellID <= 0 then return false end
	if catalog[spellID] then return true end
	
	local spellName = C_Spell.GetSpellName(spellID)
	local texture = C_Spell.GetSpellTexture(spellID)
	
	if spellName and texture then
		catalog[spellID] = {
			name = spellName,
			texture = texture,
			spellID = spellID,
			hasStacks = false,
		}
		
		if settings then
			if not settings.buffSettings then
				settings.buffSettings = {}
			end
			if not settings.buffSettings[spellID] then
				settings.buffSettings[spellID] = {
					enabled = true,
					showStacks = true,
					maxStacksDisplay = 5,
				}
			end
		end
		return true
	end
	return false
end

-- Remove a buff from catalog
-- @param catalog: Buff catalog
-- @param settings: Settings table
-- @param spellID: Spell ID to remove
-- @return boolean: Success
function lib:RemoveBuffFromCatalog(catalog, settings, spellID)
	if catalog[spellID] then
		catalog[spellID] = nil
		if settings and settings.buffSettings then
			settings.buffSettings[spellID] = nil
		end
		return true
	end
	return false
end
