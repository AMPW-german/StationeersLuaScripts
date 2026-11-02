-- Printer Control Console (ScriptedScreens UI).
-- Separate ScriptedScreens UI chip. This chip NEVER talks to storage directly
-- (it owns no storage controller); every stateful action goes through the
-- Printer.Controller RPC surface only. The reservation/queue/printer work is the
-- controller's job.
--
-- RPC surface used (all to "LuaC.Printer.Controller"):
--   printers.get_state     -> poll phase/revision/tasks/printer summary
--   printers.get_inventory -> relayed storage quantities (recipe pages only)
--   printers.request       -> submit a print job
--   printers.cancel        -> cancel a queued/paused/active task
-- The recipe list is NOT served over RPC: this chip requires the PrinterCatalog
-- library chip over the network (loaded once at chip start; a catalog redeploy
-- applies on the next console reload).
--
-- Pages: "main" (3x2 printer tiles + queue bar), "printer" (one family: its
-- task bar + locked recipe list), "recipes" (filtered/paginated catalog +
-- request bar), "tasks" (per-family queue rows + task-detail overlay).

local API_VERSION = 2
local POLL_INTERVAL = 1.0
-- While a recipe-bearing page is open the console re-fetches the relayed
-- inventory on this interval; the controller itself caches storage.get_state
-- for 2 s, so this never hammers the storage line.
local INVENTORY_REFRESH = 5.0

-- ================== User config ==================
-- Interconnect naming: ic.net targets resolve a HOUSING's labeller name, and
-- housings cross Logic Filter Bridges only when their display name contains
-- NET_TAG (max 6 ASCII chars -- the bridge's packed Setting budget). Label the
-- printer controller's housing LuaC.Printer.Controller, this console's housing
-- LuaC.Printer.Console, and every Logic Filter Bridge LuaBridge.
local NET_TAG = "LuaC."
local CONTROLLER_TARGET = "LuaC.Printer.Controller"
local CONSOLE_DESTINATION_ID = "Printer.Console"
local BRIDGE_NAME = "LuaBridge"
local BRIDGE_PREFAB_HASH = 1273838679 -- StructureLogicFilterBridge
local BRIDGE_NAME_MODE = 2            -- mode 2: display name contains packed Setting

local LT = ic.enums and ic.enums.LogicType or {}

-- The six printable families. `name` is the controller's routing name
-- (payload.family_name; printer_by_name lookup); `cat` is the PrinterCatalog
-- families-table key. They differ for family 2 ("pipe_bender" vs "pipebender")
-- -- sending the catalog key to the controller would fall back to family 1.
-- `ingots` is a support family in the catalog, not a printer, and is excluded.
local FAMILIES = {
    { id = 1, name = "autolathe",   cat = "autolathe",   label = "Autolathe" },
    { id = 2, name = "pipe_bender", cat = "pipebender",  label = "Pipe Bender" },
    { id = 3, name = "electronics", cat = "electronics", label = "Electronics" },
    { id = 4, name = "rocket",      cat = "rocket",      label = "Rocket" },
    { id = 5, name = "tool",        cat = "tool",        label = "Tool" },
    { id = 6, name = "security",    cat = "security",    label = "Security" },
}
local FAMILY_BY_ID = {}
local FAMILY_BY_CTL = {}
local FAMILY_BY_CAT = {}
for _, f in ipairs(FAMILIES) do
    FAMILY_BY_ID[f.id] = f
    FAMILY_BY_CTL[f.name] = f
    FAMILY_BY_CAT[f.cat] = f
end

-- controller family name -> catalog key (falls back to the name itself so
-- test/custom names still resolve); catalog key -> controller name likewise.
local function catalog_key(ctl_name)
    local f = FAMILY_BY_CTL[ctl_name]
    return f and f.cat or ctl_name
end
local function ctl_name(cat_key)
    local f = FAMILY_BY_CAT[cat_key]
    return f and f.name or cat_key
end

-- Controller-computed printer statuses -> tile background.
local STATUS_COLORS = {
    absent = "#3A3A46",
    idle = "#475569",
    printing = "#22C55E",
    waiting_resources = "#EAB308",
    ejecting = "#38BDF6",
    fault = "#EF4444",
}
local QUEUED_BG = "#1E3A5F"     -- not-yet-started task bars
local PROGRESS_FILL = "#22C55E" -- left-to-right done fill

-- Task states that never come back (filtered out of queue bars and ranks).
local TERMINAL_STATES = {
    completed = true, failed = true, cancelled = true, aborted = true,
}
local CANCELLABLE_STATES = {
    queued = true, paused = true, active = true, awaiting_output = true,
}

-- ================== Helpers ==================

local function safe_call(fn, ...)
    local result = { pcall(fn, ...) }
    if not result[1] then
        print("Console error: " .. tostring(result[2]))
        return nil, result[2]
    end
    return result[2]
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
        if safe_call(ic.read_id, ref_id, LT.PrefabHash) == BRIDGE_PREFAB_HASH then
            local _, e1 = safe_call(ic.write_id, ref_id, LT.Setting, setting)
            local _, e2 = safe_call(ic.write_id, ref_id, LT.Mode, BRIDGE_NAME_MODE)
            local _, e3 = safe_call(ic.write_id, ref_id, LT.On, 1)
            if e1 or e2 or e3 then
                print("PrinterConsole: bridge " .. tostring(ref_id) .. " config write failed")
            end
        end
    end
end

local function clamp(value, min, max)
    if not value then return min end
    if value < min then return min end
    if value > max then return max end
    return value
end

-- Display-name shortening for task panels and rows: a 16-char budget is the
-- readability guarantee; anything longer is cut to `n-2` + "..".
local function trunc(s, n)
    s = tostring(s or "?")
    if #s > n then
        return string.sub(s, 1, n - 2) .. ".."
    end
    return s
end

-- ss icon_type "prefab" resolves `name` against prefab NAMES; a stringified
-- hash hashes AGAIN and renders as a white square. Resolve the hash through
-- the engine's prefab_name() where it exists.
local function prefab_icon_name(v)
    if type(v) == "number" and type(prefab_name) == "function" then
        local n = safe_call(prefab_name, v)
        if type(n) == "string" and n ~= "" then
            return n
        end
    end
    return tostring(v or "")
end

local function fmt_time(sec)
    if type(sec) ~= "number" then return "--" end
    sec = math.floor(sec + 0.5)
    if sec < 60 then return tostring(sec) .. "s" end
    if sec < 3600 then
        return string.format("%dm%02ds", math.floor(sec / 60), sec % 60)
    end
    return string.format("%dh%02dm", math.floor(sec / 3600), math.floor((sec % 3600) / 60))
end

local function generate_uuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    local function replace_char(c)
        if c == 'x' then
            return string.format('%x', math.random(0, 15))
        elseif c == 'y' then
            return string.format('%x', math.random(8, 11))
        else
            return c
        end
    end
    return string.gsub(template, '.', replace_char)
end

-- Centralized display-name converter. Internally the chip speaks prefab HASHES;
-- names exist only here, for UI and logs (mirroring the storage console's
-- item_name, which is the storage side's hash->name display path). For now it
-- only strips the leading "Item" token (case-insensitive), e.g.
-- "ItemCopperIngot" -> "CopperIngot". This is the SINGLE place a display name is
-- derived, so UI and log paths can never diverge; expand it here, not at call sites.
local function display_name(name_or_hash)
    local s
    if type(name_or_hash) == "string" then
        s = name_or_hash
    elseif type(name_or_hash) == "number" then
        s = safe_call(prefab_name, name_or_hash) or tostring(name_or_hash)
    else
        s = tostring(name_or_hash)
    end
    return string.gsub(s, "^([iI]tem)", "")
end

-- Guarded runtime name -> prefab_hash resolution. The console resolves a recipe
-- reagent to its PREFAB/ITEM name first (resolve_item_name, via the manual
-- ReagentItemMap bridge or the raw catalog name), and THIS hashes that name via
-- the engine's Animator.StringToHash / IC10 HASH() to key the cost vector.
-- Guarded so a missing or guarded engine capability logs and refuses (the recipe
-- is not submitted, no half-resolved vector is emitted) instead of crashing.
local function resolve_prefab_hash(name)
    if type(hash) ~= "function" then
        return nil, "no_hash_fn"
    end
    if type(name) ~= "string" then
        return nil, "bad_reagent_name"
    end
    local ok, h = pcall(hash, name)
    if not ok or type(h) ~= "number" then
        return nil, "hash_failed"
    end
    return h, nil
end

-- ================== State ==================

local state = {
    console_uuid = nil,
    controller_state = nil,
    catalog = nil,
    last_state_revision = nil,
    -- Relayed storage inventory: { map = prefab_hash -> {quantity, available},
    -- revision, fetched_at }. Only populated while a recipe page is/was open;
    -- nil means "unavailable" (max-buildable renders "--", reagents uncolored).
    inventory = nil,
    inventory_fetched_at = -1e9,
    -- Per-reagent-name resolution cache: name -> prefab_hash or false when the
    -- engine cannot hash it. Keeps the max-buildable math cheap across renders.
    reagent_hash_cache = {},
    -- UI navigation: page stack for the back button.
    page = "main",
    nav = {},
    page_family = nil,          -- family id when page == "printer"
    task_filter_family = nil,   -- family id highlight on the tasks page
    detail_task_id = nil,       -- open task-detail overlay
    detail_task = nil,          -- last-rendered task snapshot for the overlay
    -- Recipe filters shared by the recipes page and the printer page list.
    filters = {
        family = nil,           -- catalog key; nil = all families
        source = nil,           -- "vanilla" or a workshop id string; nil = all
        search = "",            -- case-insensitive substring (no patterns)
        buildable_only = false,
        sort = "name",          -- "name" | "buildable"
        page = 1,
    },
    last_error = nil,           -- surfaced on the header error line
    ui_dirty = true,
    -- Element ids whose props change with controller progress but whose
    -- existence is structural (task progress bars, counts, header lines).
    -- A surface rebuild destroys open select popups and in-progress
    -- textinput text, so progress-only revision bumps push set_props
    -- through handles instead of rebuilding. Rebuilt every render.
    dyn = {},
    last_sig = nil,             -- structural signature of the last render
    last_rendered_revision = nil,
    preferences = {
        selected_family = nil,  -- CONTROLLER family name (payload-facing)
        selected_recipe = nil,  -- catalog recipe key (prefab name)
        selected_quantity = 1,
    },
    request_sequence = 0,
    offline = false,
    ui_surface = nil,
    -- MANUAL name->prefab(item)-name bridge (the single place to fix a recipe
    -- reagent's hash input). Loaded once below from ReagentItemMap.lua; when the
    -- module is absent it stays empty and every reagent hashes its raw catalog
    -- name (the current behaviour). See resolve_item_name / resolve_prefab_hash.
    reagent_item_map = {},
}

-- Load the manual name->item bridge once. The basic ingots/ressources rarely
-- change, so a hand-maintained table is stable. A missing/declining module
-- (e.g. a chip without a require, or a not-yet-deployed map) degrades to the
-- empty table above: every reagent then hashes its own raw catalog name -- the
-- pre-existing behaviour -- so nothing breaks and nothing guesses silently.
do
    -- Accept both module shapes: { reagents = {...} } or the reagent table
    -- itself. A failed/shapeless require is logged (it used to fail silently,
    -- leaving every reagent on the raw-name fallback).
    local ok_rim, rim = pcall(require, "ReagentItemMap")
    local reagents = nil
    if ok_rim and type(rim) == "table" then
        reagents = rim.reagents or (type(rim["Iron"]) == "table" and rim or nil)
    end
    if type(reagents) == "table" then
        state.reagent_item_map = reagents
    else
        print("PrinterConsole: ReagentItemMap load failed (" .. tostring(
            not ok_rim and rim or "module exposes no .reagents table") ..
            "); reagent hashes use raw names until it is fixed")
    end
    -- The recipe catalog is likewise a passive library chip loaded once over the
    -- network. No periodic refresh: a catalog redeploy is rare and applies on
    -- the next console reload. Absent/declining -> state.catalog stays nil and
    -- every recipe lookup degrades to no_config instead of a crash.
    local ok_cat, cat = pcall(require, "PrinterCatalog")
    if ok_cat and type(cat) == "table" then
        state.catalog = cat
    end
end

-- ================== RPC helpers ==================

-- RPC helper: request against the printer controller only.
local function safe_rpc_call(method, payload, callback)
    local ok, err = pcall(ic.net.request, CONTROLLER_TARGET, method, payload,
        function(resp_ok, response, rpc_err)
            if not resp_ok then
                state.offline = true
                if callback then callback(nil, "rpc_error") end
                return
            end
            state.offline = false
            if response and response.api_version == API_VERSION then
                if callback then callback(response, nil) end
            else
                if callback then callback(nil, "invalid_response") end
            end
        end, 5)
    if not ok then
        state.offline = true
        if callback then callback(nil, "rpc_unavailable") end
    end
    return ok
end

-- ================== Persistence ==================

local PREFERENCES_KEY = "printerc_console_prefs"
local UUID_KEY = "printerc_console_uuid"

local function persist_preferences()
    local prefs_to_save = {
        page = state.page,
        page_family = state.page_family,
        task_filter_family = state.task_filter_family,
        filters = state.filters,
        selected_family = state.preferences.selected_family,
        selected_recipe = state.preferences.selected_recipe,
        selected_quantity = state.preferences.selected_quantity,
    }
    local ok, encoded = pcall(util.json.encode, prefs_to_save)
    if ok and encoded then
        safe_call(ic.persist.set, PREFERENCES_KEY, encoded)
    end
end

local function restore_preferences()
    local encoded = safe_call(ic.persist.get, PREFERENCES_KEY)
    if encoded then
        local ok, decoded = pcall(util.json.decode, encoded)
        if ok and type(decoded) == "table" then
            state.page = decoded.page or "main"
            state.page_family = decoded.page_family
            state.task_filter_family = decoded.task_filter_family
            if type(decoded.filters) == "table" then
                for k, v in pairs(decoded.filters) do
                    state.filters[k] = v
                end
            end
            state.preferences.selected_family = decoded.selected_family
            state.preferences.selected_recipe = decoded.selected_recipe
            if decoded.selected_quantity then
                state.preferences.selected_quantity = decoded.selected_quantity
            end
        end
    end
end

local function initialize_console_uuid()
    local stored = safe_call(ic.persist.get, UUID_KEY)
    if stored and type(stored) == "string" and #stored == 36 then
        state.console_uuid = stored
    else
        state.console_uuid = generate_uuid()
        safe_call(ic.persist.set, UUID_KEY, state.console_uuid)
    end
end

-- ================== RPC surface wiring ==================

local function fetch_controller_state(callback)
    safe_rpc_call("printers.get_state", {
        api_version = API_VERSION,
        include_tasks = true,
    }, function(result, err)
        if result then
            state.controller_state = result
            state.last_state_revision = result.revision
        end
        if callback then callback(result, err) end
    end)
end

-- The single storage-facing call, relayed by the controller. Fired on recipe-
-- page entry and on INVENTORY_REFRESH while a recipe page is open; the main
-- and tasks pages never touch it.
local function fetch_inventory(callback)
    safe_rpc_call("printers.get_inventory", {
        api_version = API_VERSION,
    }, function(result, err)
        state.inventory_fetched_at = os.clock()
        if result and result.ok then
            -- Only a real change (first data or a new revision) warrants a
            -- rebuild; every-refresh ui_dirty was destroying open dropdowns
            -- on the 5-second inventory poll.
            local new_rev = result.revision
            if state.inventory == nil or state.inventory.revision ~= new_rev then
                state.ui_dirty = true
            end
            state.inventory = {
                map = result.inventory or {},
                revision = new_rev,
            }
            state.inventory_failed = nil
        elseif result and not state.inventory_failed then
            -- Controller reachable but storage not: mark the failure once so
            -- the "--" placeholders appear, then stay quiet until it changes.
            state.inventory_failed = true
            state.ui_dirty = true
        end
        if callback then callback(result, err) end
    end)
end

-- ================== Actions ==================

-- Resolve the prefab/ITEM name to HASH for a reagent, using the manual
-- ReagentItemMap bridge (state.reagent_item_map). The catalog names reagents by
-- their in-game/english name ("Iron", "Blue Coloring"); the engine's hash() and
-- storage's prefab_hash expect the PREFAB name (e.g. "ItemIronIngot"), so the
-- bridge is the single, fillable place that translates name -> prefab name.
--   VERIFIED entry  -> hash entry.item  (the correct prefab name).
--   missing/unver.  -> hash the raw reagent name (current behaviour) and print
--                      ONE warning, so the gap is visible and filling the map
--                      progressively corrects the hash input without a restart.
local mapped_warned = {}
local function resolve_item_name(reagent)
    local map = state.reagent_item_map
    local entry = (type(map) == "table" and map[reagent]) or nil
    if type(entry) == "table" and type(entry.item) == "string" and entry.verified ~= false then
        return entry.item
    end
    if not mapped_warned[reagent] then
        mapped_warned[reagent] = true
        local why = (entry == nil) and "no name->item mapping" or "an UNVERIFIED mapping"
        print("PrinterConsole: reagent '" .. tostring(reagent) .. "' has " .. why ..
            " in ReagentItemMap.lua; hashing its raw name until it is filled in.")
    end
    return reagent
end

-- Cached reagent name -> prefab hash for the max-buildable math (the same
-- resolve_item_name + hash path the submit uses, memoized so rendering a page
-- of recipes does not re-hash every reagent every time).
local function reagent_hash(reagent)
    local cached = state.reagent_hash_cache[reagent]
    if cached == nil then
        local h = resolve_prefab_hash(resolve_item_name(reagent))
        cached = h or false
        state.reagent_hash_cache[reagent] = cached
    end
    return cached ~= false and cached or nil
end

-- Resolve the per-single-item reagent grams for the selected recipe.
--
-- The controller is catalog-free: it TRUSTS the per-item cost vector this chip
-- packs, and aggregates (per-item x count) into the storage request(s) when the
-- task is reached. So the console owns the "single item" knowledge: it pulls the
-- recipe's per-reagent gram amounts from the PrinterCatalog module (required
-- over the network once at chip start),
-- strips zeros, and HASHES each reagent name to its prefab hash, yielding a
-- clean { prefab_hash = grams } vector for ONE item plus a parallel
-- { prefab_hash = display_name } label table for UI/logs only. It never touches
-- storage and never carries a controller revision. Returns (cost_vector,
-- labels, nil) on success or (nil, nil, reason) on a refusal
-- (no_config/unknown_family/unknown_recipe/hash_unavailable).
local function resolve_recipe_cost_vector(cat_family, recipe_name)
    local catalog = state.catalog
    if type(catalog) ~= "table" or type(catalog.families) ~= "table" then
        return nil, nil, "no_config"
    end
    -- PrinterCatalog.families maps family name -> { item_prefab_name -> recipe };
    -- the recipe KEY is the prefab name the controller hashes at runtime, and
    -- `valid` flags recipes the generator marked unprintable.
    local fam_recipes = catalog.families[cat_family]
    if type(fam_recipes) ~= "table" then
        return nil, nil, "unknown_family"
    end
    local recipe_entry = fam_recipes[recipe_name]
    if type(recipe_entry) ~= "table" or recipe_entry.valid == false or
        type(recipe_entry.reagents) ~= "table" then
        return nil, nil, "unknown_recipe"
    end
    local per_item = {}
    local labels = {}
    -- The catalog names reagents by english/in-game name; the controller/storage
    -- speak prefab HASHES, so resolve each positive reagent to its prefab/ITEM
    -- name (via the manual ReagentItemMap bridge, or the raw name when unmapped)
    -- and hash THAT. One gramm == one item, so a reagent's per-item grams pass
    -- straight through. A parallel labels table keeps the human reagent name for
    -- UI / logs only -- it is NEVER the controller/storage key.
    for reagent, grams in pairs(recipe_entry.reagents) do
        if type(reagent) == "string" and type(grams) == "number" and grams > 0 then
            local item = resolve_item_name(reagent)
            local h, herr = resolve_prefab_hash(item)
            if not h then
                -- A reagent we cannot resolve to a hash blocks this recipe: the
                -- catalog-free controller would reject a name-keyed vector as
                -- invalid. Log and refuse rather than emit a half-resolved vector.
                print("PrinterConsole: cannot hash reagent '" .. reagent .. "' for " ..
                    tostring(cat_family) .. "/" .. tostring(recipe_name) .. " (" ..
                    tostring(herr) .. ")")
                return nil, nil, herr or "hash_failed"
            end
            if per_item[h] then
                per_item[h] = per_item[h] + grams
            else
                per_item[h] = grams
            end
            labels[h] = display_name(reagent)
        end
    end
    return per_item, labels, nil
end

-- Submits a print job to the controller. Returns the client request id.
function submit_request()
    local family = state.preferences.selected_family
    local recipe = state.preferences.selected_recipe
    if not family or not recipe then
        state.last_error = "no recipe selected"
        state.ui_dirty = true
        return nil
    end
    if state.offline or not state.controller_state or state.controller_state.phase ~= "ready" then
        state.last_error = "controller not ready"
        state.ui_dirty = true
        return nil
    end

    -- The console sends the per-single-item grams as a HASH-KEYED cost_vector
    -- (prefab_hash -> grams) plus the count and a UI-only display-name table; the
    -- catalog-free controller aggregates (per-item x count) and requests storage
    -- once the task is reached.
    local cost_vector, labels, cost_err =
        resolve_recipe_cost_vector(catalog_key(family), recipe)
    if not cost_vector then
        -- Surface the refusal reason instead of letting a malformed request
        -- silently fall out (the controller would reject it anyway).
        state.last_error = "cannot resolve recipe: " .. tostring(cost_err)
        state.ui_dirty = true
        print("PrinterConsole: cannot resolve recipe for " .. tostring(family) .. "/" ..
            tostring(recipe) .. " (" .. tostring(cost_err) .. ")")
        return nil
    end

    local count = clamp(math.floor(tonumber(state.preferences.selected_quantity) or 1), 1, 1000000)

    state.request_sequence = state.request_sequence + 1
    local client_request_id = string.format("pcc-%s-%d-%d",
        state.console_uuid,
        math.floor(os.clock() * 1000),
        state.request_sequence)

    local payload = {
        api_version = API_VERSION,
        client_request_id = client_request_id,
        family_name = family,          -- routing topology key (controller-owned)
        item = recipe,                 -- product prefab name (RecipeHash input)
        cost_vector = cost_vector,     -- per-ONE-item reagent grams, HASH-KEYED (prefab_hash = grams)
        reagent_labels = labels,       -- HASH -> display name, UI/logs only (never a controller/storage key)
        count = count,                 -- items to print; controller aggregates x count
        destination_id = CONSOLE_DESTINATION_ID,
    }

    safe_rpc_call("printers.request", payload, function(result, rpc_err)
        if result and result.ok then
            state.last_error = nil
            print("PrinterConsole: submitted " .. tostring(result.task_id))
            fetch_controller_state()
        else
            -- Display the controller's error code so the operator can act on it.
            local code = tostring(rpc_err or (result and (result.err_code or result.code)) or "unknown")
            state.last_error = "request failed: " .. code
            print("PrinterConsole: request failed: " .. code)
        end
        state.ui_dirty = true
    end)
    return client_request_id
end

-- Cancels a queued / paused / active task.
function cancel_task(task_id, reason)
    local payload = {
        api_version = API_VERSION,
        task_id = task_id,
        reason = reason or "console_cancel",
        requester_id = state.console_uuid,
    }
    safe_rpc_call("printers.cancel", payload, function(result, rpc_err)
        if result and result.ok then
            state.last_error = nil
            state.detail_task_id = nil
            print("PrinterConsole: cancelled " .. task_id)
            fetch_controller_state()
        else
            local code = tostring(rpc_err or (result and (result.err_code or result.code)))
            state.last_error = "cancel failed: " .. code
            print("PrinterConsole: cancel failed: " .. code)
        end
        state.ui_dirty = true
    end)
end

-- ================== UI data helpers ==================

local function get_status_pill_text()
    if state.offline then return "OFFLINE" end
    local cs = state.controller_state
    if not cs then return "CONNECTING" end
    local phase = cs.phase or "boot"
    if phase == "ready" then return "READY" end
    if phase == "paused" then return "PAUSED" end
    return string.upper(tostring(phase))
end

local function get_status_pill_color()
    if state.offline then return "#CC0000" end
    local phase = state.controller_state and state.controller_state.phase
    if phase == "ready" then return "#00994D" end
    if phase == "paused" then return "#CC7A00" end
    return "#999999"
end

-- The latest controller/log error to show on the header line.
local function error_line()
    if state.last_error then
        return state.last_error
    end
    local errs = state.controller_state and state.controller_state.recent_errors
    if type(errs) == "table" and #errs > 0 then
        local last = errs[#errs]
        if type(last) == "table" then
            return tostring(last.code or "?") .. " " .. tostring(last.msg or "")
        end
        return tostring(last)
    end
    return nil
end

-- Live (non-terminal) tasks in controller order, optionally one family.
local function live_tasks(family_id)
    local out = {}
    local cs = state.controller_state
    for _, t in ipairs((cs and cs.tasks) or {}) do
        if type(t) == "table" and not TERMINAL_STATES[t.state] and
            (family_id == nil or t.family_id == family_id) then
            out[#out + 1] = t
        end
    end
    return out
end

-- Printer tile status from the controller's per-family summary.
local function printer_status_of(family_id)
    local printers = state.controller_state and state.controller_state.printers
    for _, p in ipairs(printers or {}) do
        if p.family_id == family_id then
            return p.status or "idle", p
        end
    end
    return "absent", nil
end

local function task_ratio(t)
    if t.state == "queued" or t.state == "paused" then return 0 end
    if t.count and t.count > 0 then
        return math.min(1, ((t.done_count or 0) + (t.partial or 0)) / t.count)
    end
    return 0
end

-- Rank of a task inside its family queue (1-based position among the family's
-- live tasks in task_order).
local function task_rank(t)
    local rank = 0
    for _, other in ipairs(live_tasks(t.family_id)) do
        rank = rank + 1
        if other.task_id == t.task_id then
            return rank
        end
    end
    return 0
end

-- Catalog lookup for a task's product (for ETA + display name).
local function catalog_entry(cat_family, recipe_key)
    local fam = state.catalog and state.catalog.families
    local tbl = fam and fam[cat_family]
    return tbl and tbl[recipe_key] or nil
end

local function time_multiplier()
    local m = state.controller_state and state.controller_state.time_multiplier
    return type(m) == "number" and m or 1
end

-- Max items buildable with the relayed inventory (nil = inventory unknown).
local function max_buildable(entry)
    local inv = state.inventory and state.inventory.map
    if not inv then
        return nil
    end
    local best = nil
    for reagent, grams in pairs(entry.reagents or {}) do
        if type(grams) == "number" and grams > 0 then
            local h = reagent_hash(reagent)
            local avail = (h and inv[h] and inv[h].available) or 0
            local n = math.floor(avail / grams)
            best = best and math.min(best, n) or n
        end
    end
    return best or 0
end

-- Reagent availability rows for one recipe entry:
--   { name, grams, hash, avail, status } with status = "ok" | "limit" | "short".
local function reagent_rows(entry)
    local inv = state.inventory and state.inventory.map
    local rows = {}
    for reagent, grams in pairs(entry.reagents or {}) do
        if type(reagent) == "string" and type(grams) == "number" and grams > 0 then
            local h = reagent_hash(reagent)
            local avail = (inv and h and inv[h] and inv[h].available) or nil
            rows[#rows + 1] = {
                name = display_name(reagent), grams = grams,
                hash = h, avail = avail,
            }
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    -- Status: red when the reagent cannot build even one item; otherwise the
    -- single limiting reagent (the one that fixes max-buildable) is yellow.
    local min_ratio
    for _, r in ipairs(rows) do
        if r.avail == nil then
            r.status = "ok"
        elseif r.avail < r.grams then
            r.status = "short"
        else
            local ratio = r.avail / r.grams
            if min_ratio == nil or ratio < min_ratio then
                min_ratio = ratio
            end
        end
    end
    local limit_marked = false
    for _, r in ipairs(rows) do
        if r.status == "short" then
            -- keep red
        elseif r.status == nil or r.status == "ok" then
            if r.avail ~= nil and not limit_marked and
                r.avail / r.grams == min_ratio then
                r.status = "limit"
                limit_marked = true
            else
                r.status = "ok"
            end
        end
    end
    return rows
end

-- ================== Live-update machinery ==================

local function find_task(task_id)
    if task_id == nil then
        return nil
    end
    local cs = state.controller_state
    for _, t in ipairs((cs and cs.tasks) or {}) do
        if t.task_id == task_id then
            return t
        end
    end
    return nil
end

-- Register an updater for an element id; called on progress-only revision
-- bumps to push fresh props without a rebuild.
local function dyn_register(id, fn)
    state.dyn[id] = fn
end

-- Signature of everything that changes the ELEMENT SET: page, membership,
-- ordering, structure. Progress-only data (done_count, partial, etas) is
-- excluded -- it updates in place so open selects and textinput drafts
-- survive revision bumps.
local function structural_sig()
    local parts = {
        tostring(state.page), tostring(state.page_family),
        tostring(state.task_filter_family), tostring(state.detail_task_id),
        tostring(state.filters.family), tostring(state.filters.source),
        tostring(state.filters.search), tostring(state.filters.buildable_only),
        tostring(state.filters.sort), tostring(state.filters.page),
        tostring(state.preferences.selected_family),
        tostring(state.preferences.selected_recipe),
        tostring(state.preferences.selected_quantity),
        tostring(state.offline), tostring(state.last_error),
    }
    local cs = state.controller_state
    for _, t in ipairs((cs and cs.tasks) or {}) do
        parts[#parts + 1] = string.format("%s:%s:%s", tostring(t.task_id),
            tostring(t.state), tostring(t.count))
    end
    for _, p in ipairs((cs and cs.printers) or {}) do
        parts[#parts + 1] = tostring(p.family_id) .. "=" .. tostring(p.status)
    end
    parts[#parts + 1] = "e" .. tostring(cs and #cs.recent_errors or 0)
    parts[#parts + 1] = "i" .. tostring(state.inventory and state.inventory.revision or "-")
    parts[#parts + 1] = "c" .. tostring(state.catalog ~= nil)
    return table.concat(parts, "|")
end

-- Push fresh props into every registered element; the overlay's task snapshot
-- is refreshed first so its updaters see current numbers.
local function update_dynamic(s)
    if state.detail_task_id then
        local t = find_task(state.detail_task_id)
        if t then
            state.detail_task = t
        end
    end
    for id, fn in pairs(state.dyn) do
        local h = safe_call(function() return s:get(id) end)
        if h then
            safe_call(fn, h)
        end
    end
    safe_call(function() s:commit() end)
end

-- ================== Navigation ==================

function nav_to(page, family_id)
    state.nav[#state.nav + 1] = { page = state.page, family = state.page_family }
    state.page = page
    state.page_family = family_id
    state.detail_task_id = nil
    state.detail_task = nil
    state.filters.page = 1
    if page == "recipes" or page == "printer" then
        fetch_inventory()
    end
    persist_preferences()
    state.ui_dirty = true
end

function nav_back()
    local top = state.nav[#state.nav]
    if top then
        state.nav[#state.nav] = nil
        state.page = top.page
        state.page_family = top.family
    else
        state.page = "main"
        state.page_family = nil
    end
    state.detail_task_id = nil
    state.detail_task = nil
    persist_preferences()
    state.ui_dirty = true
end

-- ================== UI components ==================

local function el(s, spec)
    return s:element(spec)
end

local function render_back(s)
    if state.page == "main" then
        return
    end
    el(s, {
        id = "nav_back",
        type = "button",
        rect = { unit = "px", x = 10, y = 8, w = 64, h = 24 },
        props = { text = "< BACK" },
        style = { bg = "#334155", text = "#E2E8F0", font_size = 12 },
        on_click = function() nav_back() end,
    })
end

local function render_header(s, width)
    render_back(s)
    local pill = get_status_pill_text()
    el(s, {
        id = "status_pill",
        type = "label",
        rect = { unit = "px", x = width - 170, y = 8, w = 160, h = 22 },
        props = { text = pill },
        style = { color = get_status_pill_color(), font_size = 14, align = "right" },
    })
    local line = error_line()
    el(s, {
        id = "error_line",
        type = "label",
        rect = { unit = "px", x = 84, y = 10, w = width - 270, h = 18 },
        props = { text = line and trunc(line, 90) or "" },
        style = { color = "#EF4444", font_size = 11 },
    })
    dyn_register("status_pill", function(h)
        h:set_props({ text = get_status_pill_text() })
        h:set_style({ color = get_status_pill_color() })
    end)
    dyn_register("error_line", function(h)
        local l = error_line()
        h:set_props({ text = l and trunc(l, 90) or "" })
    end)
end

-- One task panel: button background (blue = queued) + green progress strip +
-- icon + truncated name + done/total. ~34 px tall, readable at 16-char names.
-- Click opens the task detail overlay (no cancel on the bar itself).
local function render_task_panel(s, x, y, w, h, t, prefix)
    local is_queued = t.state == "queued" or t.state == "paused"
    el(s, {
        id = prefix .. "_bg",
        type = "button",
        rect = { unit = "px", x = x, y = y, w = w, h = h },
        props = { text = "" },
        style = { bg = is_queued and QUEUED_BG or "#14532D", text = "#FFFFFF" },
        on_click = function()
            state.detail_task_id = t.task_id
            state.detail_task = t
            state.ui_dirty = true
        end,
    })
    el(s, {
        id = prefix .. "_bar",
        type = "progress",
        rect = { unit = "px", x = x + 2, y = y + h - 6, w = w - 4, h = 4 },
        props = { value = task_ratio(t) },
        style = { bg = "#0B1526", fill = PROGRESS_FILL, z_index = 2 },
    })
    el(s, {
        id = prefix .. "_icon",
        type = "icon",
        rect = { unit = "px", x = x + 4, y = y + 3, w = h - 12, h = h - 12 },
        props = { icon_type = "prefab", name = tostring(t.item or "?"), z_index = 3 },
    })
    local ix = x + h - 6
    el(s, {
        id = prefix .. "_name",
        type = "label",
        rect = { unit = "px", x = ix + 2, y = y + 2, w = w - (ix - x) - 46, h = 14 },
        props = { text = trunc(display_name(t.item), 16), z_index = 3 },
        style = { color = "#FFFFFF", font_size = 11 },
    })
    el(s, {
        id = prefix .. "_count",
        type = "label",
        rect = { unit = "px", x = x + w - 46, y = y + h - 20, w = 44, h = 14 },
        props = { text = string.format("%d/%d", t.done_count or 0, t.count or 0), z_index = 3 },
        style = { color = "#CCE5FF", font_size = 11, align = "right" },
    })
    -- Progress + count are the live part of a task panel; update them in
    -- place so a printing task does not force a rebuild (which would kill
    -- open selects/textinputs).
    dyn_register(prefix .. "_bar", function(h)
        local cur = find_task(t.task_id) or t
        h:set_props({ value = task_ratio(cur) })
    end)
    dyn_register(prefix .. "_count", function(h)
        local cur = find_task(t.task_id) or t
        h:set_props({ text = string.format("%d/%d", cur.done_count or 0, cur.count or 0) })
    end)
end

-- A horizontal strip of task panels.
local function render_task_strip(s, x, y, w, h, tasks, prefix, max_panels)
    local shown = math.min(#tasks, max_panels)
    local gap = 6
    local pw = math.floor((w - gap * (shown - 1)) / math.max(shown, 1))
    for i = 1, shown do
        render_task_panel(s, x + (i - 1) * (pw + gap), y, pw, h, tasks[i],
            prefix .. "_" .. i)
    end
    if #tasks > shown then
        el(s, {
            id = prefix .. "_more",
            type = "label",
            rect = { unit = "px", x = x + w - 60, y = y + h - 16, w = 60, h = 12 },
            props = { text = "+" .. (#tasks - shown) .. " more" },
            style = { color = "#94A3B8", font_size = 10, align = "right" },
        })
    end
end

-- ================== Page: main ==================

local function render_main(s, width, height)
    -- 3x2 tile grid.
    local gx, gy = 12, 44
    local gw = width - 24
    local gh = math.floor(height * 0.52)
    local cols, rows = 3, 2
    local gap = 10
    local tw = math.floor((gw - gap * (cols - 1)) / cols)
    local th = math.floor((gh - gap * (rows - 1)) / rows)
    for i, fam in ipairs(FAMILIES) do
        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        local tx = gx + col * (tw + gap)
        local ty = gy + row * (th + gap)
        local status, prec = printer_status_of(fam.id)
        local bg = STATUS_COLORS[status] or STATUS_COLORS.idle
        el(s, {
            id = "tile_" .. fam.id,
            type = "button",
            rect = { unit = "px", x = tx, y = ty, w = tw, h = th },
            props = { text = "" },
            style = { bg = bg, text = "#FFFFFF" },
            on_click = function() nav_to("printer", fam.id) end,
        })
        local isz = math.min(56, th - 44)
        el(s, {
            id = "tile_" .. fam.id .. "_icon",
            type = "icon",
            rect = { unit = "px", x = tx + (tw - isz) / 2, y = ty + 10, w = isz, h = isz },
            props = { icon_type = "prefab", name = prefab_icon_name(prec and prec.prefab_hash), z_index = 2 },
        })
        el(s, {
            id = "tile_" .. fam.id .. "_name",
            type = "label",
            rect = { unit = "px", x = tx + 6, y = ty + th - 32, w = tw - 12, h = 16 },
            props = { text = fam.label, z_index = 2 },
            style = { color = "#FFFFFF", font_size = 13, align = "center" },
        })
        el(s, {
            id = "tile_" .. fam.id .. "_st",
            type = "label",
            rect = { unit = "px", x = tx + 6, y = ty + th - 16, w = tw - 12, h = 12 },
            props = { text = string.gsub(status or "idle", "_", " "), z_index = 2 },
            style = { color = "#E2E8F0", font_size = 10, align = "center" },
        })
    end

    -- ALL RECIPES button under the grid.
    local by = gy + gh + 10
    el(s, {
        id = "all_recipes",
        type = "button",
        rect = { unit = "px", x = gx, y = by, w = gw, h = 34 },
        props = { text = "ALL RECIPES" },
        style = { bg = "#1D4ED8", text = "#FFFFFF", font_size = 14 },
        on_click = function()
            state.filters.family = nil
            nav_to("recipes")
        end,
    })

    -- Bottom print-queue bar: the label is itself the button to the task page.
    local qy = height - 96
    local live = live_tasks()
    -- Active (non-queued) tasks first, queued in task_order after.
    local ordered = {}
    for _, t in ipairs(live) do
        if t.state ~= "queued" and t.state ~= "paused" then
            ordered[#ordered + 1] = t
        end
    end
    for _, t in ipairs(live) do
        if t.state == "queued" or t.state == "paused" then
            ordered[#ordered + 1] = t
        end
    end
    el(s, {
        id = "queue_label",
        type = "button",
        rect = { unit = "px", x = gx, y = qy, w = 200, h = 20 },
        props = { text = "PRINTING QUEUE (" .. #live .. ")" },
        style = { bg = "#0F172A", text = "#93C5FD", font_size = 11 },
        on_click = function()
            state.task_filter_family = nil
            nav_to("tasks")
        end,
    })
    el(s, {
        id = "queue_frame",
        type = "panel",
        rect = { unit = "px", x = gx, y = qy + 24, w = gw, h = 64 },
        style = { bg = "#0B1220" },
    })
    if #ordered == 0 then
        el(s, {
            id = "queue_empty",
            type = "label",
            rect = { unit = "px", x = gx + 10, y = qy + 48, w = 200, h = 14 },
            props = { text = "no tasks" },
            style = { color = "#64748B", font_size = 11 },
        })
    else
        local max_panels = math.max(1, math.floor((gw - 16) / 160))
        render_task_strip(s, gx + 8, qy + 32, gw - 16, 44, ordered, "qp", max_panels)
    end
end

-- ================== Shared: recipe list + request bar ==================

-- Flattened + filtered + sorted recipe rows for the current filter state.
local function filtered_recipes()
    local catalog = state.catalog
    if type(catalog) ~= "table" or type(catalog.families) ~= "table" then
        return {}
    end
    local f = state.filters
    local needle = f.search ~= "" and string.lower(f.search) or nil
    local list = {}
    for _, fam in ipairs(FAMILIES) do
        if f.family == nil or f.family == fam.cat then
            local tbl = catalog.families[fam.cat]
            for key, e in pairs(tbl or {}) do
                if type(e) == "table" then
                    local ok = true
                    if needle then
                        local dn = string.lower(tostring(e.display or key))
                        local kn = string.lower(key)
                        if not (dn:find(needle, 1, true) or kn:find(needle, 1, true)) then
                            ok = false
                        end
                    end
                    if ok and f.source then
                        local hit = false
                        for _, src in ipairs(e.sources or {}) do
                            if src == f.source then
                                hit = true
                                break
                            end
                        end
                        ok = hit
                    end
                    if ok then
                        list[#list + 1] = { key = key, entry = e, fam = fam }
                    end
                end
            end
        end
    end
    -- Buildable filter needs the inventory math once per row anyway.
    if f.buildable_only or f.sort == "buildable" then
        for _, r in ipairs(list) do
            r.maxb = max_buildable(r.entry)
        end
        if f.buildable_only then
            local kept = {}
            for _, r in ipairs(list) do
                -- nil (inventory unknown) does not prove un-buildable: keep it.
                if r.maxb == nil or r.maxb > 0 then
                    kept[#kept + 1] = r
                end
            end
            list = kept
        end
    end
    if f.sort == "buildable" then
        table.sort(list, function(a, b)
            local am, bm = a.maxb or -1, b.maxb or -1
            if am ~= bm then
                return am > bm
            end
            return (a.entry.display or a.key) < (b.entry.display or b.key)
        end)
    else
        table.sort(list, function(a, b)
            local an, bn = a.entry.display or a.key, b.entry.display or b.key
            if an ~= bn then
                return an < bn
            end
            return a.key < b.key
        end)
    end
    return list
end

local function source_label(src)
    if src == "vanilla" then
        return "vanilla"
    end
    local mods = state.catalog and state.catalog.mods
    return (mods and mods[src]) or tostring(src)
end

local function render_recipe_filters(s, x, y, w, locked_fam)
    -- Two filter rows: the single row overran the surface width (controls to
    -- the right of the source select were clipped). Row 1 carries family +
    -- search + source; row 2 carries the buildable flag + sort.
    local fx = x
    -- Printer family select (hidden when the list is locked to one family).
    if not locked_fam then
        local options = { "all printers" }
        for _, fam in ipairs(FAMILIES) do
            options[#options + 1] = fam.label
        end
        local sel = 0
        for i, fam in ipairs(FAMILIES) do
            if state.filters.family == fam.cat then
                sel = i
            end
        end
        el(s, {
            id = "f_family",
            type = "select",
            rect = { unit = "px", x = fx, y = y, w = 120, h = 24 },
            props = { options = options, selected = tostring(sel) },
            style = { bg = "#1E293B", text = "#E2E8F0", font_size = 11 },
            on_change = function(value)
                local idx = tonumber(value) or 0
                state.filters.family = idx >= 1 and FAMILIES[idx].cat or nil
                state.filters.page = 1
                state.ui_dirty = true
            end,
        })
        fx = fx + 128
    end
    -- Name search (case-insensitive substring; fired on end-edit) with an
    -- explicit X clear -- an empty field is not always re-submittable.
    local src_w = 150
    local search_w = math.max(80, w - (fx - x) - src_w - 8 - 26)
    el(s, {
        id = "f_search",
        type = "textinput",
        rect = { unit = "px", x = fx, y = y, w = search_w, h = 24 },
        props = { value = state.filters.search, placeholder = "name search", title = "Search" },
        style = { bg = "#0F172A", text = "#E2E8F0", font_size = 11 },
        on_change = function(value)
            state.filters.search = tostring(value or "")
            state.filters.page = 1
            state.ui_dirty = true
        end,
    })
    el(s, {
        id = "f_search_x",
        type = "button",
        rect = { unit = "px", x = fx + search_w + 4, y = y, w = 22, h = 24 },
        props = { text = "X" },
        style = { bg = "#334155", text = "#94A3B8", font_size = 11 },
        on_click = function()
            state.filters.search = ""
            state.filters.page = 1
            state.ui_dirty = true
        end,
    })
    -- Source select: "all sources" + every source the generator saw (vanilla
    -- is entry 1 of effective_order). Entries are built WITHOUT a leading nil
    -- hole -- {nil, "vanilla"} makes #ids runtime-dependent and previously
    -- overwrote vanilla with the first mod, shifting every option by one.
    do
        local order = (state.catalog and state.catalog.generated
            and state.catalog.generated.effective_order) or {}
        local entries = { { src = false, label = "all sources" } }
        for _, src in ipairs(order) do
            entries[#entries + 1] = {
                src = src,
                label = src == "vanilla" and "vanilla" or trunc(source_label(src), 18),
            }
        end
        local options = {}
        local sel = 0
        for i, e in ipairs(entries) do
            options[i] = e.label
            if state.filters.source == e.src then
                sel = i - 1
            end
        end
        el(s, {
            id = "f_source",
            type = "select",
            rect = { unit = "px", x = x + w - src_w, y = y, w = src_w, h = 24 },
            props = { options = options, selected = tostring(sel) },
            style = { bg = "#1E293B", text = "#E2E8F0", font_size = 11 },
            on_change = function(value)
                local e = entries[(tonumber(value) or 0) + 1]
                state.filters.source = e and e.src or nil
                state.filters.page = 1
                state.ui_dirty = true
            end,
        })
    end
    -- Row 2: buildable-only checkbox + sort select.
    local y2 = y + 28
    el(s, {
        id = "f_buildable",
        type = "checkbox",
        rect = { unit = "px", x = x, y = y2 + 2, w = 96, h = 20 },
        props = { text = "buildable", checked = state.filters.buildable_only and "true" or "false" },
        style = { bg = "#0F172A", text = "#E2E8F0", font_size = 11 },
        on_click = function()
            state.filters.buildable_only = not state.filters.buildable_only
            state.filters.page = 1
            state.ui_dirty = true
        end,
    })
    do
        local options = { "name", "buildable" }
        local sel = state.filters.sort == "buildable" and 1 or 0
        el(s, {
            id = "f_sort",
            type = "select",
            rect = { unit = "px", x = x + 104, y = y2, w = 110, h = 24 },
            props = { options = options, selected = tostring(sel) },
            style = { bg = "#1E293B", text = "#E2E8F0", font_size = 11 },
            on_change = function(value)
                state.filters.sort = tonumber(value) == 1 and "buildable" or "name"
                state.filters.page = 1
                state.ui_dirty = true
            end,
        })
    end
end

-- Recipe list rows + pagination. `locked_fam` hides the printer filter.
local function render_recipe_list(s, x, y, w, h, locked_fam)
    render_recipe_filters(s, x, y, w, locked_fam)
    local list_y = y + 58
    local list_h = h - 58 - 26
    local row_h = 34
    local page_size = math.max(1, math.floor(list_h / row_h))
    local rows = filtered_recipes()
    local pages = math.max(1, math.ceil(#rows / page_size))
    state.filters.page = clamp(state.filters.page, 1, pages)
    local first = (state.filters.page - 1) * page_size + 1
    local last = math.min(#rows, first + page_size - 1)

    for i = first, last do
        local r = rows[i]
        local e = r.entry
        local ry = list_y + (i - first) * row_h
        local rid = "rr_" .. i
        local selected = (state.preferences.selected_recipe == r.key and
            state.preferences.selected_family == r.fam.name)
        el(s, {
            id = rid .. "_bg",
            type = "button",
            rect = { unit = "px", x = x, y = ry, w = w, h = row_h - 2 },
            props = { text = "" },
            style = {
                bg = e.valid == false and "#1A1A22" or
                    (selected and "#1D4ED8" or (i % 2 == 0 and "#141B2E" or "#0F172A")),
                text = "#FFFFFF",
            },
            on_click = function()
                if e.valid == false then
                    return
                end
                state.preferences.selected_recipe = r.key
                state.preferences.selected_family = r.fam.name
                persist_preferences()
                state.ui_dirty = true
            end,
        })
        el(s, {
            id = rid .. "_icon",
            type = "icon",
            rect = { unit = "px", x = x + 4, y = ry + 3, w = 26, h = 26 },
            props = { icon_type = "prefab", name = r.key, z_index = 2 },
        })
        local name_color = e.valid == false and "#64748B" or "#FFFFFF"
        el(s, {
            id = rid .. "_name",
            type = "label",
            rect = { unit = "px", x = x + 36, y = ry + 2, w = 150, h = 14 },
            props = { text = trunc(e.display or display_name(r.key), 18), z_index = 2 },
            style = { color = name_color, font_size = 12 },
        })
        el(s, {
            id = rid .. "_src",
            type = "label",
            rect = { unit = "px", x = x + 36, y = ry + 17, w = 150, h = 12 },
            props = { text = trunc(source_label((e.sources or {})[1] or "?"), 20), z_index = 2 },
            style = { color = "#94A3B8", font_size = 10 },
        })
        -- Max buildable (red at 0, "--" when inventory is unknown).
        local mb = max_buildable(e)
        el(s, {
            id = rid .. "_max",
            type = "label",
            rect = { unit = "px", x = x + 190, y = ry + 8, w = 48, h = 16 },
            props = { text = mb == nil and "--" or tostring(mb), z_index = 2 },
            style = {
                color = (mb ~= nil and mb <= 0) and "#EF4444" or "#CCE5FF",
                font_size = 12, align = "center",
            },
        })
        -- Reagent list (positive amounts only).
        local rx = x + 246
        for _, rr in ipairs(reagent_rows(e)) do
            if rx + 96 < x + w then
                local color = "#94A3B8"
                if rr.status == "short" then
                    color = "#EF4444"
                elseif rr.status == "limit" then
                    color = "#EAB308"
                end
                local text = rr.name .. " " .. tostring(rr.grams)
                if rr.avail ~= nil then
                    text = text .. "/" .. tostring(math.floor(rr.avail))
                end
                el(s, {
                    id = rid .. "_rg" .. tostring(rr.hash or rr.name),
                    type = "label",
                    rect = { unit = "px", x = rx, y = ry + 8, w = 96, h = 16 },
                    props = { text = trunc(text, 14), z_index = 2 },
                    style = { color = color, font_size = 10 },
                })
                rx = rx + 98
            end
        end
    end

    if #rows == 0 then
        el(s, {
            id = "rr_empty",
            type = "label",
            rect = { unit = "px", x = x + 10, y = list_y + 10, w = 300, h = 16 },
            props = { text = "no recipes match the filters" },
            style = { color = "#64748B", font_size = 12 },
        })
    end

    -- Pagination: [page input][<][>] grouped on the left, count label after.
    local py = list_y + list_h + 4
    el(s, {
        id = "pg_input",
        type = "textinput",
        rect = { unit = "px", x = x, y = py, w = 56, h = 22 },
        props = { value = tostring(state.filters.page), title = "Page" },
        style = { bg = "#0F172A", text = "#E2E8F0", font_size = 11 },
        on_change = function(value)
            state.filters.page = clamp(math.floor(tonumber(value) or 1), 1, pages)
            state.ui_dirty = true
        end,
    })
    el(s, {
        id = "pg_prev",
        type = "button",
        rect = { unit = "px", x = x + 58, y = py, w = 26, h = 22 },
        props = { text = "<" },
        style = { bg = "#334155", text = "#E2E8F0", font_size = 11 },
        on_click = function()
            state.filters.page = math.max(1, state.filters.page - 1)
            state.ui_dirty = true
        end,
    })
    el(s, {
        id = "pg_next",
        type = "button",
        rect = { unit = "px", x = x + 86, y = py, w = 26, h = 22 },
        props = { text = ">" },
        style = { bg = "#334155", text = "#E2E8F0", font_size = 11 },
        on_click = function()
            state.filters.page = math.min(pages, state.filters.page + 1)
            state.ui_dirty = true
        end,
    })
    el(s, {
        id = "pg_label",
        type = "label",
        rect = { unit = "px", x = x + 120, y = py + 4, w = 160, h = 14 },
        props = { text = string.format("of %d  (%d recipes)", pages, #rows) },
        style = { color = "#94A3B8", font_size = 11 },
    })
end

-- Bottom request bar for the selected recipe: qty input, two stepper rows,
-- MIN/MAX, estimated print-only time, CREATE TASK.
local function render_request_bar(s, x, y, w, h)
    local family = state.preferences.selected_family
    local recipe = state.preferences.selected_recipe
    local entry = (family and recipe) and
        catalog_entry(catalog_key(family), recipe) or nil

    el(s, {
        id = "req_frame",
        type = "panel",
        rect = { unit = "px", x = x, y = y, w = w, h = h },
        style = { bg = "#0B1220" },
    })

    if not entry then
        el(s, {
            id = "req_none",
            type = "label",
            rect = { unit = "px", x = x + 10, y = y + 10, w = 400, h = 16 },
            props = { text = "select a recipe above" },
            style = { color = "#64748B", font_size = 12 },
        })
        return
    end

    -- Row 1: icon + stacked info block (name / family / print-only time).
    el(s, {
        id = "req_icon",
        type = "icon",
        rect = { unit = "px", x = x + 8, y = y + 8, w = 40, h = 40 },
        props = { icon_type = "prefab", name = recipe },
    })
    el(s, {
        id = "req_name",
        type = "label",
        rect = { unit = "px", x = x + 56, y = y + 14, w = w - 266, h = 24 },
        props = { text = trunc(entry.display or display_name(recipe), 40), z_index = 2 },
        style = { color = "#FFFFFF", font_size = 17 },
    })
    -- Right column: printer type + estimated print-only time.
    local fam = FAMILY_BY_CTL[family]
    el(s, {
        id = "req_fam",
        type = "label",
        rect = { unit = "px", x = x + w - 202, y = y + 10, w = 194, h = 14 },
        props = { text = fam and fam.label or tostring(family), z_index = 2 },
        style = { color = "#94A3B8", font_size = 11, align = "right" },
    })
    local qty = clamp(math.floor(tonumber(state.preferences.selected_quantity) or 1), 1, 1000000)
    local est = entry.time and (entry.time * qty * time_multiplier()) or nil
    el(s, {
        id = "req_eta",
        type = "label",
        rect = { unit = "px", x = x + w - 202, y = y + 28, w = 194, h = 13 },
        props = { text = "print time: " .. fmt_time(est), z_index = 2 },
        style = { color = "#CCE5FF", font_size = 11, align = "right" },
    })

    -- Rows 2+3: the qty input spans both rows on the left; the +/- steppers
    -- split into a negative row over a positive row; CREATE fills the height
    -- on the right. The stepper width is derived from CREATE's left edge so
    -- the two can never overlap at any surface width.
    local create_w = 110
    local create_x = x + w - create_w - 8
    local bh = 24
    local bx0 = x + 8 + 62 + 6
    local bw = math.max(26, math.min(52,
        math.floor((create_x - 10 - bx0 - 6 * 4) / 7)))
    local function stepper(id, label, delta, bx, by)
        el(s, {
            id = id,
            type = "button",
            rect = { unit = "px", x = bx, y = by, w = bw, h = bh },
            props = { text = label },
            style = { bg = "#1E293B", text = "#93C5FD", font_size = 10 },
            on_click = function()
                state.preferences.selected_quantity =
                    clamp(qty + delta, 1, 1000000)
                persist_preferences()
                state.ui_dirty = true
            end,
        })
    end
    local function cap_button(id, label, bx, by, handler)
        el(s, {
            id = id,
            type = "button",
            rect = { unit = "px", x = bx, y = by, w = bw, h = bh },
            props = { text = label },
            style = { bg = "#334155", text = "#E2E8F0", font_size = 9 },
            on_click = handler,
        })
    end
    el(s, {
        id = "req_qty",
        type = "textinput",
        rect = { unit = "px", x = x + 8, y = y + 54, w = 62, h = 2 * bh + 6 },
        props = { value = tostring(qty), title = "Quantity" },
        style = { bg = "#0F172A", text = "#FFFFFF", font_size = 14 },
        on_change = function(value)
            local n = math.floor(tonumber(value) or 1)
            state.preferences.selected_quantity = clamp(n, 1, 1000000)
            persist_preferences()
            state.ui_dirty = true
        end,
    })
    local by1, by2 = y + 54, y + 54 + bh + 6
    local neg = { -1, -5, -10, -25, -50, -100 }
    local pos = { 1, 5, 10, 25, 50, 100 }
    for i, d in ipairs(neg) do
        stepper("req_m" .. tostring(-d), tostring(d), d, bx0 + (i - 1) * (bw + 4), by1)
    end
    cap_button("req_min", "MIN", bx0 + 6 * (bw + 4), by1, function()
        state.preferences.selected_quantity = 1
        persist_preferences()
        state.ui_dirty = true
    end)
    for i, d in ipairs(pos) do
        stepper("req_p" .. tostring(d), "+" .. tostring(d), d, bx0 + (i - 1) * (bw + 4), by2)
    end
    cap_button("req_max", "MAX", bx0 + 6 * (bw + 4), by2, function()
        local mb = max_buildable(entry)
        state.preferences.selected_quantity =
            clamp(mb or 1000000, 1, 1000000)
        persist_preferences()
        state.ui_dirty = true
    end)

    -- CREATE TASK spans the stepper rows on the right.
    el(s, {
        id = "req_create",
        type = "button",
        rect = { unit = "px", x = create_x, y = y + 54, w = create_w, h = 2 * bh + 6 },
        props = { text = "CREATE TASK" },
        style = { bg = "#00994D", text = "#FFFFFF", font_size = 12 },
        on_click = function()
            submit_request()
        end,
    })
end

-- ================== Page: recipes ==================

local function render_recipes_page(s, width, height)
    local list_h = height - 190
    render_recipe_list(s, 12, 44, width - 24, list_h, nil)
    render_request_bar(s, 12, height - 130, width - 24, 122)
end

-- ================== Page: printer ==================

local function render_printer_page(s, width, height, family_id)
    local fam = FAMILY_BY_ID[family_id]
    if not fam then
        nav_back()
        return
    end
    local status, prec = printer_status_of(family_id)
    -- Header strip: icon + name + status.
    el(s, {
        id = "ph_icon",
        type = "icon",
        rect = { unit = "px", x = 84, y = 36, w = 30, h = 30 },
        props = { icon_type = "prefab", name = prefab_icon_name(prec and prec.prefab_hash) },
    })
    el(s, {
        id = "ph_name",
        type = "label",
        rect = { unit = "px", x = 122, y = 40, w = 200, h = 20 },
        props = { text = fam.label },
        style = { color = "#FFFFFF", font_size = 15 },
    })
    el(s, {
        id = "ph_status",
        type = "label",
        rect = { unit = "px", x = 122, y = 58, w = 200, h = 14 },
        props = { text = string.gsub(status or "idle", "_", " ") },
        style = { color = STATUS_COLORS[status] or "#94A3B8", font_size = 11 },
    })

    -- This family's task bar: click leads to the task page pre-filtered.
    local tasks = live_tasks(family_id)
    el(s, {
        id = "pt_label",
        type = "button",
        rect = { unit = "px", x = 340, y = 40, w = 180, h = 20 },
        props = { text = "TASKS (" .. #tasks .. ")" },
        style = { bg = "#0F172A", text = "#93C5FD", font_size = 11 },
        on_click = function()
            state.task_filter_family = family_id
            nav_to("tasks")
        end,
    })
    if #tasks > 0 then
        local max_panels = math.max(1, math.floor((width - 370 - 24) / 160))
        render_task_strip(s, 340, 64, width - 370, 34, tasks, "pt", max_panels)
    end

    -- Recipe list locked to this family (printer filter hidden).
    state.filters.family = fam.cat
    local list_y = 112
    local list_h = height - list_y - 150
    render_recipe_list(s, 12, list_y, width - 24, list_h, fam)
    render_request_bar(s, 12, height - 130, width - 24, 122)
end

-- ================== Page: tasks ==================

local function render_tasks_page(s, width, height)
    local row_h = math.floor((height - 56) / #FAMILIES)
    for i, fam in ipairs(FAMILIES) do
        local ry = 44 + (i - 1) * row_h
        local dim = state.task_filter_family ~= nil and
            state.task_filter_family ~= fam.id
        el(s, {
            id = "tq_" .. fam.id .. "_label",
            type = "label",
            rect = { unit = "px", x = 12, y = ry + 6, w = 104, h = 16 },
            props = { text = fam.label },
            style = { color = dim and "#475569" or "#E2E8F0", font_size = 12 },
        })
        local status = printer_status_of(fam.id)
        el(s, {
            id = "tq_" .. fam.id .. "_st",
            type = "label",
            rect = { unit = "px", x = 12, y = ry + 22, w = 104, h = 12 },
            props = { text = string.gsub(status or "idle", "_", " ") },
            style = { color = STATUS_COLORS[status] or "#94A3B8", font_size = 10 },
        })
        local tasks = live_tasks(fam.id)
        if #tasks == 0 then
            el(s, {
                id = "tq_" .. fam.id .. "_empty",
                type = "label",
                rect = { unit = "px", x = 124, y = ry + 10, w = 120, h = 14 },
                props = { text = "idle" },
                style = { color = "#334155", font_size = 11 },
            })
        else
            local max_panels = math.max(1, math.floor((width - 148) / 160))
            render_task_strip(s, 124, ry, width - 148, math.min(34, row_h - 6),
                tasks, "tq_" .. fam.id, max_panels)
        end
    end
end

-- ================== Overlay: task detail ==================

local function render_task_overlay(s, width, height)
    local t = state.detail_task
    -- The task may have completed since the overlay opened; find the freshest
    -- record for the same id.
    local cs = state.controller_state
    for _, cand in ipairs((cs and cs.tasks) or {}) do
        if cand.task_id == state.detail_task_id then
            t = cand
            state.detail_task = cand
            break
        end
    end
    if not t then
        state.detail_task_id = nil
        return
    end

    -- Dim background.
    el(s, {
        id = "ovl_dim",
        type = "panel",
        rect = { unit = "px", x = 0, y = 0, w = width, h = height },
        props = { z_index = 50 },
        style = { bg = "#000000" },
    })
    local cw, ch = 440, 340
    local cx, cy = (width - cw) / 2, (height - ch) / 2
    el(s, {
        id = "ovl_card",
        type = "panel",
        rect = { unit = "px", x = cx, y = cy, w = cw, h = ch },
        props = { z_index = 51 },
        style = { bg = "#111827" },
    })
    el(s, {
        id = "ovl_icon",
        type = "icon",
        rect = { unit = "px", x = cx + 12, y = cy + 12, w = 48, h = 48 },
        props = { icon_type = "prefab", name = tostring(t.item or "?"), z_index = 52 },
    })
    local fam = FAMILY_BY_CTL[t.family_name] or FAMILY_BY_ID[t.family_id]
    el(s, {
        id = "ovl_name",
        type = "label",
        rect = { unit = "px", x = cx + 70, y = cy + 14, w = cw - 90, h = 18 },
        props = { text = trunc(display_name(t.item), 30), z_index = 52 },
        style = { color = "#FFFFFF", font_size = 14 },
    })
    el(s, {
        id = "ovl_meta",
        type = "label",
        rect = { unit = "px", x = cx + 70, y = cy + 34, w = cw - 90, h = 14 },
        props = {
            text = string.format("%s  |  %s  |  rank %d",
                fam and fam.label or tostring(t.family_name or t.family_id),
                tostring(t.state or "?"), task_rank(t)),
            z_index = 52,
        },
        style = { color = "#94A3B8", font_size = 11 },
    })
    -- Progress.
    el(s, {
        id = "ovl_prog",
        type = "progress",
        rect = { unit = "px", x = cx + 12, y = cy + 70, w = cw - 24, h = 18 },
        props = { value = task_ratio(t), z_index = 52 },
        style = { bg = "#1E293B", fill = PROGRESS_FILL },
    })
    el(s, {
        id = "ovl_count",
        type = "label",
        rect = { unit = "px", x = cx + 12, y = cy + 90, w = cw - 24, h = 14 },
        props = {
            text = string.format("%d / %d done", t.done_count or 0, t.count or 0),
            z_index = 52,
        },
        style = { color = "#CCE5FF", font_size = 12, align = "center" },
    })
    -- Estimated remaining (print-only): (count - done - partial) * time * mult.
    local cat_e = t.item and catalog_entry(catalog_key(t.family_name or ""), t.item)
    local remain
    if cat_e and cat_e.time and t.state == "active" then
        remain = math.max(0,
            (t.count - (t.done_count or 0) - (t.partial or 0)) * cat_e.time * time_multiplier())
    end
    el(s, {
        id = "ovl_eta",
        type = "label",
        rect = { unit = "px", x = cx + 12, y = cy + 106, w = cw - 24, h = 14 },
        props = {
            text = t.state == "active" and ("est. remaining: " .. fmt_time(remain))
                or (t.state == "queued" and ("queued, rank " .. task_rank(t))
                or tostring(t.state or "?")),
            z_index = 52,
        },
        style = { color = "#EAB308", font_size = 11, align = "center" },
    })
    dyn_register("ovl_prog", function(h)
        local cur = state.detail_task or t
        h:set_props({ value = task_ratio(cur) })
    end)
    dyn_register("ovl_count", function(h)
        local cur = state.detail_task or t
        h:set_props({ text = string.format("%d / %d done", cur.done_count or 0, cur.count or 0) })
    end)
    dyn_register("ovl_eta", function(h)
        local cur = state.detail_task or t
        local rem
        if cat_e and cat_e.time and cur.state == "active" then
            rem = math.max(0,
                (cur.count - (cur.done_count or 0) - (cur.partial or 0)) * cat_e.time * time_multiplier())
        end
        h:set_props({
            text = cur.state == "active" and ("est. remaining: " .. fmt_time(rem))
                or (cur.state == "queued" and ("queued, rank " .. task_rank(cur))
                or tostring(cur.state or "?")),
        })
    end)
    -- Resources used / planned per reagent.
    local ry = cy + 128
    el(s, {
        id = "ovl_res_h",
        type = "label",
        rect = { unit = "px", x = cx + 12, y = ry, w = cw - 24, h = 14 },
        props = { text = "RESOURCES (used / planned)", z_index = 52 },
        style = { color = "#64748B", font_size = 10 },
    })
    ry = ry + 16
    local labels = t.reagent_labels or {}
    local vec = t.cost_vector or {}
    local shown = 0
    for h, lname in pairs(labels) do
        if shown < 8 then
            local per = vec[h] or 0
            local planned = math.ceil(per * (t.count or 0))
            local used = math.min(planned, math.ceil(per * (t.done_count or 0)))
            el(s, {
                id = "ovl_res_" .. shown,
                type = "label",
                rect = { unit = "px", x = cx + 12, y = ry, w = cw - 24, h = 13 },
                props = {
                    text = string.format("%s  %d / %d", tostring(lname), used, planned),
                    z_index = 52,
                },
                style = { color = "#94A3B8", font_size = 11 },
            })
            local row_id = "ovl_res_" .. shown
            dyn_register(row_id, function(hh)
                local cur = state.detail_task or t
                local plan2 = math.ceil(per * (cur.count or 0))
                local used2 = math.min(plan2, math.ceil(per * (cur.done_count or 0)))
                hh:set_props({ text = string.format("%s  %d / %d", tostring(lname), used2, plan2) })
            end)
            ry = ry + 14
            shown = shown + 1
        end
    end
    if shown == 0 then
        el(s, {
            id = "ovl_res_none",
            type = "label",
            rect = { unit = "px", x = cx + 12, y = ry, w = cw - 24, h = 13 },
            props = { text = "(no reagent detail)", z_index = 52 },
            style = { color = "#475569", font_size = 11 },
        })
    end
    -- Buttons: CANCEL (only for cancellable states) + CLOSE.
    if CANCELLABLE_STATES[t.state] then
        el(s, {
            id = "ovl_cancel",
            type = "button",
            rect = { unit = "px", x = cx + 12, y = cy + ch - 44, w = 120, h = 32 },
            props = { text = "CANCEL", z_index = 52 },
            style = { bg = "#7A1E1E", text = "#FFFFFF", font_size = 12 },
            on_click = function()
                cancel_task(t.task_id, "console_cancel")
            end,
        })
    end
    el(s, {
        id = "ovl_close",
        type = "button",
        rect = { unit = "px", x = cx + cw - 132, y = cy + ch - 44, w = 120, h = 32 },
        props = { text = "CLOSE", z_index = 52 },
        style = { bg = "#334155", text = "#FFFFFF", font_size = 12 },
        on_click = function()
            state.detail_task_id = nil
            state.detail_task = nil
            state.ui_dirty = true
        end,
    })
end

-- ================== Render dispatch ==================

function render_ui()
    if not state.ui_surface then
        state.ui_surface = ss.ui.surface("printerc")
        ss.ui.activate("printerc")
    end
    local s = state.ui_surface
    local size = s:size()
    local width = tonumber(size.w) or 1024
    local height = tonumber(size.h) or 768

    state.dyn = {}
    s:clear()
    render_header(s, width)
    if state.page == "printer" and state.page_family then
        render_printer_page(s, width, height, state.page_family)
    elseif state.page == "recipes" then
        render_recipes_page(s, width, height)
    elseif state.page == "tasks" then
        render_tasks_page(s, width, height)
    else
        render_main(s, width, height)
    end
    if state.detail_task_id then
        render_task_overlay(s, width, height)
    end
    safe_call(function() s:commit() end)
    state.last_rendered_revision = state.last_state_revision
    state.last_sig = structural_sig()
    state.ui_dirty = false
end

-- ================== Init ==================

initialize_console_uuid()
setup_bridges()
restore_preferences()
render_ui()

-- ================== Main loop ==================

local last_poll_time = 0

while true do
    local current_time = os.clock()
    if current_time - last_poll_time >= POLL_INTERVAL then
        fetch_controller_state()
        last_poll_time = current_time
    end
    -- Inventory refresh only while a recipe-bearing page is open.
    if (state.page == "recipes" or state.page == "printer") and
        current_time - state.inventory_fetched_at >= INVENTORY_REFRESH then
        fetch_inventory()
    end
    -- Rebuild on user action (ui_dirty). On a controller revision bump,
    -- rebuild only when the ELEMENT SET changed (structural signature);
    -- progress-only updates go through set_props so an open select dropdown
    -- or half-typed textinput is not destroyed mid-edit.
    local rev = state.last_state_revision
    if state.ui_dirty or state.last_sig == nil then
        render_ui()
    elseif rev ~= state.last_rendered_revision then
        if structural_sig() ~= state.last_sig then
            render_ui()
        else
            update_dynamic(state.ui_surface)
            state.last_rendered_revision = rev
        end
    end
    yield()
end
