local router = require("router")

local position_extractors = {}
local last_hedge = {
	BTC = decimal(0),
	FIL = decimal(0),
}
local taker_orderbooks = {}

---@class HedgeConfig
---@field max_order_size_usdt Decimal
---@field max_unhedged {[string]: Decimal}
---@field taker_qty_precision {[string]: number}
---@field taker_price_unit {[string]: Decimal}
---@field position_offset {[string]: Decimal|nil}
---@field maker_takers {[string]: Exchange[]}
---@field market_types {[string]: MarketType[]}

---@param config HedgeConfig
local function hedge(config)
	local function get_config(key)
		if config[key] == nil then
			error(string.format("missing config.%s", key))
		end
		return config[key]
	end

	local max_order_size_usdt = get_config("max_order_size_usdt")
	local max_unhedged = get_config("max_unhedged")
	local taker_qty_precision = get_config("taker_qty_precision")
	local taker_price_unit = get_config("taker_price_unit")
	local position_offset = get_config("position_offset")
	local maker_takers = get_config("maker_takers")
	local market_types = get_config("market_types")

	for currency, maker_taker in pairs(maker_takers) do
		position_extractors[currency] = {}
		last_hedge[currency] = decimal(0)
		if market_types[currency][1] == "spot" then
			local extractor = maker_taker[1].subscribe_balance("spot")
			table.insert(position_extractors[currency], function(x)
				return extractor(x)[currency].total
			end)
		elseif market_types[currency][1] == "swap" then
			local extractor = maker_taker[1].subscribe_position("swap")
			table.insert(position_extractors[currency], function(x)
				return extractor(x)[currency .. "USDT"]
			end)
		else
			error("unknown market type " .. market_types[currency][1])
		end

		if market_types[currency][2] == "spot" then
			local extractor = maker_taker[2].subscribe_balance("spot")
			table.insert(position_extractors[currency], function(x)
				return extractor(x)[currency].total
			end)
		elseif market_types[currency][2] == "swap" then
			local extractor = maker_taker[2].subscribe_position("swap")
			table.insert(position_extractors[currency], function(x)
				return extractor(x)[currency .. "USDT"]
			end)
		else
			error("unknown market type " .. market_types[currency][2])
		end
		taker_orderbooks[currency] =
			maker_taker[2].subscribe_orderbook(string.format("%s:%s/USDT", market_types[currency][2], currency))
	end

	router.on(function(x)
		for currency in pairs(max_unhedged) do
			local net_position = position_extractors[currency][1](x)
				+ position_extractors[currency][2](x)
				+ position_offset[currency]
			if net_position:abs() > max_unhedged[currency] then
				if gh.millis() - last_hedge[currency] >= decimal(1000) then
					gh.info(string.format("currency %s unhedged: net position %s", currency, net_position))
					local mid_price = (
						taker_orderbooks[currency](x).bids[1].price + taker_orderbooks[currency](x).asks[1].price
					) / decimal(2)
					local limit_price
					if net_position > decimal(0) then
						limit_price = taker_orderbooks[currency](x).bids[1].price * decimal(0.97)
					else
						limit_price = taker_orderbooks[currency](x).asks[1].price * decimal(1.03)
					end
					maker_takers[currency][2].limit_order(
						string.format("%s:%s/USDT", market_types[currency][2], currency),
						(limit_price / taker_price_unit[currency]):round_to_decimals(0) * taker_price_unit[currency],
						(-net_position)
							:round_to_decimals(taker_qty_precision[currency])
							:min((max_order_size_usdt / mid_price):floor_to_decimals(taker_qty_precision[currency]))
					)
					last_hedge[currency] = gh.millis()
				end
			end
		end
	end)
end

return hedge
