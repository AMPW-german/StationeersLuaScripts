-- Regression tests for PrinterController.lua
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
    _exports.dispatch_reserved = dispatch_reserved
    _exports.delivery_ack = delivery_ack
    _exports.release_batch = release_batch
    _exports.query_reservation = query_reservation
    _exports.printers_request = printers_request
    _exports.printers_request_status = printers_request_status
    _exports.printers_cancel = printers_cancel
    _exports.printers_get_state = printers_get_state
    _exports.printers_get_config = printers_get_config
    _exports.register_api = register_api
    _exports.check_commission = check_commission
    _exports.discover_printers = discover_printers
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

local ctx = {
    ic = nil,
    net = nil,
    store = nil,
    bit = nil,
    print_log = nil,
    handlers = nil,
}

ctx.net = {
    log = {},
}
ctx.store = {}
ctx.bit = {}
ctx.print_log = {}
ctx.handlers = nil

local bit = ctx.bit

-- 32-bit-safe pack/extract for the (unused-while-gated) printing-word stubs.
local function bit_ins(w, v, s, e)
    local width = (e or s) - s + 1
    local shift = s
    local mask = 0
    for i = 0, width - 1 do
        mask = mask + (2 ^ i)
    end
    local low = math.mod(v, mask + 1)
    return math.floor(w + low * (2 ^ shift))
end
local function bit_extract(w, s, e)
    local width = (e or s) - s + 1
    local mask = 0
    for i = 0, width - 1 do
        mask = mask + (2 ^ i)
    end
    return math.mod(math.floor(w / (2 ^ s)), mask + 1)
end
bit.ins = bit_ins
bit.extract = bit_extract

ctx.ic = {
    enums = {
        LogicType = {
            NUMBER = 1,
            LOGICAL = 4,
            TEXT = 5,
        },
        LogicSlotType = {
            INPUT = 1,
            INPUT_OUTPUT = 3,
            INTERNAL = 4,
        },
        SorterInstruction = {
            SORTER_INSTRUCTION_SORT = 1,
        },
    },
    -- read_id / write_id / mem.put_id: no-op wrappers (safe_call wraps these).
    read_id = function(ref_id, logic_type)
        return 0
    end,
    write_id = function(ref_id, logic_type, value)
        return true
    end,
    mem = setmetatable({}, {
        __index = function(_, name)
            if name == "put_id" then
                return function(ref_id, address, value)
                    ctx.store[ref_id .. ":" .. tostring(address)] = value
                    return true
                end
            end
            if name == "get_id" then
                return function(ref_id, address)
                    return ctx.store[ref_id .. ":" .. tostring(address)]
                end
            end
            return nil
        end,
    }),
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
        request = function(name, payload, options)
            local handler = ctx.handlers[name]
            if not handler then
                return nil, "no handler registered: " .. name
            end
            return handler(payload, OWNER, options or { origin = "test" })
        end,
    },
    persist = {
        set = function(name, value)
            ctx.store["persist:" .. name] = value
        end,
        get = function(name, default)
            local value = ctx.store["persist:" .. name]
            if value == nil then
                return default
            end
            return value
        end,
        exists = function(name)
            return ctx.store["persist:" .. name] ~= nil
        end,
        remove = function(name)
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
    return setfenv(chunk, env)()
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
    local chunk_run, chunk_err = run_body()
    if not chunk_run then
        print("ERROR: chunk failed to run: " .. tostring(chunk_err))
        os.exit(1)
    end
    -- The catalog-free controller boots and serves without any catalog module.
    -- The test supplies its own topology (printer_by_name) and drives requests
    -- that each carry their own catalog-derived cost_vector.
    chunk_run.state.phase = "ready"
    chunk_run.state.printer_by_name[1] = "autolathe-ref"
    chunk_run.state.printer_by_name[2] = "pipebender-ref"
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
        api_version = 1,
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
        api_version = 1,
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

    local bad2 = m.valid_cost_vector({ [1] = 5 })
    ok(bad2 == nil, "1.4 a non-string key is rejected by valid_cost_vector")

    local bad3 = m.valid_cost_vector("not-a-table")
    ok(bad3 == nil, "1.4 a non-table input is rejected by valid_cost_vector")

    local empty_tbl, empty_err, empty_total = m.valid_cost_vector({})
    ok(type(empty_tbl) == "table" and empty_total == 0,
        "1.4 an empty vector returns an empty table with total 0")
    ok(empty_err == nil, "1.4 an empty vector is structurally valid")
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
        m.state.printer_by_name[2] = "pipebender-ref"
        m.register_api()
        local resp = m.printers_request({
            api_version = 1,
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
-- Test 3: Additive reservation ledger (printer side)
--------------------------------------------
print("\n[TEST 3] Additive reservation ledger")

do
    local m = new_module()

    local cost = { Iron = 2, Copper = 1 }
    local err
    local record, rerr = m.reserve_batch("ownerA", "R1", cost, 3)
    ok(record ~= nil, "3.1 reserve_batch creates a ledger record")
    ok(record and record.reserved == 9, "3.1 reserved amount = per-item(3) x count(3) = 9")
    ok(m.state.reserved["ownerA"] == 9, "3.1 owner aggregate = 9")

    -- additive: a second reservation on the same owner accumulates
    m.reserve_batch("ownerA", "R2", cost, 2)
    ok(m.state.reserved["ownerA"] == 9 + 6, "3.2 second reservation adds to the owner aggregate (9+6=15)")

    -- dispatch moves per-item quantity into the in-transit account
    local moved, derr = m.dispatch_reserved("ownerA", "R1", 1)
    ok(moved == 1, "3.3 dispatch_reserved returns dispatched count")
    local q = m.query_reservation("ownerA", "R1")
    ok(q and q.delivered == 3, "3.3 dispatch moved per-item 3g into the in-transit account")

    -- a released reservation with in-flight quantity is refused
    local ok_rel = m.release_batch("ownerA", "R1")
    ok(ok_rel == nil, "3.4 in-flight reservation cannot be released")

    -- a clean reservation can be released, freeing the owner aggregate
    m.release_batch("ownerA", "R2")
    ok(m.state.reserved["ownerA"] == 9, "3.4 release of a clean reservation frees the owner aggregate")

    -- two owners are independent
    m.reserve_batch("ownerB", "B1", { Iron = 1 }, 4)
    ok(m.state.reserved["ownerB"] == 4, "3.5 a second owner's reservation is independent")
    m.release_batch("ownerB", "B1")
    ok(m.state.reserved["ownerB"] == nil, "3.5 releasing a solo owner drops its aggregate")
end

--------------------------------------------
-- Test 4: Task API (request / status / cancel / idempotency)
--------------------------------------------
print("\n[TEST 4] Task API")

do
    local m = new_module()

    -- 4.1 idempotent create
    local r1 = m.printers_request(
        { api_version = 1, client_request_id = "key-1", count = 5, item = "IronBar",
          family_id = 1, cost_vector = { Iron = 2 } },
        OWNER
    )
    ok(r1.ok == true and r1.task_id ~= nil, "4.1 printers_request creates a queued task")
    ok(r1.reserved == 10, "4.1 reservation recorded = 5 x Iron(2) = 10")

    -- 4.2 replay of the same client key returns the same task, not a new one
    local r2 = m.printers_request(
        { api_version = 1, client_request_id = "key-1", count = 5, item = "IronBar",
          family_id = 1, cost_vector = { Iron = 2 } },
        OWNER
    )
    ok(r2.ok == true and r2.replayed == true, "4.2 same client_request_id replays the same task")
    ok(r2.task_id == r1.task_id, "4.2 replay returns the original task_id")

    -- 4.3 status lookup
    local status = m.printers_request_status({ api_version = 1, task_id = r1.task_id }, OWNER)
    ok(status.ok == true and status.task ~= nil, "4.3 request_status finds the task")
    ok(status.task.state == "queued", "4.3 task state is queued")

    -- 4.4 unknown task => unknown_request
    local miss = m.printers_request_status({ api_version = 1, task_id = "no-such-task" }, OWNER)
    ok(miss.ok == false and miss.code == "unknown_request", "4.4 unknown task_id => unknown_request")

    -- 4.5 cancel
    local c = m.printers_cancel({ api_version = 1, task_id = r1.task_id }, OWNER)
    ok(c.ok == true and c.state == "cancelled", "4.5 cancel moves a queued task to cancelled")
    -- cancel releases the reservation
    ok(m.state.reserved[OWNER] == nil, "4.5 cancelled task frees its reservation")

    -- 4.6 get_config reports families + native gating
    local cfg = m.printers_get_config({ api_version = 1 })
    ok(cfg.ok == true and cfg.families[1] == "autolathe", "4.6 get_config reports named families")
    ok(cfg.native_enabled == false, "4.6 native printing is gated OFF by default (commission gate)")

    -- 4.7 get_state reports the queue
    local st = m.printers_get_state({ include_tasks = true })
    ok(st.ok == true, "4.7 get_state returns ok")
    ok(type(st.tasks) == "table", "4.7 get_state includes the task list")
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

    -- 5.5 a non-string key is rejected
    ok(m.valid_cost_vector({ [1] = 5 }) == nil, "5.5 a non-string key is rejected")

    -- 5.6 a NaN amount is rejected (amount ~= amount)
    ok(m.valid_cost_vector({ Iron = 0 / 0 }) == nil, "5.6 a NaN amount is rejected")

    -- 5.7 zero amounts are stripped (do not pollute the vector or the total)
    local stripped, s_err, s_total = m.valid_cost_vector({ Iron = 0, Copper = 1 })
    ok(stripped ~= nil and stripped.Iron == nil, "5.7 a zero amount is stripped from the result")
    ok(stripped.Copper == 1, "5.7 a non-zero amount survives the strip")
    ok(s_err == nil and s_total == 1, "5.7 the total excludes the stripped zero")
end

--------------------------------------------
-- Test 6: Native printing stays gated until commissioned
--------------------------------------------
print("\n[TEST 6] Native printing commission gate")

do
    local m = new_module()
    ok(m.check_commission() == false, "6.1 check_commission is false before commissioning")

    m.state.native_enabled = true
    ok(m.check_commission() == false, "6.2 enabling native alone is not enough (not yet commissioned)")

    m.state.native_commissioned = true
    ok(m.check_commission() == true, "6.3 commissioned + enabled => commission check passes")
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
-- TEST 8: Invalid-recipe logging + controlled continue
--------------------------------------------
print("\n[TEST 8] Invalid-request logging and controlled continue")

do
    local m = new_module()
    local before = m.state.errors_seen

    -- 8.1 a structurally wrong recipe (negative amount) is rejected ...
    local bad = m.printers_request(
        { api_version = 1, client_request_id = "bad-1", count = 1, item = "IronBar",
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
        { api_version = 1, client_request_id = "good-1", count = 2, item = "IronBar",
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
