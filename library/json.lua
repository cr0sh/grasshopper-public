local ffi = require("ffi")
local json_external = require("json_external")

local M = {}

---@param x string
---@return any
function M.decode(x)
	return json_external.decode(x)
end

---@param x any
---@return string
function M.encode(x)
	return json_external.encode(x)
end

return M
