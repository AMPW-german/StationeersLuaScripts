local LT = ic.enums.LogicType

local N2OCoolingValve = ic.find("N2OCoolingValve")
local N2OAnalyzer = ic.find("N2OAnalyzer")
local H2CoolingValve = ic.find("H2CoolingValve")
local H2CoolingAnalyzer = ic.find("H2CoolingAnalyzer")
local H2Analyzer = ic.find("H2Analyzer")

local function closeValve(valve)
    if valve ~= nil then
        ic.write_id(valve, LT.On, 0)
    end
end

local missingDevices = {}

if N2OCoolingValve == nil then
    table.insert(missingDevices, "N2OCoolingValve")
end

if N2OAnalyzer == nil then
    table.insert(missingDevices, "N2OAnalyzer")
end

if H2CoolingValve == nil then
    table.insert(missingDevices, "H2CoolingValve")
end

if H2CoolingAnalyzer == nil then
    table.insert(missingDevices, "H2CoolingAnalyzer")
end

if H2Analyzer == nil then
    table.insert(missingDevices, "H2Analyzer")
end

if #missingDevices > 0 then
    closeValve(N2OCoolingValve)
    closeValve(H2CoolingValve)
    error(table.concat(missingDevices, ", ") .. " not found")
end

ic.write_id(N2OAnalyzer, LT.On, 1)
ic.write_id(H2CoolingAnalyzer, LT.On, 1)
ic.write_id(H2Analyzer, LT.On, 1)

local N2ODisableTemperature = 255.15 -- 22 C in Kelvin
local H2CloseTemperature = 68.15 -- -205 C in Kelvin
local H2OpenTemperature = 63.15 -- -210 C in Kelvin

while true do
    local N2OTemperature = ic.read_id(N2OAnalyzer, LT.Temperature)
    local N2OLiquidRatio = ic.read_id(N2OAnalyzer, LT.RatioNitrousOxide)
    local H2CoolingTemperature = ic.read_id(H2CoolingAnalyzer, LT.Temperature)
    local H2Temperature = ic.read_id(H2Analyzer, LT.Temperature)
    local H2LiquidRatio = ic.read_id(H2Analyzer, LT.RatioLiquidHydrogen)

    if N2OLiquidRatio > 0.95 then
        ic.write_id(N2OCoolingValve, LT.On, 0)
    elseif N2OTemperature > N2ODisableTemperature then
        ic.write_id(N2OCoolingValve, LT.On, 1)
    else
        ic.write_id(N2OCoolingValve, LT.On, 0)
    end

    if H2LiquidRatio > 0.95 or H2Temperature < H2CoolingTemperature or H2CoolingTemperature > H2CloseTemperature then
        ic.write_id(H2CoolingValve, LT.On, 0)
    elseif H2CoolingTemperature < H2OpenTemperature then
        ic.write_id(H2CoolingValve, LT.On, 1)
    end

    yield()
end

