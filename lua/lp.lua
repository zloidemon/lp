require 'on_lsn'
return {
    new = function(space, expire_timeout)
        -- constants
        local ID                = 0
        local TIME              = 1
        local KEY               = 2
        local DATA              = 3
        local EXPIRE_TIMEOUT    = 1800

        space = tonumber(space)
        if expire_timeout ~= nil then
            expire_timeout = tonumber(expire_timeout)
        else
            expire_timeout = EXPIRE_TIMEOUT
        end

        local self              = {}
        local chs               = {}    -- channels
        local pool_chs          = {}    -- channel_pool
        local waiters           = {}    -- waiters


        local _last_id = tonumber64(0)
        local last_id
        local last_checked_id = tonumber64(0)

        last_id = function()
            local max = box.space[space].index[0]:max()
            if max == nil then
                return _last_id
            end
            _last_id = box.unpack('l', max[ID])
            return _last_id
        end

        local function channel()
            if #pool_chs < 1024 then
                return box.ipc.channel(1)
            end
            local ch = table.remove(pool_chs, 1)
            if ch == nil then
                ch = box.ipc.channel(1)
            end
            return ch
        end
        local function drop_channel(id)
            if chs[id] == nil then
                return
            end
            table.insert(pool_chs, chs[id])
            chs[id] = nil
        end

        local function sprintf(fmt, ...) return string.format(fmt, ...) end
        local function printf(fmt, ...) print(sprintf(fmt, ...)) end

        local function _take(id, keys)

            id = box.pack('l', id)
            local res = {}

            for i, key in pairs(keys) do
                local iter = box.space[space].index[1]
                    :iterator(box.index.GE, key, id)

                for tuple in iter do
                    if tuple[KEY] ~= key then
                        break
                    end
                    table.insert(res, { box.unpack('l', tuple[ID]), tuple })
                end
            end
            table.sort(res, function(a, b) return a[1] < b[1] end)
            local result = {}

            for i, v in pairs(res) do
                table.insert(result, v[2])
            end

            return result
        end


        -- cleanup space iteration
        local function cleanup_space()

            local now = box.time()
            local count = 0
            while true do
                local iter = box.space[space].index[0]
                                :iterator(box.index.GE, box.pack('l', 0))
                local lst = {}
                for tuple in iter do
                    if box.unpack('i', tuple[TIME]) + expire_timeout > now then
                        break
                    end
                    table.insert(lst, tuple[ID])
                    if #lst >= 1000 then
                        break
                    end
                end

                if #lst == 0 then
                    break
                end

                for num, id in pairs(lst) do
                    box.delete(space, id)
                    count = count + 1
                end
            end
            return count
        end

        -- wakeup waiters
        local function wakeup_waiters(key)
            while waiters[key] ~= nil do
                local wlist = waiters[key]
                waiters[key] = nil
                -- wakeup waiters
                for fid in pairs(wlist) do
                    wlist[fid] = nil
                    if chs[fid] ~= nil then
                        local ch = chs[fid]
                        drop_channel(fid)
                        ch:put(true)
                    end
                end
            end
        end


        local function on_change_lsn(lsn)
            local tuple
            while last_checked_id < last_id() do
                last_checked_id = last_checked_id + tonumber64(1)
                tuple = box.select(space, 0, box.pack('l', last_checked_id))
                if tuple ~= nil then
                    wakeup_waiters(tuple[KEY])
                end
            end
        end

        box.on_change_lsn(on_change_lsn)

        local function put_task(key, data)

            local time = box.pack('i', math.floor(box.time()))

            local task
            if data ~= nil then
                task = box.insert(space,
                    box.pack('l', last_id() + 1), time, key, data)
            else
                task = box.insert(space, box.pack('l', last_id() + 1), time, key)
            end

            return task
        end

        -- put task
        self.push = function(key, data)
            return put_task(key, data)
        end

        -- put some tasks
        self.push_list = function(...)
            local put = {...}
            local i = 1
            local count = 0
            while i <= #put do
                local key = put[ i ]
                local data = put[ i + 1 ]
                i = i + 2
                count = count + 1
                put_task(key, data)
            end

            return box.pack('l', count)
        end

        -- subscribe tasks
        self.subscribe = function(id, timeout, ...)
            local keys = {...}

            id = tonumber64(id)

            if id == tonumber64(0) then
                id = last_id() + tonumber64(1)
                id = tonumber64(id)
            end

            local events = _take(id, keys)

            if #events > 0 then
                table.insert(
                    events,
                    box.tuple.new{ box.pack('l', last_id() + tonumber64(1)) }
                )
                return events
            end

            timeout = tonumber(timeout)
            local started
            local fid = box.fiber.self():id()

            while timeout > 0 do
                started = box.time()

                -- set waiter fid
                for i, key in pairs(keys) do
                    if waiters[key] == nil then
                        waiters[key] = {}
                    end
                    waiters[key][fid] = true
                end

                chs[ fid ] = channel()
                if chs[ fid ]:get(timeout) == nil then
                    -- drop channel if nobody puts into
                    drop_channel(fid)
                end

                -- clean waiter fid
                for i, key in pairs(keys) do
                    if waiters[key] ~= nil then
                        waiters[key][fid] = nil

                        -- memory leak if app uses unique keys
                        local empty = true
                        for i in pairs(waiters[key]) do
                            empty = false
                            break
                        end
                        if empty then
                            waiters[key] = nil
                        end
                    end
                end


                timeout = timeout - (box.time() - started)

                events = _take(id, keys)
                if #events > 0 then
                    break
                end
            end

            if id <= last_id() then
                id = last_id() + tonumber64(1)
            end

            -- last tuple always contains time
            table.insert(events, box.tuple.new{ box.pack('l', id) })
            return events
        end

        -- get/set expire_timeout
        self.expire_timeout = function(new_timeout)
            if new_timeout ~= nil then
                new_timeout = tonumber(new_timeout)
                expire_timeout = new_timeout
            end
            return tostring(expire_timeout)
        end


        self.stat = function()
            local tuples = {}
            local clients = 0
            for i in pairs(chs) do
                clients = clients + 1
            end
            clients = tostring(clients)

            local keys = 0
            for i in pairs(waiters) do
                keys = keys + 1
            end

            table.insert(tuples, box.tuple.new{'pool_channels', tostring(#pool_chs)})
            table.insert(tuples, box.tuple.new{'clients', clients})
            table.insert(tuples,
                box.tuple.new{'expire_timeout', tostring(expire_timeout)})
            table.insert(tuples, box.tuple.new{'work_keys', tostring(keys)})
            return tuples
        end

        self.cleanup = function()
            return cleanup_space()
        end


        -- cleanup process
        box.fiber.wrap(
            function()
                box.fiber.name('expired')
                printf("Start cleanup fiber for space %s (period %d sec): %s",
                    space, expire_timeout, box.info.status)
                while true do
                    if box.info.status == 'primary' then
                        local min = box.space[space].index[0]:min()
                        local now = math.floor( box.time() )
                        if min ~= nil then
                            local et =
                                box.unpack('i', min[TIME]) + expire_timeout
                            if et <= now then
                                cleanup_space()
                            end
                        end
                    end
                    box.fiber.sleep(expire_timeout / 10)
                end
            end
        )

        local max = box.space[space].index[0]:max()
        if max ~= nil then
            last_checked_id = box.unpack('l', max[ID])
            max = nil
        end


        return self
    end
}
