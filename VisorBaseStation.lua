-- Transmitting values to the hardsuit:
    -- 12 digits can be transmitted via the temperature and pressure settings
    -- "Setting" is a full float
    -- "Error" adds an unsigned integer

-- Encodes the seconds remaining in the suit's Setting value.
-- The integer portion stores the floored absolute event time, leaving the
-- fractional portion available for other telemetry values.

local WEATHER_STATION_PREFAB_HASH = 1997212478
local SUIT_TRANSMITTER_NAME = "SuitTransmitter"
local SIMULATION_MEMORY_NAME = "simulationMemory"
local MIRROR_MEMORY_NAME = "MirrorMemory"
local BATTERY_MIRROR_NAME = "BatteryMirror"
local STATION_BATTERY_PREFAB_HASH = -400115994
local LARGE_STATION_BATTERY_PREFAB_HASH = -1388288459
local LT = ic.enums.LogicType
local SOUND_ALERT = LT.SoundAlert

local function find_devices()
	local weather_station_ref
	local suit_transmitter_ref
	local simulation_memory_ref
	local mirror_memory_ref
	local battery_mirror_ref
	local battery_refs = {}

	for _, device in ipairs(ic.device.list()) do
		if device.prefab_hash == WEATHER_STATION_PREFAB_HASH then
			weather_station_ref = device.ref_id
		elseif device.display_name == SUIT_TRANSMITTER_NAME then
			suit_transmitter_ref = device.ref_id
		elseif device.display_name == SIMULATION_MEMORY_NAME then
			simulation_memory_ref = device.ref_id
		elseif device.display_name == MIRROR_MEMORY_NAME then
			mirror_memory_ref = device.ref_id
		elseif device.display_name == BATTERY_MIRROR_NAME then
			battery_mirror_ref = device.ref_id
		end

		if device.prefab_hash == STATION_BATTERY_PREFAB_HASH
			or device.prefab_hash == LARGE_STATION_BATTERY_PREFAB_HASH then
			table.insert(battery_refs, device.ref_id)
		end
	end

	return weather_station_ref, suit_transmitter_ref, simulation_memory_ref, mirror_memory_ref, battery_mirror_ref, battery_refs
end

local function try_run(phase, callback)
	local succeeded, error_message = pcall(callback)
	if not succeeded then
		print("VisorBaseStation " .. phase .. " error: " .. tostring(error_message))
	end
end

local battery_mirror_initialized = false
local sound_alert_sent = false

while true do
	local suit_transmitter_ref
	local mirror_memory_ref

	try_run("write", function()
		local weather_station_ref, found_suit_transmitter_ref, simulation_memory_ref, found_mirror_memory_ref, battery_mirror_ref, battery_refs = find_devices()
		suit_transmitter_ref = found_suit_transmitter_ref
		mirror_memory_ref = found_mirror_memory_ref

		if not battery_mirror_initialized and battery_mirror_ref ~= nil then
			ic.write_id(battery_mirror_ref, LT.Mode, 2)
			ic.write_id(battery_mirror_ref, LT.Setting, hash("Batter"))
			battery_mirror_initialized = true
		end

		if suit_transmitter_ref ~= nil and simulation_memory_ref ~= nil then
			local seconds_remaining = ic.read_id(weather_station_ref, LT.NextWeatherEventTime)
			-- local seconds_remaining = ic.read_id(simulation_memory_ref, LT.Setting)
			local has_storm_time = seconds_remaining ~= nil and seconds_remaining ~= 0

			if not has_storm_time then
				sound_alert_sent = false
			elseif SOUND_ALERT ~= nil and not sound_alert_sent then
				ic.write_id(suit_transmitter_ref, SOUND_ALERT, has_storm_time and 1 or 0)
				sound_alert_sent = true
				ic.timer.in_seconds(10, function()
					ic.write_id(suit_transmitter_ref, SOUND_ALERT, 0)
				end)
			end

            yield()

			if seconds_remaining ~= nil then
				seconds_remaining = math.abs(seconds_remaining)
				local encoded_setting = math.floor(seconds_remaining)
				ic.write_id(suit_transmitter_ref, LT.Setting, encoded_setting)
			end

			local total_battery_ratio = 0
			local battery_count = 0
			for _, battery_ref in ipairs(battery_refs) do
				local battery_ratio = ic.read_id(battery_ref, LT.Ratio)
				if battery_ratio ~= nil then
					total_battery_ratio = total_battery_ratio + battery_ratio
					battery_count = battery_count + 1
				end
			end

			if battery_count > 0 then
				local average_battery_ratio = total_battery_ratio / battery_count
				local battery_fraction = math.min(999, math.floor(average_battery_ratio * 1000 + 0.5)) / 1000
				local suit_pressure = ic.read_id(suit_transmitter_ref, LT.PressureSetting)
				if suit_pressure ~= nil then
					ic.write_id(suit_transmitter_ref, LT.PressureSetting, math.floor(suit_pressure) + battery_fraction)
				end
			end
		end
	end)

	yield()

	try_run("mirror", function()
		if suit_transmitter_ref ~= nil and mirror_memory_ref ~= nil then
			local mirrored_setting = ic.read_id(suit_transmitter_ref, LT.PressureSetting)
			if mirrored_setting ~= nil then
				ic.write_id(mirror_memory_ref, LT.Setting, mirrored_setting)
			end
		end
	end)
end
