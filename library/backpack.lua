local common = require("common")
local router = require("router")
local util = require("util")
local decimal = require("decimal")
local gh = require("gh")
local json = require("json")
local send = require("send")

local function extract_data(payload)
	local success, obj = pcall(json.decode, payload.content)
	if not success then
		gh.debug("Failed payload: " .. payload.content)
		error("JSON decode failed: " .. tostring(obj))
	end
	return obj
end

---@class Backpack: Exchange
local M = {}

function M.subscribe_orderbook(market, params)
	local base, quote, market_type = common.parse_market(market)
	local endpoint, symbol
	if market_type == "spot" then
		endpoint = "/api/v1/depth"
		symbol = base .. "_" .. quote
	elseif market_type == "swap" then
		endpoint = "/api/v1/depth"
		symbol = base .. "_" .. quote .. "_PERP"
	else
		error("unsupported market type " .. market_type)
	end

	local function parse_orderbook(payload)
		local data = extract_data(payload)

		local orderbook = { bids = {}, asks = {} }
		for _, v in ipairs(data.bids) do
			table.insert(orderbook.bids, { price = decimal(v[1]), quantity = decimal(v[2]) })
		end
		for _, v in ipairs(data.asks) do
			table.insert(orderbook.asks, { price = decimal(v[1]), quantity = decimal(v[2]) })
		end

		table.sort(orderbook.bids, function(x, y)
			return x.price > y.price
		end)
		table.sort(orderbook.asks, function(x, y)
			return x.price < y.price
		end)

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

	gh._subscribe(req, 500)
	return router.register(req, parse_orderbook)
end

function M.subscribe_balance(market_type, params)
	local endpoint
	if market_type == "spot" then
		if params and params["auto_lend"] then
			endpoint = "/api/v1/capital/collateral"
		else
			-- TODO: implement this back
			-- endpoint = "/api/v1/capital"
			endpoint = "/api/v1/capital/collateral"
		end
	elseif market_type == "swap" then
		endpoint = "/api/v1/capital"
	else
		error("unsupported account type " .. market_type)
	end

	local function parse_balance(payload)
		local data = extract_data(payload)
		local balance = {}
		for _, v in ipairs(data.collateral) do
			if not util.is_zero(v.totalQuantity) then
				local free = decimal(v.lendQuantity)
				balance[v.symbol] = { free = free, locked = decimal(0), total = free }
			end
		end
		return common.wrap_balance(balance)
	end

	if params and params["auto_lend"] ~= nil then
		params["auto_lend"] = nil
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, {}), true)
	gh._subscribe(req, 500)
	return router.register(req, parse_balance)
end

function M.subscribe_position(market_type, params)
	local endpoint
	if market_type == "swap" then
		endpoint = "/api/v1/position"
	else
		error("unsupported account type " .. market_type)
	end

	local function parse_position(payload)
		local data = extract_data(payload)
		local position = {}
		for _, v in ipairs(data) do
			local base, quote = string.match(v.symbol, "(%w+)%_(%w+)%_PERP")
			if quote == "USDC" then
				position[base .. "USDT"] = decimal(v.netQuantity)
			end
		end
		return common.wrap_position(position)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, {}), true)

	gh._subscribe(req, 200)
	return router.register(req, parse_position)
end

function M.subscribe_orders(market, params)
	local endpoint, symbol
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/api/v1/orders"
		symbol = base .. "_" .. quote
	elseif market_type == "swap" then
		endpoint = "/api/v1/orders"
		symbol = base .. "_" .. quote .. "_PERP"
	else
		error("unsupported account type " .. market_type)
	end

	local function parse_orders(payload)
		local data = extract_data(payload)
		local orders = {}
		for _, v in ipairs(data) do
			if v.orderType == "Limit" and (v.status == "New" or v.status == "PartiallyFilled") then
				if v.side == "Bid" then
					table.insert(
						orders,
						{ id = tostring(v.id), price = decimal(v.price), amount = decimal(v.quantity) }
					)
				else
					table.insert(
						orders,
						{ id = tostring(v.id), price = decimal(v.price), amount = -decimal(v.quantity) }
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
			symbol = symbol,
		}),
		true
	)
	gh._subscribe(req, 500)
	return router.register(req, parse_orders)
end

---@return Order
function M.limit_order(market, price, amount, params)
	local endpoint, symbol
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/api/v1/order"
		symbol = base .. "_" .. quote
	elseif market_type == "swap" then
		endpoint = "/api/v1/order"
		symbol = base .. "_" .. quote .. "_PERP"
	else
		error("unsupported market type" .. market_type)
	end
	local default_params = {
		symbol = symbol,
		orderType = "Limit",
		quantity = amount:abs(),
		price = price,
		timeInForce = "GTC",
	}
	if amount > decimal(0) then
		default_params.side = "Bid"
	else
		default_params.side = "Ask"
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { price = price, amount = amount, id = tostring(data.id) }
end

---@return Order
function M.market_order(market, amount, params)
	local endpoint, symbol
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/api/v1/order"
		symbol = base .. "_" .. quote
	elseif market_type == "swap" then
		endpoint = "/api/v1/order"
		symbol = base .. "_" .. quote .. "_PERP"
	else
		error("unsupported market type" .. market_type)
	end
	local default_params = {
		symbol = symbol,
		orderType = "Market",
		quantity = amount:abs(),
	}
	if amount > decimal(0) then
		default_params.side = "Bid"
	else
		default_params.side = "Ask"
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { amount = amount, id = tostring(data.id) }
end

function M.cancel_order(market, order, params)
	local endpoint, symbol
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/api/v1/order"
		symbol = base .. "_" .. quote
	elseif market_type == "swap" then
		endpoint = "/api/v1/order"
		symbol = base .. "_" .. quote .. "_PERP"
	else
		error("unsupported market type" .. market_type)
	end
	local default_params = {
		symbol = symbol,
		orderId = order.id,
	}
	local _ = M.send(endpoint, "delete", util.apply_default(params, default_params), true)
end

function M.build_request(endpoint, method, params, private)
	local url = "https://api.backpack.exchange" .. endpoint
	local tbl
	if method == "post" or method == "delete" then
		tbl = { url = url, method = method, sign = private, body = json.encode(params) }
	else
		local urlencoded = util.build_urlencoded(params)
		if urlencoded ~= "" then
			url = url .. "?" .. urlencoded
		end
		tbl = { url = url, method = method, sign = private }
	end

	return tbl
end

function M.send(endpoint, method, params, private)
	return extract_data(send.send(M.build_request(endpoint, method, params, private)))
end

return M
