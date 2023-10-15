local gh = require("gh")
local router = require("router")
local context = require("context")
local decimal = require("decimal")
local util = require("util")

---@class Strategy
---@field coro thread
---@field error any

local M = {}

---@type { [string]: Strategy }
local strategies = {}

---@enum Interrupt
M.interrupts = {
	restart = "restart",
	terminate = "terminate",
	network = "network",
}

---@param strategy_name string
---@param func function
local function in_strategy_ctx(strategy_name, func, ...)
	context.set_current_strategy(strategy_name)
	gh.set_script_name(strategy_name)
	local packed = table.pack(pcall(func, ...))
	context.set_current_strategy(nil)
	gh.set_script_name("")
	table.remove(packed, 1)
	return table.unpack(packed)
end

local function resume_strategy(strategy_name, ...)
	if strategies[strategy_name] == nil then
		error("unknown strategy " .. strategy_name, 2)
	end
	local success, ret = in_strategy_ctx(strategy_name, coroutine.resume, strategies[strategy_name].coro, ...)
	if not success then
		in_strategy_ctx(strategy_name, util.execute_atexit)
		context.reset_strategy_local(strategy_name)
		gh.error("strategy " .. strategy_name .. " ended with an error: " .. tostring(ret))
		strategies[strategy_name].error = ret
	elseif coroutine.status(strategies[strategy_name].coro) == "dead" then
		in_strategy_ctx(strategy_name, util.execute_atexit)
		context.reset_strategy_local(strategy_name)
		gh.info("strategy " .. strategy_name .. " ended without an error")
	end
	return ret
end

local function load_strategy(strategy_name)
	if strategies[strategy_name] ~= nil then
		error("duplicate strategy " .. strategy_name)
	end
	gh.reset_metrics(strategy_name)
	strategies[strategy_name] = {
		coro = coroutine.create(function()
			local fun = require(strategy_name)
			fun()
		end),
	}
	local success, ret = pcall(resume_strategy, strategy_name)
	if not success then
		error("strategy failed on startup: " .. tostring(ret))
	end
end

function M.event_loop()
	strategies = {} -- for the cast of 2nd or more run due to restarts

	for _, strategy_name in ipairs(gh.list_strategies()) do
		load_strategy(strategy_name)
	end

	local error_kind

	for ev in gh.next_event do
		local success, ret = pcall(function()
			if ev.kind == "signal" then
				if ev.response_payload.terminate then
					error_kind = M.interrupts.terminate
				elseif ev.response_payload.restart then
					error_kind = M.interrupts.restart
				else
					error("unknown signal payload")
				end
				error(error_kind)
			elseif ev.kind == "fetcher" then
				if ev.response_payload.error then
					gh.error(ev.response_payload.content)
				else
					for strategy_name in pairs(strategies) do
						in_strategy_ctx(strategy_name, router.deliver_fetcher_payload, ev.response_payload)
					end
				end
			elseif ev.kind == "send_response" then
				-- nothing to do
			else
				gh.warn(string.format("unknown event kind %s", ev.kind))
			end

			for strategy_name, strategy in pairs(strategies) do
				if coroutine.status(strategy.coro) == "suspended" then
					local want = context._want(strategy_name)
					if want ~= nil then
						local result = table.pack(want(ev))
						if result[1] ~= nil then
							context._reset_want(strategy_name)
							resume_strategy(strategy_name, table.unpack(result))
						end
					else
						error("coroutine wants nothing")
					end
				else
					gh.debug(
						string.format(
							"%s %s: %s",
							strategy_name,
							coroutine.status(strategy.coro),
							debug.traceback(strategy.coro)
						)
					)
				end
			end
		end)

		if not success then
			if error_kind == M.interrupts.terminate or error_kind == M.interrupts.restart then
				return error_kind
			elseif ret == M.interrupts.network then
				gh.error("network error occurred while invoking grasshopper send()")
			else
				gh.error(string.format("unhandled executor error: %s", ret))
				return
			end
		end

		for strategy_name, strategy in pairs(strategies) do
			if coroutine.status(strategy.coro) == "dead" then
				strategies[strategy_name] = nil
				context.reset_strategy_local(strategy_name)
				if strategy.error ~= nil then
					gh.error(tostring(strategy.error))
					gh.debug("reloading strategy " .. strategy_name)
					load_strategy(strategy_name)
				end
			end
		end
	end
end

function M.clear_strategies()
	local atexit_coros = {}
	local clear_start = gh.millis()
	for strategy_name in pairs(strategies) do
		atexit_coros[strategy_name] = coroutine.create(function()
			in_strategy_ctx(strategy_name, util.execute_atexit)
		end)
		coroutine.resume(atexit_coros[strategy_name])
	end
	for ev in gh.next_event do
		if gh.millis() - clear_start > decimal(5000) then
			gh.error("timeout of 5 seconds occurred, exiting atexit loop")
			break
		end
		local should_break = true
		if ev.kind == "send_response" then
			for strategy_name, atexit_coro in pairs(atexit_coros) do
				if coroutine.status(atexit_coro) == "suspended" then
					local want = context._want(strategy_name)
					if want ~= nil then
						local result = table.pack(want(ev))
						if result[1] ~= nil then
							context._reset_want(strategy_name)
							in_strategy_ctx(strategy_name, coroutine.resume, atexit_coro, table.unpack(result))
						end
					end
				else
				end
			end
		end
		for strategy_name, atexit_coro in pairs(atexit_coros) do
			if coroutine.status(atexit_coro) == "dead" then
				gh.debug("strategy " .. strategy_name .. " cleared successfully")
				atexit_coros[strategy_name] = nil
			else
				should_break = false
			end
		end
		if should_break then
			break
		end
	end
end

return M
