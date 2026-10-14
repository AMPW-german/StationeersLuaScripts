local script_path = debug.getinfo(1, "S").source:sub(2)
local root = script_path:match("^(.*)[/\\]tests[/\\]") or "."
local controller_path = os.getenv("SC_SOURCE") or (root .. "/StorageController.lua")

local WALLLIGHT = 1001
local COPPER = 2002
local GOLD = 3003

local LT = { On = 1, Setting = 2, Open = 3, Mode = 4, Quantity = 5, Activate = 6, Output = 7, SettingOutput = 8 }
local LST = { Occupied = 1, PrefabHash = 2, Quantity = 3, MaxQuantity = 4 }
local SI = { FilterPrefabHashEquals = 1 }

local function encode_sorter_row(prefab_hash)
    return SI.FilterPrefabHashEquals + ((prefab_hash % 4294967296) * 256)
end

local function decode_sorter_row(row)
    if type(row) ~= "number" or row <= 0 or row % 256 ~= SI.FilterPrefabHashEquals then
        return nil
    end
    return math.floor(row / 256) % 4294967296
end

local function load_controller(ctx)
    local handle = assert(io.open(controller_path, "r"))
    local source = handle:read("*a")
    handle:close()
    local entry = source:find("\ninitialize()", 1, true)
    assert(entry, "initialize() entry point not found")
    source = source:sub(1, entry - 1) .. [[
return {
    state = state,
    service_input = service_input,
    service_fail = service_fail,
    service_output_return = service_output_return,
    service_output = service_output,
    request_storage = request_storage,
    configure_devices = configure_devices,
    service_group_drain = service_group_drain,
}
]]
    local chunk = assert(loadstring(source, controller_path))
    local env = setmetatable({
        ic = ctx.ic,
        util = { json = { encode = function() return "{}" end, decode = function() return {} end } },
        prefab_name = function(h) return ctx.names[h] or tostring(h) end,
        yield = function() end,
        print = function(line) ctx.log[#ctx.log + 1] = tostring(line) end,
    }, { __index = _G })
    setfenv(chunk, env)
    return chunk()
end

local function new_context()
    local ctx = {
        devices = {},
        next_ref = 0,
        log = {},
        names = { [WALLLIGHT] = "ItemWallLight", [COPPER] = "ItemCopperIngot", [GOLD] = "ItemGoldIngot" },
        delivered = {},
        returned = {},
        dumped = {},
        fail_routes = {},
        upstream = {},
        inbound = {},
        arrivals = {},
        stray_prefabs = {},
        stages_seen = {},
        released_group_states = {},
        empty_in_transit_ticks = 0,
        silo_closed_during_drain = 0,
        filter_cleared_during_drain = 0,
        held_input_ticks = 0,
        upstream_delay = 2,
        read_errors = {},
        write_errors = {},
    }
    ctx.ic = {
        enums = { LogicType = LT, LogicSlotType = LST, SorterInstruction = SI },
        read_id = function(ref_id, logic_type)
            if ctx.read_errors[ref_id .. ":" .. logic_type] then
                error(ctx.read_errors[ref_id .. ":" .. logic_type])
            end
            local device = ctx.devices[ref_id]
            if device.stuck_open and logic_type == LT.Open then
                return 1
            end
            return device.logic[logic_type] or 0
        end,
        write_id = function(ref_id, logic_type, value)
            if ctx.write_errors[ref_id .. ":" .. logic_type .. ":" .. value] then
                error(ctx.write_errors[ref_id .. ":" .. logic_type .. ":" .. value])
            end
            if ctx.write_errors[ref_id .. ":" .. logic_type] then
                error(ctx.write_errors[ref_id .. ":" .. logic_type])
            end
            local device = ctx.devices[ref_id]
            if logic_type == LT.Activate and value == 1 then
                device.activate_writes = (device.activate_writes or 0) + 1
            end
            if logic_type == LT.Open and value == 0 and device.open_close_delay then
                device.open_close_writes = (device.open_close_writes or 0) + 1
                if not device.pending_open then
                    device.pending_open = device.open_close_delay
                end
                return
            end
            device.logic[logic_type] = value
        end,
        read_slot_id = function(ref_id, slot, slot_type)
            local held = ctx.devices[ref_id].slots[slot]
            if not held then
                return 0
            end
            return held[slot_type] or 0
        end,
        mem = {
            get_id = function(ref_id, address)
                return ctx.devices[ref_id].mem[address] or 0
            end,
            put_id = function(ref_id, address, value)
                ctx.devices[ref_id].mem[address] = value
            end,
        },
        net = { register = function() end, publish = function() end, request = function() end },
        persist = { get = function() return nil end, set = function() return true end },
        device = { list = function() return {} end },
    }
    return ctx
end

local function make_device(ctx, name)
    ctx.next_ref = ctx.next_ref + 1
    local device = {
        ref_id = ctx.next_ref,
        display_name = name,
        logic = {},
        slots = {},
        mem = {},
        silo_stacks = 0,
        pending = {},
        arrivals = {},
    }
    ctx.devices[device.ref_id] = device
    return device
end

local function place_item(device, prefab_hash, quantity, max_quantity)
    device.slots[0] = {
        [LST.Occupied] = 1,
        [LST.PrefabHash] = prefab_hash,
        [LST.Quantity] = quantity,
        [LST.MaxQuantity] = max_quantity or quantity,
    }
end

local function take_item(device)
    local held = device.slots[0]
    device.slots[0] = nil
    if not held then
        return nil
    end
    return { prefab_hash = held[LST.PrefabHash], quantity = held[LST.Quantity], max_quantity = held[LST.MaxQuantity] }
end

local function slot_occupied(device)
    return device.slots[0] ~= nil
end

local function make_group(ctx, id, prefab_hash, options)
    options = options or {}
    local label = string.format("0x%04X", id)
    local group = {
        id = id,
        label = label,
        sorter = make_device(ctx, label),
        stacker = make_device(ctx, label),
        silo = make_device(ctx, label),
        state = prefab_hash and "assigned" or "unassigned",
        assignment_prefab_hash = prefab_hash,
        confirmed_quantity = options.confirmed or 0,
        reserved_quantity = 0,
        pending_quantity = 0,
        max_stack_quantity = options.max_stack,
        silo_stack_count = options.silo_stacks or 0,
        silo_memory_cursor = 0,
        silo_memory_words = {},
        scan_complete = true,
        clearing_stacker = false,
        clearing_tick = 0,
        transit = {},
    }
    if prefab_hash then
        group.sorter.mem[0] = encode_sorter_row(prefab_hash)
    end
    group.silo.silo_stacks = options.silo_stacks or 0
    group.silo.logic[LT.Quantity] = group.silo.silo_stacks
    if options.stacker_item then
        place_item(group.stacker, prefab_hash, options.stacker_item, options.max_stack)
        group.pending_quantity = options.stacker_item
    end
    for _, entry in ipairs(options.drain_queue or {}) do
        group.stacker.arrivals[#group.stacker.arrivals + 1] = {
            prefab_hash = prefab_hash,
            quantity = entry.quantity,
            max_quantity = options.max_stack,
            appear_delay = entry.appear_delay or entry.emit_delay or 1,
            transit = entry.transit or 1,
            via_silo = entry.via_silo,
        }
    end
    return group
end

local function setup(ctx, groups)
    local M = load_controller(ctx)
    local state = M.state
    state.valves.input = make_device(ctx, "Storage.InputValve")
    state.valves.fail = make_device(ctx, "Storage.FailValve")
    state.valves.output_in = make_device(ctx, "Storage.OutputInValve")
    state.valves.output_out = make_device(ctx, "Storage.OutputOutValve")
    state.splitters.fail = make_device(ctx, "Storage.FailSplitter")
    state.splitters.output = make_device(ctx, "Storage.OutputSplitter")
    state.output_stacker = make_device(ctx, "Storage.OutputStacker")
    state.output_stacker.buffer = { prefab_hash = nil, quantity = 0 }
    for id, group in pairs(groups) do
        state.groups[id] = group
        if group.assignment_prefab_hash then
            state.prefab_groups[group.assignment_prefab_hash] = group
        end
    end
    state.group_count = 0
    while state.groups[state.group_count] do
        state.group_count = state.group_count + 1
    end
    state.phase = "ready"
    ctx.M = M
    ctx.state = state
    return M
end

local function record_stage(ctx)
    local state = ctx.state
    local task = state.output_task
    if task then
        ctx.stages_seen[task.stage] = true
        if task.draining_group then
            local group = task.group
            if group.silo.logic[LT.Open] ~= 1 and task.drain_close_tick == nil then
                ctx.silo_closed_during_drain = ctx.silo_closed_during_drain + 1
            end
            if group.silo.silo_stacks == 0 and not slot_occupied(group.stacker)
                and #group.silo.pending == 0 and group.confirmed_quantity > 0 then
                ctx.empty_in_transit_ticks = ctx.empty_in_transit_ticks + 1
            end
            if state.prefab_groups[task.request.prefab_hash] ~= group
                or decode_sorter_row(group.sorter.mem[0]) ~= task.request.prefab_hash then
                ctx.filter_cleared_during_drain = ctx.filter_cleared_during_drain + 1
            end
            if task.remaining_quantity <= task.buffered_quantity then
                local held = state.valves.input.slots[0]
                if held and held[LST.PrefabHash] == task.request.prefab_hash then
                    ctx.held_input_ticks = ctx.held_input_ticks + 1
                end
            end
            ctx.last_drain_task = task
            ctx.last_drain_group = task.group
        end
    end
    local draining_now = task ~= nil and task.draining_group or false
    if ctx.was_draining and not draining_now and ctx.last_drain_group then
        ctx.released_group_states[#ctx.released_group_states + 1] = {
            confirmed = ctx.last_drain_group.confirmed_quantity,
            reserved = ctx.last_drain_group.reserved_quantity,
            group_state = ctx.last_drain_group.state,
            reservation_released = ctx.last_drain_task and ctx.last_drain_task.reservation_released,
            silo_open = ctx.last_drain_group.silo.logic[LT.Open],
            tick = state.tick,
        }
        ctx.last_drain_task = nil
        ctx.last_drain_group = nil
    end
    ctx.was_draining = draining_now
    if state.stray then
        ctx.stray_prefabs[#ctx.stray_prefabs + 1] = state.stray.prefab_hash
    end
end

local function physics(ctx)
    local state = ctx.state
    local output_in = state.valves.output_in
    local arriving = {}
    for _, device in pairs(ctx.devices) do
        if device.pending_open then
            device.pending_open = device.pending_open - 1
            if device.pending_open <= 0 then
                device.logic[LT.Open] = 0
                device.pending_open = nil
            end
        end
    end
    for _, group in pairs(state.groups) do
        local silo = group.silo
        silo.logic[LT.Quantity] = silo.silo_stacks
        local stacker = group.stacker
        local arrival = stacker.arrivals[1]
        if arrival then
            arrival.appear_delay = arrival.appear_delay - 1
            if arrival.appear_delay <= 0 and not slot_occupied(stacker) then
                table.remove(stacker.arrivals, 1)
                place_item(stacker, arrival.prefab_hash, arrival.quantity, arrival.max_quantity)
                stacker.slot_route = { via_silo = arrival.via_silo, transit = arrival.transit }
            end
        end
        if stacker.logic[LT.Activate] == 1 and slot_occupied(stacker) then
            local item = take_item(stacker)
            stacker.logic[LT.Activate] = 0
            local route = stacker.slot_route or {}
            stacker.slot_route = nil
            if route.via_silo then
                silo.pending[#silo.pending + 1] = {
                    prefab_hash = item.prefab_hash,
                    quantity = item.quantity,
                    max_quantity = item.max_quantity,
                    transit = route.transit or 1,
                }
            else
                group.transit[#group.transit + 1] = {
                    group = group,
                    prefab_hash = item.prefab_hash,
                    quantity = item.quantity,
                    max_quantity = item.max_quantity,
                    arrive_tick = state.tick + (route.transit or 1),
                }
            end
        end
        if silo.logic[LT.Open] == 1 then
            while #silo.pending > 0 do
                local em = table.remove(silo.pending, 1)
                group.transit[#group.transit + 1] = {
                    group = group,
                    prefab_hash = em.prefab_hash,
                    quantity = em.quantity,
                    max_quantity = em.max_quantity,
                    arrive_tick = state.tick + em.transit,
                }
            end
            if silo.silo_stacks > 0 then
                silo.silo_stacks = silo.silo_stacks - 1
                silo.logic[LT.Quantity] = silo.silo_stacks
                group.transit[#group.transit + 1] = {
                    group = group,
                    prefab_hash = group.assignment_prefab_hash,
                    quantity = group.max_stack_quantity,
                    max_quantity = group.max_stack_quantity,
                    arrive_tick = state.tick + 1,
                }
            end
        end
        for index = #group.transit, 1, -1 do
            local em = group.transit[index]
            if state.tick >= em.arrive_tick then
                table.remove(group.transit, index)
                arriving[#arriving + 1] = em
            end
        end
    end

    local output_stacker = state.output_stacker
    if output_stacker.logic[LT.Output] == 1 and not slot_occupied(state.valves.output_out) then
        local setting = output_stacker.logic[LT.Setting] or 0
        if slot_occupied(output_stacker) then
            local item = take_item(output_stacker)
            place_item(state.valves.output_out, item.prefab_hash, item.quantity, item.max_quantity)
        elseif setting > 0 and output_stacker.buffer.quantity >= setting then
            output_stacker.buffer.quantity = output_stacker.buffer.quantity - setting
            place_item(state.valves.output_out, output_stacker.buffer.prefab_hash, setting, setting)
        end
    end

    local function drain_valve(valve, route)
        if valve.logic[LT.Open] == 1 then
            if slot_occupied(valve) then
                local item = take_item(valve)
                route(item)
            end
            valve.logic[LT.Open] = 0
        end
    end
    drain_valve(output_in, function(item)
        if state.stray and state.stray.stage == "await_stacker" then
            place_item(output_stacker, item.prefab_hash, item.quantity, item.max_quantity)
        else
            output_stacker.buffer.prefab_hash = item.prefab_hash
            output_stacker.buffer.quantity = output_stacker.buffer.quantity + item.quantity
        end
    end)
    drain_valve(state.valves.output_out, function(item)
        if (state.splitters.output.logic[LT.Mode] or 0) == 0 then
            ctx.delivered[#ctx.delivered + 1] = item
        else
            ctx.returned[#ctx.returned + 1] = item
            ctx.inbound[#ctx.inbound + 1] = item
        end
    end)
    drain_valve(state.valves.input, function(item)
        ctx.upstream[#ctx.upstream + 1] = {
            prefab_hash = item.prefab_hash,
            quantity = item.quantity,
            max_quantity = item.max_quantity,
            arrive_tick = state.tick + ctx.upstream_delay,
        }
    end)
    drain_valve(state.valves.fail, function(item)
        local mode = state.splitters.fail.logic[LT.Mode] or 0
        ctx.fail_routes[#ctx.fail_routes + 1] = { prefab = item.prefab_hash, mode = mode }
        if mode == 0 then
            ctx.dumped[#ctx.dumped + 1] = item
        else
            ctx.inbound[#ctx.inbound + 1] = item
        end
    end)

    for index = #ctx.upstream, 1, -1 do
        local em = ctx.upstream[index]
        if state.tick >= em.arrive_tick then
            local target_group
            for _, group in pairs(state.groups) do
                if decode_sorter_row(group.sorter.mem[0]) == em.prefab_hash then
                    target_group = group
                    break
                end
            end
            if target_group then
                table.remove(ctx.upstream, index)
                target_group.stacker.arrivals[#target_group.stacker.arrivals + 1] = {
                    prefab_hash = em.prefab_hash,
                    quantity = em.quantity,
                    max_quantity = em.max_quantity,
                    appear_delay = 1,
                }
            elseif not slot_occupied(state.valves.fail) then
                table.remove(ctx.upstream, index)
                place_item(state.valves.fail, em.prefab_hash, em.quantity, em.max_quantity)
            end
        end
    end

    if #ctx.inbound > 0 and not slot_occupied(state.valves.input) and not state.valves.input.releasing then
        local item = table.remove(ctx.inbound, 1)
        place_item(state.valves.input, item.prefab_hash, item.quantity, item.max_quantity)
    end

    for _, em in ipairs(arriving) do
        if not slot_occupied(output_in) then
            place_item(output_in, em.prefab_hash, em.quantity, em.max_quantity)
            ctx.arrivals[#ctx.arrivals + 1] = {
                prefab_hash = em.prefab_hash,
                quantity = em.quantity,
                stage = state.output_task and state.output_task.stage or "none",
            }
        else
            table.insert(em.group.transit, 1, {
                group = em.group,
                prefab_hash = em.prefab_hash,
                quantity = em.quantity,
                max_quantity = em.max_quantity,
                arrive_tick = state.tick,
            })
        end
    end
end

local function idle(ctx)
    local state = ctx.state
    if state.output_task ~= nil or #state.queue > 0 or state.stray ~= nil or #ctx.inbound > 0 then
        return false
    end
    if slot_occupied(state.valves.output_in) or slot_occupied(state.valves.input)
        or slot_occupied(state.valves.fail) or #ctx.upstream > 0 then
        return false
    end
    for _, group in pairs(state.groups) do
        if #group.transit > 0 or #group.silo.pending > 0 then
            return false
        end
    end
    return true
end

local function run(ctx, max_ticks, on_tick)
    local state = ctx.state
    for _ = 1, max_ticks do
        state.tick = state.tick + 1
        local ok, err = pcall(function()
            if on_tick then
                on_tick(ctx)
            end
            physics(ctx)
            ctx.M.service_input()
            ctx.M.service_fail()
            ctx.M.service_output_return()
            ctx.M.service_output()
            record_stage(ctx)
        end)
        if not ok then
            return false, err
        end
        if state.phase ~= "ready" then
            return false, "phase left ready: " .. tostring(state.phase)
        end
        if idle(ctx) then
            return true
        end
    end
    return false, "tick budget exhausted"
end

local function request(ctx, prefab_hash, quantity)
    ctx.request_seq = (ctx.request_seq or 0) + 1
    local response = ctx.M.request_storage({
        api_version = 1,
        client_request_id = "test-" .. ctx.request_seq,
        prefab_hash = prefab_hash,
        quantity = quantity,
    }, "test-client")
    assert(response.ok, "request rejected: " .. tostring(response.code))
    return response.request_id
end

local function total(list)
    local sum = 0
    for _, item in ipairs(list) do
        sum = sum + item.quantity
    end
    return sum
end

local only = os.getenv("SC_TEST")
local results = {}
local function test(name, fn)
    if only and not name:find(only, 1, true) then
        return
    end
    local ctx = new_context()
    local ok, err = pcall(fn, ctx)
    if ok then
        results[#results + 1] = "PASS " .. name
    else
        results[#results + 1] = "FAIL " .. name .. ": " .. tostring(err)
        local tail = {}
        for i = math.max(1, #ctx.log - 25), #ctx.log do
            tail[#tail + 1] = "    " .. ctx.log[i]
        end
        results[#results + 1] = table.concat(tail, "\n")
    end
end

local function expect(cond, message)
    if not cond then
        error(message, 2)
    end
end

local function assert_drain_invariants(ctx, group, prefab_hash, expect_drain_clear)
    for _, stray_prefab in ipairs(ctx.stray_prefabs) do
        expect(stray_prefab ~= prefab_hash, "matching drain emission classified as stray")
    end
    expect(#ctx.released_group_states > 0, "drain release never observed")
    for _, release in ipairs(ctx.released_group_states) do
        expect(release.confirmed == 0, "group released with " .. release.confirmed .. " confirmed still in transit")
        expect(release.reserved == 0, "reservation not zero at release: " .. release.reserved)
        expect(release.reservation_released == true, "reservation_released flag not set at release")
    end
    expect(group.reserved_quantity == 0, "reservation not zero after completion: " .. group.reserved_quantity)
    expect(ctx.empty_in_transit_ticks >= 2, "did not observe >=2 empty-source ticks with confirmed>0: " .. ctx.empty_in_transit_ticks)
    expect(ctx.silo_closed_during_drain == 0, "silo closed while drain in progress: " .. ctx.silo_closed_during_drain .. " ticks")
    expect(group.silo.logic[LT.Open] == 0, "silo not closed after drain finished")
    if expect_drain_clear then
        expect(ctx.stages_seen.await_drain_clear == true, "await_drain_clear stage never observed")
    end
    expect(ctx.state.fault == nil, "unexpected fault")
end

local function step(ctx, n, on_tick)
    local state = ctx.state
    for _ = 1, n do
        state.tick = state.tick + 1
        if on_tick then
            on_tick(ctx)
        end
        physics(ctx)
        ctx.M.service_input()
        ctx.M.service_fail()
        ctx.M.service_output_return()
        ctx.M.service_output()
        record_stage(ctx)
    end
end

local function track_max(ctx, group)
    if group.confirmed_quantity > (ctx.max_confirmed or 0) then
        ctx.max_confirmed = group.confirmed_quantity
    end
end

test("drain delivers 35 admitted upstream on retained filter", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { max_stack = 10 })
    local group1 = make_group(ctx, 1, nil, {})
    setup(ctx, { [0] = group0, [1] = group1 })
    local state = ctx.state
    place_item(state.valves.input, WALLLIGHT, 5, 10)
    step(ctx, 8, function(c) track_max(c, group0) end)
    expect(group0.confirmed_quantity == 5, "ledger not 5 after first admission: " .. group0.confirmed_quantity)
    local held = group0.stacker.slots[0]
    expect(held and held[LST.Quantity] == 5, "first 5 units not physically in group stacker")
    ctx.upstream_delay = 25
    for _ = 1, 3 do
        while slot_occupied(state.valves.input) or state.valves.input.releasing do
            step(ctx, 1, function(c) track_max(c, group0) end)
        end
        place_item(state.valves.input, WALLLIGHT, 10, 10)
        step(ctx, 3, function(c) track_max(c, group0) end)
    end
    expect(group0.confirmed_quantity == 35, "ledger not 35 before request: " .. group0.confirmed_quantity)
    expect(group0.silo.silo_stacks == 0 and held[LST.Quantity] == 5,
        "more than 5 units physically at group before request")
    expect(#ctx.upstream == 3, "expected 30 units still upstream, have " .. #ctx.upstream)
    local request_id = request(ctx, WALLLIGHT, 35)
    expect(group0.reserved_quantity == 35, "reservation not taken: " .. group0.reserved_quantity)
    local injected_foreign = false
    local ok, err = run(ctx, 600, function(c)
        track_max(c, group0)
        if not injected_foreign and c.state.output_task and c.state.output_task.draining_group
            and not slot_occupied(c.state.valves.input) then
            place_item(c.state.valves.input, COPPER, 4, 4)
            injected_foreign = true
        end
    end)
    expect(ok, "run failed: " .. tostring(err))
    expect(injected_foreign, "never injected foreign input during drain")
    expect(ctx.state.requests[request_id].state == "completed", "request not completed: " .. ctx.state.requests[request_id].state)
    expect(total(ctx.delivered) == 35, "delivered " .. total(ctx.delivered) .. " expected 35")
    expect(total(ctx.returned) == 0, "returned " .. total(ctx.returned) .. " expected 0")
    expect(total(ctx.dumped) == 0, "dumped " .. total(ctx.dumped) .. " expected 0")
    expect(#ctx.fail_routes == 0, "already-counted items pushed to fail path")
    expect(ctx.max_confirmed == 35, "ledger counted beyond admitted 35: " .. tostring(ctx.max_confirmed))
    assert_drain_invariants(ctx, group0, WALLLIGHT, false)
    expect(group0.confirmed_quantity == 0, "source ledger not zero: " .. group0.confirmed_quantity)
    expect(ctx.filter_cleared_during_drain == 0, "assignment or sorter filter cleared during drain")
    expect(group0.state == "unassigned", "group not unassigned after drain: " .. tostring(group0.state))
    expect(ctx.state.prefab_groups[WALLLIGHT] == nil, "prefab map still holds drained group")
    expect(decode_sorter_row(group0.sorter.mem[0]) == nil, "sorter filter retained after drain end")
    expect(not slot_occupied(group0.stacker) and #group0.stacker.arrivals == 0,
        "late stacker items remain after drain")
    expect(ctx.state.prefab_groups[COPPER] == group1, "foreign input during drain took over draining group")
    expect(group1.confirmed_quantity == 4, "foreign input not admitted to free group")
    local arrival_stages = {}
    local stage_list = {}
    for _, arrival in ipairs(ctx.arrivals) do
        arrival_stages[arrival.stage] = true
        stage_list[#stage_list + 1] = arrival.stage
    end
    expect(arrival_stages.dispense == true, "no arrival landed during dispense; stages: " .. table.concat(stage_list, ","))
    expect(arrival_stages.await_output or arrival_stages.await_delivery_clear
        or arrival_stages.await_return or arrival_stages.await_drain_clear,
        "no arrival landed during a delivery/return stage; stages: " .. table.concat(stage_list, ","))
end)

test("same-prefab input admitted once during unsatisfied drain", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { max_stack = 10 })
    local group1 = make_group(ctx, 1, nil, {})
    setup(ctx, { [0] = group0, [1] = group1 })
    local state = ctx.state
    place_item(state.valves.input, WALLLIGHT, 5, 10)
    step(ctx, 8, function(c) track_max(c, group0) end)
    ctx.upstream_delay = 30
    place_item(state.valves.input, WALLLIGHT, 10, 10)
    step(ctx, 4, function(c) track_max(c, group0) end)
    expect(group0.confirmed_quantity == 15, "ledger not 15 before request: " .. group0.confirmed_quantity)
    local request_id = request(ctx, WALLLIGHT, 15)
    local injected_fresh = false
    local ok, err = run(ctx, 600, function(c)
        track_max(c, group0)
        local task = c.state.output_task
        if not injected_fresh and task and task.draining_group
            and task.remaining_quantity > task.buffered_quantity
            and not slot_occupied(c.state.valves.input) then
            place_item(c.state.valves.input, WALLLIGHT, 5, 10)
            injected_fresh = true
        end
    end)
    expect(ok, "run failed: " .. tostring(err))
    expect(injected_fresh, "never injected fresh same-prefab input during unsatisfied drain")
    expect(ctx.state.requests[request_id].state == "completed", "request not completed: " .. ctx.state.requests[request_id].state)
    expect(ctx.max_confirmed == 20, "fresh 5 not counted exactly once: max ledger " .. tostring(ctx.max_confirmed))
    expect(total(ctx.delivered) == 15, "delivered " .. total(ctx.delivered) .. " expected 15")
    expect(total(ctx.returned) == 5, "returned " .. total(ctx.returned) .. " expected 5")
    expect(total(ctx.dumped) == 0 and #ctx.fail_routes == 0, "material pushed to fail path")
    assert_drain_invariants(ctx, group0, WALLLIGHT, true)
    expect(ctx.filter_cleared_during_drain == 0, "assignment or sorter filter cleared during drain")
    local target = ctx.state.prefab_groups[WALLLIGHT]
    expect(target ~= nil, "excess not re-admitted to any group")
    expect(target.confirmed_quantity == 5, "re-admitted excess is " .. target.confirmed_quantity .. " expected 5")
end)

test("request 10 of 35 holds returned excess until drain ends", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, {
        confirmed = 35,
        max_stack = 10,
        stacker_item = 5,
        drain_queue = {
            { quantity = 10, appear_delay = 5, transit = 2 },
            { quantity = 10, appear_delay = 11, transit = 2, via_silo = true },
            { quantity = 10, appear_delay = 16, transit = 3 },
        },
    })
    local group1 = make_group(ctx, 1, nil, {})
    setup(ctx, { [0] = group0, [1] = group1 })
    local request_id = request(ctx, WALLLIGHT, 10)
    local ok, err = run(ctx, 600)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[request_id].state == "completed", "request not completed: " .. ctx.state.requests[request_id].state)
    expect(total(ctx.delivered) == 10, "delivered " .. total(ctx.delivered) .. " expected 10")
    expect(total(ctx.returned) == 25, "returned " .. total(ctx.returned) .. " expected 25")
    assert_drain_invariants(ctx, group0, WALLLIGHT, true)
    expect(ctx.held_input_ticks > 0, "returned excess never held at input while sourced drain active")
    local target = ctx.state.prefab_groups[WALLLIGHT]
    expect(target ~= nil, "returned excess not re-admitted to any group")
    expect(target.confirmed_quantity == 25, "re-admitted excess is " .. target.confirmed_quantity .. " expected 25")
end)

test("partial request returns excess through return path", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, {
        confirmed = 20,
        max_stack = 10,
        stacker_item = 10,
        drain_queue = {
            { quantity = 10, appear_delay = 4, transit = 2 },
        },
    })
    local group1 = make_group(ctx, 1, nil, {})
    setup(ctx, { [0] = group0, [1] = group1 })
    local request_id = request(ctx, WALLLIGHT, 15)
    local ok, err = run(ctx, 500)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[request_id].state == "completed", "request not completed")
    expect(total(ctx.delivered) == 15, "delivered " .. total(ctx.delivered) .. " expected 15")
    expect(total(ctx.returned) == 5, "returned " .. total(ctx.returned) .. " expected 5")
    expect(group0.state ~= "draining", "group0 still draining")
    local target = ctx.state.prefab_groups[WALLLIGHT]
    expect(target ~= nil, "excess not re-admitted to any group")
    expect(target.confirmed_quantity == 5, "re-admitted excess is " .. target.confirmed_quantity .. " expected 5")
end)

test("matching held input admitted while awaiting source", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 10, max_stack = 10 })
    setup(ctx, { [0] = group0 })
    local request_id = request(ctx, WALLLIGHT, 10)
    local state = ctx.state
    for _ = 1, 10 do
        state.tick = state.tick + 1
        physics(ctx)
        ctx.M.service_output_return()
        ctx.M.service_output()
        if state.output_task and state.output_task.stage == "await_source" then
            break
        end
    end
    expect(state.output_task and state.output_task.stage == "await_source",
        "task did not reach await_source: " .. tostring(state.output_task and state.output_task.stage))
    place_item(state.valves.output_in, WALLLIGHT, 10, 10)
    local ok, err = run(ctx, 300)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[request_id].state == "completed", "request not completed")
    expect(total(ctx.delivered) == 10, "delivered " .. total(ctx.delivered))
    for _, stray_prefab in ipairs(ctx.stray_prefabs) do
        expect(stray_prefab ~= WALLLIGHT, "held matching input classified as stray")
    end
end)

test("unrelated and idle matching items still stray", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, {
        confirmed = 35,
        max_stack = 10,
        stacker_item = 5,
        drain_queue = {
            { quantity = 10, appear_delay = 4, transit = 1 },
            { quantity = 10, appear_delay = 8, transit = 1 },
            { quantity = 10, appear_delay = 14, transit = 2 },
        },
    })
    local group1 = make_group(ctx, 1, nil, {})
    local group2 = make_group(ctx, 2, nil, {})
    setup(ctx, { [0] = group0, [1] = group1, [2] = group2 })
    request(ctx, WALLLIGHT, 35)
    local state = ctx.state
    local injected_foreign = false
    local injected_idle = false
    for _ = 1, 500 do
        state.tick = state.tick + 1
        local ok, err = pcall(function()
            if not injected_foreign and state.output_task and state.output_task.stage == "await_output" then
                place_item(state.valves.output_in, COPPER, 3, 3)
                injected_foreign = true
            elseif injected_foreign and not injected_idle and state.stray == nil
                and state.valves.output_in.slots[0] == nil
                and group0.confirmed_quantity == 0
                and state.output_task and state.output_task.stage == "await_output" then
                place_item(state.valves.output_in, WALLLIGHT, 2, 2)
                injected_idle = true
            end
            physics(ctx)
            ctx.M.service_input()
            ctx.M.service_fail()
            ctx.M.service_output_return()
            ctx.M.service_output()
            record_stage(ctx)
        end)
        expect(ok, "run failed: " .. tostring(err))
        if state.output_task == nil and state.stray == nil and #ctx.inbound == 0
            and state.valves.output_in.slots[0] == nil then
            break
        end
    end
    expect(injected_foreign, "never injected foreign stray")
    expect(injected_idle, "never injected idle matching stray")
    local foreign = 0
    local idle_returned = 0
    for _, item in ipairs(ctx.returned) do
        if item.prefab_hash == COPPER then
            foreign = foreign + item.quantity
        elseif item.prefab_hash == WALLLIGHT then
            idle_returned = idle_returned + item.quantity
        end
    end
    expect(foreign == 3, "foreign stray not returned: " .. foreign)
    expect(idle_returned == 2, "idle matching stray not returned: " .. idle_returned)
    expect(total(ctx.delivered) == 35, "delivered " .. total(ctx.delivered))
end)

test("queued request executes after active completes", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 10, max_stack = 10, silo_stacks = 1 })
    local group1 = make_group(ctx, 1, COPPER, { confirmed = 5, max_stack = 5, silo_stacks = 1 })
    setup(ctx, { [0] = group0, [1] = group1 })
    local first = request(ctx, WALLLIGHT, 10)
    local second = request(ctx, COPPER, 5)
    local ok, err = run(ctx, 400)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[first].state == "completed", "first request not completed")
    expect(ctx.state.requests[second].state == "completed", "second request not completed: " .. ctx.state.requests[second].state)
    expect(ctx.state.requests[first].sequence < ctx.state.requests[second].sequence, "completion order wrong")
    expect(total(ctx.delivered) == 15, "delivered " .. total(ctx.delivered))
end)

test("splitter ratio registers zeroed at configure", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 10, max_stack = 10 })
    local group1 = make_group(ctx, 1, nil, {})
    setup(ctx, { [0] = group0, [1] = group1 })
    ctx.state.splitters.fail.logic[LT.Setting] = 3
    ctx.state.splitters.fail.logic[LT.SettingOutput] = 5
    ctx.state.splitters.output.logic[LT.Setting] = 2
    ctx.state.splitters.output.logic[LT.SettingOutput] = 7
    expect(ctx.M.configure_devices() == true, "configure_devices failed")
    expect(ctx.state.splitters.fail.logic[LT.Setting] == 0, "fail splitter Setting not zeroed")
    expect(ctx.state.splitters.fail.logic[LT.SettingOutput] == 0, "fail splitter SettingOutput not zeroed")
    expect(ctx.state.splitters.output.logic[LT.Setting] == 0, "output splitter Setting not zeroed")
    expect(ctx.state.splitters.output.logic[LT.SettingOutput] == 0, "output splitter SettingOutput not zeroed")
end)

test("fail splitter routes to input or dump by assignment", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 10, max_stack = 10 })
    local group1 = make_group(ctx, 1, nil, {})
    setup(ctx, { [0] = group0, [1] = group1 })
    local ok, err = run(ctx, 200, function(c)
        if not slot_occupied(c.state.valves.fail) and not c.state.valves.fail.releasing then
            if not c.fail_w then
                c.fail_w = true
                place_item(c.state.valves.fail, WALLLIGHT, 3, 3)
            elseif not c.fail_copper and c.state.prefab_groups[WALLLIGHT] then
                c.fail_copper = true
                place_item(c.state.valves.fail, COPPER, 2, 2)
            elseif not c.fail_gold and c.state.prefab_groups[COPPER] then
                c.fail_gold = true
                place_item(c.state.valves.fail, GOLD, 1, 1)
            end
        end
    end)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.fail_gold, "gold item never placed")
    expect(group0.confirmed_quantity == 13, "fail item for assigned group not re-admitted: " .. group0.confirmed_quantity)
    expect(ctx.state.prefab_groups[COPPER] == group1, "copper not assigned to free group")
    expect(group1.confirmed_quantity == 2, "copper fail item not re-admitted: " .. group1.confirmed_quantity)
    expect(total(ctx.dumped) == 1 and ctx.dumped[1].prefab_hash == GOLD, "gold not dumped")
    local routes = {}
    for _, seen in ipairs(ctx.fail_routes) do
        routes[seen.prefab] = seen.mode
    end
    expect(routes[WALLLIGHT] == 1, "existing-group fail item routed Mode" .. tostring(routes[WALLLIGHT]) .. " expected 1")
    expect(routes[COPPER] == 1, "new-group fail item routed Mode" .. tostring(routes[COPPER]) .. " expected 1")
    expect(routes[GOLD] == 0, "unassigned fail item routed Mode" .. tostring(routes[GOLD]) .. " expected 0")
    local dump_log = false
    for _, line in ipairs(ctx.log) do
        if line:find("to dump", 1, true) then
            dump_log = true
        end
    end
    expect(dump_log, "no fail-routing log line mentions dump")
end)

test("delayed silo close completes drain after actual open zero", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, {
        confirmed = 35,
        max_stack = 10,
        stacker_item = 5,
        drain_queue = {
            { quantity = 10, appear_delay = 4, transit = 1 },
            { quantity = 10, appear_delay = 3, transit = 4 },
            { quantity = 10, appear_delay = 2, transit = 1 },
        },
    })
    local group1 = make_group(ctx, 1, nil, {})
    setup(ctx, { [0] = group0, [1] = group1 })
    group0.silo.open_close_delay = 3
    local request_id = request(ctx, WALLLIGHT, 35)
    local last_deliver_tick
    local pending_close_ticks = 0
    local ok, err = run(ctx, 600, function(c)
        if total(c.delivered) == 35 and not last_deliver_tick then
            last_deliver_tick = c.state.tick
        end
        if c.state.output_task and c.state.output_task.drain_close_tick then
            pending_close_ticks = pending_close_ticks + 1
            expect(c.state.prefab_groups[WALLLIGHT] == group0, "map dropped during pending close")
            expect(decode_sorter_row(group0.sorter.mem[0]) == WALLLIGHT, "filter dropped during pending close")
            expect(group0.reserved_quantity == 35, "reservation released during pending close")
        end
    end)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[request_id].state == "completed", "request not completed")
    expect(total(ctx.delivered) == 35, "delivered " .. total(ctx.delivered))
    expect(pending_close_ticks >= 2, "no pending-close wait observed: " .. pending_close_ticks)
    expect(group0.silo.open_close_writes == 1, "close command written " .. tostring(group0.silo.open_close_writes) .. " times")
    assert_drain_invariants(ctx, group0, WALLLIGHT, true)
    expect(group0.confirmed_quantity == 0, "source ledger not zero: " .. group0.confirmed_quantity)
    for _, release in ipairs(ctx.released_group_states) do
        expect(release.silo_open == 0, "assignment cleared before actual silo open zero")
        expect(last_deliver_tick and last_deliver_tick < release.tick,
            "final output did not release before close confirmation")
    end
end)

test("stalled silo close faults bounded without release", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, {
        confirmed = 35,
        max_stack = 10,
        stacker_item = 5,
        drain_queue = {
            { quantity = 10, appear_delay = 3, transit = 1 },
            { quantity = 10, appear_delay = 3, transit = 2 },
            { quantity = 10, appear_delay = 3, transit = 2 },
        },
    })
    local group1 = make_group(ctx, 1, nil, {})
    setup(ctx, { [0] = group0, [1] = group1 })
    group0.silo.stuck_open = true
    local request_id = request(ctx, WALLLIGHT, 35)
    local ok, err = run(ctx, 200)
    expect(not ok, "stalled close unexpectedly completed")
    expect(ctx.state.fault ~= nil or tostring(err):find("timeout") or tostring(err):find("did not confirm"),
        "no bounded fault for stalled close: " .. tostring(err))
    expect(#ctx.released_group_states == 0, "group released while close unconfirmed")
    expect(group0.state == "draining", "group lost draining state during stalled close: " .. tostring(group0.state))
    expect(ctx.state.prefab_groups[WALLLIGHT] == group0, "map dropped during stalled close")
    expect(group0.reserved_quantity == 35, "reservation released during stalled close")
    expect(ctx.state.requests[request_id].state ~= "completed", "request completed while close unconfirmed")
end)

test("silo close write error faults without release", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, {
        confirmed = 35,
        max_stack = 10,
        stacker_item = 5,
        drain_queue = {
            { quantity = 10, appear_delay = 3, transit = 1 },
            { quantity = 10, appear_delay = 3, transit = 2 },
            { quantity = 10, appear_delay = 3, transit = 2 },
        },
    })
    setup(ctx, { [0] = group0 })
    ctx.write_errors[group0.silo.ref_id .. ":" .. LT.Open .. ":0"] = "forced close write failure"
    request(ctx, WALLLIGHT, 35)
    local ok, err = run(ctx, 300)
    expect(not ok, "close write error silently completed")
    expect(ctx.state.fault and ctx.state.fault.code == "device_error",
        "expected device_error fault, got: " .. tostring(ctx.state.fault and ctx.state.fault.code or err))
    expect(tostring(ctx.state.fault.detail):find("silo close", 1, true),
        "fault detail not silo close: " .. tostring(ctx.state.fault and ctx.state.fault.detail))
    expect(#ctx.released_group_states == 0, "group released on failed close write")
end)

test("silo close confirmation read error faults without release", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, {
        confirmed = 35,
        max_stack = 10,
        stacker_item = 5,
        drain_queue = {
            { quantity = 10, appear_delay = 3, transit = 1 },
            { quantity = 10, appear_delay = 3, transit = 2 },
            { quantity = 10, appear_delay = 3, transit = 2 },
        },
    })
    setup(ctx, { [0] = group0 })
    ctx.read_errors[group0.silo.ref_id .. ":" .. LT.Open] = "forced close read failure"
    request(ctx, WALLLIGHT, 35)
    local ok, err = run(ctx, 300)
    expect(not ok, "close read error silently completed")
    expect(ctx.state.fault and ctx.state.fault.code == "device_error",
        "expected device_error fault, got: " .. tostring(ctx.state.fault and ctx.state.fault.code or err))
    expect(tostring(ctx.state.fault.detail):find("did not confirm", 1, true),
        "fault detail not close confirmation: " .. tostring(ctx.state.fault and ctx.state.fault.detail))
    expect(#ctx.released_group_states == 0, "group released on failed close read")
end)

test("pending close reopens on fresh matching stock", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 10, max_stack = 10 })
    setup(ctx, { [0] = group0 })
    local state = ctx.state
    local task = {
        request = { prefab_hash = WALLLIGHT, reserved_quantity = 10, request_id = "synthetic", state = "active" },
        group = group0,
        remaining_quantity = 0,
        buffered_quantity = 0,
        draining_group = true,
        drain_source_observed = true,
        drain_empty_ticks = 2,
        drain_close_tick = state.tick,
        silo_closed = false,
    }
    group0.silo.logic[LT.Open] = 1
    place_item(group0.stacker, WALLLIGHT, 10, 10)
    local ok, err = ctx.M.service_group_drain(task)
    expect(ok == true and err == nil, "reopen call failed: " .. tostring(err))
    expect(task.drain_close_tick == nil, "close tick not cleared on fresh stock")
    expect(task.silo_closed == false, "silo_closed stayed true after reopen")
    expect(task.drain_empty_ticks == 0, "empty ticks not reset on reopen")
    expect(group0.silo.logic[LT.Open] == 1, "silo not reopened")
    expect(group0.stacker.logic[LT.Activate] == 1, "stacker not re-pulsed after reopen")
    expect(state.prefab_groups[WALLLIGHT] == group0, "map dropped on reopen")
    expect(decode_sorter_row(group0.sorter.mem[0]) == WALLLIGHT, "filter dropped on reopen")
    take_item(group0.stacker)
    group0.confirmed_quantity = 0
    for _ = 1, 4 do
        ok, err = ctx.M.service_group_drain(task)
        expect(ok == true and err == nil, "post-drain call failed: " .. tostring(err))
    end
    expect(task.draining_group == false, "drain did not finish after stock accounted")
    expect(task.drain_close_tick == nil, "close tick not reset after release")
    expect(group0.state == "unassigned", "group not unassigned after release: " .. tostring(group0.state))
    expect(state.prefab_groups[WALLLIGHT] == nil, "map retained after release")
    expect(decode_sorter_row(group0.sorter.mem[0]) == nil, "filter retained after release")
end)

local function expect_group_reset(group, label)
    expect(group.state == "unassigned", label .. " state: " .. tostring(group.state))
    expect(group.assignment_prefab_hash == nil, label .. " assignment retained")
    expect(group.confirmed_quantity == 0, label .. " confirmed: " .. group.confirmed_quantity)
    expect(group.reserved_quantity == 0, label .. " reserved: " .. group.reserved_quantity)
    expect(group.max_stack_quantity == nil, label .. " max stack retained")
    expect(group.silo_stack_count == 0, label .. " silo count: " .. tostring(group.silo_stack_count))
    expect(group.silo_memory_cursor == 0, label .. " memory cursor")
    expect(next(group.silo_memory_words) == nil, label .. " memory words")
    expect(group.scan_complete, label .. " scan incomplete")
    expect(decode_sorter_row(group.sorter.mem[0]) == nil, label .. " sorter row retained")
end

test("ordinary full silo depletion releases group", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 10, silo_stacks = 1, max_stack = 10 })
    setup(ctx, { [0] = group0 })
    local request_id = request(ctx, WALLLIGHT, 10)
    local ok, err = run(ctx, 300)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[request_id].state == "completed", "request not completed")
    expect(total(ctx.delivered) == 10, "delivered " .. total(ctx.delivered))
    expect_group_reset(group0, "depleted group")
    expect(ctx.state.prefab_groups[WALLLIGHT] == nil, "map retained after depletion")
    expect((group0.stacker.activate_writes or 0) == 0, "stacker activated for ordinary silo request")
    for _, line in ipairs(ctx.log) do
        expect(not line:find("partial%-stack drain"), "partial drain started for silo request")
    end
    place_item(ctx.state.valves.input, COPPER, 4, 10)
    ok, err = run(ctx, 60)
    expect(ok, "reuse run failed: " .. tostring(err))
    expect(ctx.state.prefab_groups[COPPER] == group0, "freed group not reused for copper")
    expect(group0.confirmed_quantity == 4, "copper ledger: " .. group0.confirmed_quantity)
    expect(group0.assignment_prefab_hash == COPPER, "freed group assigned wrong prefab")
end)

test("two full silo stacks deplete cleanly", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 20, silo_stacks = 2, max_stack = 10 })
    setup(ctx, { [0] = group0 })
    local request_id = request(ctx, WALLLIGHT, 20)
    local ok, err = run(ctx, 300)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[request_id].state == "completed", "request not completed")
    expect(total(ctx.delivered) == 20, "delivered " .. total(ctx.delivered))
    expect_group_reset(group0, "depleted group")
    expect(ctx.state.prefab_groups[WALLLIGHT] == nil, "map retained after depletion")
end)

test("partial silo request retains assignment", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 20, silo_stacks = 2, max_stack = 10 })
    setup(ctx, { [0] = group0 })
    local request_id = request(ctx, WALLLIGHT, 10)
    local ok, err = run(ctx, 300)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[request_id].state == "completed", "request not completed")
    expect(total(ctx.delivered) == 10, "delivered " .. total(ctx.delivered))
    expect(group0.state == "assigned", "group released for partial request: " .. tostring(group0.state))
    expect(group0.confirmed_quantity == 10, "confirmed: " .. group0.confirmed_quantity)
    expect(ctx.state.prefab_groups[WALLLIGHT] == group0, "map dropped for partial request")
    expect(decode_sorter_row(group0.sorter.mem[0]) == WALLLIGHT, "filter dropped for partial request")
end)

test("queued same-group requests deplete after second completes", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 20, silo_stacks = 2, max_stack = 10 })
    setup(ctx, { [0] = group0 })
    local first_id = request(ctx, WALLLIGHT, 10)
    local second_id = request(ctx, WALLLIGHT, 10)
    local saw_second_active = false
    local ok, err = run(ctx, 400, function(c)
        local second = c.state.requests[second_id]
        if second.state == "active" and not saw_second_active then
            saw_second_active = true
            expect(c.state.prefab_groups[WALLLIGHT] == group0, "map dropped before second request")
            expect(group0.state == "assigned" or group0.state == "draining",
                "group lost before second request: " .. tostring(group0.state))
            expect(group0.reserved_quantity == 10,
                "second reservation lost: " .. tostring(group0.reserved_quantity))
        end
    end)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[first_id].state == "completed", "first not completed")
    expect(saw_second_active, "second request never activated")
    expect(ctx.state.requests[second_id].state == "completed",
        "second not completed: " .. tostring(ctx.state.requests[second_id].state))
    expect(ctx.state.requests[second_id].state ~= "rejected", "second rejected inventory_changed")
    expect(total(ctx.delivered) == 20, "delivered " .. total(ctx.delivered))
    expect_group_reset(group0, "depleted group")
end)

test("ordinary excess return releases and reassigns", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 10, silo_stacks = 1, max_stack = 10 })
    setup(ctx, { [0] = group0 })
    local request_id = request(ctx, WALLLIGHT, 5)
    local ok, err = run(ctx, 400)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[request_id].state == "completed", "request not completed")
    expect(total(ctx.delivered) == 5, "delivered " .. total(ctx.delivered))
    expect(total(ctx.returned) == 5, "returned " .. total(ctx.returned))
    local assigned = ctx.state.prefab_groups[WALLLIGHT]
    expect(assigned ~= nil, "excess not re-admitted to a group")
    expect(assigned.confirmed_quantity == 5, "re-admitted ledger: " .. tostring(assigned.confirmed_quantity))
    expect(assigned.state ~= "draining", "group left in draining state")
end)

test("ordinary depletion with delayed silo close", function(ctx)
    local group0 = make_group(ctx, 0, WALLLIGHT, { confirmed = 10, silo_stacks = 1, max_stack = 10 })
    setup(ctx, { [0] = group0 })
    group0.silo.open_close_delay = 3
    local request_id = request(ctx, WALLLIGHT, 10)
    local saw_pending_close = false
    local ok, err = run(ctx, 300, function(c)
        local task = c.state.output_task
        if task and task.drain_close_tick then
            saw_pending_close = true
            expect(c.state.prefab_groups[WALLLIGHT] == group0, "map dropped during pending close")
        end
    end)
    expect(ok, "run failed: " .. tostring(err))
    expect(ctx.state.requests[request_id].state == "completed", "request not completed")
    expect(total(ctx.delivered) == 10, "delivered " .. total(ctx.delivered))
    expect(saw_pending_close, "close confirmation never pending")
    local release_tick
    for _, release in ipairs(ctx.released_group_states) do
        release_tick = release.tick
        expect(release.silo_open == 0, "assignment cleared before observed silo open zero")
    end
    expect(release_tick ~= nil, "drain release never observed")
    expect_group_reset(group0, "depleted group")
    expect(ctx.state.prefab_groups[WALLLIGHT] == nil, "map retained after depletion")
end)

print("")
for _, line in ipairs(results) do
    print(line)
end
local failed = 0
local total_tests = 0
for _, line in ipairs(results) do
    if line:sub(1, 4) == "PASS" then
        total_tests = total_tests + 1
    elseif line:sub(1, 4) == "FAIL" then
        failed = failed + 1
        total_tests = total_tests + 1
    end
end
print(string.format("%d/%d tests failed", failed, total_tests))
os.exit(failed == 0 and 0 or 1)
