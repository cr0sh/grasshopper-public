local ffi = require("ffi")
local json_external = require("json_external")

---@type any
local gh = {}

local M = {}

function M.cdef()
	ffi.cdef([[
        typedef struct {
            void *key;
            void *value;
        } LazyValueObjectPair;

        void* decode(LuaStr);
        uint8_t kind(const void*);
        bool as_bool(const void*);
        double as_number(const void*);
        char* as_string(const void*);
        void free_string(char*);
        void* get_array_element(const void*, uint32_t);
        uint32_t get_array_length(const void*);
        bool has_object_element(const void*, const char*, uint32_t);
        void* get_object_element(const void*, const char*, uint32_t);
        uint32_t get_object_length(const void*);
        void free_value(void*);
        void* iter_elements(const void*);
        void debug_print(const void*);
        bool has_next(void*);
        LazyValueObjectPair* next_pair(void*);
        void free_iterator(void*);
        void* pair_value(LazyValueObjectPair*);
        void free_pair(LazyValueObjectPair*);
    ]])
end

function M.set_clib(x)
	gh = x
end

local function value_to_primitive(value)
	local kind = tonumber(gh.kind(value))
	if kind == 0 then -- null
		return nil
	elseif kind == 1 then -- bool
		return gh.as_bool(value)
	elseif kind == 2 then -- number
		return gh.as_number(value)
	elseif kind == 3 then -- string
		local cs = gh.as_string(value)
		local s = ffi.string(cs)
		gh.free_string(cs)
		return s
	elseif kind == 4 then -- array
		local len = tonumber(gh.get_array_length(value))
		assert(len ~= nil)
		return setmetatable({}, {
			__len = function()
				return len
			end,
			__index = function(_, idx)
				if type(idx) ~= "number" then
					return nil
				end
				if idx <= 0 or idx > len then
					error(string.format("array out of bounds: length is %s but index is %s", #value, idx), 2)
				end
				---@diagnostic disable-next-line
				return value_to_primitive(ffi.gc(gh.get_array_element(value, idx - 1), gh.free_value))
			end,
			__newindex = function()
				error("cannot set value on this array", 2)
			end,
			__ipairs = function(_)
				local idx = 1
				return function()
					if idx <= len then
						---@diagnostic disable-next-line
						local v = value_to_primitive(ffi.gc(gh.get_array_element(value, idx - 1), gh.free_value))
						local idx_ = idx
						idx = idx + 1
						return idx_, v
					else
						return nil
					end
				end
			end,
		})
	elseif kind == 5 then -- object
		local len = tonumber(gh.get_object_length(value))
		assert(len ~= nil)
		return setmetatable({}, {
			__len = function()
				return len
			end,
			__index = function(_, idx)
				if type(idx) ~= "string" then
					return nil
				end
				if not gh.has_object_element(value, idx, #idx) then
					return nil
				end
				---@diagnostic disable-next-line
				local value = ffi.gc(gh.get_object_element(value, idx, #idx), gh.free_value)
				local x = value_to_primitive(value)
				return x
			end,
			__pairs = function(_)
				---@diagnostic disable
				local iter = ffi.gc(gh.iter_elements(value), gh.free_iterator)
				return function()
					if not gh.has_next(iter) then
						return nil
					end
					local pair = ffi.gc(gh.next_pair(iter), gh.free_pair)
					local key = gh.as_string(pair.key)
					local keystring = ffi.string(key)
					gh.free_string(key)
					local value = value_to_primitive(ffi.gc(gh.pair_value(pair), gh.free_value))
					return keystring, value
				end
			end,
			__newindex = function()
				error("cannot set value on this object", 2)
			end,
		})
	else
		error("unknown kind " .. tostring(kind))
	end
end

---@param x string
---@return any
function M.decode(x)
	---@diagnostic disable-next-line
	return value_to_primitive(ffi.gc(ffi.cast("void*", gh.decode({ ptr = x, len = #x })), gh.free_value), x)
end

---@param x any
---@return string
function M.encode(x)
	return json_external.encode(x)
end

return M
