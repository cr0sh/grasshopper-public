local common = require("common")
local router = require("router")
local util = require("util")
local decimal = require("decimal")
local gh = require("gh")
local json = require("json")
local send = require("send")

local function extract_obj(payload)
	local success, obj = pcall(json.decode, payload.content)
	if not success then
		gh.debug("Failed payload: " .. payload.content)
		error("JSON decode failed: " .. tostring(obj))
	end
	if obj.status == "0000" then
		return obj
	end
	error({ code = obj.status, message = util.dump(obj) })
end

---@class Bithumb: Exchange
local M = {}

function M.subscribe_orderbook(market, params)
	local base, quote = common.parse_market(market)
	local endpoint = string.format("/public/orderbook/%s_%s", base, quote)

	local function parse_orderbook(payload)
		local data = extract_obj(payload).data

		local orderbook = { bids = {}, asks = {} }
		for _, v in ipairs(data.bids) do
			if decimal(v.quantity) > decimal(0) then
				table.insert(orderbook.bids, {
					price = decimal(v.price),
					quantity = decimal(v.quantity),
				})
			end
		end
		for _, v in ipairs(data.asks) do
			if decimal(v.quantity) > decimal(0) then
				table.insert(orderbook.asks, {
					price = decimal(v.price),
					quantity = decimal(v.quantity),
				})
			end
		end
		return common.wrap_orderbook(orderbook)
	end

	local req = M.build_request(endpoint, "get", params)

	gh._subscribe(req, 150)
	return router.register(req, parse_orderbook)
end

function M.subscribe_balance(market_type, params)
	local _ = market_type
	local function parse_balance(payload)
		local data = extract_obj(payload).data
		local balance = {}
		for k, v in pairs(data) do
			local s = string.find(k, "total_")
			if s then
				local asset = string.sub(k, 7)
				local entry = {
					free = decimal(data["available_" .. asset]),
					locked = decimal(data["in_use_" .. asset]),
					total = decimal(v),
				}
				balance[string.upper(asset)] = entry
			end
		end
		return common.wrap_balance(balance)
	end

	local req = M.build_request("/info/balance", "post", util.apply_default(params, { currency = "ALL" }), true)

	gh._subscribe(req, 200)
	return router.register(req, parse_balance)
end

function M.subscribe_orders(market, params)
	local base, quote = common.parse_market(market)

	local function parse_orders(payload)
		local success, data = pcall(extract_obj, payload)
		if not success then
			if data.code == "5600" then
				return common.wrap_orders({})
			else
				error(data)
			end
		end
		local orders = {}
		for _, v in ipairs(data.data) do
			if v.order_currency == base and v.payment_currency == quote then
				if v.type == "bid" then
					table.insert(orders, { price = decimal(v.price), amount = decimal(v.units), id = v.order_id })
				else
					table.insert(orders, { price = decimal(v.price), amount = -decimal(v.units), id = v.order_id })
				end
			end
		end

		return common.wrap_orders(orders)
	end

	local req = M.build_request(
		"/info/orders",
		"post",
		util.apply_default(params, { order_currency = base, payment_currency = quote }),
		true
	)

	gh._subscribe(req, 200)
	return router.register(req, parse_orders)
end

---@return Order
function M.limit_order(market, price, amount, params)
	local endpoint = "/trade/place"
	local qty = amount:abs()
	local order_type = "ask"
	if amount > decimal(0) then
		order_type = "bid"
	end
	local base, quote = common.parse_market(market)
	local data = M.send(
		endpoint,
		"post",
		util.apply_default(params, {
			order_currency = base,
			payment_currency = quote,
			units = qty,
			price = price,
			type = order_type,
		}),
		true
	)
	return { price = price, amount = amount, id = data.order_id, type = order_type }
end

---@return Order
function M.market_order(market, amount, params)
	local endpoint = "/trade/market_sell"
	if amount > decimal(0) then
		endpoint = "/trade/market_buy"
	end
	local qty = amount:abs()
	local base, quote = common.parse_market(market)
	local data = M.send(
		endpoint,
		"post",
		util.apply_default(params, {
			units = qty,
			order_currency = base,
			payment_currency = quote,
		}),
		true
	)
	return { amount = amount, id = data.order_id }
end

function M.cancel_order(market, order, params)
	local endpoint = "/trade/cancel"
	local base, quote = common.parse_market(market)
	M.send(
		endpoint,
		"post",
		util.apply_default(params, {
			type = order.type,
			order_id = order.id,
			order_currency = base,
			payment_currency = quote,
		}),
		true
	)
end

function M.build_request(endpoint, method, params, private)
	local url = "https://api.bithumb.com" .. endpoint
	local urlencoded = util.build_urlencoded(params)
	local tbl
	if method == "get" then
		url = url .. "?" .. urlencoded
		tbl = { url = url, method = method, sign = private }
	elseif method == "post" then
		tbl = { url = url, method = method, body = urlencoded, sign = private }
	else
		error("invalid method " .. method)
	end
	return tbl
end

function M.send(endpoint, method, params, private)
	return extract_obj(send.send(M.build_request(endpoint, method, params, private)))
end

return M
