local common = require("common")
local json = require("json")
local router = require("router")
local util = require("util")

local function extract_data(payload)
	local success, obj = pcall(json.decode, payload.content)
	if not success then
		gh.debug("Failed payload: " .. payload.content)
		error("JSON decode failed: " .. tostring(obj))
	end
	if obj.code ~= nil then
		error({ code = obj.code, message = obj.msg })
	end
	return obj
end

---@class Binance: Exchange
local M = {}

function M.subscribe_orderbook(market, params)
	local base, quote, market_type = common.parse_market(market)
	local endpoint
	if market_type == "spot" then
		endpoint = "/api/v3/depth"
	elseif market_type == "swap" then
		endpoint = "/fapi/v1/depth"
	else
		error("unsupported market type " .. market_type)
	end
	local symbol = base .. quote

	local function parse_orderbook(payload)
		local data = extract_data(payload)

		local orderbook = { bids = {}, asks = {} }
		for _, v in ipairs(data.bids) do
			table.insert(orderbook.bids, { price = decimal(v[1]), quantity = decimal(v[2]) })
		end
		for _, v in ipairs(data.asks) do
			table.insert(orderbook.asks, { price = decimal(v[1]), quantity = decimal(v[2]) })
		end

		return common.wrap_orderbook(orderbook)
	end

	local req = M.build_request(
		endpoint,
		"get",
		util.apply_default(params, {
			symbol = symbol,
			limit = 50,
		})
	)

	gh._subscribe(req, 640)
	return router.register(req, parse_orderbook)
end

function M.subscribe_balance(market_type, params)
	local endpoint
	if market_type == "spot" then
		endpoint = "/api/v3/account"
	elseif market_type == "swap" then
		endpoint = "/fapi/v2/balance"
	else
		error("unsupported account type ")
	end

	local function parse_balance(payload)
		local data = extract_data(payload)
		local balance = {}
		if market_type == "spot" then
			for _, v in ipairs(data.balances) do
				local free = decimal(v.free)
				local locked = decimal(v.locked)
				balance[v.asset] = { free = free, locked = locked, total = free + locked }
			end
		else
			for _, v in ipairs(data) do
				local free = decimal(v.maxWithdrawAmount)
				local total = decimal(v.availableBalance)
				balance[v.asset] = { free = free, locked = total - free, total = total }
			end
		end
		return common.wrap_balance(balance)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, {}), true)
	gh._subscribe(req, 1500)
	return router.register(req, parse_balance)
end

function M.subscribe_orders(market, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/api/v3/allOrders"
	elseif market_type == "swap" then
		endpoint = "/fapi/v1/orders"
	else
		error("unsupported account type ")
	end

	local function parse_orders(payload)
		local data = extract_data(payload)
		local orders = {}
		for _, v in ipairs(data) do
			if v.status == "NEW" then
				if v.side == "BUY" then
					table.insert(
						orders,
						{ id = tostring(v.orderId), price = decimal(v.price), amount = decimal(v.origQty) }
					)
				else
					table.insert(
						orders,
						{ id = tostring(v.orderId), price = decimal(v.price), amount = -decimal(v.origQty) }
					)
				end
			end
		end
		return common.wrap_orders(orders)
	end

	local req = M.build_request(
		endpoint,
		"get",
		util.apply_default(params, {
			symbol = base .. quote,
		}),
		true
	)
	gh._subscribe(req, 1000)
	return router.register(req, parse_orders)
end

function M.subscribe_position(market_type, params)
	local endpoint
	if market_type == "spot" then
		error("position is not available in spot accounts")
	elseif market_type == "swap" then
		endpoint = "/fapi/v2/positionRisk"
	else
		error("unsupported market type " .. market_type)
	end

	local function parse_position(payload)
		local data = extract_data(payload)
		local position = {}
		for _, v in ipairs(data) do
			if v.positionSide ~= "BOTH" then
				error("Binance hedge mode is not supported")
			end
			position[v.symbol] = decimal(v.positionAmt)
		end
		return common.wrap_position(position)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, {}), true)
	gh._subscribe(req, 500)
	return router.register(req, parse_position)
end

---@return Order
function M.limit_order(market, price, amount, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/api/v3/order"
	elseif market_type == "swap" then
		endpoint = "/fapi/v1/order"
	else
		error("unsupported market type" .. market_type)
	end
	local default_params = {
		symbol = base .. quote,
		type = "LIMIT",
		quantity = amount:abs(),
		price = price,
		timeInForce = "GTC",
	}
	if amount > decimal(0) then
		default_params.side = "BUY"
	else
		default_params.side = "SELL"
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { price = price, amount = amount, id = data.orderId }
end

---@return Order
function M.market_order(market, amount, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/api/v3/order"
	elseif market_type == "swap" then
		endpoint = "/fapi/v1/order"
	else
		error("unsupported market type" .. market_type)
	end
	local default_params = {
		symbol = base .. quote,
		type = "MARKET",
		quantity = amount:abs(),
	}
	if amount > decimal(0) then
		default_params.side = "BUY"
	else
		default_params.side = "SELL"
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return data.orderId
end

function M.cancel_order(market, order, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/api/v3/order"
	elseif market_type == "swap" then
		endpoint = "/fapi/v1/order"
	else
		error("unsupported market type" .. market_type)
	end
	local default_params = {
		symbol = base .. quote,
		orderId = order.id,
	}
	local _ = M.send(endpoint, "delete", util.apply_default(params, default_params), true)
end

function M.build_request(endpoint, method, params, private)
	local api = string.match(endpoint, "([^/]+)")
	local url
	if api == "api" or api == "sapi" then
		url = "https://api.binance.com" .. endpoint
	elseif api == "fapi" then
		url = "https://fapi.binance.com" .. endpoint
	else
		error("unknown endpoint type " .. api)
	end
	local tbl
	local urlencoded = util.build_urlencoded(params)
	if urlencoded ~= "" then
		url = url .. "?" .. urlencoded
	end
	tbl = { url = url, method = method }

	if private then
		tbl.sign = "binance"
	end
	return tbl
end

function M.send(endpoint, method, params, private)
	return extract_data(gh._send(M.build_request(endpoint, method, params, private)))
end

return M
