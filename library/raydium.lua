local common = require("common")
local router = require("router")
local util = require("util")
local decimal = require("decimal")
local gh = require("gh")
local json = require("json")

---@class Raydium: Exchange
local M = {
	defaults = {},
}

function M.subscribe_balance(market_type, params)
	local _ = market_type
	params = params or {}
	local token0 = params["token0"] or M.defaults["token0"]
	local token1 = params["token1"] or M.defaults["token1"]
	local position = params["position"] or M.defaults["position"]
	if token0 == nil then
		error("token0 required")
	end
	if token1 == nil then
		error("token1 required")
	end
	if position == nil then
		error("position required")
	end
	local function parse_balance(payload)
		local success, obj = pcall(json.decode, payload.content)
		if not success then
			gh.debug("Failed payload: " .. payload.content)
			error("JSON decode failed: " .. tostring(obj))
		end
		local amount0 = decimal(obj[1])
		local amount1 = decimal(obj[2])
		---@type Balance
		local balances = {
			[token0] = {
				free = amount0,
				locked = decimal(0),
				total = amount0,
			},
			[token1] = {
				free = amount1,
				locked = decimal(0),
				total = amount1,
			},
		}
		if balances[token0].total == decimal(0) or balances[token1].total == decimal(0) then
			local now = gh.millis()
			if M.last_oor == nil then
				M.last_oor = now
			elseif now - M.last_oor > decimal(7200) * decimal(1000) then
				-- gh.notice("Raydium position out of range")
				M.last_oor = nil
			end
		else
			M.last_oor = nil
		end
		return common.wrap_balance(balances)
	end

	local req = M.build_request("/" .. position, "get", {}, false)

	gh._subscribe(req, 800)
	return router.register(req, parse_balance)
end

function M.build_request(endpoint, method, params, private)
	local url = "https://raydium-position.local" .. endpoint
	local urlencoded = util.build_urlencoded(params)
	local tbl
	if method == "get" then
		url = url .. "?" .. urlencoded
		tbl = { url = url, method = method, sign = false, primary_only = false }
	elseif method == "post" then
		tbl = { url = url, method = method, body = urlencoded, sign = private, primary_only = false }
	else
		error("invalid method " .. method)
	end
	return tbl
end

return M
