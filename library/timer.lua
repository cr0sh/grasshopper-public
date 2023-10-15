local gh = require("gh")
local decimal = require("decimal")
local context = require("context")
local M = {}

local timer_state_key = {}

---@enum gh_timer_status
local GH_TIMER_STATUS = {
	stopped = "stopped",
	started = "started",
	paused = "paused",
}

---@class TimerState
---@field start Decimal | nil
---@field wall_start Decimal | nil
---@field status gh_timer_status
---@field elapsed Decimal

---@return TimerState
local function timer_state()
	local t = context.strategy_local()
	if t[timer_state_key] == nil then
		t[timer_state_key] = {
			status = "stopped",
			elapsed = decimal(0),
		}
	end
	return t[timer_state_key]
end

function M.start()
	local now = gh.millis()
	local state = timer_state()
	if state.status ~= "stopped" then
		return nil
	end
	state.status = "started"
	state.start = now
	state.wall_start = now
	state.elapsed = decimal(0)
end

function M.pause()
	local state = timer_state()
	if state.status ~= "started" then
		return
	end
	state.status = "paused"
	__GH_TIMER_STATUS = GH_TIMER_STATUS.paused
	state.elapsed = state.elapsed + gh.millis() - state.start
end

function M.resume()
	local state = timer_state()
	if state.status ~= "paused" then
		return
	end
	state.status = "started"
	state.start = gh.millis()
end

---@return Decimal, Decimal
function M.stop()
	local state = timer_state()
	if state.status == "stopped" then
		error("tried to stop timer which is not running", 2)
	end
	if state.status == "started" then
		M.pause()
	end
	state.status = "stopped"
	__GH_TIMER_STATUS = GH_TIMER_STATUS.stopped
	return state.elapsed, gh.millis() - state.wall_start
end

return M
