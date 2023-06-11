local util = require("util")

local M = {}

---@param orderbook Orderbook
---@param premium_fun fun(Decimal): Decimal
---@param premium_target Decimal
---@param price_unit Decimal
---@param force_maker boolean
function M.smart_price_bid(orderbook, premium_fun, premium_target, price_unit, force_maker)
	local price
	local function price_exists(test_price)
		for _, entry in ipairs(orderbook.bids) do
			if entry.price == test_price then
				return true
			end
		end
		return false
	end
	price = orderbook.bids[1].price + price_unit
	if force_maker then
		price = orderbook.bids[1].price
	end
	while premium_fun(price) < premium_target do
		price = price - price_unit
	end
	while not price_exists(price - price_unit) and price >= orderbook.bids[#orderbook.bids].price do
		price = price - price_unit
	end
	return price
end

---@param orderbook Orderbook
---@param premium_fun fun(Decimal): Decimal
---@param premium_target Decimal
---@param price_unit Decimal
---@param force_maker boolean
function M.smart_price_ask(orderbook, premium_fun, premium_target, price_unit, force_maker)
	local price
	local function price_exists(test_price)
		for _, entry in ipairs(orderbook.asks) do
			if entry.price == test_price then
				return true
			end
		end
		return false
	end
	price = orderbook.asks[1].price - price_unit
	if force_maker then
		price = orderbook.asks[1].price
	end
	while premium_fun(price) < premium_target do
		price = price + price_unit
	end
	while not price_exists(price + price_unit) and price <= orderbook.asks[#orderbook.asks].price do
		price = price + price_unit
	end
	return price
end

---@class OrderManager
local OrderManager = {}

---@param exchange Exchange
---@param market Market
---@return OrderManager
function OrderManager:new(exchange, market)
	local o = {}
	setmetatable(o, self)
	self.__index = self
	self.exchange = exchange
	self.market = market
	---@type {[string]: fun()}
	self.open_orders = {}
	---@type {[string]: fun()}
	self.pending_orders = {}
	self.orders_cleaned = false
	self.should_cancel = {}

	self.extractor = self.exchange.subscribe_orders(self.market)

	return o
end

---@return boolean
function OrderManager:is_pending()
	return #self.pending_orders > 0
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
		if self.pending_orders[order.id] ~= nil then
			self.open_orders[order.id] = self.pending_orders[order.id]
			self.pending_orders[order.id] = nil
			gh.debug(string.format("order %s is open", order.id))
		elseif self.should_cancel[order.id] ~= nil then
			gh.warn(string.format("cancelling stale order %s", order.id))
			util.pwcall(self.exchange.cancel_order, self.market, order)
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
				gh.debug(string.format("order %s filled", id))
				self.open_orders[id] = nil
				filled_hook()
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
			gh.debug(string.format("order %s canceled", id))
			self.should_cancel[id] = nil
		end
	end
end

---@param price Decimal
---@param amount Decimal
---@param filled_hook fun()|nil
---@return Order|nil
function OrderManager:limit_order(price, amount, filled_hook)
	local success, ret = util.pwcall(self.exchange.limit_order, self.market, price, amount)
	if not success then
		return nil
	end
	gh.debug(string.format("order %s is pending", ret.id))
	self.pending_orders[ret.id] = filled_hook or function() end
	return ret
end

---@param amount Decimal
---@param filled_hook fun()|nil
function OrderManager:market_order(amount, filled_hook)
	local success, _ = util.pwcall(self.exchange.market_order, self.market, amount)
	if not success then
		return
	end
	if filled_hook then
		filled_hook()
	end
end

---@param order Order
function OrderManager:cancel_order(order)
	self.should_cancel[order.id] = order
	local success, _ = util.pwcall(self.exchange.cancel_order, self.market, order)
	if success then
		self.open_orders[order.id] = nil
	end
end

M.OrderManager = OrderManager

return M
