local RES = GetCurrentResourceName()
local Sounds = {}
local boomboxSeq = 0
local placeGrant = {}

local function now() return GetGameTimer() end

local notify = PSP.notify
local onCooldown = PSP.onCooldown

local function localize(r)
    if type(r) ~= 'table' then return r end
    if type(r.error) == 'string' then r.error = locale(r.error) end
    if type(r.track) == 'table' and r.track.title == '' then r.track.title = locale('track.untitled') end
    if type(r.results) == 'table' then
        for _, t in ipairs(r.results) do
            if t.title == '' then t.title = locale('track.untitled') end
        end
    end
    return r
end

local function nodeCall(fn, arg, timeoutMs)
    local p = promise.new()
    SetTimeout(timeoutMs or 200000, function()
        if p.state == 0 then p:resolve({ ok = false, error = locale('err.timeout') }) end
    end)
    exports[RES][fn](exports[RES], arg, function(r)
        if p.state == 0 then p:resolve(r) end
    end)
    return localize(Citizen.Await(p))
end

local function position(s)
    if not s.track or s.loading then return 0 end
    if s.paused then return s.pausedPos end
    return (now() - s.startedAt) / 1000.0
end

local function publicState(s)
    return {
        id = s.id, kind = s.kind, netId = s.netId, coords = s.coords, volume = s.volume,
        loop = s.loop, paused = s.paused, track = s.track, token = s.token, loading = s.loading or false,
        position = position(s), queue = s.queue, eq = s.eq,
    }
end

local function broadcast(s)
    local st = publicState(s)
    for pid in pairs(s.audience) do TriggerClientEvent('pena_soundplayer:state', pid, s.id, st) end
end

local function addAudience(s, pid)
    if s.audience[pid] then return end
    s.audience[pid] = true
    TriggerClientEvent('pena_soundplayer:state', pid, s.id, publicState(s))
end

local function soundPos(s)
    if s.kind == 'boombox' then
        local c = s.coords
        return c and vec3(c.x, c.y, c.z) or nil
    end
    local ent = s.netId and NetworkGetEntityFromNetworkId(s.netId) or 0
    if ent == 0 or not DoesEntityExist(ent) then return nil end
    return GetEntityCoords(ent)
end

local function scopeRadii(s)
    local D = (s.kind == 'car' and Config.carRadio or Config.boombox).distance
    return D + 50.0, D + 90.0
end

local function removeSound(id)
    local s = Sounds[id]
    if not s then return end
    Sounds[id] = nil
    for pid in pairs(s.audience) do TriggerClientEvent('pena_soundplayer:removed', pid, id) end
end

local function beginPlayback(s)
    if not s.loading then return end
    s.loading = false
    s.starter = nil
    s.startedAt = now() - (s.pausedPos or 0) * 1000
    broadcast(s)
end

local function startTrack(s, track, starter)
    s.track = track
    s.paused = false
    s.pausedPos = 0
    s.token = (s.token or 0) + 1
    s.loading = true
    s.starter = starter
    s.startedAt = now()
    local token = s.token
    SetTimeout(Config.loadTimeout or 8000, function()
        if Sounds[s.id] == s and s.token == token then beginPlayback(s) end
    end)
end

local function clearTrack(s)
    s.track, s.paused, s.pausedPos, s.loading, s.starter = nil, false, 0, false, nil
    s.token = (s.token or 0) + 1
end

local function advance(s, manual, starter)
    if s.track and s.loop and not manual then
        startTrack(s, s.track, nil)
    elseif #s.queue > 0 then
        startTrack(s, table.remove(s.queue, 1), starter)
    else
        clearTrack(s)
    end
end

local function seatAllowed(ped, veh)
    local mode = Config.carRadio.allowedSeats
    if mode == 'any' then return true end
    if GetPedInVehicleSeat(veh, -1) == ped then return true end
    return mode == 'front' and GetPedInVehicleSeat(veh, 0) == ped
end

local function canControl(src, s)
    if not PSP.loggedIn(src) then return false end
    if Config.blockWhenDead and PSP.dead(src) then return false end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    if s.kind == 'boombox' then
        local c = s.coords
        return #(GetEntityCoords(ped) - vec3(c.x, c.y, c.z)) <= Config.boombox.controlDistance + 2.0
    end
    local veh = NetworkGetEntityFromNetworkId(s.netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    if GetVehiclePedIsIn(ped, false) ~= veh then return false end
    return seatAllowed(ped, veh)
end

local function setOf(list, fn)
    local out = {}
    for _, v in ipairs(list or {}) do out[fn and fn(v) or v] = true end
    return out
end
local hash = function(name) return joaat(name) & 0xFFFFFFFF end
local allowedModels = setOf(Config.carRadio.allowedModels, hash)
local hasAllowList = next(allowedModels) ~= nil
local blockedModels = setOf(Config.carRadio.blockedModels, hash)
local blockedTypes = setOf(Config.carRadio.blockedTypes)

local function vehicleAllowed(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    local model = GetEntityModel(veh) & 0xFFFFFFFF
    if blockedModels[model] then return false end
    local okType, vtype = pcall(GetVehicleType, veh)
    if okType and vtype and blockedTypes[vtype] then return false end
    if hasAllowList and not allowedModels[model] then return false end
    return true
end

Callback.register('pena_soundplayer:canUse', function(src, netId)
    if not PSP.loggedIn(src) then return false end
    local veh = type(netId) == 'number' and NetworkGetEntityFromNetworkId(netId) or 0
    return vehicleAllowed(veh)
end)

local ensureTick

local function newSound(id, kind)
    ensureTick()
    return {
        id = id, kind = kind, volume = Config.defaultVolume, loop = false, eq = { 0, 0, 0, 0, 0 },
        paused = false, pausedPos = 0, startedAt = 0, token = 0, queue = {}, track = nil, loading = false, audience = {},
    }
end

local function createCarSound(src, id)
    if not Config.carRadio.enabled or not PSP.loggedIn(src) then return nil end
    local netId = tonumber(id:match('^car:(%d+)$'))
    if not netId then return nil end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    if not vehicleAllowed(veh) then notify(src, locale('car.noRadio'), 'error') return nil end
    local ped = GetPlayerPed(src)
    if GetVehiclePedIsIn(ped, false) ~= veh or not seatAllowed(ped, veh) then return nil end
    local s = newSound(id, 'car')
    s.netId = netId
    Sounds[id] = s
    return s
end

Callback.register('pena_soundplayer:search', function(src, q)
    if not PSP.loggedIn(src) then return { ok = false, error = locale('err.noChar') } end
    if type(q) ~= 'string' or #q < 2 or #q > 100 then return { ok = false, error = locale('search.short') } end
    if onCooldown(src, 'search', Config.searchCooldown) then return { ok = false, error = 'busy', quiet = true } end
    if (PSP.pendingSearches or 0) >= (Config.maxPendingSearches or 6) then return { ok = false, error = 'busy', quiet = true } end
    PSP.pendingSearches = (PSP.pendingSearches or 0) + 1
    local r = nodeCall('search', q, 60000)
    PSP.pendingSearches = math.max(0, (PSP.pendingSearches or 1) - 1)
    if r and r.ok then
        r.results = PSP.filterResults(r.results)
        if #r.results == 0 then return { ok = false, error = locale('search.none') } end
    end
    return r
end)

local function trackInUse(id)
    for _, s in pairs(Sounds) do
        if s.track and s.track.id == id then return true end
        for _, q in ipairs(s.queue) do if q.id == id then return true end end
    end
    return false
end

Callback.register('pena_soundplayer:chunk', function(src, trackId, n)
    if type(trackId) ~= 'string' or #trackId ~= 11 or not trackId:match('^[%w_%-]+$') then return { ok = false } end
    n = math.tointeger(n)
    if not n or n < 0 or n > 9999 then return { ok = false } end
    if not trackInUse(trackId) then return { ok = false, error = 'track is not playing' } end
    return nodeCall('chunk', { id = trackId, n = n }, 20000)
end)

RegisterNetEvent('pena_soundplayer:server:play', function(id, ref, mode)
    local src = source
    if type(id) ~= 'string' or #id > 40 or type(ref) ~= 'string' or #ref > 300 then return end
    if mode ~= 'now' and mode ~= 'queue' then mode = 'now' end

    local function clearStatus() TriggerClientEvent('pena_soundplayer:status', src, id, '') end
    local function bail(text) clearStatus() if text then notify(src, text, 'error') end end

    local s = Sounds[id] or (id:sub(1, 4) == 'car:' and createCarSound(src, id)) or nil
    if not s or not canControl(src, s) then return bail() end
    addAudience(s, src)
    if onCooldown(src, 'play', Config.playCooldown) then return bail(locale('err.slowDown')) end
    if mode == 'queue' and #s.queue >= Config.maxQueue then return bail(locale('queue.full')) end

    local refId = PSP.idFromRef(ref)
    if refId and PSP.isBlocked({ id = refId }) then return bail(locale('song.blocked')) end

    TriggerClientEvent('pena_soundplayer:status', src, id, locale('status.track'))
    local r = nodeCall('ensure', ref)
    TriggerClientEvent('pena_soundplayer:status', src, id, '')

    if Sounds[id] ~= s then return end
    if not r or not r.ok or not r.track then
        return notify(src, (r and r.error) or locale('song.notFound'), 'error')
    end
    if PSP.isBlocked(r.track) then return notify(src, locale('song.blocked'), 'error') end

    if mode == 'queue' and s.track then
        if #s.queue >= Config.maxQueue then return notify(src, locale('queue.full'), 'error') end
        s.queue[#s.queue + 1] = r.track
    else
        startTrack(s, r.track, src)
    end
    broadcast(s)
end)

RegisterNetEvent('pena_soundplayer:server:ready', function(id, token)
    local src = source
    local s = type(id) == 'string' and Sounds[id] or nil
    if not s or not s.loading or s.token ~= token then return end
    if s.starter and s.starter ~= src and GetPlayerName(s.starter) then return end
    beginPlayback(s)
end)

RegisterNetEvent('pena_soundplayer:server:playlist', function(id, plId, mode, shuffle)
    local src = source
    if type(id) ~= 'string' or #id > 40 then return end
    if mode ~= 'play' and mode ~= 'queue' then mode = 'play' end

    local function clearStatus() TriggerClientEvent('pena_soundplayer:status', src, id, '') end
    local function bail(text) clearStatus() if text then notify(src, text, 'error') end end

    local s = Sounds[id] or (id:sub(1, 4) == 'car:' and createCarSound(src, id)) or nil
    if not s or not canControl(src, s) then return bail() end
    addAudience(s, src)
    if onCooldown(src, 'play', Config.playCooldown) then return bail(locale('err.slowDown')) end

    local pl = PSP.getPlaylist(src, plId)
    if not pl then return bail(locale('pl.notFound')) end
    local tracks = {}
    for _, t in ipairs(pl.tracks) do
        if not PSP.isBlocked(t) then tracks[#tracks + 1] = t end
    end
    if #tracks == 0 then return bail(locale('pl.empty')) end
    if shuffle then
        for i = #tracks, 2, -1 do
            local j = math.random(1, i)
            tracks[i], tracks[j] = tracks[j], tracks[i]
        end
    end

    if mode == 'play' then s.queue = {} end
    s.loadToken = (s.loadToken or 0) + 1
    local lt = s.loadToken
    local replaced = mode ~= 'play'
    broadcast(s)

    CreateThread(function()
        TriggerClientEvent('pena_soundplayer:status', src, id, locale('status.playlist'))
        local failNotified = false
        local ok, err = pcall(function()
            for _, t in ipairs(tracks) do
                if Sounds[id] ~= s or s.loadToken ~= lt then break end
                if #s.queue >= Config.maxQueue then break end
                local r = nodeCall('ensure', t.id)
                if Sounds[id] ~= s or s.loadToken ~= lt then break end
                if r and r.ok and r.track and not PSP.isBlocked(r.track) then
                    if not replaced then
                        replaced = true
                        startTrack(s, r.track, src)
                        TriggerClientEvent('pena_soundplayer:status', src, id, '')
                    elseif not s.track then
                        startTrack(s, r.track, src)
                    else
                        s.queue[#s.queue + 1] = r.track
                    end
                    broadcast(s)
                elseif r and not r.ok and not failNotified and not s.track then
                    failNotified = true
                    notify(src, r.error or locale('pl.noneFound'), 'error')
                end
            end
        end)
        clearStatus()
        if not ok then print(('^1[%s] playlist error: %s^7'):format(RES, tostring(err))) end
    end)
end)

local actions = {
    pause = function(s)
        if s.track and not s.paused then s.pausedPos = position(s); s.paused = true end
    end,
    resume = function(s)
        if s.track and s.paused then
            if not s.loading then s.startedAt = now() - s.pausedPos * 1000 end
            s.paused = false
        end
    end,
    seek = function(s, v)
        if not s.track or s.loading or type(v) ~= 'number' then return end
        local dur = s.track.duration or 0
        v = math.max(0.0, math.min(v + 0.0, math.max(dur - 1, 0)))
        if s.paused then s.pausedPos = v else s.startedAt = now() - v * 1000 end
    end,
    skip = function(s, _, src) advance(s, true, src) end,
    stop = function(s)
        s.queue = {}
        s.loadToken = (s.loadToken or 0) + 1
        clearTrack(s)
    end,
    eq = function(s, v)
        local b = PSP.cleanBands(v)
        if b then s.eq = b end
    end,
    volume = function(s, v)
        if type(v) ~= 'number' then return end
        s.volume = math.max(0.0, math.min(v + 0.0, 1.0))
    end,
    loop = function(s, v) s.loop = v == true end,
    remove = function(s, v)
        v = tonumber(v)
        if v and s.queue[v] then table.remove(s.queue, v) end
    end,
}

RegisterNetEvent('pena_soundplayer:server:ctl', function(id, action, value)
    local src = source
    if type(id) ~= 'string' or type(action) ~= 'string' or not actions[action] then return end
    if onCooldown(src, 'ctl', 120) then return end
    local s = Sounds[id]
    if not s or not canControl(src, s) then return end
    addAudience(s, src)
    actions[action](s, value, src)
    if action == 'eq' then
        for pid in pairs(s.audience) do TriggerClientEvent('pena_soundplayer:eq', pid, id, s.eq) end
    else
        broadcast(s)
    end
end)

local function boomboxCommandAllowed(src)
    local group = Config.boombox.commandGroup
    if group == '' then return true end
    return PSP.hasAce(src, group or 'group.admin')
end

RegisterNetEvent('pena_soundplayer:server:sync', function()
    local src = source
    if not PSP.loggedIn(src) then return end
    local ped = GetPlayerPed(src)
    local pc = ped and ped ~= 0 and GetEntityCoords(ped) or nil
    local out = {}
    for id, s in pairs(Sounds) do
        local sp = soundPos(s)
        local enterR = scopeRadii(s)
        if s.audience[src] or (pc and sp and #(pc - sp) <= enterR) then
            s.audience[src] = true
            out[id] = publicState(s)
        end
    end
    TriggerClientEvent('pena_soundplayer:bulk', src, out)
    PSP.suggestAdminCommands(src)
    local cmd = Config.boombox.command
    if Config.boombox.enabled and cmd and cmd ~= '' and boomboxCommandAllowed(src) then
        TriggerClientEvent('chat:addSuggestion', src, '/' .. cmd, locale('cmd.boombox'))
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    for _, s in pairs(Sounds) do s.audience[src] = nil end
    placeGrant[src] = nil
end)

function PSP.purgeTrack(trackId)
    for _, s in pairs(Sounds) do
        for i = #s.queue, 1, -1 do
            if s.queue[i].id == trackId then table.remove(s.queue, i) end
        end
        if s.track and s.track.id == trackId then advance(s, true) end
        broadcast(s)
    end
end

local function ownerOf(src) return PSP.owner(src) or tostring(src) end

local function countBoomboxes(src)
    local owner, n = ownerOf(src), 0
    for _, s in pairs(Sounds) do if s.kind == 'boombox' and s.owner == owner then n = n + 1 end end
    return n
end

local function granted(src)
    return placeGrant[src] ~= nil and now() - placeGrant[src] < 60000
end

local function mayPlace(src)
    if not Config.boombox.enabled or not PSP.loggedIn(src) then return false end
    if countBoomboxes(src) >= Config.boombox.maxPerPlayer then return false, locale('boombox.already') end
    return granted(src)
end

local function startPlacement(src)
    if not Config.boombox.enabled or not PSP.loggedIn(src) then return false end
    if countBoomboxes(src) >= Config.boombox.maxPerPlayer then
        notify(src, locale('boombox.already'), 'error')
        return false
    end
    placeGrant[src] = now()
    TriggerClientEvent('pena_soundplayer:client:placeBoombox', src)
    return true
end

exports('placeBoombox', function(src)
    src = tonumber(src)
    if not src then return false end
    return startPlacement(src)
end)

if Config.boombox.enabled and Config.boombox.command and Config.boombox.command ~= '' then
    RegisterCommand(Config.boombox.command, function(src)
        if src == 0 then return end
        if not boomboxCommandAllowed(src) then return notify(src, locale('err.noPermission'), 'error') end
        if not PSP.loggedIn(src) then return notify(src, locale('err.noChar'), 'error') end
        startPlacement(src)
    end, false)
end

local function boomboxRegistered(netId)
    for _, s in pairs(Sounds) do
        if s.kind == 'boombox' and s.netId == netId then return true end
    end
    return false
end

RegisterNetEvent('pena_soundplayer:server:boomboxPlaced', function(netId)
    local src = source
    if type(netId) ~= 'number' or not Config.boombox.enabled then return end

    local ent = 0
    for _ = 1, 25 do
        ent = NetworkGetEntityFromNetworkId(netId)
        if ent ~= 0 and DoesEntityExist(ent) then break end
        Wait(100)
    end
    if ent == 0 or not DoesEntityExist(ent) then return end
    Wait(250)

    -- Never touch anything that is not a boombox, or a boombox that is already in use.
    if GetEntityModel(ent) ~= joaat(Config.boombox.model) then return end
    if boomboxRegistered(netId) then return end

    local ped = GetPlayerPed(src)
    local near = #(GetEntityCoords(ent) - GetEntityCoords(ped)) < 8.0
    local allowed, why = mayPlace(src)
    if not (near and allowed) then
        -- Only clean up a boombox that sits next to the player who tried to place it.
        if near then DeleteEntity(ent) end
        if why then notify(src, why, 'error') end
        return
    end

    placeGrant[src] = nil

    boomboxSeq = boomboxSeq + 1
    local id = 'boombox:' .. boomboxSeq
    local c = GetEntityCoords(ent)
    local s = newSound(id, 'boombox')
    s.netId, s.owner, s.coords = netId, ownerOf(src), { x = c.x, y = c.y, z = c.z }
    s.audience[src] = true
    Sounds[id] = s
    broadcast(s)
end)

RegisterNetEvent('pena_soundplayer:server:pickup', function(id)
    local src = source
    local s = type(id) == 'string' and Sounds[id] or nil
    if not s or s.kind ~= 'boombox' or not canControl(src, s) then return end
    local ent = NetworkGetEntityFromNetworkId(s.netId)
    if ent ~= 0 and DoesEntityExist(ent) then DeleteEntity(ent) end
    removeSound(id)
end)

local function vehicleOccupied(veh)
    for seat = -1, 8 do
        if GetPedInVehicleSeat(veh, seat) ~= 0 then return true end
    end
    return false
end

local tickRunning = false
ensureTick = function()
    if tickRunning then return end
    tickRunning = true
    CreateThread(function()
        while true do
            Wait(1000)
            if not next(Sounds) then tickRunning = false return end
            local players = {}
            for _, p in ipairs(GetPlayers()) do
                if PSP.loggedIn(tonumber(p)) then
                    local ped = GetPlayerPed(p)
                    if ped and ped ~= 0 then players[tonumber(p)] = GetEntityCoords(ped) end
                end
            end
            for id, s in pairs(Sounds) do
                local ent = (s.netId and NetworkGetEntityFromNetworkId(s.netId)) or 0
                local gone = ent == 0 or not DoesEntityExist(ent)
                if gone then
                    s.missing = (s.missing or 0) + 1
                    if s.missing >= 3 then removeSound(id) end
                else
                    s.missing = 0
                    local sp = s.kind == 'boombox' and soundPos(s) or GetEntityCoords(ent)
                    if sp then
                        local enterR, leaveR = scopeRadii(s)
                        for pid, pc in pairs(players) do
                            local d = #(pc - sp)
                            if s.audience[pid] then
                                if d > leaveR then
                                    s.audience[pid] = nil
                                    TriggerClientEvent('pena_soundplayer:removed', pid, id)
                                end
                            elseif d <= enterR then
                                addAudience(s, pid)
                            end
                        end
                        for pid in pairs(s.audience) do if not players[pid] then s.audience[pid] = nil end end
                    end
                    if s.kind == 'car' and Config.carRadio.stopWhenEmptyAfter > 0 then
                        local empty = not vehicleOccupied(ent)
                        s.emptyFor = empty and ((s.emptyFor or 0) + 1) or 0
                        if s.emptyFor >= Config.carRadio.stopWhenEmptyAfter then removeSound(id) end
                    end
                end
                if Sounds[id] and s.track and not s.paused and not s.loading then
                    local dur = s.track.duration or 600
                    if position(s) >= dur - 0.3 then
                        advance(s, false)
                        broadcast(s)
                    end
                end
            end
        end
    end)
end

AddEventHandler('onResourceStop', function(name)
    if name ~= RES then return end
    for _, s in pairs(Sounds) do
        if s.kind == 'boombox' and s.netId then
            local ent = NetworkGetEntityFromNetworkId(s.netId)
            if ent ~= 0 and DoesEntityExist(ent) then DeleteEntity(ent) end
        end
    end
end)
