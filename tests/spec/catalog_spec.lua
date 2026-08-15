-- Tests for Libs/LibGCDI-Catalog/LibGCDI-Catalog.lua — the ordering logic shared
-- by the spell/item/buff catalogs (GDCIndicator.lua wires GCDI.configs-specific
-- callbacks into this; here we wire plain table fixtures instead).

dofile("Libs/LibGCDI-Catalog/LibGCDI-Catalog.lua")
local lib = LibStub("LibGCDI-Catalog")

-- Builds a manager over a catalog {id -> {name=...}}, a mutable `order` array,
-- and an enabled-set. Mirrors how GCDIndicator.lua wires real callbacks.
local function make_manager(catalog, order, enabledSet)
	local settings = { order = order }
	return lib:NewCatalog({
		name = "test",
		getCatalog = function() return catalog end,
		getSettings = function() return settings end,
		getOrderKey = function() return settings.order end,
		setOrderKey = function(newOrder) settings.order = newOrder end,
		isEnabled = function(id) return enabledSet[id] == true end,
	}), settings
end

describe("LibGCDI-Catalog GetAllOrdered", function()
	it("keeps saved-order items first (enabled then disabled within each), then appends unsorted items alphabetically", function()
		local catalog = {
			[1] = { name = "Alpha" },
			[2] = { name = "Bravo" },   -- disabled, not in saved order
			[3] = { name = "Charlie" },
			[4] = { name = "Delta" },   -- enabled, not in saved order
		}
		local manager = make_manager(catalog, { 3, 1 }, { [1] = true, [3] = true, [4] = true })
		assertDeepEqual(manager:GetAllOrdered(), { 3, 1, 4, 2 })
	end)

	it("returns an empty table when settings is unavailable", function()
		local manager = lib:NewCatalog({
			getCatalog = function() return {} end,
			getSettings = function() return nil end,
		})
		assertDeepEqual(manager:GetAllOrdered(), {})
	end)

	it("drops saved-order entries whose id no longer exists in the catalog", function()
		local catalog = { [1] = { name = "Alpha" } }
		local manager = make_manager(catalog, { 1, 999 }, { [1] = true })
		assertDeepEqual(manager:GetAllOrdered(), { 1 })
	end)
end)

describe("LibGCDI-Catalog GetEnabledOrdered", function()
	it("only includes enabled ids, saved order first", function()
		local catalog = {
			[1] = { name = "Alpha" },
			[2] = { name = "Bravo" },
			[3] = { name = "Charlie" },
		}
		local manager = make_manager(catalog, { 3, 1 }, { [1] = true, [3] = true })
		assertDeepEqual(manager:GetEnabledOrdered(), { 3, 1 })
	end)
end)

describe("LibGCDI-Catalog MoveInOrder", function()
	it("moves an item up (direction -1) by swapping with its predecessor", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" }, [3] = { name = "C" } }
		local manager, settings = make_manager(catalog, { 1, 2, 3 }, { [1] = true, [2] = true, [3] = true })
		manager:MoveInOrder(3, -1)
		assertDeepEqual(settings.order, { 1, 3, 2 })
	end)

	it("moves an item down (direction 1) by swapping with its successor", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" }, [3] = { name = "C" } }
		local manager, settings = make_manager(catalog, { 1, 2, 3 }, { [1] = true, [2] = true, [3] = true })
		manager:MoveInOrder(1, 1)
		assertDeepEqual(settings.order, { 2, 1, 3 })
	end)

	it("is a no-op when moving the first item up or the last item down", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" } }
		local manager, settings = make_manager(catalog, { 1, 2 }, { [1] = true, [2] = true })
		manager:MoveInOrder(1, -1)
		assertDeepEqual(settings.order, { 1, 2 })
		manager:MoveInOrder(2, 1)
		assertDeepEqual(settings.order, { 1, 2 })
	end)
end)

describe("LibGCDI-Catalog MoveToBottom", function()
	it("moves the item to the end of the full ordered list", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" }, [3] = { name = "C" } }
		local manager, settings = make_manager(catalog, { 1, 2, 3 }, { [1] = true, [2] = true, [3] = true })
		manager:MoveToBottom(1)
		assertDeepEqual(settings.order, { 2, 3, 1 })
	end)

	it("is a no-op when the item is already last", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" } }
		local manager, settings = make_manager(catalog, { 1, 2 }, { [1] = true, [2] = true })
		manager:MoveToBottom(2)
		assertDeepEqual(settings.order, { 1, 2 })
	end)
end)
