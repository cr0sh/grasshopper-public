local common = require("common")
local router = require("router")
local util = require("util")
local decimal = require("decimal")
local gh = require("gh")
local json = require("json")
local send = require("send")
local binance = require("binance")

local function extract_data(payload)
	local success, obj = pcall(json.decode, payload.content)
	if not success then
		gh.debug("Failed payload: " .. payload.content)
		error("JSON decode failed: " .. tostring(obj))
	end
	return obj
end

---@class Lighter: Exchange
local M = {}

local metadata_cache

local function get_metadata(symbol)
	if metadata_cache == nil then
		local books_data = extract_data(send.send({
			url = "https://mainnet.zklighter.elliot.ai/api/v1/orderBookDetails",
			method = "get",
			sign = false,
		}))
		metadata_cache = {}
		for _, v in ipairs(books_data["order_book_details"]) do
			metadata_cache[v["symbol"]] = {
				id = v["market_id"],
				size_multiplier = (decimal(10) ^ decimal(v["size_decimals"])):round_to_decimals(0),
				price_multiplier = (decimal(10) ^ decimal(v["price_decimals"])):round_to_decimals(0),
			}
		end
	end
	return metadata_cache[symbol]
end

function M.subscribe_position(market_type, params)
	local endpoint = "/positions"

	if market_type == nil or market_type == "swap" then
	else
		error("unsupported market type " .. market_type)
	end

	local function parse_position(payload)
		local result = extract_data(payload)

		local position = {}
		for _, v in ipairs(result) do
			position[v[1] .. "USDT"] = decimal(v[2])
		end

		return common.wrap_position(position)
	end

	local req = M.build_request(endpoint, "get", params, false)

	gh._subscribe(req, 200)
	return router.register(req, parse_position)
end

M.subscribe_orderbook = binance.subscribe_orderbook

function M.limit_order(market, price, amount, params)
	local base, quote = common.parse_market(market)
	local metadata = get_metadata(base)
	gh.debug(base .. ":" .. util.dump(metadata))
	gh.debug(tostring(amount))
	local default_params = {
		orderType = 0,
		orderBookIndex = metadata["id"],
		price = tostring((price * metadata["price_multiplier"]):round_to_decimals(0)),
		baseAmount = tostring((amount:abs() * metadata["size_multiplier"]):round_to_decimals(0)),
	}

	if quote ~= "USDT" then
		error("unsupported quote " .. quote)
	end

	if amount > decimal(0) then
		default_params["isAsk"] = 0
	else
		default_params["isAsk"] = 1
	end

	local data = extract_data(send.send({
		url = "http://localhost:3000/create-order",
		method = "post",
		body = json.encode(util.apply_default(params, default_params)),
	}))

	return { price = price, amount = amount, id = data.orderId }
end

function M.build_request(endpoint, method, params, private)
	local url = "http://localhost:3000" .. endpoint
	local tbl
	if method == "get" then
		local urlencoded = util.build_urlencoded(params)
		if urlencoded ~= "" then
			url = url .. "?" .. urlencoded
		end
		tbl = { url = url, method = method, sign = private }
	elseif method == "post" then
		tbl = { url = url, method = method, body = json.encode(params), sign = private }
	else
		error("invalid method " .. method)
	end

	return tbl
end

return M
