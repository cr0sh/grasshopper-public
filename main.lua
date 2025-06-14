#!/usr/bin/env ./gh_wrapper

package.path = package.path .. ";library/?.lua;scripts/?.lua"

local ffi = require("ffi")
local gh = require("gh")
local decimal = require("decimal")
local executor = require("executor")

gh.cdef()
decimal.cdef()

local grasshopper = ffi.load("grasshopper")

gh.set_clib(grasshopper)
decimal.set_clib(grasshopper)

gh.initialize()

require("test")

local sigint = false

local success, err = xpcall(executor.event_loop, function(e)
	if e == executor.interrupts.terminate then
		sigint = true
	end
	print(debug.traceback())
	return e
end)
if success then
	if err == executor.interrupts.terminate then
		sigint = true
	end
else
	if err == executor.interrupts.terminate then
		sigint = true
	elseif err ~= executor.interrupts.restart then
		local errstr = tostring(err)
		if string.sub(errstr, #errstr - #"interrupted!" + 1, #errstr) == "interrupted!" then
			gh.debug("got interrupt signal")
			sigint = true
		else
			gh.error(errstr)
		end
	end
end

executor.clear_strategies()
gh.deinitialize()
if sigint then
	os.exit(130)
end
