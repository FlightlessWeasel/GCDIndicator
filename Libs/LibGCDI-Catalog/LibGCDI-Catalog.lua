-- ═══════════════════════════════════════════════════════════════════════════
-- LibGCDI-Catalog - Generic catalog ordering for GCDIndicator
-- Handles spells, items, buffs with a single implementation
-- ═══════════════════════════════════════════════════════════════════════════

local MAJOR, MINOR = "LibGCDI-Catalog", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

-- ═══════════════════════════════════════════════════════════════════════════
-- CATALOG MANAGER CLASS
-- ═══════════════════════════════════════════════════════════════════════════

local CatalogManager = {}
CatalogManager.__index = CatalogManager

-- Create a new catalog manager
-- config = {
--   name = "spells",                    -- identifier for debugging
--   getCatalog = function() end,        -- returns the catalog table
--   getSettings = function() end,       -- returns the settings table
--   getOrderKey = function() end,       -- returns the order array from settings (e.g., settings.spellOrder)
--   setOrderKey = function(order) end,  -- sets the order array in settings
--   isEnabled = function(id) end,       -- returns if item is enabled
--   onReorder = function() end,         -- called after reordering (rebuild bars, etc.)
-- }
function lib:NewCatalog(config)
    local manager = setmetatable({}, CatalogManager)
    manager.name = config.name or "unknown"
    manager.getCatalog = config.getCatalog
    manager.getSettings = config.getSettings
    manager.getOrderKey = config.getOrderKey
    manager.setOrderKey = config.setOrderKey
    manager.isEnabled = config.isEnabled
    manager.onReorder = config.onReorder
    return manager
end

-- Get all catalog items ordered (enabled first, then disabled)
-- Returns: ordered array of IDs
function CatalogManager:GetAllOrdered()
    local settings = self.getSettings()
    if not settings then return {} end
    
    local catalog = self.getCatalog()
    local orderArray = self.getOrderKey() or {}
    
    local enabledOrdered = {}
    local disabledOrdered = {}
    local inOrder = {}
    
    -- First: items that are in the saved order
    for _, id in ipairs(orderArray) do
        if catalog[id] then
            inOrder[id] = true
            if self.isEnabled(id) then
                table.insert(enabledOrdered, id)
            else
                table.insert(disabledOrdered, id)
            end
        end
    end
    
    -- Second: items not in saved order (sort alphabetically by name)
    local unsortedEnabled = {}
    local unsortedDisabled = {}
    for id, data in pairs(catalog) do
        if not inOrder[id] then
            local entry = { id = id, name = data.name or tostring(id) }
            if self.isEnabled(id) then
                table.insert(unsortedEnabled, entry)
            else
                table.insert(unsortedDisabled, entry)
            end
        end
    end
    table.sort(unsortedEnabled, function(a, b) return a.name < b.name end)
    table.sort(unsortedDisabled, function(a, b) return a.name < b.name end)
    
    for _, entry in ipairs(unsortedEnabled) do
        table.insert(enabledOrdered, entry.id)
    end
    for _, entry in ipairs(unsortedDisabled) do
        table.insert(disabledOrdered, entry.id)
    end
    
    -- Combine: enabled first, then disabled
    local result = {}
    for _, id in ipairs(enabledOrdered) do
        table.insert(result, id)
    end
    for _, id in ipairs(disabledOrdered) do
        table.insert(result, id)
    end
    
    return result
end

-- Get only enabled items in order
-- Returns: ordered array of enabled IDs
function CatalogManager:GetEnabledOrdered()
    local settings = self.getSettings()
    if not settings then return {} end
    
    local catalog = self.getCatalog()
    local orderArray = self.getOrderKey() or {}
    
    local ordered = {}
    local inOrder = {}
    
    -- First: items in saved order that are enabled
    for _, id in ipairs(orderArray) do
        if catalog[id] and self.isEnabled(id) then
            table.insert(ordered, id)
            inOrder[id] = true
        end
    end
    
    -- Second: items not in order that are enabled
    for id in pairs(catalog) do
        if not inOrder[id] and self.isEnabled(id) then
            table.insert(ordered, id)
        end
    end
    
    return ordered
end

-- Save the current order
function CatalogManager:SaveOrder(orderedList)
    local settings = self.getSettings()
    if not settings then return end
    
    local newOrder = {}
    for i, id in ipairs(orderedList) do
        newOrder[i] = id
    end
    self.setOrderKey(newOrder)
end

-- Move an item up or down in the order
-- direction: -1 for up, 1 for down
function CatalogManager:MoveInOrder(id, direction)
    local ordered = self:GetAllOrdered()
    local currentIndex = nil
    
    for i, checkId in ipairs(ordered) do
        if checkId == id then
            currentIndex = i
            break
        end
    end
    
    if not currentIndex then return end
    
    local newIndex = currentIndex + direction
    if newIndex < 1 or newIndex > #ordered then return end
    
    -- Swap
    ordered[currentIndex], ordered[newIndex] = ordered[newIndex], ordered[currentIndex]
    self:SaveOrder(ordered)
    
    -- Auto-save and rebuild
    if GCDI and GCDI.auto_save_to_profile then
        GCDI.auto_save_to_profile()
    end
    if self.onReorder then
        self.onReorder()
    end
end

-- Move an item to the bottom of the list
function CatalogManager:MoveToBottom(id)
    local ordered = self:GetAllOrdered()
    local currentIndex = nil
    
    for i, checkId in ipairs(ordered) do
        if checkId == id then
            currentIndex = i
            break
        end
    end
    
    if not currentIndex or currentIndex == #ordered then return end
    
    table.remove(ordered, currentIndex)
    table.insert(ordered, id)
    self:SaveOrder(ordered)
    
    -- Auto-save and rebuild
    if GCDI and GCDI.auto_save_to_profile then
        GCDI.auto_save_to_profile()
    end
    if self.onReorder then
        self.onReorder()
    end
end

-- Export the library
lib.CatalogManager = CatalogManager
