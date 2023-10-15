local router = require("router")
local util = require("util")
local trade_utils = require("strategy.trade_utils")
local gh = require("gh")
local decimal = require("decimal")

local position_extractors = {}
local taker_exchanges = {}
local taker_market_types = {}
local last_hedge = {
	BTC = decimal(0),
	FIL = decimal(0),
}
local taker_orderbooks = {}
local position_locked_since = {}
local last_taker_position_before_lock = {}
local position_unlockers = {}

---@class TransposedHedgeConfig
---@field max_taker_slippage Decimal
---@field max_unhedged Decimal
---@field position_offset Decimal | string | nil
---@field makers string[][]
---@field taker string[]
---@field order_params {[string]: any} | nil

---@param transposed_config {[string]: TransposedHedgeConfig}
local function hedge(transposed_config, ignore_hedge_safeguard)
	local config_exists = false

	local config = {}
	for coin, values in pairs(transposed_config) do
		config_exists = true
		for key, value in pairs(values) do
			if config[key] == nil then
				config[key] = { [coin] = value }
			else
				config[key][coin] = value
			end
		end
	end
	if not config_exists then
		return
	end
	local function get_config(key)
		if config[key] == nil then
			error(string.format("missing config.%s", key))
		end
		return config[key]
	end

	local max_taker_slippage = get_config("max_taker_slippage")
	local max_unhedged = get_config("max_unhedged")
	local position_offset = get_config("position_offset")
	local makers = get_config("makers")
	local taker = get_config("taker")
	local order_params = config.order_params

	for currency, makers_tbl in pairs(makers) do
		position_extractors[currency] = {}
		last_hedge[currency] = decimal(0)
		for _, maker in ipairs(makers_tbl) do
			local market_type, exchange = unpack(maker)
			position_extractors[currency][exchange .. "-" .. market_type] =
				trade_utils.subscribe_effective_position(require(exchange), market_type, currency)
		end

		local market_type, exchange = unpack(taker[currency])
		taker_market_types[currency] = market_type
		taker_exchanges[currency] = exchange
		local eff_position = trade_utils.subscribe_effective_position(require(exchange), market_type, currency)
		position_extractors[currency][exchange .. "-" .. market_type] = eff_position
		position_unlockers[currency] = function(x)
			local taker_position = eff_position(x)
			if position_locked_since[currency] then
				if last_taker_position_before_lock[currency] ~= taker_position then
					gh.debug(
						string.format(
							"position unlocked: %s ~= %s",
							last_taker_position_before_lock[currency],
							taker_position
						)
					)
					position_locked_since[currency] = nil
				end
			end
			last_taker_position_before_lock[currency] = taker_position
		end
		taker_exchanges[currency] = require(exchange)
		taker_orderbooks[currency] =
			require(exchange).subscribe_orderbook(string.format("%s:%s/USDT", market_type, currency))
	end

	local position_confirmed = {}

	local taker_price_unit = {}
	local taker_quantity_unit = {}

	router.on(function(x, extractor)
		local position_error = false
		for currency in pairs(transposed_config) do
			local unadjusted_net_position = decimal(0)

			for _, position_extractor in pairs(position_extractors[currency]) do
				unadjusted_net_position = unadjusted_net_position + position_extractor(x)
			end

			position_unlockers[currency](x, extractor)

			if position_offset[currency] == "auto" then
				position_offset[currency] = -unadjusted_net_position
				gh.info(
					string.format(
						'position offset is "auto" for currency %s: set to %s',
						currency,
						position_offset[currency]
					)
				)
			elseif position_offset[currency] == "force" then
				position_offset[currency] = decimal(0)
				position_confirmed[currency] = true
				gh.warn(string.format('position offset is "force" for currency %s', currency))
			end

			local net_position = unadjusted_net_position + position_offset[currency]
			if taker_price_unit[currency] == nil and taker_quantity_unit[currency] == nil then
				taker_price_unit[currency], taker_quantity_unit[currency] =
					util.orderbook_units(taker_orderbooks[currency](x))
			end
			local mid_price = (
				taker_orderbooks[currency](x).bids[1].price + taker_orderbooks[currency](x).asks[1].price
			) / decimal(2)
			if not position_confirmed[currency] and net_position:abs() * mid_price > decimal(8000) then
				gh.error(
					string.format(
						"currency %s unhedged too much at initialization (net position %s)! exiting",
						currency,
						net_position
					)
				)
				position_error = true
			else
				position_confirmed[currency] = true
				if net_position:abs() > max_unhedged[currency] then
					if
						position_locked_since[currency] ~= nil
						and gh.millis() - position_locked_since[currency] >= decimal(2500)
					then
						gh.error("position locked more than 2500 milliseconds, retrying hedge")
						position_locked_since[currency] = nil
					end
					if
						position_locked_since[currency] == nil
						and gh.millis() - last_hedge[currency] >= decimal(300)
					then
						gh.info(string.format("currency %s unhedged: net position %s", currency, net_position))
						for name, eff_position in pairs(position_extractors[currency]) do
							gh.debug(name .. ": " .. tostring(eff_position(x)))
						end
						local limit_price
						local orderbook_idx = 1
						local max_order_size = decimal(0)
						if net_position > decimal(0) then
							while
								max_taker_slippage[currency]
								>= (
										taker_orderbooks[currency](x).bids[orderbook_idx].price
										- taker_orderbooks[currency](x).bids[1].price
									):abs()
									/ taker_orderbooks[currency](x).bids[1].price
							do
								max_order_size = max_order_size
									+ taker_orderbooks[currency](x).bids[orderbook_idx].quantity
								if orderbook_idx + 1 <= #taker_orderbooks[currency](x).bids then
									orderbook_idx = orderbook_idx + 1
								else
									break
								end
							end
							limit_price = taker_orderbooks[currency](x).bids[orderbook_idx].price
						else
							while
								max_taker_slippage[currency]
								>= (
										taker_orderbooks[currency](x).asks[1].price
										- taker_orderbooks[currency](x).asks[orderbook_idx].price
									):abs()
									/ taker_orderbooks[currency](x).asks[1].price
							do
								max_order_size = max_order_size
									+ taker_orderbooks[currency](x).asks[orderbook_idx].quantity
								if orderbook_idx + 1 <= #taker_orderbooks[currency](x).asks then
									orderbook_idx = orderbook_idx + 1
								else
									break
								end
							end
							limit_price = taker_orderbooks[currency](x).asks[orderbook_idx].price * decimal(1.03)
						end
						local net_position_sign = decimal(1)
						if -net_position < decimal(0) then
							net_position_sign = decimal(-1)
						end
						local params
						if order_params ~= nil then
							params = order_params[currency]
						end
						local taker_market = string.format("%s:%s/USDT", taker_market_types[currency], currency)
						local order = taker_exchanges[currency].limit_order(
							taker_market,
							(limit_price / taker_price_unit[currency]):round_to_decimals(0) * taker_price_unit[currency],
							(
								(net_position_sign * (net_position:abs()) / taker_quantity_unit[currency]):round_to_decimals(
									0
								) * taker_quantity_unit[currency]
							):min(
								(max_order_size / taker_quantity_unit[currency]):floor_to_decimals(0)
									* taker_quantity_unit[currency]
							),
							params
						)
						local success, ret = pcall(taker_exchanges[currency].cancel_order, taker_market, order)
						if not success then
							gh.debug("cannot cancel hedge order: " .. tostring(ret))
						end
						last_hedge[currency] = gh.millis()
						position_locked_since[currency] = gh.millis()
						position_unlockers[currency](x) -- XXX: to mitigate suspicious position unlock failure
					end
				end
			end
		end
		if position_error then
			if not ignore_hedge_safeguard then
				gh.error("position error occurred at initialization")
			else
				gh.warn("position error occurred at initialization, continuing(ignore_hedge_safeguard is on)")

				for currency in pairs(transposed_config) do
					position_confirmed[currency] = true
				end
			end
		end
	end)
end

return hedge
