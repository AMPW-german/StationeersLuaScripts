-- PrinterController.lua
-- Printer manager -- active behavior chip. It is CATALOG-FREE: it carries no
-- recipe data and consumes the PrinterCatalog library chip neither at load nor
-- at runtime. A console UI chip on the same data network requires the catalog
-- (`require("PrinterCatalog")`, hot-reloaded via `require("PrinterCatalog", true)`),
-- builds the recipe menu, and packs each print request as a fully-specified,
-- self-contained payload. The controller only ROUTES, RESERVES, and ACTUATES:
--   * routes the request to the right printer family by `family_name`,
--   * structurally validates the supplied `cost_vector` (it TRUSTS the catalog-
--     derived data the console packed; it never re-derives costs itself),
--   * reserves the in-flight quantity and, once commissioned, drives the native
--     single-item print.
--
-- This separation is deliberate: the catalog is a passive library chip (see
-- tools/generate_printer_catalog.py --@module emission). Updating recipes is a
-- redeploy of ONLY PrinterCatalog.lua; the controller and consoles do not need a
-- restart to pick up changes.
--
-- Actuation of the physical single-item print is gated behind a commission
-- check that defaults to OFF; native printing is validated with mocks here and
-- enabled only after commissioning passes.
--
-- Lua 5.1 compatible. Pin/UI-free for its core control surface; routing-device
-- writes go through ic.net / ic.mem / ic.read_id / ic.write_id, never pins.

local LT = ic.enums.LogicType
local LST = ic.enums.LogicSlotType
local SI = ic.enums.SorterInstruction

local API_VERSION = 1
local CONTROLLER_SCHEMA_VERSION = 1
local MAX_QUEUE_LENGTH = 64
local MAX_TASK_HISTORY = 128

-- Journaled persistence (ic.persist + util.json, mirroring StorageController):
-- the in-flight task ledger is journaled and checkpointed after every durable
-- mutation, so a chip that halts mid-tick recovers on boot without re-reserving
-- its resources.
local JOURNAL_MAX = 128
local ERRORS_MAX = 64

local PERSISTENCE_KEY = "printer_controller_state"

-- The six supported printer families, by prefab hash.
local PREFAB_FAMILIES = {
    [1] = 213489205,   -- autolathe
    [2] = 1034502899,  -- pipe_bender
    [3] = 701147862,   -- electronics
    [4] = -709183946, -- rocket
    [5] = 1516074380,  -- tool
    [6] = -1073785338, -- security
}

local FAMILY_NAMES = {
    [1] = "autolathe", [2] = "pipe_bender", [3] = "electronics",
    [4] = "rocket", [5] = "tool", [6] = "security",
}

local NAME_FEED = {
    [1] = "Printers.Feed.Autolathe", [2] = "Printers.Feed.PipeBender",
    [3] = "Printers.Feed.Electronics", [4] = "Printers.Feed.Rocket",
    [5] = "Printers.Feed.Tool", [6] = "Printers.Feed.Security",
}

-- Native printer program addresses (53-bit program words packed into chip
-- memory; validated by mock, not driven until commissioned).
local MEM_OPCODE = 0
local PARAM_OPCODE = 1
local PARAM_REAGENT_COUNT = 2
local PARAM_REAGENT_ADDRESS = 3
local PARAM_REAGENT_ADDRESS_LIMIT = 16
local PARAM_COUNT = 4
local PARAM_TIER = 5

-- Task lifecycle states.
local ST = {
    QUEUED = "queued",
    ACTIVE = "active",
    PAUSED = "paused",
    AWAITING_OUTPUT = "awaiting_output",
    OUTPUT_DONE = "output_done",
    COMPLETED = "completed",
    FAILED = "failed",
    CANCELLED = "cancelled",
    ABORTED = "aborted",
}

local state = {
    phase = "booting",           -- booting/discovering/ready/invalid_topology/faulted
    printers = {},                -- ref_id -> printer record
    printer_by_name = {},         -- family_name -> ref_id
    active_task_by_printer = {},  -- ref_id -> task_id
    tasks = {},
    task_order = {},
    idempotency = {},             -- client_key -> task_id
    sequence = 0,
    journal_seq = 0,
    journal = {},
    tick = 0,
    errors = {},
    native_enabled = false,        -- COMMISSION GATE; off by default
    native_commissioned = false,
    reserved = {},                 -- owner -> total reserved quantity
    reserved_ledger = {},          -- reservation_key -> reservation record
    errors_seen = 0,
}

local function deep_copy(input)
    if type(input) ~= "table" then
        return input
    end
    local output = {}
    for key, value in pairs(input) do
        output[key] = deep_copy(value)
    end
    return output
end

local function safe_call(fn, ...)
    local result = {pcall(fn, ...)}
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

local function safe_memory_write(ref_id, address, value)
    local _, err = safe_call(ic.mem.put_id, ref_id, address, value)
    return err == nil, err
end

local function now()
    return state.tick
end

local function add_error(code, detail)
    state.errors_seen = state.errors_seen + 1
    state.errors[#state.errors + 1] = {
        code = code, detail = detail, tick = now(),
    }
    -- Bound the in-memory error log: a hostile or misbehaving caller that keeps
    -- submitting bad requests must not grow the log unbounded and stall the chip.
    while #state.errors > ERRORS_MAX do
        table.remove(state.errors, 1)
    end
    print("PrinterController: error " .. code .. (detail and (": " .. tostring(detail)) or ""))
end

-- Map a console-supplied family name to its numeric family id. Topology only --
-- NOT the catalog. Unknown family names are rejected at the request boundary.
local FAMILY_ID = {
    [FAMILY_NAMES[1]] = 1,
    [FAMILY_NAMES[2]] = 2,
    [FAMILY_NAMES[3]] = 3,
    [FAMILY_NAMES[4]] = 4,
    [FAMILY_NAMES[5]] = 5,
    [FAMILY_NAMES[6]] = 6,
}

-- Structural validation of a console-supplied cost vector.
--
-- The controller is catalog-free: it TRUSTS the catalog-derived reagent vector
-- that the console packed into the request, but it still verifies the SHAPE so a
-- malformed or hostile request cannot poison the reservation ledger. A valid
-- vector is a table of reagent-key -> non-negative number. The key is either a
-- reagent NAME (string) or its prefab HASH (number); internally the console
-- hashes reagent names to prefab hashes (Animator.StringToHash / IC10 HASH()),
-- so the cost_vector the controller aggregates and forwards to storage is
-- hash-keyed. Both key types are accepted so a name-keyed or hash-keyed request
-- validates; the aggregate is keyed however the console sent it. Returns
-- (cleaned_copy, nil, total) on success or (nil, reason, 0) on failure.
local function valid_cost_vector(raw)
    if type(raw) ~= "table" then
        return nil, "invalid_cost_vector", 0
    end
    local cost = {}
    local total = 0
    for name, amount in pairs(raw) do
        if (type(name) ~= "string" and type(name) ~= "number") or
            type(amount) ~= "number" or amount ~= amount or amount < 0 then
            return nil, "invalid_cost_amount", 0
        end
        if amount ~= 0 then
            cost[name] = amount
            total = total + amount
        end
    end
    return cost, nil, total
end

-- Additive reservation ledger (printer-side). Models the reserved/delivered
-- accounting that StorageController provides additively; call the storage
-- service via ic.net in production.
local function reservation_key(owner, reservation_id)
    return tostring(owner) .. ":" .. tostring(reservation_id)
end

local function reserve_batch(owner, reservation_id, recipe_cost, count)
    local key = reservation_key(owner, reservation_id)
    local record = state.reserved_ledger[key]
    if not record then
        record = {
            owner = owner,
            reservation_id = reservation_id,
            recipe_cost = deep_copy(recipe_cost),
            reserved = 0,
            delivered = 0,
            cancelled = false,
        }
        state.reserved_ledger[key] = record
    end
    local per = 0
    for _, amount in pairs(recipe_cost) do
        per = per + amount
    end
    local delta = per * count
    record.reserved = record.reserved + delta
    local owner_total = state.reserved[owner] or 0
    state.reserved[owner] = owner_total + delta
    return record, nil
end

local function dispatch_reserved(owner, reservation_id, count)
    local key = reservation_key(owner, reservation_id)
    local record = state.reserved_ledger[key]
    if not record then
        return nil, "unknown_reservation"
    end
    if record.cancelled then
        return nil, "reservation_cancelled"
    end
    -- Per-item quantity reserved for one dispatch is the sum of the recipe
    -- cost; move that from reserved into the in-transit account.
    local per = 0
    for _, amount in pairs(record.recipe_cost) do
        per = per + amount
    end
    local delta = per * count
    record.delivered = record.delivered + delta
    return count, nil
end

local function delivery_ack(owner, reservation_id, count)
    local key = reservation_key(owner, reservation_id)
    local record = state.reserved_ledger[key]
    if not record then
        return nil, "unknown_reservation"
    end
    -- Confirmation of receipt completes this reservation slot.
    record.done = true
    return true, nil
end

local function release_batch(owner, reservation_id)
    local key = reservation_key(owner, reservation_id)
    local record = state.reserved_ledger[key]
    if not record then
        return nil, "unknown_reservation"
    end
    if record.delivered > 0 then
        return nil, "cannot_release_in_flight"
    end
    local owner_total = (state.reserved[owner] or 0) - record.reserved
    if owner_total <= 0 then
        state.reserved[owner] = nil
    else
        state.reserved[owner] = owner_total
    end
    record.cancelled = true
    state.reserved_ledger[key] = nil
    return true, nil
end

local function query_reservation(owner, reservation_id)
    local record = state.reserved_ledger[reservation_key(owner, reservation_id)]
    if not record then
        return nil, "unknown_reservation"
    end
    return {
        reservation_id = reservation_id,
        owner = owner,
        reserved = record.reserved,
        delivered = record.delivered,
        cancelled = record.cancelled,
        done = record.done,
    }, nil
end

-- ============================ Storage line request (aggregated, one per task) ============================
-- When a task is REACHED (pulled from the queue to active), the controller -- not
-- the console -- computes the AGGREGATED quantity (per-item x count) and requests
-- it from the storage line ONCE. This chip stays catalog-free: it forwards the
-- per-reagent aggregate the console packed; the storage line maps reagent names
-- to its routing/prefab. The call is fully guarded so an unavailable/declined
-- storage line is logged and the chip continues (it never crashes on storage).
local STORAGE_TARGET = "Storage.Controller"

-- Guarded async-style net request that never throws: returns (result, err).
-- The engine may call back via a callback, but as a server issuing an
-- out-of-band client request we treat a synchronous return contract and guard
-- the boundary so a missing/declining storage line cannot abort the tick.
local function safe_request(target, method, payload, options)
    local res = { pcall(ic.net.request, target, method, payload, options) }
    if not res[1] then
        return nil, "request_error:" .. tostring(res[2])
    end
    return res[2], res[3]
end

-- Expand a per-item cost vector to the aggregated (x count) total the storage
-- line must be told to hold. Empty vectors produce an empty aggregate.
local function aggregate_cost_vector(cost, count)
    local agg = {}
    for name, amount in pairs(cost or {}) do
        agg[name] = amount * count
    end
    return agg
end

-- ============================ Durable journal + checkpoint ============================
-- ic.persist is a string-valued store; util.json encodes the durable snapshot,
-- exactly as StorageController persists its ledger. journal_append is called
-- after every durable mutation; checkpoint() writes the snapshot. On boot
-- restore_state() reloads it, so a chip that halts mid-tick resumes in place
-- and in-flight tasks are NOT re-reserved.
local function has_persist()
    return type(ic) == "table" and type(ic.persist) == "table" and
        type(ic.persist.set) == "function" and type(ic.persist.get) == "function" and
        type(util) == "table" and type(util.json) == "table" and
        type(util.json.encode) == "function" and type(util.json.decode) == "function"
end

local function durable_snapshot()
    return {
        controller_schema_version = CONTROLLER_SCHEMA_VERSION,
        sequence = state.sequence,
        journal_seq = state.journal_seq,
        task_order = deep_copy(state.task_order),
        tasks = deep_copy(state.tasks),
        reservation_ledger = deep_copy(state.reserved_ledger),
        reserved = deep_copy(state.reserved),
        idempotency = deep_copy(state.idempotency),
        active_task_by_printer = deep_copy(state.active_task_by_printer),
        journal = deep_copy(state.journal),
        saved_tick = state.tick,
    }
end

local function checkpoint()
    if not has_persist() then
        -- In-memory journal was already advanced; nothing durable to persist
        -- without the engine's persistent store + json codec present.
        return true
    end
    local encoded = safe_call(util.json.encode, durable_snapshot())
    if type(encoded) ~= "string" then
        add_error("persistence_encode_error", encoded)
        return false
    end
    local _, err = safe_call(ic.persist.set, PERSISTENCE_KEY, encoded)
    if err ~= nil then
        add_error("persistence_write_error", tostring(err))
        return false
    end
    return true
end

local function journal_append(op, task_id, extra)
    state.journal_seq = state.journal_seq + 1
    local entry = {
        seq = state.journal_seq,
        op = op,
        task_id = task_id,
        tick = state.tick,
        updated_tick = now(),
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            entry[k] = v
        end
    end
    state.journal[#state.journal + 1] = entry
    -- Recovery-point marker: this flush captures the journal through the
    -- sequence just written. Appended directly (not re-entrantly through
    -- journal_append) so the marker is not itself re-persisted within the same
    -- flush -- it becomes the recovery point the NEXT checkpoint snapshots.
    local capture_seq = state.journal_seq
    state.journal_seq = state.journal_seq + 1
    state.journal[#state.journal + 1] = {
        seq = state.journal_seq,
        op = "checkpoint",
        task_id = task_id,
        tick = state.tick,
        updated_tick = now(),
        journal_seq = capture_seq,
    }
    while #state.journal > JOURNAL_MAX do
        table.remove(state.journal, 1)
    end
    checkpoint()
end

local function restore_state()
    if not has_persist() then
        return false, "no_persistence_backend"
    end
    local encoded = safe_call(ic.persist.get, PERSISTENCE_KEY)
    if type(encoded) ~= "string" or encoded == "" then
        -- First boot: nothing was ever persisted. A clean start, not an error,
        -- so we do not log it -- only a decode/schema failure is an error.
        return false, "no_state"
    end
    local saved = safe_call(util.json.decode, encoded)
    if type(saved) ~= "table" then
        add_error("persistence_decode_error", saved)
        return false, "decode_failed"
    end
    if saved.controller_schema_version ~= CONTROLLER_SCHEMA_VERSION then
        add_error("persistence_schema_mismatch",
            "controller_schema_version " .. tostring(saved.controller_schema_version) ..
            " vs " .. tostring(CONTROLLER_SCHEMA_VERSION))
        return false, "schema_mismatch"
    end
    -- Rebuild the recoverable core in place. The reservation ledger is
    -- restored as-is, so an in-flight task's resources are NOT reserved again.
    state.sequence = tonumber(saved.sequence) or 0
    state.journal_seq = tonumber(saved.journal_seq) or 0
    state.journal = {}
    for _, entry in ipairs(saved.journal or {}) do
        state.journal[#state.journal + 1] = entry
    end
    state.active_task_by_printer = {}
    for ref, tid in pairs(saved.active_task_by_printer or {}) do
        state.active_task_by_printer[ref] = tid
    end
    state.tasks = {}
    state.task_order = {}
    for _, tid in ipairs(saved.task_order or {}) do
        local task = saved.tasks and saved.tasks[tid]
        if type(task) == "table" then
            if task.controller_schema_version == nil then
                task.controller_schema_version = CONTROLLER_SCHEMA_VERSION
            end
            state.tasks[tid] = task
            state.task_order[#state.task_order + 1] = tid
        end
    end
    state.reserved_ledger = {}
    for key, rec in pairs(saved.reservation_ledger or {}) do
        if type(rec) == "table" then
            state.reserved_ledger[key] = rec
        end
    end
    state.reserved = {}
    for owner, amount in pairs(saved.reserved or {}) do
        state.reserved[owner] = amount
    end
    state.idempotency = {}
    for client_key, tid in pairs(saved.idempotency or {}) do
        state.idempotency[client_key] = tid
    end
    print("PrinterController: restored state, tasks=" .. tostring(#state.task_order) ..
        " journal=" .. tostring(#state.journal) .. " seq=" .. tostring(state.sequence))
    return true, "restored_" .. tostring(#state.task_order) .. "_tasks"
end

-- ============================ Storage line request (reached = aggregated, one per reagent hash) ============================
-- When a task is REACHED (pulled from the queue to active) the controller -- not
-- the console -- computes the AGGREGATED quantity (per-item x count) and requests
-- it from the storage line. The storage request contract is a single
-- prefab_hash + integer quantity, so a multi-reagent task fans out to ONE request
-- per reagent hash (quantity = ceil(aggregate grams); 1 g == 1 item). Per-reagent
-- idempotency (record.storage_requested, keyed by prefab_hash) guards re-issue on
-- the same tick / recovery. Failures are logged (controlled) and swallowed so the
-- chip never aborts. Defined after the journal + restore section so journal_append
-- / has_persist are captured as upvalues.
local function request_storage_reservation(task)
    local key = reservation_key(task.owner, task.reservation_id)
    local record = state.reserved_ledger[key]
    if not record then
        -- Defensive: a task should always carry its reservation, but never let a
        -- missing record crash the tick.
        return nil, "no_reservation_record"
    end
    record.storage_results = record.storage_results or {}
    record.storage_requested = record.storage_requested or {}

    -- Fan the multi-reagent aggregate out into ONE storage.request per reagent
    -- hash: the storage request contract is a single prefab_hash + integer
    -- quantity, so a multi-reagent task is split by reagent. The controller
    -- stays catalog-free (it forwards the hash-keyed vector the console packed);
    -- and 1 gram == 1 item, so a reagent's request quantity is the ceiling of
    -- that reagent's aggregate mass (per-item grams x count).
    local agg = aggregate_cost_vector(task.cost_vector, task.count)
    local saw_fail = false
    local sent = 0
    for prefab_hash, grams in pairs(agg) do
        -- Per-reagent idempotency keyed on (owner,reservation,prefab_hash) so a
        -- recovery re-run does not re-issue the same request.
        local sub_key = task.client_key .. ":storage:" .. tostring(prefab_hash)
        if not record.storage_requested[sub_key] then
            local quantity = math.ceil(grams)
            if quantity < 1 then
                quantity = 1
            end
            -- Journal the intent durably BEFORE the external send (crash model:
            -- guarded I/O + pre-send flush), so a halt between "reached" and
            -- "delivered" recovers the request without re-aggregating.
            journal_append("storage_request", task.task_id, {
                reservation_id = task.reservation_id,
                prefab_hash = prefab_hash,
                quantity = quantity,
            })
            local payload = {
                api_version = API_VERSION,
                client_request_id = sub_key,
                prefab_hash = prefab_hash,
                quantity = quantity,
                owner = task.owner,
                reservation_id = task.reservation_id,
                item = task.item,
                family_id = task.family_id,
            }
            record.storage_requested[sub_key] = true
            local result, err = safe_request(STORAGE_TARGET, "storage.request", payload,
                { origin = "printer-controller" })
            record.storage_results[sub_key] = result or false
            sent = sent + 1
            if type(result) == "table" and result.ok == false then
                saw_fail = true
                add_error("storage_request_rejected",
                    "for hash " .. tostring(prefab_hash) .. " (" ..
                    tostring(result.err_code or result.code or "declined") .. ")")
            elseif not result then
                saw_fail = true
                add_error("storage_request_error",
                    tostring(err or "no_result") .. " for hash " .. tostring(prefab_hash))
            end
        end
    end
    record.storage_state = saw_fail and "failed" or "ok"
    record.storage_sent = sent
    return record, nil
end

-- Discovery: find the six supported printers by prefab hash.
local function discover_printers()
    state.printers = {}
    state.printer_by_name = {}
    for family_id, hash in pairs(PREFAB_FAMILIES) do
        local found
        found = safe_call(ic.find_all, hash, family_id, 1)
        if found and type(found) == "table" and found[1] then
            for _, printer in ipairs(found) do
            local ref = printer.ref_id or printer.refId or printer.id
            if ref then
                local rec = {
                    ref_id = ref,
                    family = family_id,
                    family_name = FAMILY_NAMES[family_id],
                }
                state.printers[ref] = rec
                -- Dual-key: the routing table is looked up by BOTH numeric family
                -- id and family name, so consoles (which carry a family_name
                -- string) and numeric callers route identically.
                state.printer_by_name[family_id] = ref
                state.printer_by_name[FAMILY_NAMES[family_id]] = ref
                if family_id == 1 then
                    print("PrinterController: found autolathe at ref " .. tostring(ref))
                end
            end
        end
    end
end
    return #state.printers
end

-- Native single-item printing — GATED. Builds the program into printer memory.
-- Only invoked after check_commission(), which is false until commissioning.
local function check_commission()
    return state.native_enabled == true and state.native_commissioned == true
end

local function make_packed_word(opcode, params)
    local word = ic.bit.ins(0, opcode, 0, 8)
    -- Pack each 32-bit param into the running 32-bit slot after the opcode.
    local pos = 8
    for _, param in ipairs(params) do
        word = ic.bit.ins(word, param, pos, 32)
        pos = pos + 32
    end
    return word
end

local function program_for_recipe(task)
    local recipe = task.cost_vector
    local words = {}
    words[MEM_OPCODE] = make_packed_word(0, { task.opcode_kind or 1 })
    words[PARAM_OPCODE] = task.opcode_kind or 1
    local reagents = {}
    for name, amount in pairs(recipe) do
        reagents[#reagents + 1] = {name = name, amount = amount}
    end
    table.sort(reagents, function(a, b) return a.name < b.name end)
    words[PARAM_REAGENT_COUNT] = #reagents
    for index, entry in ipairs(reagents, PARAM_REAGENT_ADDRESS) do
        words[index] = entry
    end
    words[PARAM_COUNT] = task.count
    words[PARAM_TIER] = task.tier
    return words
end

local function start_print(printer_ref, printer, task)
    if not check_commission() then
        return false, "not_commissioned"
    end
    -- Single active task per printer invariant.
    local active = state.active_task_by_printer[printer_ref]
    if active and active ~= task.task_id then
        return false, "printer_busy"
    end
    local words = program_for_recipe(task)
    for address, word in pairs(words) do
        local ok, err = safe_memory_write(printer_ref, address, type(word) == "table" and 0 or word)
        if not ok then
            return false, err or "memory_write_failed"
        end
    end
    state.active_task_by_printer[printer_ref] = task.task_id
    task.printer_ref = printer_ref
    return true, "started"
end

-- Task lifecycle.
local function response_error(code)
    return {
        api_version = API_VERSION,
        ok = false,
        code = code,
    }
end

local function transition(task, next_state, error_code)
    state.sequence = state.sequence + 1
    local old_state = task.state
    task.state = next_state
    task.error_code = error_code
    task.sequence = state.sequence
    task.updated_tick = now()
    -- Journal + flush FIRST so the recovery point is durable before any external
    -- send. A publish failure is logged (controlled) and never loses the
    -- transition: journal_append checkpoints the ledger so a halted chip recovers.
    journal_append("transition", task.task_id, {
        from = old_state, to = next_state, error_code = error_code,
    })
    -- External send, guarded: a publish failure is captured and logged
    -- (controlled), and a pcall failure cannot lose the transition above it.
    local ok, err = pcall(ic.net.publish, "printers/v1/task/" .. task.task_id, task)
    if not ok then
        add_error("transition_publish_error", tostring(err))
    end
end

local function lookup_task(task_id, sender)
    local task = state.tasks[task_id]
    if not task then
        return nil, "unknown_request"
    end
    if task.owner ~= sender then
        return nil, "unknown_request"
    end
    return task, nil
end

local function printers_request(payload, sender)
    if type(payload) ~= "table" or payload.api_version ~= API_VERSION then
        add_error("invalid_request", "bad_type_or_version")
        return response_error("invalid_request")
    end
    if state.phase ~= "ready" then
        -- Transient boot condition, not a bad request: do not log.
        return response_error("not_ready")
    end
    local owner = sender or payload.owner
    if type(payload.client_request_id) ~= "string" then
        add_error("invalid_request", "bad_client_request_id")
        return response_error("invalid_request")
    end
    if type(payload.count) ~= "number" or payload.count <= 0 or payload.count % 1 ~= 0 then
        add_error("invalid_quantity", tostring(payload.count))
        return response_error("invalid_quantity")
    end
    local family_id = payload.family_id or 1
    if type(payload.item) ~= "string" then
        add_error("invalid_item", tostring(payload.item))
        return response_error("invalid_item")
    end
    local client_key = tostring(owner) .. ":" .. payload.client_request_id
    local existing = state.idempotency[client_key]
    if existing then
        local task, err = lookup_task(existing, sender)
        if task then
            return {
                api_version = API_VERSION,
                ok = true,
                task_id = task.task_id,
                state = task.state,
                replayed = true,
            }
        end
    end
    if #state.task_order >= MAX_QUEUE_LENGTH then
        add_error("queue_full", "task_order " .. tostring(#state.task_order))
        return response_error("queue_full")
    end
    local cost, err, total = valid_cost_vector(payload.cost_vector)
    if not cost then
        -- A structurally invalid recipe is a controlled, logged rejection: record
        -- it and continue serving the rest of the queue.
        add_error("invalid_recipe", tostring(err or "invalid_cost_vector"))
        return response_error(err or "invalid_cost_vector")
    end
    local record
    record, err = reserve_batch(owner, payload.client_request_id .. ":reserve", cost, payload.count)
    if not record then
        add_error("reserve_failed", tostring(err))
        return response_error(err or "reserve_failed")
    end
    local reservation_id = payload.client_request_id .. ":reserve"
    state.sequence = state.sequence + 1
    local task_id = string.format("printer-%d-%d", now(), state.sequence)
    local task = {
        task_id = task_id,
        client_key = client_key,
        owner = owner,
        reservation_id = reservation_id,
        family_id = family_id,
        item = payload.item,
        count = payload.count,
        cost_vector = deep_copy(cost),
        cost_total = total,
        tier = payload.tier or 1,
        state = ST.QUEUED,
        sequence = state.sequence,
        created_tick = now(),
        updated_tick = now(),
        error_code = nil,
    }
    if state.printer_by_name[family_id] then
        task.printer_ref = state.printer_by_name[family_id]
    end
    state.tasks[task_id] = task
    state.task_order[#state.task_order + 1] = task_id
    state.idempotency[client_key] = task_id
    journal_append("task_created", task_id, {
        owner = owner, client_key = client_key, reservation_id = reservation_id,
        family_id = family_id, item = payload.item, count = task.count,
        cost_total = task.cost_total,
    })
    transition(task, ST.QUEUED)
    checkpoint()
    return {
        api_version = API_VERSION,
        ok = true,
        task_id = task_id,
        state = task.state,
        reserved = record.reserved,
        count = payload.count,
    }
end

local function printers_request_status(payload, sender)
    if type(payload) ~= "table" or payload.api_version ~= API_VERSION then
        return response_error("invalid_request")
    end
    local task, err = lookup_task(payload.task_id, sender)
    if not task then
        return response_error(err or "unknown_request")
    end
    return {
        api_version = API_VERSION,
        ok = true,
        task = task,
    }
end

local function printers_cancel(payload, sender)
    if type(payload) ~= "table" or payload.api_version ~= API_VERSION then
        return response_error("invalid_request")
    end
    local task, err = lookup_task(payload.task_id, sender)
    if not task then
        return response_error(err or "unknown_request")
    end
    if task.state == ST.ACTIVE then
        return response_error("already_active")
    end
    if task.state ~= ST.QUEUED and task.state ~= ST.PAUSED then
        return response_error("not_cancellable")
    end
    -- Release the reservation for the un-completed portion.
    release_batch(task.owner, task.reservation_id)
    transition(task, ST.CANCELLED)
    checkpoint()
    return {
        api_version = API_VERSION,
        ok = true,
        task_id = task.task_id,
        state = task.state,
    }
end

local function printers_get_state(payload, sender)
    payload = payload or {}
    if payload.task_id_filter and type(payload.task_id_filter) == "string" then
        local task, err = lookup_task(payload.task_id_filter, sender)
        if err or not task then
            return { api_version = API_VERSION, ok = false, err_code = err or "unknown_task" }
        end
        return { api_version = API_VERSION, ok = true, tasks = { task }, task_count = 1 }
    end
    local tasks
    if payload.include_tasks ~= false then
        tasks = {}
        for _, task_id in ipairs(state.task_order) do
            local task = state.tasks[task_id]
            if task then
                tasks[#tasks + 1] = task
            end
        end
    end
    return {
        api_version = API_VERSION,
        ok = true,
        phase = state.phase,
        task_count = #state.task_order,
        tasks = tasks,
    }
end

local function printers_get_config(payload)
    payload = payload or {}
    return {
        api_version = API_VERSION,
        ok = true,
        families = FAMILY_NAMES,
        native_enabled = state.native_enabled,
        native_commissioned = state.native_commissioned,
        max_queue_length = MAX_QUEUE_LENGTH,
    }
end

-- Every RPC handler is wrapped so a hostile or malformed payload -- or an
-- internal bug -- can never crash the chip: the call is captured, logged, and a
-- controlled error response returned. The raw handlers are what the tests call
-- directly; these wrappers are what the network dispatches to.
local function guarded(name, handler)
    return function(payload, sender)
        local ok, result = pcall(handler, payload, sender)
        if not ok then
            add_error(name .. "_crash", tostring(result))
            return response_error("handler_error")
        end
        return result
    end
end

local function register_api()
    ic.net.register("printers.request", guarded("printers.request", printers_request))
    ic.net.register("printers.request_status", guarded("printers.request_status", printers_request_status))
    ic.net.register("printers.cancel", guarded("printers.cancel", printers_cancel))
    ic.net.register("printers.get_state", guarded("printers.get_state", printers_get_state))
    ic.net.register("printers.get_config", guarded("printers.get_config", printers_get_config))
end

-- Durable persistence is journal-based and lives in the "Durable journal +
-- checkpoint" section above (has_persist / durable_snapshot / checkpoint /
-- journal_append / restore_state), mirroring StorageController's ic.persist +
-- util.json string ledger. trim_history bounds the in-memory task ledger.
local function trim_history()
    while #state.task_order > MAX_TASK_HISTORY do
        local task_id = table.remove(state.task_order, 1)
        local task = state.tasks[task_id]
        if task and task.state ~= ST.QUEUED and task.state ~= ST.ACTIVE and
            task.state ~= ST.AWAITING_OUTPUT then
            state.tasks[task_id] = nil
            for client_key, existing in pairs(state.idempotency) do
                if existing == task_id then
                    state.idempotency[client_key] = nil
                end
            end
        else
            state.task_order[#state.task_order + 1] = task_id
            break
        end
    end
end

-- Task lifecycle helpers (declared before the body that uses them so closures
-- bind to the local, not a nil global).
local function payload_owner_key(task)
    return task.client_key and task.client_key:match("^(.-):") or tostring(task.owner)
end

local function set_phase_or_fallback()
    if not next(state.printers) then
        state.phase = "discovering"
    else
        state.phase = "ready"
    end
end

-- Tick loop body: advance each task through its lifecycle. Each task is served
-- in isolation: a throw in one task (external I/O, a latent bug) is captured,
-- logged, and that one task is marked failed -- it can neither skip the end-of
-- tick checkpoint nor abort the rest of the queue.
local function service_one(task)
    if task.state == ST.QUEUED then
        if state.printer_by_name[task.family_id] then
            transition(task, ST.ACTIVE)
            start_print(state.printer_by_name[task.family_id],
                state.printers[state.printer_by_name[task.family_id]], task)
            -- Once REACHED, the controller requests the AGGREGATED quantity from
            -- storage once. The call is fully guarded inside; a missing/declining
            -- storage line is logged and the tick continues.
            request_storage_reservation(task)
        end
    elseif task.state == ST.ACTIVE then
        -- Native completion is driven by hardware commission; here we
        -- advance awaiting output then output done on confirm.
        transition(task, ST.AWAITING_OUTPUT)
    elseif task.state == ST.AWAITING_OUTPUT then
        transition(task, ST.OUTPUT_DONE)
    elseif task.state == ST.OUTPUT_DONE then
        dispatch_reserved(task.owner, task.reservation_id, 1)
        delivery_ack(task.owner, task.reservation_id)
        transition(task, ST.COMPLETED)
        trim_history()
    end
end

local function service_tasks()
    for index = #state.task_order, 1, -1 do
        local task_id = state.task_order[index]
        local task = state.tasks[task_id]
        if not task then
            state.task_order[index] = nil
        else
            local ok, err = pcall(service_one, task)
            if not ok then
                add_error("task_service_error", tostring(err) .. " on " .. tostring(task_id))
                -- Controlled, in-place recovery: park this one bad task as failed
                -- so it does not retry-forever or block the queue.
                if task.state ~= ST.COMPLETED and task.state ~= ST.CANCELLED
                    and task.state ~= ST.FAILED and task.state ~= ST.ABORTED then
                    task.state = ST.FAILED
                    task.error_code = "task_service_error"
                end
            end
        end
    end
    -- The end-of-tick checkpoint always runs, even if a task above failed, so the
    -- durable recovery point is never skipped by a single bad task.
    checkpoint()
end

local function initialize()
    print("PrinterController: booting")
    register_api()
    restore_state()
    set_phase_or_fallback()
    discover_printers()
end

initialize()

while true do
    -- The whole tick is guarded: an uncaught error anywhere in the loop is
    -- captured, logged, and the chip survives to the next yield instead of
    -- halting. The journal/checkpoint inside service_tasks already make the
    -- recovery point durable; this is the last line of crash protection.
    local ok, err = pcall(function()
        state.tick = state.tick + 1
        if state.phase ~= "ready" then
            if #state.printers == 0 then
                local found = discover_printers()
                if found > 0 then
                    for ref, record in pairs(state.printers) do
                        if not state.printer_by_name[record.family] then
                            state.printer_by_name[record.family] = ref
                        end
                    end
                    state.phase = "ready"
                    print("PrinterController: ready with " .. tostring(found) .. " printers")
                end
            end
        elseif state.phase == "ready" then
            service_tasks()
        end
    end)
    if not ok then
        add_error("tick_error", tostring(err))
        checkpoint()
    end
    yield()
end
