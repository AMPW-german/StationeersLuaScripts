local LT = ic.enums.LogicType

local N2OCoolingValve = ic.find("N2OCoolingValve")
local N2OAnalyzer = ic.find("N2OAnalyzer")
local H2CoolingValve = ic.find("H2CoolingValve")
local H2CoolingAnalyzer = ic.find("H2CoolingAnalyzer")
local H2Analyzer = ic.find("H2Analyzer")

if N2OCoolingValve == nil then
    error("N2OCoolingValve not found")
elseif N2OAnalyzer == nil then
    ic.write_id(N2OCoolingValve, LT.On, 0)
    error("N2OAnalyzer not found")
end

local N2ODisableTemperature = 255.15 -- 22 C in Kelvin

while true do
    local N2OTemperature = ic.read_id(N2OAnalyzer, LT.Temperature)

    if N2OTemperature > N2ODisableTemperature then
        ic.write_id(N2OCoolingValve, LT.On, 1)
    else
        ic.write_id(N2OCoolingValve, LT.On, 0)
    end
    yield()
end

