--@module Printer Control Console (ScriptedScreens UI).
--@version 1.1.0
--@author Herme
--@date 2026-10-16
--
-- Separate ScriptedScreens UI chip. This chip NEVER talks to storage directly
-- (it owns no storage controller); every stateful action goes through the
-- Printer.Controller RPC surface only. The reservation/queue/printer work is the
-- controller's job.
--
-- RPC surface used (all to "Printer.Controller"):
--   printers.get_state   -> poll phase/revision/task count
--   printers.get_config  -> fetch families + recipes + commission_check
--   printers.request     -> submit a print job
--   printers.cancel      -> cancel an in-flight/queued task
--
-- Build note: this chip talks to the bundled controller, so a revision bump
-- means a controller flash+restart, which is the accepted behavior.

local API_VERSION = 1
local POLL_INTERVAL = 1.0
local CONTROLLER_TARGET = "Printer.Controller"
local CONSOLE_DESTINATION_ID = "Printer.Console"

-- ================== Helpers ==================

local function safe_call(fn, ...)
    local result = { pcall(fn, ...) }
    if not result[1] then
        print("Console error: " .. tostring(result[2]))
        return nil, result[2]
    end
    return result[2]
end

local function clamp(value, min, max)
    if not value then return min end
    if value < min then return min end
    if value > max then return max end
    return value
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

-- Guarded runtime name -> prefab_hash resolution. The catalog provides reagent
-- NAMES; the controller and storage speak prefab HASHES, so the console resolves
-- the hash here via the engine's Animator.StringToHash / IC10 HASH() and keys the
-- cost vector on it. Guarded so a missing or guarded engine capability logs and
-- refuses instead of crashing the console.
local function resolve_prefab_hash(reagent_name)
    if type(hash) ~= "function" then
        return nil, "no_hash_fn"
    end
    if type(reagent_name) ~= "string" then
        return nil, "bad_reagent_name"
    end
    local ok, h = pcall(hash, reagent_name)
    if not ok or type(h) ~= "number" then
        return nil, "hash_failed"
    end
    return h, nil
end

-- ================== State ==================

local state = {
    console_uuid = nil,
    controller_state = nil,
    controller_config = nil,
    last_state_revision = nil,
    preferences = {
        sort_mode = "by_phase",
        current_page = 1,
        panel_open = false,
        selected_family = nil,
        selected_recipe = nil,
        selected_quantity = 1,
        selected_printer = nil,
    },
    request_sequence = 0,
    offline = false,
    ui_surface = nil,
}

local safe_rpc_call
local fetch_controller_state
local fetch_controller_config
local submit_request
local cancel_task

-- RPC helper: request against the printer controller only.
function safe_rpc_call(method, payload, callback)
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
        sort_mode = state.preferences.sort_mode,
        current_page = state.preferences.current_page,
        panel_open = state.preferences.panel_open,
        selected_family = state.preferences.selected_family,
        selected_recipe = state.preferences.selected_recipe,
        selected_quantity = state.preferences.selected_quantity,
        selected_printer = state.preferences.selected_printer,
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
            state.preferences.sort_mode = decoded.sort_mode or state.preferences.sort_mode
            state.preferences.current_page = decoded.current_page or 1
            if decoded.panel_open ~= nil then
                state.preferences.panel_open = decoded.panel_open
            end
            state.preferences.selected_family = decoded.selected_family
            state.preferences.selected_recipe = decoded.selected_recipe
            if decoded.selected_quantity then
                state.preferences.selected_quantity = decoded.selected_quantity
            end
            state.preferences.selected_printer = decoded.selected_printer
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

function fetch_controller_state(callback)
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

function fetch_controller_config(callback)
    safe_rpc_call("printers.get_config", { api_version = API_VERSION }, function(result, err)
        if result then
            state.controller_config = result
        end
        if callback then callback(result, err) end
    end)
end

-- ================== Actions ==================

-- Resolve the per-single-item reagent grams for the selected recipe.
--
-- The controller is catalog-free: it TRUSTS the per-item cost vector this chip
-- packs, and aggregates (per-item x count) into the storage request(s) when the
-- task is reached. So the console owns the "single item" knowledge: it pulls the
-- recipe's per-reagent gram amounts from the controller-provided config, strips
-- zeros, and HASHES each reagent name to its prefab hash, yielding a clean
-- { prefab_hash = grams } vector for ONE item plus a parallel { prefab_hash =
-- display_name } label table for UI/logs only. It never touches storage and never
-- carries a controller revision. Returns (cost_vector, labels, nil) on success or
-- (nil, nil, reason) on a refusal (no_config/unknown_family/unknown_recipe/
-- hash_unavailable).
local function resolve_recipe_cost_vector(family_name, recipe_name)
    local config = state.controller_config
    if type(config) ~= "table" or type(config.families) ~= "table" then
        return nil, nil, "no_config"
    end
    local families = config.families
    -- The config exposes families as a list of { name, recipes = { { name, reagents } } }
    -- (hot-reloaded from the recipe catalog), so a fresh recipe set is available
    -- without restarting the controller.
    local family_entry
    for _, fam in ipairs(families) do
        if type(fam) == "table" and fam.name == family_name then
            family_entry = fam
            break
        end
    end
    if not family_entry or type(family_entry.recipes) ~= "table" then
        return nil, nil, "unknown_family"
    end
    local recipe_entry
    for _, recipe in ipairs(family_entry.recipes) do
        if type(recipe) == "table" and recipe.name == recipe_name then
            recipe_entry = recipe
            break
        end
    end
    if not recipe_entry or type(recipe_entry.reagents) ~= "table" then
        return nil, nil, "unknown_recipe"
    end
    local per_item = {}
    local labels = {}
    -- The catalog provides reagent NAMES; the controller and storage speak prefab
    -- HASHES, so hash each positive reagent and key the cost vector on the hash.
    -- One gramm == one item, so a reagent's per-item grams pass straight through.
    -- A parallel labels table keeps the human name for UI / logs only -- it is
    -- NEVER sent as the controller/storage key.
    for reagent, grams in pairs(recipe_entry.reagents) do
        if type(reagent) == "string" and type(grams) == "number" and grams > 0 then
            local h, herr = resolve_prefab_hash(reagent)
            if not h then
                -- A reagent we cannot resolve to a hash blocks this recipe: the
                -- catalog-free controller would reject a name-keyed vector as
                -- invalid. Log and refuse rather than emit a half-resolved vector.
                print("PrinterConsole: cannot hash reagent '" .. reagent .. "' for " ..
                    tostring(family_name) .. "/" .. tostring(recipe_name) .. " (" ..
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
    if not family then
        print("PrinterConsole: no family selected")
        return nil
    end
    if state.offline or not state.controller_state or state.controller_state.phase ~= "ready" then
        print("PrinterConsole: controller not ready")
        return nil
    end

    -- The console sends the per-single-item grams as a HASH-KEYED cost_vector
    -- (prefab_hash -> grams) plus the count and a UI-only display-name table; the
    -- catalog-free controller aggregates (per-item x count) and requests storage
    -- once the task is reached.
    local cost_vector, labels, cost_err = resolve_recipe_cost_vector(family, recipe)
    if not cost_vector then
        -- Surface the controller-side boundary reason to the operator instead of
        -- letting a malformed request silently fall out. The catalog-free
        -- controller would reject this as invalid_cost_vector; we pre-check.
        print("PrinterConsole: cannot resolve recipe for " .. tostring(family) .. "/" ..
            tostring(recipe) .. " (" .. tostring(cost_err) .. ")")
        return nil
    end

    local count = clamp(state.preferences.selected_quantity, 1, 1000000)

    state.request_sequence = state.request_sequence + 1
    local client_request_id = string.format("pcc-%s-%d-%d",
        state.console_uuid,
        math.floor(os.clock() * 1000),
        state.request_sequence)

    local payload = {
        api_version = API_VERSION,
        client_request_id = client_request_id,
        family_name = family,          -- routing topology key (controller-owned)
        item = recipe,                 -- product label for UI/logs (the family routes it)
        recipe = recipe,               -- legacy alias
        cost_vector = cost_vector,     -- per-ONE-item reagent grams, HASH-KEYED (prefab_hash = grams)
        reagent_labels = labels,       -- HASH -> display name, UI/logs only (never a controller/storage key)
        count = count,                 -- items to print; controller aggregates x count
        quantity = count,              -- legacy alias
        destination_id = CONSOLE_DESTINATION_ID,
        printer_ref = state.preferences.selected_printer,
    }

    safe_rpc_call("printers.request", payload, function(result, rpc_err)
        if result and result.ok then
            print("PrinterConsole: submitted " .. tostring(result.task_id))
            fetch_controller_state()
            fetch_controller_config()
        else
            -- Display the controller's error code so the operator can act on it.
            local code = tostring(rpc_err or (result and (result.err_code or result.code)) or "unknown")
            print("PrinterConsole: request failed: " .. code)
        end
    end)
    return client_request_id
end

-- Cancels an in-flight / queued / paused task.
function cancel_task(task_id, reason)
    local payload = {
        api_version = API_VERSION,
        request_id = task_id,
        reason = reason or "console_cancel",
        requester_id = state.console_uuid,
    }
    safe_rpc_call("printers.cancel", payload, function(result, rpc_err)
        if result and result.ok then
            print("PrinterConsole: cancelled " .. task_id)
            fetch_controller_state()
        else
            print("PrinterConsole: cancel failed: " .. tostring(rpc_err or (result and result.err_code)))
        end
    end)
end

-- ================== UI (headless-safe) ==================

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

local function render_task_list(s, task, x, y, width, height, index)
    local row_h = height
    s:element({
        id = "task_" .. index .. "_state",
        type = "text",
        rect = { unit = "px", x = x, y = y, w = 260, h = row_h },
        props = {
            text = string.format("(%s) x%d %s %s",
                tostring(task.state or "?"),
                task.total_quantity or 0,
                tostring(task.recipe or "?"),
                tostring(task.state == "PRINTING" and task.print_progress and math.floor(task.print_progress * 100) or 0) .. "%"),
        },
        style = { text = "#FFFFFF", font_size = 11 },
    })

    if task.state ~= "DONE" and task.state ~= "CANCELLED" and task.state ~= "FAILED" then
        s:element({
            id = "cancel_" .. index,
            type = "button",
            rect = { unit = "px", x = x + width - 70, y = y, w = 65, h = 22 },
            props = { text = "CANCEL" },
            style = { bg = "#7A1E1E", text = "#FFFFFF", font_size = 10 },
            on_click = function()
                cancel_task(task.task_id, "console_cancel")
            end,
        })
    end
end

local function render_families(s, x, y, width, height)
    local config = state.controller_config
    if not config or not config.families then return end
    for i, fam in ipairs(config.families) do
        s:element({
            id = "family_" .. i,
            type = "button",
            rect = { unit = "px", x = x, y = y + (i - 1) * 24, w = width - 90, h = 22 },
            props = { text = tostring(fam.name) },
            style = { bg = "#2A2A3E", text = "#FFCC99", font_size = 11 },
            on_click = function()
                state.preferences.selected_family = fam.name
                if fam.recipes and fam.recipes[1] then
                    state.preferences.selected_recipe = fam.recipes[1].name
                end
                state.preferences.panel_open = true
                persist_preferences()
                render_ui()
            end,
        })
    end
end

local function render_request_panel(s, width, height)
    local panel_y = height - height * 0.24
    s:element({
        id = "request_label",
        type = "text",
        rect = { unit = "px", x = 20, y = panel_y + 4, w = width - 40, h = 16 },
        props = { text = "PRINT REQUEST", font_size = 12 },
        style = { text = "#99CCFF" },
    })
    s:element({
        id = "request_button",
        type = "button",
        rect = { unit = "px", x = width - 160, y = panel_y + 4, w = 140, h = 26 },
        props = { text = "REQUEST" },
        style = { bg = "#00994D", text = "#FFFFFF", font_size = 13 },
        on_click = function()
            submit_request()
        end,
    })
    s:element({
        id = "qty_minus",
        type = "button",
        rect = { unit = "px", x = width - 350, y = panel_y + 4, w = 40, h = 26 },
        props = { text = "-1" },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 10 },
        on_click = function()
            state.preferences.selected_quantity = clamp(state.preferences.selected_quantity - 1, 1, 1000000)
            persist_preferences()
            render_ui()
        end,
    })
    s:element({
        id = "qty_plus",
        type = "button",
        rect = { unit = "px", x = width - 300, y = panel_y + 4, w = 40, h = 26 },
        props = { text = "+1" },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 10 },
        on_click = function()
            state.preferences.selected_quantity = clamp(state.preferences.selected_quantity + 1, 1, 1000000)
            persist_preferences()
            render_ui()
        end,
    })
end

function render_ui()
    if not state.ui_surface then
        state.ui_surface = ss.ui.surface("printerc")
        ss.ui.activate("printerc")
    end
    local s = state.ui_surface
    local size = s:size()
    local width = tonumber(size.w) or 1024
    local height = tonumber(size.h) or 768

    s:clear()

    -- Header: status pill + task count.
    s:element({
        id = "status_pill",
        type = "text",
        rect = { unit = "px", x = 12, y = 12, w = 200, h = 22 },
        props = { text = get_status_pill_text() },
        style = { text = get_status_pill_color(), font_size = 13, bold = true },
    })
    local task_count = state.controller_state and state.controller_state.task_count or 0
    s:element({
        id = "task_count_label",
        type = "text",
        rect = { unit = "px", x = 230, y = 12, w = 300, h = 22 },
        props = { text = string.format("Tasks: %d   rev %s", task_count, tostring(state.last_state_revision or "?")), font_size = 11 },
        style = { text = "#CCCCCC" },
    })

    render_families(s, 12, 50, 300, height - 60)
    render_task_list(s, (state.controller_state and state.controller_state.tasks and state.controller_state.tasks[1]) or {}, 330, 50, width - 350, height - 120, 1)
    if state.preferences.panel_open then
        render_request_panel(s, width, height)
    end
end

-- ================== Init ==================

initialize_console_uuid()
restore_preferences()
fetch_controller_config()
render_ui()

-- ================== Main loop ==================

local last_config_time = 0
local last_poll_time = 0

while true do
    local current_time = os.clock()
    if current_time - last_poll_time >= POLL_INTERVAL then
        fetch_controller_state()
        last_poll_time = current_time
    end
    if current_time - last_config_time >= 10.0 then
        fetch_controller_config()
        last_config_time = current_time
        render_ui()
    end
    yield()
end
