local gh = require("gh")
local timer = require("timer")
local context = require("context")
local M = {}

---@param payload table
function M.send(payload)
	local token = gh._send(payload)
	timer.pause()
	local ret = context.yield(function(ev)
		if ev.kind == "send_response" and ev.token == token then
			return ev.response_payload
		end
	end)
	timer.resume()
	if ret.error then
		error(string.format("send to %s failed: status %s, content %s", payload.url, ret.status, ret.content), 2)
	end
	return ret
end

return M
