local common = require("common")
local json = require("json")
local router = require("router")
local util = require("util")

---@class Bybit: Exchange
local M = {}

local function extract_result(payload)
	local success, obj = pcall(json.decode, payload.content)
	if not success then
		gh.debug("Failed payload: " .. payload.content)
		error("JSON decode failed: " .. tostring(obj))
	end
	if obj.retCode == 0 then
		return obj.result
	end
	error({ code = obj.retCode, message = util.dump(obj) })
end

function M.subscribe_orderbook(market, params)
	local base, quote, market_type = common.parse_market(market)
	local endpoint = "/v5/market/orderbook"
	local category
	if market_type == "spot" then
		category = "spot"
	elseif market_type == "swap" then
		category = "linear"
	else
		error("unsupported market type " .. market_type)
	end
	local symbol = base .. quote
	local limit = 25

	local function parse_orderbook(payload)
		local result = extract_result(payload)

		local orderbook = { bids = {}, asks = {} }
		for _, v in ipairs(result.b) do
			table.insert(orderbook.bids, { price = decimal(v[1]), quantity = decimal(v[2]) })
		end
		for _, v in ipairs(result.a) do
			table.insert(orderbook.asks, { price = decimal(v[1]), quantity = decimal(v[2]) })
		end

		return common.wrap_orderbook(orderbook)
	end

	local req = M.build_request(
		endpoint,
		"get",
		util.apply_default(params, {
			category = category,
			symbol = symbol,
			limit = limit,
		})
	)

	gh._subscribe(req, 200)
	return router.register(req, parse_orderbook)
end

function M.subscribe_balance(market_type, params)
	local endpoint = "/v5/account/wallet-balance"
	local _ = market_type

	local default_params = {}

	default_params.accountType = "UNIFIED"

	local function parse_balance(payload)
		local result = extract_result(payload)

		local balance = {}
		for _, v in ipairs(result.list[1].coin) do
			local total = decimal(v.equity)
			local free = decimal(v.availableToWithdraw)
			local locked = total - free
			balance[v.coin] = { free = free, locked = locked, total = total }
		end

		return common.wrap_balance(balance)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, default_params), true)

	gh._subscribe(req, 200)
	return router.register(req, parse_balance)
end

function M.subscribe_position(market_type, params)
	local endpoint = "/v5/position/list"

	local default_params = {
		settleCoin = "USDT",
	}

	if market_type == nil or market_type == "swap" then
		default_params.category = "linear"
	else
		error("unsupported market type " .. market_type)
	end

	local function parse_position(payload)
		local result = extract_result(payload)

		local position = {}
		for _, v in ipairs(result.list) do
			if v.side == "Buy" then
				position[v.symbol] = decimal(v.size)
			else
				position[v.symbol] = -decimal(v.size)
			end
		end

		return common.wrap_position(position)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, default_params), true)

	gh._subscribe(req, 200)
	return router.register(req, parse_position)
end

function M.subscribe_orders(market, params)
	local endpoint = "/v5/order/realtime"
	local base, quote, market_type = common.parse_market(market)

	local default_params = {}

	if market_type == "spot" then
		default_params.category = "spot"
	elseif market_type == "swap" then
		default_params.category = "linear"
	else
		error("unsupported market type " .. market_type)
	end

	default_params.symbol = base .. quote

	local function parse_orders(payload)
		local result = extract_result(payload)

		local orders = {}
		for _, v in ipairs(result.list) do
			if v.side == "Buy" then
				table.insert(orders, { price = decimal(v.price), amount = decimal(v.qty), id = v.orderId })
			else
				table.insert(orders, { price = decimal(v.price), amount = -decimal(v.qty), id = v.orderId })
			end
		end

		return common.wrap_orders(orders)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, default_params), true)

	gh._subscribe(req, 200)
	return router.register(req, parse_orders)
end

function M.limit_order(market, price, amount, params)
	local endpoint = "/v5/order/create"
	local base, quote, market_type = common.parse_market(market)
	local default_params = {
		orderType = "Limit",
		price = tostring(price),
		qty = tostring(amount:abs()),
	}
	if market_type == "spot" then
		default_params.category = "spot"
	elseif market_type == "swap" then
		default_params.category = "linear"
	else
		error("unknown market type " .. market_type)
	end

	default_params.symbol = base .. quote
	if amount > decimal(0) then
		default_params.side = "Buy"
	else
		default_params.side = "Sell"
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { price = price, amount = amount, id = data.orderId }
end

function M.market_order(market, amount, params)
	local endpoint = "/v5/order/create"
	local base, quote, market_type = common.parse_market(market)
	local default_params = {
		symbol = base .. quote,
		orderType = "Market",
		qty = tostring(amount:abs()),
	}
	if market_type == "spot" then
		default_params.category = "spot"
	elseif market_type == "swap" then
		default_params.category = "linear"
	else
		error("unknown market type " .. market_type)
	end

	if amount > decimal(0) then
		default_params.side = "Buy"
	else
		default_params.side = "Sell"
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { amount = amount, id = data.orderId }
end

function M.cancel_order(market, order, params)
	local endpoint = "/v5/order/cancel"
	local base, quote, market_type = common.parse_market(market)
	local default_params = {
		symbol = base .. quote,
		orderId = order.id,
	}
	if market_type == "spot" then
		default_params.category = "spot"
	elseif market_type == "swap" then
		default_params.category = "linear"
	else
		error("unknown market type " .. market_type)
	end
	M.send(endpoint, "post", util.apply_default(params, default_params), true)
end

function M.build_request(endpoint, method, params, private)
	local url = "https://api.bybit.com" .. endpoint
	local tbl
	if method == "get" then
		local urlencoded = util.build_urlencoded(params)
		if urlencoded ~= "" then
			url = url .. "?" .. urlencoded
		end
		tbl = { url = url, method = method }
	elseif method == "post" then
		tbl = { url = url, method = method, body = json.encode(params) }
	else
		error("invalid method " .. method)
	end

	if private then
		tbl.sign = "bybit"
	end
	return tbl
end

function M.send(endpoint, method, params, private)
	return extract_result(gh._send(M.build_request(endpoint, method, params, private)))
end

return M
