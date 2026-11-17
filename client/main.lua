local RES = GetCurrentResourceName()
local Sounds = {}
local nuiOpen, openId = false, nil
local boomboxRunning = false
local watchOpenUI

local function getBase()
    local b = Config.baseUrl
    if type(b) ~= 'string' or b == '' then return '' end
    if b:sub(-1) ~= '/' then b = b .. '/' end
    return b
end

local noticeColors = { error = '~r~', success = '~g~' }

local function notify(text, kind)
    text = tostring(text or ''):gsub('~', '')
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(('~h~%s~h~ %s%s'):format(locale('title'), noticeColors[kind] or '~s~', text))
    EndTextCommandThefeedPostTicker(false, false)
end

RegisterNetEvent('pena_soundplayer:notify', notify)

local function loggedIn() return NetworkIsPlayerActive(PlayerId()) end

local function requestModel(model, timeout)
    if not IsModelValid(model) then return false end
    local limit = GetGameTimer() + timeout
    RequestModel(model)
    while not HasModelLoaded(model) do
        if GetGameTimer() > limit then return false end
        Wait(0)
    end
    return true
end

local function requestAnimDict(dict, timeout)
    if not DoesAnimDictExist(dict) then return false end
    local limit = GetGameTimer() + timeout
    RequestAnimDict(dict)
    while not HasAnimDictLoaded(dict) do
        if GetGameTimer() > limit then return false end
        Wait(0)
    end
    return true
end

local streamerMode = GetResourceKvpInt('pena_soundplayer:streamer') == 1

local function sfx(name)
    local c = Config.sounds
    if streamerMode or not c or not c.enabled then return end
    local snd = c[name]
    if snd and snd[1] and snd[2] then PlaySoundFrontend(-1, snd[1], snd[2], true) end
end

local Spatial = {}

local clamp = function(v, a, b) return v < a and a or (v > b and b or v) end
local lerp = function(a, b, t) return a + (b - a) * t end
local lerpHz = function(a, b, t) return math.exp(lerp(math.log(a), math.log(b), t)) end
local MAXHZ = 22000.0

local function cfg() return Config.spatial end

local function falloff(model, d, D, exponent)
    local f = clamp(1.0 - d / D, 0.0, 1.0)
    if model == 'linear' then return f end
    if model == 'sqrt' then return math.sqrt(f) end
    return f ^ (exponent or 2.0)
end

local openCache = {}

local function windowsDownCount(veh)
    local ok, v = pcall(function() return Entity(veh).state.windowsDown end)
    if not ok or v == nil or v == false then return 0 end
    if v == true then return 4 end
    return tonumber(v) or 0
end

function Spatial.vehicleOpenness(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return 1.0 end
    local now = GetGameTimer()
    local c = openCache[veh]
    if c and now - c.t < 250 then return c.v end

    local v = cfg().vehicle
    local open
    local class = GetVehicleClass(veh)
    if v.openClasses[class] then
        open = v.openClasses[class]
    elseif IsThisModelAQuadbike(GetEntityModel(veh)) or IsThisModelABike(GetEntityModel(veh)) then
        open = 1.0
    else
        open = 0.0
        local doors = math.min(GetNumberOfVehicleDoors(veh), 4)
        for i = 0, doors - 1 do
            open = open + clamp(GetVehicleDoorAngleRatio(veh, i), 0.0, 1.0) * v.doorWeight
        end
        for i = 0, 3 do
            if not IsVehicleWindowIntact(veh, i) then open = open + v.windowWeight end
        end
        open = open + windowsDownCount(veh) * v.windowWeight
        if IsVehicleAConvertible(veh, false) then
            local roof = GetConvertibleRoofState(veh)
            if roof == 2 then open = open + v.roofDownWeight
            elseif roof ~= 0 then open = open + v.roofDownWeight * 0.5 end
        end
    end
    open = clamp(open, 0.0, 1.0)
    openCache[veh] = { t = now, v = open }
    if GetGameTimer() % 7 == 0 then
        for k, e in pairs(openCache) do if now - e.t > 5000 then openCache[k] = nil end end
    end
    return open
end

function Spatial.listener()
    local ped = PlayerPedId()
    local head = GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0)
    if head.x == 0.0 and head.y == 0.0 then head = GetEntityCoords(ped) end
    local rot = GetFinalRenderedCamRot(2)
    local z = math.rad(rot.z)
    local veh = GetVehiclePedIsIn(ped, false)
    return {
        ped = ped, pos = GetEntityCoords(ped), head = head, veh = veh,
        right = vec2(math.cos(z), math.sin(z)),
        fwd = vec2(-math.sin(z), math.cos(z)),
        interior = GetInteriorFromEntity(ped),
        room = GetRoomKeyFromEntity(ped),
        enclosed = veh ~= 0 and (1.0 - Spatial.vehicleOpenness(veh)) or 0.0,
    }
end

local function soundSource(st, L)
    if st.kind == 'car' then
        if not st.netId or not NetworkDoesNetworkIdExist(st.netId) then return nil end
        local ent = NetToVeh(st.netId)
        if ent == 0 or not DoesEntityExist(ent) then return nil end
        return { pos = GetEntityCoords(ent), ent = ent, inside = ent == L.veh, veh = ent }
    end
    local ent = 0
    if st.netId and NetworkDoesNetworkIdExist(st.netId) then
        ent = NetToObj(st.netId)
        if ent ~= 0 and not DoesEntityExist(ent) then ent = 0 end
    end
    local pos
    if ent ~= 0 then pos = GetEntityCoords(ent)
    else local c = st.coords pos = vec3(c.x, c.y, c.z) end
    return { pos = pos, ent = ent, inside = false }
end

local function stepOcclusion(entry, L, src, dist)
    local oc = cfg().occlusion
    local o = entry.occ
    if not o then o = { v = 0.0, goal = 0.0, h = nil, t = 0 }; entry.occ = o end
    if not oc.enabled or src.inside or dist < oc.minDistance then
        o.goal = 0.0; o.h = nil
        o.v = lerp(o.v, 0.0, 0.3)
        return o.v
    end

    local now = GetGameTimer()
    if o.h then
        local ready, hits = true, 0
        for i = 1, #o.h do
            local rv, hit = GetShapeTestResult(o.h[i])
            if rv == 1 then ready = false break end
            if rv == 2 and hit == 1 then hits = hits + 1 end
        end
        if ready then
            o.goal = hits / #o.h
            o.h = nil
        elseif now - o.t > 400 then
            o.h = nil
        end
    end
    if not o.h and now - o.t >= oc.interval then
        o.t = now
        local from = L.head
        local to = src.pos + vec3(0.0, 0.0, oc.targetHeight)
        local d = to - from
        local len = #d
        if len > 0.01 then
            d = d / len
            local side = vec3(d.y, -d.x, 0.0)
            local sl = #side
            side = sl > 0.001 and (side / sl) or vec3(1.0, 0.0, 0.0)
            local ignore = src.ent ~= 0 and src.ent or L.ped
            o.h = {
                StartShapeTestLosProbe(from.x, from.y, from.z, to.x, to.y, to.z, oc.flags, ignore, 4),
                StartShapeTestLosProbe(from.x, from.y, from.z, to.x + side.x * oc.spread, to.y + side.y * oc.spread, to.z, oc.flags, ignore, 4),
                StartShapeTestLosProbe(from.x, from.y, from.z, to.x - side.x * oc.spread, to.y - side.y * oc.spread, to.z, oc.flags, ignore, 4),
            }
        end
    end
    o.v = lerp(o.v, o.goal, oc.smoothing)
    return o.v
end

function Spatial.margin(st, ppos)
    local D = (st.kind == 'car' and Config.carRadio or Config.boombox).distance
    local pos
    if st.kind == 'car' then
        if not st.netId or not NetworkDoesNetworkIdExist(st.netId) then return -999.0 end
        local ent = NetToVeh(st.netId)
        if ent == 0 or not DoesEntityExist(ent) then return -999.0 end
        pos = GetEntityCoords(ent)
    else
        local c = st.coords
        pos = vec3(c.x, c.y, c.z)
    end
    return D - #(ppos - pos)
end

function Spatial.compute(entry, st, L)
    local C = cfg()
    local kcfg = st.kind == 'car' and Config.carRadio or Config.boombox
    local src = soundSource(st, L)
    if not src then return 0.0, MAXHZ, 0.0 end

    local vol = kcfg.baseVolume * (st.volume or 0.5)
    if src.inside then return vol, MAXHZ, 0.0 end

    local D = kcfg.distance
    local to = src.pos - L.pos
    local dist = #to
    if dist >= D then
        if entry and entry.occ then entry.occ.v = 0.0; entry.occ.h = nil end
        return 0.0, MAXHZ, 0.0
    end

    local gain = vol * falloff(C.falloff[st.kind] or 'exponential', dist, D, C.exponent)
    local lowpass = lerpHz(MAXHZ, C.airAbsorption.minLowpass, (dist / D) ^ C.airAbsorption.curve)

    if src.veh then
        local open = Spatial.vehicleOpenness(src.veh)
        gain = gain * lerp(kcfg.outsideMultiplier, C.vehicle.openGain, open)
        lowpass = math.min(lowpass, lerpHz(kcfg.outsideLowpass, C.vehicle.openLowpass, open))
    end

    if L.enclosed > 0.0 then
        gain = gain * lerp(1.0, C.vehicle.listenerGain, L.enclosed)
        lowpass = math.min(lowpass, lerpHz(MAXHZ, C.vehicle.listenerLowpass, L.enclosed))
    end

    local I = C.interior
    if I.enabled then
        local si = src.ent ~= 0 and GetInteriorFromEntity(src.ent) or GetInteriorAtCoords(src.pos.x, src.pos.y, src.pos.z)
        if si ~= L.interior then
            gain = gain * I.gain
            lowpass = math.min(lowpass, I.lowpass)
        elseif si ~= 0 and src.ent ~= 0 then
            local sr = GetRoomKeyFromEntity(src.ent)
            if sr ~= 0 and L.room ~= 0 and sr ~= L.room then
                gain = gain * I.roomGain
                lowpass = math.min(lowpass, I.roomLowpass)
            end
        end
    end

    local occ = stepOcclusion(entry or {}, L, src, dist)
    if occ > 0.001 then
        local O = C.occlusion
        gain = gain * lerp(1.0, O.gain, occ)
        lowpass = math.min(lowpass, lerpHz(MAXHZ, O.lowpass, occ))
    end

    local pan, back = 0.0, 0.0
    local hl = math.sqrt(to.x * to.x + to.y * to.y)
    if hl > 0.3 then
        local dirx, diry = to.x / hl, to.y / hl
        local P = C.pan
        pan = (dirx * L.right.x + diry * L.right.y) * P.strength * math.min(1.0, hl / P.fullAtDistance)
        back = math.max(0.0, -(dirx * L.fwd.x + diry * L.fwd.y))
        lowpass = math.min(lowpass, lerpHz(MAXHZ, P.rearLowpass, back))
        gain = gain * (1.0 - P.rearGainLoss * back)
    end

    return clamp(gain, 0.0, 1.0), clamp(lowpass, 200.0, MAXHZ), clamp(pan, -1.0, 1.0)
end

local mixRunning = false
local function startMixLoop()
    if mixRunning then return end
    mixRunning = true
    CreateThread(function()
        while true do
            local active, near = false, false
            local pp = GetEntityCoords(PlayerPedId())
            for _, s in pairs(Sounds) do
                if s.state.track then
                    active = true
                    if Spatial.margin(s.state, pp) > -3.0 or (s.last and s.last.g > 0.0) then near = true break end
                end
            end
            if not active then mixRunning = false return end
            if not near then
                Wait(400)
            else
                local L = Spatial.listener()
                for id, s in pairs(Sounds) do
                    if s.state.track then
                        local g, lp, pan = Spatial.compute(s, s.state, L)
                        local l = s.last
                        if not l or math.abs(l.g - g) > 0.01 or math.abs(l.lp - lp) > lp * 0.04 or math.abs(l.pan - pan) > 0.03 then
                            s.last = { g = g, lp = lp, pan = pan }
                            SendNUIMessage({ action = 'mix', id = id, gain = g, lowpass = lp, pan = pan })
                        end
                    end
                end
                Wait(Config.spatial.tick)
            end
        end
    end)
end

local startBoomboxLoop

local function pushMix(id, st)
    local entry = Sounds[id]
    local g, lp, pan = Spatial.compute(entry, st, Spatial.listener())
    if entry then entry.last = { g = g, lp = lp, pan = pan } end
    SendNUIMessage({ action = 'mix', id = id, gain = g, lowpass = lp, pan = pan })
    return g
end

RegisterNetEvent('pena_soundplayer:state', function(id, st)
    local old = Sounds[id]
    Sounds[id] = { state = st, last = old and old.last or nil, occ = old and old.occ or nil }
    if st.track then startMixLoop() end
    if st.kind == 'boombox' then startBoomboxLoop() end
    local g = 0.0
    if st.track then
        local fresh = not old or not old.state.track or old.state.token ~= st.token
            or old.state.loading ~= st.loading or not old.last
        if fresh then g = pushMix(id, st) else g = old.last.g end
    end
    SendNUIMessage({ action = 'state', id = id, state = st, base = getBase(), mode = Config.audioMode })

    local started = st.track and not st.loading and not st.paused
        and (not old or not old.state.track or old.state.loading or old.state.token ~= st.token)
    if started and g > 0.02 then
        SendNUIMessage({ action = 'toast', title = st.track.title, channel = st.track.channel, thumb = st.track.thumb })
    end
end)

RegisterNetEvent('pena_soundplayer:eq', function(id, eq)
    local s = Sounds[id]
    if not s then return end
    s.state.eq = eq
    SendNUIMessage({ action = 'eq', id = id, eq = eq })
end)

RegisterNetEvent('pena_soundplayer:bulk', function(all)
    for id, st in pairs(all) do
        Sounds[id] = { state = st }
        if st.track then pushMix(id, st) startMixLoop() end
        if st.kind == 'boombox' then startBoomboxLoop() end
        SendNUIMessage({ action = 'state', id = id, state = st, base = getBase(), mode = Config.audioMode })
    end
end)

RegisterNetEvent('pena_soundplayer:removed', function(id)
    Sounds[id] = nil
    SendNUIMessage({ action = 'removed', id = id })
    if openId == id then
        nuiOpen, openId = false, nil
        SetNuiFocus(false, false)
        sfx('close')
        SendNUIMessage({ action = 'close' })
    end
end)

RegisterNetEvent('pena_soundplayer:status', function(id, text)
    SendNUIMessage({ action = 'status', id = id, text = text })
end)

AddEventHandler('onClientResourceStart', function(name)
    if name ~= RES then return end
    Wait(1500)
    SendNUIMessage({ action = 'streamer', value = streamerMode, announce = false })
    TriggerServerEvent('pena_soundplayer:server:sync')
end)

local streamerCmd = Config.streamerCommand or 'streamermode'
RegisterCommand(streamerCmd, function()
    streamerMode = not streamerMode
    SetResourceKvpInt('pena_soundplayer:streamer', streamerMode and 1 or 0)
    SendNUIMessage({ action = 'streamer', value = streamerMode, announce = true })
end, false)

CreateThread(function()
    Wait(2000)
    TriggerEvent('chat:addSuggestion', '/' .. streamerCmd, locale('streamer.help'))
end)
AddEventHandler('onResourceStop', function(name)
    if name == RES then TriggerEvent('chat:removeSuggestion', '/' .. streamerCmd) end
end)

exports('isStreamerMode', function() return streamerMode end)

local function openUI(id)
    if nuiOpen or not loggedIn() then return end
    nuiOpen, openId = true, id
    SetNuiFocus(true, true)
    sfx('open')
    SendNUIMessage({
        action = 'open', id = id, base = getBase(), accent = Config.accent,
        theme = Config.theme, themeSwitcher = Config.themeSwitcher == true,
        kind = id:sub(1, 4) == 'car:' and 'car' or 'boombox',
    })
    watchOpenUI()
end

local function closeUI()
    if not nuiOpen then return end
    nuiOpen, openId = false, nil
    SetNuiFocus(false, false)
    sfx('close')
    SendNUIMessage({ action = 'close' })
end

RegisterNUICallback('close', function(_, cb) closeUI() cb('ok') end)

RegisterNUICallback('search', function(data, cb)
    local r = Callback.await('pena_soundplayer:search', data and data.q)
    cb(r or { ok = false, error = locale('err.searchFailed') })
end)

RegisterNUICallback('sfx', function(data, cb)
    if data and type(data.name) == 'string' then sfx(data.name) end
    cb('ok')
end)

RegisterNUICallback('ready', function(data, cb)
    if data and type(data.id) == 'string' and type(data.token) == 'number' then
        TriggerServerEvent('pena_soundplayer:server:ready', data.id, data.token)
    end
    cb('ok')
end)

local RPC = {
    ['data'] = true, ['pl:create'] = true, ['pl:delete'] = true, ['pl:rename'] = true, ['pl:add'] = true,
    ['pl:remove'] = true, ['pl:share'] = true, ['pl:import'] = true,
    ['eq:save'] = true, ['eq:delete'] = true, ['eq:share'] = true, ['eq:import'] = true,
}
RegisterNUICallback('rpc', function(data, cb)
    if not data or type(data.name) ~= 'string' or not RPC[data.name] then
        return cb({ ok = false, error = locale('err.unknownAction') })
    end
    local a = type(data.args) == 'table' and data.args or {}
    local r = Callback.await('pena_soundplayer:' .. data.name, a[1], a[2])
    cb(r or { ok = false, error = locale('err.noAnswer') })
end)

RegisterNUICallback('playlist', function(data, cb)
    if data and openId and data.id == openId then
        TriggerServerEvent('pena_soundplayer:server:playlist', openId, data.plId, data.mode, data.shuffle == true)
    end
    cb('ok')
end)

RegisterNUICallback('copy', function(data, cb)
    if data and type(data.text) == 'string' then
        SendNUIMessage({ action = 'clipboard', text = data.text })
        notify(locale('copied'), 'success')
    end
    cb('ok')
end)

RegisterNUICallback('chunk', function(data, cb)
    local r = data and Callback.await('pena_soundplayer:chunk', data.id, data.n)
    cb(r or { ok = false })
end)

RegisterNUICallback('play', function(data, cb)
    if data and openId and data.id == openId then
        TriggerServerEvent('pena_soundplayer:server:play', openId, data.ref, data.mode)
    end
    cb('ok')
end)

RegisterNUICallback('ctl', function(data, cb)
    if data and openId and data.id == openId then
        TriggerServerEvent('pena_soundplayer:server:ctl', openId, data.type, data.value)
    end
    cb('ok')
end)

local watchId = 0
watchOpenUI = function()
    watchId = watchId + 1
    local me = watchId
    CreateThread(function()
        while nuiOpen and openId and watchId == me do
            Wait(500)
            if not (nuiOpen and openId and watchId == me) then return end
            if openId:sub(1, 4) == 'car:' then
                if GetVehiclePedIsIn(PlayerPedId(), false) == 0 then closeUI() end
            else
                local s = Sounds[openId]
                if not s then closeUI()
                else
                    local c = s.state.coords
                    if #(GetEntityCoords(PlayerPedId()) - vec3(c.x, c.y, c.z)) > Config.boombox.controlDistance + 3.0 then
                        closeUI()
                    end
                end
            end
        end
    end)
end

local function tryOpenCarRadio()
    if nuiOpen or not loggedIn() then return end
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or not NetworkGetEntityIsNetworked(veh) then return end
    local mode = Config.carRadio.allowedSeats
    local allowed = mode == 'any'
        or GetPedInVehicleSeat(veh, -1) == ped
        or (mode == 'front' and GetPedInVehicleSeat(veh, 0) == ped)
    if not allowed then return notify(locale('car.badSeat'), 'error') end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    if not Callback.await('pena_soundplayer:canUse', netId) then
        sfx('error')
        return notify(locale('car.noRadio'), 'error')
    end
    if nuiOpen then return end
    openUI('car:' .. netId)
end

if Config.carRadio.enabled then
    RegisterCommand('+pena_soundplayer_radio', tryOpenCarRadio, false)
    RegisterCommand('-pena_soundplayer_radio', function() end, false)
    RegisterKeyMapping('+pena_soundplayer_radio', locale('keymap.radio'), 'keyboard', Config.carRadio.key)
end

local function placeBoombox()
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) or IsEntityDead(ped) then return notify(locale('boombox.cannotPlace'), 'error') end

    local model = joaat(Config.boombox.model)
    local dict = 'anim@heists@money_grab@briefcase'
    if not requestModel(model, 5000) or not requestAnimDict(dict, 5000) then
        return notify(locale('boombox.cannotPlace'), 'error')
    end
    TaskPlayAnim(ped, dict, 'put_down_case', 8.0, -8.0, 1200, 48, 0.0, false, false, false)
    Wait(800)

    local c = GetOffsetFromEntityInWorldCoords(ped, 0.0, 0.9, 0.0)
    local obj = CreateObject(model, c.x, c.y, c.z, true, true, false)
    SetEntityHeading(obj, GetEntityHeading(ped) + 180.0)
    PlaceObjectOnGroundProperly(obj)
    FreezeEntityPosition(obj, true)
    SetModelAsNoLongerNeeded(model)
    RemoveAnimDict(dict)

    TriggerServerEvent('pena_soundplayer:server:boomboxPlaced', NetworkGetNetworkIdFromEntity(obj))
end

RegisterNetEvent('pena_soundplayer:client:placeBoombox', placeBoombox)

startBoomboxLoop = function()
    if boomboxRunning or not Config.boombox.enabled then return end
    boomboxRunning = true
    AddTextEntry('PENA_SOUNDPLAYER_PROMPT', locale('boombox.prompt'))
    CreateThread(function()
        while true do
            local sleep = 500
            local nearId, nearDist, any = nil, nil, false
            local pcoords
            for id, s in pairs(Sounds) do
                if s.state.kind == 'boombox' then
                    any = true
                    if not nuiOpen and loggedIn() then
                        pcoords = pcoords or GetEntityCoords(PlayerPedId())
                        local c = s.state.coords
                        local d = #(pcoords - vec3(c.x, c.y, c.z))
                        if d <= Config.boombox.controlDistance and (not nearDist or d < nearDist) then
                            nearId, nearDist = id, d
                        end
                    end
                end
            end
            if not any then
                boomboxRunning = false
                return
            end
            if nearId then
                sleep = 0
                BeginTextCommandDisplayHelp('PENA_SOUNDPLAYER_PROMPT')
                EndTextCommandDisplayHelp(0, false, false, -1)
                if IsControlJustReleased(0, 38) then
                    openUI(nearId)
                elseif IsControlJustReleased(0, 47) then
                    TriggerServerEvent('pena_soundplayer:server:pickup', nearId)
                end
            end
            Wait(sleep)
        end
    end)
end

AddEventHandler('onResourceStop', function(name)
    if name ~= RES then return end
    if nuiOpen then SetNuiFocus(false, false) end
end)
