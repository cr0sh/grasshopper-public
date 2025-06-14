local ffi = require("ffi")

---@type any
local gh = {}

---@type fun(x: number|string): Decimal
local M = {}

function M.cdef()
	ffi.cdef([[
        typedef struct {
            uint8_t raw[16];
        } decimal_t;

        decimal_t decimal_from_string(const uint8_t*, uint32_t len);
        uint8_t* decimal_to_string(decimal_t);
        decimal_t decimal_add(decimal_t, decimal_t);
        decimal_t decimal_sub(decimal_t, decimal_t);
        decimal_t decimal_mul(decimal_t, decimal_t);
        decimal_t decimal_div(decimal_t, decimal_t);
        decimal_t decimal_mod(decimal_t, decimal_t);
        decimal_t decimal_pow(decimal_t, decimal_t);
        decimal_t decimal_unm(decimal_t);
        bool decimal_eq(decimal_t, decimal_t);
        bool decimal_lt(decimal_t, decimal_t);
        bool decimal_le(decimal_t, decimal_t);
        decimal_t decimal_abs(decimal_t);
        decimal_t decimal_ceil_to_decimals(decimal_t, int32_t);
        decimal_t decimal_floor_to_decimals(decimal_t, int32_t);
        decimal_t decimal_round_to_decimals(decimal_t, int32_t);
        decimal_t decimal_max(decimal_t, decimal_t);
        decimal_t decimal_min(decimal_t, decimal_t);

        decimal_t millis(void);
        void report_timings(LuaStr, decimal_t, decimal_t);

        void free_string(char*);
    ]])
end

function M.set_clib(clib)
	gh = clib

	ffi.metatype("decimal_t", {
		__add = gh.decimal_add,
		__sub = gh.decimal_sub,
		__mul = gh.decimal_mul,
		__div = gh.decimal_div,
		__mod = gh.decimal_mod,
		__pow = gh.decimal_pow,
		__unm = function(x)
			return gh.decimal_unm(x)
		end,
		__eq = function(self, x)
			if type(x) ~= "cdata" then
				return false
			else
				return gh.decimal_eq(self, x)
			end
		end,
		__lt = gh.decimal_lt,
		__le = gh.decimal_le,
		__tostring = function(self)
			local ptr = gh.decimal_to_string(self)
			local s = ffi.string(ptr)
			gh.free_string(ptr)
			return s
		end,
		__index = {
			abs = gh.decimal_abs,
			ceil_to_decimals = gh.decimal_ceil_to_decimals,
			floor_to_decimals = gh.decimal_floor_to_decimals,
			round_to_decimals = gh.decimal_round_to_decimals,
			max = gh.decimal_max,
			min = gh.decimal_min,
		},
		__newindex = function()
			error("field assignment not allowed in decimals", 2)
		end,
		__call = function()
			error("function call not allowed in decimals", 2)
		end,
	})
end

---@diagnostic disable-next-line
setmetatable(M, {
	__call = function(_, x)
		if x == 0 then
			return ffi.new("decimal_t")
		end
		local value
		if type(x) == "number" then
			x = tostring(x)
			value = gh.decimal_from_string(x, #x)
		elseif type(x) == "string" then
			value = gh.decimal_from_string(x, #x)
		else
			error("unsupported type " .. type(x) .. " for decimal constructor", 1)
		end

		return value
	end,
})

return M
