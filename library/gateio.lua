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
	if obj.label ~= nil then
		error({ code = obj.label, message = util.dump(obj) })
	end
	return obj
end

---@class Gateio: Exchange
local M = {}

local quanto_multiplier_cache = {}

---Returns quanto_multiplier of the market given.
---@param base string
---@param quote string
local function quanto_multiplier(base, quote)
	if quanto_multiplier_cache[base .. quote] ~= nil then
		return quanto_multiplier_cache[base .. quote]
	end

	local endpoint = "/futures/usdt/contracts/" .. base .. "_" .. quote
	local data = M.send(endpoint, "get", {}, false)
	quanto_multiplier_cache[base .. quote] = decimal(data.quanto_multiplier)
	return quanto_multiplier_cache[base .. quote]
end

function M.subscribe_orderbook(market, params)
	local base, quote, market_type = common.parse_market(market)
	local endpoint
	local symbol
	local default_params = {}
	if market_type == "spot" then
		endpoint = "/spot/order_book"
		default_params.currency_pair = base .. "_" .. quote
	elseif market_type == "swap" then
		endpoint = "/futures/usdt/order_book"
		default_params.contract = base .. "_" .. quote
	else
		error("unsupported market type " .. market_type)
	end

	local function parse_orderbook(payload)
		local data = extract_data(payload)

		local orderbook = { bids = {}, asks = {} }
		if market_type == "spot" then
			for _, v in ipairs(data.bids) do
				table.insert(orderbook.bids, { price = decimal(v[1]), quantity = decimal(v[2]) })
			end
			for _, v in ipairs(data.asks) do
				table.insert(orderbook.asks, { price = decimal(v[1]), quantity = decimal(v[2]) })
			end
		else
			for _, v in ipairs(data.bids) do
				table.insert(orderbook.bids, { price = decimal(v.p), quantity = decimal(v.s) })
			end
			for _, v in ipairs(data.asks) do
				table.insert(orderbook.asks, { price = decimal(v.p), quantity = decimal(v.s) })
			end
		end

		return common.wrap_orderbook(orderbook)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, default_params))

	gh._subscribe(req, 200)
	return router.register(req, parse_orderbook)
end

function M.subscribe_balance(market_type, params)
	local endpoint
	local _ = market_type
	if market_type == "spot" then
		endpoint = "/spot/accounts"
	elseif market_type == "swap" then
		endpoint = "/futures/usdt/accounts"
	else
		error("unsupported market type " .. market_type)
	end

	local function parse_balance(payload)
		local data = extract_data(payload)
		local balance = {}

		if market_type == "spot" then
			for _, v in ipairs(data) do
				local free = decimal(v.available)
				local locked = decimal(v.locked)
				balance[v.currency] = { free = free, locked = locked, total = free + locked }
			end
		else
			local free = decimal(data.available)
			local total = decimal(data.total)
			balance[data.currency] = { free = free, locked = total - free, total = total }
		end

		return common.wrap_balance(balance)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, {}), true)

	gh._subscribe(req, 500)
	return router.register(req, parse_balance)
end

function M.subscribe_position(market_type, params)
	local endpoint = "/futures/usdt/positions"
	if market_type ~= "swap" then
		error("unsupported market type " .. market_type)
	end

	local function parse_position(payload)
		local data = extract_data(payload)
		local position = {}

		for _, v in ipairs(data) do
			local base, quote = string.match(v.contract, "(%w+)_(%w+)")
			if base == nil then
				error("unknown contract " .. v.instId)
			end
			position[base .. quote] = decimal(v.size) * quanto_multiplier(base, quote)
		end

		return common.wrap_position(position)
	end

	local req = M.build_request(endpoint, "get", params, true)

	gh._subscribe(req, 500)
	return router.register(req, parse_position)
end

function M.subscribe_orders(market, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	local default_params = {}
	if market_type == "spot" then
		endpoint = "/spot/open_orders"
	elseif market_type == "swap" then
		endpoint = "/futures/usdt/orders"
		default_params.contract = base .. "_" .. quote
		default_params.status = "open"
	else
		error("unsupported market type " .. market_type)
	end

	local function parse_orders(payload)
		local data = extract_data(payload)
		local orders = {}
		if market_type == "spot" then
			local raw_orders
			local found = false
			for _, v in ipairs(data) do
				if v.currency_pair == base .. "_" .. quote then
					raw_orders = v.orders
					break
				end
			end
			if raw_orders == nil then
				return common.wrap_orders({})
			end
			for _, order in ipairs(raw_orders) do
				if order.status == "open" then
					if order.side == "buy" then
						table.insert(
							orders,
							{ price = decimal(order.price), amount = decimal(order.amount), id = order.id }
						)
					else
						table.insert(
							orders,
							{ price = decimal(order.price), amount = -decimal(order.amount), id = order.id }
						)
					end
				end
			end
			return common.wrap_orders(orders)
		else
			for _, order in ipairs(data) do
				if order.contract == base .. "_" .. quote then
					table.insert(
						orders,
						{ price = decimal(order.price), amount = decimal(order.size), id = tostring(order.id) }
					)
				end
			end
			return common.wrap_orders(orders)
		end
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, default_params), true)

	gh._subscribe(req, 500)
	return router.register(req, parse_orders)
end

function M.limit_order(market, price, amount, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	local default_params
	if market_type == "spot" then
		endpoint = "/spot/orders"
		default_params = {
			currency_pair = base .. "_" .. quote,
			type = "limit",
			account = "spot",
			time_in_force = "gtc",
			price = tostring(price),
			amount = tostring(amount:abs()),
		}
		if amount > decimal(0) then
			default_params.side = "buy"
		else
			default_params.side = "sell"
		end
	elseif market_type == "swap" then
		endpoint = "/futures/usdt/orders"
		default_params = {
			contract = base .. "_" .. quote,
			size = (amount / quanto_multiplier(base, quote)).value,
			price = tostring(price),
			tif = "gtc",
		}
	else
		error("unknown market type " .. market_type)
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { price = price, amount = amount, id = data.id }
end

function M.market_order(market, amount, params)
	local endpoint
	local base, quote, market_type = common.parse_market(market)
	local default_params
	if market_type == "spot" then
		endpoint = "/spot/orders"
		default_params = {
			currency_pair = base .. "_" .. quote,
			type = "market",
			account = "spot",
			amount = tostring(amount:abs()),
			time_in_force = "fok",
		}
		if amount > decimal(0) then
			default_params.side = "buy"
		else
			default_params.side = "sell"
		end
	elseif market_type == "swap" then
		endpoint = "/futures/usdt/orders"
		default_params = {
			contract = base .. "_" .. quote,
			size = (amount / quanto_multiplier(base, quote)).value,
			price = "0",
			tif = "fok",
		}
	else
		error("unknown market type " .. market_type)
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { amount = amount, id = data.id }
end

function M.cancel_order(market, order, params)
	local base, quote, market_type = common.parse_market(market)
	if market_type == "spot" then
		local endpoint = "/spot/cancel_batch_orders"
		M.send(endpoint, "post", { { currency_pair = base .. "_" .. quote, id = order.id } }, true)
	elseif market_type == "swap" then
		local endpoint = "/futures/usdt/orders/" .. order.id
		M.send(endpoint, "delete", params, true)
	else
		error("unknown market type " .. market_type)
	end
end

function M.build_request(endpoint, method, params, private)
	local url = "https://api.gateio.ws/api/v4" .. endpoint
	local tbl
	if method == "get" then
		local urlencoded = util.build_urlencoded(params)
		if urlencoded ~= "" then
			url = url .. "?" .. urlencoded
		end
		tbl = { url = url, method = method }
	else
		tbl = {
			url = url,
			method = method,
			body = json.encode(params),
			headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" },
		}
	end

	if private then
		tbl.sign = "gateio"
	end
	return tbl
end

function M.send(endpoint, method, params, private)
	return extract_data(gh._send(M.build_request(endpoint, method, params, private)))
end

return M
