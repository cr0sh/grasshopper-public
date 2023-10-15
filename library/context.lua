---@type string | nil
local current_strategy = nil

local want_key = {}

---@type { [string]: table }
local strategy_locals = {}

local M = {}

---@param x string | nil
function M.set_current_strategy(x)
	current_strategy = x
end

function M.current_strategy()
	return current_strategy
end

---@return table
function M.strategy_local()
	if current_strategy == nil then
		error("not in a strategy", 2)
	end
	if strategy_locals[current_strategy] == nil then
		strategy_locals[current_strategy] = {}
	end
	return strategy_locals[current_strategy]
end

---@param strategy_name string
function M.reset_strategy_local(strategy_name)
	strategy_locals[strategy_name] = nil
end

---@generic T
---@param want fun(ev: Event): T | nil
---@return T
function M.yield(want)
	M.strategy_local()[want_key] = want
	return coroutine.yield()
end

---@param strategy_name string
function M._want(strategy_name)
	return strategy_locals[strategy_name][want_key]
end

---@param strategy_name string
function M._reset_want(strategy_name)
	strategy_locals[strategy_name][want_key] = nil
end

return M
