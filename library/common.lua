local M = {}

---Splits given market identifier `market_type:base/quote` to parts.
---@param market string
---@return string
---@return string
---@return string
function M.parse_market(market)
	local market_type, base, quote = string.match(market, "(%w+):(%w+)/(%w+)")
	return base, quote, market_type
end

local function orderbook_eq(tbl1, tbl2)
	for i in ipairs(tbl1.bids) do
		if tbl1.bids[i].price ~= tbl2.bids[i].price then
			return false
		end
		if tbl1.bids[i].quantity ~= tbl2.bids[i].quantity then
			return false
		end
	end
	for i in ipairs(tbl1.asks) do
		if tbl1.asks[i].price ~= tbl2.asks[i].price then
			return false
		end
		if tbl1.asks[i].quantity ~= tbl2.asks[i].quantity then
			return false
		end
	end

	return true
end

---Wraps an `Orderbook` to provide essential functionalities.
---@param tbl Orderbook
---@return Orderbook
function M.wrap_orderbook(tbl)
	setmetatable(tbl, { __eq = orderbook_eq })
	return tbl
end

local function balance_eq(tbl1, tbl2)
	for k in pairs(tbl1) do
		if tbl1[k].free ~= tbl2[k].free then
			return false
		end
		if tbl1[k].locked ~= tbl2[k].locked then
			return false
		end
		if tbl1[k].total ~= tbl2[k].total then
			return false
		end
	end
	for k in pairs(tbl2) do
		if tbl1[k].free ~= tbl2[k].free then
			return false
		end
		if tbl1[k].locked ~= tbl2[k].locked then
			return false
		end
		if tbl1[k].total ~= tbl2[k].total then
			return false
		end
	end
	return true
end

---Wraps an `Balance` to provide essential functionalities.
---@param tbl Balance
---@return Balance
function M.wrap_balance(tbl)
	local tblcopy = {}
	for k, v in pairs(tbl) do
		tblcopy[k] = v
	end
	local function index_balance(_, key)
		if tblcopy[key] ~= nil then
			return tblcopy[key]
		else
			return { free = decimal(0), locked = decimal(0), total = decimal(0) }
		end
	end
	return setmetatable(tbl, { __index = index_balance, __eq = balance_eq })
end

local function position_eq(tbl1, tbl2)
	for k in pairs(tbl1) do
		if tbl1[k] ~= tbl2[k] then
			return false
		end
	end
	for k in pairs(tbl2) do
		if tbl1[k] ~= tbl2[k] then
			return false
		end
	end
	return true
end

---Wraps an `Position` to provide essential functionalities.
---@param tbl Position
---@return Position
function M.wrap_position(tbl)
	local tblcopy = {}
	for k, v in pairs(tbl) do
		tblcopy[k] = v
	end
	local function index_position(_, key)
		if tblcopy[key] ~= nil then
			return tblcopy[key]
		else
			return decimal(0)
		end
	end
	return setmetatable(tbl, { __index = index_position, __eq = position_eq })
end

local function orders_eq(tbl1, tbl2)
	for _, v in ipairs(tbl1) do
		local ok = false
		for _, vv in ipairs(tbl2) do
			if v.id == vv.id then
				ok = true
				break
			end
		end
		if not ok then
			return false
		end
	end
	for _, v in ipairs(tbl2) do
		local ok = false
		for _, vv in ipairs(tbl1) do
			if v.id == vv.id then
				ok = true
				break
			end
		end
		if not ok then
			return false
		end
	end
	return true
end

---Wraps an `Order[]` array to provide essential functionalities.
---@param tbl Order[]
---@return Order[]
function M.wrap_orders(tbl)
	setmetatable(tbl, { __eq = orders_eq })
	return tbl
end

return M
