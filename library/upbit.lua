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
	if obj.error ~= nil then
		error({ code = obj.error.name, message = tostring(obj.error.message) })
	end
	return obj
end

---@class Upbit: Exchange
local M = {}

function M.subscribe_orderbook(market, params)
	local base, quote = common.parse_market(market)
	local endpoint = "/v1/orderbook"
	local symbol = quote .. "-" .. base

	local function parse_orderbook(payload)
		local data = extract_data(payload)

		local function extract_orderbook(tbl)
			local orderbook = { bids = {}, asks = {} }
			for _, v in ipairs(tbl.orderbook_units) do
				table.insert(orderbook.bids, { price = decimal(v.bid_price), quantity = decimal(v.bid_size) })
				table.insert(orderbook.asks, { price = decimal(v.ask_price), quantity = decimal(v.ask_size) })
			end
			return orderbook
		end

		if #data == 1 then
			return common.wrap_orderbook(extract_orderbook(data[1]))
		else
			local orderbooks = {}
			for _, v in ipairs(data) do
				local quote_, base_ = string.match(v.market, "(%w+)-(%w+)")
				orderbooks[base_ .. quote_] = common.wrap_orderbook(extract_orderbook(v))
			end
			return orderbooks
		end
	end

	local req = M.build_request(
		endpoint,
		"get",
		util.apply_default(params, {
			markets = { symbol },
		})
	)

	gh._subscribe(req, 300)
	return router.register(req, parse_orderbook)
end

function M.subscribe_balance(market_type, params)
	local endpoint = "/v1/accounts"
	local _ = market_type

	local function parse_balance(payload)
		local data = extract_data(payload)
		local balance = {}
		for _, v in ipairs(data) do
			local free = decimal(v.balance)
			local locked = decimal(v.locked)
			balance[v.currency] = { free = free, locked = locked, total = free + locked }
		end
		return common.wrap_balance(balance)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, {}), true)
	gh._subscribe(req, 500)
	return router.register(req, parse_balance)
end

function M.subscribe_orders(market, params)
	local endpoint = "/v1/orders"
	local base, quote = common.parse_market(market)

	local function parse_orders(payload)
		local data = extract_data(payload)
		local orders = {}
		for _, v in ipairs(data) do
			if v.state == "wait" then
				local order = {
					id = v.uuid,
					price = decimal(v.price),
				}
				if order.side == "bid" then
					v.amount = decimal(v.volume)
				else
					v.amount = -decimal(v.volume)
				end
				table.insert(orders, order)
			end
		end
		return common.wrap_orders(orders)
	end

	local req = M.build_request(
		endpoint,
		"get",
		util.apply_default(params, {
			market = quote .. "-" .. base,
		}),
		true
	)
	gh._subscribe(req, 500)
	return router.register(req, parse_orders)
end

function M.limit_order(market, price, amount, params)
	local endpoint = "/v1/orders"
	local base, quote = common.parse_market(market)
	local market_ = quote .. "-" .. base
	local volume = amount:abs()
	local side = "ask"
	if amount > decimal(0) then
		side = "bid"
	end
	local data = M.send(
		endpoint,
		"post",
		util.apply_default(params, {
			market = market_,
			volume = tostring(volume),
			side = side,
			price = tostring(price),
			ord_type = "limit",
		}),
		true
	)
	return { price = price, amount = amount, id = data.uuid }
end

function M.market_order(market, amount, params)
	local endpoint = "/v1/orders"
	local base, quote = common.parse_market(market)
	local market_ = quote .. "-" .. base
	local volume = amount:abs()
	local side = "ask"
	if amount > decimal(0) then
		side = "bid"
	end
	local data = M.send(
		endpoint,
		"post",
		util.apply_default(params, {
			market = market_,
			volume = tostring(volume),
			side = side,
			ord_type = "limit",
		}),
		true
	)
	return { amount = amount, id = data.uuid }
end

function M.cancel_order(market, order, params)
	local endpoint = "/v1/order"
	local _ = market
	M.send(
		endpoint,
		"delete",
		util.apply_default(params, {
			uuid = order.id,
		}),
		true
	)
end

function M.build_request(endpoint, method, params, private)
	local url = "https://api.upbit.com" .. endpoint
	local tbl = { method = method }
	if method == "get" then
		local flattened = {}
		for k, v in pairs(params) do
			if type(v) == "table" then
				for _, vv in ipairs(v) do
					flattened[string.format("%s", k)] = vv
				end
			else
				flattened[k] = v
			end
		end
		local urlencoded = util.build_urlencoded(flattened)
		if urlencoded ~= "" then
			url = url .. "?" .. urlencoded
		end
	else
		tbl.headers = { ["Content-Type"] = "application/json; charset=utf-8" }
		tbl.body = json.encode(params)
	end
	tbl.url = url

	if private then
		tbl.sign = "upbit"
	end
	return tbl
end

function M.send(endpoint, method, params, private)
	return extract_data(gh._send(M.build_request(endpoint, method, params, private)))
end

return M
