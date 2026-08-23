local MAJOR, MINOR = "LibGCDI-Catalog", 1
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

local CatalogManager = {}
CatalogManager.__index = CatalogManager

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

function CatalogManager:GetAllOrdered()
    local settings = self.getSettings()
    if not settings then return {} end
    
    local catalog = self.getCatalog()
    local orderArray = self.getOrderKey() or {}
    
    local enabledOrdered = {}
    local disabledOrdered = {}
    local inOrder = {}
    
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
    
    local result = {}
    for _, id in ipairs(enabledOrdered) do
        table.insert(result, id)
    end
    for _, id in ipairs(disabledOrdered) do
        table.insert(result, id)
    end
    
    return result
end

function CatalogManager:GetEnabledOrdered()
    local settings = self.getSettings()
    if not settings then return {} end
    
    local catalog = self.getCatalog()
    local orderArray = self.getOrderKey() or {}
    
    local ordered = {}
    local inOrder = {}
    
    for _, id in ipairs(orderArray) do
        if catalog[id] and self.isEnabled(id) then
            table.insert(ordered, id)
            inOrder[id] = true
        end
    end
    
    -- pairs() order is undefined; sorting alphabetically below is required or
    -- HUD bar order desyncs from the companion script's pixel layout.
    local unsortedEnabled = {}
    for id, data in pairs(catalog) do
        if not inOrder[id] and self.isEnabled(id) then
            table.insert(unsortedEnabled, { id = id, name = data.name or tostring(id) })
        end
    end
    table.sort(unsortedEnabled, function(a, b) return a.name < b.name end)

    for _, entry in ipairs(unsortedEnabled) do
        table.insert(ordered, entry.id)
    end
    
    return ordered
end

function CatalogManager:SaveOrder(orderedList)
    local settings = self.getSettings()
    if not settings then
        print("|cffff0000LibCatalog:|r SaveOrder failed - no settings")
        return false
    end

    local newOrder = {}
    for i, id in ipairs(orderedList) do
        newOrder[i] = id
    end
    self.setOrderKey(newOrder)
    return true
end

function CatalogManager:CommitOrder(orderedList)
    if not self:SaveOrder(orderedList) then
        return
    end

    if GCDI and GCDI.auto_save_to_profile then
        GCDI.auto_save_to_profile()
    end

    if self.onReorder then
        self.onReorder()
    end
end

function CatalogManager:MoveInOrder(id, direction)
    local ordered = self:GetAllOrdered()
    local currentIndex = nil

    for i, checkId in ipairs(ordered) do
        if checkId == id then
            currentIndex = i
            break
        end
    end

    if not currentIndex then
        print("|cffff0000LibCatalog:|r Item not found in order: " .. tostring(id))
        return
    end

    local newIndex = currentIndex + direction
    if newIndex < 1 or newIndex > #ordered then return end

    ordered[currentIndex], ordered[newIndex] = ordered[newIndex], ordered[currentIndex]

    self:CommitOrder(ordered)
end

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
    self:CommitOrder(ordered)
end

function CatalogManager:MoveToTop(id)
    local ordered = self:GetAllOrdered()
    local currentIndex = nil

    for i, checkId in ipairs(ordered) do
        if checkId == id then
            currentIndex = i
            break
        end
    end

    if not currentIndex or currentIndex == 1 then return end

    table.remove(ordered, currentIndex)
    table.insert(ordered, 1, id)
    self:CommitOrder(ordered)
end

lib.CatalogManager = CatalogManager
