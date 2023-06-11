local util = require("util")
local M = {}

local routes = {}
local recent = {}

---@alias Identfier integer
---@type Identfier
local next_identifier = 1

---Registers the parse callback and returns an 'extractor' function which returns the parsed value.
---@generic T
---@alias Extractor<T> fun(tbl: table): T
---@param req Request
---@param callback fun(payload: string): T
---@return Extractor<T>
function M.register(req, callback)
	if routes[req.url] ~= nil then
		return routes[req.url][1]
	end
	local ident = next_identifier
	local extractor = function(tbl)
		return tbl[ident]
	end

	routes[req.url] = { extractor, callback, ident }
	next_identifier = next_identifier + 1
	return extractor
end

---A `gh._next()` wrapper. Returns a table to be extracted by 'extractor's returned by `register`.
---@return table | nil
---@return Extractor<any> | nil
---@return any
function M._next()
	local payload
	for p in gh._next do
		if routes[p.url] == nil then
			gh.warn("url not registered: " .. p.url)
		else
			payload = p
			local extractor, callback, identifier = unpack(routes[payload.url])
			local success, candidate = pcall(callback, payload)
			if success then
				if recent[identifier] ~= candidate then
					recent[identifier] = candidate
					return recent, extractor, identifier
				end
			else
				gh.error("router callback error: " .. util.dump(candidate))
			end
		end
	end
	return nil
end

---Main event loop.
---@param callback fun(tbl: {[Identfier]: any}, id: any): nil
function M.on(callback)
	for x, extractor in M._next do
		local fail = false
		for _, p in pairs(routes) do
			if x[p[3]] == nil then
				fail = true
				break
			end
		end

		if not fail then
			local success, err = pcall(callback, x, extractor)
			if not success then
				gh.error("router callback failed: " .. util.dump(err))
			end
		end
	end
end

return M
