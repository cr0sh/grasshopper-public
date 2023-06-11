local M = {}

-- Dumps an object into a string.
--
-- ref: https://stackoverflow.com/a/27028488
function M.dump(o)
	if type(o) == "table" then
		local s = "{ "
		for k, v in pairs(o) do
			if type(k) ~= "number" then
				k = '"' .. k .. '"'
			end
			s = s .. "[" .. k .. "] = " .. M.dump(v) .. ", "
		end
		return s .. "} "
	elseif type(o) == "string" then
		return '"' .. o .. '"'
	else
		return tostring(o)
	end
end

-- Build a (not escaped) x-www-urlencoded string from key-value entries.
function M.build_urlencoded(tbl)
	if tbl == nil then
		return ""
	end
	local s = ""
	for k, v in pairs(tbl) do
		if s == "" then
			s = s .. string.format("%s=%s", k, v)
		else
			s = s .. string.format("&%s=%s", k, v)
		end
	end
	return s
end

-- set default value(if unset) for every entry of defaultTbl to tbl.
function M.apply_default(tbl, default_tbl)
	local ret = {}
	if tbl == nil then
		tbl = {}
	end
	for k, v in pairs(default_tbl) do
		if tbl[k] == nil then
			ret[k] = v
		else
			ret[k] = tbl[k]
		end
	end
	return ret
end

-- Same as pcall, but logs a warning message to the host if fails
function M.pwcall(...)
	local success, ret = pcall(...)
	if not success then
		local success_, str = pcall(tostring, ret)
		if type(ret) ~= "table" and success_ then
			gh.warn("pwcall failed: " .. str)
		else
			gh.warn("pwcall failed: " .. M.dump(ret))
		end
	end
	return success, ret
end

local atexit_handler = 1

-- Registers an atexit handler which is ran when the program terminates.
-- Returns the key to be used in `remove_atexit`.
function M.atexit(fn)
	local key = tostring(atexit_handler)
	atexit[key] = fn
	atexit_handler = atexit_handler + 1
	return key
end

-- Removes the atexit handler registered by `atexit`.
function M.remove_atexit(key)
	atexit[key] = nil
end

-- Removes the (price, qty) order entry from the orderbook.
function M.remove_order(orderbook, price, quantity)
	local new_orderbook = { bids = {}, asks = {} }
	for _, bid in ipairs(orderbook.bids) do
		if bid.price == price then
			if bid.quantity > quantity then
				table.insert(new_orderbook.bids, { price = bid.price, quantity = bid.quantity - quantity })
			end
		else
			table.insert(new_orderbook.bids, { price = bid.price, quantity = bid.quantity })
		end
	end
	for _, ask in ipairs(orderbook.asks) do
		if ask.price == price then
			if ask.quantity > quantity then
				table.insert(new_orderbook.asks, { price = ask.price, quantity = ask.quantity - quantity })
			end
		else
			table.insert(new_orderbook.asks, { price = ask.price, quantity = ask.quantity })
		end
	end
	return new_orderbook
end

return M
