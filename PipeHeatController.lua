local LT = ic.enums.LogicType

local waterReader = ic.find("WaterReader")
local airPump = ic.find("AirPump")
local airValve = ic.find("CoolingValve")
local airInput = ic.find("CoolingAirIntake")
local airVent = ic.find("CoolingAirOutPut")

if waterReader == nil then
    error("WaterReader not found")
elseif airPump == nil then
    error("AirPump not found")
elseif airValve == nil then
    error("CoolingValve not found")
elseif airInput == nil then
    error("CoolingAirIntake not found")
elseif airVent == nil then
    error("CoolingAirOutPut not found")
end

ic.write_id(airInput, LT.On, 1)
ic.write_id(airInput, LT.Mode, 1) -- Inwards

ic.write_id(airVent, LT.On, 1)
ic.write_id(airVent, LT.Mode, 0) -- Outwards

yield()

ic.write_id(airInput, LT.PressureInternal, 2000)
ic.write_id(airInput, LT.PressureExternal, 10)
ic.write_id(airVent, LT.PressureInternal, 2000)
ic.write_id(airVent, LT.PressureExternal, 50000)

ic.write_id(airPump, LT.On, 0)
ic.write_id(airValve, LT.On, 0)
ic.write_id(airInput, LT.On, 0)
ic.write_id(airVent, LT.On, 0)

local pumpOn = false

local enableTemperature = 300.15 -- 27 C in Kelvin
local disableTemperature = 295.15 -- 22 C in Kelvin

function tick(dt)
    local waterTemperature = ic.read_id(waterReader, LT.Temperature)

    if waterTemperature > enableTemperature and not pumpOn then
        pumpOn = true
        ic.write_id(airPump, LT.On, 1)
        ic.write_id(airValve, LT.On, 1)
        ic.write_id(airInput, LT.On, 1)
        ic.write_id(airVent, LT.On, 1)
    elseif waterTemperature < disableTemperature and pumpOn then
        pumpOn = false
        ic.write_id(airPump, LT.On, 0)
        ic.write_id(airValve, LT.On, 0)
        ic.write_id(airInput, LT.On, 0)
        ic.write_id(airVent, LT.On, 0)
    end
end