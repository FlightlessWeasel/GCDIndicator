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

	it("appends enabled ids absent from the saved order alphabetically by name, matching GetAllOrdered's convention", function()
		local catalog = {
			[1] = { name = "Zulu" },   -- enabled, not in saved order
			[2] = { name = "Alpha" },  -- enabled, not in saved order
			[3] = { name = "Mike" },   -- enabled, saved order
			[4] = { name = "Delta" },  -- enabled, not in saved order
		}
		local manager = make_manager(catalog, { 3 }, { [1] = true, [2] = true, [3] = true, [4] = true })
		-- Saved-order entry (3) first, then the unordered enabled entries
		-- alphabetized by name (Alpha, Delta, Zulu), never raw pairs() order.
		assertDeepEqual(manager:GetEnabledOrdered(), { 3, 2, 4, 1 })
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

describe("LibGCDI-Catalog MoveToTop", function()
	it("moves the item to the start of the full ordered list", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" }, [3] = { name = "C" } }
		local manager, settings = make_manager(catalog, { 1, 2, 3 }, { [1] = true, [2] = true, [3] = true })
		manager:MoveToTop(3)
		assertDeepEqual(settings.order, { 3, 1, 2 })
	end)

	it("is a no-op when the item is already first", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" } }
		local manager, settings = make_manager(catalog, { 1, 2 }, { [1] = true, [2] = true })
		manager:MoveToTop(1)
		assertDeepEqual(settings.order, { 1, 2 })
	end)
end)

-- Builds a manager with an onReorder spy, over a mutable order array, no GCDI
-- global present (matches the test environment - see tests/mocks/wow_api.lua).
local function make_manager_with_reorder_spy(catalog, order, enabledSet)
	local settings = { order = order }
	local reorderCalls = 0
	local manager = lib:NewCatalog({
		name = "test",
		getCatalog = function() return catalog end,
		getSettings = function() return settings end,
		getOrderKey = function() return settings.order end,
		setOrderKey = function(newOrder) settings.order = newOrder end,
		isEnabled = function(id) return enabledSet[id] == true end,
		onReorder = function() reorderCalls = reorderCalls + 1 end,
	})
	return manager, settings, function() return reorderCalls end
end

-- Swaps the global `print` for a call-counting spy for the duration of `fn`,
-- always restoring it afterward (even on error) so a failing assertion below
-- doesn't leave `print` broken for later tests.
local function count_prints(fn)
	local calls = 0
	local realPrint = print
	print = function(...) calls = calls + 1 end
	local ok, err = pcall(fn)
	print = realPrint
	if not ok then error(err, 0) end
	return calls
end

describe("LibGCDI-Catalog reorder side effects", function()
	it("MoveInOrder invokes onReorder after saving", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" } }
		local manager, settings, reorderCalls = make_manager_with_reorder_spy(catalog, { 1, 2 }, { [1] = true, [2] = true })
		manager:MoveInOrder(1, 1)
		assertEqual(reorderCalls(), 1)
	end)

	it("MoveToBottom invokes onReorder after saving", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" } }
		local manager, settings, reorderCalls = make_manager_with_reorder_spy(catalog, { 1, 2 }, { [1] = true, [2] = true })
		manager:MoveToBottom(1)
		assertEqual(reorderCalls(), 1)
	end)

	it("MoveToTop invokes onReorder after saving", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" } }
		local manager, settings, reorderCalls = make_manager_with_reorder_spy(catalog, { 1, 2 }, { [1] = true, [2] = true })
		manager:MoveToTop(2)
		assertEqual(reorderCalls(), 1)
	end)

	it("MoveInOrder does not print debug output on a successful move", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" } }
		local manager = make_manager(catalog, { 1, 2 }, { [1] = true, [2] = true })
		local printCalls = count_prints(function() manager:MoveInOrder(1, 1) end)
		assertEqual(printCalls, 0, "MoveInOrder should not print debug output")
	end)

	it("MoveToBottom does not print debug output on a successful move", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" } }
		local manager = make_manager(catalog, { 1, 2 }, { [1] = true, [2] = true })
		local printCalls = count_prints(function() manager:MoveToBottom(1) end)
		assertEqual(printCalls, 0, "MoveToBottom should not print debug output")
	end)

	it("MoveToTop does not print debug output on a successful move", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" } }
		local manager = make_manager(catalog, { 1, 2 }, { [1] = true, [2] = true })
		local printCalls = count_prints(function() manager:MoveToTop(2) end)
		assertEqual(printCalls, 0, "MoveToTop should not print debug output")
	end)
end)

describe("LibGCDI-Catalog CommitOrder", function()
	it("saves a full ordered list and invokes onReorder, without printing", function()
		local catalog = { [1] = { name = "A" }, [2] = { name = "B" }, [3] = { name = "C" } }
		local manager, settings, reorderCalls = make_manager_with_reorder_spy(catalog, { 1, 2, 3 }, { [1] = true, [2] = true, [3] = true })
		local printCalls = count_prints(function() manager:CommitOrder({ 3, 1, 2 }) end)
		assertDeepEqual(settings.order, { 3, 1, 2 })
		assertEqual(reorderCalls(), 1)
		assertEqual(printCalls, 0)
	end)
end)
