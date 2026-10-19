-- tests/test_printer_console.lua : PrinterControlConsole RPC-isolation test.
--
-- Proves the console chip NEVER touches a storage controller; every stateful
-- action goes through Printer.Controller RPC only. Splices out the main loop,
-- drives the console's functions with a mocked ic.net/ss.ui/ic.persist/util,
-- and records every net request.

-- ================== File reading ==================

local function read_source(name)
    local f = io.open(("%s"):format(name), 'r')
    if not f then
        f = io.open(("../%s"):format(name), 'r')
    end
    f = assert(f, "cannot open " .. name .. " (run from repo root or tests/)")
    local s = f:read('*a')
    f:close()
    return s
end

-- ================== Mocks ==================

local net_requests = {}    -- every ic.net.request call: {target, method, payload}
local persist_store = {}

local function fresh_state()
    net_requests = {}
    persist_store = {}
end

local function make_sandbox()
    local s = setmetatable({ _G = {} }, { __index = _G })
    s.yield = function() end
    s.print = function() end
    s.os = setmetatable({ clock = function() return 1.0 end }, { __index = _G.os })
    s.math = math
    s.pcall = pcall
    s.setfenv = _G._setfenv or setfenv
    s.setmetatable = setmetatable
    s.type = type
    s.tostring = tostring
    s.tonumber = tonumber
    s.assert = assert
    s.error = error
    s.ipairs = ipairs
    s.pairs = pairs
    s.string = string
    s.table = table
    s.rawget = rawget
    s.rawset = rawset
    s.select = select

    s.ic = {
        net = {
            request = function(target, method, payload, cb, timeout)
                net_requests[#net_requests + 1] = { target = target, method = method, payload = payload }
                local resp
                if method == "printers.get_config" then
                    resp = { api_version = 1, ok = true, phase = "ready",
                        commission_check = false,
                        families = { { name = "TestFam", recipes = { { name = "IronBar", reagents = { Iron = 500 } } } },
                                     { name = "Pipe Bender", recipes = { { name = "ElbowJoint", reagents = { Copper = 200 } } } },
                                     { name = "BadFam", recipes = { { name = "BadItem", reagents = { BadReagent = 10 } } } } },
                    }
                elseif method == "printers.get_state" then
                    resp = { api_version = 1, ok = true, phase = "ready", task_count = 0, tasks = {},
                             revision = "rev-1" }
                elseif method == "printers.request" then
                    resp = { api_version = 1, ok = true, task_id = "task-1", queue_position = 1,
                             cost_vector = { Iron = 5 } }
                elseif method == "printers.cancel" then
                    resp = { api_version = 1, ok = true, task_id = "task-1" }
                else
                    resp = { api_version = 1, ok = false, err_code = "unknown_method" }
                end
                cb(true, resp, nil)
                return true
            end,
        },
        persist = {
            get = function(k) return persist_store[k] end,
            set = function(k, v) persist_store[k] = v end,
        },
    }
    s.util = {
        json = {
            encode = function(tbl) return "encoded" end,
            decode = function(str) return str end,
        },
    }
    s.ss = {
        ui = {
            surface = function(id)
                local surface = {}
                function surface:size() return { w = 1024, h = 768 } end
                function surface:clear() end
                function surface:element(spec) end
                return surface
            end,
            activate = function(id) end,
        },
    }
    s.pcall = pcall
    -- Engine Animator.StringToHash / IC10 HASH() mock: a deterministic
    -- string->number hash with a prefab_name inverse, so a display_name(hash)
    -- round-trips in the harness and the console's runtime name->hash path is
    -- exercised (names are resolved to the controller/storage-facing prefab_hash).
    local _hash_fwd = {}
    local _hash_rev = {}
    s.hash = function(name)
        if type(name) ~= "string" then
            return 0
        end
        -- Sentinel: a reagent the engine cannot hash surfaces as a pcall failure,
        -- locking the console's "refuse, do not crash, do not emit a half-resolved
        -- vector" branch (Test 3c).
        if name == "BadReagent" then
            error("sentinel: cannot hash reagent", 0)
        end
        local cached = _hash_fwd[name]
        if cached then
            return cached
        end
        local h = 0
        for i = 1, #name do
            h = (h * 31 + string.byte(name, i)) % 2147483647
        end
        _hash_fwd[name] = h
        _hash_rev[h] = name
        return h
    end
    s.prefab_name = function(h)
        return _hash_rev[h]
    end
    s._G = s
    setfenv(1, s)
    return s, net_requests, persist_store
end

-- ================== Splice the main loop out ==================

local function new_module()
    local source = read_source('PrinterControlConsole.lua')
    local marker, marker_end = source:find("-- ================== Main loop ==================", 1, true)
    if not marker then
        error("could not find main-loop marker in PrinterControlConsole.lua")
    end
    local body = string.sub(source, 1, marker - 1)
    body = body .. "\nreturn { state=state, submit_request=submit_request, cancel_task=cancel_task, fetch_controller_state=fetch_controller_state, fetch_controller_config=fetch_controller_config }\n"
    local chunk, err = loadstring(body)
    if not chunk then
        error("printer console body failed to load: " .. tostring(err))
    end
    local sandbox, _net, _persist = make_sandbox()
    chunk_run = chunk
    setfenv(chunk_run, sandbox)
    local okrun, module, run_err = pcall(chunk_run)
    if not okrun then
        error("printer console run failed: " .. tostring(module))
    end
    if type(module) ~= "table" then
        error("printer console did not return a module table; got " .. type(module))
    end
    return module, sandbox._G
end

-- ================== Test helpers ==================

local passed = 0
local failed = 0
local function ok(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("  [FAIL] %s", tostring(msg)))
    end
end
local function check(msg, cond) ok(cond, msg) end

-- ================== Load ==================

print("\n=== test_printer_console: RPC isolation ===")
local mod, chunk_run = new_module()

check("console module returned", mod ~= nil)
check("exposes submit_request", mod.submit_request ~= nil)
check("exposes cancel_task", mod.cancel_task ~= nil)
check("exposes fetch_controller_state", mod.fetch_controller_state ~= nil)
check("exposes fetch_controller_config", mod.fetch_controller_config ~= nil)
check("exposes state", mod.state ~= nil)

-- ================== Test 1: config + load did not touch storage ==================

print("\n--- Test 1: init/config never touches storage ---")
local function any_storage_contact()
    for _, req in ipairs(net_requests) do
        if req.target == "Storage.Controller" or req.target == "Storage.Console" then
            return true
        end
        if type(req.method) == "string" and string.find(req.method, "^storage%.", 1, true) then
            return true
        end
    end
    return false
end
check("no storage controller contact", not any_storage_contact())
check("all requests target Printer.Controller", (function()
    for _, req in ipairs(net_requests) do
        if req.target ~= "Printer.Controller" then return false end
    end
    return true
end)())
check("all methods are printers.*", (function()
    for _, req in ipairs(net_requests) do
        if type(req.method) == "string" then
            if not string.find(req.method, "^printers%.") then return false end
        end
    end
    return true
end)())
check("a printers.get_config was issued", (function()
    for _, req in ipairs(net_requests) do
        if req.method == "printers.get_config" then return true end
    end
    return false
end)())
check("config response set families on controller_config",
    mod.state.controller_config ~= nil and mod.state.controller_config.families ~= nil)

-- ================== Test 2: not-ready refuses submit ==================

print("\n--- Test 2: submit refused when controller not ready ---")
-- controller_state is nil after load (init only fetched config + rendered).
local rid = mod.submit_request()
check("submit_request returns nil when not ready", rid == nil)
check("no printers.request issued while not ready", (function()
    for _, req in ipairs(net_requests) do
        if req.method == "printers.request" then return false end
    end
    return true
end)())

-- ================== Test 3: ready submit issues printers.request ==================

print("\n--- Test 3: ready submit issues printers.request with the right payload ---")
-- Make the controller report ready.
mod.fetch_controller_state()
check("controller_state is ready after poll",
    mod.state.controller_state ~= nil and mod.state.controller_state.phase == "ready")

mod.state.preferences.selected_family = "TestFam"
mod.state.preferences.selected_recipe = "IronBar"
mod.state.preferences.selected_quantity = 4

rid = mod.submit_request()
check("submit_request returned a client request id", type(rid) == "string" and #rid > 0)
local last_request
for i = #net_requests, 1, -1 do
    if net_requests[i].method == "printers.request" then
        last_request = net_requests[i]
        break
    end
end
check("a printers.request was issued", last_request ~= nil)
check("printer.request targeted Printer.Controller", last_request and last_request.target == "Printer.Controller")
check("printer.request carried family_name", last_request and last_request.payload.family_name == "TestFam")
check("printer.request carried recipe", last_request and last_request.payload.recipe == "IronBar")
check("printer.request carried quantity", last_request and last_request.payload.quantity == 4)
check("printer.request carried a client_request_id", last_request and type(last_request.payload.client_request_id) == "string")
check("printer.request used the console destination", last_request and last_request.payload.destination_id == "Printer.Console")
-- The console packed the per-ONE-item grams as a HASH-KEYED cost_vector
-- (prefab_hash -> grams) plus a UI-only reagent_labels table; the catalog-free
-- controller aggregates x count itself on the source chip.
check("printer.request carried a cost_vector",
    last_request and type(last_request.payload.cost_vector) == "table")
do
    local cv = last_request and last_request.payload.cost_vector
    local labels = last_request and last_request.payload.reagent_labels
    local all_numeric_key, found_500, single_hash, keys = true, false, nil, 0
    for k, v in pairs(cv or {}) do
        keys = keys + 1
        if type(k) ~= "number" then
            all_numeric_key = false
        end
        if v == 500 then
            found_500 = true
        end
        single_hash = k
    end
    check("cost_vector is HASH-keyed: every key is a prefab_hash number",
        keys > 0 and all_numeric_key)
    check("cost_vector carries the per-item Iron gram amount (500)", found_500)
    -- The reagent NAME must NOT leak into the controller/storage key space.
    check("cost_vector is not name-keyed (no 'Iron' string key)",
        not (cv and type(cv["Iron"]) == "number"))
    -- The display name lives only in the parallel UI/log label table.
    check("reagent_labels maps the hashed reagent to its display name",
        type(labels) == "table" and labels[single_hash] == "Iron")
end
check("printer.request carried the single item name",
    last_request and last_request.payload.item == "IronBar")
check("printer.request carried the count (items to print)",
    last_request and last_request.payload.count == 4)

-- ================== Test 3b: unresolvable recipe is refused, not a crash ==================

print("\n--- Test 3b: an unresolvable recipe is refused (no printers.request) ---")
local reqs_before = (#net_requests)
mod.state.preferences.selected_family = "TestFam"
mod.state.preferences.selected_recipe = "GhostRecipe"  -- not in the config
local rid_refuse = mod.submit_request()
check("submit_request refused with nil when the recipe cannot be resolved", rid_refuse == nil)
check("no new printers.request was issued for an unresolvable recipe",
    (function()
        for i = reqs_before + 1, #net_requests do
            if net_requests[i].method == "printers.request" then return false end
        end
        return true
    end)())

-- ================== Test 3c: a reagent the engine cannot hash is refused, not a crash ==================

print("\n--- Test 3c: an un-hashable reagent refuses the submit (no crash, no request) ---")
local reqs_before3c = #net_requests
mod.state.preferences.selected_family = "BadFam"
mod.state.preferences.selected_recipe = "BadItem"  -- its only reagent cannot be hashed
local rid_hash = mod.submit_request()
check("submit_request refused with nil when a reagent cannot be hashed to a prefab_hash",
    rid_hash == nil)
check("no printers.request was issued for an un-hashable reagent",
    (function()
        for i = reqs_before3c + 1, #net_requests do
            if net_requests[i].method == "printers.request" then return false end
        end
        return true
    end)())

-- ================== Test 4: cancel goes through printers.cancel ==================

print("\n--- Test 4: cancel routes through printers.cancel ---")
mod.cancel_task("task-1", "console_cancel")
local last_cancel
for i = #net_requests, 1, -1 do
    if net_requests[i].method == "printers.cancel" then
        last_cancel = net_requests[i]
        break
    end
end
check("a printers.cancel was issued", last_cancel ~= nil)
check("cancel targeted Printer.Controller", last_cancel and last_cancel.target == "Printer.Controller")
check("cancel carried request_id", last_cancel and last_cancel.payload.request_id == "task-1")
check("cancel carried requester_id", last_cancel and type(last_cancel.payload.requester_id) == "string")

-- ================== Test 5: no storage contact even after many ops ==================

print("\n--- Test 5: full op sequence never contacts storage ---")
mod.fetch_controller_state()
mod.fetch_controller_config()
mod.submit_request()
mod.cancel_task("task-1")
check("still no storage contact after the full sequence", not any_storage_contact())

-- ================== Test 6: uuid + prefs persisted via ic.persist ==================

print("\n--- Test 6: uuid + prefs persisted ---")
check("console uuid is a 36-char string", type(mod.state.console_uuid) == "string" and #mod.state.console_uuid == 36)
check("uuid stored under the console key", persist_store["printerc_console_uuid"] == mod.state.console_uuid)

-- ================== Summary ==================

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
print("All PrinterControlConsole RPC-isolation tests passed.")
