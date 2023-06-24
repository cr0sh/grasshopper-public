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
	if obj.code == "0" then
		return obj.data
	end
	error({ code = obj.code, message = util.dump(obj) })
end

---@class Okx: Exchange
local M = {}

local contract_size_cache = {}

function M.subscribe_orderbook(market, params)
	local base, quote, market_type = common.parse_market(market)
	local endpoint = "/api/v5/market/books"
	local symbol
	if market_type == "spot" then
		symbol = base .. "-" .. quote
	elseif market_type == "swap" then
		symbol = base .. "-" .. quote .. "-SWAP"
	else
		error("unsupported market type " .. market_type)
	end

	local function parse_orderbook(payload)
		local data = extract_data(payload)

		local orderbook = { bids = {}, asks = {} }
		for _, v in ipairs(data[1].bids) do
			table.insert(orderbook.bids, { price = decimal(v[1]), quantity = decimal(v[2]) })
		end
		for _, v in ipairs(data[1].asks) do
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

	gh._subscribe(req, 200)
	return router.register(req, parse_orderbook)
end

function M.subscribe_balance(market_type, params)
	local endpoint = "/api/v5/account/balance"
	local _ = market_type

	local function parse_balance(payload)
		local data = extract_data(payload)
		local balance = {}

		for _, v in ipairs(data[1].details) do
			local free = decimal(v.availBal)
			local locked = decimal(v.frozenBal)
			balance[v.ccy] = { free = free, locked = locked, total = free + locked }
		end

		return common.wrap_balance(balance)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, {}), true)

	gh._subscribe(req, 500)
	return router.register(req, parse_balance)
end

function M.subscribe_position(market_type, params)
	local endpoint = "/api/v5/account/positions"
	local inst_type
	if market_type == "swap" then
		inst_type = "SWAP"
	else
		error("unsupported market type " .. market_type)
	end

	local function parse_position(payload)
		local data = extract_data(payload)
		local position = {}

		for _, v in ipairs(data) do
			local abs = decimal(v.pos)
			local base, quote = string.match(v.instId, "(%w+)%-(%w+)%-SWAP")
			if base == nil then
				error("unknown instId " .. v.instId)
			end
			if v.posSide == "short" then
				abs = -abs
			end
			position[base .. quote] = abs
		end

		return common.wrap_position(position)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, { instType = inst_type }), true)

	gh._subscribe(req, 500)
	return router.register(req, parse_position)
end

function M.subscribe_orders(market, params)
	local endpoint = "/api/v5/trade/orders-pending"
	local base, quote, market_type = common.parse_market(market)
	local symbol
	if market_type == "spot" then
		symbol = base .. "-" .. quote
	elseif market_type == "swap" then
		symbol = base .. "-" .. quote .. "-SWAP"
	else
		error("unsupported market type " .. market_type)
	end

	local function parse_orders(payload)
		local data = extract_data(payload)
		local orders = {}

		for _, v in ipairs(data) do
			if v.side == "buy" then
				table.insert(orders, { price = decimal(v.px), amount = decimal(v.sz), id = v.ordId })
			else
				table.insert(orders, { price = decimal(v.px), amount = -decimal(v.sz), id = v.ordId })
			end
		end

		return common.wrap_orders(orders)
	end

	local req = M.build_request(endpoint, "get", util.apply_default(params, { instId = symbol }), true)

	gh._subscribe(req, 500)
	return router.register(req, parse_orders)
end

function M.limit_order(market, price, amount, params)
	local endpoint = "/api/v5/trade/order"
	local base, quote, market_type = common.parse_market(market)
	local default_params = {
		ordType = "limit",
		px = tostring(price),
		sz = tostring(amount:abs()),
	}
	local contract_size
	if market_type == "spot" then
		default_params.instId = base .. "-" .. quote
		default_params.tdMode = "cash"
	elseif market_type == "swap" then
		default_params.instId = base .. "-" .. quote .. "-SWAP"
		default_params.tdMode = "cross"
		contract_size = contract_size_cache[default_params.instId]
		if contract_size == nil then
			error(string.format("contract size unknown for instrument %s", default_params.instId))
		end
		default_params.sz = tostring((amount / contract_size):abs())
	else
		error("unknown market type " .. market_type)
	end

	if amount > decimal(0) then
		default_params.side = "buy"
	else
		default_params.side = "sell"
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { price = price, amount = amount, id = data[1].ordId }
end

function M.market_order(market, amount, params)
	local endpoint = "/api/v5/trade/order"
	local base, quote, market_type = common.parse_market(market)
	local default_params = {
		ordType = "market",
		sz = tostring(amount:abs()),
		tdMode = "cash",
	}
	local contract_size
	if market_type == "spot" then
		default_params.instId = base .. "-" .. quote
	elseif market_type == "swap" then
		default_params.instId = base .. "-" .. quote .. "-SWAP"
		contract_size = contract_size_cache[default_params.instId]
		if contract_size == nil then
			error(string.format("contract size unknown for instrument %s", default_params.instId))
		end
		default_params.sz = tostring((amount / contract_size):abs())
	else
		error("unknown market type " .. market_type)
	end

	if amount > decimal(0) then
		default_params.side = "buy"
	else
		default_params.side = "sell"
	end

	local data = M.send(endpoint, "post", util.apply_default(params, default_params), true)
	return { amount = amount, id = data[1].ordId }
end

function M.cancel_order(market, order, params)
	local endpoint = "/api/v5/trade/cancel-order"
	local base, quote, market_type = common.parse_market(market)
	local default_params = { ordId = order.id }
	if market_type == "spot" then
		default_params.instId = base .. "-" .. quote
	elseif market_type == "swap" then
		default_params.instId = base .. "-" .. quote .. "-SWAP"
	else
		error("unknown market type " .. market_type)
	end

	M.send(endpoint, "post", util.apply_default(params, default_params), true)
end

function M.build_request(endpoint, method, params, private)
	local url = "https://aws.okx.com" .. endpoint
	local tbl
	if method == "get" then
		local urlencoded = util.build_urlencoded(params)
		if urlencoded ~= "" then
			url = url .. "?" .. urlencoded
		end
		tbl = { url = url, method = method }
	elseif method == "post" then
		tbl = {
			url = url,
			method = method,
			body = json.encode(params),
			headers = { ["Content-Type"] = "application/json" },
		}
	else
		error("invalid method " .. method)
	end

	if private then
		tbl.sign = "okx"
	end
	return tbl
end

function M.send(endpoint, method, params, private)
	return extract_data(gh._send(M.build_request(endpoint, method, params, private)))
end

local instruments_data = M.send("/api/v5/public/instruments", "get", { instType = "SWAP" })
for i, v in ipairs(instruments_data) do
	if v["instId"] == nil or v["instId"] == "" then
		error(string.format("empty instid on index %d", i))
	end
	contract_size_cache[v["instId"]] = decimal(v["ctVal"])
end

return M
