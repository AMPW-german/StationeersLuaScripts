--#region User Config
local co2FilterSlots = { 4, 5, 6 } -- Set these to the CO2-filter slots in your suit.
local targetPressure = 80 -- kPa
local targetTemperature = 25 -- degrees C
local minSafePressure = 35 -- kPa
local maxSafePressure = 120 -- kPa
local minSafeOxygenPartialPressure = 20 -- kPa
local minSafeTemperature = 11 -- degrees C
local maxSafeTemperature = 49 -- degrees C
--#endregion

local dRead = ic.read
local dWrite = ic.write
local dSlotRead = ic.read_slot
local suit = ic.const.BASE_UNIT_INDEX
local helmet = 0
local LT = ic.enums.LogicType
local SLT = ic.enums.LogicSlotType
local blinking = false
local lastBlinkTime = -0.5
local blinkInterval = 0.5
local lastSuitValues = {}
local manuallyClosedVisor = false
local lastObservedVisorOpen = nil

local function readHelmet(logicType)
    local ok, value = pcall(dRead, helmet, logicType)
    if not ok then
        return nil
    end

    return value
end

local function writeHelmet(logicType, value)
    if readHelmet(LT.Open) == nil then
        return false
    end

    return pcall(dWrite, helmet, logicType, value)
end

local function resetHelmetState()
    blinking = false
    lastBlinkTime = -0.5
    manuallyClosedVisor = false
    lastObservedVisorOpen = nil
end

local function writeSuitIfChanged(logicType, value)
    if lastSuitValues[logicType] ~= value then
        dWrite(suit, logicType, value)
        lastSuitValues[logicType] = value
    end
end

local function writeSuitSettingInteger(logicType, integerValue)
    local currentValue = dRead(suit, logicType) or 0
    local currentInteger = math.floor(currentValue)

    if currentInteger ~= integerValue then
        local value = integerValue + (currentValue - currentInteger)
        dWrite(suit, logicType, value)
        lastSuitValues[logicType] = value
    end
end

local function setHelmetLock(locked)
    local value = locked and 1 or 0
    if readHelmet(LT.Lock) ~= value then
        return writeHelmet(LT.Lock, value)
    end

    return true
end

local function isEnvironmentSafe()
    local pressure = dRead(suit, LT.PressureExternal) or 0
    local temperature = util.temp(dRead(suit, LT.TemperatureExternal) or 0)
    local oxygenRatio = dRead(suit, LT.RatioOxygenOutput) or 0
    local hydrogenRatio = dRead(suit, LT.RatioHydrogenOutput) or 0
    local methaneRatio = dRead(suit, LT.RatioMethaneOutput) or 0
    local pollutantRatio = dRead(suit, LT.RatioPollutantOutput) or 0
    local oxygenPartialPressure = pressure * oxygenRatio

    return pressure >= minSafePressure and pressure <= maxSafePressure
        and temperature >= minSafeTemperature and temperature <= maxSafeTemperature
        and oxygenPartialPressure >= minSafeOxygenPartialPressure
        and hydrogenRatio == 0
        and methaneRatio == 0
        and pollutantRatio == 0
end

local function lastCO2FilterIsLow()
    local lastInstalledSlot = nil

    for _, slot in ipairs(co2FilterSlots) do
        if dSlotRead(suit, slot, SLT.Occupied) == 1 then
            lastInstalledSlot = slot
        end
    end

    if lastInstalledSlot == nil then
        return false
    end

    local ok, quantity = pcall(dSlotRead, suit, lastInstalledSlot, SLT.Quantity)
    return ok and quantity ~= nil and quantity < 0.25
end

local function activateLifeSupport()
    if readHelmet(LT.Open) ~= nil then
        writeHelmet(LT.Lock, 0)
        writeHelmet(LT.Open, 0)
        writeHelmet(LT.Lock, 1)
    end
    pcall(dWrite, suit, LT.On, 1)
    pcall(dWrite, suit, LT.Filtration, 1)
    pcall(dWrite, suit, LT.AirRelease, 1)
    lastSuitValues[LT.On] = 1
    lastSuitValues[LT.Filtration] = 1
    lastSuitValues[LT.AirRelease] = 1
end

local function setVisorOpen(shouldOpen)
    local currentOpenValue = readHelmet(LT.Open)
    if currentOpenValue == nil then
        return nil
    end

    local currentOpen = currentOpenValue == 1

    if currentOpen ~= shouldOpen then
        if not setHelmetLock(false) or not writeHelmet(LT.Open, shouldOpen and 1 or 0) then
            return nil
        end

        currentOpenValue = readHelmet(LT.Open)
        if currentOpenValue == nil then
            return nil
        end

        currentOpen = currentOpenValue == 1
    end

    if currentOpen == shouldOpen and not shouldOpen then
        if not setHelmetLock(true) then
            return nil
        end
    end

    return currentOpen
end

while true do
    ic.yield()

    local ok, err = pcall(function()
        writeSuitSettingInteger(LT.PressureSetting, math.floor(targetPressure))
        writeSuitSettingInteger(LT.TemperatureSetting, math.floor(util.temp(targetTemperature, "C", "K")))

        -- 12 digits can be transmitted via the temperature and pressure settings
        -- "Setting" is a full float
        -- "Error" adds an unsigned integer
        -- "Volume" adds an unsigned float -- should be used for storm warning so shouldn't be used for transmitting data (or non essential data that gets ignored during a storm warning)

        local visorCurrentlyOpen = readHelmet(LT.Open)
        if visorCurrentlyOpen == nil then
            resetHelmetState()
            activateLifeSupport()
            return
        end

        local environmentSafe = isEnvironmentSafe()
        visorCurrentlyOpen = visorCurrentlyOpen == 1
        local visorShouldOpen = false

        if not environmentSafe then
            manuallyClosedVisor = false
        else
            if lastObservedVisorOpen == true and not visorCurrentlyOpen then
                manuallyClosedVisor = true
            end

            visorShouldOpen = not manuallyClosedVisor
        end

        local visorIsOpen = setVisorOpen(visorShouldOpen)
        if visorIsOpen == nil then
            resetHelmetState()
            activateLifeSupport()
            return
        end

        lastObservedVisorOpen = visorIsOpen

        if visorIsOpen then
            writeSuitIfChanged(LT.On, 0)
            writeSuitIfChanged(LT.Filtration, 0)
            writeSuitIfChanged(LT.AirRelease, 0)
        else
            writeSuitIfChanged(LT.On, 1)
            writeSuitIfChanged(LT.Filtration, 1)
            writeSuitIfChanged(LT.AirRelease, 1)
        end

        if lastCO2FilterIsLow() then
            local now = util.game_time()
            if now - lastBlinkTime >= blinkInterval then
                blinking = not blinking
                lastBlinkTime = now
                writeHelmet(LT.On, blinking and 1 or 0)
            end
        elseif blinking then
            blinking = false
            writeHelmet(LT.On, 0)
        end
    end)

    if not ok then
        activateLifeSupport()
        error(err, 0)
    end
end