-- Regression tests for PrinterController.lua journaling + persistence (plan item 8).
--
-- The StationeersLua tick execution can be stopped any time between ticks, so the
-- controller must make its in-flight task state DURABLE and RESTORABLE:
--
--   * every state transition is appended to an in-memory `journal`
--     (journal_append, capped at JOURNAL_MAX) AND
--   * a full durable snapshot is flushed to ic.persist after each checkpoint
--     ("a journal entry implies a checkpoint"), and
--   * on boot, restore_state() replays that snapshot: it rebuilds the tasks,
--     task_order, the reservation ledger, the idempotency map, the active-task
--     per-printer mapping, and the sequence counter -- WITHOUT
--     re-reserving in-flight resources or re-creating tasks.
--
-- The controller is catalog-free: it carries no `refresh_catalog`, no
-- `recipe_cost_vector`, and no `my_revision`/`my_api_version`. Every request
-- supplies its own catalog-derived `cost_vector`, which the controller
-- structurally validates (valid_cost_vector) before it touches the ledger.
--
-- These tests exercise that contract across a simulated hard restart: a fresh
-- module boots against the SAME persistent store (ctx.store), which is exactly
-- what a tick stop + restart looks like from the chip's point of view.
--
-- The persistence path uses the game's util.json for serialization and ic.persist
-- for the durable store -- the same mechanism StorageController.lua uses. The
-- tests substitute tests/json_codec.lua for util.json as a stand-in only.
--
-- Lua 5.1 compatible. No ic.* in the test itself (the mocks drive the chip).
--
-- Usage:
--   lua tests/test_printer_persistence.lua            (relative paths — cwd = repo root)
--   lua -v 5.1  or  /path/to/Lua51/lua
--
-- Exits 0 when all checks pass, 1 otherwise.

-- ---- Load the JSON codec stand-in from the repo root or the tests/ dir.
local function load_first(paths, err_msg)
    for i = 1, #paths do
        local okmod, mod = pcall(dofile, paths[i])
        if okmod and mod then
            return mod
        end
    end
    error(err_msg)
end

local json = load_first(
    { "json_codec.lua", "tests/json_codec.lua" },
    "json_codec.lua not found (run from repo root or tests/)")

-- Compile check only (the body is spliced below to avoid the main loop).
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

local function load_source(path, alt)
    local f = io.open(path, 'r')
    if not f and alt then
        f = io.open(alt, 'r')
    end
    f = assert(f, 'cannot open ' .. path .. (alt and (', or ' .. alt) or ''))
    local text = f:read("*a")
    f:close()
    return text
end

local chip_source = load_source('PrinterController.lua', '../PrinterController.lua')
local entry_index = chip_source:find("\ninitialize()", 1, true)
if not entry_index then
    error("could not find initialize() entry point in PrinterController.lua")
end

local test_entry = string.sub(chip_source, 1, entry_index - 1)

local export_code = [[
    local _exports = {}
    _exports.state = state
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
    _exports.service_tasks = service_tasks
    _exports.checkpoint = checkpoint
    _exports.restore_state = restore_state
    return _exports
]]

local body = test_entry .. "\n" .. export_code .. "\n"
local loadstring = loadstring or load
local chunk, err = loadstring(body, 'PrinterController.lua (test harness)')

if not chunk then
    print("ERROR: failed to load spliced test body:\n" .. tostring(err))
    os.exit(1)
end

local ctx = {
    net = { log = {} },
    store = {},
}

ctx.bit = {}
ctx.print_log = {}
ctx.handlers = nil

local bit = ctx.bit

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
        LogicType = { NUMBER = 1048576, LOGICAL = 2097152, TEXT = 3145728 },
        LogicSlotType = { INPUT = 1, INPUT_OUTPUT = 3, INTERNAL = 4 },
        SorterInstruction = { SORTER_INSTRUCTION_SORT = 1 },
    },
    -- The real chip reads/writes via safe_call + these mocks; no-op-ish.
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
            return handler(payload, "test-owner", options or { origin = "test" })
        end,
    },
    -- The durable store. Persists across run_body() calls (across "restarts").
    -- The controller writes JSON encoded with util.json (see env.util below).
    persist = {
        set = function(name, value)
            ctx.store["persist:" .. name] = value
        end,
        get = function(name, default)
            local value = ctx.store["persist:" .. name]
            if value == nil then
                if default ~= nil then
                    return default
                end
                return nil
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
-- Actuation packs a word via ic.bit.ins; surface the test's bit ops on ic.
-- (Gated off unless commissioned, so the path is only reached on P5's task.)
ctx.ic.bit = ctx.bit

-- The PERSISTENCE_KEY the controller durably writes to.
local PERSISTENCE_KEY = "printer_controller_state"

local function run_body()
    local env = setmetatable({}, { __index = _G })
    for k, v in pairs(_G) do
        env[k] = v
    end
    env.state = nil
    env.ic = ctx.ic
    -- The controller serializes via util.json.encode/decode; substitute the codec.
    env.util = { json = json }
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

-- A "module" is one chip lifetime: run_body() boots the chip (which runs the
-- spliced body up to initialize()), then we recover the durable snapshot the way
-- the chip does on boot. Because run_body re-runs the same code against the same
-- ctx.store, calling new_module() a second time simulates a hard stop + restart.
-- The controller is catalog-free, so no catalog is wired in and no
-- refresh_catalog() is invoked; the test drives requests that each carry an
-- explicit cost_vector.
local function new_module()
    ctx.handlers = nil
    local chunk_run, chunk_err = run_body()
    if not chunk_run then
        print("ERROR: chunk failed to run: " .. tostring(chunk_err))
        os.exit(1)
    end
    -- Boot the same way the chip boots: reload the durable snapshot so an
    -- in-flight task survives a restart. The spliced body cuts off the real
    -- initialize() (see entry_index above), so we run the API-registration and
    -- recovery paths here.
    chunk_run.register_api()
    chunk_run.restore_state()
    chunk_run.state.phase = "ready"
    chunk_run.state.printer_by_name[1] = "autolathe-ref"
    chunk_run.state.printer_by_name[2] = "pipebender-ref"
    return chunk_run
end

local OWNER = "test-owner"

--------------------------------------------
-- TEST P1: Fresh boot with no durable state
--------------------------------------------
print("\n[TEST P1] Fresh boot with no durable state")

do
    ctx.store = {}
    ctx.handlers = nil
    local m1 = new_module()

    ok(type(m1.state) == "table", "P1.1 fresh boot boots cleanly with no durable state")
    ok(count_table_values(m1.state.tasks) == 0, "P1.2 fresh boot recovers zero tasks")
    ok(count_table_values(m1.state.journal) == 0, "P1.3 fresh boot starts with an empty journal")
    ok(m1.state.journal_seq == 0, "P1.4 fresh boot journal_seq is 0")
    ok(count_table_values(m1.state.reserved_ledger) == 0, "P1.5 fresh boot recovers zero reservations")

    -- A request that is not persisted: the durable store still stays empty until
    -- a mutating op runs and checkpoints.
    ok(ctx.store["persist:" .. PERSISTENCE_KEY] == nil,
        "P1.6 no durable snapshot exists before any mutating op")
end

--------------------------------------------
-- TEST P2: Create journals + checkpoints
--------------------------------------------
print("\n[TEST P2] A create journals and checkpoints durably")

do
    local m = new_module()

    local created = m.printers_request({
        api_version = 1,
        client_request_id = "job-1",
        count = 5,
        item = "IronBar",
        family_id = 1,
        cost_vector = { Iron = 2 },
    }, OWNER)
    ok(created and created.ok == true and created.task_id ~= nil, "P2.1 task created and queued")
    local taskId = created.task_id

    -- The durable store must hold a JSON snapshot (ic.persist + util.json).
    local raw = ctx.store["persist:" .. PERSISTENCE_KEY]
    ok(type(raw) == "string" and #raw > 0, "P2.2 a durable snapshot was flushed to ic.persist")

    -- The in-memory journal captured both the create and the queued transition.
    local saw_created, saw_transition, saw_seq = false, false, false
    for _, entry in ipairs(m.state.journal or {}) do
        if entry.op == "task_created" then
            saw_created = true
        end
        if entry.op == "transition" and entry.to == "queued" then
            saw_transition = true
        end
        if entry.op == "checkpoint" then
            saw_seq = true
        end
    end
    ok(saw_created, "P2.3 the journal recorded a task_created entry")
    ok(saw_transition, "P2.4 the journal recorded a transition to queued")
    ok(saw_seq, "P2.5 a checkpoint entry was recorded to the journal")
    ok(m.state.journal_seq >= 3, "P2.6 journal_seq advanced to at least 3 (create, transition, checkpoint)")

    -- The durable snapshot decodes to a complete, valid shape.
    local blob = json.decode(raw)
    ok(blob ~= nil, "P2.7 the durable snapshot decodes")
    ok(blob.controller_schema_version == 1, "P2.8 the snapshot carries the controller schema version")

    local foundTask = false
    for i = 1, #blob.task_order do
        local tid = blob.task_order[i]
        local task = blob.tasks and blob.tasks[tid]
        if task and task.task_id == taskId then
            foundTask = true
            ok(task.cost_vector ~= nil and task.cost_vector.Iron == 2,
                "P2.9 the journal snapshot kept the accepted cost vector (Iron=2)")
            ok(task.reservation_id == "job-1:reserve",
                "P2.10 the snapshot carries the task's reservation id")
            ok(task.state == "queued", "P2.11 the snapshot captured the queued state")
        end
    end
    ok(foundTask, "P2.12 the durable snapshot names the created task + reservation")

    -- A checkpoint entry records the journal_seq it captured -- the recovery point.
    local lastCheckpointSeq = 0
    for i = #m.state.journal, 1, -1 do
        local entry = m.state.journal[i]
        if entry.op == "checkpoint" then
            lastCheckpointSeq = entry.journal_seq
            break
        end
    end
    ok(lastCheckpointSeq >= m.state.journal_seq - 1,
        "P2.13 the final checkpoint recorded the current journal_seq")
end

--------------------------------------------
-- TEST P3: Restart recovers in-flight state WITHOUT re-reserving
--------------------------------------------
print("\n[TEST P3] Restart recovers in-flight state without re-reserving")

do
    local m1 = new_module()
    local created = m1.printers_request({
        api_version = 1,
        client_request_id = "job-1",
        count = 5,
        item = "IronBar",
        family_id = 1,
        cost_vector = { Iron = 2 },
    }, OWNER)
    local taskId = created.task_id
    local resBeforeRestart = m1.state.reserved[OWNER]
    local seqBeforeRestart = m1.state.sequence
    local ledgerBefore = count_table_values(m1.state.reserved_ledger)
    ok(ledgerBefore == 1, "P3.0 pre-restart there is exactly one reservation ledger entry")

    -- A hard stop + restart: a fresh module boots against the same persistent store.
    local m2 = new_module()

    ok(count_table_values(m2.state.tasks) == 1, "P3.1 the in-flight task survived the restart")
    ok(count_table_values(m2.state.task_order) == 1, "P3.2 the task order survived the restart")

    local recovered = false
    for _, task in pairs(m2.state.tasks) do
        if task.task_id == taskId then
            recovered = true
            ok(task.cost_vector ~= nil and task.cost_vector.Iron == 2,
                "P3.3 the recovered task kept its accepted cost vector (Iron=2)")
            ok(task.reservation_id == "job-1:reserve",
                "P3.4 the recovered task kept its reservation id (in place, not re-reserved)")
            ok(task.state == "queued", "P3.5 the recovered task kept its queued state")
            ok(task.count == 5, "P3.6 the recovered task kept its count")
        end
    end
    ok(recovered, "P3.7 the exact task reappeared after the restart")

    -- The reservation ledger was RESTORED, not recreated: still exactly one entry,
    -- and the owner aggregate is unchanged -- the in-flight reservation is intact
    -- without any re-reserve against (possibly depleted) hardware.
    local ledgerAfter = count_table_values(m2.state.reserved_ledger)
    ok(ledgerAfter == 1, "P3.8 the reservation ledger was restored (still one entry, no double-reserve)")
    ok(m2.state.reserved[OWNER] == resBeforeRestart,
        "P3.9 the owner aggregate reservation is unchanged across the restart")
    ok(seqBeforeRestart == m2.state.sequence,
        "P3.10 the sequence counter was preserved across the restart")
end

--------------------------------------------
-- TEST P4: Idempotent replay after a restart does NOT double-reserve
--------------------------------------------
print("\n[TEST P4] Idempotent replay after a restart does not double-reserve")

do
    local m1 = new_module()
    local created = m1.printers_request({
        api_version = 1,
        client_request_id = "job-1",
        count = 5,
        item = "IronBar",
        family_id = 1,
        cost_vector = { Iron = 2 },
    }, OWNER)
    local taskId = created.task_id

    local m2 = new_module()

    -- A client that retries the SAME request after the restart must get the same
    -- task (idempotency map was restored), not a fresh reservation.
    local replay = m2.printers_request({
        api_version = 1,
        client_request_id = "job-1",
        count = 5,
        item = "IronBar",
        family_id = 1,
        cost_vector = { Iron = 2 },
    }, OWNER)
    ok(replay and replay.replayed == true,
        "P4.1 a client retry after restart replays the original task")
    ok(replay and replay.task_id == taskId,
        "P4.2 the replay returns the original task id (not a new one)")
    ok(count_table_values(m2.state.tasks) == 1, "P4.3 no second task was created")
    ok(count_table_values(m2.state.reserved_ledger) == 1,
        "P4.4 no second reservation was made (idempotency map survived the restart)")
end

--------------------------------------------
-- TEST P5: A mid-flight ACTIVE task survives a restart in place
--------------------------------------------
print("\n[TEST P5] A mid-flight active task survives a restart")

do
    ctx.store = {}
    ctx.handlers = nil

    local m5 = new_module()
    m5.state.native_enabled = true
    m5.state.native_commissioned = true
    local created = m5.printers_request({
        api_version = 1,
        client_request_id = "job-5",
        count = 3,
        item = "IronBar",
        family_id = 1,
        cost_vector = { Iron = 2 },
    }, OWNER)
    local taskId = created.task_id

    -- Drive the task from queued to active; service_tasks checkpoints at the end.
    m5.service_tasks()
    ok(m5.state.tasks[taskId] and m5.state.tasks[taskId].state == "active",
        "P5.1 service_tasks moved the task to active")
    ok(m5.state.active_task_by_printer["autolathe-ref"] == taskId,
        "P5.2 the printer is marked busy with the in-flight task")
    ok(type(ctx.store["persist:" .. PERSISTENCE_KEY]) == "string",
        "P5.3 the active task was checkpointed to ic.persist")

    -- Restart: the in-flight job and its active invariant come back exactly.
    local m5b = new_module()
    ok(m5b.state.tasks[taskId] ~= nil, "P5.4 the active task survived the restart")
    ok(m5b.state.tasks[taskId].state == "active",
        "P5.5 the task recovered as active, not rebuilt from scratch")
    ok(m5b.state.active_task_by_printer["autolathe-ref"] == taskId,
        "P5.6 the active-per-printer invariant survived the restart (job still held)")
    ok(count_table_values(m5b.state.tasks) == 1,
        "P5.7 no duplicate task after the active restart")
    ok(count_table_values(m5b.state.reserved_ledger) == 1,
        "P5.8 no double-reserve of the in-flight job after the restart")
end

--------------------------------------------
-- TEST P6: A schema-mismatched snapshot is refused without corruption
--------------------------------------------
print("\n[TEST P6] A schema-mismatched snapshot is refused without corruption")

do
    ctx.store = {}
    local bad = json.encode({
        controller_schema_version = 999,
        task_order = { "stale-task" },
        tasks = {
            ["stale-task"] = { task_id = "stale-task", state = "queued" },
        },
    })
    ctx.store["persist:" .. PERSISTENCE_KEY] = bad

    -- A controller version whose durable shape no longer matches.
    ctx.handlers = nil
    local m6 = new_module()

    ok(count_table_values(m6.state.tasks) == 0,
        "P6.1 a schema-mismatched snapshot did not restore any tasks")
    ok(m6.state.errors_seen > 0, "P6.2 the schema mismatch was logged as an error")
    -- The schema mismatch only refuses the STALE snapshot; the chip itself still
    -- boots catalog-free and can serve a fresh request (proof the boot is clean,
    -- not that any catalog revision was adopted).
    local fresh = m6.printers_request({
        api_version = 1,
        client_request_id = "fresh-after-bad",
        count = 1,
        item = "IronBar",
        family_id = 1,
        cost_vector = { Iron = 2 },
    }, OWNER)
    ok(fresh and fresh.ok == true and fresh.task_id ~= nil,
        "P6.3 the controller booted clean despite the stale, incompatible blob")
end

--------------------------------------------
-- TEST P7: Cancel is journaled + survives a restart with its release
--------------------------------------------
print("\n[TEST P7] Cancel is journaled and survives a restart")

do
    ctx.store = {}
    ctx.handlers = nil

    local m7 = new_module()
    local created = m7.printers_request({
        api_version = 1,
        client_request_id = "job-7",
        count = 5,
        item = "IronBar",
        family_id = 1,
        cost_vector = { Iron = 2 },
    }, OWNER)
    local taskId = created.task_id
    ok(count_table_values(m7.state.reserved_ledger) == 1,
        "P7.1 pre-cancel there is one active reservation ledger entry")

    local cancelled = m7.printers_cancel(
        { task_id = taskId, api_version = 1, owner = OWNER }, OWNER)
    ok(cancelled and cancelled.ok == true, "P7.2 the task was cancelled")
    local ledgerAfterCancel = count_table_values(m7.state.reserved_ledger)
    ok(ledgerAfterCancel == 0,
        "P7.3 cancellation released its ledger entry on the source chip")
    ok(m7.state.tasks[taskId] and m7.state.tasks[taskId].state == "cancelled",
        "P7.4 the task recorded as cancelled and was checkpointed")

    -- Restart: the cancel + release must already have been flushed durably.
    local m7b = new_module()
    ok(m7b.state.tasks[taskId] and m7b.state.tasks[taskId].state == "cancelled",
        "P7.5 the cancelled task survived the restart as cancelled")
    ok(count_table_values(m7b.state.reserved_ledger) == 0,
        "P7.6 the ledger release survived the restart (no orphaned reservation)")
end

--------------------------------------------
-- TEST P8: A reached task requests storage (aggregated), journaled before send
--------------------------------------------
print("\n[TEST P8] A reached task requests storage (aggregated), journaled before send")

do
    ctx.store = {}
    ctx.handlers = nil

    local m8 = new_module()
    local created = m8.printers_request({
        api_version = 1,
        client_request_id = "job-8",
        count = 3,
        item = "IronBar",
        family_id = 1,
        cost_vector = { Iron = 2 },
    }, OWNER)
    ok(created and created.ok == true, "P8.1 the task was created")
    local taskId = created.task_id

    -- Drive the queue once: a reached task is pulled to active and the
    -- controller requests the AGGREGATED quantity from storage once. The
    -- storage line itself is not mocked here, so the external send is a guarded
    -- no-result; what we lock is that the controller COMPUTED the aggregate
    -- and journaled the intent durably BEFORE the external send, so a halt
    -- between "reached" and "delivered" recovers the request without re-aggregating.
    m8.service_tasks()

    ok(m8.state.tasks[taskId] and m8.state.tasks[taskId].state == "active",
        "P8.2 a reached task is active after one service pass")

    -- The aggregated storage request was journaled (durable, before the send).
    local saw_storage_request, saw_qty = false, nil
    for _, entry in ipairs(m8.state.journal or {}) do
        if entry.op == "storage_request" then
            saw_storage_request = true
            saw_qty = entry.quantity
            ok(entry.reservation_id ~= nil,
                "P8.3 the storage-request entry carried the reservation id")
        end
    end
    ok(saw_storage_request, "P8.4 a reached task journaled its storage request")
    ok(saw_qty == 3, "P8.5 the journaled storage request carried the item count (3)")

    -- The controller aggregated per-item x count on the source chip: 2 x 3 = 6.
    ok(m8.state.reserved[OWNER] == 6,
        "P8.6 the controller-side aggregate is per-item x count = 6 on the owner")
end

--------------------------------------------
print(string.rep("-", 60))
print(string.format("Printer persistence: %d passed, %d failed", pass, fail))
if fail > 0 then
    os.exit(1)
else
    print("All printer persistence checks passed.")
end
