--[[
CallbackHandler-1.0 - Part of AceAddon
License: Public Domain
]]

local MAJOR, MINOR = "CallbackHandler-1.0", 7
local CallbackHandler = LibStub:NewLibrary(MAJOR, MINOR)

if not CallbackHandler then return end

local meta = {__index = function(tbl, key) tbl[key] = {} return tbl[key] end}

local type = type
local pcall = pcall
local pairs = pairs
local assert = assert
local concat = table.concat
local loadstring = loadstring or load
local next = next
local select = select
local type = type
local xpcall = xpcall

local function errorhandler(err)
	return geterrorhandler()(err)
end

local function Dispatch(handlers, ...)
	local index, method = next(handlers)
	if not method then return end
	repeat
		xpcall(method, errorhandler, ...)
		index, method = next(handlers, index)
	until not method
end

local function CreateDispatcher(events, callbacks)
	local dispatcher = function(...)
		Dispatch(events, ...)
	end
	return dispatcher
end

function CallbackHandler:New(target, RegisterName, UnregisterName, UnregisterAllName)
	RegisterName = RegisterName or "RegisterCallback"
	UnregisterName = UnregisterName or "UnregisterCallback"
	UnregisterAllName = UnregisterAllName or "UnregisterAllCallbacks"

	local events = setmetatable({}, meta)
	local registry = { recurse = 0, insertQueue = {} }

	target[RegisterName] = function(self, eventname, method, ...)
		if type(eventname) ~= "string" then
			error("Usage: "..RegisterName.."(eventname, method[, arg]): 'eventname' - string expected.", 2)
		end

		method = method or eventname

		local first = not rawget(events, eventname) or not next(events[eventname])

		if type(method) ~= "string" and type(method) ~= "function" then
			error("Usage: "..RegisterName.."(\"eventname\", \"methodname\"): 'methodname' - string or function expected.", 2)
		end

		local regfunc

		if type(method) == "string" then
			if type(self) ~= "table" then
				error("Usage: "..RegisterName.."(\"eventname\", \"methodname\"): self was not a table?", 2)
			elseif self == target then
				error("Usage: "..RegisterName.."(\"eventname\", \"methodname\"): do not use Library:RegisterCallback(), use your own object.", 2)
			elseif type(self[method]) ~= "function" then
				error("Usage: "..RegisterName.."(\"eventname\", \"methodname\"): 'methodname' - method '"..tostring(method).."' not found on self.", 2)
			end

			if select("#", ...) >= 1 then
				local arg = ...
				regfunc = function(...) self[method](self, arg, ...) end
			else
				regfunc = function(...) self[method](self, ...) end
			end
		else
			if type(self) ~= "table" and type(self) ~= "string" then
				error("Usage: "..RegisterName.."(self, \"eventname\", func): 'self' - table or string expected.", 2)
			end

			if select("#", ...) >= 1 then
				local arg = ...
				regfunc = function(...) method(arg, ...) end
			else
				regfunc = method
			end
		end

		events[eventname][self] = regfunc

		if first and target[RegisterName.."_OnUsed"] then
			target[RegisterName.."_OnUsed"](target, target, eventname)
		end
	end

	target[UnregisterName] = function(self, eventname)
		if not self or self == target then
			error("Usage: "..UnregisterName.."(eventname): bad self", 2)
		end
		if type(eventname) ~= "string" then
			error("Usage: "..UnregisterName.."(eventname): 'eventname' - string expected.", 2)
		end
		if rawget(events, eventname) and events[eventname][self] then
			events[eventname][self] = nil
			if target[UnregisterName.."_OnUnused"] and not next(events[eventname]) then
				target[UnregisterName.."_OnUnused"](target, target, eventname)
			end
		end
	end

	target[UnregisterAllName] = function(self)
		if self == target then
			error("Usage: "..UnregisterAllName.."(): bad self", 2)
		end
		for eventname, callbacks in pairs(events) do
			if callbacks[self] then
				callbacks[self] = nil
				if target[UnregisterName.."_OnUnused"] and not next(callbacks) then
					target[UnregisterName.."_OnUnused"](target, target, eventname)
				end
			end
		end
	end

	target.Fire = function(self, eventname, ...)
		if not eventname then
			error("Usage: Fire(eventname[, ...]): 'eventname' expected.", 2)
		end
		
		local callbacks = rawget(events, eventname)
		if callbacks then
			Dispatch(callbacks, eventname, ...)
		end
	end

	return target
end
