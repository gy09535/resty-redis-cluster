local redis = require "resty.redis"
local resty_lock = require "resty.lock"
local xmodem = require "resty.xmodem"
local setmetatable = setmetatable
local tostring = tostring
local string = string
local type = type
local table = table
local ngx = ngx
local math = math
local rawget = rawget
local pairs = pairs
local unpack = unpack
local ipairs = ipairs
local tonumber = tonumber
local match = string.match
local char = string.char


local DEFAULT_MAX_REDIRECTION = 5
local DEFAULT_MAX_CONNECTION_ATTEMPTS = 3
local DEFAULT_KEEPALIVE_TIMEOUT = 55000
local DEFAULT_KEEPALIVE_CONS = 1000
local DEFAULT_CONNECTION_TIMEOUT = 1000


local function parseKey(keyStr)
    local leftTagSingalIndex = string.find(keyStr, "{", 0)
    local rightTagSingalIndex = string.find(keyStr, "}", 0)
    if leftTagSingalIndex and rightTagSingalIndex then
        --parse hashtag
        return keyStr.sub(keyStr, leftTagSingalIndex + 1, rightTagSingalIndex - 1)
    else
        return keyStr
    end
end


local _M = {}

local mt = { __index = _M }

local slot_cache = {}
local master_nodes = {}

local cmds_for_all_master = {
    ["flushall"] = true,
    ["flushdb"] = true
}

local cluster_invalid_cmds = {
    ["config"] = true,
    ["shutdown"] = true
}

local function redis_slot(str)
    return xmodem.redis_crc(parseKey(str))
end

local function checkAuth(self, redis_client)
    if type(self.config.auth) == "string" then
        local count, err = redis_client:get_reused_times()
        if count == 0 then
            local _
            _, err = redis_client:auth(self.config.auth)
        end

        if not err then
            return true, nil
        else
            return nil, err
        end

    else
        return true, nil
    end
end

local function releaseConnection(red, config)
    local ok,err = red:set_keepalive(config.keepalive_timeout
            or DEFAULT_KEEPALIVE_TIMEOUT, config.keepalive_cons or DEFAULT_KEEPALIVE_CONS)
    if not ok then
        ngx.log(ngx.ERR,"set keepalive failed:", err)
    end
end

local function split(s, delimiter)
    local result = {};
    for m in (s..delimiter):gmatch("(.-)"..delimiter) do
        table.insert(result, m);
    end
    return result;
end

local function try_hosts_slots(self, serv_list)
    local errors = {}
    local config = self.config
    if #serv_list < 1 then
        return nil, "failed to fetch slots, serv_list config is empty"
    end
    for i = 1, #serv_list do
        local ip = serv_list[i].ip
        local port = serv_list[i].port
        local redis_client = redis:new()
        local ok, err
        redis_client:set_timeout(config.connection_timout or DEFAULT_CONNECTION_TIMEOUT)

        --attempt to connect DEFAULT_MAX_CONNECTION_ATTEMPTS times to redis
        for k = 1, config.max_connection_attempts or DEFAULT_MAX_CONNECTION_ATTEMPTS do
            ok, err = redis_client:connect(ip, port)
            if ok then break end
            if err then
                ngx.log(ngx.ERR,"unable to connect, attempt nr ", k, " : error: ", err)
                table.insert(errors, err)
            end
        end

        if ok then
            local authok, autherr = checkAuth(self, redis_client)
            if autherr then
                table.insert(errors, autherr)
                return nil, errors
            end
            local slots_info, err = redis_client:cluster("slots")
            if slots_info then
                local slots = {}
                -- while slots are updated, create a list of servers present in cluster
                -- this can differ from self.config.serv_list if a cluster is resized (added/removed nodes)
                local servers = { serv_list = {} }
                for i = 1, #slots_info do
                    local sub_info = slots_info[i]
                    --slot info item 1 and 2 are the subrange start end slots
                    local startslot, endslot = sub_info[1], sub_info[2]

                    -- generate new list of servers
                    for j = 3, #sub_info do
                      servers.serv_list[#servers.serv_list + 1 ] = { ip = sub_info[j][1], port = sub_info[j][2] }
                    end

                    for slot = startslot, endslot do
                        local list = { serv_list = {} }
                        --from 3, here lists the host/port/nodeid of in charge nodes
                        for j = 3, #sub_info do
                            list.serv_list[#list.serv_list + 1] = { ip = sub_info[j][1], port = sub_info[j][2] }
                            slots[slot] = list
                        end
                    end
                end
                --ngx.log(ngx.NOTICE, "finished initializing slotcache...")
                slot_cache[self.config.name] = slots
                slot_cache[self.config.name .. "serv_list"] = servers
            else
                table.insert(errors, err)
            end
            -- cache master nodes
            local nodes_res, nerr = redis_client:cluster("nodes")
            if nodes_res then
                local nodes_info = split(nodes_res, char(10))
                for _, node in ipairs(nodes_info) do
                    local node_info = split(node, " ")
                    if #node_info > 2 then
                        local is_master = match(node_info[3], "master") ~= nil
                        if is_master then
                            local ip_port = split(split(node_info[2], "@")[1], ":")
                            table.insert(master_nodes, {
                                ip = ip_port[1],
                                port = tonumber(ip_port[2])
                            })
                        end
                    end
                end
            else
                table.insert(errors, nerr)
            end
            releaseConnection(redis_client, config)
        else
            table.insert(errors, err)
        end
        if #errors == 0 then
            return true, nil
        end
    end
    return nil, errors
end


function _M.fetch_slots(self)
    local serv_list = self.config.serv_list
    local serv_list_cached = slot_cache[self.config.name .. "serv_list"]

    local serv_list_combined = {}

    -- if a cached serv_list is present, use it
    if serv_list_cached then
        serv_list_combined = serv_list_cached.serv_list
    else
        serv_list_combined = serv_list
    end

    serv_list_cached = nil -- important!

    local ok, errors = try_hosts_slots(self, serv_list_combined)
    if errors then
        local err = "failed to fetch slots: " .. table.concat(errors, ";")
        ngx.log(ngx.ERR, err)
        return nil, err
    end
end


function _M.init_slots(self)
    if slot_cache[self.config.name] then
        -- already initialized
        return true
    end
    local lock, err = resty_lock:new("redis_cluster_slot_locks")
    if not lock then
        ngx.log(ngx.ERR, "failed to create lock in initialization slot cache: ", err)
        return nil, err
    end

    local elapsed, err = lock:lock("redis_cluster_slot_" .. self.config.name)
    if not elapsed then
        ngx.log(ngx.ERR, "failed to acquire the lock in initialization slot cache: ", err)
        return nil, err
    end

    if slot_cache[self.config.name] then
        local ok, err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "failed to unlock in initialization slot cache: ", err)
        end
        -- already initialized
        return true
    end

    local _, errs = self:fetch_slots()
    if errs then
        local ok, err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "failed to unlock in initialization slot cache:", err)
        end
        return nil, errs
    end
    local ok, err = lock:unlock()
    if not ok then
        ngx.log(ngx.ERR, "failed to unlock in initialization slot cache:", err)
    end
    -- initialized
    return true
end



function _M.new(self, config)
    if not config.name then
        return nil, " redis cluster config name is empty"
    end
    if not config.serv_list or #config.serv_list < 1 then
        return nil, " redis cluster config serv_list is empty"
    end


    local inst = { config = config }
    inst = setmetatable(inst, mt)
    local _, err = inst:init_slots()
    if err then
        return nil, err
    end
    return inst
end


math.randomseed(os.time())


local function pick_node(self, serv_list, slot, magicRadomSeed)
    local host
    local port
    local slave
    local err
    local index
    if #serv_list < 1 then
        err = "serv_list for slot " .. slot .. " is empty"
        return host, port, slave, err
    end
    if self.config.enableSlaveRead then
        if magicRadomSeed then
            index = magicRadomSeed % #serv_list + 1
        else
            index = math.random(#serv_list)
        end
        host = serv_list[index].ip
        port = serv_list[index].port
        --cluster slots will always put the master node as first
        if index > 1 then
            slave = true
        else
            slave = false
        end
        --ngx.log(ngx.NOTICE, "pickup node: ", c(serv_list[index]))
    else
        host = serv_list[1].ip
        port = serv_list[1].port
        slave = false
        --ngx.log(ngx.NOTICE, "pickup node: ", cjson.encode(serv_list[1]))
    end
    return host, port, slave, err
end


local askHostAndPort = {}


local function parseAskSignal(res)
    --ask signal sample:ASK 12191 127.0.0.1:7008, so we need to parse and get 127.0.0.1, 7008
    if res ~= ngx.null then
        if type(res) == "string" and string.sub(res, 1, 3) == "ASK" then
            local matched = ngx.re.match(res, [[^ASK [^ ]+ ([^:]+):([^ ]+)]], "jo", nil, askHostAndPort)
            if not matched then
                return nil, nil
            end
            return matched[1], matched[2]
        end
        if type(res) == "table" then
            for i = 1, #res do
                if type(res[i]) == "string" and string.sub(res[i], 1, 3) == "ASK" then
                    local matched = ngx.re.match(res[i], [[^ASK [^ ]+ ([^:]+):([^ ]+)]], "jo", nil, askHostAndPort)
                    if not matched then
                        return nil, nil
                    end
                    return matched[1], matched[2]
                end
            end
        end
    end
    return nil, nil
end


local function hasMovedSignal(res)
    if res ~= ngx.null then
        if type(res) == "string" and string.sub(res, 1, 5) == "MOVED" then
            return true
        else
            if type(res) == "table" then
                for i = 1, #res do
                    if type(res[i]) == "string" and string.sub(res[i], 1, 5) == "MOVED" then
                        return true
                    end
                end
            end
        end
    end
    return false
end


local function handleCommandWithRetry(self, targetIp, targetPort, asking, cmd, key, ...)
    local config = self.config

    key = tostring(key)
    local slot = redis_slot(key)

    for k = 1, config.max_redirection or DEFAULT_MAX_REDIRECTION do

        if k > 1 then
            ngx.log(ngx.NOTICE, "handle retry attempts:" .. k .. " for cmd:" .. cmd .. " key:" .. key)
        end

        local slots = slot_cache[self.config.name]
        if slots == nil or slots[slot] == nil then
            return nil, "not slots information present, nginx might have never successfully executed cluster(\"slots\")"
        end
        local serv_list = slots[slot].serv_list

        -- We must empty local reference to slots cache, otherwise there will be memory issue while
        -- coroutine swich happens(eg. ngx.sleep, cosocket), very important!
        slots = nil

        local ip, port, slave, err

        if targetIp ~= nil and targetPort ~= nil then
            -- asking redirection should only happens at master nodes
            ip, port, slave = targetIp, targetPort, false
        else
            ip, port, slave, err = pick_node(self, serv_list, slot)
            if err then
                ngx.log(ngx.ERR, "pickup node failed, will return failed for this request, meanwhile refereshing slotcache " .. err)
                self:fetch_slots()
                return nil, err
            end
        end

        local redis_client = redis:new()
        redis_client:set_timeout(config.connection_timout or DEFAULT_CONNECTION_TIMEOUT)
        local ok, connerr = redis_client:connect(ip, port)

        if ok then
            local authok, autherr = checkAuth(self, redis_client)
            if autherr then
                return nil, autherr
            end
            if slave then
                --set readonly
                local ok, err = redis_client:readonly()
                if not ok then
                    self:fetch_slots()
                    return nil, err
                end
            end

            if asking then
                --executing asking
                local ok, err = redis_client:asking()
                if not ok then
                    self:fetch_slots()
                    return nil, err
                end
            end

            local needToRetry = false
            local res, err
            if cmd == "eval" or cmd == "evalsha" then
                res, err = redis_client[cmd](redis_client, ...)
            else
                res, err = redis_client[cmd](redis_client, key, ...)
            end

            if err then
                if string.sub(err, 1, 5) == "MOVED" then
                    --ngx.log(ngx.NOTICE, "find MOVED signal, trigger retry for normal commands, cmd:" .. cmd .. " key:" .. key)
                    --if retry with moved, we will not asking to specific ip,port anymore
                    releaseConnection(redis_client, config)
                    targetIp = nil
                    targetPort = nil
                    self:fetch_slots()
                    needToRetry = true

                elseif string.sub(err, 1, 3) == "ASK" then
                    --ngx.log(ngx.NOTICE, "handle asking for normal commands, cmd:" .. cmd .. " key:" .. key)
                    releaseConnection(redis_client, config)
                    if asking then
                        --Should not happen after asking target ip,port and still return ask, if so, return error.
                        return nil, "nested asking redirection occurred, client cannot retry "
                    else
                        local askHost, askPort = parseAskSignal(err)

                        if askHost ~= nil and askPort ~= nil then
                            return handleCommandWithRetry(self, askHost, askPort, true, cmd, key, ...)
                        else
                            return nil, " cannot parse ask redirection host and port: msg is " .. err
                        end
                    end

                elseif string.sub(err, 1, 11) == "CLUSTERDOWN" then
                    return nil, "Cannot executing command, cluster status is failed!"
                else
                    --There might be node fail, we should also refresh slot cache
                    self:fetch_slots()
                    return nil, err
                end
            end
            if not needToRetry then
                releaseConnection(redis_client, config)
                return res, err
            end
        else
            --There might be node fail, we should also refresh slot cache
            self:fetch_slots()
            if k == config.max_redirection or k == DEFAULT_MAX_REDIRECTION then
                -- only return after allowing for `k` attempts
                return nil, connerr
            end
        end
    end
    return nil, "failed to execute command, reaches maximum redirection attempts"
end


local function generateMagicSeed(self)
    --For pipeline, We don't want request to be forwarded to all channels, eg. if we have 3*3 cluster(3 master 2 replicas) we
    --alway want pick up specific 3 nodes for pipeline requests, instead of 9.
    --Currently we simply use (num of allnode)%count as a randomly fetch. Might consider a better way in the future.
    -- use the dynamic serv_list instead of the static config serv_list
    local nodeCount = #slot_cache[self.config.name .. "serv_list"].serv_list
    return math.random(nodeCount)
end

local function _do_cmd_master(self, cmd, key, ...)
    local errors = {}
    for _, master in ipairs(master_nodes) do
        local redis_client = redis:new()
        redis_client:set_timeout(self.config.connection_timout or DEFAULT_CONNECTION_TIMEOUT)
        local ok, err = redis_client:connect(master.ip, master.port)
        if ok then
            ok, err = redis_client[cmd](redis_client, key, ...)
        end
        if err then
            table.insert(errors, err)
        end
        releaseConnection(redis_client, self.config)
    end
    return #errors == 0, table.concat(errors, ";")
end

local function _do_cmd(self, cmd, key, ...)
    if cluster_invalid_cmds[cmd] == true then
        return nil, "command not supported"
    end

    local _reqs = rawget(self, "_reqs")
    if _reqs then
        local args = { ... }
        local t = { cmd = cmd, key = key, args = args }
        table.insert(_reqs, t)
        return
    end

    if cmds_for_all_master[cmd] then
        return _do_cmd_master(self, cmd, key, ...)
    end

    local res, err = handleCommandWithRetry(self, nil, nil, false, cmd, key, ...)
    return res, err
end


local function constructFinalPipelineRes(self, node_res_map, node_req_map)
    --construct final result with origin index
    local finalret = {}
    for k, v in pairs(node_res_map) do
        local reqs = node_req_map[k].reqs
        local res = v
        local needToFetchSlots = true
        for i = 1, #reqs do
            --deal with redis cluster ask redirection
            local askHost, askPort = parseAskSignal(res[i])
            if askHost ~= nil and askPort ~= nil then
                --ngx.log(ngx.NOTICE, "handle ask signal for cmd:" .. reqs[i]["cmd"] .. " key:" .. reqs[i]["key"] .. " target host:" .. askHost .. " target port:" .. askPort)
                local askres, err = handleCommandWithRetry(self, askHost, askPort, true, reqs[i]["cmd"], reqs[i]["key"], unpack(reqs[i]["args"]))
                if err then
                    return nil, err
                else
                    finalret[reqs[i].origin_index] = askres
                end
            elseif hasMovedSignal(res[i]) then
                --ngx.log(ngx.NOTICE, "handle moved signal for cmd:" .. reqs[i]["cmd"] .. " key:" .. reqs[i]["key"])
                if needToFetchSlots then
                    -- if there is multiple signal for moved, we just need to fetch slot cache once, and do retry.
                    self:fetch_slots()
                    needToFetchSlots = false
                end
                local movedres, err = handleCommandWithRetry(self, nil, nil, false, reqs[i]["cmd"], reqs[i]["key"], unpack(reqs[i]["args"]))
                if err then
                    return nil, err
                else
                    finalret[reqs[i].origin_index] = movedres
                end
            else
                finalret[reqs[i].origin_index] = res[i]
            end
        end
    end
    return finalret
end


local function hasClusterFailSignalInPipeline(res)
    for i = 1, #res do
        if res[i] ~= ngx.null and type(res[i]) == "table" then
            for j = 1, #res[i] do
                if type(res[i][j]) == "string" and string.sub(res[i][j], 1, 11) == "CLUSTERDOWN" then
                    return true
                end
            end
        end
    end
    return false
end


function _M.init_pipeline(self)
    self._reqs = {}
end


function _M.commit_pipeline(self)
    local _reqs = rawget(self, "_reqs")

    if not _reqs or #_reqs == 0 then return
    end

    self._reqs = nil
    local config = self.config
    local needToRetry = false

    local slots = slot_cache[config.name]
    if slots == nil then
        return nil, "not slots information present, nginx might have never successfully executed cluster(\"slots\")"
    end

    local node_res_map = {}

    local node_req_map = {}
    local magicRandomPickupSeed = generateMagicSeed(self)

    --construct req to real node mapping
    for i = 1, #_reqs do
        -- Because we will forward req to different nodes, so the result will not be the origin order,
        -- we need to record the original index and finally we can construct the result with origin order
        _reqs[i].origin_index = i
        local key = _reqs[i].key
        local slot = redis_slot(tostring(key))
        if slots[slot] == nil then
            return nil, "not slots information present, nginx might have never successfully executed cluster(\"slots\")"
        end
        local slot_item = slots[slot]

        local ip, port, slave, err = pick_node(self, slot_item.serv_list, slot, magicRandomPickupSeed)
        if err then
            -- We must empty local reference to slots cache, otherwise there will be memory issue while
            -- coroutine swich happens(eg. ngx.sleep, cosocket), very important!
            slots = nil
            self:fetch_slots()
            return nil, err
        end

        local node = ip .. tostring(port)
        if not node_req_map[node] then
            node_req_map[node] = { ip = ip, port = port, slave = slave, reqs = {} }
            node_res_map[node] = {}
        end
        local ins_req = node_req_map[node].reqs
        ins_req[#ins_req + 1] = _reqs[i]
    end

    -- We must empty local reference to slots cache, otherwise there will be memory issue while
    -- coroutine swich happens(eg. ngx.sleep, cosocket), very important!
    slots = nil

    for k, v in pairs(node_req_map) do
        local ip = v.ip
        local port = v.port
        local reqs = v.reqs
        local slave = v.slave
        local redis_client = redis:new()
        redis_client:set_timeout(config.connection_timout or DEFAULT_CONNECTION_TIMEOUT)
        local ok, err = redis_client:connect(ip, port)

        local authok, autherr = checkAuth(self, redis_client)
        if autherr then
            return nil, autherr
        end

        if slave then
            --set readonly
            local ok, err = redis_client:readonly()
            if not ok then
                self:fetch_slots()
                return nil, err
            end
        end
        if ok then
            redis_client:init_pipeline()
            for i = 1, #reqs do
                local req = reqs[i]
                if #req.args > 0 then
                    if req.cmd == "eval" or req.cmd == "evalsha" then
                        redis_client[req.cmd](redis_client, unpack(req.args))
                    else
                        redis_client[req.cmd](redis_client, req.key, unpack(req.args))
                    end
                else
                    redis_client[req.cmd](redis_client, req.key)
                end
            end
            local res, err = redis_client:commit_pipeline()
            if err then
                --There might be node fail, we should also refresh slot cache
                self:fetch_slots()
                return nil, err .. " return from " .. tostring(ip) .. ":" .. tostring(port)
            end

            if hasClusterFailSignalInPipeline(res) then
                return nil, "Cannot executing pipeline command, cluster status is failed!"
            end
            releaseConnection(redis_client, config)
            node_res_map[k] = res
        else
            --There might be node fail, we should also refresh slot cache
            self:fetch_slots()
            return nil, err .. "pipeline commit failed while connecting to " .. tostring(ip) .. ":" .. tostring(port)
        end
    end

    --construct final result with origin index
    local finalres, err = constructFinalPipelineRes(self, node_res_map, node_req_map)
    if not err then
        return finalres
    else
        return nil, err .. " failed to construct final pipeline result "
    end
end


function _M.cancel_pipeline(self)
    self._reqs = nil
end

local function _do_eval_cmd(self, cmd, ...)
--[[
eval command usage:
eval(script, 1, key, arg1, arg2 ...)
eval(script, 0, arg1, arg2 ...)
]]
    local args = {...}
    local keys_num = args[2]
    if type(keys_num) ~= "number" then
        return nil, "Cannot execute eval without keys number"
    end
    if keys_num > 1 then
        return nil, "Cannot execute eval with more than one keys for redis cluster"
    end
    local key = args[3] or "no_key"
    return _do_cmd(self, cmd, key, ...)
end
-- dynamic cmd
setmetatable(_M, {
    __index = function(self, cmd)
        local method =
        function(self, ...)
            if cmd == "eval" or cmd == "evalsha" then
                return _do_eval_cmd(self, cmd, ...)
            else
                return _do_cmd(self, cmd, ...)
            end
        end

        -- cache the lazily generated method in our
        -- module table
        _M[cmd] = method
        return method
    end
})

return _M