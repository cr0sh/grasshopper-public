local util = require("util")
local timer = require("timer")
local decimal = require("decimal")
local gh = require("gh")
local context = require("context")

local M = {}

local routes_key = {}
local recent_payloads_key = {}
local recent_callback_results_key = {}
local next_identifier_key = {}
local exit_now = {}

local function get_strategy_locals()
	local r = context.strategy_local()[routes_key]
	local p = context.strategy_local()[recent_payloads_key]
	local c = context.strategy_local()[recent_callback_results_key]
	local n = context.strategy_local()[next_identifier_key]
	if r == nil then
		context.strategy_local()[routes_key] = {}
		r = context.strategy_local()[routes_key]
	end
	if p == nil then
		context.strategy_local()[recent_payloads_key] = {}
		p = context.strategy_local()[recent_payloads_key]
	end
	if c == nil then
		context.strategy_local()[recent_callback_results_key] = {}
		c = context.strategy_local()[recent_callback_results_key]
	end
	if n == nil then
		context.strategy_local()[next_identifier_key] = 1
		n = context.strategy_local()[next_identifier_key]
	end
	return r, p, c, n
end

---Registers the parse callback and returns an 'extractor' function which returns the parsed value.
---@generic T
---@alias Extractor<T> fun(tbl: table): T
---@param req Request
---@param callback fun(payload: ResponsePayload): T
---@return Extractor<T>
function M.register(req, callback)
	local routes, _, _, next_identifier = get_strategy_locals()
	-- TODO: handle case of same-req, different-callback case
	if routes[req.url] ~= nil then
		return routes[req.url][1]
	end
	local ident = next_identifier
	local extractor = function(tbl)
		return tbl[ident]
	end

	routes[req.url] = { extractor, callback, ident }
	context.strategy_local()[next_identifier_key] = ident + 1
	return extractor
end

---@return table | nil
---@return Extractor<any> | nil
---@return any
local function next()
	local routes, recent_payloads, recent_callback_results = get_strategy_locals()
	while true do
		---@type ResponsePayload
		local payload
		for url, p in pairs(recent_payloads) do
			assert(url == p.url, string.format("%s ~= %s", url, p.url))
			payload = p
			break
		end
		if payload == nil then
			payload = context.yield(function(ev)
				if ev.kind == "fetcher" then
					if routes[ev.response_payload.url] ~= nil then
						return ev.response_payload
					end
				end
			end)
		end
		recent_payloads[payload.url] = nil

		if routes[payload.url] == nil then
			gh.warn("spurious event delivery from " .. payload.url)
		else
			local extractor, callback, identifier = unpack(routes[payload.url])
			local success, candidate = xpcall(callback, function(e)
				gh.debug(debug.traceback())
				return e
			end, payload)
			if success then
				if recent_callback_results[identifier] ~= candidate then
					recent_callback_results[identifier] = candidate
					return recent_callback_results, extractor, identifier
				end
			else
				gh.error("fetch callback failure: " .. util.dump(candidate))
			end
		end
	end
end

---@param payload ResponsePayload
function M.deliver_fetcher_payload(payload)
	local routes, recent_payloads = get_strategy_locals()
	if routes[payload.url] ~= nil then
		recent_payloads[payload.url] = payload
	end
end

---Main event loop.
---@param callback fun(tbl: any[], id: any): nil
function M.on(callback)
	local all_ok = false
	local routes = get_strategy_locals()

	local current_strategy = context.current_strategy()
	if current_strategy == nil then
		error("called outside the strategy context", 2)
	end

	for x, extractor in next do
		if not all_ok then
			all_ok = true
			for _, p in pairs(routes) do
				if x[p[3]] == nil then
					all_ok = false
					break
				end
			end
		end

		if all_ok then
			timer.start()
			local success, err = xpcall(callback, function(e)
				gh.debug(debug.traceback())
				return e
			end, x, extractor)
			local elapsed, wall_elapsed = timer.stop()
			if success then
				if elapsed > decimal(50) then
					gh.warn(string.format("router event processor took too long: elapsed %sms", elapsed))
				end
				if wall_elapsed > decimal(1500) then
					gh.warn(string.format("router event processor took too long: wall-elapsed %sms", wall_elapsed))
				end
				gh.report_timings(current_strategy, elapsed, wall_elapsed)
			else
				if err == exit_now then
					gh.info("router exited")
					break
				end
				gh.error("router callback failed: " .. util.dump(err))
			end
		end
	end
end

---Exits the current event loop.
function M.exit()
	error(exit_now)
end

return M
