-- https://github.com/actboy168/json.lua/blob/bd7b7787bb8b586e59b5afe5886dd1b76c86eb56/json.lua
-- MIT License
--
-- Copyright (c) 2020 actboy168
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

local type = type
local next = next
local error = error
local tonumber = tonumber
local tostring = tostring
local table_concat = table.concat
local table_sort = table.sort
local string_char = string.char
local string_byte = string.byte
local string_find = string.find
local string_match = string.match
local string_gsub = string.gsub
local string_sub = string.sub
local string_format = string.format
local setmetatable = setmetatable
local getmetatable = getmetatable
local huge = math.huge
local tiny = -huge

local utf8_char
local math_type

if _VERSION == "Lua 5.1" or _VERSION == "Lua 5.2" then
	local math_floor = math.floor
	function utf8_char(c)
		if c <= 0x7f then
			return string_char(c)
		elseif c <= 0x7ff then
			return string_char(math_floor(c / 64) + 192, c % 64 + 128)
		elseif c <= 0xffff then
			return string_char(math_floor(c / 4096) + 224, math_floor(c % 4096 / 64) + 128, c % 64 + 128)
		elseif c <= 0x10ffff then
			return string_char(
				math_floor(c / 262144) + 240,
				math_floor(c % 262144 / 4096) + 128,
				math_floor(c % 4096 / 64) + 128,
				c % 64 + 128
			)
		end
		error(string_format("invalid UTF-8 code '%x'", c))
	end

	function math_type(v)
		if v >= -2147483648 and v <= 2147483647 and math_floor(v) == v then
			return "integer"
		end
		return "float"
	end
else
	---@diagnostic disable-next-line
	utf8_char = utf8.char
	math_type = math.type
end

local json = {}

json.supportSparseArray = true

local objectMt = {}

function json.createEmptyObject()
	return setmetatable({}, objectMt)
end

function json.isObject(t)
	if t[1] ~= nil then
		return false
	end
	return next(t) ~= nil or getmetatable(t) == objectMt
end

if debug and debug.upvalueid then
	-- Generate a lightuserdata
	json.null = debug.upvalueid(json.createEmptyObject, 1)
else
	json.null = function() end
end

-- json.encode --
local statusVisited
local statusBuilder

local encode_map = {}

local encode_escape_map = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["/"] = "\\/",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local decode_escape_set = {}
local decode_escape_map = {}
for k, v in next, encode_escape_map do
	decode_escape_map[v] = k
	decode_escape_set[string_byte(v, 2)] = true
end

for i = 0, 31 do
	local c = string_char(i)
	if not encode_escape_map[c] then
		encode_escape_map[c] = string_format("\\u%04x", i)
	end
end

local function encode(v)
	local res = encode_map[type(v)](v)
	statusBuilder[#statusBuilder + 1] = res
end

encode_map["nil"] = function()
	return "null"
end

local function encode_string(v)
	return string_gsub(v, '[%z\1-\31\\"]', encode_escape_map)
end

function encode_map.string(v)
	statusBuilder[#statusBuilder + 1] = '"'
	statusBuilder[#statusBuilder + 1] = encode_string(v)
	return '"'
end

function encode_map.cdata(v)
	statusBuilder[#statusBuilder + 1] = '"'
	statusBuilder[#statusBuilder + 1] = encode_string(tostring(v))
	return '"'
end

local function convertreal(v)
	local g = string_format("%.16g", v)
	if tonumber(g) == v then
		return g
	end
	return string_format("%.17g", v)
end

if string_match(tostring(1 / 2), "%p") == "," then
	local _convertreal = convertreal
	function convertreal(v)
		return string_gsub(_convertreal(v), ",", ".")
	end
end

function encode_map.number(v)
	if v ~= v or v <= tiny or v >= huge then
		error("unexpected number value '" .. tostring(v) .. "'")
	end
	if math_type(v) == "integer" then
		return string_format("%d", v)
	end
	return convertreal(v)
end

function encode_map.boolean(v)
	if v then
		return "true"
	else
		return "false"
	end
end

function encode_map.table(t)
	local first_val = next(t)
	if first_val == nil then
		if getmetatable(t) == objectMt then
			return "{}"
		else
			return "[]"
		end
	end
	if statusVisited[t] then
		error("circular reference")
	end
	statusVisited[t] = true
	if type(first_val) == "string" then
		local keys = {}
		for k in next, t do
			if type(k) ~= "string" then
				error("invalid table: mixed or invalid key types: " .. k)
			end
			keys[#keys + 1] = k
		end
		table_sort(keys)
		do
			local k = keys[1]
			statusBuilder[#statusBuilder + 1] = '{"'
			statusBuilder[#statusBuilder + 1] = encode_string(k)
			statusBuilder[#statusBuilder + 1] = '":'
			encode(t[k])
		end
		for i = 2, #keys do
			local k = keys[i]
			statusBuilder[#statusBuilder + 1] = ',"'
			statusBuilder[#statusBuilder + 1] = encode_string(k)
			statusBuilder[#statusBuilder + 1] = '":'
			encode(t[k])
		end
		statusVisited[t] = nil
		return "}"
	elseif json.supportSparseArray then
		local max = 0
		for k in next, t do
			if math_type(k) ~= "integer" or k <= 0 then
				error("invalid table: mixed or invalid key types: " .. k)
			end
			if max < k then
				max = k
			end
		end
		statusBuilder[#statusBuilder + 1] = "["
		encode(t[1])
		for i = 2, max do
			statusBuilder[#statusBuilder + 1] = ","
			encode(t[i])
		end
		statusVisited[t] = nil
		return "]"
	else
		if t[1] == nil then
			error("invalid table: sparse array is not supported")
		end
		if jit and t[0] ~= nil then
			-- 0 is the first index in luajit
			error("invalid table: mixed or invalid key types: " .. 0)
		end
		statusBuilder[#statusBuilder + 1] = "["
		encode(t[1])
		local count = 2
		while t[count] ~= nil do
			statusBuilder[#statusBuilder + 1] = ","
			encode(t[count])
			count = count + 1
		end
		if next(t, count - 1) ~= nil then
			local k = next(t, count - 1)
			if type(k) == "number" then
				error("invalid table: sparse array is not supported")
			else
				error("invalid table: mixed or invalid key types: " .. k)
			end
		end
		statusVisited[t] = nil
		return "]"
	end
end

local function encode_unexpected(v)
	if v == json.null then
		return "null"
	else
		error("unexpected type '" .. type(v) .. "'")
	end
end
encode_map["function"] = encode_unexpected
encode_map["userdata"] = encode_unexpected
encode_map["thread"] = encode_unexpected

function json.encode(v)
	statusVisited = {}
	statusBuilder = {}
	encode(v)
	return table_concat(statusBuilder)
end

json._encode_map = encode_map
json._encode_string = encode_string

-- json.decode --

local statusBuf
local statusPos
local statusTop
local statusAry = {}
local statusRef = {}

local function find_line()
	local line = 1
	local pos = 1
	while true do
		local f, _, nl1, nl2 = string_find(statusBuf, "([\n\r])([\n\r]?)", pos)
		if not f then
			return line, statusPos - pos + 1
		end
		local newpos = f + ((nl1 == nl2 or nl2 == "") and 1 or 2)
		if newpos > statusPos then
			return line, statusPos - pos + 1
		end
		pos = newpos
		line = line + 1
	end
end

local function decode_error(msg)
	error(string_format("ERROR: %s at line %d col %d", msg, find_line()), 2)
end

local function get_word()
	return string_match(statusBuf, "^[^ \t\r\n%]},]*", statusPos)
end

local function next_byte()
	local pos = string_find(statusBuf, "[^ \t\r\n]", statusPos)
	if pos then
		statusPos = pos
		return string_byte(statusBuf, pos)
	end
	return -1
end

local function consume_byte(c)
	local _, pos = string_find(statusBuf, c, statusPos)
	if pos then
		statusPos = pos + 1
		return true
	end
end

local function expect_byte(c)
	local _, pos = string_find(statusBuf, c, statusPos)
	if not pos then
		decode_error(string_format("expected '%s'", string_sub(c, #c)))
	end
	statusPos = pos
end

local function decode_unicode_surrogate(s1, s2)
	return utf8_char(0x10000 + (tonumber(s1, 16) - 0xd800) * 0x400 + (tonumber(s2, 16) - 0xdc00))
end

local function decode_unicode_escape(s)
	return utf8_char(tonumber(s, 16))
end

local function decode_string()
	local has_unicode_escape = false
	local has_escape = false
	local i = statusPos + 1
	while true do
		i = string_find(statusBuf, '[%z\1-\31\\"]', i)
		if not i then
			decode_error("expected closing quote for string")
		end
		local x = string_byte(statusBuf, i)
		if x < 32 then
			statusPos = i
			decode_error("control character in string")
		end
		if
			x == 34 --[[ '"' ]]
		then
			local s = string_sub(statusBuf, statusPos + 1, i - 1)
			if has_unicode_escape then
				s = string_gsub(
					string_gsub(s, "\\u([dD][89aAbB]%x%x)\\u([dD][c-fC-F]%x%x)", decode_unicode_surrogate),
					"\\u(%x%x%x%x)",
					decode_unicode_escape
				)
			end
			if has_escape then
				s = string_gsub(s, "\\.", decode_escape_map)
			end
			statusPos = i + 1
			return s
		end
		--assert(x == 92 --[[ "\\" ]])
		local nx = string_byte(statusBuf, i + 1)
		if
			nx == 117 --[[ "u" ]]
		then
			if not string_match(statusBuf, "^%x%x%x%x", i + 2) then
				statusPos = i
				decode_error("invalid unicode escape in string")
			end
			has_unicode_escape = true
			i = i + 6
		else
			if not decode_escape_set[nx] then
				statusPos = i
				decode_error("invalid escape char '" .. (nx and string_char(nx) or "<eol>") .. "' in string")
			end
			has_escape = true
			i = i + 2
		end
	end
end

local function decode_number()
	local num, c = string_match(statusBuf, "^([0-9]+%.?[0-9]*)([eE]?)", statusPos)
	if
		not num or string_byte(num, -1) == 0x2E --[[ "." ]]
	then
		decode_error("invalid number '" .. get_word() .. "'")
	end
	if c ~= "" then
		num = string_match(statusBuf, "^([^eE]*[eE][-+]?[0-9]+)[ \t\r\n%]},]", statusPos)
		if not num then
			decode_error("invalid number '" .. get_word() .. "'")
		end
	end
	statusPos = statusPos + #num
	return tonumber(num)
end

local function decode_number_zero()
	local num, c = string_match(statusBuf, "^(.%.?[0-9]*)([eE]?)", statusPos)
	if
		not num
		or string_byte(num, -1) == 0x2E --[[ "." ]]
		or string_match(statusBuf, "^.[0-9]+", statusPos)
	then
		decode_error("invalid number '" .. get_word() .. "'")
	end
	if c ~= "" then
		num = string_match(statusBuf, "^([^eE]*[eE][-+]?[0-9]+)[ \t\r\n%]},]", statusPos)
		if not num then
			decode_error("invalid number '" .. get_word() .. "'")
		end
	end
	statusPos = statusPos + #num
	return tonumber(num)
end

local function decode_number_negative()
	statusPos = statusPos + 1
	local c = string_byte(statusBuf, statusPos)
	if c then
		if c == 0x30 then
			return -decode_number_zero()
		elseif c > 0x30 and c < 0x3A then
			return -decode_number()
		end
	end
	decode_error("invalid number '" .. get_word() .. "'")
end

local function decode_true()
	if string_sub(statusBuf, statusPos, statusPos + 3) ~= "true" then
		decode_error("invalid literal '" .. get_word() .. "'")
	end
	statusPos = statusPos + 4
	return true
end

local function decode_false()
	if string_sub(statusBuf, statusPos, statusPos + 4) ~= "false" then
		decode_error("invalid literal '" .. get_word() .. "'")
	end
	statusPos = statusPos + 5
	return false
end

local function decode_null()
	if string_sub(statusBuf, statusPos, statusPos + 3) ~= "null" then
		decode_error("invalid literal '" .. get_word() .. "'")
	end
	statusPos = statusPos + 4
	return json.null
end

local function decode_array()
	statusPos = statusPos + 1
	if consume_byte("^[ \t\r\n]*%]") then
		return {}
	end
	local res = {}
	statusTop = statusTop + 1
	statusAry[statusTop] = true
	statusRef[statusTop] = res
	return res
end

local function decode_object()
	statusPos = statusPos + 1
	if consume_byte("^[ \t\r\n]*}") then
		return json.createEmptyObject()
	end
	local res = {}
	statusTop = statusTop + 1
	statusAry[statusTop] = false
	statusRef[statusTop] = res
	return res
end

local decode_uncompleted_map = {
	[string_byte('"')] = decode_string,
	[string_byte("0")] = decode_number_zero,
	[string_byte("1")] = decode_number,
	[string_byte("2")] = decode_number,
	[string_byte("3")] = decode_number,
	[string_byte("4")] = decode_number,
	[string_byte("5")] = decode_number,
	[string_byte("6")] = decode_number,
	[string_byte("7")] = decode_number,
	[string_byte("8")] = decode_number,
	[string_byte("9")] = decode_number,
	[string_byte("-")] = decode_number_negative,
	[string_byte("t")] = decode_true,
	[string_byte("f")] = decode_false,
	[string_byte("n")] = decode_null,
	[string_byte("[")] = decode_array,
	[string_byte("{")] = decode_object,
}
local function unexpected_character()
	decode_error("unexpected character '" .. string_sub(statusBuf, statusPos, statusPos) .. "'")
end
local function unexpected_eol()
	decode_error("unexpected character '<eol>'")
end

local decode_map = {}
for i = 0, 255 do
	decode_map[i] = decode_uncompleted_map[i] or unexpected_character
end
decode_map[-1] = unexpected_eol

local function decode()
	return decode_map[next_byte()]()
end

local function decode_item()
	local top = statusTop
	local ref = statusRef[top]
	if statusAry[top] then
		ref[#ref + 1] = decode()
	else
		expect_byte('^[ \t\r\n]*"')
		local key = decode_string()
		expect_byte("^[ \t\r\n]*:")
		statusPos = statusPos + 1
		ref[key] = decode()
	end
	if top == statusTop then
		repeat
			local chr = next_byte()
			statusPos = statusPos + 1
			if
				chr == 44 --[[ "," ]]
			then
				return
			end
			if statusAry[statusTop] then
				if
					chr ~= 93 --[[ "]" ]]
				then
					decode_error("expected ']' or ','")
				end
			else
				if
					chr ~= 125 --[[ "}" ]]
				then
					decode_error("expected '}' or ','")
				end
			end
			statusTop = statusTop - 1
		until statusTop == 0
	end
end

function json.decode(str)
	if type(str) ~= "string" then
		error("expected argument of type string, got " .. type(str))
	end
	statusBuf = str
	statusPos = 1
	statusTop = 0
	local res = decode()
	while statusTop > 0 do
		decode_item()
	end
	if string_find(statusBuf, "[^ \t\r\n]", statusPos) then
		decode_error("trailing garbage")
	end
	return res
end

return json
