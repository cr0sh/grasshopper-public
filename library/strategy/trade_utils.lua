local gh = require("gh")
local util = require("util")
local decimal = require("decimal")

local M = {}

local function price_exists(orderbook_units, test_price)
	for _, entry in ipairs(orderbook_units) do
		if entry.price == test_price then
			return true
		end
	end
	return false
end

M.upbit_stoppers = {
	{ decimal("0.1"), decimal("0.0001") },
	{ decimal("1"), decimal("0.001") },
	{ decimal("10"), decimal("0.01") },
	{ decimal("100"), decimal("1") },
	{ decimal("1000"), decimal("1") },
	{ decimal("10000"), decimal("5") },
	{ decimal("100000"), decimal("10") },
	{ decimal("500000"), decimal("50") },
	{ decimal("1000000"), decimal("100") },
	{ decimal("2000000"), decimal("500") },
	{ decimal("9999999999"), decimal("1000") },
}

M.bithumb_stoppers = {
	{ decimal("1"), decimal("0.001") },
	{ decimal("10"), decimal("0.01") },
	{ decimal("100"), decimal("1") },
	-- { decimal("5000"), decimal("1") },
	{ decimal("10000"), decimal("5") },
	{ decimal("50000"), decimal("10") },
	{ decimal("100000"), decimal("50") },
	{ decimal("500000"), decimal("100") },
	{ decimal("1000000"), decimal("500") },
	{ decimal("9999999999"), decimal("1000") },
}

---@param stoppers Decimal[][]
---@param price Decimal
---@param stop_on_equal boolean
---@return Decimal
function M.krw_price_unit(stoppers, price, stop_on_equal)
	for _, v in ipairs(stoppers) do
		local upper, unit = unpack(v)
		if price < upper or price == upper and stop_on_equal then
			return unit
		end
	end
	error("no suitable stopper found, price " .. tostring(price) .. " too big")
end

---@param orderbook Orderbook
---@param premium_fun fun(Decimal): Decimal
---@param premium_target Decimal
---@param price_unit Decimal
---@param force_maker boolean
---@param is_upbit boolean | nil
---@param is_bithumb boolean | nil
function M.smart_price_bid(
	orderbook,
	premium_fun,
	premium_target,
	price_unit,
	force_maker,
	is_upbit,
	is_bithumb,
	search_price_unit
)
	if search_price_unit == nil then
		search_price_unit = price_unit
	end
	local price
	if #orderbook.asks >= 50 then
		-- NOTE: some exchanges accept outlier prices, so filter them
		price = orderbook.asks[math.floor(#orderbook.asks * 0.9)].price:min(orderbook.asks[1].price * decimal(2))
	else
		price = orderbook.asks[#orderbook.asks].price
	end
	if force_maker then
		if is_upbit then
			price_unit = M.krw_price_unit(M.upbit_stoppers, price, true)
		elseif is_bithumb then
			price_unit = M.krw_price_unit(M.bithumb_stoppers, price, true)
		end
		if orderbook.asks[1].price > orderbook.bids[1].price + price_unit then
			price = orderbook.bids[1].price + price_unit
		else
			price = orderbook.bids[1].price
		end
	end
	while premium_fun(price) < premium_target do
		if is_upbit then
			price_unit = M.krw_price_unit(M.upbit_stoppers, price, true)
		elseif is_bithumb then
			price_unit = M.krw_price_unit(M.bithumb_stoppers, price, true)
		end
		price = price - search_price_unit
	end
	if price < orderbook.asks[1].price then
		-- optimize maker price
		for _, entry in ipairs(orderbook.bids) do
			if entry.price < price then
				return entry.price + price_unit
			elseif entry.price == price then
				return price
			end
		end
	end
	return price
end

---@param orderbook Orderbook
---@param premium_fun fun(Decimal): Decimal
---@param premium_target Decimal
---@param price_unit Decimal
---@param force_maker boolean
---@param is_upbit boolean | nil
---@param is_bithumb boolean | nil
function M.smart_price_ask(
	orderbook,
	premium_fun,
	premium_target,
	price_unit,
	force_maker,
	is_upbit,
	is_bithumb,
	search_price_unit
)
	if search_price_unit == nil then
		search_price_unit = price_unit
	end
	local price
	if #orderbook.bids >= 50 then
		-- NOTE: some exchanges accept outlier prices, so filter them
		price = orderbook.bids[math.floor(#orderbook.bids * 0.9)].price:max(orderbook.bids[1].price / decimal(2))
	else
		price = orderbook.bids[#orderbook.bids].price
	end
	if force_maker then
		if is_upbit then
			price_unit = M.krw_price_unit(M.upbit_stoppers, price, false)
		elseif is_bithumb then
			price_unit = M.krw_price_unit(M.bithumb_stoppers, price, false)
		end
		if orderbook.bids[1].price < orderbook.asks[1].price - price_unit then
			price = orderbook.asks[1].price - price_unit
		else
			price = orderbook.asks[1].price
		end
	end
	while premium_fun(price) < premium_target do
		if is_upbit then
			price_unit = M.krw_price_unit(M.upbit_stoppers, price, false)
		elseif is_bithumb then
			price_unit = M.krw_price_unit(M.bithumb_stoppers, price, false)
		end
		price = price + search_price_unit
	end
	if price > orderbook.bids[1].price then
		-- optimize maker price
		for _, entry in ipairs(orderbook.asks) do
			if entry.price > price then
				return entry.price - price_unit
			elseif entry.price == price then
				return price
			end
		end
	end
	return price
end

---@param exchange Exchange
---@param market_type string
---@param currency string
---@return Extractor<Decimal>
function M.subscribe_effective_position(exchange, market_type, currency)
	if market_type == "spot" then
		local subscription = exchange.subscribe_balance(market_type)
		return function(x)
			local balance = subscription(x)[currency]
			if balance.debt ~= nil then
				return balance.total - balance.debt
			else
				return balance.total
			end
		end
	elseif market_type == "swap" then
		local subscription = exchange.subscribe_position("swap")
		return function(x)
			return subscription(x)[currency .. "USDT"]
		end
	else
		error("unsupported market type " .. market_type)
	end
end

---@class OrderManager
local OrderManager = {}

---@param exchange Exchange
---@param market Market
---@param orders_params any
---@param force_stale_side "bid"|"ask"|nil
---@param silent boolean|nil
---@return OrderManager
function OrderManager:new(exchange, market, orders_params, force_stale_side, silent)
	local o = {}
	setmetatable(o, self)
	self.__index = self
	o.exchange = exchange
	o.market = market
	---@type {[string]: table}
	o.open_orders = {}
	---@type {[string]: table}
	o.pending_orders = {}
	o.orders_cleaned = false
	o.should_cancel = {}
	o.force_stale_side = force_stale_side
	o.silent = silent

	o.extractor = o.exchange.subscribe_orders(o.market, orders_params)

	return o
end

---@diagnostic disable

---@return boolean
function OrderManager:is_pending()
	for _, _ in pairs(self.pending_orders) do
		return true
	end
	return false
end

---@param order Order
---@return boolean
function OrderManager:is_timed_out(order)
	if self.pending_orders[order.id] == nil then
		return false
	end
	return gh.millis() - self.pending_orders[order.id][1] > decimal(1000)
end

---@param x table
function OrderManager:update(x, extractor)
	local orders = self.extractor(x)
	if not self.orders_cleaned then
		for _, order in ipairs(orders) do
			gh.warn("closing orphaned order " .. order.id)
			self:cancel_order(order)
		end
		self.orders_cleaned = true
	end

	if extractor ~= self.extractor then
		return
	end

	for _, order in ipairs(orders) do
		local force_match = self.force_stale_side == "ask" and order.amount < decimal(0)
			or self.force_stale_side == "bid" and order.amount > decimal(0)
		if self.pending_orders[order.id] ~= nil then
			self.open_orders[order.id] = self.pending_orders[order.id]
			self.pending_orders[order.id] = nil
			gh.debug(string.format("order %s is open", order.id))
		elseif self.should_cancel[order.id] ~= nil or force_match and self.open_orders[order.id] == nil then
			gh.warn(string.format("cancelling stale order %s", order.id))
			local success = util.pwcall(self.exchange.cancel_order, self.market, order)
			if success then
				self.should_cancel[order.id] = nil
			end
		end
	end

	for id, filled_hook in pairs(self.open_orders) do
		if self.pending_orders[id] == nil then
			local found = false
			for _, order in ipairs(orders) do
				if order.id == id then
					found = true
					break
				end
			end
			if not found then
				filled_hook[3] = filled_hook[3] - 1
				if filled_hook[3] == 0 then
					if not self.silent then
						gh.debug(string.format("order %s filled", id))
					end
					self.open_orders[id] = nil
					filled_hook[2]()
				end
			else
				filled_hook[3] = 5
			end
		end
	end

	for id in pairs(self.should_cancel) do
		local found = false
		for _, order in ipairs(orders) do
			if order.id == id then
				found = true
				break
			end
		end

		if not found then
			self.should_cancel[id] = self.should_cancel[id] - 1
			if self.should_cancel[id] == 0 then
				if not self.silent then
					gh.debug(string.format("order %s canceled", id))
				end
				self.should_cancel[id] = nil
			end
		end
	end
end

local function is_timeout(ret)
	return type(ret) == "userdata" and string.gmatch(tostring(ret), "[^\r\n]+")() == "timeout"
end

---@param price Decimal
---@param amount Decimal
---@param filled_hook fun()|nil
---@return Order|nil
function OrderManager:limit_order(price, amount, filled_hook, params)
	local success, ret
	if self.silent then
		success, ret = pcall(self.exchange.limit_order, self.market, price, amount, params)
	else
		success, ret = util.pwcall(self.exchange.limit_order, self.market, price, amount, params)
	end
	if not success then
		if is_timeout(ret) then
			gh.error("timed out while placing an order. Restarting")
			gh.restart()
		end
		return nil
	end
	if not self.silent then
		gh.debug(string.format("order %s is pending", ret.id))
	end
	self.pending_orders[ret.id] = { gh.millis(), filled_hook or function() end, 5 }
	return ret
end

---@param amount Decimal
---@param filled_hook fun()|nil
function OrderManager:market_order(amount, filled_hook)
	local success
	if self.silent then
		success, _ = pcall(self.exchange.market_order, self.market, amount)
	else
		success, _ = util.pwcall(self.exchange.market_order, self.market, amount)
	end
	if not success then
		return
	end
	if filled_hook then
		filled_hook()
	end
end

---@param order Order
function OrderManager:cancel_order(order, force_forget, silent)
	if not self.silent then
		gh.debug(string.format("cancelling order %s", order.id))
	end
	self.pending_orders[order.id] = nil
	self.should_cancel[order.id] = 10
	while true do
		local success, ret
		if silent then
			success, ret = pcall(self.exchange.cancel_order, self.market, order)
		else
			success, ret = util.pwcall(self.exchange.cancel_order, self.market, order)
		end
		if success then
			self.should_cancel[order.id] = nil
		end
		if success or force_forget then
			self.open_orders[order.id] = nil
		end
		if success or not is_timeout(ret) then
			return
		end
		gh.warn("could not cancel order, timeout occurred")
	end
end

M.OrderManager = OrderManager

return M
