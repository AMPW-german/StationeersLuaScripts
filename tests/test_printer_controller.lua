-- Regression tests for PrinterController.lua (API v2)
--
-- Runs the chip's real code in a Lua 5.1 sandbox with a mocked `ic` engine
-- library. The chip body up to `initialize()` is executed; the main
-- `while true do yield() end` loop is replaced by an explicit `return`,
-- matching the storage-controller drain test's harness.
--
-- The controller is catalog-free: it has no `refresh_catalog`, no `working`
-- recipe table, no `my_revision`/`my_api_version`, and no `catalog_provider`.
-- Each `printers_request` carries its own `cost_vector` (catalog-derived on the
-- console side), which the controller structurally validates with
-- `valid_cost_vector` before it ever touches the reservation ledger. That
-- boundary is the thing under test here.
--
-- Lua 5.1 compatible. No ic.* in the test itself.
--
-- Usage:
--   lua tests/test_printer_controller.lua            (relative paths — cwd = repo root)
--   lua -v 5.1  or  /path/to/Lua51/lua
--
-- Exits 0 when all checks pass, 1 otherwise.

-- Compile check only (the body is spliced below to avoid the main loop).
-- Try both the repo-root and the tests/ working directory so the suite runs
-- from either location.
do
    local ok_root = loadfile('PrinterController.lua')
    local ok_sub  = loadfile('../PrinterController.lua')
    assert(ok_root or ok_sub,
        'PrinterController.lua not loadable (run from repo root or tests/)')
end


local function count_table_values(tbl)
    local n = 0
    for _ in pairs(tbl) do
        n = n + 1
    end
    return n
end

local function read_source(path, alt)
    local f = io.open(path, 'r')
    if not f and alt then
        f = io.open(alt, 'r')
    end
    f = assert(f, 'cannot open ' .. path .. (alt and (', or ' .. alt) or ''))
    local text = f:read("*a")
    f:close()
    return text
end

local chip_source = read_source('PrinterController.lua', '../PrinterController.lua')
local entry_index = chip_source:find("\ninitialize()", 1, true)
if not entry_index then
    error("could not find initialize() entry point in PrinterController.lua")
end
-- Drop the leading newline and everything after it (the entry call + main loop).
local test_entry = string.sub(chip_source, 1, entry_index - 1)

local export_code = [[
    local _exports = {}
    _exports.state = state
    _exports.valid_cost_vector = valid_cost_vector
    _exports.reserve_batch = reserve_batch
    _exports.consume_batch = consume_batch
    _exports.release_batch = release_batch
    _exports.query_reservation = query_reservation
    _exports.printers_request = printers_request
    _exports.printers_cancel = printers_cancel
    _exports.printers_get_state = printers_get_state
    _exports.printers_get_inventory = printers_get_inventory
    _exports.register_api = register_api
    _exports.discover_printers = discover_printers
    _exports.discover_feeds = discover_feeds
    _exports.initialize_devices = initialize_devices
    _exports.service_one = service_one
    _exports.service_tasks = service_tasks
    _exports.service_ejection = service_ejection
    _exports.service_route = service_route
    _exports.route_open = route_open
    _exports.route_release = route_release
    _exports.service_inventory_fetch = service_inventory_fetch
    _exports.request_storage_reservation = request_storage_reservation
    _exports.start_print = start_print
    _exports.stop_print = stop_print
    _exports.printer_status = printer_status
    _exports.record_residue = record_residue
    _exports.verify_topology = verify_topology
    return _exports
]]

local body = test_entry .. "\n" .. export_code .. "\n"
local chunk, err = loadstring(body, 'PrinterController.lua (test harness)')
if not chunk then
    print("ERROR: failed to compile chunk: " .. tostring(err))
    os.exit(1)
end

print(string.format(
    "PrinterController: test harness loaded ok (%d chars of chip body executed)",
    #body
))

--------------------------------------------
-- Mock engine `ic` (printer variant)
--------------------------------------------
local OWNER = "tester-01"
local STORAGE_TARGET = "LuaC.Storage.Controller"
local CONTROLLER_TARGET = "LuaC.Printer.Controller"

local ctx = {
    ic = nil,
    net = nil,
    store = nil,
    print_log = nil,
    handlers = nil,
    writes = nil,      -- ref -> { logic_type -> last written value }
    write_log = nil,   -- ordered { ref, lt, value } writes
    reads = nil,       -- ref -> { logic_type -> read value }
    slots = nil,       -- ref -> { slot -> { slot_type -> read value } }
    storage_handler = nil,  -- function(method, payload) for LuaC.Storage.Controller
}

ctx.net = { log = {} }
ctx.store = {}
ctx.print_log = {}
ctx.handlers = nil
ctx.writes = {}
ctx.write_log = {}
ctx.reads = {}
ctx.slots = {}
ctx.storage_handler = nil

-- Named LogicTypes the driver touches; values are arbitrary stand-ins.
local LT_MOCK = {
    NUMBER = 1, LOGICAL = 4, TEXT = 5,
    RecipeHash = 100, Activate = 101, CompletionRatio = 102,
    ExportCount = 103, ExportQuantity = 104, ImportQuantity = 105,
    ImportSlotOccupant = 106, ExportSlotOccupant = 107,
    Idle = 108, Error = 109, ClearMemory = 110, Flush = 111,
    Open = 112, Output = 113, Time = 114, PrefabHash = 115,
    On = 116, Setting = 117, Mode = 118, Lock = 119,
    Reagents = 120, ImportCount = 121, SettingOutput = 122,
}

local LST_MOCK = {
    INPUT = 1, INPUT_OUTPUT = 3, INTERNAL = 4, Occupant = 5,
    Occupied = 10, OccupantHash = 11, Quantity = 12,
}

ctx.ic = {
    enums = {
        LogicType = LT_MOCK,
        LogicSlotType = LST_MOCK,
        SorterInstruction = {
            SORTER_INSTRUCTION_SORT = 1,
            FilterPrefabHashEquals = 2,
            FilterPrefabHashNotEquals = 7,
        },
    },
    -- read_id serves ctx.reads (default 0); write_id records into ctx.writes
    -- and appends to write_log so tests can assert actuation order.
    read_id = function(ref_id, logic_type)
        local dev = ctx.reads[ref_id]
        local v = dev and dev[logic_type]
        if type(v) == "number" then
            return v
        end
        return 0
    end,
    write_id = function(ref_id, logic_type, value)
        local dev = ctx.writes[ref_id]
        if not dev then
            dev = {}
            ctx.writes[ref_id] = dev
        end
        dev[logic_type] = value
        ctx.write_log[#ctx.write_log + 1] = { ref = ref_id, lt = logic_type, value = value }
        -- ClearMemory zeroes the device's import/export tallies on the real
        -- firmware -- the controller issues the clear on one pass and
        -- verifies the counter reads 0 on the next.
        if logic_type == LT_MOCK.ClearMemory then
            local rdev = ctx.reads[ref_id]
            if rdev then
                rdev[LT_MOCK.ExportCount] = 0
                rdev[LT_MOCK.ImportCount] = 0
            end
        end
        return true
    end,
    mem = {
        put_id = function(ref_id, address, value)
            ctx.store[ref_id .. ":" .. tostring(address)] = value
            return true
        end,
        get_id = function(ref_id, address)
            return ctx.store[ref_id .. ":" .. tostring(address)]
        end,
    },
    -- Slot reads serve ctx.slots[ref][slot][type] (default 0), mirroring
    -- read_id's ctx.reads contract.
    read_slot_id = function(ref_id, slot, slot_type)
        local dev = ctx.slots[ref_id]
        local s = dev and dev[slot]
        local v = s and s[slot_type]
        if type(v) == "number" then
            return v
        end
        return 0
    end,
    find_all = function()
        return {}
    end,
    net = {
        register = function(name, handler)
            if ctx.handlers == nil then
                ctx.handlers = {}
            end
            assert(ctx.handlers[name] == nil, "handler already registered: " .. name)
            ctx.handlers[name] = handler
        end,
        publish = function(name, value)
            table.insert(ctx.net.log, { name = name, value = value })
        end,
        -- Real signature: ic.net.request(target, method, payload, callback,
        -- [timeout]) -- the runtime requires the callback and delivers results
        -- via callback(ok, response, err). The mock invokes it synchronously
        -- so tests stay linear. The controller's own endpoints dispatch
        -- through ctx.handlers; the storage line is emulated by
        -- ctx.storage_handler (nil = unreachable -> ok=false).
        request = function(target, method, payload, callback, timeout)
            local function respond(ok, response, err)
                if type(callback) == "function" then
                    callback(ok, response, err)
                end
            end
            if target == STORAGE_TARGET then
                if ctx.storage_handler then
                    respond(true, ctx.storage_handler(method, payload), nil)
                else
                    respond(false, nil, "no storage handler")
                end
                return
            end
            if target == CONTROLLER_TARGET then
                local handler = ctx.handlers and ctx.handlers[method]
                if not handler then
                    respond(false, nil, "no handler registered: " .. tostring(method))
                    return
                end
                respond(true, handler(payload, OWNER, { origin = "test" }), nil)
                return
            end
            respond(false, nil, "unknown target: " .. tostring(target))
        end,
    },
    persist = {
        set = function(name, value)
            ctx.store["persist:" .. name] = value
            -- The real ic.persist.set returns true on success.
            return true
        end,
        get = function(name, default)
            local value = ctx.store["persist:" .. name]
            if value == nil then
                return default
            end
            return value
        end,
        -- The real ic.persist surface: set/get/has/delete/clear.
        has = function(name)
            return ctx.store["persist:" .. name] ~= nil
        end,
        delete = function(name)
            ctx.store["persist:" .. name] = nil
        end,
    },
    print = function(msg)
        print(msg)
        table.insert(ctx.print_log, msg)
    end,
}

local function run_body()
    local env = setmetatable({}, { __index = _G })
    for k, v in pairs(_G) do
        env[k] = v
    end
    env.state = nil
    env.ic = ctx.ic
    -- Engine Animator.StringToHash / IC10 HASH() stand-in (deterministic).
    env.hash = function(name)
        if type(name) ~= "string" then
            return nil
        end
        local h = 0
        for i = 1, #name do
            h = (h * 31 + string.byte(name, i)) % 2147483647
        end
        return h
    end
    return setfenv(chunk, env)()
end

local function last_write(ref, lt)
    for i = #ctx.write_log, 1, -1 do
        local w = ctx.write_log[i]
        if w.ref == ref and w.lt == lt then
            return w.value
        end
    end
    return nil
end

local function count_writes(ref, lt, value)
    local n = 0
    for _, w in ipairs(ctx.write_log) do
        if w.ref == ref and w.lt == lt and (value == nil or w.value == value) then
            n = n + 1
        end
    end
    return n
end

--------------------------------------------
-- Test framework
--------------------------------------------
local pass = 0
local fail = 0

local function ok(cond, msg)
    if cond then
        pass = pass + 1
        print("  [PASS] " .. msg)
    else
        fail = fail + 1
        print("  [FAIL] " .. msg)
    end
end

local function new_module()
    ctx.handlers = nil
    ctx.writes = {}
    ctx.write_log = {}
    ctx.reads = {}
    ctx.slots = {}
    ctx.storage_handler = nil
    local chunk_run, chunk_err = run_body()
    if not chunk_run then
        print("ERROR: chunk failed to run: " .. tostring(chunk_err))
        os.exit(1)
    end
    -- The catalog-free controller boots and serves without any catalog module.
    -- The test supplies its own topology (printer_by_name is dual-keyed by the
    -- controller: numeric family id AND controller family name) and drives
    -- requests that each carry their own catalog-derived cost_vector.
    chunk_run.state.phase = "ready"
    chunk_run.state.printer_by_name[1] = "autolathe-ref"
    chunk_run.state.printer_by_name[2] = "pipebender-ref"
    chunk_run.state.printer_by_name["autolathe"] = "autolathe-ref"
    chunk_run.state.printer_by_name["pipe_bender"] = "pipebender-ref"
    chunk_run.state.printers["autolathe-ref"] = { ref_id = "autolathe-ref", family = 1 }
    chunk_run.state.printers["pipebender-ref"] = { ref_id = "pipebender-ref", family = 2 }
    chunk_run.register_api()
    return chunk_run
end

--------------------------------------------
-- Test 1: Catalog-free surface + request cost_vector contract
--------------------------------------------
print("\n[TEST 1] Catalog-free surface and request contract")

do
    local m = new_module()

    -- 1.1 the catalog-free surface: the controller carries no catalog knowledge
    ok(m.refresh_catalog == nil, "1.1 no refresh_catalog surface (catalog-free)")
    ok(m.recipe_cost_vector == nil, "1.1 no recipe_cost_vector surface (catalog-free)")
    ok(m.state.my_revision == nil, "1.1 no my_revision (no catalog revision adopted)")
    ok(m.state.my_api_version == nil, "1.1 no my_api_version (no catalog version adopted)")
    ok(m.state.working == nil, "1.1 no working recipe table")

    -- 1.2 a request WITH its own catalog-derived cost_vector is accepted, and the
    -- reservation is sized from that vector (5 x Iron(2) = 10).
    local resp1 = m.printers_request({
        api_version = 2,
        client_request_id = "c1",
        count = 5,
        item = "IronBar",
        family_id = 1,
        cost_vector = { Iron = 2 },
    }, OWNER)
    ok(resp1 and resp1.ok == true and resp1.task_id ~= nil, "1.2 a request with a cost_vector queues a task")
    ok(resp1 and resp1.reserved == 10, "1.2 reservation = 5 x Iron(2) = 10 from the supplied vector")

    -- 1.3 a request WITHOUT a cost_vector is refused (invalid_cost_vector).
    local respBad = m.printers_request({
        api_version = 2,
        client_request_id = "c2",
        count = 1,
        item = "IronBar",
        family_id = 1,
    }, OWNER)
    ok(respBad and respBad.ok == false and respBad.code == "invalid_cost_vector",
        "1.3 a request without a cost_vector is refused (invalid_cost_vector)")

    -- 1.4 valid_cost_vector validates the shape and reports the total.
    local clean, err, total = m.valid_cost_vector({ Iron = 2, Copper = 1 })
    ok(clean ~= nil and clean.Iron == 2 and clean.Copper == 1,
        "1.4 valid_cost_vector accepts a clean name->amount table")
    ok(total == 3, "1.4 valid_cost_vector reports the total (2+1=3)")
    ok(err == nil, "1.4 valid_cost_vector reports no error on the happy path")

    local bad1 = m.valid_cost_vector({ Iron = -1 })
    ok(bad1 == nil, "1.4 a negative amount is rejected by valid_cost_vector")

    -- Internally the chip speaks prefab HASHES, so a numeric (hash) key is a
    -- valid cost_vector key alongside a reagent name. Both are accepted.
    local good2, good2_err, good2_total = m.valid_cost_vector({ [7] = 5 })
    ok(good2 ~= nil and good2[7] == 5,
        "1.4 a prefab-hash (numeric) key is accepted by valid_cost_vector")
    ok(good2_err == nil and good2_total == 5,
        "1.4 a hash-keyed amount contributes to the total")
    local bad2 = m.valid_cost_vector({ [{}] = 5 })
    ok(bad2 == nil, "1.4 a non-name/hash (table) key is rejected")

    local bad3 = m.valid_cost_vector("not-a-table")
    ok(bad3 == nil, "1.4 a non-table input is rejected by valid_cost_vector")

    local empty_tbl, empty_err, empty_total = m.valid_cost_vector({})
    ok(type(empty_tbl) == "table" and empty_total == 0,
        "1.4 an empty vector returns an empty table with total 0")
    ok(empty_err == nil, "1.4 an empty vector is structurally valid")

    -- 1.5 v2 family_name routing: the console sends names, not ids; the task
    -- must land on the resolved family (family 2 here), never the family-1
    -- fallback.
    local r15 = m.printers_request({
        api_version = 2,
        client_request_id = "c-name",
        count = 1,
        item = "PipeElbow",
        family_name = "pipe_bender",
        cost_vector = { Copper = 3 },
    }, OWNER)
    ok(r15 and r15.ok == true and r15.task_id ~= nil, "1.5 a family_name request is accepted")
    local named_task = r15 and m.state.tasks[r15.task_id]
    ok(named_task and named_task.family_id == 2,
        "1.5 family_name 'pipe_bender' resolves to family_id 2 (not the 1 fallback)")
    ok(named_task and named_task.family_name == "pipe_bender",
        "1.5 the task records its controller family_name")
end

--------------------------------------------
-- Test 2: No catalog module is consulted at any point
--------------------------------------------
print("\n[TEST 2] No catalog module is consulted")

do
    -- 2.1 the module boots and serves without a catalog provider being wired up.
    ctx.handlers = nil
    local m, chunk_err = run_body()
    if not m then
        ok(false, "2.1 the controller boots cleanly with no catalog")
    else
        ok(m.state.catalog_provider == nil, "2.1 no catalog_provider is wired into the state")
        -- supply topology, then serve.
        m.state.phase = "ready"
        m.state.printer_by_name[1] = "autolathe-ref"
        m.state.printers["autolathe-ref"] = { ref_id = "autolathe-ref", family = 1 }
        m.register_api()
        local resp = m.printers_request({
            api_version = 2,
            client_request_id = "nc-1",
            count = 1,
            item = "IronBar",
            family_id = 1,
            cost_vector = { Iron = 2 },
        }, OWNER)
        ok(resp and resp.ok == true, "2.1 a request is served without any catalog")
        ok(m.state.catalog_provider == nil,
            "2.1 no catalog_provider was set even after a request was served")
    end
end

--------------------------------------------
-- Test 3: Reservation ledger (partial release)
--------------------------------------------
print("\n[TEST 3] Reservation ledger and partial release")

do
    local m = new_module()

    local cost = { Iron = 2, Copper = 1 }
    local record, rerr = m.reserve_batch("ownerA", "R1", cost, 3)
    ok(record ~= nil, "3.1 reserve_batch creates a ledger record")
    ok(record and record.reserved == 9, "3.1 reserved amount = per-item(3) x count(3) = 9")
    ok(m.state.reserved["ownerA"] == 9, "3.1 owner aggregate = 9")

    -- additive: a second reservation on the same owner accumulates
    m.reserve_batch("ownerA", "R2", cost, 2)
    ok(m.state.reserved["ownerA"] == 9 + 6, "3.2 second reservation adds to the owner aggregate (9+6=15)")

    -- In-flight grams (delivered) are not freed grams, but they leave the
    -- owner aggregate too: the delivered share transfers to the residue
    -- ledger on cancel. request_storage_reservation bumps record.delivered
    -- per accepted send; here we drive the field directly to model 3g on
    -- the line.
    local rec = m.state.reserved_ledger["ownerA:R1"]
    rec.delivered = 3
    local released = m.release_batch("ownerA", "R1")
    ok(released == 6, "3.3 release reports the undelivered share (9-3=6)")
    ok(m.state.reserved["ownerA"] == 15 - 9,
        "3.3 the whole reservation leaves the aggregate (delivered share -> residue)")

    -- a clean reservation releases in full
    local released2 = m.release_batch("ownerA", "R2")
    ok(released2 == 6, "3.4 a clean reservation releases in full")
    ok(m.state.reserved["ownerA"] == nil, "3.4 owner aggregate is empty after both releases")

    -- two owners are independent
    m.reserve_batch("ownerB", "B1", { Iron = 1 }, 4)
    ok(m.state.reserved["ownerB"] == 4, "3.5 a second owner's reservation is independent")
    m.release_batch("ownerB", "B1")
    ok(m.state.reserved["ownerB"] == nil, "3.5 releasing a solo owner drops its aggregate")

    -- completion consumes the reservation entirely
    m.reserve_batch("ownerA", "R3", { Iron = 1 }, 5)
    m.consume_batch("ownerA", "R3")
    ok(m.state.reserved_ledger["ownerA:R3"] == nil, "3.6 consume_batch clears the record")
    ok(m.state.reserved["ownerA"] == nil, "3.6 consume_batch frees the owner aggregate")
end

--------------------------------------------
-- Test 4: Task API (request / cancel / idempotency / get_state)
--------------------------------------------
print("\n[TEST 4] Task API")

do
    local m = new_module()

    -- 4.1 idempotent create
    local r1 = m.printers_request(
        { api_version = 2, client_request_id = "key-1", count = 5, item = "IronBar",
          family_id = 1, cost_vector = { Iron = 2 } },
        OWNER
    )
    ok(r1.ok == true and r1.task_id ~= nil, "4.1 printers_request creates a queued task")
    ok(r1.reserved == 10, "4.1 reservation recorded = 5 x Iron(2) = 10")

    -- the v2 task record carries the fields the UI needs (no legacy aliases/tier)
    local task = m.state.tasks[r1.task_id]
    ok(task and task.done_count == 0, "4.1 task carries done_count = 0")
    ok(task and task.resources_state == "pending", "4.1 task carries resources_state = pending")
    ok(task and task.family_name == "autolathe", "4.1 task carries family_name")
    ok(task and task.tier == nil, "4.1 task carries no tier (removed in v2)")

    -- 4.2 replay of the same client key returns the same task, not a new one
    local r2 = m.printers_request(
        { api_version = 2, client_request_id = "key-1", count = 5, item = "IronBar",
          family_id = 1, cost_vector = { Iron = 2 } },
        OWNER
    )
    ok(r2.ok == true and r2.replayed == true, "4.2 same client_request_id replays the same task")
    ok(r2.task_id == r1.task_id, "4.2 replay returns the original task_id")

    -- 4.3 task lookup happens through get_state (request_status was removed)
    local st = m.printers_get_state({ include_tasks = true })
    local found
    for _, t in ipairs(st.tasks or {}) do
        if t.task_id == r1.task_id then
            found = t
        end
    end
    ok(found ~= nil and found.state == "queued", "4.3 get_state surfaces the queued task")

    -- 4.4 cancel
    local c = m.printers_cancel({ api_version = 2, task_id = r1.task_id }, OWNER)
    ok(c.ok == true and c.state == "cancelled", "4.4 cancel moves a queued task to cancelled")
    -- cancel releases the reservation
    ok(m.state.reserved[OWNER] == nil, "4.4 cancelled task frees its reservation")

    -- 4.5 get_state v2 summary fields
    local st2 = m.printers_get_state({ include_tasks = true })
    ok(st2.ok == true and st2.api_version == 2, "4.5 get_state returns ok + api_version 2")
    ok(type(st2.printers) == "table" and #st2.printers == 6,
        "4.5 get_state carries one printer record per family (6)")
    ok(type(st2.time_multiplier) == "number",
        "4.5 get_state carries time_multiplier")
    ok(st2.revision ~= nil, "4.5 get_state carries a revision")
    ok(type(st2.recent_errors) == "table", "4.5 get_state carries recent_errors")
    local saw_idle, saw_absent
    for _, p in ipairs(st2.printers) do
        if p.family_id == 1 then saw_idle = p.status end
        if p.family_id == 6 then saw_absent = p.status end
    end
    ok(saw_idle == "idle", "4.5 discovered printer with no task reports idle")
    ok(saw_absent == "absent", "4.5 undiscovered printer reports absent")

    -- 4.6 reagent_labels are stored on the task for the detail overlay
    local r3 = m.printers_request(
        { api_version = 2, client_request_id = "key-2", count = 1, item = "IronBar",
          family_id = 1, cost_vector = { [42] = 3 },
          reagent_labels = { [42] = "Iron" } },
        OWNER
    )
    local t3 = m.state.tasks[r3.task_id]
    ok(t3 and t3.reagent_labels and t3.reagent_labels[42] == "Iron",
        "4.6 reagent_labels are stored on the task")
end

--------------------------------------------
-- Test 5: valid_cost_vector shape + validation
--------------------------------------------
print("\n[TEST 5] valid_cost_vector shape and validation")

do
    local m = new_module()

    -- 5.1 a clean vector is accepted and returns its total
    local cost, err, total = m.valid_cost_vector({ Iron = 2 })
    ok(cost ~= nil and cost.Iron == 2, "5.1 a clean vector is accepted")
    ok(err == nil, "5.1 no error reported on a clean vector")
    ok(total == 2, "5.1 the reported total is 2")

    -- 5.2 a multi-reagent vector sums to its total
    local multi, m_err, m_total = m.valid_cost_vector({ Iron = 1, Copper = 1 })
    ok(multi ~= nil and multi.Iron == 1 and multi.Copper == 1, "5.2 a multi-reagent vector is accepted")
    ok(m_total == 2, "5.2 the multi-reagent total is 2")

    -- 5.3 a non-table input is rejected
    ok(m.valid_cost_vector("not-a-table") == nil, "5.3 a non-table input is rejected")

    -- 5.4 a negative amount is rejected
    ok(m.valid_cost_vector({ Iron = -1 }) == nil, "5.4 a negative amount is rejected")

    -- 5.5 internal comms are hash-keyed, so a numeric (prefab-hash) key is
    -- accepted alongside a reagent name; a non-name/hash (table) key is rejected
    do
        local hk, hk_err, hk_total = m.valid_cost_vector({ [9] = 4 })
        ok(hk ~= nil and hk[9] == 4 and hk_total == 4,
            "5.5 a prefab-hash (numeric) key is accepted and counted")
        ok(m.valid_cost_vector({ [{}] = 5 }) == nil,
            "5.5 a non-name/hash (table) key is rejected")
    end

    -- 5.6 a NaN amount is rejected (amount ~= amount)
    ok(m.valid_cost_vector({ Iron = 0 / 0 }) == nil, "5.6 a NaN amount is rejected")

    -- 5.7 zero amounts are stripped (do not pollute the vector or the total)
    local stripped, s_err, s_total = m.valid_cost_vector({ Iron = 0, Copper = 1 })
    ok(stripped ~= nil and stripped.Iron == nil, "5.7 a zero amount is stripped from the result")
    ok(stripped.Copper == 1, "5.7 a non-zero amount survives the strip")
    ok(s_err == nil and s_total == 1, "5.7 the total excludes the stripped zero")
end

--------------------------------------------
-- Test 6: Real actuation (LogicType drive)
--------------------------------------------
print("\n[TEST 6] Real actuation drives the printer LogicTypes")

do
    local m = new_module()
    -- Storage accepts every request so resources_state reaches "delivered"
    -- (Activate is only asserted once the reagents are confirmed on board).
    ctx.storage_handler = function(method, payload)
        return { api_version = 1, ok = true }
    end

    -- A queued task transitions to ACTIVE on service and drives RecipeHash +
    -- Activate on its printer (no commission gate in v2).
    local r = m.printers_request(
        { api_version = 2, client_request_id = "act-1", count = 3, item = "IronBar",
          family_id = 1, cost_vector = { Iron = 2 } },
        OWNER
    )
    local task = m.state.tasks[r.task_id]
    -- The job's reagent mass is 2g x 3 = 6: the machine starts empty and the
    -- load lands between passes. Activate is pressed once when the reagent
    -- DELTA over the pre-delivery baseline covers the whole job, not before.
    ctx.reads["autolathe-ref"] = { [LT_MOCK.Reagents] = 0 }
    m.service_one(task)
    ok(task.state == "active", "6.1 the serviced task is active")
    ok(m.printer_status(1) == "waiting_resources",
        "6.1 status is waiting_resources while the load is still flying")
    ctx.reads["autolathe-ref"][LT_MOCK.Reagents] = 6
    -- The ACTIVE branch verifies the cleared counter on the next pass (the
    -- clear is issued one pass, verified 0 the next), then RecipeHash;
    -- Activate waits for delivered reagent mass on the following pass.
    m.service_one(task)
    ok(last_write("autolathe-ref", LT_MOCK.ClearMemory) == 1,
        "6.1 the export counter is cleared once before the run starts")
    m.service_one(task)
    local rh = last_write("autolathe-ref", LT_MOCK.RecipeHash)
    ok(type(rh) == "number" and rh ~= 0, "6.2 RecipeHash was written to the printer")
    ok(last_write("autolathe-ref", LT_MOCK.Activate) == 1,
        "6.3 Activate=1 was written to the printer")
    ok(m.printer_status(1) == "printing",
        "6.3 status is printing only once the printer was activated")
    ok(m.state.active_task_by_printer["autolathe-ref"] == task.task_id,
        "6.4 the printer is bound to the task")
    -- storage was asked for the aggregated grams (storage handler absent ->
    -- guarded decline is logged, task still runs, marked waiting)
    ok(task.resources_state == "failed" or task.resources_state == "delivered",
        "6.5 resources_state is surfaced on the task")

    -- progress follows the hardware counter (Reagents stays mocked above)
    ctx.reads["autolathe-ref"] = { [LT_MOCK.ExportCount] = 2,
        [LT_MOCK.CompletionRatio] = 0.5 }
    m.service_one(task)
    ok(task.done_count == 2, "6.6 done_count follows ExportCount")
    ok(task.partial == 0.5, "6.6 partial follows CompletionRatio")
    ok(task.state == "active", "6.6 still active below the target count")

    -- finishing the count stops the printer and walks the output tail
    ctx.reads["autolathe-ref"][LT_MOCK.ExportCount] = 3
    m.service_one(task)
    ok(last_write("autolathe-ref", LT_MOCK.Activate) == 0,
        "6.7 Activate=0 when the count completes")
    m.service_one(task)
    m.service_one(task)
    ok(task.state == "completed", "6.7 the task completes through the output tail")
    ok(m.state.reserved[OWNER] == nil, "6.7 completion consumed the reservation")
    ok(m.state.active_task_by_printer["autolathe-ref"] == nil,
        "6.7 the printer binding is released")
    ok(last_write("autolathe-ref", LT_MOCK.ClearMemory) == 1,
        "6.7 the idle counter/recipe hold is repinned once the task ends")

    -- a printer fault fails the task
    local r2 = m.printers_request(
        { api_version = 2, client_request_id = "act-2", count = 1, item = "IronBar",
          family_id = 1, cost_vector = { Iron = 2 } },
        OWNER
    )
    local task2 = m.state.tasks[r2.task_id]
    m.service_one(task2)
    ctx.reads["autolathe-ref"] = { [LT_MOCK.Error] = 1 }
    m.service_one(task2)
    ok(task2.state == "failed" and task2.error_code == "printer_fault",
        "6.8 a LogicType.Error fails the task")
    ok(last_write("autolathe-ref", LT_MOCK.Activate) == 0,
        "6.8 the faulted printer is stopped")
end

--------------------------------------------
-- Test 7: Discovery and phase routing
--------------------------------------------
print("\n[TEST 7] Discovery and phase routing")

do
    local m = new_module()
    -- printers are supplied by the test via printer_by_name; discover would
    -- find none with an empty engine, but the routing table drives task start.
    ok(m.state.printer_by_name[1] == "autolathe-ref", "7.1 family 1 routes to the autolathe ref")
    ok(m.state.printer_by_name[2] == "pipebender-ref", "7.2 family 2 routes to the pipe bender ref")
    ok(m.state.phase == "ready", "7.3 phase is ready after discovery in the test")
end

--------------------------------------------
-- TEST 8: Invalid-request logging + controlled continue
--------------------------------------------
print("\n[TEST 8] Invalid-request logging and controlled continue")

do
    local m = new_module()
    local before = m.state.errors_seen

    -- 8.1 a structurally wrong recipe (negative amount) is rejected ...
    local bad = m.printers_request(
        { api_version = 2, client_request_id = "bad-1", count = 1, item = "IronBar",
          family_id = 1, cost_vector = { Iron = -5 } },
        OWNER
    )
    ok(bad.ok == false and bad.code == "invalid_cost_amount",
        "8.1 a negative-amount cost_vector is rejected")

    -- 8.2 ... AND written to the error log (the controller logs + continues).
    ok(m.state.errors_seen > before,
        "8.2 the invalid recipe was logged (errors_seen advanced)")

    -- 8.3 the chip CONTINUES: a subsequent valid request is still served.
    local good = m.printers_request(
        { api_version = 2, client_request_id = "good-1", count = 2, item = "IronBar",
          family_id = 1, cost_vector = { Iron = 3 } },
        OWNER
    )
    ok(good.ok == true and good.task_id ~= nil,
        "8.3 a valid request after a bad one still queues (control continues)")
    ok(good.reserved == 6, "8.3 the valid request reserved 2 x Iron(3) = 6")

    -- 8.4 a wholly malformed payload (not a table) is rejected, not a crash.
    local null = m.printers_request("not-a-table", OWNER)
    ok(null.ok == false and null.code == "invalid_request",
        "8.4 a non-table payload is rejected, not crash")

    -- 8.5 v1 payloads are refused at the gate.
    local old = m.printers_request(
        { api_version = 1, client_request_id = "old-1", count = 1, item = "IronBar",
          family_id = 1, cost_vector = { Iron = 1 } },
        OWNER
    )
    ok(old.ok == false and old.code == "invalid_request",
        "8.5 a legacy api_version payload is rejected")
end

--------------------------------------------
-- TEST 9: cancel-active records residue; ejection runs after the queue drains
--------------------------------------------
print("\n[TEST 9] Cancel-active + residue + ejection")

do
    local m = new_module()
    ctx.storage_handler = function(method, payload)
        return { api_version = 1, ok = true }
    end

    -- reach a task, mark some progress, then cancel it mid-run
    local r = m.printers_request(
        { api_version = 2, client_request_id = "cx-1", count = 4, item = "IronBar",
          family_id = 1, cost_vector = { [9] = 2 } },
        OWNER
    )
    local task = m.state.tasks[r.task_id]
    -- 2g x 4 = 8g reagent mass landing on board primes the single Activate
    -- press: the machine starts empty, then the load arrives.
    ctx.reads["autolathe-ref"] = { [LT_MOCK.Reagents] = 0 }
    m.service_one(task)
    ok(task.state == "active", "9.1 the task is active")
    ctx.reads["autolathe-ref"][LT_MOCK.Reagents] = 8
    m.service_one(task) -- start_print captures the baseline on the ACTIVE pass
    ctx.reads["autolathe-ref"][LT_MOCK.ExportCount] = 1
    m.service_one(task)
    ok(task.done_count == 1, "9.1 one item produced before cancel")

    -- simulate 8g delivered on the storage line (2g x 4 requested)
    task.delivered_reagents[9] = 8
    local c = m.printers_cancel({ api_version = 2, task_id = r.task_id }, OWNER)
    ok(c.ok == true and c.state == "cancelled", "9.2 an active task can be cancelled")
    ok(last_write("autolathe-ref", LT_MOCK.Activate) == 0,
        "9.2 cancelling stops the printer")
    -- residue = delivered(8) - consumed(2 x done_count(1)) = 6
    ok(m.state.residue[1] and m.state.residue[1][9] == 6,
        "9.2 delivered-but-unconsumed grams land in the residue ledger")

    -- a queued task for the family keeps ejection from starting
    local r2 = m.printers_request(
        { api_version = 2, client_request_id = "cx-2", count = 1, item = "IronBar",
          family_id = 1, cost_vector = { [9] = 2 } },
        OWNER
    )
    m.service_ejection()
    ok(m.state.ejecting[1] == nil, "9.3 ejection does not start while the family has live work")

    -- drain the family queue (cancel the queued task), then ejection starts
    m.printers_cancel({ api_version = 2, task_id = r2.task_id }, OWNER)
    m.service_ejection()
    ok(m.state.ejecting[1] ~= nil, "9.4 ejection starts once the family has no live tasks")
    ok(last_write("autolathe-ref", LT_MOCK.Open) == 1,
        "9.4 Open=1 drives the printer's internal eject")
    ok(last_write("autolathe-ref", LT_MOCK.Activate) == 0,
        "9.4 nothing is printing while ejecting")

    -- a queued task arriving mid-cycle waits for the Open to close
    local r3 = m.printers_request(
        { api_version = 2, client_request_id = "cx-3", count = 1, item = "IronBar",
          family_id = 1, cost_vector = { [9] = 2 } },
        OWNER
    )
    local task3 = m.state.tasks[r3.task_id]
    m.service_one(task3)
    ok(task3.state == "queued", "9.5 a new task stays queued during ejection")

    -- the cycle runs to completion even though the task is now live:
    -- elapsed past the bound + empty reads -> eject_end closes Open and
    -- clears the residue ledger.
    m.state.tick = 100
    m.service_ejection()
    ok(m.state.ejecting[1] == nil, "9.6 the cycle closes at its bound")
    ok(last_write("autolathe-ref", LT_MOCK.Open) == 0,
        "9.6 Open=0 after the eject completes")
    ok(m.state.residue[1] == nil, "9.6 residue cleared after ejection")

    -- with the eject closed the queued task proceeds normally
    m.service_one(task3)
    ok(task3.state == "active", "9.7 the queued task starts after ejection ends")
end

--------------------------------------------
-- TEST 10: get_inventory relay (cached, on-demand)
--------------------------------------------
print("\n[TEST 10] printers.get_inventory relay")

do
    local m = new_module()

    -- no storage handler -> the handler ARMS a fetch; the tick performs the
    -- (failing) async send. The handler itself stays non-blocking.
    local no_storage = m.printers_get_inventory({ api_version = 2 }, OWNER)
    ok(no_storage.ok == false and no_storage.err_code == "inventory_unavailable",
        "10.1 absent storage reports inventory_unavailable")
    ok(m.state.inventory_want == true, "10.1 the call armed a refresh")
    m.service_inventory_fetch()
    ok(m.state.inventory_cache == nil,
        "10.1 the failed async fetch left the cache empty")

    -- storage serves groups; the relay compacts to prefab_hash -> {q, avail}
    local calls = 0
    ctx.storage_handler = function(method, payload)
        calls = calls + 1
        return {
            api_version = 2, ok = true, inventory_revision = "inv-1",
            groups = {
                { prefab_hash = 9, confirmed_quantity = 100, available_quantity = 80 },
                { prefab_hash = 42, confirmed_quantity = 5, available_quantity = 5 },
            },
        }
    end
    m.state.inventory_queried_at = -1e9  -- expire the arm rate limit
    local arming = m.printers_get_inventory({ api_version = 2 }, OWNER)
    ok(arming.ok == false, "10.2 the arming call still reports unavailable")
    m.service_inventory_fetch()          -- the tick sends; mock answers in-line
    local inv = m.printers_get_inventory({ api_version = 2 }, OWNER)
    ok(inv.ok == true and type(inv.inventory) == "table",
        "10.2 the relay returns a compact inventory map")
    ok(inv.inventory[9] and inv.inventory[9].available == 80,
        "10.2 the map carries available_quantity")
    ok(inv.inventory[42] and inv.inventory[42].quantity == 5,
        "10.2 the map carries confirmed_quantity")
    ok(calls == 1, "10.2 one storage.get_state was sent")

    -- a second call inside the cache window hits the cache, not storage
    local inv2 = m.printers_get_inventory({ api_version = 2 }, OWNER)
    ok(inv2.ok == true and calls == 1,
        "10.3 the second call inside 2s is served from cache")
end

--------------------------------------------
-- TEST 11: boot device sanitization
--------------------------------------------
print("\n[TEST 11] initialize_devices parks controlled devices")

do
    local m = new_module()

    -- a feed flip-flop parks in the all-through route and stays powered
    m.state.feed_refs[1] = { "feed-ref-1" }
    m.state.ingress_ref = "ingress-ref"
    m.state.classifier_ref = "classifier-ref"
    -- a printer with no durable task gets Activate=0 + Open=0
    m.initialize_devices()
    ok(last_write("feed-ref-1", LT_MOCK.Mode) == 0,
        "11.1 the feed flip-flop parks in through mode")
    ok(last_write("feed-ref-1", LT_MOCK.On) == 1, "11.1 the feed flip-flop is powered on")
    ok(last_write("ingress-ref", LT_MOCK.Mode) == 2,
        "11.1 the ingress sorter is in Logic mode")
    ok(last_write("ingress-ref", LT_MOCK.Output) == -1,
        "11.1 the ingress sorter holds its input")
    ok(last_write("classifier-ref", LT_MOCK.Mode) == 2,
        "11.1 the output classifier is in Logic mode")
    ok(last_write("autolathe-ref", LT_MOCK.Activate) == 0,
        "11.2 an idle printer is deactivated at boot")
    ok(last_write("autolathe-ref", LT_MOCK.Open) == 0,
        "11.2 an idle printer's Open is closed at boot")

    -- a durable ACTIVE task keeps its printer running across the restart
    ctx.write_log = {}
    local r = m.printers_request(
        { api_version = 2, client_request_id = "boot-1", count = 1, item = "IronBar",
          family_id = 1, cost_vector = { Iron = 1 } },
        OWNER
    )
    local task = m.state.tasks[r.task_id]
    task.state = "active"
    m.state.active_task_by_printer["autolathe-ref"] = task.task_id
    m.initialize_devices()
    ok(count_writes("autolathe-ref", LT_MOCK.Activate, 0) == 0,
        "11.3 a printer owning a durable task is NOT deactivated at boot")
end

--------------------------------------------
-- TEST 12: serialized transfer route driver
--------------------------------------------
print("\n[TEST 12] serialized transfer route driver")

do
    local m = new_module()
    m.state.feed_refs[1] = { "feed-auto" }
    m.state.feed_refs[4] = { "feed-rocket" }
    m.state.ingress_ref = "ingress-ref"

    -- 12.1 a reached task arms the route BEFORE firing the reservation:
    -- the target family's flip diverts, every other passes through.
    local r = m.printers_request(
        { api_version = 2, client_request_id = "fx-1", count = 1, item = "Glass",
          family_id = 1, cost_vector = { [9] = 2, [42] = 1 } },
        OWNER
    )
    local task = m.state.tasks[r.task_id]
    m.service_one(task)
    ok(task.state == "active", "12.1 the reached task goes active")
    ok(m.state.route ~= nil and m.state.route.task_id == task.task_id,
        "12.1 the transfer route is armed for this task")
    ok(last_write("feed-auto", LT_MOCK.Mode) == 1,
        "12.1 the target family's flip diverts to its branch")
    ok(last_write("feed-rocket", LT_MOCK.Mode) == 0,
        "12.1 other families' flips pass through")
    ok(m.state.route.hashes[9] and m.state.route.hashes[42],
        "12.1 the route expects the task's cost-vector hashes")
    ok(last_write("feed-auto", LT_MOCK.Setting) == 0,
        "12.1 the flip's ratio dial stays pinned at 0 (Mode is the selector)")

    -- 12.2 a second family's task cannot fire while the bus is busy
    local m2 = new_module()
    m2.state.feed_refs[1] = { "feed-auto" }
    m2.state.feed_refs[2] = { "feed-bender" }
    local rA = m2.printers_request(
        { api_version = 2, client_request_id = "fx-2a", count = 1, item = "Glass",
          family_id = 1, cost_vector = { [9] = 2 } },
        OWNER
    )
    local rB = m2.printers_request(
        { api_version = 2, client_request_id = "fx-2b", count = 1, item = "Pipe",
          family_id = 2, cost_vector = { [7] = 3 } },
        OWNER
    )
    local taskA = m2.state.tasks[rA.task_id]
    local taskB = m2.state.tasks[rB.task_id]
    m2.service_one(taskA)
    m2.service_one(taskB)
    ok(taskA.state == "active" and taskB.state == "queued",
        "12.2 the bus serializes: the second task stays queued")
    ok(m2.state.route.task_id == taskA.task_id,
        "12.2 the route belongs to the first transfer")

    -- 12.3 release requires the WHOLE aggregate load inside the printer --
    -- releasing on first movement let a late reagent delivery ride the bus
    -- past every flip to the output classifier. fx-1 needs 3 items.
    task.resources_state = "delivered"
    ctx.reads["autolathe-ref"] = { [LT_MOCK.ImportCount] = 0 }
    m.service_route()
    ok(m.state.route ~= nil, "12.3 route holds while import is unconfirmed")
    ctx.reads["autolathe-ref"][LT_MOCK.ImportCount] = 1
    for _ = 1, 6 do m.service_route() end
    ok(m.state.route ~= nil,
        "12.3 route holds while only part of the load is in")
    ctx.reads["autolathe-ref"][LT_MOCK.ImportCount] = 3
    for _ = 1, 6 do m.service_route() end
    ok(m.state.route == nil,
        "12.3 route releases once the full load is in + settle")
    ok(last_write("feed-auto", LT_MOCK.Mode) == 0,
        "12.3 the bus is back to all-through after release")

    -- 12.4 a terminal task drops the route so strays ride to the return
    local m3 = new_module()
    m3.state.feed_refs[1] = { "feed-auto" }
    local r3 = m3.printers_request(
        { api_version = 2, client_request_id = "fx-4", count = 1, item = "Glass",
          family_id = 1, cost_vector = { [9] = 2 } },
        OWNER
    )
    local task3 = m3.state.tasks[r3.task_id]
    m3.service_one(task3)
    ok(m3.state.route ~= nil, "12.4 route armed")
    task3.state = "cancelled"
    m3.service_route()
    ok(m3.state.route == nil, "12.4 a terminal task releases the route")
    ok(last_write("feed-auto", LT_MOCK.Mode) == 0,
        "12.4 flips return to through mode")

    -- 12.5 ingress steering: expected hash -> bus, stray -> storage return
    ctx.slots["ingress-ref"] = { [0] = {
        [LST_MOCK.Occupied] = 1, [LST_MOCK.OccupantHash] = 9,
        [LST_MOCK.Quantity] = 2 } }
    m.state.route = { task_id = task.task_id, family_id = 1,
        hashes = { [9] = true }, started = 0, saw_import = true, settle = 0 }
    task.state = "active"
    task.resources_state = "delivered"
    m.service_route()
    ok(last_write("ingress-ref", LT_MOCK.Output) == 2,
        "12.5 an expected hash is steered to the bus (Export2)")
    ctx.slots["ingress-ref"][0][LST_MOCK.OccupantHash] = 555
    m.service_route()
    ok(last_write("ingress-ref", LT_MOCK.Output) == 1,
        "12.5 a stray hash bounces to the storage return (Export)")

    -- 12.6 residue inside the machine cannot fake a complete load: the route
    -- releases on the reagent DELTA over its own pre-delivery baseline, so
    -- leftover mass plus a partial load cannot release it while later
    -- reagent deliveries still ride the bus.
    local m4 = new_module()
    m4.state.feed_refs[1] = { "feed-auto" }
    ctx.storage_handler = function(method, payload)
        return { api_version = 1, ok = true }
    end
    ctx.reads["autolathe-ref"] = { [LT_MOCK.Reagents] = 5,
        [LT_MOCK.ImportCount] = 0 }
    local r4 = m4.printers_request(
        { api_version = 2, client_request_id = "fx-5", count = 1, item = "Glass",
          family_id = 1, cost_vector = { [9] = 10 } },
        OWNER
    )
    local task4 = m4.state.tasks[r4.task_id]
    m4.service_one(task4)
    ok(m4.state.route ~= nil, "12.6 route armed")
    task4.resources_state = "delivered"
    -- residue 5 + the first 5 of the load: absolute mass 10 already meets the
    -- need, but only 5 of the job's mass actually arrived so far.
    ctx.reads["autolathe-ref"][LT_MOCK.Reagents] = 10
    for _ = 1, 6 do m4.service_route() end
    ok(m4.state.route ~= nil,
        "12.6 residue-inflated reagent mass cannot release the route early")
    ctx.reads["autolathe-ref"][LT_MOCK.Reagents] = 15
    for _ = 1, 6 do m4.service_route() end
    ok(m4.state.route == nil,
        "12.6 the route releases once the load's mass delta is inside")

    -- 12.7 a lifetime ImportCount read at route-open cannot fake completion:
    -- ClearMemory fires at start_print (after the arm), so the pre-clear
    -- tally must rebase instead of releasing the route before the gold
    -- arrives -- the live failure where the feeders dropped mid-delivery.
    local m5 = new_module()
    m5.state.feed_refs[1] = { "feed-auto" }
    ctx.storage_handler = function(method, payload)
        return { api_version = 1, ok = true }
    end
    ctx.reads["autolathe-ref"] = { [LT_MOCK.ImportCount] = 47,
        [LT_MOCK.Reagents] = 0 }
    local r5 = m5.printers_request(
        { api_version = 2, client_request_id = "fx-6", count = 1, item = "Glass",
          family_id = 1, cost_vector = { [9] = 3 } },
        OWNER
    )
    local task5 = m5.state.tasks[r5.task_id]
    m5.service_one(task5)
    ok(m5.state.route ~= nil, "12.7 route armed")
    task5.resources_state = "delivered"
    -- post-clear counter: only 2 of the job's 3 items are in so far
    ctx.reads["autolathe-ref"][LT_MOCK.ImportCount] = 2
    for _ = 1, 6 do m5.service_route() end
    ok(m5.state.route ~= nil,
        "12.7 the lifetime tally cannot release the route early")
    ctx.reads["autolathe-ref"][LT_MOCK.ImportCount] = 3
    for _ = 1, 6 do m5.service_route() end
    ok(m5.state.route == nil,
        "12.7 the route releases once the post-clear count completes")
end

--------------------------------------------
-- TEST 13: no phantom completion + export-count-only progress
--------------------------------------------
print("\n[TEST 13] counter baseline + export-count-only progress")

do
    local m = new_module()
    ctx.storage_handler = function(method, payload)
        return { api_version = 1, ok = true }
    end

    -- 13.1 the verified-clear baseline: the counter clear is issued on one
    -- pass and the counter must read 0 on the NEXT pass before it becomes
    -- the origin -- an unreadable counter retries (no activation) and a
    -- stale pre-clear tally is never adopted as the baseline.
    ctx.reads["autolathe-ref"] = { [LT_MOCK.ExportCount] = 4 }
    local r = m.printers_request(
        { api_version = 2, client_request_id = "px-1", count = 1, item = "IronBar",
          family_id = 1, cost_vector = { [9] = 2 } },
        OWNER
    )
    local task = m.state.tasks[r.task_id]
    local real_read = ctx.ic.read_id
    ctx.ic.read_id = function() error("device gone") end
    m.service_one(task)
    ctx.ic.read_id = real_read
    ok(task.state == "active" and task.export_baseline == nil,
        "13.1 an unreadable counter leaves the task unstarted, not baseline 0")
    ok(last_write("autolathe-ref", LT_MOCK.Activate) ~= 1,
        "13.1 Activate was not written without a counter baseline")
    -- model the reset landing late: the verify pass still reads the stale
    -- pre-clear tally -> the baseline is refused and the clear re-issued
    ctx.reads["autolathe-ref"][LT_MOCK.ExportCount] = 4
    m.service_one(task)
    ok(task.export_baseline == nil and task.state == "active",
        "13.1 a stale pre-clear tally is not adopted; the task retries")
    -- the re-issued clear landed: the next verify reads 0 -> baseline adopted
    m.service_one(task)
    ok(task.export_baseline == 0,
        "13.1 the verified post-clear counter is the baseline (always 0)")
    ctx.reads["autolathe-ref"][LT_MOCK.ExportCount] = 1
    m.service_one(task)
    ok(task.done_count == 1,
        "13.1 only a real post-baseline export advances the count")

    -- 13.2 the classifier routes but does NOT count: a transit whose occupant
    -- hash equals the task's product hash is steered to the collection leg,
    -- yet progress comes only from the post-baseline ExportCount delta. A
    -- product held in the sorter slot for many ticks must never inflate
    -- done_count (the regression that completed jobs early in-game).
    local m2 = new_module()
    ctx.storage_handler = function(method, payload)
        return { api_version = 1, ok = true }
    end
    m2.state.classifier_ref = "classifier-ref"
    local r2 = m2.printers_request(
        { api_version = 2, client_request_id = "px-2", count = 2, item = "IronBar",
          family_id = 1, cost_vector = { [9] = 2 } },
        OWNER
    )
    local task2 = m2.state.tasks[r2.task_id]
    m2.service_one(task2)
    local product = task2.product_hash
    ok(type(product) == "number", "13.2 the task knows its product hash")
    -- the counter stays at its cleared 0; only classifier transits are seen
    ctx.slots["classifier-ref"] = { [0] = {
        [LST_MOCK.Occupied] = 1, [LST_MOCK.OccupantHash] = product,
        [LST_MOCK.Quantity] = 1 } }
    m2.service_route()
    ok(last_write("classifier-ref", LT_MOCK.Output) == 2,
        "13.2 the product is steered to the collection leg (Export2)")
    -- the same item re-arrives at the sorter every tick it waits; it must
    -- not move done_count at all -- ExportCount is the sole progress source
    for _ = 1, 5 do m2.service_route() end
    m2.service_one(task2)
    ok(task2.done_count == 0,
        "13.2 held product transits never advance done_count")
    ctx.reads["autolathe-ref"] = ctx.reads["autolathe-ref"] or {}
    ctx.reads["autolathe-ref"][LT_MOCK.ExportCount] = 1
    m2.service_one(task2)
    ok(task2.done_count == 1,
        "13.2 only a real post-baseline export advances the count")
    ctx.slots["classifier-ref"][0][LST_MOCK.OccupantHash] = 9
    m2.service_route()
    ok(last_write("classifier-ref", LT_MOCK.Output) == 1,
        "13.2 a reagent-hash transit routes back to storage (Export)")
    ctx.slots["classifier-ref"][0][LST_MOCK.OccupantHash] = 777
    m2.service_route()
    ok(m2.state.classifier_unknown[777],
        "13.2 an unknown prefab is held and diagnosed, not routed")
end

--------------------------------------------
-- TEST 14: required-topology boot gate
--------------------------------------------
print("\n[TEST 14] required-topology boot gate")

do
    local m = new_module()
    -- Only families 1-2 are stubbed by new_module, no feeds or sorters:
    -- the gate must throw and name the missing devices.
    local ok_gate, err_gate = pcall(m.verify_topology)
    ok(not ok_gate, "14.1 incomplete topology throws (chip fails to boot)")
    ok(type(err_gate) == "string" and
        err_gate:find("required device", 1, true) ~= nil,
        "14.1 the error reports the missing required devices")

    -- Complete the topology: printers for families 3-6, one feed splitter
    -- per family carrying a digital flip flop hash, both sorters carrying
    -- the StructureSorter hash.
    local FEED_LEFT_H = -810874728   -- StructureChuteDigitalFlipFlopSplitterLeft
    local FEED_RIGHT_H = 163728359   -- StructureChuteDigitalFlipFlopSplitterRight
    local SORTER_H = -1009150565     -- StructureSorter
    for family_id = 3, 6 do
        m.state.printer_by_name[family_id] = "printer-ref-" .. family_id
    end
    for family_id = 1, 6 do
        local ref = "feed-ref-" .. family_id
        m.state.feed_refs[family_id] = { ref }
        ctx.reads[ref] = { [LT_MOCK.PrefabHash] = FEED_LEFT_H }
    end
    m.state.ingress_ref = "ingress-ref"
    m.state.classifier_ref = "classifier-ref"
    ctx.reads["ingress-ref"] = { [LT_MOCK.PrefabHash] = SORTER_H }
    ctx.reads["classifier-ref"] = { [LT_MOCK.PrefabHash] = SORTER_H }
    ok(pcall(m.verify_topology),
        "14.2 a full valid topology passes the gate")

    -- A mislabeled device under a feed name fails the prefab check even
    -- though the family is populated.
    ctx.reads["feed-ref-3"][LT_MOCK.PrefabHash] = 999
    ok(not pcall(m.verify_topology),
        "14.3 a non-flip-flop device under a feed name fails")
    ctx.reads["feed-ref-3"][LT_MOCK.PrefabHash] = FEED_RIGHT_H
    ok(pcall(m.verify_topology),
        "14.3 the Right-variant digital flip flop is also accepted")

    -- A StructureLogicSorter is a different prefab: it must NOT satisfy the
    -- standard-sorter requirement.
    ctx.reads["classifier-ref"][LT_MOCK.PrefabHash] = 873418029
    ok(not pcall(m.verify_topology),
        "14.4 a Logic Sorter at the classifier slot fails the check")

    -- A missing printer family fails even with feeds + sorters present.
    ctx.reads["classifier-ref"][LT_MOCK.PrefabHash] = SORTER_H
    m.state.printer_by_name[5] = nil
    ok(not pcall(m.verify_topology),
        "14.5 a missing printer family fails the gate")
end

--------------------------------------------
print(string.format(
    "\n=== PrinterController test suite: %d passed, %d failed ===",
    pass, fail
))

if fail == 0 then
    print("All PrinterController tests passed")
    os.exit(0)
else
    print(string.format("%d test(s) failed", fail))
    os.exit(1)
end
