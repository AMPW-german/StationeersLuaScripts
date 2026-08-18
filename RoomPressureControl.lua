local LT  = ic.enums.LogicType
local LBM = ic.enums.LogicBatchMethod

local vent = ic.find("RegulatorVent")
local atmSensor = ic.find("RegulatorSensor")
local pipeSensor = ic.find("PipeSensor")
local emptySwitch = ic.find("EmptySwitch")

if vent == nil or atmSensor == nil then
    return
end

local inwardsSet = false
local inwardsSet2 = false
local outwardsSet = false
local outwardsSet2 = false
    
while true do
    local pressure = ic.read_id(atmSensor, LT.Pressure)
    local pipePressure = ic.read_id(pipeSensor, LT.Pressure)
    
    if pressure < 105 and pressure > 95 or pipePressure <= 5 and pressure < 80 then
        inwardsSet = false
        inwardsSet2 = false
        outwardsSet = false
        outwardsSet2 = false
        ic.write_id(vent, LT.On, 0)
    elseif pressure > 110 then
        if not inwardsSet then
            inwardsSet = true
            inwardsSet2 = false
            outwardsSet = false
            outwardsSet2 = false
        
            ic.write_id(vent, LT.On, 1)
            ic.write_id(vent, LT.Mode, 1)
        elseif not inwardsSet2 then
            inwardsSet2 = true
            ic.write_id(vent, LT.PressureInternal, 45000)
            ic.write_id(vent, LT.PressureExternal, 100)
        
            local pressureInt = ic.read_id(vent, LT.PressureInternal)
            local pressureExt = ic.read_id(vent, LT.PressureExternal)
            print("Inwards: Int: ", pressureInt, ", Ext: ", pressureExt)
        end
    elseif pressure < 90 then
        if not outwardsSet then
            inwardsSet = false
            inwardsSet2 = false
            outwardsSet = true
            outwardsSet2 = false
        
            ic.write_id(vent, LT.On, 1)
            ic.write_id(vent, LT.Mode, 0)
        elseif not outwardsSet2 then
            outwardsSet2 = true
            ic.write_id(vent, LT.PressureInternal, 0)
            ic.write_id(vent, LT.PressureExternal, 100)
        
            local pressureInt = ic.read_id(vent, LT.PressureInternal)
            local pressureExt = ic.read_id(vent, LT.PressureExternal)
            print("Inwards: Int: ", pressureInt, ", Ext: ", pressureExt)
        end
    end

    yield()
end