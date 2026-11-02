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

-- ================== User config ==================
-- Interconnect naming: ic.net targets resolve a HOUSING's labeller name, and
-- housings cross Logic Filter Bridges only when their display name contains
-- NET_TAG (max 6 ASCII chars -- the bridge's packed Setting budget). Label the
-- storage controller's housing LuaC.Storage.Controller, this housing
-- LuaC.Printer.Controller, and every Logic Filter Bridge LuaBridge.
local NET_TAG = "LuaC."
local STORAGE_TARGET = "LuaC.Storage.Controller"
-- The storage line has its OWN wire protocol version (it is not the printer
-- API): sending the printer's API_VERSION in a storage payload is rejected
-- with invalid_request (observed in-game).
local STORAGE_API_VERSION = 1
local BRIDGE_NAME = "LuaBridge"
local BRIDGE_PREFAB_HASH = 1273838679 -- StructureLogicFilterBridge
local BRIDGE_NAME_MODE = 2            -- mode 2: display name contains packed Setting

-- Required topology, enforced at boot: the chip REFUSES to start unless every
-- family's printer, every NAME_FEED feed splitter, and both standard sorters
-- are present with the right prefab hash -- a missing or wrong device silently
-- misroutes items. Feeders may be EITHER chute digital flip-flop variant
-- (Left or Right); the sorters must be the plain StructureSorter prefab
-- (they are driven in Logic MODE -- a StructureLogicSorter is a different
-- prefab and does not satisfy the check).
local FEED_PREFAB_HASH_LEFT = -810874728  -- StructureChuteDigitalFlipFlopSplitterLeft
local FEED_PREFAB_HASH_RIGHT = 163728359  -- StructureChuteDigitalFlipFlopSplitterRight
local SORTER_PREFAB_HASH = -1009150565    -- StructureSorter

local API_VERSION = 2
local CONTROLLER_SCHEMA_VERSION = 2
local MAX_QUEUE_LENGTH = 64
local MAX_TASK_HISTORY = 128

-- Multiplies the catalog's per-item print time for the console's ETA math
-- (machine speed / tier differences live here, not in the catalog).
local PRINT_TIME_MULTIPLIER = 1.0

-- Inventory relay rate limit: printers.get_inventory forwards at most one
-- storage.get_state per this interval (seconds); inside the window the cached
-- map is returned instead. Consoles only call it while the recipe page is open.
local INVENTORY_CACHE_TTL = 2.0

-- Net request timeout (seconds) passed as arg 5 to ic.net.request, matching
-- the storage console's proven call shape. INVENTORY_SEND_TIMEOUT bounds how
-- long a get_state send may stay outstanding before it is retried.
local NET_TIMEOUT = 5
local INVENTORY_SEND_TIMEOUT = 5

-- Ejection (post-cancel residue return): while a family is ejecting its feed
-- sorter claims nothing (empty program -> arrivals pass down the line to the
-- storage return) and the printer's Open drive dumps internal reagent stacks.
-- EJECT_MAX_TICKS bounds the whole cycle when slot-empty detection is
-- unavailable; EJECT_MIN_TICKS is the minimum hold before an empty slot may
-- close the cycle.
local EJECT_MAX_TICKS = 60
local EJECT_MIN_TICKS = 10

-- Journaled persistence (ic.persist + util.json, mirroring StorageController):
-- the in-flight task ledger is journaled and checkpointed after every durable
-- mutation, so a chip that halts mid-tick recovers on boot without re-reserving
-- its resources.
local JOURNAL_MAX = 128
local ERRORS_MAX = 64
-- ic.persist caps a single value at 8192 bytes by default (mod's "Lua Persist"
-- MaxValueLength) but the WHOLE store gets MaxTotalBytes (32768): a snapshot
-- that outgrows one value splits over "<key>:1"..":N" sibling keys while the
-- base key holds a tiny {"snapshot_chunks":N} manifest. Full-fidelity state
-- (journal + history) therefore fits to ~31KB; the staged degradation only
-- engages past the TOTAL budget, and a rejected set() still fails loudly
-- rather than freezing the durable recovery point (the bug that kept
-- reviving a cancelled task). Keep margin under 8192 for codec overhead.
local PERSIST_VALUE_MAX = 7800
local PERSIST_MAX_CHUNKS = 4          -- 32768 total / 7800 per value -> 4
local PERSIST_TOTAL_MAX = PERSIST_VALUE_MAX * PERSIST_MAX_CHUNKS
local PERSIST_JOURNAL_KEEP = 16    -- newest journal entries retained per snapshot
local PERSIST_TERMINAL_KEEP = 8        -- newest terminal tasks retained (idempotency)
-- If a printer's Reagents read never reflects its loaded mass (unit/type
-- mismatch), Activate would wait forever behind the prime check; after this
-- many delivered ticks it fires anyway and logs the divergence.
local ACTIVATE_FALLBACK_TICKS = 120

local PERSISTENCE_KEY = "printer_controller_state"

-- The six supported printer families, by structure prefab NAME. The numeric
-- hash is resolved lazily through the engine's own StringToHash (prefab_to_family
-- below) -- hardcoding offline-computed values drifted from the build's real
-- prefab hashes and left discovery matching nothing.
local PREFAB_NAMES = {
    [1] = "StructureAutolathe",
    [2] = "StructureHydraulicPipeBender",
    [3] = "StructureElectronicsPrinter",
    [4] = "StructureRocketManufactory",
    [5] = "StructureToolManufactory",
    [6] = "StructureSecurityPrinter",
}

-- family_id -> resolved prefab hash (also emitted to consoles for tile icons)
-- and prefab_hash -> family_id, filled on first use by prefab_to_family().
local PREFAB_FAMILIES = {}
local PREFAB_TO_FAMILY = nil
local NAME_TO_FAMILY = nil
local function prefab_to_family()
    if PREFAB_TO_FAMILY then
        return PREFAB_TO_FAMILY
    end
    PREFAB_TO_FAMILY = {}
    NAME_TO_FAMILY = {}
    for family_id, pname in pairs(PREFAB_NAMES) do
        NAME_TO_FAMILY[pname] = family_id
        local ok, h = pcall(hash, pname)
        if ok and type(h) == "number" then
            PREFAB_FAMILIES[family_id] = h
            PREFAB_TO_FAMILY[h] = family_id
        else
            print("PrinterController: cannot resolve prefab hash for " ..
                tostring(pname) .. " (family " .. tostring(family_id) ..
                " stays undiscoverable)")
        end
    end
    return PREFAB_TO_FAMILY
end

local FAMILY_NAMES = {
    [1] = "autolathe", [2] = "pipe_bender", [3] = "electronics",
    [4] = "rocket", [5] = "tool", [6] = "security",
}

local NAME_FEED = {
    [1] = "Printers.Feed.Autolathe", [2] = "Printers.Feed.PipeBender",
    [3] = "Printers.Feed.Electronics", [4] = "Printers.Feed.Rocket",
    [5] = "Printers.Feed.Tool", [6] = "Printers.Feed.Security",
}

-- The two standard sorters on the printer network, run in Logic mode.
local NAME_INGRESS = "Printers.Ingress"
local NAME_CLASSIFIER = "Printers.OutputClassifier"

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

-- States from which a task never comes back; ejection waits for a family to
-- have none left in a live state.
local TERMINAL = {
    [ST.COMPLETED] = true, [ST.FAILED] = true,
    [ST.CANCELLED] = true, [ST.ABORTED] = true,
}

-- Routing surface. The Printers.Feed.* devices are chute digital flip-flop
-- splitters (NOT memory sorters): each has a through branch that continues
-- the shared ingredient bus and a side branch into its printer. Mode selects
-- the output for the next item: 1 diverts to the printer side branch
-- (conn 2, "Chute Output 2"), 0 passes through (conn 1, "Chute Output").
-- There is no per-item filtering on the bus: exactly the selected family's
-- branch diverts while all others pass, so ingredient transfers are
-- SERIALIZED -- the route is armed before the storage request fires and held
-- until the target's import is confirmed. Verify the two Mode values once
-- against the physical build (a family that diverts backwards means the
-- constants are swapped for that prefab variant).
local FEED_DIVERT_MODE = 1
local FEED_THROUGH_MODE = 0

-- Printers.Ingress / Printers.OutputClassifier are STANDARD sorters in Logic
-- mode (Mode 2): the sorter holds its import item until a one-shot Output
-- write names a destination slot, then Output resets to -1. Output values
-- are slot indexes: 1 = Export (conn 2, "Chute Output"), 2 = Export2
-- (conn 0, "Chute Output 2"). Verify port orientation once; the plan's
-- drawing puts the bus on the Export2 side and the storage return on Export.
local SORTER_LOGIC_MODE = 2
local SORTER_OUTPUT_HOLD = -1
local INGRESS_OUT_FEED = 2       -- Export2 -> shared ingredient bus
local INGRESS_OUT_RETURN = 1     -- Export -> storage input
-- Observed wiring: on the output classifier the legs are the reverse of the
-- ingress sorter's -- Export2 carries finished products to collection and
-- Export returns reagents/residue to storage.
local CLASSIFIER_OUT_RETURN = 1  -- Export -> storage input
local CLASSIFIER_OUT_PRODUCT = 2 -- Export2 -> passive product collection

-- Transfer lifecycle bounds: the armed route releases after the storage line
-- reports all sub-requests done AND the whole aggregate load is confirmed
-- inside the printer, plus a short settle window for trailing stacks; when
-- no counter can confirm the load, movement ceases and a grace window bounds
-- the hold, and a bounded timeout covers a lost delivery instead of wedging
-- the queue.
local TRANSFER_SETTLE_TICKS = 5
local TRANSFER_MAX_TICKS = 240
local IMPORT_GRACE_TICKS = 60
-- Ticks a task may wait for a readable export counter before it fails.
local START_WAIT_MAX = 60

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
    residue = {},                  -- family_id -> {reagent_hash -> grams} (post-cancel, durable)
    ejecting = {},                 -- family_id -> start_tick (transient; re-derived on boot)
    feed_refs = {},                -- family_id -> {flip-flop ref_id, ...} (NAME_FEED devices)
    ingress_ref = nil,             -- Printers.Ingress sorter ref_id
    classifier_ref = nil,          -- Printers.OutputClassifier sorter ref_id
    route = nil,                   -- armed transfer: {task_id, family_id, hashes, started, reagents_baseline, import_baseline, last_imports, saw_import, last_import, import_complete, settle, leak_logged}
    classifier_unknown = {},       -- hash -> true (diagnostic dedupe for held items)
    inventory_cache = nil,         -- last relayed {prefab_hash -> {quantity, available}}
    inventory_revision = nil,
    inventory_queried_at = -1e9,   -- os.clock() of last armed get_state fetch
    inventory_want = nil,          -- armed by the RPC handler; the tick sends
    inventory_send_pending = nil,  -- a get_state response is outstanding
    inventory_send_at = -1e9,      -- os.clock() of the outstanding send
    reserved = {},                 -- owner -> total reserved quantity
    reserved_ledger = {},          -- reservation_key -> reservation record
    errors_seen = 0,
}

-- Keys that JSON stringified on encode are restored to numbers where possible
-- ("9" -> 9); genuinely string keys pass through untouched.
local function renumber_keys(tbl)
    if type(tbl) ~= "table" then
        return tbl
    end
    local out = {}
    for k, v in pairs(tbl) do
        out[tonumber(k) or k] = v
    end
    return out
end

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

local function safe_slot(ref_id, slot, slot_type)
    return safe_call(ic.read_slot_id, ref_id, slot, slot_type)
end

local function safe_memory_write(ref_id, address, value)
    local _, err = safe_call(ic.mem.put_id, ref_id, address, value)
    return err == nil, err
end

local function safe_memory_read(ref_id, address)
    return safe_call(ic.mem.get_id, ref_id, address)
end

-- Pack the interconnect tag the way the bridge expects Setting: ASCII6 (the
-- IC10 STR() encoding). Prefer the engine builtin; fall back to byte packing
-- so the chip still configures its bridges where the builtin is absent.
local function pack_tag(s)
    if type(pack_ascii6) == "function" then
        local ok, packed = pcall(pack_ascii6, s)
        if ok and type(packed) == "number" then
            return packed
        end
    end
    local packed = 0
    for i = 1, math.min(#s, 6) do
        packed = packed * 256 + s:byte(i)
    end
    return packed
end

-- Configure every Logic Filter Bridge labelled LuaBridge on this network:
-- Setting holds the packed tag, Mode 2 filters imported device display names
-- by it, On enables forwarding. Bridges are discoverable from both sides, so
-- each chip configures the pair on its own segment; identical writes are
-- idempotent and one failing bridge does not abort the rest.
local function setup_bridges()
    local ref_ids = safe_call(ic.find_all or find_all, BRIDGE_NAME, "exact")
    if type(ref_ids) ~= "table" then
        return
    end
    local setting = pack_tag(NET_TAG)
    for _, ref_id in ipairs(ref_ids) do
        if safe_read(ref_id, LT.PrefabHash) == BRIDGE_PREFAB_HASH then
            local ok_setting = safe_write(ref_id, LT.Setting, setting)
            local ok_mode = safe_write(ref_id, LT.Mode, BRIDGE_NAME_MODE)
            local ok_on = safe_write(ref_id, LT.On, 1)
            if not (ok_setting and ok_mode and ok_on) then
                print("PrinterController: bridge " .. tostring(ref_id) .. " config write failed")
            end
        end
    end
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

-- On task completion the reservation is fully consumed: clear the ledger
-- entry and release the owner's outstanding aggregate.
local function consume_batch(owner, reservation_id)
    local key = reservation_key(owner, reservation_id)
    local record = state.reserved_ledger[key]
    if not record then
        return nil, "unknown_reservation"
    end
    local owner_total = (state.reserved[owner] or 0) - record.reserved
    if owner_total <= 0 then
        state.reserved[owner] = nil
    else
        state.reserved[owner] = owner_total
    end
    state.reserved_ledger[key] = nil
    return true, nil
end

-- Release a reservation. The WHOLE reservation leaves the owner aggregate:
-- the undelivered share is freed and the delivered share moves to the residue
-- ledger (record_residue), so nothing stays double-counted in `reserved`.
-- Returns the undelivered (freed) share for reporting.
local function release_batch(owner, reservation_id)
    local key = reservation_key(owner, reservation_id)
    local record = state.reserved_ledger[key]
    if not record then
        return nil, "unknown_reservation"
    end
    local releasable = record.reserved - record.delivered
    if releasable < 0 then
        releasable = 0
    end
    local owner_total = (state.reserved[owner] or 0) - record.reserved
    if owner_total <= 0 then
        state.reserved[owner] = nil
    else
        state.reserved[owner] = owner_total
    end
    record.cancelled = true
    state.reserved_ledger[key] = nil
    return releasable, nil
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
-- Guarded net request that never throws: returns (sent_ok, send_err).
-- This runtime REQUIRES a callback as arg 4: the 3-arg form is rejected with
-- "bad argument #4 (value expected)" and an options table with "callback must
-- be a function or string" (both observed in-game). Requests are therefore
-- ASYNCHRONOUS -- this wrapper only guards the send; results arrive later via
-- on_response(ok, response, err), the signature StorageControlConsole proves.
local function safe_request(target, method, payload, on_response)
    local cb = type(on_response) == "function" and on_response or function() end
    local ok, err = pcall(ic.net.request, target, method, payload, cb, NET_TIMEOUT)
    if not ok then
        return nil, "request_error:" .. tostring(err)
    end
    return true, nil
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
        residue = deep_copy(state.residue),
        journal = deep_copy(state.journal),
        saved_tick = state.tick,
    }
end

-- Encode the durable snapshot, shrinking it in stages only once it outgrows
-- the WHOLE chunked persist budget: first the audit journal tail (recovery
-- never replays it), then the journal entirely, then the oldest terminal
-- history (whose idempotency keys drop with them). Live tasks, ledgers,
-- residue and the surviving idempotent keys always persist. Returns
-- (encoded, degraded_tag).
local function encode_snapshot()
    local snap = durable_snapshot()
    local encoded = safe_call(util.json.encode, snap)
    if type(encoded) ~= "string" then
        return nil, encoded
    end
    if #encoded <= PERSIST_TOTAL_MAX then
        return encoded, nil
    end
    local j = snap.journal or {}
    if #j > PERSIST_JOURNAL_KEEP then
        local tail = {}
        for i = #j - PERSIST_JOURNAL_KEEP + 1, #j do
            tail[#tail + 1] = j[i]
        end
        snap.journal = tail
        encoded = safe_call(util.json.encode, snap)
        if #encoded <= PERSIST_TOTAL_MAX then
            return encoded, "journal_trimmed"
        end
    end
    snap.journal = {}
    encoded = safe_call(util.json.encode, snap)
    if #encoded <= PERSIST_TOTAL_MAX then
        return encoded, "journal_dropped"
    end
    -- Keep every live task plus the newest PERSIST_TERMINAL_KEEP terminal
    -- entries (walk task_order back-to-front so the newest survive).
    local keep, order, terminals = {}, {}, 0
    for i = #snap.task_order, 1, -1 do
        local tid = snap.task_order[i]
        local t = snap.tasks[tid]
        if t and not TERMINAL[t.state] then
            keep[tid] = true
            order[#order + 1] = tid
        elseif t and terminals < PERSIST_TERMINAL_KEEP then
            terminals = terminals + 1
            keep[tid] = true
            order[#order + 1] = tid
        end
    end
    for tid in pairs(snap.tasks) do
        if not keep[tid] then
            snap.tasks[tid] = nil
        end
    end
    snap.task_order = {}
    for i = #order, 1, -1 do
        snap.task_order[#snap.task_order + 1] = order[i]
    end
    -- An idempotency key without its task replays as a fresh request anyway,
    -- so dangling keys are dropped rather than kept.
    for key, tid in pairs(snap.idempotency) do
        if not keep[tid] then
            snap.idempotency[key] = nil
        end
    end
    encoded = safe_call(util.json.encode, snap)
    if #encoded <= PERSIST_TOTAL_MAX then
        return encoded, "history_trimmed"
    end
    return nil, "persist_oversize_" .. tostring(#encoded)
end

-- Sibling keys holding snapshot data when the encoded blob outgrows one
-- persist value; the base key then carries a {"snapshot_chunks":N} manifest.
local function snapshot_chunk_key(i)
    return PERSISTENCE_KEY .. ":" .. tostring(i)
end

local function checkpoint()
    if not has_persist() then
        -- In-memory journal was already advanced; nothing durable to persist
        -- without the engine's persistent store + json codec present.
        return true
    end
    local encoded, degraded = encode_snapshot()
    if encoded == nil then
        add_error("persistence_encode_error", degraded)
        return false
    end
    if degraded ~= state.persist_degraded then
        state.persist_degraded = degraded
        if degraded then
            add_error("persist_degraded",
                "durable snapshot trimmed (" .. degraded .. ") to fit " ..
                tostring(PERSIST_TOTAL_MAX) .. "B persist budget")
        end
    end
    -- persist.set returns true on success; a rejected value (over the byte
    -- limit) returns false/nil rather than throwing, so check the result.
    local function persist_write(key, value)
        local ok_write, err = safe_call(ic.persist.set, key, value)
        if ok_write ~= true or err ~= nil then
            add_error("persistence_write_error",
                "set " .. key .. " -> " .. tostring(ok_write) .. "/" ..
                tostring(err) .. " (" .. tostring(#value) .. "B)")
            return false
        end
        return true
    end
    -- Chunked layout: data lands in ":1"..":N" keys FIRST, the base key's
    -- manifest LAST, so a torn flush can only revive the previous consistent
    -- snapshot. Stale trailing chunks from a longer past snapshot are
    -- reclaimed so they cannot corrupt the byte budget.
    local can_sweep = type(ic.persist.has) == "function" and
        type(ic.persist.delete) == "function"
    local function sweep_stale_chunks(keep)
        if can_sweep then
            for i = keep + 1, PERSIST_MAX_CHUNKS do
                local key = snapshot_chunk_key(i)
                if ic.persist.has(key) then
                    ic.persist.delete(key)
                end
            end
        end
    end
    if #encoded <= PERSIST_VALUE_MAX then
        -- The blob lands BEFORE the sweep: a halt here leaves either the old
        -- manifest+chunks or the new blob plus strays, never a manifest
        -- pointing at deleted keys.
        local wrote = persist_write(PERSISTENCE_KEY, encoded)
        sweep_stale_chunks(0)
        return wrote
    end
    local chunks = math.ceil(#encoded / PERSIST_VALUE_MAX)
    if chunks > PERSIST_MAX_CHUNKS then
        add_error("persist_oversize",
            "snapshot needs " .. chunks .. " chunks (" ..
            tostring(#encoded) .. "B) over " .. PERSIST_MAX_CHUNKS .. " max")
        return false
    end
    for i = 1, chunks do
        local piece = encoded:sub(
            (i - 1) * PERSIST_VALUE_MAX + 1, i * PERSIST_VALUE_MAX)
        if not persist_write(snapshot_chunk_key(i), piece) then
            return false
        end
    end
    sweep_stale_chunks(chunks)
    local manifest = safe_call(util.json.encode, { snapshot_chunks = chunks })
    if type(manifest) ~= "string" then
        add_error("persistence_encode_error", manifest)
        return false
    end
    return persist_write(PERSISTENCE_KEY, manifest)
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
    -- A chunked snapshot's base key holds only a manifest; the data lives in
    -- the sibling ":N" keys and is reassembled in order. A single-value
    -- snapshot decodes straight to the state table (legacy blob).
    if type(saved) == "table" and type(saved.snapshot_chunks) == "number" then
        local parts = {}
        for i = 1, saved.snapshot_chunks do
            local piece = safe_call(ic.persist.get, snapshot_chunk_key(i))
            if type(piece) ~= "string" then
                add_error("persist_chunk_missing",
                    "snapshot chunk " .. tostring(i) .. "/" ..
                    tostring(saved.snapshot_chunks) .. " unreadable")
                return false, "chunk_missing"
            end
            parts[#parts + 1] = piece
        end
        saved = safe_call(util.json.decode, table.concat(parts))
    end
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
        -- Printer ref ids are numbers; JSON stringified them on the way in.
        state.active_task_by_printer[tonumber(ref) or ref] = tid
    end
    state.tasks = {}
    state.task_order = {}
    for _, tid in ipairs(saved.task_order or {}) do
        local task = saved.tasks and saved.tasks[tid]
        if type(task) == "table" then
            if task.controller_schema_version == nil then
                task.controller_schema_version = CONTROLLER_SCHEMA_VERSION
            end
            -- Hash-keyed tables (prefab_hash -> value) round-tripped through
            -- JSON with string keys; normalize them back to numbers so hash
            -- lookups keep working on the recovered chip.
            task.cost_vector = renumber_keys(task.cost_vector)
            task.reagent_labels = renumber_keys(task.reagent_labels)
            task.delivered_reagents = renumber_keys(task.delivered_reagents)
            task.printer_ref = tonumber(task.printer_ref) or task.printer_ref
            state.tasks[tid] = task
            state.task_order[#state.task_order + 1] = tid
            -- Surface each task the chip is about to resume so a job that
            -- "comes back" after a cancel is visible in the boot log with its
            -- recovered state (a stale snapshot is the usual culprit).
            if not TERMINAL[task.state] then
                print("PrinterController: resumed task " .. tostring(tid) ..
                    " (" .. tostring(task.item) .. " x" .. tostring(task.count) ..
                    ", state=" .. tostring(task.state) .. ")")
            end
        end
    end
    state.reserved_ledger = {}
    for key, rec in pairs(saved.reservation_ledger or {}) do
        if type(rec) == "table" then
            rec.recipe_cost = renumber_keys(rec.recipe_cost)
            state.reserved_ledger[key] = rec
        end
    end
    -- Net responses do not survive a halt: a record restored with outstanding
    -- sends (storage_pending > 0) would wait forever for callbacks that no
    -- longer exist. Re-arm the unanswered sub-requests (the durable
    -- storage_requested flags + storage's client_request_id dedupe make the
    -- re-send safe) and mark the record for the service pass to re-issue.
    for _, rec in pairs(state.reserved_ledger) do
        if (rec.storage_pending or 0) > 0 then
            for sub_key in pairs(rec.storage_requested or {}) do
                if not rec.storage_results or
                    rec.storage_results[sub_key] == nil or
                    rec.storage_results[sub_key] == false then
                    rec.storage_requested[sub_key] = nil
                end
            end
            rec.storage_pending = 0
            rec.storage_retry = true
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
    state.residue = {}
    for family_id, amounts in pairs(saved.residue or {}) do
        if type(amounts) == "table" then
            -- JSON round-trips may stringify keys; normalize both levels.
            local bucket = {}
            state.residue[tonumber(family_id) or family_id] = bucket
            for prefab_hash, grams in pairs(amounts) do
                if type(grams) == "number" and grams > 0 then
                    bucket[tonumber(prefab_hash) or prefab_hash] = grams
                end
            end
        end
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
    -- Per-reagent delivered grams, for the cancel-time residue computation.
    task.delivered_reagents = task.delivered_reagents or {}

    -- Fan the multi-reagent aggregate out into ONE storage.request per reagent
    -- hash: the storage request contract is a single prefab_hash + integer
    -- quantity, so a multi-reagent task is split by reagent. The controller
    -- stays catalog-free (it forwards the hash-keyed vector the console packed);
    -- and 1 gram == 1 item, so a reagent's request quantity is the ceiling of
    -- that reagent's aggregate mass (per-item grams x count).
    local agg = aggregate_cost_vector(task.cost_vector, task.count)
    local family_id = task.family_id or FAMILY_ID[task.family_name] or 1
    local task_id = task.task_id

    -- Response bookkeeping. ic.net.request is callback-only here, so results
    -- land AFTER this call returns -- possibly ticks later, possibly after a
    -- cancel/restore. The closure therefore re-resolves the live task + ledger
    -- record by id instead of trusting the captured tables.
    local function on_response(sub_key, prefab_hash, quantity)
        return function(ok, response, err)
            local live_record = state.reserved_ledger[key]
            local live_task = state.tasks[task_id]
            local accepted = ok and type(response) == "table" and
                response.ok ~= false
            if live_record then
                live_record.storage_results = live_record.storage_results or {}
                live_record.storage_results[sub_key] = response or false
                live_record.storage_pending =
                    math.max(0, (live_record.storage_pending or 0) - 1)
                if accepted then
                    -- In-transit grams are no longer releasable: cancelling
                    -- later only frees what was never dispatched.
                    live_record.delivered = (live_record.delivered or 0) + quantity
                else
                    live_record.storage_failed = true
                end
            end
            if accepted and live_task then
                live_task.delivered_reagents = live_task.delivered_reagents or {}
                live_task.delivered_reagents[prefab_hash] =
                    (live_task.delivered_reagents[prefab_hash] or 0) + quantity
            end
            -- A response landing after the reservation was released (cancel /
            -- fail) cannot update the record; the grams it covers are still
            -- physically owed to the residue ledger so the ejection pass
            -- returns them instead of losing them inside the printer.
            if accepted and not live_record and live_task and
                live_task.state ~= ST.COMPLETED then
                local bucket = state.residue[family_id]
                if not bucket then
                    bucket = {}
                    state.residue[family_id] = bucket
                end
                bucket[prefab_hash] = (bucket[prefab_hash] or 0) + quantity
            end
            if not accepted then
                if ok then
                    add_error("storage_request_rejected",
                        "for hash " .. tostring(prefab_hash) .. " (" .. tostring(
                            type(response) == "table" and
                            (response.err_code or response.code) or "declined") .. ")")
                else
                    add_error("storage_request_error",
                        tostring(err or "no_result") .. " for hash " ..
                        tostring(prefab_hash))
                end
            end
            -- All responses in: finalize the line state so the tile can flip
            -- from waiting_resources to printing (or stays waiting on failure).
            if live_record and (live_record.storage_pending or 0) <= 0 then
                live_record.storage_state =
                    live_record.storage_failed and "failed" or "ok"
                if live_task and live_task.state == ST.ACTIVE then
                    live_task.resources_state =
                        live_record.storage_failed and "failed" or "delivered"
                    state.sequence = state.sequence + 1
                end
            end
        end
    end

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
                api_version = STORAGE_API_VERSION, -- storage's wire protocol, not ours
                client_request_id = sub_key,
                prefab_hash = prefab_hash,
                quantity = quantity,
                owner = task.owner,
                reservation_id = task.reservation_id,
                item = task.item,
                family_id = task.family_id,
            }
            record.storage_requested[sub_key] = true
            sent = sent + 1
            -- Increment BEFORE the send: a runtime that invokes the callback
            -- synchronously decrements inside safe_request, so pending must
            -- already count this sub-request.
            record.storage_pending = (record.storage_pending or 0) + 1
            local sent_ok, send_err = safe_request(STORAGE_TARGET, "storage.request",
                payload, on_response(sub_key, prefab_hash, quantity))
            if not sent_ok then
                record.storage_pending = math.max(0, (record.storage_pending or 0) - 1)
                record.storage_results[sub_key] = false
                record.storage_failed = true
                saw_fail = true
                add_error("storage_request_error",
                    tostring(send_err) .. " for hash " .. tostring(prefab_hash))
            end
        end
    end
    record.storage_sent = (record.storage_sent or 0) + sent
    -- While responses are outstanding the tile reads waiting_resources; the
    -- last response finalizes it to delivered/failed.
    if (record.storage_pending or 0) > 0 then
        record.storage_state = "requesting"
        task.resources_state = "requesting"
    else
        record.storage_state = (record.storage_failed or saw_fail) and "failed" or "ok"
        task.resources_state = record.storage_state == "failed" and "failed" or "delivered"
    end
    return record, nil
end

-- Discovery: ic.device.list() is the real surface -- it returns
-- {ref_id, prefab_hash, name_hash, display_name} per device. The earlier
-- find_all(hash, ...) signature does not exist; find_all matches display
-- NAMES only and yields raw reference ids. Family matching resolves the
-- device prefab hash against prefab_to_family()'s runtime-hashed names.
local function discover_printers()
    state.printers = {}
    state.printer_by_name = {}
    local by_hash = prefab_to_family()
    local devices = safe_call(ic.device and ic.device.list)
    if type(devices) == "table" then
        for _, dev in ipairs(devices) do
            if type(dev) == "table" then
                local ph = tonumber(dev.prefab_hash) or dev.prefab_hash
                -- Primary: exact prefab-NAME match (algorithm-free). Fallback:
                -- the runtime-hashed name map, for when prefab_name() is absent.
                local pname = safe_call(prefab_name, ph)
                local family_id = (type(pname) == "string" and NAME_TO_FAMILY[pname])
                    or by_hash[ph]
                local ref = dev.ref_id or dev.refId or dev.id
                if family_id and ref then
                    state.printers[ref] = {
                        ref_id = ref,
                        family = family_id,
                        family_name = FAMILY_NAMES[family_id],
                        prefab_hash = ph,
                    }
                    -- Dual-key: the routing table is looked up by BOTH numeric
                    -- family id and family name, so consoles (which carry a
                    -- family_name string) and numeric callers route identically.
                    state.printer_by_name[family_id] = ref
                    state.printer_by_name[FAMILY_NAMES[family_id]] = ref
                    if family_id == 1 then
                        print("PrinterController: found autolathe at ref " .. tostring(ref))
                    end
                end
            end
        end
    end
    local n = 0
    for _ in pairs(state.printers) do
        n = n + 1
    end
    return n
end

-- Guarded prefab-name -> hash resolution (engine Animator.StringToHash / IC10
-- HASH()). The console keys recipes by prefab name; RecipeHash wants the hash.
local function safe_hash(name)
    if type(hash) ~= "function" or type(name) ~= "string" then
        return nil, "no_hash_fn"
    end
    local ok, h = pcall(hash, name)
    if not ok or type(h) ~= "number" then
        return nil, "hash_failed"
    end
    return h, nil
end

-- Actuation: the real printer drive is LogicType writes, not a memory program.
-- RecipeHash selects the product (the task's `item` is a prefab NAME; the
-- console already validated it resolves), Activate starts continuous
-- production. Per-item semantics verified in-game during commissioning; all
-- writes are guarded so a hostile/absent device can never halt the chip.
local function start_print(printer_ref, printer, task)
    -- Single active task per printer invariant.
    local active = state.active_task_by_printer[printer_ref]
    if active and active ~= task.task_id then
        return false, "printer_busy"
    end
    local h, herr = safe_hash(task.item)
    if not h then
        add_error("recipe_hash_failed", tostring(task.item) .. " (" .. tostring(herr) .. ")")
        return false, "recipe_hash_failed"
    end
    task.product_hash = h
    -- ClearMemory is a one-shot clear: a single write zeroes the lifetime
    -- ExportCount/ImportCount tallies and the recipe persists until the next
    -- recipe write, so the hold does NOT need re-driving (V3 keeps it at 1
    -- while idle anyway, which costs it nothing). The reset is ASYNCHRONOUS:
    -- the clear is issued on one pass and the counter is verified on the
    -- NEXT, where the post-clear read must be exactly 0 -- a nonzero or
    -- unreadable tally means the reset has not landed (or never took), so
    -- the clear is re-issued and the verify retried (bounded by
    -- START_WAIT_MAX) rather than adopting a stale lifetime tally that would
    -- count foreign exports as this job's progress.
    if task.export_baseline == nil then
        if not task.export_clear_sent then
            safe_write(printer_ref, LT.ClearMemory, 1)
            task.export_clear_sent = true
            -- Claim the printer as soon as its counter is cleared: the reset
            -- is already this task's doing, and the durable binding keeps
            -- status truthful through the verify window (and lets a mid-start
            -- halt attribute the cleared counter to this task).
            state.active_task_by_printer[printer_ref] = task.task_id
            task.printer_ref = printer_ref
            -- The pre-delivery reagent mass is the prime check's origin: an
            -- absolute Reagents read would count leftovers toward the
            -- incoming load and prime early on a machine that cannot
            -- actually produce yet. Captured with the clear -- the earliest
            -- point before any delivery can land.
            if task.reagents_baseline == nil then
                task.reagents_baseline = safe_read(printer_ref, LT.Reagents)
            end
            return nil, "export_counter_unavailable"
        end
        local baseline = safe_read(printer_ref, LT.ExportCount)
        if type(baseline) ~= "number" then
            return nil, "export_counter_unavailable"
        end
        if baseline ~= 0 then
            safe_write(printer_ref, LT.ClearMemory, 1)
            return nil, "export_counter_unavailable"
        end
        task.export_baseline = baseline
    end
    -- Fallback for a task restored with a baseline but no reagent origin
    -- (e.g. an older snapshot); the live path captures it with the clear.
    if task.reagents_baseline == nil then
        task.reagents_baseline = safe_read(printer_ref, LT.Reagents)
    end
    local ok1, e1 = safe_write(printer_ref, LT.RecipeHash, h)
    if not ok1 then
        return false, e1 or "recipe_hash_write_failed"
    end
    -- Power must be on for Activate to run the machine; a powered-off printer
    -- silently ignores the run flag. Activate is NOT pressed here: the
    -- fabricator drops it while the machine cannot produce, so the ACTIVE
    -- branch presses it once, when Reagents covers the whole job.
    safe_write(printer_ref, LT.On, 1)
    state.active_task_by_printer[printer_ref] = task.task_id
    task.printer_ref = printer_ref
    return true, "started"
end

-- Stop the current production run on a printer (cancel / task done / boot
-- sanitize). Guarded; a missing printer just reports a failed write.
local function stop_print(printer_ref)
    safe_write(printer_ref, LT.Activate, 0)
end

-- Read production progress for a task on its printer. Returns
-- (done_count, item_ratio): done_count is THIS task's completed-item count
-- (LogicType.ExportCount minus the baseline captured at start_print, clamped
-- to the task's count), item_ratio is the current item's CompletionRatio
-- 0..1 for finer UI progress. Both degrade to zeros when the device is
-- unreachable -- a read failure must never abort the tick, it only stalls
-- the reported progress.
local function read_print_progress(printer_ref, task)
    local produced = safe_read(printer_ref, LT.ExportCount)
    local done = task.done_count or 0
    local delta = 0
    if type(produced) == "number" then
        local base = task.export_baseline
        if type(base) ~= "number" then
            -- A restored task without a baseline adopts the current counter
            -- as its origin rather than counting lifetime exports.
            task.export_baseline = produced
            base = produced
        end
        delta = math.floor(produced - base)
        if delta < 0 then
            -- Counter went backwards (printer rebuilt/reset mid-task):
            -- re-baseline rather than let progress go negative.
            task.export_baseline = produced
            delta = 0
        end
    end
    -- Progress is exactly the printer's own export tally: the post-baseline
    -- ExportCount delta, kept monotonic so a mid-task re-baseline never
    -- reports less than a previous read. The output classifier is NOT a
    -- progress source -- it only routes output. Crediting its transits
    -- re-counted a held item every tick it waited in the sorter slot, which
    -- ran done_count ahead of the real print tally and completed jobs early.
    done = math.max(done, delta)
    if done > task.count then
        done = task.count
    end
    local ratio = safe_read(printer_ref, LT.CompletionRatio)
    if type(ratio) ~= "number" or ratio ~= ratio then
        ratio = 0
    end
    if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
    return done, ratio
end

-- A printer reports a fault (LogicType.Error nonzero).
local function printer_faulted(printer_ref)
    local err_flag = safe_read(printer_ref, LT.Error)
    return type(err_flag) == "number" and err_flag ~= 0
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
    -- Free the printer binding when the task leaves its producing states so a
    -- cancelled/completed/failed task never keeps the printer marked busy.
    if next_state == ST.CANCELLED or next_state == ST.COMPLETED or
        next_state == ST.FAILED or next_state == ST.ABORTED then
        if task.printer_ref and
            state.active_task_by_printer[task.printer_ref] == task.task_id then
            state.active_task_by_printer[task.printer_ref] = nil
        end
        -- Repin the idle counter/recipe hold (ClearMemory is a held flag; V3
        -- keeps it at 1 whenever the printer is not producing).
        if task.printer_ref then
            safe_write(task.printer_ref, LT.ClearMemory, 1)
        end
    end
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

local function lookup_task(task_id)
    local task = state.tasks[task_id]
    if not task then
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
    -- Consoles route by family_name; family_id stays accepted for direct
    -- callers. An unresolvable family is REJECTED, never silently re-routed:
    -- falling back to a default family would print the item on the wrong
    -- printer and send its reagents down the wrong feed.
    local family_id = payload.family_id or FAMILY_ID[payload.family_name]
    if type(family_id) ~= "number" or FAMILY_NAMES[family_id] == nil then
        add_error("unknown_family", tostring(payload.family_name or payload.family_id))
        return response_error("unknown_family")
    end
    if type(payload.item) ~= "string" then
        add_error("invalid_item", tostring(payload.item))
        return response_error("invalid_item")
    end
    local client_key = tostring(owner) .. ":" .. payload.client_request_id
    local existing = state.idempotency[client_key]
    if existing then
        local task, err = lookup_task(existing)
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
        family_name = FAMILY_NAMES[family_id],
        item = payload.item,
        count = payload.count,
        done_count = 0,
        partial = 0,
        cost_vector = deep_copy(cost),
        cost_total = total,
        reagent_labels = type(payload.reagent_labels) == "table"
            and deep_copy(payload.reagent_labels) or nil,
        resources_state = "pending",
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

-- Merge a cancelled task's delivered-but-unconsumed reagent grams into the
-- durable residue ledger for its family; the ejection pass returns them to
-- storage once the family's queue has fully drained.
local function record_residue(task)
    local delivered = task.delivered_reagents
    if type(delivered) ~= "table" then
        return
    end
    local per_item = task.cost_vector or {}
    local done = task.done_count or 0
    local amounts
    for prefab_hash, grams in pairs(delivered) do
        local consumed = (per_item[prefab_hash] or 0) * done
        local leftover = grams - consumed
        if leftover > 0 then
            amounts = amounts or {}
            amounts[prefab_hash] = (amounts[prefab_hash] or 0) + leftover
        end
    end
    if not amounts then
        return
    end
    local family = task.family_id or FAMILY_ID[task.family_name] or 1
    local bucket = state.residue[family]
    if not bucket then
        bucket = {}
        state.residue[family] = bucket
    end
    for prefab_hash, grams in pairs(amounts) do
        bucket[prefab_hash] = (bucket[prefab_hash] or 0) + grams
    end
    journal_append("residue", task.task_id, {
        family_id = family, reagents = amounts,
    })
end

-- Defined with the routing block below; a cancel needs it synchronously so
-- the armed bus route drops before the ejection pass can open the printer.
local route_release

local function printers_cancel(payload, sender)
    if type(payload) ~= "table" or payload.api_version ~= API_VERSION then
        return response_error("invalid_request")
    end
    local task, err = lookup_task(payload.task_id)
    if not task then
        return response_error(err or "unknown_request")
    end
    if task.state == ST.CANCELLED then
        -- Idempotent: the task is already in the state the operator wants, so
        -- report success rather than an error that looks like a failed cancel.
        return {
            api_version = API_VERSION,
            ok = true,
            task_id = task.task_id,
            state = task.state,
            already_cancelled = true,
        }
    end
    if task.state ~= ST.QUEUED and task.state ~= ST.PAUSED and
        task.state ~= ST.ACTIVE and task.state ~= ST.AWAITING_OUTPUT then
        return response_error("not_cancellable")
    end
    -- Stop the machine first if it is mid-run; leftovers are returned by the
    -- ejection pass once the family queue is drained.
    if task.state == ST.ACTIVE or task.state == ST.AWAITING_OUTPUT then
        if task.printer_ref then
            stop_print(task.printer_ref)
        end
        record_residue(task)
    end
    -- A cancelled task may still own the armed bus route: release it now so
    -- its in-flight arrivals bounce to the storage return instead of
    -- diverting into the (about to eject) printer.
    if state.route and state.route.task_id == task.task_id then
        route_release()
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

-- Per-family printer status for the console's status-colored tiles. Computed
-- here so every console sees the same truth: absent -> no discovered printer;
-- ejecting -> residue return in progress; waiting_resources -> its reached
-- task's storage request is pending, failed, or still flying in (delivered
-- only means the storage line finished dispatching); printing -> Activate was
-- asserted once the machine held the whole job load; idle -> otherwise.
local function printer_status(family_id)
    local ref = state.printer_by_name[family_id]
    if not ref then
        return "absent", nil
    end
    if state.ejecting[family_id] then
        return "ejecting", nil
    end
    local task_id = state.active_task_by_printer[ref]
    local task = task_id and state.tasks[task_id]
    if task and task.state ~= ST.CANCELLED and task.state ~= ST.COMPLETED and
        task.state ~= ST.FAILED and task.state ~= ST.ABORTED then
        if task.activated then
            return "printing", task_id
        end
        return "waiting_resources", task_id
    end
    return "idle", nil
end

local function printers_get_state(payload, sender)
    payload = payload or {}
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
    local printers = {}
    prefab_to_family()  -- lazy-fills PREFAB_FAMILIES for the icon hashes below
    for family_id = 1, 6 do
        local status, active_task = printer_status(family_id)
        printers[#printers + 1] = {
            family_id = family_id,
            family_name = FAMILY_NAMES[family_id],
            prefab_hash = PREFAB_FAMILIES[family_id],
            ref_id = state.printer_by_name[family_id],
            status = status,
            active_task_id = active_task,
        }
    end
    local recent_errors = {}
    local first = math.max(1, #state.errors - 2)
    for i = first, #state.errors do
        recent_errors[#recent_errors + 1] = state.errors[i]
    end
    return {
        api_version = API_VERSION,
        ok = true,
        phase = state.phase,
        revision = state.sequence,
        task_count = #state.task_order,
        tasks = tasks,
        printers = printers,
        time_multiplier = PRINT_TIME_MULTIPLIER,
        recent_errors = recent_errors,
    }
end

-- Inventory relay: the ONLY storage-facing RPC the console gets (the console/
-- storage RPC isolation is test-enforced). ic.net.request is callback-only in
-- this runtime, so the handler cannot block for a storage.get_state result:
-- it ARMS a refresh (rate-limited by INVENTORY_CACHE_TTL) which the tick sends
-- asynchronously, and returns the current cache. First call on an empty cache
-- reports inventory_unavailable; the console's periodic re-poll picks the
-- populated cache up once the response lands.
local function printers_get_inventory(payload, sender)
    local now_s = os.clock and os.clock() or 0
    if not state.inventory_send_pending and
        (now_s - state.inventory_queried_at) >= INVENTORY_CACHE_TTL then
        state.inventory_queried_at = now_s
        state.inventory_want = true
    end
    if not state.inventory_cache then
        return {
            api_version = API_VERSION,
            ok = false,
            err_code = "inventory_unavailable",
        }
    end
    return {
        api_version = API_VERSION,
        ok = true,
        revision = state.inventory_revision,
        inventory = state.inventory_cache,
    }
end

-- Performs the armed storage.get_state fetch from tick context (sends are only
-- made from the main loop, never inside an RPC handler). The callback compacts
-- storage's groups into the prefab_hash -> {quantity, available} relay map.
-- A response that never lands is retried after INVENTORY_SEND_TIMEOUT.
local function service_inventory_fetch()
    if state.inventory_send_pending then
        local now_s = os.clock and os.clock() or 0
        if now_s - (state.inventory_send_at or 0) > INVENTORY_SEND_TIMEOUT then
            state.inventory_send_pending = nil
            if not state.inventory_cache then
                add_error("inventory_unavailable", "storage.get_state timed out")
            end
        else
            return
        end
    end
    if not state.inventory_want then
        return
    end
    state.inventory_want = nil
    state.inventory_send_pending = true
    state.inventory_send_at = os.clock and os.clock() or 0
    local sent_ok, send_err = safe_request(STORAGE_TARGET, "storage.get_state",
        { api_version = STORAGE_API_VERSION, include_groups = true },
        function(ok, response, err)
            state.inventory_send_pending = nil
            if ok and type(response) == "table" and response.ok ~= false and
                type(response.groups) == "table" then
                local compact = {}
                for _, group in ipairs(response.groups) do
                    local h = group.prefab_hash or group.assignment_prefab_hash
                    if type(h) == "number" then
                        compact[h] = {
                            quantity = group.confirmed_quantity or 0,
                            available = group.available_quantity or
                                group.confirmed_quantity or 0,
                        }
                    end
                end
                state.inventory_cache = compact
                state.inventory_revision = response.inventory_revision
            elseif not state.inventory_cache then
                add_error("inventory_unavailable", tostring(err or "no_result"))
            end
        end)
    if not sent_ok then
        state.inventory_send_pending = nil
        if not state.inventory_cache then
            add_error("inventory_unavailable", tostring(send_err or "send_failed"))
        end
    end
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
    ic.net.register("printers.cancel", guarded("printers.cancel", printers_cancel))
    ic.net.register("printers.get_state", guarded("printers.get_state", printers_get_state))
    ic.net.register("printers.get_inventory", guarded("printers.get_inventory", printers_get_inventory))
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

-- Discovery: the feed sorters that sit between the storage line and each
-- printer, labelled in NAME_FEED. Display names resolve via the same
-- find_all(name, "exact") path the storage controller uses for bridges.
local function find_named(name)
    local found = safe_call(ic.find_all or find_all, name)
    local refs = {}
    if type(found) == "table" then
        for _, device in ipairs(found) do
            -- find_all returns raw reference ids; tolerate table-shaped
            -- entries for mock runtimes that still hand back records.
            local ref = (type(device) == "table")
                and (device.ref_id or device.refId or device.id) or device
            if type(ref) == "number" then
                refs[#refs + 1] = ref
            end
        end
    end
    return refs
end

local function discover_feeds()
    state.feed_refs = {}
    for family_id, name in pairs(NAME_FEED) do
        local refs = find_named(name)
        state.feed_refs[family_id] = refs
        if #refs == 0 then
            print("PrinterController: no feed splitter named " .. name)
        end
        -- V3's boot block does this for a reason: the chute flip-flop is a
        -- RATIO splitter ("toggle between two outputs using n:1"), so any
        -- nonzero Setting/SettingOutput left on the dial makes it alternate
        -- outputs per item and silently overrides the Mode a route armed --
        -- the exact copper-in/gold-through pattern. Pin both to 0 so Mode is
        -- the sole output selector.
        for _, ref in ipairs(refs) do
            safe_write(ref, LT.Setting, 0)
            safe_write(ref, LT.SettingOutput, 0)
        end
    end
    -- The two standard sorters: ingress steers storage-line arrivals onto the
    -- bus or back to storage; the classifier splits printer output into
    -- reagent returns and the product collection.
    local ingress = find_named(NAME_INGRESS)
    state.ingress_ref = ingress[1]
    local classifier = find_named(NAME_CLASSIFIER)
    state.classifier_ref = classifier[1]
    if not state.ingress_ref then
        print("PrinterController: " .. NAME_INGRESS .. " not found; stray items will use its leftover route")
    end
    if not state.classifier_ref then
        print("PrinterController: " .. NAME_CLASSIFIER .. " not found; progress falls back to ExportCount")
    end
end

-- Program the shared ingredient bus for a transfer: the target family's
-- flip-flops divert, every other family's pass through. target_family nil
-- means the all-through idle state, which is also the ejection state -- any
-- stray or post-cancel arrival simply rides the bus to the terminal return
-- leg back into storage.
local function program_route(target_family)
    for family_id, refs in pairs(state.feed_refs) do
        local mode = (family_id == target_family) and FEED_DIVERT_MODE
            or FEED_THROUGH_MODE
        for _, ref in ipairs(refs) do
            -- Setting must stay 0 or the flop's ratio behaviour alternates
            -- outputs per item no matter what Mode says (V3 pins it too).
            safe_write(ref, LT.Setting, 0)
            safe_write(ref, LT.Mode, mode)
            safe_write(ref, LT.On, 1)
        end
    end
end

-- Arm a transfer for a task. The route's expected-hash set covers both
-- numeric (hash-keyed) and name-keyed cost vectors so the ingress sorter can
-- tell expected arrivals from strays.
local function route_open(task)
    local hashes = {}
    for key in pairs(task.cost_vector or {}) do
        if type(key) == "number" then
            hashes[key] = true
        elseif type(key) == "string" then
            local h = safe_hash(key)
            if h then
                hashes[h] = true
            end
        end
    end
    -- The pre-delivery reagent mass is captured so residue left inside the
    -- machine cannot masquerade as the incoming load; the import counter is
    -- captured too, but it only becomes meaningful after the start_print
    -- clear restarts it (a read BELOW this baseline is that reset, so the
    -- route rebases rather than comparing against the dead lifetime tally).
    local pref = task.printer_ref or state.printer_by_name[task.family_id]
    state.route = {
        task_id = task.task_id,
        family_id = task.family_id,
        hashes = hashes,
        started = state.tick,
        reagents_baseline = pref and safe_read(pref, LT.Reagents) or nil,
        import_baseline = pref and safe_read(pref, LT.ImportCount) or nil,
        last_imports = nil,
        saw_import = false,
        last_import = nil,
        import_complete = false,
        settle = 0,
        leak_logged = false,
        stall_logged = false,
    }
    if #(state.feed_refs[task.family_id] or {}) == 0 then
        add_error("no_feed_path", "no feed splitter for " ..
            tostring(FAMILY_NAMES[task.family_id] or task.family_id) ..
            "; delivery will ride the bus to the storage return")
    end
    program_route(task.family_id)
end

function route_release()
    state.route = nil
    program_route(nil)
end

-- The route is stale when its owning task is gone or terminal; release it so
-- in-flight strays ride through to the storage return and the queue can
-- advance. Checked here and at the top of every task service so a stale
-- route cannot wedge the bus when the full loop is not running.
local function route_release_if_stale()
    local route = state.route
    if route then
        local t = state.tasks[route.task_id]
        if not t or TERMINAL[t.state] then
            route_release()
        end
    end
end

-- One steering pass over a Logic-mode standard sorter. A waiting item is
-- held in the import slot until Output names a destination slot; Output then
-- resets itself to -1, so each arrival gets exactly one explicit decision.
-- route_fn(hash, qty) returns the destination slot index, or nil to keep the
-- item held for a later pass.
local function steer_sorter(ref, route_fn)
    if not ref then
        return
    end
    safe_write(ref, LT.Mode, SORTER_LOGIC_MODE)
    local occupied = safe_slot(ref, 0, LST.Occupied)
    if type(occupied) == "number" and occupied > 0 then
        local hash = safe_slot(ref, 0, LST.OccupantHash)
        local qty = safe_slot(ref, 0, LST.Quantity)
        local out = route_fn(hash, type(qty) == "number" and qty or 1)
        if out then
            safe_write(ref, LT.Output, out)
            safe_write(ref, LT.On, 1)
        else
            safe_write(ref, LT.On, 0)
        end
    else
        safe_write(ref, LT.On, 0)
    end
end

-- Hashes the classifier should send back to storage: every reagent the
-- controller handles, live-task cost vectors plus the durable residue
-- ledger. Covers both numeric and name keys (names resolve through hash()).
local function classifier_reagent_set()
    local set = {}
    local function add_keys(tbl)
        for key in pairs(tbl or {}) do
            if type(key) == "number" then
                set[key] = true
            elseif type(key) == "string" then
                local h = safe_hash(key)
                if h then
                    set[h] = true
                end
            end
        end
    end
    for _, task_id in ipairs(state.task_order) do
        local task = state.tasks[task_id]
        if task then
            add_keys(task.cost_vector)
        end
    end
    for _, amounts in pairs(state.residue) do
        add_keys(amounts)
    end
    return set
end

-- A classifier transit whose hash equals a task's product hash is a product
-- bound for the collection leg. Completion is counted from ExportCount while
-- the last item is still riding the output chute, so by the time it reaches
-- the sorter its task can already be terminal -- routing therefore consults
-- every task's product_hash (the field persists on the task record).
local function classifier_product(hash)
    local product = false
    for _, task_id in ipairs(state.task_order) do
        local task = state.tasks[task_id]
        if task then
            if task.product_hash == nil and type(task.item) == "string" then
                task.product_hash = safe_hash(task.item)
            end
            if task.product_hash == hash then
                if not TERMINAL[task.state] then
                    return true
                end
                product = true
            end
        end
    end
    return product
end

-- Per-tick routing service: steer both standard sorters, then advance the
-- armed transfer's lifecycle. Steering runs every tick so a held item always
-- meets a fresh decision; the transfer itself is serialized -- at most one
-- family's branch diverts at a time.
local function service_route()
    steer_sorter(state.ingress_ref, function(hash, qty)
        local route = state.route
        if route and route.hashes[hash] then
            return INGRESS_OUT_FEED
        end
        return INGRESS_OUT_RETURN
    end)
    local reagents = nil
    steer_sorter(state.classifier_ref, function(hash, qty)
        reagents = reagents or classifier_reagent_set()
        if reagents[hash] then
            -- A hash the armed delivery still expects reaching the OUTPUT
            -- side means it rode past every flip instead of diverting --
            -- surface the leak once instead of silently bouncing it home.
            local route = state.route
            if route and route.hashes[hash] and not route.leak_logged then
                route.leak_logged = true
                add_error("delivery_bounced",
                    "expected reagent " .. tostring(hash) ..
                    " reached the output classifier mid-transfer")
            end
            return CLASSIFIER_OUT_RETURN
        end
        if classifier_product(hash) then
            return CLASSIFIER_OUT_PRODUCT
        end
        -- Unknown prefab: hold it in the sorter and surface a diagnostic
        -- once, rather than guessing a leg.
        if not state.classifier_unknown[hash] then
            state.classifier_unknown[hash] = true
            add_error("classifier_unknown_item",
                "unclassified prefab " .. tostring(hash) .. " held at output")
        end
        return nil
    end)

    local route = state.route
    if not route then
        return
    end
    local task = state.tasks[route.task_id]
    if not task or TERMINAL[task.state] then
        -- The owning task is gone (cancelled/failed/completed): drop the
        -- route so any still-flying arrivals ride through to the return.
        route_release()
        return
    end
    if #(state.feed_refs[route.family_id] or {}) == 0 then
        -- No feed splitter exists for this family: nothing can be diverted,
        -- so import confirmation through the bus is impossible. Treat the
        -- transfer as confirmed and let the settle window run.
        route.import_complete = true
    elseif not route.import_complete then
        local pref = task.printer_ref or state.printer_by_name[route.family_id]
        if pref then
            -- Movement = the import counter growing, or the import slot
            -- holding an expected hash.
            local imports = safe_read(pref, LT.ImportCount)
            local occupant = safe_slot(pref, 0, LST.OccupantHash)
            if (type(imports) == "number" and
                imports > (route.last_imports or 0)) or
                (type(occupant) == "number" and route.hashes[occupant]) then
                route.saw_import = true
                route.last_import = state.tick
            end
            if type(imports) == "number" then
                route.last_imports = imports
                -- ClearMemory fires at start_print, typically AFTER the
                -- route armed: a read below the captured baseline is that
                -- reset, so the delta origin rebases to the restarted
                -- counter instead of a dead lifetime tally.
                if type(route.import_baseline) ~= "number" then
                    route.import_baseline = imports
                elseif imports < route.import_baseline then
                    route.import_baseline = 0
                end
            end
            -- The whole aggregate load is inside when the import counter's
            -- delta reaches it (post-clear counts) or the reagent DELTA over
            -- the route's own baseline does (stack-granularity counters,
            -- residue-blind). Releasing on anything less let late reagent
            -- deliveries ride the bus past every flip to the classifier.
            local need = (task.cost_total or 0) * task.count
            local reagents = safe_read(pref, LT.Reagents)
            if need > 0 and
                ((type(route.import_baseline) == "number" and
                     type(imports) == "number" and
                     imports - route.import_baseline >= need) or
                 (type(reagents) == "number" and
                     type(route.reagents_baseline) == "number" and
                     reagents - route.reagents_baseline >= need)) then
                route.import_complete = true
            end
        end
    end
    local delivered = task.resources_state == "delivered" or
        task.resources_state == "failed"
    -- A premature release is strictly worse than a patient hold: the gap
    -- between one reagent's last import and the next reagent's arrival can
    -- legitimately outlast any quiet-tick bound, and releasing there drops
    -- the in-flight delivery onto the classifier. The route therefore waits
    -- for the whole-load confirmation or the transfer timeout; a long quiet
    -- stretch is logged once, never released on.
    if delivered and route.saw_import and route.last_import and
        not route.stall_logged and
        state.tick - route.last_import >= IMPORT_GRACE_TICKS then
        route.stall_logged = true
        add_error("transfer_stalled",
            "task " .. tostring(route.task_id) ..
            " no import movement for " .. IMPORT_GRACE_TICKS ..
            " ticks; route still armed")
    end
    if delivered and route.import_complete then
        route.settle = route.settle + 1
    end
    if route.settle >= TRANSFER_SETTLE_TICKS then
        route_release()
    elseif state.tick - route.started >= TRANSFER_MAX_TICKS then
        add_error("transfer_timeout", "task " .. tostring(route.task_id) ..
            " route released unconfirmed after " .. TRANSFER_MAX_TICKS ..
            " ticks")
        route_release()
    end
end

-- Ejection lifecycle for a family's post-cancel residue. `Open` drives the
-- printer's internal reagent dump; the feed sorter holds its empty program
-- (the family has no live tasks, so the bus is in the all-through route), which
-- bounces any still-in-flight arrivals down the line to the storage return.
-- Nothing may print while Open is high, so queued tasks for the family hold
-- until the cycle closes.
local function eject_begin(family_id)
    local ref = state.printer_by_name[family_id]
    if ref then
        safe_write(ref, LT.Open, 1)
    end
    journal_append("eject_begin", tostring(family_id), { family_id = family_id })
    return true
end

-- The printer is empty when its internal reagent mass is zero and neither
-- slot holds anything. ImportQuantity/ExportQuantity and the slot-occupant
-- LogicTypes do not exist on these printers (autolathe LT set), so the real
-- signals are LT.Reagents plus per-slot Occupied reads; a printer variant
-- that answers none of them counts as empty (EJECT_MAX_TICKS bounds either
-- way), while any real read showing contents keeps the cycle open.
local function eject_is_empty(family_id)
    local ref = state.printer_by_name[family_id]
    if not ref then
        return true
    end
    local reagents = safe_read(ref, LT.Reagents)
    if type(reagents) == "number" and reagents > 0 then
        return false
    end
    local imp = safe_slot(ref, 0, LST.Occupied)
    if type(imp) == "number" and imp > 0 then
        return false
    end
    local exp = safe_slot(ref, 1, LST.Occupied)
    if type(exp) == "number" and exp > 0 then
        return false
    end
    local imp_occ = safe_read(ref, LT.ImportSlotOccupant)
    local exp_occ = safe_read(ref, LT.ExportSlotOccupant)
    return not (type(imp_occ) == "number" and imp_occ > 0) and
        not (type(exp_occ) == "number" and exp_occ > 0)
end

local function eject_end(family_id)
    local ref = state.printer_by_name[family_id]
    if ref then
        safe_write(ref, LT.Open, 0)
    end
    state.ejecting[family_id] = nil
    state.residue[family_id] = nil
    journal_append("eject_end", tostring(family_id), { family_id = family_id })
    checkpoint()
end

local function family_has_live_tasks(family_id)
    for _, task_id in ipairs(state.task_order) do
        local task = state.tasks[task_id]
        if task and task.family_id == family_id and not TERMINAL[task.state] then
            return true
        end
    end
    return false
end

-- Drain pass: residue returns to storage only once the family has no queued
-- or active work left. An Open printer cannot print, so ejecting never starts
-- mid-task; tasks that arrive during a cycle wait for it to close.
local function service_ejection()
    for family_id, amounts in pairs(state.residue) do
        if next(amounts) ~= nil then
            local started = state.ejecting[family_id]
            if not started then
                -- The drain-first check gates STARTING only: once a cycle is
                -- under way it must run to its bounded end even if new work
                -- queues behind it, or the queued task and the open cycle
                -- would wait on each other forever.
                if not family_has_live_tasks(family_id) then
                    eject_begin(family_id)
                    state.ejecting[family_id] = state.tick
                end
            else
                local elapsed = state.tick - started
                if elapsed >= EJECT_MAX_TICKS or
                    (elapsed >= EJECT_MIN_TICKS and eject_is_empty(family_id)) then
                    eject_end(family_id)
                end
            end
        end
    end
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
    -- A route whose owner went terminal must not block this service pass:
    -- release it before the queued/active gates below evaluate the bus.
    route_release_if_stale()
    if task.state == ST.QUEUED then
        local printer_ref = state.printer_by_name[task.family_id]
        -- A family mid-ejection cannot print (Open blocks it); the task stays
        -- queued until the residue cycle closes. Transfers are serialized:
        -- the shared bus may carry at most one delivery, so a queued task
        -- also waits while another family's route is armed.
        if printer_ref and not state.ejecting[task.family_id]
            and not state.route then
            -- The route is armed BEFORE the storage request fires so the
            -- delivery always meets a programmed path: the target branch
            -- diverts, every other branch passes through. The aggregated
            -- request then goes out BEFORE Activate so resources_state is
            -- already truthful when the tile flips to printing.
            route_open(task)
            request_storage_reservation(task)
            transition(task, ST.ACTIVE)
            local ok, err = start_print(printer_ref,
                state.printers[printer_ref], task)
            if ok == false then
                transition(task, ST.FAILED, err or "start_failed")
            end
            -- ok == nil: the counter clear was issued or is still being
            -- verified; the task is ACTIVE without a baseline and the ACTIVE
            -- branch continues the start on the next pass.
        end
    elseif task.state == ST.ACTIVE then
        -- Responses lost across a halt are re-issued here (storage dedupes by
        -- client_request_id); restore_state marks the record storage_retry.
        -- A re-issue needs the bus like any delivery: it waits for the
        -- current transfer to release, then arms its own route.
        local res_record = state.reserved_ledger[
            reservation_key(task.owner, task.reservation_id)]
        if res_record and res_record.storage_retry then
            if not state.route or state.route.task_id == task.task_id then
                res_record.storage_retry = nil
                if not state.route then
                    route_open(task)
                end
                request_storage_reservation(task)
            end
        end
        local printer_ref = task.printer_ref or state.printer_by_name[task.family_id]
        if not printer_ref then
            transition(task, ST.FAILED, "no_printer")
        elseif printer_faulted(printer_ref) then
            stop_print(printer_ref)
            record_residue(task)
            transition(task, ST.FAILED, "printer_fault")
        elseif task.export_baseline == nil then
            -- Not started yet (or the baseline could not be captured): try
            -- start_print; a transient counter-read failure keeps the task
            -- here and retries next tick, bounded by START_WAIT_MAX.
            local ok, err = start_print(printer_ref,
                state.printers[printer_ref], task)
            if ok == nil then
                task.start_wait = (task.start_wait or 0) + 1
                if task.start_wait >= START_WAIT_MAX then
                    transition(task, ST.FAILED, err or "start_failed")
                end
            elseif not ok then
                transition(task, ST.FAILED, err or "start_failed")
            end
        elseif task.resources_state == "failed" then
            -- The reservation was rejected or the sends errored: the job can
            -- never run, so fail it visibly instead of waiting forever.
            transition(task, ST.FAILED, "resources_unavailable")
        elseif task.resources_state == "delivered" then
            -- The fabricator drops Activate while it cannot produce, so it is
            -- pressed ONCE when the machine's stored reagent mass covers the
            -- whole job -- the user-visible "all items are in the printer".
            -- (Pressing from reservation-ack time just made the empty printer
            -- drop it again every tick.) The elapsed fallback covers a
            -- printer whose Reagents read never reflects the load.
            if not task.activated then
                -- Primed = THIS job's load inside: the reagent mass delta
                -- from the task's own pre-delivery baseline (so residue can
                -- never prime a machine that still lacks the recipe mass),
                -- or the cleared ImportCount reaching the aggregate count.
                local need = (task.cost_total or 0) * task.count
                local reagents = safe_read(printer_ref, LT.Reagents)
                local primed = type(reagents) == "number" and
                    type(task.reagents_baseline) == "number" and
                    reagents - task.reagents_baseline >= need
                if not primed then
                    local imports = safe_read(printer_ref, LT.ImportCount)
                    primed = type(imports) == "number" and imports >= need
                end
                task.delivered_ticks = (task.delivered_ticks or 0) + 1
                if not primed and
                    task.delivered_ticks >= ACTIVATE_FALLBACK_TICKS then
                    primed = true
                    add_error("activate_unprimed",
                        "task " .. tostring(task.task_id) ..
                        " activated without full reagent mass")
                end
                if primed then
                    safe_write(printer_ref, LT.On, 1)
                    safe_write(printer_ref, LT.Activate, 1)
                    task.activated = true
                end
            end
            local done, ratio = read_print_progress(printer_ref, task)
            if done ~= (task.done_count or 0) then
                task.done_count = done
                task.updated_tick = now()
                -- Progress is part of the visible state; bump the revision so
                -- revision-driven consoles redraw on it.
                state.sequence = state.sequence + 1
                task.sequence = state.sequence
            end
            task.partial = ratio
            if done >= task.count then
                stop_print(printer_ref)
                transition(task, ST.AWAITING_OUTPUT)
            end
        end
    elseif task.state == ST.AWAITING_OUTPUT then
        transition(task, ST.OUTPUT_DONE)
    elseif task.state == ST.OUTPUT_DONE then
        consume_batch(task.owner, task.reservation_id)
        transition(task, ST.COMPLETED)
        trim_history()
    end
end

local function service_tasks()
    -- Ejection first: it observes the task states from the previous tick, so a
    -- task that is still queued at the top of this pass correctly counts as
    -- live work and keeps the cycle from racing its own printer.
    service_ejection()
    -- Routing second: steer both standard sorters and advance the armed
    -- transfer BEFORE any task can fire a new reservation this tick, so a
    -- freshly claimed delivery always meets a programmed path.
    service_route()
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

-- Boot device sanitization: every controlled device lands in a known state,
-- mirroring the storage controller's boot contract. Feed flip-flops park in
-- the all-through route (strays ride to the storage return); both standard
-- sorters go to Logic mode holding their input. Printers that do not own a
-- durable in-flight task are deactivated, closed, and counter-cleared; a
-- printer whose task survived the restart keeps Activate untouched so
-- production resumes.
local function initialize_devices()
    for family_id, refs in pairs(state.feed_refs) do
        for _, ref in ipairs(refs) do
            safe_write(ref, LT.Mode, FEED_THROUGH_MODE)
            safe_write(ref, LT.On, 1)
        end
    end
    for _, ref in ipairs({ state.ingress_ref, state.classifier_ref }) do
        if ref then
            safe_write(ref, LT.Mode, SORTER_LOGIC_MODE)
            safe_write(ref, LT.Output, SORTER_OUTPUT_HOLD)
            safe_write(ref, LT.On, 0)
        end
    end
    for ref, record in pairs(state.printers) do
        local task_id = state.active_task_by_printer[ref]
        local task = task_id and state.tasks[task_id]
        if not (task and not TERMINAL[task.state]) then
            stop_print(ref)
            -- Idle printers keep their counters zeroed (the V3 pattern):
            -- lifetime tallies can never leak into the next task's baseline.
            safe_write(ref, LT.ClearMemory, 1)
        end
        -- Known state = powered, not activated, closed: Activate needs On=1 to
        -- run at all, so a powered-off printer looks dead to automation.
        safe_write(ref, LT.On, 1)
        safe_write(ref, LT.Open, 0)
    end
    -- A restored task whose reservation already fired may still have items in
    -- flight: re-arm its route so they divert into its printer instead of
    -- bouncing to storage. The bus can only arm one route, so other families'
    -- stragglers still ride through to the return (same collision bound the
    -- protocol always had); the task service loop owns the route from here.
    local resumed = nil
    for _, task_id in ipairs(state.task_order) do
        local t = state.tasks[task_id]
        if t and t.state == ST.ACTIVE and t.resources_state ~= nil
            and t.resources_state ~= "pending" then
            resumed = t
            break
        end
    end
    if resumed then
        route_open(resumed)
    else
        program_route(nil)
    end
end

-- Boot topology gate: every required device must be discovered AND carry the
-- expected prefab hash, or the chip refuses to start. A named-but-wrong
-- device (a sorter parked under a feed label, a Logic Sorter where the
-- standard sorter belongs, a missing printer family) is a hard failure:
-- partial topology silently misroutes or drops items, which is worse than a
-- loud boot error that names exactly what is missing.
local function verify_topology()
    local missing = {}
    for family_id = 1, 6 do
        if not state.printer_by_name[family_id] then
            missing[#missing + 1] = "printer " .. FAMILY_NAMES[family_id] ..
                " (" .. PREFAB_NAMES[family_id] .. ")"
        end
        local feeds = state.feed_refs[family_id] or {}
        if #feeds == 0 then
            missing[#missing + 1] = "feed splitter " .. NAME_FEED[family_id]
        else
            for _, ref in ipairs(feeds) do
                local ph = safe_read(ref, LT.PrefabHash)
                if ph ~= FEED_PREFAB_HASH_LEFT and
                    ph ~= FEED_PREFAB_HASH_RIGHT then
                    missing[#missing + 1] = NAME_FEED[family_id] ..
                        " device " .. tostring(ref) ..
                        " is not a digital flip flop (prefab " ..
                        tostring(ph) .. ")"
                end
            end
        end
    end
    local function check_sorter(ref, label)
        if not ref then
            missing[#missing + 1] = label
        elseif safe_read(ref, LT.PrefabHash) ~= SORTER_PREFAB_HASH then
            missing[#missing + 1] = label .. " device " .. tostring(ref) ..
                " is not a StructureSorter (prefab " ..
                tostring(safe_read(ref, LT.PrefabHash)) .. ")"
        end
    end
    check_sorter(state.ingress_ref, NAME_INGRESS)
    check_sorter(state.classifier_ref, NAME_CLASSIFIER)
    if #missing > 0 then
        for _, what in ipairs(missing) do
            print("PrinterController: missing required device: " .. what)
        end
        error("PrinterController: " .. tostring(#missing) ..
            " required device(s) missing or wrong prefab -- see log")
    end
end

local function initialize()
    print("PrinterController: booting")
    register_api()
    setup_bridges()
    restore_state()
    discover_printers()
    discover_feeds()
    verify_topology()
    initialize_devices()
    set_phase_or_fallback()
end

initialize()

while true do
    -- The whole tick is guarded: an uncaught error anywhere in the loop is
    -- captured, logged, and the chip survives to the next yield instead of
    -- halting. The journal/checkpoint inside service_tasks already make the
    -- recovery point durable; this is the last line of crash protection.
    local ok, err = pcall(function()
        state.tick = state.tick + 1
        -- Armed storage.get_state relays fire from tick context (the request
        -- is callback-only, so it cannot be sent from inside an RPC handler).
        service_inventory_fetch()
        if state.phase ~= "ready" then
            local printer_count = 0
            for _ in pairs(state.printers) do
                printer_count = printer_count + 1
            end
            if printer_count == 0 then
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
