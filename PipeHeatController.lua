local LT = ic.enums.LogicType

local waterReader = ic.find("WaterReader")
local airPump = ic.find("AirPump")
local airValves = ic.find_all("CoolingValve")
local airInputs = ic.find_all("CoolingAirIntake")
local airVents = ic.find_all("CoolingAirOutPut")
local roomVentInput = ic.find_all("PressurizeVent")
local roomVentOutput = ic.find_all("CoolingVent")
local roomSensor = ic.find("ServerRoomGasSensor")

local function write_all(devices, logicType, value)
    for _, device in ipairs(devices) do
        ic.write_id(device, logicType, value)
    end
end

local tickCounter = 0
local function set_vent_target_pressures()
    write_all(airInputs, LT.PressureInternal, 1750)
    write_all(airInputs, LT.PressureExternal, 10)
    write_all(airVents, LT.PressureInternal, 1650)
    write_all(airVents, LT.PressureExternal, 50000)
end

local function set_room_vent_targets()
    write_all(roomVentInput, LT.PressureExternal, 38)
    write_all(roomVentOutput, LT.PressureExternal, 90)
end

if waterReader == nil then
    error("WaterReader not found")
elseif airPump == nil then
    error("AirPump not found")
elseif #airValves == 0 then
    error("CoolingValve not found")
elseif #airInputs == 0 then
    error("CoolingAirIntake not found")
elseif #airVents == 0 then
    error("CoolingAirOutPut not found")
elseif #roomVentInput == 0 then
    error("PressurizeVent not found")
elseif #roomVentOutput == 0 then
    error("CoolingVent not found")
elseif roomSensor == nil then
    error("ServerRoomGasSensor not found")
end

write_all(airInputs, LT.On, 1)
write_all(airInputs, LT.Mode, 1) -- Inwards

write_all(airVents, LT.On, 1)
write_all(airVents, LT.Mode, 0) -- Outwards

write_all(roomVentInput, LT.Mode, 1) -- Inwards (outside the room)
write_all(roomVentOutput, LT.Mode, 1) -- Inwards (inside the room)
set_room_vent_targets()

yield()

ic.write_id(airPump, LT.On, 0)
write_all(airValves, LT.On, 0)
write_all(airInputs, LT.On, 0)
write_all(airVents, LT.On, 0)
write_all(roomVentInput, LT.On, 0)
write_all(roomVentOutput, LT.On, 0)

local pumpOn = false

local enableTemperature = 300.15 -- 27 C in Kelvin
local disableTemperature = 295.15 -- 22 C in Kelvin
local minimumRoomTemperature = 305.15 -- 32 C in Kelvin
local maximumRoomPressure = 120
local minimumRoomPressure = 95

while true do
    tickCounter = tickCounter + 1
    if tickCounter >= 25 then
        set_vent_target_pressures()
        set_room_vent_targets()
        tickCounter = 0
    end

    local waterTemperature = ic.read_id(waterReader, LT.Temperature)
    local roomTemperature = ic.read_id(roomSensor, LT.Temperature)
    local roomPressure = ic.read_id(roomSensor, LT.Pressure)

    -- Low room temperature overrides the input vent's pressure control.
    if roomTemperature < minimumRoomTemperature or roomPressure > maximumRoomPressure then
        write_all(roomVentInput, LT.On, 0)
    else
        write_all(roomVentInput, LT.On, 1)
    end

    if roomPressure < minimumRoomPressure then
        write_all(roomVentOutput, LT.On, 0)
    else
        write_all(roomVentOutput, LT.On, 1)
    end

    if waterTemperature > enableTemperature and not pumpOn then
        pumpOn = true
        ic.write_id(airPump, LT.On, 1)
        write_all(airValves, LT.On, 1)
        write_all(airInputs, LT.On, 1)
        write_all(airVents, LT.On, 1)
    elseif waterTemperature < disableTemperature and pumpOn then
        pumpOn = false
        ic.write_id(airPump, LT.On, 0)
        write_all(airValves, LT.On, 0)
        write_all(airInputs, LT.On, 0)
        write_all(airVents, LT.On, 0)
    end

    yield()
end