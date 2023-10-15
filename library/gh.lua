local ffi = require("ffi")
local json = require("json")

---@type any
local gh = {}

local M = {}

---@class ResponsePayload
---@field url string
---@field content string
---@field status number
---@field error boolean
---@field restart boolean
---@field terminate boolean
---@class Event
---@field kind string
---@field response_payload ResponsePayload
---@field token ffi.cdata*

function M.cdef()
	ffi.cdef([[
        typedef struct {
            const uint8_t *url_ptr;
            size_t url_len;
            size_t url_cap;
            const uint8_t *content_ptr;
            size_t content_len;
            size_t content_cap;
            uint16_t status;
            bool error;
            bool restart;
            bool terminate;
        } ResponsePayload;

        typedef struct {
            const uint8_t *kind_ptr;
            size_t kind_len;
            size_t kind_cap;
            const ResponsePayload *_response_payload;
            uint64_t token;
        } Event;

        typedef struct {
            const uint8_t *ptr;
            size_t len;
        } LuaStr;

        void subscribe_rest_events(LuaStr, double);
        Event next_event(void);
        void free_event(Event);
        uint64_t send_payload(LuaStr);
        uint8_t* list_strategies(void);
        const ResponsePayload* get_response_payload(Event);
        void free_response_payload(const ResponsePayload*);

        void initialize(void);
        void deinitialize(void);
        void reset_metrics(LuaStr);

        void set_script_name(LuaStr);
        void trace(LuaStr);
        void debug(LuaStr);
        void info(LuaStr);
        void warn(LuaStr);
        void error(LuaStr);
        void notice(LuaStr);
        void emergency(LuaStr);
    ]])
end

---@param payload table
---@param period_ms number
function M._subscribe(payload, period_ms)
	local s = json.encode(payload)
	gh.subscribe_rest_events({ ptr = s, len = #s }, period_ms)
end

---@return Event
function M.next_event()
	---@diagnostic disable-next-line
	return ffi.gc(gh.next_event(), gh.free_event)
end

---@param ev Event
function M.free_event(ev)
	return gh.free_event(ev)
end

---@return ffi.cdata*
function M._send(payload)
	local s = json.encode(payload)
	return gh.send_payload({ ptr = s, len = #s })
end

function M.list_strategies()
	local s = gh.list_strategies()
	local ss = ffi.string(s)
	gh.free_string(s)
	return json.decode(ss)
end

function M.initialize()
	gh.initialize()
end

function M.deinitialize()
	gh.deinitialize()
end

function M.reset_metrics(strategy_name)
	gh.reset_metrics({ ptr = strategy_name, len = #strategy_name })
end

---@param name string
function M.set_script_name(name)
	gh.set_script_name({ ptr = name, len = #name })
end

---@param message string
function M.trace(message)
	gh.trace({ ptr = message, len = #message })
end

---@param message string
function M.debug(message)
	gh.debug({ ptr = message, len = #message })
end

---@param message string
function M.info(message)
	gh.info({ ptr = message, len = #message })
end

---@param message string
function M.warn(message)
	gh.warn({ ptr = message, len = #message })
end

---@param message string
function M.error(message)
	gh.error({ ptr = message, len = #message })
end

---@param message string
function M.notice(message)
	gh.notice({ ptr = message, len = #message })
end

---@param message string
function M.emergency(message)
	gh.emergency({ ptr = message, len = #message })
end

---@return Decimal
function M.millis()
	return gh.millis()
end

---@param strategy_name string
---@param elapsed Decimal
---@param wall_elapsed Decimal
function M.report_timings(strategy_name, elapsed, wall_elapsed)
	gh.report_timings({ ptr = strategy_name, len = #strategy_name }, elapsed, wall_elapsed)
end

function M.set_clib(x)
	gh = x
	ffi.metatype("Event", {
		__index = function(self, key)
			if key == "kind" then
				return ffi.string(self.kind_ptr, self.kind_len)
			elseif key == "response_payload" then
				return ffi.gc(gh.get_response_payload(self), gh.free_response_payload)
			end
		end,
	})
	ffi.metatype("ResponsePayload", {
		__index = function(self, key)
			if key == "url" then
				if self.url_ptr ~= nil then
					return ffi.string(self.url_ptr, self.url_len)
				else
					return ""
				end
			elseif key == "content" then
				if self.content_ptr ~= nil then
					return ffi.string(self.content_ptr, self.content_len)
				else
					return ""
				end
			end
		end,
	})
end

return M
