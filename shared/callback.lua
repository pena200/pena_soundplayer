local RES = GetCurrentResourceName()
local requestEvent = RES .. ':cb:request'
local responseEvent = RES .. ':cb:response'

Callback = {}

if IsDuplicityVersion() then
    local handlers = {}

    function Callback.register(name, fn)
        handlers[name] = fn
    end

    RegisterNetEvent(requestEvent, function(id, name, ...)
        local src = source
        if type(id) ~= 'number' or type(name) ~= 'string' then return end
        local handler = handlers[name]
        if not handler then return end
        local ok, result = pcall(handler, src, ...)
        if not ok then
            print(('^1[%s] callback %s failed: %s^7'):format(RES, name, tostring(result)))
            result = nil
        end
        TriggerClientEvent(responseEvent, src, id, result)
    end)
else
    local pending = {}
    local seq = 0

    function Callback.await(name, ...)
        seq = seq + 1
        local id = seq
        local p = promise.new()
        pending[id] = p
        SetTimeout(90000, function()
            if pending[id] then
                pending[id] = nil
                p:resolve(nil)
            end
        end)
        TriggerServerEvent(requestEvent, id, name, ...)
        return Citizen.Await(p)
    end

    RegisterNetEvent(responseEvent, function(id, result)
        local p = pending[id]
        if not p then return end
        pending[id] = nil
        p:resolve(result)
    end)
end
