local LT = ic.enums.LogicType
local LST = ic.enums.LogicSlotType
local SI = ic.enums.SorterInstruction

local API_VERSION = 1
local CONTROLLER_SCHEMA_VERSION = 1
local GROUP_STACKER_SETTING = 500
local VALVE_ITEM_LIMIT = 1
local SORTER_ROWS = 32
local MAX_QUEUE_LENGTH = 64
local MAX_REQUEST_HISTORY = 128
local VALVE_TIMEOUT_TICKS = 120
local DRAIN_EMPTY_CONFIRM_TICKS = 2
local MAX_DISCOVERY_ATTEMPTS = 20
local DISCOVERY_STABLE_SCANS = 3
local SILO_MEMORY_WORDS = 600
local MAX_SILO_MEMORY_READS_PER_TICK = 1

local PREFAB_SORTER = 873418029
local PREFAB_STACKER = -2020231820
local PREFAB_STACKER_REVERSE = 1585641623
local PREFAB_SILO = 1155865682

local NAME_INPUT_VALVE = "Storage.InputValve"
local NAME_FAIL_VALVE = "Storage.FailValve"
local NAME_FAIL_SPLITTER = "Storage.FailSplitter"
local NAME_OUTPUT_IN_VALVE = "Storage.OutputInValve"
local NAME_OUTPUT_STACKER = "Storage.OutputStacker"
local NAME_OUTPUT_OUT_VALVE = "Storage.OutputOutValve"
local NAME_OUTPUT_SPLITTER = "Storage.OutputSplitter"

local state = {
    phase = "booting",
    errors = {},
    groups = {},
    group_count = 0,
    prefab_groups = {},
    requests = {},
    request_order = {},
    idempotency = {},
    queue = {},
    active_request_id = nil,
    output_task = nil,
    stray = nil,
    state_revision = 0,
    inventory_revision = 0,
    sequence = 0,
    tick = 0,
    devices = {},
    valves = {},
    splitters = {},
    output_stacker = nil,
    fault = nil,
}

local function safe_call(fn, ...)
    local result = { pcall(fn, ...) }
    if not result[1] then
        return nil, result[2]
    end
    return result[2]
end

local function safe_read(ref_id, logic_type)
    return safe_call(ic.read_id, ref_id, logic_type)
end

local function safe_write(ref_id, logic_type, value)
    local _, err = safe_call(ic.write_id, ref_id, logic_type, value)
    return err == nil, err
end

local function safe_slot(ref_id, slot, slot_type)
    return safe_call(ic.read_slot_id, ref_id, slot, slot_type)
end

local function safe_memory_read(ref_id, address)
    return safe_call(ic.mem.get_id, ref_id, address)
end

local function safe_memory_write(ref_id, address, value)
    local _, err = safe_call(ic.mem.put_id, ref_id, address, value)
    return err == nil, err
end

local function now()
    return state.tick
end

local function bump_state()
    state.state_revision = state.state_revision + 1
end

local function add_error(code, detail)
    state.errors[#state.errors + 1] = { code = code, detail = detail }
    local message = code .. ": " .. tostring(detail)
    print("StorageController error: " .. message)
    error(message, 0)
end

local function publish(topic, payload)
    pcall(ic.net.publish, topic, payload)
end

local function publish_state()
    bump_state()
    print("StorageController phase: " .. state.phase)
    publish("storage/v1/state", {
        api_version = API_VERSION,
        schema_version = CONTROLLER_SCHEMA_VERSION,
        phase = state.phase,
        state_revision = state.state_revision,
        fault = state.fault,
        queue_depth = #state.queue,
        active_request_id = state.active_request_id,
    })
end

local function persist()
    local saved_requests = {}
    for _, request_id in ipairs(state.request_order) do
        local request = state.requests[request_id]
        if request then
            saved_requests[#saved_requests + 1] = request
        end
    end
    local ok, encoded = pcall(util.json.encode, {
        schema_version = CONTROLLER_SCHEMA_VERSION,
        sequence = state.sequence,
        inventory_revision = state.inventory_revision,
        requests = saved_requests,
        queue = state.queue,
    })
    if not ok then
        add_error("persistence_error", tostring(encoded))
        return false
    end
    local stored, store_err = safe_call(ic.persist.set, "storage_controller", encoded)
    if store_err ~= nil then
        add_error("persistence_error", tostring(store_err))
        return false
    end
    return stored ~= false
end

local function restore_persistence()
    local encoded = safe_call(ic.persist.get, "storage_controller")
    if encoded == nil or encoded == "" then
        return
    end
    local ok, saved = pcall(util.json.decode, encoded)
    if not ok or type(saved) ~= "table" or saved.schema_version ~= CONTROLLER_SCHEMA_VERSION then
        add_error("persistence_error", "unsupported or corrupt saved state")
        return
    end
    state.sequence = tonumber(saved.sequence) or 0
    state.inventory_revision = tonumber(saved.inventory_revision) or 0
    for _, request in ipairs(saved.requests or {}) do
        if type(request) == "table" and type(request.request_id) == "string" then
            state.requests[request.request_id] = request
            state.request_order[#state.request_order + 1] = request.request_id
            if request.client_key then
                state.idempotency[request.client_key] = request.request_id
            end
        end
    end
    for _, request_id in ipairs(saved.queue or {}) do
        if state.requests[request_id] and state.requests[request_id].state == "queued" then
            state.queue[#state.queue + 1] = request_id
        end
    end
end

local function set_phase(phase)
    state.phase = phase
    publish_state()
end

local function fault(code, detail)
    if state.phase == "faulted" then
        error(code .. ": " .. tostring(detail), 0)
    end
    print("StorageController fault: " .. code .. ": " .. tostring(detail))
    state.fault = { code = code, detail = detail, tick = now() }
    state.phase = "faulted"
    for _, valve in pairs(state.valves) do
        safe_write(valve.ref_id, LT.Open, 0)
    end
    for _, splitter in pairs(state.splitters) do
        safe_write(splitter.ref_id, LT.Mode, 0)
    end
    for _, group in pairs(state.groups) do
        safe_write(group.silo.ref_id, LT.Open, 0)
    end
    persist()
    publish("storage/v1/fault", state.fault)
    publish_state()
    error(code .. ": " .. tostring(detail), 0)
end

local function is_group_label(name)
    return type(name) == "string" and name:match("^0x[%x][%x][%x][%x]$") ~= nil
end

local function group_id(name)
    if not is_group_label(name) then
        return nil
    end
    return tonumber(name:sub(3), 16)
end

local function canonical_label(id)
    return string.format("0x%04X", id)
end

local function is_stacker_prefab(prefab_hash)
    return prefab_hash == PREFAB_STACKER or prefab_hash == PREFAB_STACKER_REVERSE
end

local function item_name(prefab_hash)
    local ok, name = pcall(prefab_name, prefab_hash)
    if ok and name then
        return name
    end
    return tostring(prefab_hash)
end

local function add_bucket(buckets, name, kind, device)
    local bucket = buckets[name]
    if not bucket then
        bucket = { sorters = {}, stackers = {}, silos = {} }
        buckets[name] = bucket
    end
    bucket[kind][#bucket[kind] + 1] = device
end

local function discover_topology()
    print("StorageController: discovering storage topology")
    local devices, err = safe_call(ic.device.list)
    if devices == nil then
        return false, { "topology_scan_failed: " .. tostring(err) }
    end

    local buckets = {}
    local reserved = {}
    local topology_errors = {}
    local function record_error(code, detail)
        topology_errors[#topology_errors + 1] = code .. ": " .. detail
    end
    state.groups = {}
    state.group_count = 0
    for _, device in ipairs(devices) do
        local name = device.display_name
        if device.prefab_hash == PREFAB_SORTER and is_group_label(name) then
            add_bucket(buckets, name, "sorters", device)
        elseif is_stacker_prefab(device.prefab_hash) and is_group_label(name) then
            add_bucket(buckets, name, "stackers", device)
        elseif device.prefab_hash == PREFAB_SILO and is_group_label(name) then
            add_bucket(buckets, name, "silos", device)
        elseif name == NAME_OUTPUT_STACKER and is_stacker_prefab(device.prefab_hash) then
            reserved.output_stacker = reserved.output_stacker or {}
            reserved.output_stacker[#reserved.output_stacker + 1] = device
        elseif name == NAME_INPUT_VALVE or name == NAME_FAIL_VALVE or name == NAME_OUTPUT_IN_VALVE or name == NAME_OUTPUT_OUT_VALVE then
            reserved[name] = reserved[name] or {}
            reserved[name][#reserved[name] + 1] = device
        elseif name == NAME_FAIL_SPLITTER or name == NAME_OUTPUT_SPLITTER then
            reserved[name] = reserved[name] or {}
            reserved[name][#reserved[name] + 1] = device
        elseif device.prefab_hash == PREFAB_SORTER or is_stacker_prefab(device.prefab_hash) or device.prefab_hash == PREFAB_SILO then
            record_error("unexpected_managed_device", tostring(name))
        end
    end

    for _, name in ipairs({ NAME_INPUT_VALVE, NAME_FAIL_VALVE, NAME_FAIL_SPLITTER, NAME_OUTPUT_IN_VALVE, NAME_OUTPUT_STACKER, NAME_OUTPUT_OUT_VALVE, NAME_OUTPUT_SPLITTER }) do
        local key = name == NAME_OUTPUT_STACKER and "output_stacker" or name
        local matches = reserved[key]
        if matches == nil or #matches ~= 1 then
            record_error("reserved_device_count", name .. " expected exactly one")
        end
    end

    local expected = 0
    while true do
        local label = canonical_label(expected)
        local bucket = buckets[label]
        if not bucket then
            break
        end
        if #bucket.sorters ~= 1 or #bucket.stackers ~= 1 or #bucket.silos ~= 1 then
            record_error("invalid_group", label .. " must contain one sorter, stacker, and silo")
        else
            state.groups[expected] = {
                id = expected,
                label = label,
                sorter = bucket.sorters[1],
                stacker = bucket.stackers[1],
                silo = bucket.silos[1],
                state = "unassigned",
                confirmed_quantity = 0,
                reserved_quantity = 0,
                scan_complete = false,
                silo_memory_cursor = 0,
                silo_memory_words = {},
                clearing_stacker = false,
                clearing_tick = 0,
            }
        end
        buckets[label] = nil
        expected = expected + 1
    end
    for label in pairs(buckets) do
        record_error("non_contiguous_or_orphaned_group", label)
    end
    if expected == 0 then
        record_error("no_groups", "no complete groups starting at 0x0000")
    end
    state.group_count = expected

    if #topology_errors > 0 then
        return false, topology_errors
    end
    state.valves.input = reserved[NAME_INPUT_VALVE][1]
    state.valves.fail = reserved[NAME_FAIL_VALVE][1]
    state.valves.output_in = reserved[NAME_OUTPUT_IN_VALVE][1]
    state.valves.output_out = reserved[NAME_OUTPUT_OUT_VALVE][1]
    state.splitters.fail = reserved[NAME_FAIL_SPLITTER][1]
    state.splitters.output = reserved[NAME_OUTPUT_SPLITTER][1]
    state.output_stacker = reserved.output_stacker[1]
    print("StorageController: discovered " .. tostring(state.group_count) .. " storage groups")
    return true
end

local function topology_signature()
    local parts = {
        tostring(state.group_count),
        tostring(state.valves.input.ref_id),
        tostring(state.valves.fail.ref_id),
        tostring(state.valves.output_in.ref_id),
        tostring(state.valves.output_out.ref_id),
        tostring(state.splitters.fail.ref_id),
        tostring(state.splitters.output.ref_id),
        tostring(state.output_stacker.ref_id),
    }
    for id = 0, state.group_count - 1 do
        local group = state.groups[id]
        parts[#parts + 1] = tostring(group.sorter.ref_id)
        parts[#parts + 1] = tostring(group.stacker.ref_id)
        parts[#parts + 1] = tostring(group.silo.ref_id)
    end
    return table.concat(parts, ":")
end

local function configure(ref_id, logic_type, value, name)
    local ok, err = safe_write(ref_id, logic_type, value)
    if not ok then
        add_error("device_configuration_failed", name .. ": " .. tostring(err))
        return false
    end
    local observed, read_err = safe_read(ref_id, logic_type)
    if read_err ~= nil or observed ~= value then
        add_error("device_configuration_mismatch", name .. " expected " .. tostring(value) .. " observed " .. tostring(observed))
        return false
    end
    return true
end

local function configure_devices()
    for _, valve in pairs(state.valves) do
        configure(valve.ref_id, LT.On, 1, valve.display_name)
        configure(valve.ref_id, LT.Setting, VALVE_ITEM_LIMIT, valve.display_name)
        configure(valve.ref_id, LT.Open, 0, valve.display_name)
    end
    for _, group in pairs(state.groups) do
        configure(group.sorter.ref_id, LT.On, 1, group.label)
        configure(group.sorter.ref_id, LT.Mode, 1, group.label)
        configure(group.stacker.ref_id, LT.On, 1, group.label)
        configure(group.stacker.ref_id, LT.Mode, 0, group.label)
        configure(group.stacker.ref_id, LT.Setting, GROUP_STACKER_SETTING, group.label)
        configure(group.silo.ref_id, LT.On, 1, group.label)
        configure(group.silo.ref_id, LT.Open, 0, group.label)
    end
    configure(state.output_stacker.ref_id, LT.On, 1, NAME_OUTPUT_STACKER)
    configure(state.output_stacker.ref_id, LT.Mode, 1, NAME_OUTPUT_STACKER)
    configure(state.output_stacker.ref_id, LT.Setting, GROUP_STACKER_SETTING, NAME_OUTPUT_STACKER)
    configure(state.output_stacker.ref_id, LT.Output, -1, NAME_OUTPUT_STACKER)
    for _, splitter in pairs(state.splitters) do
        configure(splitter.ref_id, LT.On, 1, splitter.display_name)
        configure(splitter.ref_id, LT.Mode, 0, splitter.display_name)
    end
    return #state.errors == 0
end

local function signed32(value)
    value = value % 4294967296
    if value >= 2147483648 then
        return value - 4294967296
    end
    return value
end

--[[
SDB memory records store the stack quantity in bits 8-20. The game currently
reports ingot stacks with quantity 1, so treat that value as 500 until the game
fixes the encoded quantity.
]]
local function decode_silo_stack(word)
    if type(word) ~= "number" or word <= 0 or word % 1 ~= 0 or math.floor(word / 9007199254740992) ~= 0 then
        return nil
    end
    local quantity = math.floor(word / 256) % 8192
    local prefab_hash = signed32(math.floor(word / 2097152) % 4294967296)
    if quantity <= 0 or prefab_hash == 0 then
        return nil
    end
    if quantity == 1 then
        print("StorageController: SDB memory quantity is 1 for " .. item_name(prefab_hash) .. "; overriding quantity to 500")
        quantity = 500
    end
    return {
        quantity = quantity,
        prefab_hash = prefab_hash,
    }
end

local function format_silo_word(word, radix, digits)
    if type(word) ~= "number" or word < 0 or word % 1 ~= 0 or math.floor(word / 9007199254740992) ~= 0 then
        return nil
    end
    local alphabet = "0123456789ABCDEF"
    local encoded = {}
    for index = digits, 1, -1 do
        local digit = word % radix
        encoded[index] = alphabet:sub(digit + 1, digit + 1)
        word = math.floor(word / radix)
    end
    return table.concat(encoded)
end

local function log_silo_raw_word(group, address, word, memory_error)
    if group.label ~= "0x0000" then
        return
    end
    print("StorageController: 0x0000 silo memory address=" .. tostring(address))
    print("  decimal=" .. tostring(word))
    print("  hex=" .. tostring(format_silo_word(word, 16, 16)))
    print("  bits=" .. tostring(format_silo_word(word, 2, 64)))
    print("  error=" .. tostring(memory_error))
end

local function probe_silo_memory(group)
    local first_word
    local first_error
    for address = 0, 2 do
        local word, memory_error = safe_memory_read(group.silo.ref_id, address)
        log_silo_raw_word(group, address, word, memory_error)
        if address == 0 then
            first_word = word
            first_error = memory_error
        end
    end
    return first_word, first_error
end

local function encode_sorter_row(prefab_hash)
    return SI.FilterPrefabHashEquals + ((prefab_hash % 4294967296) * 256)
end

local function decode_sorter_row(row)
    if type(row) ~= "number" or row < 0 then
        return nil
    end
    local opcode = row % 256
    if opcode ~= SI.FilterPrefabHashEquals then
        return nil
    end
    local packed_hash = math.floor(row / 256) % 4294967296
    if math.floor(row / 1099511627776) ~= 0 then
        return nil
    end
    return signed32(packed_hash)
end

local function set_assignment(group, prefab_hash)
    for address = 0, SORTER_ROWS - 1 do
        local value = address == 0 and encode_sorter_row(prefab_hash) or 0
        local ok, err = safe_memory_write(group.sorter.ref_id, address, value)
        if not ok then
            return false, "sorter memory write failed: " .. tostring(err)
        end
        local observed = safe_memory_read(group.sorter.ref_id, address)
        if observed ~= value then
            return false, "sorter memory read-back mismatch"
        end
    end
    group.assignment_prefab_hash = prefab_hash
    group.assignment_source = "new_input"
    group.state = "assigned"
    state.prefab_groups[prefab_hash] = group
    print("StorageController: assigned " .. group.label .. " to " .. item_name(prefab_hash))
    return true
end

local function clear_assignment(group, next_state)
    local prefab_hash = group.assignment_prefab_hash
    group.state = next_state or "unassigned"
    if group.state == "unassigned" then
        group.clearing_stacker = false
        group.clearing_tick = 0
    end
    for address = 0, SORTER_ROWS - 1 do
        local ok, err = safe_memory_write(group.sorter.ref_id, address, 0)
        if not ok then
            return false, "sorter memory clear failed: " .. tostring(err)
        end
        if safe_memory_read(group.sorter.ref_id, address) ~= 0 then
            return false, "sorter memory clear read-back mismatch"
        end
    end
    if prefab_hash and state.prefab_groups[prefab_hash] == group then
        state.prefab_groups[prefab_hash] = nil
    end
    group.assignment_prefab_hash = nil
    group.assignment_source = nil
    print("StorageController: cleared assignment for " .. group.label)
    return true
end

local function recover_assignments()
    for _, group in pairs(state.groups) do
        local row0 = safe_memory_read(group.sorter.ref_id, 0)
        if row0 == nil then
            add_error("sorter_memory_read_failed", group.label)
        elseif row0 == 0 then
            group.state = "unassigned"
            group.clearing_stacker = false
            group.clearing_tick = 0
            for address = 1, SORTER_ROWS - 1 do
                if safe_memory_read(group.sorter.ref_id, address) ~= 0 then
                    add_error("invalid_sorter_program", group.label)
                    break
                end
            end
        else
            local prefab_hash = decode_sorter_row(row0)
            if prefab_hash == nil or prefab_hash == 0 or state.prefab_groups[prefab_hash] then
                add_error("invalid_sorter_program", group.label)
            else
                for address = 1, SORTER_ROWS - 1 do
                    if safe_memory_read(group.sorter.ref_id, address) ~= 0 then
                        add_error("invalid_sorter_program", group.label)
                        break
                    end
                end
                if #state.errors == 0 then
                    group.assignment_prefab_hash = prefab_hash
                    group.assignment_source = "sorter_memory"
                    group.state = "assigned"
                    state.prefab_groups[prefab_hash] = group
                    print("StorageController: recovered " .. group.label .. " assignment for " .. item_name(prefab_hash))
                end
            end
        end
    end
    return #state.errors == 0
end

local function read_item(ref_id, slot)
    slot = slot or 0
    local occupied = safe_slot(ref_id, slot, LST.Occupied)
    if occupied == nil or occupied == 0 then
        return nil
    end
    local prefab_hash = safe_slot(ref_id, slot, LST.PrefabHash)
    local quantity = safe_slot(ref_id, slot, LST.Quantity)
    local max_quantity = safe_slot(ref_id, slot, LST.MaxQuantity)
    if type(prefab_hash) ~= "number" or type(quantity) ~= "number" or quantity <= 0 then
        return nil, "invalid held item"
    end
    return { prefab_hash = prefab_hash, quantity = quantity, max_quantity = max_quantity }
end

local function read_stacker_item(ref_id)
    for slot = 0, 2 do
        local item, item_error = read_item(ref_id, slot)
        if item_error then
            return nil, item_error
        end
        if item then
            return item
        end
    end
    return nil
end

local function clear_unassigned_groups()
    local cleared_count = 0
    for _, group in pairs(state.groups) do
        if group.state == "unassigned" or group.state == "inventory_unknown" or not group.assignment_prefab_hash then
            local stacker_item, stacker_error = read_stacker_item(group.stacker.ref_id)
            if stacker_error then
                add_error("stacker_read_failed", group.label .. ": " .. stacker_error)
            elseif stacker_item then
                print("StorageController: " .. group.label .. " has unassigned item " .. item_name(stacker_item.prefab_hash) .. " in stacker; clearing")
                if not safe_write(group.stacker.ref_id, LT.Activate, 1) then
                    add_error("stacker_activation_failed", group.label)
                else
                    cleared_count = cleared_count + 1
                end
            end
            local silo_stacks = safe_read(group.silo.ref_id, LT.Quantity)
            if type(silo_stacks) == "number" and silo_stacks > 0 then
                print("StorageController: " .. group.label .. " has " .. tostring(silo_stacks) .. " unassigned silo stacks; draining")
                if not safe_write(group.silo.ref_id, LT.Open, 1) then
                    add_error("silo_open_failed", group.label)
                else
                    cleared_count = cleared_count + 1
                end
            end
            group.state = "unassigned"
            group.assignment_prefab_hash = nil
            group.assignment_source = nil
            group.confirmed_quantity = 0
            group.pending_quantity = 0
            group.max_stack_quantity = nil
            group.silo_stack_count = 0
            group.silo_memory_cursor = 0
            group.silo_memory_words = {}
            group.scan_complete = true
            group.clearing_stacker = false
            group.clearing_tick = 0
        end
    end
    if cleared_count > 0 then
        print("StorageController: cleared " .. tostring(cleared_count) .. " unassigned groups")
    end
    return #state.errors == 0
end

local function baseline_inventory()
    for _, group in pairs(state.groups) do
        local stacker_item, stacker_error = read_stacker_item(group.stacker.ref_id)
        if stacker_error then
            add_error("inventory_baseline_failed", group.label .. ": " .. stacker_error)
        end
        local silo_slots = safe_read(group.silo.ref_id, LT.Quantity)
        if type(silo_slots) ~= "number" or silo_slots < 0 then
            add_error("inventory_baseline_failed", group.label .. ": invalid silo quantity")
        else
            group.silo_stack_count = silo_slots
            local pending = stacker_item and stacker_item.quantity or 0
            group.pending_quantity = pending
            if stacker_item and stacker_item.max_quantity and stacker_item.max_quantity > 0 then
                group.max_stack_quantity = stacker_item.max_quantity
            end
            if silo_slots == 0 then
                group.confirmed_quantity = pending
                if pending > 0 then
                    local prefab_name = group.assignment_prefab_hash and item_name(group.assignment_prefab_hash) or "unknown"
                    print("StorageController: " .. group.label .. " recovered " .. tostring(pending) .. " units of " .. prefab_name .. " from stacker")
                elseif group.assignment_prefab_hash then
                    local cleared, clear_err = clear_assignment(group)
                    if not cleared then
                        add_error("sorter_memory_clear_failed", group.label .. ": " .. tostring(clear_err))
                    end
                end
            else
                local word, memory_error
                word, memory_error = safe_memory_read(group.silo.ref_id, 0)
                local stack = decode_silo_stack(word)
                if stack and stack.prefab_hash == group.assignment_prefab_hash then
                    group.max_stack_quantity = stack.quantity
                    group.confirmed_quantity = silo_slots * stack.quantity + pending
                    group.silo_memory_words[0] = word
                    group.silo_memory_cursor = 1
                    print("StorageController: " .. group.label .. " recovered " .. tostring(group.confirmed_quantity) .. " units of " .. item_name(group.assignment_prefab_hash) .. " from " .. tostring(silo_slots) .. " silo stacks")
                else
                    group.state = "inventory_unknown"
                    group.confirmed_quantity = pending
                    group.assignment_prefab_hash = nil
                    group.assignment_source = nil
                    group.clearing_stacker = false
                    group.clearing_tick = 0
                    print("StorageController: " .. group.label .. " could not decode its first silo stack: " .. tostring(memory_error or word))
                end
            end
        end
    end
    return #state.errors == 0
end

local function resolve_silo_stack_size(group)
    if group.max_stack_quantity then
        return true
    end
    local stack_count = safe_read(group.silo.ref_id, LT.Quantity)
    if type(stack_count) ~= "number" or stack_count <= 0 then
        return false
    end
    local word, memory_error = safe_memory_read(group.silo.ref_id, 0)
    local stack = decode_silo_stack(word)
    log_silo_raw_word(group, 0, word, memory_error)
    if not stack or stack.prefab_hash ~= group.assignment_prefab_hash then
        return false
    end
    group.silo_stack_count = stack_count
    group.max_stack_quantity = stack.quantity
    group.confirmed_quantity = stack_count * stack.quantity + (group.pending_quantity or 0)
    group.silo_memory_words[0] = word
    group.silo_memory_cursor = 1
    group.scan_complete = false
    group.state = "assigned"
    print("StorageController: " .. group.label .. " recovered " .. tostring(group.confirmed_quantity) .. " units on request")
    return true
end

local function available(group)
    return group.confirmed_quantity - group.reserved_quantity
end

local function scan_silo_memory()
    for _, group in pairs(state.groups) do
        if not group.scan_complete and group.state ~= "draining_mismatch" and group.state ~= "inventory_unknown" then
            for _ = 1, MAX_SILO_MEMORY_READS_PER_TICK do
                local scan_limit = math.min(group.silo_stack_count or 0, SILO_MEMORY_WORDS)
                if group.silo_memory_cursor >= scan_limit then
                    group.scan_complete = true
                    print("StorageController: completed SDB stack scan for " .. group.label)
                    return
                end
                local address = group.silo_memory_cursor
                local word, memory_error = safe_memory_read(group.silo.ref_id, address)
                if word == nil then
                    add_error("silo_memory_read_failed", group.label .. " address " .. tostring(address) .. ": " .. tostring(memory_error))
                end
                group.silo_memory_words[address] = word
                local stack = decode_silo_stack(word)
                if not stack or stack.prefab_hash ~= group.assignment_prefab_hash or stack.quantity ~= group.max_stack_quantity then
                    group.state = "inventory_mismatch"
                    print("StorageController: " .. group.label .. " stack " .. tostring(address) .. " does not match its recovered assignment")
                    if stack and stack.prefab_hash and stack.prefab_hash ~= group.assignment_prefab_hash then
                        print("StorageController: " .. group.label .. " contains wrong resource " .. item_name(stack.prefab_hash) .. " instead of " .. item_name(group.assignment_prefab_hash) .. "; draining")
                        if safe_write(group.silo.ref_id, LT.Open, 1) then
                            group.state = "draining_mismatch"
                        end
                    end
                end
                group.silo_memory_cursor = address + 1
            end
            return
        end
    end
end

local function lowest_free_group()
    for id = 0, state.group_count - 1 do
        local group = state.groups[id]
        if group and group.state == "unassigned" and group.confirmed_quantity == 0 and group.reserved_quantity == 0 then
            return group
        end
    end
end

local function release_valve(valve, splitter, route_one)
    if valve.releasing then
        if now() - valve.release_tick > VALVE_TIMEOUT_TICKS then
            fault("movement_timeout", valve.display_name .. " did not clear")
        end
        local item = read_item(valve.ref_id)
        local open = safe_read(valve.ref_id, LT.Open)
        if item == nil or open == 0 then
            valve.releasing = false
            print("StorageController: " .. valve.display_name .. " cleared")
        end
        return
    end
    if splitter then
        local mode = route_one and 0 or 1
        if valve.route_mode ~= mode then
            valve.route_mode = mode
            valve.route_tick = now()
        end
        local written = safe_write(splitter.ref_id, LT.Mode, mode)
        local observed = safe_read(splitter.ref_id, LT.Mode)
        if not written or observed ~= mode then
            if now() - valve.route_tick > VALVE_TIMEOUT_TICKS then
                fault("device_error", splitter.display_name .. " route did not confirm; observed " .. tostring(observed))
            end
            return false
        end
        valve.route_mode = nil
        valve.route_tick = nil
    end
    if not safe_write(valve.ref_id, LT.Open, 1) then
        fault("device_error", valve.display_name)
        return false
    end
    valve.releasing = true
    valve.release_tick = now()
    print("StorageController: released " .. valve.display_name)
    return true
end

local function service_input()
    local valve = state.valves.input
    if valve.releasing then
        release_valve(valve)
        return
    end
    local item, item_error = read_item(valve.ref_id)
    if item_error then
        fault("device_error", NAME_INPUT_VALVE .. ": " .. item_error)
        return
    end
    if not item then
        return
    end
    local group = state.prefab_groups[item.prefab_hash]
    if not group then
        group = lowest_free_group()
        if group then
            local ok, err = set_assignment(group, item.prefab_hash)
            if not ok then
                fault("device_error", group.label .. ": " .. err)
                return
            end
        end
    end
    if group then
        if not group.max_stack_quantity and type(item.max_quantity) == "number" and item.max_quantity > 0 then
            group.max_stack_quantity = item.max_quantity
        end
        group.confirmed_quantity = group.confirmed_quantity + item.quantity
        state.inventory_revision = state.inventory_revision + 1
        persist()
        print("StorageController: admitted " .. tostring(item.quantity) .. " of " .. item_name(item.prefab_hash) .. " to " .. group.label)
    else
        print("StorageController: no free group for " .. item_name(item.prefab_hash) .. "; forwarding to fail path")
    end
    release_valve(valve)
end

local function service_fail()
    local valve = state.valves.fail
    if valve.releasing then
        release_valve(valve)
        return
    end
    local item, item_error = read_item(valve.ref_id)
    if item_error then
        fault("device_error", NAME_FAIL_VALVE .. ": " .. item_error)
        return
    end
    if not item then
        return
    end
    local group = state.prefab_groups[item.prefab_hash]
    if not group then
        group = lowest_free_group()
        if group then
            local ok, err = set_assignment(group, item.prefab_hash)
            if not ok then
                fault("device_error", group.label .. ": " .. err)
                return
            end
        end
    end
    print("StorageController: fail valve routing " .. item_name(item.prefab_hash) .. " to " .. (group and "input" or "dump"))
    release_valve(valve, state.splitters.fail, group ~= nil)
end

local transition

local function set_output_stage(task, stage)
    task.stage = stage
    task.stage_tick = now()
end

local function fail_output_task(task, code, detail)
    task.request.error_code = code
    persist()
    fault(code, detail)
end

local function reject_output_task(task, code, detail)
    local request = task.request
    task.group.reserved_quantity = math.max(0, task.group.reserved_quantity - request.reserved_quantity)
    task.group.confirmed_quantity = 0
    state.inventory_revision = state.inventory_revision + 1
    transition(request, "rejected", code)
    state.active_request_id = nil
    state.output_task = nil
    persist()
    print("StorageController: rejected request " .. request.request_id .. ": " .. detail)
end

local function start_output_task()
    while #state.queue > 0 do
        local request_id = table.remove(state.queue, 1)
        local request = state.requests[request_id]
        if request and request.state == "queued" then
            local group = state.groups[request.group_id]
            if not group or group.assignment_prefab_hash ~= request.prefab_hash or not group.max_stack_quantity or group.max_stack_quantity <= 0 then
                if group then
                    group.reserved_quantity = math.max(0, group.reserved_quantity - request.reserved_quantity)
                end
                transition(request, "rejected", "inventory_changed")
                persist()
            else
                transition(request, "active")
                state.active_request_id = request.request_id
                state.output_task = {
                    request = request,
                    group = group,
                    remaining_quantity = request.requested_quantity,
                    buffered_quantity = 0,
                    stage = "dispense",
                    stage_tick = now(),
                }
                persist()
                print("StorageController: started request " .. request.request_id)
                return state.output_task
            end
        end
    end
    return nil
end

local function command_stacker_output(quantity)
    if not configure(state.output_stacker.ref_id, LT.Setting, quantity, NAME_OUTPUT_STACKER) then
        return false
    end
    return safe_write(state.output_stacker.ref_id, LT.Output, 1)
end

local function start_group_drain(task, stacker_item)
    if not clear_assignment(task.group, "draining") then
        return false, "sorter assignment"
    end
    task.draining_group = true
    task.drain_empty_ticks = 0
    task.drain_source_observed = false
    task.group.pending_quantity = stacker_item.quantity
    task.silo_watch_count = nil
    task.silo_closed = true
    if not safe_write(task.group.silo.ref_id, LT.Open, 1) then
        return false, "silo open"
    end
    task.silo_closed = false
    if not safe_write(task.group.stacker.ref_id, LT.Activate, 1) then
        return false, "stacker activate"
    end
    print("StorageController: activated partial-stack drain for " .. task.group.label)
    return true
end

local function service_group_drain(task)
    if not task.draining_group or not task.drain_source_observed then
        return true
    end
    local stacker_item, stacker_error = read_stacker_item(task.group.stacker.ref_id)
    if stacker_error then
        return false, "stacker: " .. stacker_error
    end
    local silo_stacks, quantity_error = safe_read(task.group.silo.ref_id, LT.Quantity)
    if type(silo_stacks) ~= "number" then
        return false, "silo quantity: " .. tostring(quantity_error)
    end
    if stacker_item or silo_stacks > 0 then
        task.drain_empty_ticks = 0
        return true
    end
    task.drain_empty_ticks = task.drain_empty_ticks + 1
    if task.drain_empty_ticks < DRAIN_EMPTY_CONFIRM_TICKS then
        return true
    end
    if not safe_write(task.group.silo.ref_id, LT.Open, 0) then
        return false, "silo close"
    end
    local silo_open, open_error = safe_read(task.group.silo.ref_id, LT.Open)
    if open_error ~= nil or silo_open ~= 0 then
        return false, "silo close did not confirm: " .. tostring(open_error or silo_open)
    end
    task.silo_closed = true
    for _, request_id in ipairs(state.queue) do
        local queued_request = state.requests[request_id]
        if queued_request and queued_request.state == "queued" and queued_request.group_id == task.group.id then
            task.group.reserved_quantity = math.max(0, task.group.reserved_quantity - queued_request.reserved_quantity)
            transition(queued_request, "rejected", "inventory_changed")
        end
    end
    task.group.reserved_quantity = math.max(0, task.group.reserved_quantity - task.request.reserved_quantity)
    task.reservation_released = true
    task.group.state = "unassigned"
    task.group.pending_quantity = 0
    task.group.max_stack_quantity = nil
    task.group.silo_stack_count = 0
    task.group.silo_memory_cursor = 0
    task.group.silo_memory_words = {}
    task.group.scan_complete = true
    task.group.clearing_stacker = false
    task.group.clearing_tick = 0
    task.draining_group = false
    print("StorageController: released empty group " .. task.group.label)
    return true
end

local function complete_output_task(task)
    local request = task.request
    if not task.reservation_released then
        task.group.reserved_quantity = math.max(0, task.group.reserved_quantity - request.reserved_quantity)
    end
    request.delivered_quantity = request.requested_quantity
    transition(request, "completed")
    state.active_request_id = nil
    state.output_task = nil
    persist()
end

-- Return idle or unexpected items from any point in the shared output path.
local function service_output_return()
    local input_valve = state.valves.output_in
    local output_valve = state.valves.output_out
    local stray = state.stray
    if stray then
        if now() - stray.stage_tick > VALVE_TIMEOUT_TICKS then
            fault("movement_timeout", "output return stage " .. stray.stage)
            return
        end
        if stray.stage == "await_stacker" then
            local output_item, output_item_error = read_stacker_item(state.output_stacker.ref_id)
            if output_item_error then
                fault("device_error", NAME_OUTPUT_STACKER .. ": " .. output_item_error)
                return
            end
            if not output_item then
                return
            end
            if output_item.prefab_hash ~= stray.prefab_hash or output_item.quantity ~= stray.quantity then
                fault("inventory_mismatch", NAME_OUTPUT_STACKER .. " does not hold the expected returned stack")
                return
            end
            if not command_stacker_output(stray.quantity) then
                fault("device_error", NAME_OUTPUT_STACKER)
                return
            end
            stray.stage = "await_output"
            stray.stage_tick = now()
            return
        end
        if stray.stage == "await_output" then
            local item, item_error = read_item(output_valve.ref_id)
            if item_error then
                fault("device_error", NAME_OUTPUT_OUT_VALVE .. ": " .. item_error)
                return
            end
            if item then
                if item.prefab_hash ~= stray.prefab_hash or item.quantity ~= stray.quantity then
                    fault("inventory_mismatch", NAME_OUTPUT_OUT_VALVE .. " returned stack quantity mismatch")
                    return
                end
                if not safe_write(state.output_stacker.ref_id, LT.Output, -1) then
                    fault("device_error", NAME_OUTPUT_STACKER)
                    return
                end
                if release_valve(output_valve, state.splitters.output, false) then
                    stray.stage = "await_clear"
                    stray.stage_tick = now()
                end
            end
            return
        end
        release_valve(output_valve)
        if not output_valve.releasing then
            print("StorageController: returned stray stack of " .. tostring(stray.quantity) .. " to storage")
            state.stray = nil
        end
        return
    end

    local task = state.output_task
    if output_valve.releasing then
        if task and (task.stage == "await_delivery_clear" or task.stage == "await_return_clear") then
            return
        end
        release_valve(output_valve)
        return
    end
    local output_item, output_error = read_item(output_valve.ref_id)
    if output_error then
        fault("device_error", NAME_OUTPUT_OUT_VALVE .. ": " .. output_error)
        return
    end
    local expected_output = task and (task.stage == "await_output" or task.stage == "await_return")
        and output_item and output_item.prefab_hash == task.request.prefab_hash
        and output_item.quantity == task.portion_quantity
    if output_item then
        if not expected_output then
            print("StorageController: " .. NAME_OUTPUT_OUT_VALVE .. " received unexpected " .. item_name(output_item.prefab_hash) .. "; returning it to storage")
            state.stray = { quantity = output_item.quantity, prefab_hash = output_item.prefab_hash, stage = "await_output", stage_tick = now() }
        end
        return
    end

    local stacker_item, stacker_error = read_stacker_item(state.output_stacker.ref_id)
    if stacker_error then
        fault("device_error", NAME_OUTPUT_STACKER .. ": " .. stacker_error)
        return
    end
    local expected_stacker = task and stacker_item and stacker_item.prefab_hash == task.request.prefab_hash
    if stacker_item then
        if not expected_stacker then
            print("StorageController: " .. NAME_OUTPUT_STACKER .. " contains unexpected " .. item_name(stacker_item.prefab_hash) .. "; returning it to storage")
            state.stray = { quantity = stacker_item.quantity, prefab_hash = stacker_item.prefab_hash, stage = "await_stacker", stage_tick = now() }
        end
        return
    end

    if input_valve.releasing then
        if task and task.stage == "await_input" then
            return
        end
        release_valve(input_valve)
        return
    end
    local item, item_error = read_item(input_valve.ref_id)
    if item_error then
        fault("device_error", NAME_OUTPUT_IN_VALVE .. ": " .. item_error)
        return
    end
    if not item then
        return
    end
    if task and item.prefab_hash == task.request.prefab_hash and task.stage == "await_input" then
        return
    end
    print("StorageController: " .. NAME_OUTPUT_IN_VALVE .. " received unexpected " .. item_name(item.prefab_hash) .. "; returning it to storage")
    state.stray = { quantity = item.quantity, prefab_hash = item.prefab_hash, stage = "await_stacker", stage_tick = now() }
    release_valve(input_valve)
end

local function service_output()
    if state.stray then
        if state.output_task then
            state.output_task.stage_tick = now()
        end
        return
    end
    local task = state.output_task or start_output_task()
    if not task then
        return
    end
    if now() - task.stage_tick > VALVE_TIMEOUT_TICKS then
        if task.stage == "await_source" and task.remaining_quantity == task.request.requested_quantity and task.buffered_quantity == 0 then
            reject_output_task(task, "insufficient_stock", task.group.label .. " did not provide the reserved material")
        else
            fail_output_task(task, "movement_timeout", "output stage " .. task.stage)
        end
        return
    end

    local input_valve = state.valves.output_in
    local output_valve = state.valves.output_out
    local drain_ok, drain_error = service_group_drain(task)
    if not drain_ok then
        fail_output_task(task, "device_error", task.group.label .. " drain: " .. drain_error)
        return
    end
    if task.stage == "dispense" then
        if task.buffered_quantity > 0 then
            task.portion_quantity = math.min(task.remaining_quantity, task.buffered_quantity)
            if not command_stacker_output(task.portion_quantity) then
                fail_output_task(task, "device_error", NAME_OUTPUT_STACKER)
                return
            end
            set_output_stage(task, "await_output")
            return
        end
        local available_stacks, quantity_error = safe_read(task.group.silo.ref_id, LT.Quantity)
        if type(available_stacks) ~= "number" then
            fail_output_task(task, "device_error", task.group.label .. " quantity: " .. tostring(quantity_error))
            return
        end
        if available_stacks <= 0 then
            local stacker_item, stacker_error = read_stacker_item(task.group.stacker.ref_id)
            if stacker_error then
                fail_output_task(task, "device_error", task.group.label .. " stacker: " .. stacker_error)
                return
            end
            if not stacker_item then
                set_output_stage(task, "await_source")
                return
            end
            if stacker_item.prefab_hash ~= task.request.prefab_hash then
                fail_output_task(task, "inventory_mismatch", task.group.label .. " stacker contains wrong prefab")
                return
            end
            local started, start_error = start_group_drain(task, stacker_item)
            if not started then
                fail_output_task(task, "device_error", task.group.label .. " drain: " .. start_error)
                return
            end
            set_output_stage(task, "await_input")
            return
        end
        local max_stack_quantity = task.group.max_stack_quantity or 1
        local stacks_needed = math.ceil(task.remaining_quantity / max_stack_quantity)
        if stacks_needed > available_stacks then
            stacks_needed = available_stacks
        elseif stacks_needed < 1 then
            stacks_needed = 1
        end
        if not safe_write(task.group.silo.ref_id, LT.Open, 1) then
            fail_output_task(task, "device_error", task.group.label .. " open")
            return
        end
        task.silo_watch_count = available_stacks - stacks_needed
        task.silo_closed = false
        set_output_stage(task, "await_input")
        return
    end

    if task.stage == "await_source" then
        local available_stacks, quantity_error = safe_read(task.group.silo.ref_id, LT.Quantity)
        if type(available_stacks) ~= "number" then
            fail_output_task(task, "device_error", task.group.label .. " quantity: " .. tostring(quantity_error))
            return
        end
        if available_stacks > 0 then
            set_output_stage(task, "dispense")
            return
        end
        local stacker_item, stacker_error = read_stacker_item(task.group.stacker.ref_id)
        if stacker_error then
            fail_output_task(task, "device_error", task.group.label .. " stacker: " .. stacker_error)
        elseif stacker_item then
            if stacker_item.prefab_hash ~= task.request.prefab_hash then
                fail_output_task(task, "inventory_mismatch", task.group.label .. " stacker contains wrong prefab")
                return
            end
            local started, start_error = start_group_drain(task, stacker_item)
            if not started then
                fail_output_task(task, "device_error", task.group.label .. " drain: " .. start_error)
                return
            end
            set_output_stage(task, "await_input")
        end
        return
    end

    if task.stage == "await_input" then
        if input_valve.releasing then
            release_valve(input_valve)
            return
        end
        if task.silo_watch_count ~= nil and not task.silo_closed then
            local current_stacks, watch_quantity_error = safe_read(task.group.silo.ref_id, LT.Quantity)
            if type(current_stacks) ~= "number" then
                fail_output_task(task, "device_error", task.group.label .. " quantity: " .. tostring(watch_quantity_error))
                return
            end
            if current_stacks <= task.silo_watch_count then
                if not safe_write(task.group.silo.ref_id, LT.Open, 0) then
                    fail_output_task(task, "device_error", task.group.label .. " close")
                    return
                end
                task.silo_closed = true
            end
        end
        local item, item_error = read_item(input_valve.ref_id)
        if item_error then
            fail_output_task(task, "device_error", NAME_OUTPUT_IN_VALVE .. ": " .. item_error)
        elseif item then
            if item.prefab_hash ~= task.request.prefab_hash then
                return
            end
            if not task.silo_closed then
                if not safe_write(task.group.silo.ref_id, LT.Open, 0) then
                    fail_output_task(task, "device_error", task.group.label .. " close")
                    return
                end
                task.silo_closed = true
            end
            if item.quantity > task.group.confirmed_quantity then
                fail_output_task(task, "ledger_invariant", task.group.label .. " output exceeds confirmed quantity")
                return
            end
            task.buffered_quantity = task.buffered_quantity + item.quantity
            if task.draining_group then
                task.drain_source_observed = true
            end
            task.group.confirmed_quantity = task.group.confirmed_quantity - item.quantity
            state.inventory_revision = state.inventory_revision + 1
            persist()
            release_valve(input_valve)
            set_output_stage(task, "dispense")
        end
        return
    end

    if task.stage == "await_output" then
        local item, item_error = read_item(output_valve.ref_id)
        if item_error then
            fail_output_task(task, "device_error", NAME_OUTPUT_OUT_VALVE .. ": " .. item_error)
        elseif item then
            if item.prefab_hash ~= task.request.prefab_hash or item.quantity ~= task.portion_quantity then
                fail_output_task(task, "inventory_mismatch", NAME_OUTPUT_OUT_VALVE .. " produced unexpected stack")
                return
            end
            if not safe_write(state.output_stacker.ref_id, LT.Output, -1) then
                fail_output_task(task, "device_error", NAME_OUTPUT_STACKER)
                return
            end
            if release_valve(output_valve, state.splitters.output, true) then
                set_output_stage(task, "await_delivery_clear")
            end
        end
        return
    end

    if task.stage == "await_delivery_clear" then
        release_valve(output_valve)
        if not output_valve.releasing then
            task.buffered_quantity = task.buffered_quantity - task.portion_quantity
            task.remaining_quantity = task.remaining_quantity - task.portion_quantity
            if task.remaining_quantity == 0 then
                if task.buffered_quantity == 0 then
                    complete_output_task(task)
                else
                    task.portion_quantity = task.buffered_quantity
                    if not command_stacker_output(task.portion_quantity) then
                        fail_output_task(task, "device_error", NAME_OUTPUT_STACKER)
                        return
                    end
                    set_output_stage(task, "await_return")
                end
            else
                set_output_stage(task, "dispense")
            end
        end
        return
    end

    if task.stage == "await_return" then
        local item, item_error = read_item(output_valve.ref_id)
        if item_error then
            fail_output_task(task, "device_error", NAME_OUTPUT_OUT_VALVE .. ": " .. item_error)
        elseif item then
            if item.prefab_hash ~= task.request.prefab_hash or item.quantity ~= task.portion_quantity then
                fail_output_task(task, "inventory_mismatch", NAME_OUTPUT_OUT_VALVE .. " return stack mismatch")
                return
            end
            if not safe_write(state.output_stacker.ref_id, LT.Output, -1) then
                fail_output_task(task, "device_error", NAME_OUTPUT_STACKER)
                return
            end
            if release_valve(output_valve, state.splitters.output, false) then
                set_output_stage(task, "await_return_clear")
            end
        end
        return
    end

    release_valve(output_valve)
    if not output_valve.releasing then
        complete_output_task(task)
    end
end

local function response_error(code)
    return { api_version = API_VERSION, ok = false, code = code }
end

transition = function(request, next_state, error_code)
    state.sequence = state.sequence + 1
    request.state = next_state
    request.error_code = error_code
    request.sequence = state.sequence
    request.updated_tick = now()
    publish("storage/v1/request/" .. request.request_id, request)
    print("StorageController: request " .. request.request_id .. " -> " .. next_state)
end

local function request_storage(payload, sender)
    if type(payload) == "table" then
        print("StorageController: incoming request from " .. tostring(sender) .. " for " .. tostring(payload.quantity) .. " of " .. item_name(payload.prefab_hash))
    else
        print("StorageController: incoming invalid request from " .. tostring(sender))
    end
    if type(payload) ~= "table" or payload.api_version ~= API_VERSION then
        return response_error("invalid_request")
    end
    if state.phase == "faulted" then
        return response_error("controller_faulted")
    end
    if state.phase ~= "ready" then
        return response_error("not_ready")
    end
    if type(payload.client_request_id) ~= "string" or type(payload.prefab_hash) ~= "number" or type(payload.quantity) ~= "number" or payload.quantity <= 0 or payload.quantity % 1 ~= 0 then
        return response_error("invalid_request")
    end
    local client_key = tostring(sender) .. ":" .. payload.client_request_id
    local existing_id = state.idempotency[client_key]
    if existing_id then
        print("StorageController: replayed request " .. existing_id)
        return { api_version = API_VERSION, ok = true, request_id = existing_id, state = state.requests[existing_id].state, replayed = true }
    end
    if #state.queue >= MAX_QUEUE_LENGTH then
        return response_error("queue_full")
    end
    local group = state.prefab_groups[payload.prefab_hash]
    if not group then
        return response_error("unknown_resource")
    end
    if not resolve_silo_stack_size(group) then
        return response_error("inventory_unknown")
    end
    if available(group) < payload.quantity then
        return response_error("insufficient_stock")
    end
    state.sequence = state.sequence + 1
    local request_id = string.format("storage-%d-%d", now(), state.sequence)
    local request = {
        request_id = request_id,
        client_key = client_key,
        owner = sender,
        prefab_hash = payload.prefab_hash,
        requested_quantity = payload.quantity,
        reserved_quantity = payload.quantity,
        delivered_quantity = 0,
        destination_id = payload.destination_id,
        group_id = group.id,
        state = "queued",
        sequence = state.sequence,
        created_tick = now(),
        updated_tick = now(),
    }
    group.reserved_quantity = group.reserved_quantity + payload.quantity
    state.requests[request_id] = request
    state.request_order[#state.request_order + 1] = request_id
    state.idempotency[client_key] = request_id
    state.queue[#state.queue + 1] = request_id
    persist()
    publish("storage/v1/request/" .. request_id, request)
    print("StorageController: queued request " .. request_id .. " for " .. tostring(payload.quantity) .. " of " .. item_name(payload.prefab_hash))
    return { api_version = API_VERSION, ok = true, request_id = request_id, state = "queued", reserved_quantity = payload.quantity }
end

local function request_status(payload, sender)
    if type(payload) ~= "table" or payload.api_version ~= API_VERSION or type(payload.request_id) ~= "string" then
        return response_error("invalid_request")
    end
    local request = state.requests[payload.request_id]
    if not request or request.owner ~= sender then
        return response_error("unknown_request")
    end
    return { api_version = API_VERSION, ok = true, request = request }
end

local function cancel_request(payload, sender)
    if type(payload) ~= "table" or payload.api_version ~= API_VERSION or type(payload.request_id) ~= "string" then
        return response_error("invalid_request")
    end
    local request = state.requests[payload.request_id]
    if not request or request.owner ~= sender then
        return response_error("unknown_request")
    end
    if request.state == "active" then
        return response_error("already_active")
    end
    if request.state ~= "queued" and request.state ~= "accepted" then
        return response_error("not_cancellable")
    end
    local group = state.groups[request.group_id]
    group.reserved_quantity = math.max(0, group.reserved_quantity - request.reserved_quantity)
    transition(request, "cancelled")
    persist()
    return { api_version = API_VERSION, ok = true, request_id = request.request_id, state = request.state }
end

local function get_state(payload)
    payload = payload or {}
    local groups = {}
    if payload.include_groups then
        for _, group in pairs(state.groups) do
            groups[#groups + 1] = {
                id = group.id,
                label = group.label,
                prefab_hash = group.assignment_prefab_hash,
                state = group.state,
                confirmed_quantity = group.confirmed_quantity,
                reserved_quantity = group.reserved_quantity,
                available_quantity = available(group),
                max_stack_quantity = group.max_stack_quantity,
                silo_stack_count = group.silo_stack_count,
                silo_scan_cursor = group.silo_memory_cursor,
                silo_scan_complete = group.scan_complete,
            }
        end
    end
    return {
        api_version = API_VERSION,
        schema_version = CONTROLLER_SCHEMA_VERSION,
        ok = true,
        phase = state.phase,
        ready = state.phase == "ready",
        fault = state.fault,
        errors = state.errors,
        state_revision = state.state_revision,
        inventory_revision = state.inventory_revision,
        queue_depth = #state.queue,
        active_request_id = state.active_request_id,
        groups = groups,
    }
end

local function get_config()
    return {
        api_version = API_VERSION,
        ok = true,
        group_stacker_setting = GROUP_STACKER_SETTING,
        valve_item_limit = VALVE_ITEM_LIMIT,
        max_queue_length = MAX_QUEUE_LENGTH,
    }
end

local function trim_history()
    while #state.request_order > MAX_REQUEST_HISTORY do
        local request_id = table.remove(state.request_order, 1)
        local request = state.requests[request_id]
        if request and request.state ~= "queued" and request.state ~= "active" then
            state.requests[request_id] = nil
            state.idempotency[request.client_key] = nil
        else
            state.request_order[#state.request_order + 1] = request_id
            break
        end
    end
end

local function register_api()
    ic.net.register("storage.request", request_storage)
    ic.net.register("storage.request_status", request_status)
    ic.net.register("storage.cancel", cancel_request)
    ic.net.register("storage.get_state", get_state)
    ic.net.register("storage.get_config", get_config)
end

local function log_inventory_summary()
    local total_quantity = 0
    for id = 0, state.group_count - 1 do
        local group = state.groups[id]
        if group and group.assignment_prefab_hash then
            print("StorageController: " .. group.label .. " holds " .. tostring(group.confirmed_quantity) .. " units of " .. item_name(group.assignment_prefab_hash))
            total_quantity = total_quantity + group.confirmed_quantity
        end
    end
    print("StorageController: startup inventory total " .. tostring(total_quantity) .. " units across " .. tostring(state.group_count) .. " groups")
end

local function initialize()
    print("StorageController: booting")
    register_api()
    restore_persistence()
    set_phase("discovering")
    local topology_errors
    local best_group_count = -1
    local stable_signature
    local stable_scans = 0
    for attempt = 1, MAX_DISCOVERY_ATTEMPTS do
        local discovered
        discovered, topology_errors = discover_topology()
        if discovered then
            local signature = topology_signature()
            if state.group_count > best_group_count then
                best_group_count = state.group_count
                stable_signature = signature
                stable_scans = 1
            elseif state.group_count == best_group_count and signature == stable_signature then
                stable_scans = stable_scans + 1
            elseif state.group_count == best_group_count then
                stable_signature = signature
                stable_scans = 1
            else
                stable_scans = 0
                topology_errors = { "topology_regressed: expected at least " .. tostring(best_group_count) .. " groups, observed " .. tostring(state.group_count) }
                discovered = false
            end
            if discovered then
                print("StorageController: topology confirmation " .. tostring(stable_scans) .. "/" .. tostring(DISCOVERY_STABLE_SCANS) .. " with " .. tostring(state.group_count) .. " groups")
                if stable_scans >= DISCOVERY_STABLE_SCANS then
                    break
                end
                discovered = false
                topology_errors = { "topology_not_stable: waiting for matching device snapshots" }
            end
        else
            stable_scans = 0
        end
        topology_errors = topology_errors or { "topology_scan_failed: no diagnostic returned" }
        print("StorageController: topology scan " .. tostring(attempt) .. "/" .. tostring(MAX_DISCOVERY_ATTEMPTS) .. " incomplete: " .. table.concat(topology_errors, "; "))
        if attempt == MAX_DISCOVERY_ATTEMPTS then
            add_error("topology_not_stable", table.concat(topology_errors, "; "))
        end
        yield()
    end
    if not configure_devices() then
        set_phase("invalid_topology")
        return
    end
    set_phase("recovering")
    if not recover_assignments() or not baseline_inventory() then
        set_phase("invalid_topology")
        return
    end
    if not clear_unassigned_groups() then
        set_phase("invalid_topology")
        return
    end
    log_inventory_summary()
    persist()
    set_phase("ready")
end

initialize()

while true do
    state.tick = state.tick + 1
    if state.phase == "ready" then
        local still_draining = false
        for _, group in pairs(state.groups) do
            if group.state == "draining_mismatch" then
                local silo_stacks = safe_read(group.silo.ref_id, LT.Quantity)
                local stacker_item = read_stacker_item(group.stacker.ref_id)
                if type(silo_stacks) == "number" and silo_stacks == 0 and not stacker_item then
                    print("StorageController: " .. group.label .. " finished draining mismatched resources")
                    group.state = "unassigned"
                    group.confirmed_quantity = 0
                    group.pending_quantity = 0
                    group.max_stack_quantity = nil
                    group.silo_stack_count = 0
                    group.silo_memory_cursor = 0
                    group.silo_memory_words = {}
                    group.scan_complete = true
                    group.clearing_stacker = false
                    group.clearing_tick = 0
                    safe_write(group.silo.ref_id, LT.Open, 0)
                else
                    if type(silo_stacks) == "number" and silo_stacks == 0 and stacker_item then
                        if not group.clearing_stacker then
                            group.clearing_stacker = true
                            group.clearing_tick = now()
                            print("StorageController: " .. group.label .. " silo empty, closing to return stacker item to input")
                            safe_write(group.silo.ref_id, LT.Open, 0)
                        elseif now() - group.clearing_tick >= 3 then
                            print("StorageController: " .. group.label .. " activating stacker to clear item")
                            if not safe_write(group.stacker.ref_id, LT.Activate, 1) then
                                add_error("stacker_activation_failed", group.label)
                            end
                            group.clearing_stacker = false
                            safe_write(group.silo.ref_id, LT.Open, 0)
                        end
                    end
                    still_draining = true
                end
            end
            if group.state == "inventory_unknown" then
                local silo_stacks = safe_read(group.silo.ref_id, LT.Quantity)
                local stacker_item, stacker_error = read_stacker_item(group.stacker.ref_id)
                if type(silo_stacks) == "number" and silo_stacks == 0 and not stacker_item and not stacker_error then
                    print("StorageController: " .. group.label .. " resolved inventory_unknown state")
                    group.state = "unassigned"
                    group.confirmed_quantity = 0
                    group.pending_quantity = 0
                    group.max_stack_quantity = nil
                    group.silo_stack_count = 0
                    group.silo_memory_cursor = 0
                    group.silo_memory_words = {}
                    group.scan_complete = true
                    group.clearing_stacker = false
                    group.clearing_tick = 0
                    safe_write(group.silo.ref_id, LT.Open, 0)
                else
                    if type(silo_stacks) == "number" and silo_stacks == 0 and stacker_item and not stacker_error then
                        if not group.clearing_stacker then
                            group.clearing_stacker = true
                            group.clearing_tick = now()
                            print("StorageController: " .. group.label .. " silo empty, closing to return stacker item to input")
                            safe_write(group.silo.ref_id, LT.Open, 0)
                        elseif now() - group.clearing_tick >= 3 then
                            print("StorageController: " .. group.label .. " activating stacker to clear item")
                            if not safe_write(group.stacker.ref_id, LT.Activate, 1) then
                                add_error("stacker_activation_failed", group.label)
                            end
                            group.clearing_stacker = false
                            safe_write(group.silo.ref_id, LT.Open, 0)
                        end
                    end
                    still_draining = true
                end
            end
            if group.state == "unassigned" then
                local silo_stacks = safe_read(group.silo.ref_id, LT.Quantity)
                if type(silo_stacks) == "number" and silo_stacks > 0 then
                    print("StorageController: " .. group.label .. " has " .. tostring(silo_stacks) .. " unassigned silo stacks; draining")
                    if not safe_write(group.silo.ref_id, LT.Open, 1) then
                        add_error("silo_open_failed", group.label)
                    else
                        still_draining = true
                    end
                else
                    local stacker_item, stacker_error = read_stacker_item(group.stacker.ref_id)
                    if stacker_error then
                        add_error("stacker_read_failed", group.label .. ": " .. stacker_error)
                    elseif stacker_item then
                        if not group.clearing_stacker then
                            group.clearing_stacker = true
                            group.clearing_tick = now()
                            print("StorageController: " .. group.label .. " has unassigned item " .. item_name(stacker_item.prefab_hash) .. " in stacker; closing silo to return to input")
                            safe_write(group.silo.ref_id, LT.Open, 0)
                            still_draining = true
                        elseif now() - group.clearing_tick >= 3 then
                            print("StorageController: " .. group.label .. " activating stacker to clear item")
                            if not safe_write(group.stacker.ref_id, LT.Activate, 1) then
                                add_error("stacker_activation_failed", group.label)
                            end
                            group.clearing_stacker = false
                            safe_write(group.silo.ref_id, LT.Open, 0)
                        else
                            still_draining = true
                        end
                    else
                        group.clearing_stacker = false
                    end
                end
            end
        end
        service_input()
        service_fail()
        service_output_return()
        service_output()
        if state.output_task == nil and #state.queue == 0 and not still_draining then
            scan_silo_memory()
        end
        trim_history()
    end
    yield()
end
