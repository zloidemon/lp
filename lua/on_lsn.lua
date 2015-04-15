local fiber = require 'fiber'
local triggers = {}

local last_log_time = 0
local log_min_delay = 1
local watch_period  = .1

local last_lsn = box.info.lsn

box.on_change_lsn = function(cb)
    table.insert(triggers, cb)
end


local function log(m, force)
    if force == nil or not force then
        if fiber.time() - last_log_time < log_min_delay then
            return
        end
    end
    last_log_time = fiber.time()
    print(e)
end


local function watcher()
    local ifiber = fiber.self()
    ifiber:name("on_lsn")
    print('Start fiber')

    while true do
        box.fiber.sleep(watch_period)
        if box.info.server.lsn ~= last_lsn then
            last_lsn = box.info.server.lsn

            for i, cb in pairs(triggers) do

                local s, e = pcall(cb, last_lsn)
                if not s then
                    log(e)
                end
            end
        end
    end
end


fiber.create(watcher)

return { on_change_lsn = box.on_change_lsn }
