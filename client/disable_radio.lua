if not Config.disableDefaultRadio then return end

local function silence(veh)
    SetUserRadioControlEnabled(false)
    if veh and veh ~= 0 and DoesEntityExist(veh) then
        SetVehRadioStation(veh, 'OFF')
        SetVehicleRadioEnabled(veh, false)
    end
end

CreateThread(function()
    local last = nil
    while true do
        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if veh ~= last then
            last = veh
            silence(veh)
        end
        Wait(500)
    end
end)
