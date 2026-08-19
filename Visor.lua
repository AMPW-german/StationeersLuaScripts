local hud = ss.hud.surface("main")
ss.hud.activate("main")

--#region User Config
local rightEdgeOffset = 80 -- Pixels reserved at the right edge for stock visor icons.
local homebaseX = 1200 -- Homebase world X coordinate.
local homebaseZ = 980 -- Homebase world Z coordinate.
--#endregion

local LT = ic.enums.LogicType
local REFRESH_INTERVAL = 0.25
local refreshElapsed = REFRESH_INTERVAL
local STATUS_WIDTH = 180
local NAV_SIZE = 48
local NAV_CANVAS_ID = "home_direction"
local WAYPOINT_PERSIST_KEY = "saved_waypoint"
local WAYPOINT_ROW_GAP = 8
local WAYPOINT_DELETE_SIZE = 20
local WAYPOINT_DELETE_WIDTH = 46
local LENS_RGB = {
    black = { 0, 0, 0 },
    blue = { 59, 130, 246 },
    cyan = { 6, 182, 212 },
    green = { 34, 197, 94 },
    grey = { 148, 163, 184 },
    orange = { 249, 115, 22 },
    pink = { 236, 72, 153 },
    purple = { 168, 85, 247 },
    red = { 239, 68, 68 },
    white = { 255, 255, 255 },
    yellow = { 234, 179, 8 },
}

local function safeReadId(ref, logicType, quiet)
    local ok, valueOrError = pcall(ic.read_id, ref, logicType)
    if not ok then
        if not quiet then
            print(string.format("[Visor] read_id failed for ref %s, logic %s: %s", tostring(ref), tostring(logicType), tostring(valueOrError)))
        end
        return nil
    end

    local value = valueOrError
    if ok and type(value) == "number" and value == value then
        return value
    end
    return nil
end

local function findSuitRef()
    local ok, devicesOrError = pcall(ic.device_list)
    if not ok then
        print("[Visor] device_list failed: " .. tostring(devicesOrError))
        return nil
    end

    local devices = devicesOrError
    if not ok or type(devices) ~= "table" then
        return nil
    end

    for _, device in ipairs(devices) do
        local ref = math.floor(tonumber(device.ref_id) or 0)
        if ref ~= 0
            and safeReadId(ref, LT.Filtration, true) ~= nil
            and safeReadId(ref, LT.RatioOxygen, true) ~= nil
            and safeReadId(ref, LT.Pressure, true) ~= nil then
            return ref
        end
    end

    return nil
end

local function formatStormTimer(seconds)
    return string.format("%02d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function lensRgb(color)
    local hex = type(color) == "string" and color:match("#?(%x%x%x%x%x%x)")
    if hex then
        return tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16), tonumber(hex:sub(5, 6), 16)
    end

    local rgb = LENS_RGB[type(color) == "string" and color:lower() or ""]
    if rgb then
        return rgb[1], rgb[2], rgb[3]
    end
    return 255, 255, 255
end

local function bearingDegrees(deltaX, deltaZ)
    if deltaX == 0 and deltaZ == 0 then
        return 0
    end

    local bearing = math.deg(math.atan(deltaX / deltaZ))
    if deltaZ < 0 then
        bearing = bearing + 180
    elseif deltaX < 0 then
        bearing = bearing + 360
    end
    return (bearing + 180) % 360
end

local function readHomeNavigation(suitRef)
    if not suitRef then
        return nil
    end

    local positionX = safeReadId(suitRef, LT.PositionX)
    local positionZ = safeReadId(suitRef, LT.PositionZ)
    if not positionX or not positionZ then
        return nil
    end

    local deltaX = homebaseX - positionX
    local deltaZ = homebaseZ - positionZ
    local distance = math.sqrt(deltaX * deltaX + deltaZ * deltaZ)
    local bearing = bearingDegrees(deltaX, deltaZ)
    local forwardX = safeReadId(suitRef, LT.ForwardX)
    local forwardZ = safeReadId(suitRef, LT.ForwardZ)
    local relativeBearing = nil
    if forwardX ~= nil and forwardZ ~= nil then
        relativeBearing = (bearing - bearingDegrees(forwardX, forwardZ)) % 360
    end

    return {
        distance = distance,
        bearing = bearing,
        relativeBearing = relativeBearing,
    }
end

local savedWaypoints = {}
local buildHud

local function saveWaypoints()
    local ok, jsonOrError = pcall(util.json.encode, savedWaypoints)
    if not ok or type(jsonOrError) ~= "string" then
        print("[Visor] waypoints encoding failed: " .. tostring(jsonOrError))
        return false
    end
    if not ic.persist.set(WAYPOINT_PERSIST_KEY, jsonOrError) then
        print("[Visor] waypoints persistence failed")
        return false
    end
    return true
end

local function restoreWaypoints()
    if not ic.persist.has(WAYPOINT_PERSIST_KEY) then
        return
    end

    local blob = ic.persist.get(WAYPOINT_PERSIST_KEY)
    if type(blob) ~= "string" or blob == "" then
        return
    end
    local ok, waypointsOrError = pcall(util.json.decode, blob)
    if not ok or type(waypointsOrError) ~= "table" then
        print("[Visor] waypoints restore failed: " .. tostring(waypointsOrError))
        return
    end

    for index, waypoint in ipairs(waypointsOrError) do
        local x = type(waypoint) == "table" and tonumber(waypoint.x) or nil
        local z = type(waypoint) == "table" and tonumber(waypoint.z) or nil
        if x ~= nil and z ~= nil then
            savedWaypoints[#savedWaypoints + 1] = {
                x = x,
                z = z,
                name = tostring(waypoint.name or ("WAYPOINT " .. tostring(index))),
            }
        end
    end
end

local function navigationTo(suitRef, targetX, targetZ)
    targetX = tonumber(targetX)
    targetZ = tonumber(targetZ)
    if not suitRef or targetX == nil or targetZ == nil then
        return nil
    end

    local positionX = safeReadId(suitRef, LT.PositionX)
    local positionZ = safeReadId(suitRef, LT.PositionZ)
    if not positionX or not positionZ then
        return nil
    end

    local deltaX = targetX - positionX
    local deltaZ = targetZ - positionZ
    local bearing = bearingDegrees(deltaX, deltaZ)
    local forwardX = safeReadId(suitRef, LT.ForwardX)
    local forwardZ = safeReadId(suitRef, LT.ForwardZ)
    return {
        distance = math.sqrt(deltaX * deltaX + deltaZ * deltaZ),
        bearing = bearing,
        relativeBearing = forwardX and forwardZ and (bearing - bearingDegrees(forwardX, forwardZ)) % 360 or nil,
    }
end

local function addWaypoint(suitRef)
    if not suitRef then
        return
    end

    local x = safeReadId(suitRef, LT.PositionX)
    local z = safeReadId(suitRef, LT.PositionZ)
    if x == nil or z == nil then
        print("[Visor] waypoint add failed: suit position unavailable")
        return
    end

    savedWaypoints[#savedWaypoints + 1] = {
        x = x,
        z = z,
        name = "WAYPOINT " .. tostring(#savedWaypoints + 1),
    }
    if saveWaypoints() then
        buildHud()
    end
end

local function deleteWaypoint(index)
    table.remove(savedWaypoints, index)
    if saveWaypoints() then
        buildHud()
    end
end

local function paintNavigationArrow(canvasId, bearing, lensColor)
    local red, green, blue = lensRgb(lensColor)
    local center = NAV_SIZE / 2
    local radius = 17
    local angle = math.rad(((-bearing or 0) - 90) % 360)
    local pointX = center + math.sin(angle) * radius
    local pointY = center - math.cos(angle) * radius

    hud:canvas_with_update(canvasId, function()
        hud:canvas_clear(canvasId, 0, 0, 0, 0)
        hud:canvas_circle(canvasId, center, center, radius, red, green, blue, 160, 1)
        hud:canvas_line(canvasId, center, center - radius - 3, center, center + radius + 3, red, green, blue, 80, 1)
        hud:canvas_line(canvasId, center - radius - 3, center, center + radius + 3, center, red, green, blue, 80, 1)
        hud:canvas_circle(canvasId, pointX, pointY, 4, red, green, blue, 255, 4)
    end)
    hud:canvas_apply(canvasId)
end

buildHud = function()
    local size = hud:size()
    local width, height = tonumber(size.w) or 0, tonumber(size.h) or 0
    local statusWidth = math.min(STATUS_WIDTH, width)
    local statusY = 16
    local statusX = math.max(0, width - statusWidth - rightEdgeOffset)
    local suitRef = findSuitRef()
    local stormSetting = suitRef and safeReadId(suitRef, LT.Setting) or nil
    local pressureSetting = suitRef and safeReadId(suitRef, LT.PressureSetting) or nil
    local stormSeconds = stormSetting and math.floor(math.abs(stormSetting)) or 0
    local batteryPercent = pressureSetting and math.floor(((pressureSetting - math.floor(pressureSetting)) * 1000) + 0.5) / 10 or nil
    local timerVisible = stormSeconds > 0
    local lensColor = ss.hud.lens_color()
    local navigationOk, navigationOrError = pcall(readHomeNavigation, suitRef)
    if not navigationOk then
        print("[Visor] home navigation failed: " .. tostring(navigationOrError))
    end
    local navigation = navigationOk and navigationOrError or nil
    local navigationY = statusY + 60
    local navigationTextWidth = statusWidth - NAV_SIZE - 6
    local waypointStartY = navigationY + NAV_SIZE + WAYPOINT_ROW_GAP
    local addWaypointY = waypointStartY + #savedWaypoints * (NAV_SIZE + WAYPOINT_ROW_GAP)
    local stormY = addWaypointY + 36

    hud:clear()
    hud:element({
        id = "battery",
        type = "label",
        rect = { unit = "px", x = statusX, y = statusY, w = statusWidth, h = 24 },
        props = { text = batteryPercent and string.format("BASE BATTERY  %.1f%%", batteryPercent) or "BASE BATTERY  --", visible = true },
        style = { font_size = 16, color = lensColor, align = "right" },
    })
    hud:element({
        id = "home_distance",
        type = "label",
        rect = { unit = "px", x = statusX, y = navigationY, w = navigationTextWidth, h = 22 },
        props = { text = navigation and string.format("HOME  %.1f m", navigation.distance) or "HOME  --", visible = true },
        style = { font_size = 15, color = lensColor, align = "right" },
    })
    hud:element({
        id = "home_turn",
        type = "label",
        rect = { unit = "px", x = statusX, y = navigationY + 24, w = navigationTextWidth, h = 22 },
        props = { text = navigation and string.format("DIR   %03.0f°", navigation.bearing) or "DIR   --", visible = true },
        style = { font_size = 15, color = lensColor, align = "right" },
    })
    hud:element({
        id = NAV_CANVAS_ID,
        type = "canvas",
        rect = { unit = "px", x = statusX + navigationTextWidth + 6, y = navigationY, w = NAV_SIZE, h = NAV_SIZE },
        props = { width = NAV_SIZE, height = NAV_SIZE, visible = true },
    })
    for index, waypoint in ipairs(savedWaypoints) do
        local rowY = waypointStartY + (index - 1) * (NAV_SIZE + WAYPOINT_ROW_GAP)
        local markerCanvasId = "waypoint_canvas_" .. tostring(index)
        local waypointNavigation = navigationTo(suitRef, waypoint.x, waypoint.z)
        local waypointIndex = index
        local waypointName = tostring(waypoint.name or ("WAYPOINT " .. tostring(index)))
        hud:element({
            id = "waypoint_name_" .. tostring(index),
            type = "textinput",
            rect = { unit = "px", x = statusX - 8, y = rowY, w = navigationTextWidth - 24, h = 24 },
            props = { value = waypointName, placeholder = "WAYPOINT " .. tostring(index), visible = true },
            style = { bg = "#00000000", text = lensColor, placeholder_color = lensColor, font_size = 15 },
            on_change = function(value)
                local currentWaypoint = savedWaypoints[waypointIndex]
                if currentWaypoint then
                    local editedName = tostring(value or "")
                    currentWaypoint.name = editedName
                    saveWaypoints()
                end
            end,
        })
        hud:element({
            id = "waypoint_distance_" .. tostring(index),
            type = "label",
            rect = { unit = "px", x = statusX + navigationTextWidth - 42, y = rowY, w = 42, h = 20 },
            props = { text = waypointNavigation and string.format("%.1fm", waypointNavigation.distance) or "--", visible = true },
            style = { font_size = 12, color = lensColor, align = "right" },
        })
        hud:element({
            id = markerCanvasId,
            type = "canvas",
            rect = { unit = "px", x = statusX + navigationTextWidth + 6, y = rowY, w = NAV_SIZE, h = NAV_SIZE },
            props = { width = NAV_SIZE, height = NAV_SIZE, visible = true },
        })
        hud:element({
            id = "delete_waypoint_" .. tostring(index),
            type = "button",
            rect = { unit = "px", x = statusX, y = rowY + 24, w = WAYPOINT_DELETE_WIDTH, h = WAYPOINT_DELETE_SIZE },
            props = { text = "DELETE", visible = true },
            style = { bg = "#00000000", border = lensColor, border_width = 1, text = lensColor, font_size = 12 },
            on_click = function()
                deleteWaypoint(waypointIndex)
            end,
        })
        hud:element({
            id = "waypoint_direction_" .. tostring(index),
            type = "label",
            rect = { unit = "px", x = statusX + WAYPOINT_DELETE_WIDTH + 4, y = rowY + 24, w = navigationTextWidth - WAYPOINT_DELETE_WIDTH - 4, h = 20 },
            props = { text = waypointNavigation and string.format("%03.0f°", waypointNavigation.bearing) or "--", visible = true },
            style = { font_size = 15, color = lensColor, align = "right" },
        })
    end
    hud:element({
        id = "add_waypoint",
        type = "button",
        rect = { unit = "px", x = statusX, y = addWaypointY, w = statusWidth, h = 28 },
        props = { text = "WAYPOINT", visible = true },
        style = { bg = "#00000000", border = lensColor, border_width = 1, text = lensColor, font_size = 12 },
        on_click = function()
            addWaypoint(suitRef)
        end,
    })
    hud:element({
        id = "storm_timer",
        type = "label",
        rect = { unit = "px", x = statusX, y = stormY, w = statusWidth, h = 28 },
        props = { text = "STORM  " .. formatStormTimer(stormSeconds), visible = timerVisible },
        style = { font_size = 20, color = "#EF4444", align = "right" },
    })
    hud:element({
        id = "storm_incoming",
        type = "label",
        rect = { unit = "px", x = 0, y = height / 2 - 18, w = width, h = 36 },
        props = { text = "STORM INCOMING", visible = timerVisible and stormSeconds <= 30 },
        style = { font_size = 28, color = "#EF4444", align = "center" },
    })
    hud:commit()
    paintNavigationArrow(NAV_CANVAS_ID, navigation and navigation.relativeBearing, lensColor)
    for index, waypoint in ipairs(savedWaypoints) do
        local markerCanvasId = "waypoint_canvas_" .. tostring(index)
        local waypointNavigation = navigationTo(suitRef, waypoint.x, waypoint.z)
        paintNavigationArrow(markerCanvasId, waypointNavigation and waypointNavigation.relativeBearing, lensColor)
    end
end

function tick(dt)
    refreshElapsed = refreshElapsed + dt
    if refreshElapsed >= REFRESH_INTERVAL then
        refreshElapsed = 0
        buildHud()
    end
end

restoreWaypoints()
buildHud()