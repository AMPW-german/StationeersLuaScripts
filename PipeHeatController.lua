local LT = ic.enums.LogicType

local roomVentInput = ic.find_all("PressurizeVent")
local roomVentOutput = ic.find_all("CoolingVent")
local roomSensor = ic.find("ServerRoomGasSensor")

local function write_all(devices, logicType, value)
    for _, device in ipairs(devices) do
        ic.write_id(device, logicType, value)
    end
end

local tickCounter = 0

local function set_room_vent_targets()
    write_all(roomVentInput, LT.PressureExternal, 32)
    write_all(roomVentOutput, LT.PressureExternal, 90)
end

if #roomVentInput == 0 then
    error("PressurizeVent not found")
elseif #roomVentOutput == 0 then
    error("CoolingVent not found")
elseif roomSensor == nil then
    error("ServerRoomGasSensor not found")
end

write_all(roomVentInput, LT.Mode, 1) -- Inwards (outside the room)
write_all(roomVentOutput, LT.Mode, 1) -- Inwards (inside the room)
set_room_vent_targets()

yield()

write_all(roomVentInput, LT.On, 0)
write_all(roomVentOutput, LT.On, 0)

local pumpOn = false

local minimumRoomTemperature = 305.15 -- 32 C in Kelvin
local maximumRoomPressure = 120
local minimumRoomPressure = 95

while true do
    tickCounter = tickCounter + 1
    if tickCounter >= 25 then
        set_room_vent_targets()
        tickCounter = 0
    end

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

    yield()
end