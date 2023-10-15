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
	if obj.code ~= nil then
		error({ code = obj.code, message = obj.msg })
	end
	return obj
end

---@class BinancePm: Exchange
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

	gh._subscribe(req, 300)
	return router.register(req, parse_orderbook)
end

function M.subscribe_balance(market_type, params)
	local _ = market_type
	local endpoint = "/papi/v1/balance"

	local function parse_balance(payload)
		local data = extract_data(payload)
		local balance = {}
		if market_type == "spot" then
			for _, v in ipairs(data) do
				if
					not (
						v.free ~= nil
						and util.is_zero(v.free)
						and util.is_zero(v.locked)
						and util.is_zero(v.total)
						and v.debt ~= nil
						and util.is_zero(v.debt)
					)
				then
					local free = decimal(v.crossMarginFree)
					local total = decimal(v.totalWalletBalance)
					local debt = decimal(v.crossMarginBorrowed) + decimal(v.crossMarginInterest)
					balance[v.asset] = { free = free, locked = total - free, total = total, debt = debt }
				end
			end
		else
			-- TODO
		end
		return common.wrap_balance(balance)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, {}), true)
	gh._subscribe(req, 300)
	return router.register(req, parse_balance)
end

function M.subscribe_orders(market, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/papi/v1/margin/openOrders"
	elseif market_type == "swap" then
		endpoint = "/papi/v1/um/openOrders"
	else
		error("unsupported account type")
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
		endpoint = "/papi/v1/um/positionRisk"
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
	gh._subscribe(req, 300)
	return router.register(req, parse_position)
end

---@return Order
function M.limit_order(market, price, amount, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/papi/v1/margin/order"
	elseif market_type == "swap" then
		endpoint = "/papi/v1/um/order"
	else
		error("unsupported market type " .. market_type)
	end
	local default_params = {
		symbol = base .. quote,
		type = "LIMIT",
		quantity = amount:abs(),
		price = price,
		timeInForce = "GTC",
	}
	if market_type == "spot" then
		default_params.sideEffectType = "MARGIN_BUY"
	end
	if amount > decimal(0) then
		default_params.side = "BUY"
	else
		default_params.side = "SELL"
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { price = price, amount = amount, id = tostring(data.orderId) }
end

---@return Order
function M.market_order(market, amount, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/papi/v1/margin/order"
	elseif market_type == "swap" then
		endpoint = "/papi/v1/um/order"
	else
		error("unsupported market type " .. market_type)
	end
	local default_params = {
		symbol = base .. quote,
		type = "MARKET",
		quantity = amount:abs(),
	}
	if market_type == "spot" then
		default_params.sideEffectType = "MARGIN_BUY"
	end
	if amount > decimal(0) then
		default_params.side = "BUY"
	else
		default_params.side = "SELL"
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { amount = amount, id = tostring(data.orderId) }
end

function M.cancel_order(market, order, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		endpoint = "/papi/v1/margin/order"
	elseif market_type == "swap" then
		endpoint = "/papi/v1/um/order"
	else
		error("unsupported market type " .. market_type)
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
	elseif api == "papi" then
		url = "https://papi.binance.com" .. endpoint
	else
		error("unknown endpoint type " .. api)
	end
	local tbl
	local urlencoded = util.build_urlencoded(params)
	if urlencoded ~= "" then
		url = url .. "?" .. urlencoded
	end
	tbl = { url = url, method = method, sign = private }

	return tbl
end

function M.send(endpoint, method, params, private)
	return extract_data(send.send(M.build_request(endpoint, method, params, private)))
end

return M
