local API_VERSION = 1
local POLL_INTERVAL = 1.0
local CELL_GAP = 8
local GRID_COLUMNS = 4
local GRID_ROWS = 4
local SILO_STACK_CAPACITY = 600
local PANEL_HEIGHT_RATIO = 0.225
local PAGINATION_BAR_HEIGHT = 28
local CONTROLLER_TARGET = "Storage.Controller"
local CONSOLE_DESTINATION_ID = "Storage.Console"

local function safe_call(fn, ...)
    local result = { pcall(fn, ...) }
    if not result[1] then
        return nil, result[2]
    end
    return result[2]
end

local function clamp(value, min, max)
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

local function item_name(prefab_hash)
    local ok, name = pcall(prefab_name, prefab_hash)
    if ok and name then
        if string.sub(name, 1, 4) == "Item" and #name > 4 then
            return string.sub(name, 5)
        end
        return name
    end
    return "Unknown Item"
end

local state = {
    console_uuid = nil,
    controller_state = nil,
    last_state_revision = nil,
    last_inventory_revision = nil,
    preferences = {
        sort_mode = "by_silo",
        current_page = 1,
        panel_open = false,
        selected_resource_prefab_hash = nil,
        selected_quantity = 1,
    },
    request_sequence = 0,
    offline = false,
    ui_surface = nil,
}

local refresh_silo_cards

local function safe_rpc_call(method, payload, callback)
    local timeout = 5
    ic.net.request(CONTROLLER_TARGET, method, payload, function(ok, response, err)
        if not ok then
            state.offline = true
            if callback then
                callback(nil, "rpc_timeout")
            end
        else
            state.offline = false
            if response and response.api_version == API_VERSION then
                if callback then
                    callback(response, nil)
                end
            else
                if callback then
                    callback(nil, "invalid_response")
                end
            end
        end
    end, timeout)
end

local function persist_preferences()
    local prefs_to_save = {
        sort_mode = state.preferences.sort_mode,
        current_page = state.preferences.current_page,
        panel_open = state.preferences.panel_open,
        selected_resource_prefab_hash = state.preferences.selected_resource_prefab_hash,
        selected_quantity = state.preferences.selected_quantity,
    }
    local ok, encoded = pcall(util.json.encode, prefs_to_save)
    if ok then
        safe_call(ic.persist.set, "storage_console_prefs", encoded)
    end
end

local function restore_preferences()
    local encoded = safe_call(ic.persist.get, "storage_console_prefs")
    if encoded then
        local ok, decoded = pcall(util.json.decode, encoded)
        if ok and type(decoded) == "table" then
            if decoded.sort_mode then
                state.preferences.sort_mode = decoded.sort_mode
            end
            if decoded.current_page then
                state.preferences.current_page = decoded.current_page
            end
            if decoded.panel_open ~= nil then
                state.preferences.panel_open = decoded.panel_open
            end
            if decoded.selected_resource_prefab_hash then
                state.preferences.selected_resource_prefab_hash = decoded.selected_resource_prefab_hash
            end
            if decoded.selected_quantity then
                state.preferences.selected_quantity = decoded.selected_quantity
            end
        end
    end
end

local function initialize_console_uuid()
    local stored_uuid = safe_call(ic.persist.get, "storage_console_uuid")
    if stored_uuid and type(stored_uuid) == "string" and #stored_uuid == 36 then
        state.console_uuid = stored_uuid
    else
        state.console_uuid = generate_uuid()
        safe_call(ic.persist.set, "storage_console_uuid", state.console_uuid)
    end
end

local function fetch_controller_state(callback)
    safe_rpc_call("storage.get_state", { 
        api_version = API_VERSION, 
        include_groups = true 
    }, function(result, err)
        if result and result.ok then
            local had_controller_state = state.controller_state ~= nil
            state.controller_state = result
            state.last_state_revision = result.state_revision
            state.last_inventory_revision = result.inventory_revision
            if state.preferences.panel_open and had_controller_state and refresh_silo_cards then
                refresh_silo_cards()
            else
                render_ui()
            end
            if callback then
                callback(true)
            end
        else
            if state.preferences.panel_open and refresh_silo_cards then
                refresh_silo_cards()
            else
                render_ui()
            end
            if callback then
                callback(false)
            end
        end
    end)
end

local function get_sorted_groups()
    if not state.controller_state or not state.controller_state.groups then
        return {}
    end
    
    local groups = {}
    for _, group in ipairs(state.controller_state.groups) do
        groups[#groups + 1] = group
    end
    
    if state.preferences.sort_mode == "by_silo" then
        table.sort(groups, function(a, b)
            return a.id < b.id
        end)
    elseif state.preferences.sort_mode == "by_resource" then
        table.sort(groups, function(a, b)
            local name_a = a.prefab_hash and item_name(a.prefab_hash) or ""
            local name_b = b.prefab_hash and item_name(b.prefab_hash) or ""
            
            -- Both have names - sort by name, then by ID
            if a.prefab_hash and b.prefab_hash then
                if name_a == name_b then
                    return a.id < b.id
                end
                return name_a < name_b
            end
            
            -- Only a has a name - a comes first
            if a.prefab_hash and not b.prefab_hash then
                return true
            end
            
            -- Only b has a name - b comes first
            if not a.prefab_hash and b.prefab_hash then
                return false
            end
            
            -- Neither has a name - sort by ID
            return a.id < b.id
        end)
    else -- by_quantity
        table.sort(groups, function(a, b)
            local qty_a = a.confirmed_quantity or 0
            local qty_b = b.confirmed_quantity or 0
            
            -- Both have prefab_hash - sort by quantity descending, then by ID
            if a.prefab_hash and b.prefab_hash then
                if qty_a == qty_b then
                    return a.id < b.id
                end
                return qty_a > qty_b
            end
            
            -- Only a has a prefab_hash - a comes first
            if a.prefab_hash and not b.prefab_hash then
                return true
            end
            
            -- Only b has a prefab_hash - b comes first
            if not a.prefab_hash and b.prefab_hash then
                return false
            end
            
            -- Neither has a prefab_hash - sort by ID
            return a.id < b.id
        end)
    end
    
    return groups
end

local function get_paginated_groups(groups, cols, rows)
    local page_size = cols * rows
    local start_idx = (state.preferences.current_page - 1) * page_size + 1
    local end_idx = math.min(start_idx + page_size - 1, #groups)
    
    local paginated = {}
    for i = start_idx, end_idx do
        paginated[#paginated + 1] = groups[i]
    end
    
    return paginated, math.ceil(#groups / page_size)
end

local function calculate_card_dimensions(grid_width, grid_height, rows)
    local card_width = (grid_width - CELL_GAP * (GRID_COLUMNS + 1)) / GRID_COLUMNS
    local card_height = (grid_height - CELL_GAP * (rows + 1)) / rows
    return math.max(1, card_width), math.max(1, card_height)
end

local function get_status_pill_text()
    if state.offline then
        return "OFFLINE"
    end
    
    if not state.controller_state then
        return "DISCOVERING"
    end
    
    local phase = state.controller_state.phase
    if phase == "ready" then
        return "READY"
    elseif phase == "faulted" then
        return "FAULT"
    else
        return string.upper(phase)
    end
end

local function get_status_pill_color()
    if state.offline then
        return {r = 128, g = 128, b = 128}
    end
    
    if not state.controller_state then
        return {r = 255, g = 204, b = 0}
    end
    
    local phase = state.controller_state.phase
    if phase == "ready" then
        return {r = 0, g = 255, b = 0}
    elseif phase == "faulted" then
        return {r = 255, g = 0, b = 0}
    else
        return {r = 255, g = 204, b = 0}
    end
end

local function render_header(s, width, height)
    -- Background
    s:element({
        id = "header_bg",
        type = "panel",
        rect = { unit = "px", x = 0, y = 0, w = width, h = height },
        style = { bg = "#1A1A2E" }
    })
    
    -- Status pill
    local status_text = get_status_pill_text()
    local status_color = get_status_pill_color()
    local color_hex = string.format("#%02X%02X%02X", status_color.r, status_color.g, status_color.b)
    
    s:element({
        id = "status_pill_bg",
        type = "panel",
        rect = { unit = "px", x = 10, y = height / 2 - 12, w = 80, h = 24 },
        style = { bg = color_hex }
    })
    s:element({
        id = "status_text",
        type = "label",
        rect = { unit = "px", x = 10, y = height / 2 - 7, w = 80, h = 14 },
        props = { text = status_text },
        style = { font_size = 14, color = "#000000", align = "center" }
    })
    
    -- Sort toggle
    local sort_text
    if state.preferences.sort_mode == "by_silo" then
        sort_text = "[BY SILO]"
    elseif state.preferences.sort_mode == "by_resource" then
        sort_text = "[BY RESOURCE]"
    else
        sort_text = "[BY QUANTITY]"
    end
    s:element({
        id = "sort_toggle",
        type = "button",
        rect = { unit = "px", x = width / 2 - 50, y = height / 2 - 7, w = 100, h = 14 },
        props = { text = sort_text },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 14 },
        on_click = function(playerName)
            if state.preferences.sort_mode == "by_silo" then
                state.preferences.sort_mode = "by_resource"
            elseif state.preferences.sort_mode == "by_resource" then
                state.preferences.sort_mode = "by_quantity"
            else
                state.preferences.sort_mode = "by_silo"
            end
            persist_preferences()
            render_ui()
        end
    })
    
    -- Request panel toggle
    s:element({
        id = "request_toggle",
        type = "button",
        rect = { unit = "px", x = width - 80, y = height / 2 - 7, w = 80, h = 14 },
        props = { text = "[REQUEST]" },
        style = { bg = "#2A2A3E", text = "#00FF80", font_size = 14 },
        on_click = function(playerName)
            state.preferences.panel_open = not state.preferences.panel_open
            persist_preferences()
            render_ui()
        end
    })
    
    return height
end

local function render_silo_card(s, group, x, y, width, height, index)
    -- Background with vertical progress bar
    local fill_ratio = 0
    if group.silo_stack_count then
        fill_ratio = clamp(group.silo_stack_count / SILO_STACK_CAPACITY, 0, 1)
    end
    
    local card_id = "card_" .. tostring(index)
    
    -- Card background
    s:element({
        id = card_id .. "_bg",
        type = "panel",
        rect = { unit = "px", x = x, y = y, w = width, h = height },
        style = { bg = "#262633" }
    })
    
    -- Vertical progress bar (bottom to top)
    if fill_ratio > 0 then
        local bar_height = height * fill_ratio
        s:element({
            id = card_id .. "_progress",
            type = "panel",
            rect = { unit = "px", x = x, y = y + height - bar_height, w = width, h = bar_height },
            style = { bg = "#0080CC" }
        })
    end
    
    local padding = 8
    local quantity_x = x + width * 0.4
    local quantity_width = width * 0.6 - padding
    local details_y = y + height / 2
    local icon_size = math.max(1, math.min(48, width / 2 - padding * 2, height / 2 - padding * 2))
    local icon_x = x + padding
    local icon_y = y + padding

    -- Icon
    if group.prefab_hash then
        s:element({
            id = card_id .. "_icon",
            type = "icon",
            rect = { unit = "px", x = icon_x, y = icon_y, w = icon_size, h = icon_size },
            props = { icon_type = "prefab", name = tostring(group.prefab_hash) }
        })
    else
        -- Placeholder icon for unassigned
        s:element({
            id = card_id .. "_placeholder",
            type = "panel",
            rect = { unit = "px", x = icon_x, y = icon_y, w = icon_size, h = icon_size },
            style = { bg = "#4D4D59" }
        })
    end

    local quantity = group.confirmed_quantity or 0
    local max_quantity = "--"
    if group.max_stack_quantity then
        max_quantity = tostring(group.max_stack_quantity * SILO_STACK_CAPACITY)
    end
    s:element({
        id = card_id .. "_qty",
        type = "label",
        rect = { unit = "px", x = quantity_x, y = y + padding, w = quantity_width, h = 14 },
        props = { text = tostring(quantity) },
        style = { font_size = 14, color = "#CCE5FF", align = "right" }
    })

    s:element({
        id = card_id .. "_max_qty",
        type = "label",
        rect = { unit = "px", x = quantity_x, y = y + padding + 16, w = quantity_width, h = 12 },
        props = { text = max_quantity },
        style = { font_size = 12, color = "#9999B3", align = "right" }
    })

    local name = group.prefab_hash and item_name(group.prefab_hash) or "--"
    s:element({
        id = card_id .. "_name",
        type = "label",
        rect = { unit = "px", x = x + padding, y = details_y, w = width - padding * 2, h = 16 },
        props = { text = name },
        style = { font_size = 13, color = "#FFFFFF", align = "center" }
    })

    s:element({
        id = card_id .. "_id",
        type = "label",
        rect = { unit = "px", x = x + padding, y = details_y + 20, w = width - padding * 2, h = 12 },
        props = { text = group.label or string.format("0x%04X", group.id) },
        style = { font_size = 12, color = "#9999B3", align = "center" }
    })
    
    -- Card click handler for resource selection
    s:element({
        id = card_id .. "_click",
        type = "button",
        rect = { unit = "px", x = x, y = y, w = width, h = height },
        props = { text = "" },
        style = { bg = "transparent", text = "transparent" },
        on_click = function(playerName)
            if group.prefab_hash then
                state.preferences.selected_resource_prefab_hash = group.prefab_hash
                state.preferences.panel_open = true
                persist_preferences()
                render_ui()
            end
        end
    })
    
    -- Highlight border if selected
    if state.preferences.selected_resource_prefab_hash == group.prefab_hash then
        s:element({
            id = card_id .. "_border",
            type = "border",
            rect = { unit = "px", x = x, y = y, w = width, h = height },
            style = { color = "#00FF80", thickness = 2 }
        })
    end
end

local function render_silo_grid(s, x, y, width, height)
    local rows = state.preferences.panel_open and 3 or GRID_ROWS
    local groups = get_sorted_groups()
    local max_page = math.max(1, math.ceil(#groups / (GRID_COLUMNS * rows)))
    state.preferences.current_page = clamp(state.preferences.current_page, 1, max_page)
    local paginated_groups, total_pages = get_paginated_groups(groups, GRID_COLUMNS, rows)
    local cards_height = math.max(1, height - PAGINATION_BAR_HEIGHT)
    local card_width, card_height = calculate_card_dimensions(width, cards_height, rows)
    
    -- Grid background
    s:element({
        id = "grid_bg",
        type = "panel",
        rect = { unit = "px", x = x, y = y, w = width, h = height },
        style = { bg = "#14141F" }
    })
    
    -- Render cards above the pagination footer.
    for i, group in ipairs(paginated_groups) do
        local col = (i - 1) % GRID_COLUMNS
        local row = math.floor((i - 1) / GRID_COLUMNS)
        local card_x = x + CELL_GAP + col * (card_width + CELL_GAP)
        local card_y = y + CELL_GAP + row * (card_height + CELL_GAP)
        render_silo_card(s, group, card_x, card_y, card_width, card_height, i)
    end
    
    s:element({
        id = "pagination_bar",
        type = "panel",
        rect = { unit = "px", x = x, y = y + cards_height, w = width, h = PAGINATION_BAR_HEIGHT },
        style = { bg = "#1A1A2E" }
    })

    -- Pagination controls
    if total_pages > 1 then
        local page_text = string.format("Page %d/%d", state.preferences.current_page, total_pages)
        s:element({
            id = "pagination_text",
            type = "label",
            rect = { unit = "px", x = x + width / 2 - 50, y = y + cards_height + 8, w = 100, h = 12 },
            props = { text = page_text },
            style = { font_size = 12, color = "#9999B3", align = "center" }
        })
        
        -- Previous page button
        s:element({
            id = "prev_page",
            type = "button",
            rect = { unit = "px", x = x + 20, y = y + cards_height + 4, w = 50, h = 20 },
            props = { text = "<" },
            style = { bg = "#2A2A3E", text = "#FFFFFF", font_size = 14 },
            on_click = function(playerName)
                if state.preferences.current_page > 1 then
                    state.preferences.current_page = state.preferences.current_page - 1
                    persist_preferences()
                    render_ui()
                end
            end
        })
        
        -- Next page button
        s:element({
            id = "next_page",
            type = "button",
            rect = { unit = "px", x = x + width - 70, y = y + cards_height + 4, w = 50, h = 20 },
            props = { text = ">" },
            style = { bg = "#2A2A3E", text = "#FFFFFF", font_size = 14 },
            on_click = function(playerName)
                if state.preferences.current_page < total_pages then
                    state.preferences.current_page = state.preferences.current_page + 1
                    persist_preferences()
                    render_ui()
                end
            end
        })
    end
end

refresh_silo_cards = function()
    if not state.ui_surface then
        return
    end

    local status_color = get_status_pill_color()
    local status_bg = state.ui_surface:get("status_pill_bg")
    local status_text = state.ui_surface:get("status_text")
    if status_bg then
        status_bg:set_style({ bg = string.format("#%02X%02X%02X", status_color.r, status_color.g, status_color.b) })
    end
    if status_text then
        status_text:set_props({ text = get_status_pill_text() })
    end

    local rows = state.preferences.panel_open and 3 or GRID_ROWS
    local groups = get_sorted_groups()
    local paginated_groups = get_paginated_groups(groups, GRID_COLUMNS, rows)
    for i, group in ipairs(paginated_groups) do
        local card_id = "card_" .. tostring(i)
        local quantity = state.ui_surface:get(card_id .. "_qty")
        local max_quantity = state.ui_surface:get(card_id .. "_max_qty")
        local name = state.ui_surface:get(card_id .. "_name")
        local id = state.ui_surface:get(card_id .. "_id")
        if quantity then
            quantity:set_props({ text = tostring(group.confirmed_quantity or 0) })
        end
        if max_quantity then
            local max = group.max_stack_quantity and tostring(group.max_stack_quantity * SILO_STACK_CAPACITY) or "--"
            max_quantity:set_props({ text = max })
        end
        if name then
            name:set_props({ text = group.prefab_hash and item_name(group.prefab_hash) or "--" })
        end
        if id then
            id:set_props({ text = group.label or string.format("0x%04X", group.id) })
        end
    end
    state.ui_surface:commit()
end

local function render_request_panel(s, width, height)
    local panel_height = height * PANEL_HEIGHT_RATIO
    local panel_y = height - panel_height
    
    -- Panel background
    s:element({
        id = "panel_bg",
        type = "panel",
        rect = { unit = "px", x = 0, y = panel_y, w = width, h = panel_height },
        style = { bg = "#0D0D1A" }
    })
    
    -- Close button
    s:element({
        id = "close_button",
        type = "button",
        rect = { unit = "px", x = width - 60, y = panel_y + 15, w = 60, h = 14 },
        props = { text = "[CLOSE]" },
        style = { bg = "#2A2A3E", text = "#FF8080", font_size = 14 },
        on_click = function(playerName)
            state.preferences.panel_open = false
            persist_preferences()
            render_ui()
        end
    })
    
    -- Resource selection section
    s:element({
        id = "resource_label",
        type = "label",
        rect = { unit = "px", x = 20, y = panel_y + 15, w = 80, h = 14 },
        props = { text = "Resource:" },
        style = { font_size = 14, color = "#CCCCCC", align = "left" }
    })
    
    -- Resource selector
    local resource_options = {}
    local resource_hashes = {}
    local seen_prefab_hashes = {}
    for _, group in ipairs(get_sorted_groups()) do
        if group.prefab_hash and not seen_prefab_hashes[group.prefab_hash] then
            local option = item_name(group.prefab_hash)
            resource_options[#resource_options + 1] = option
            resource_hashes[#resource_hashes + 1] = group.prefab_hash
            seen_prefab_hashes[group.prefab_hash] = true
        end
    end

    local selected_option = "0"
    for index, prefab_hash in ipairs(resource_hashes) do
        if prefab_hash == state.preferences.selected_resource_prefab_hash then
            selected_option = tostring(index - 1)
            break
        end
    end
    s:element({
        id = "resource_select",
        type = "select",
        rect = { unit = "px", x = 100, y = panel_y + 10, w = 240, h = 30 },
        props = { options = resource_options, selected = selected_option },
        style = { bg = "#1A1A2E", text = "#FFFFFF", font_size = 14 },
        on_change = function(new_value, playerName)
            local prefab_hash = resource_hashes[(tonumber(new_value) or -1) + 1]
            if prefab_hash then
                state.preferences.selected_resource_prefab_hash = prefab_hash
                state.preferences.selected_quantity = 1
                persist_preferences()
                render_ui()
            end
        end
    })

    -- Selected resource availability
    local selected_available = 0
    if state.preferences.selected_resource_prefab_hash and state.controller_state then
        for _, group in ipairs(state.controller_state.groups) do
            if group.prefab_hash == state.preferences.selected_resource_prefab_hash then
                selected_available = group.available_quantity or 0
                break
            end
        end
    end

    -- Quantity input section
    s:element({
        id = "quantity_label",
        type = "label",
        rect = { unit = "px", x = 20, y = panel_y + 55, w = 80, h = 14 },
        props = { text = "Quantity:" },
        style = { font_size = 14, color = "#CCCCCC", align = "left" }
    })

    s:element({
        id = "available_qty",
        type = "label",
        rect = { unit = "px", x = 20, y = panel_y + 73, w = 80, h = 12 },
        props = { text = string.format("Available: %d", selected_available) },
        style = { font_size = 12, color = "#99E599", align = "left" }
    })

    -- Direct number input
    s:element({
        id = "quantity_input",
        type = "textinput",
        rect = { unit = "px", x = 100, y = panel_y + 55, w = 80, h = 30 },
        props = { 
            value = tostring(state.preferences.selected_quantity), 
            placeholder = "1",
            title = "Enter quantity (1-" .. tostring(selected_available) .. ")"
        },
        style = { bg = "#1A1A2E", text = "#FFFFFF", placeholder_color = "#555555", font_size = 16 },
        on_change = function(new_value, playerName)
            local qty = tonumber(new_value)
            if qty and qty > 0 and qty <= selected_available then
                state.preferences.selected_quantity = math.floor(qty)
                persist_preferences()
                render_ui()
            end
        end
    })
    
    -- Quick adjustment buttons
    s:element({
        id = "qty_plus_100",
        type = "button",
        rect = { unit = "px", x = 190, y = panel_y + 55, w = 35, h = 20 },
        props = { text = "+100" },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 10 },
        on_click = function(playerName)
            local new_qty = state.preferences.selected_quantity + 100
            if new_qty <= selected_available then
                state.preferences.selected_quantity = new_qty
                persist_preferences()
                render_ui()
            end
        end
    })
    
    s:element({
        id = "qty_plus_10",
        type = "button",
        rect = { unit = "px", x = 230, y = panel_y + 55, w = 35, h = 20 },
        props = { text = "+10" },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 10 },
        on_click = function(playerName)
            local new_qty = state.preferences.selected_quantity + 10
            if new_qty <= selected_available then
                state.preferences.selected_quantity = new_qty
                persist_preferences()
                render_ui()
            end
        end
    })
    
    s:element({
        id = "qty_plus_1",
        type = "button",
        rect = { unit = "px", x = 270, y = panel_y + 55, w = 35, h = 20 },
        props = { text = "+1" },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 10 },
        on_click = function(playerName)
            local new_qty = state.preferences.selected_quantity + 1
            if new_qty <= selected_available then
                state.preferences.selected_quantity = new_qty
                persist_preferences()
                render_ui()
            end
        end
    })
    
    s:element({
        id = "max_button",
        type = "button",
        rect = { unit = "px", x = 310, y = panel_y + 55, w = 40, h = 20 },
        props = { text = "MAX" },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 10 },
        on_click = function(playerName)
            if selected_available > 0 then
                state.preferences.selected_quantity = selected_available
                persist_preferences()
                render_ui()
            end
        end
    })
    
    s:element({
        id = "qty_minus_100",
        type = "button",
        rect = { unit = "px", x = 190, y = panel_y + 77, w = 35, h = 20 },
        props = { text = "-100" },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 10 },
        on_click = function(playerName)
            local new_qty = state.preferences.selected_quantity - 100
            if new_qty > 0 then
                state.preferences.selected_quantity = new_qty
                persist_preferences()
                render_ui()
            end
        end
    })

    s:element({
        id = "qty_minus_10",
        type = "button",
        rect = { unit = "px", x = 230, y = panel_y + 77, w = 35, h = 20 },
        props = { text = "-10" },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 10 },
        on_click = function(playerName)
            local new_qty = state.preferences.selected_quantity - 10
            if new_qty > 0 then
                state.preferences.selected_quantity = new_qty
                persist_preferences()
                render_ui()
            end
        end
    })

    s:element({
        id = "qty_minus_1",
        type = "button",
        rect = { unit = "px", x = 270, y = panel_y + 77, w = 35, h = 20 },
        props = { text = "-1" },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 10 },
        on_click = function(playerName)
            local new_qty = state.preferences.selected_quantity - 1
            if new_qty > 0 then
                state.preferences.selected_quantity = new_qty
                persist_preferences()
                render_ui()
            end
        end
    })

    s:element({
        id = "min_button",
        type = "button",
        rect = { unit = "px", x = 310, y = panel_y + 77, w = 40, h = 20 },
        props = { text = "MIN" },
        style = { bg = "#2A2A3E", text = "#99CCFF", font_size = 10 },
        on_click = function(playerName)
            state.preferences.selected_quantity = 1
            persist_preferences()
            render_ui()
        end
    })

    -- Request button
    s:element({
        id = "request_button",
        type = "button",
        rect = { unit = "px", x = 365, y = panel_y + 55, w = 120, h = 30 },
        props = { text = "REQUEST" },
        style = { bg = "#00994D", text = "#FFFFFF", font_size = 14 },
        on_click = function(playerName)
            submit_request()
        end
    })
    
end

function render_ui()
    if not state.ui_surface then
        state.ui_surface = ss.ui.surface("main")
        ss.ui.activate("main")
    end
    
    local s = state.ui_surface
    local size = s:size()
    local width = tonumber(size.w) or 0
    local height = tonumber(size.h) or 0
    
    -- Clear UI
    s:clear()
    
    -- Render header
    local header_height = render_header(s, width, 50)
    
    -- Render silo grid
    local grid_height = height - header_height
    if state.preferences.panel_open then
        grid_height = grid_height - height * PANEL_HEIGHT_RATIO
    end
    render_silo_grid(s, 0, header_height, width, grid_height)
    
    -- Render request panel if open
    if state.preferences.panel_open then
        render_request_panel(s, width, height)
    end
end

function submit_request()
    if not state.preferences.selected_resource_prefab_hash then
        print("StorageConsole: No resource selected")
        return
    end
    
    if state.offline or not state.controller_state or state.controller_state.phase ~= "ready" then
        print("StorageConsole: Controller not ready")
        return
    end
    
    state.request_sequence = state.request_sequence + 1
    local client_request_id = string.format("console-%s-%d-%d", 
        state.console_uuid, 
        math.floor(os.clock() * 1000), 
        state.request_sequence)
    
    local payload = {
        api_version = API_VERSION,
        client_request_id = client_request_id,
        prefab_hash = state.preferences.selected_resource_prefab_hash,
        quantity = state.preferences.selected_quantity,
        destination_id = CONSOLE_DESTINATION_ID
    }
    
    safe_rpc_call("storage.request", payload, function(result, err)
        if result and result.ok then
            print("StorageConsole: Request submitted: " .. result.request_id)
            -- Refresh state
            fetch_controller_state()
        else
            print("StorageConsole: Request failed: " .. tostring(err or (result and result.code)))
        end
    end)
end

-- Initialize
initialize_console_uuid()
restore_preferences()
render_ui()

-- Main loop
local last_poll_time = 0

while true do
    local current_time = os.clock()
    
    -- Fetch controller state periodically
    if current_time - last_poll_time >= POLL_INTERVAL then
        fetch_controller_state()
        last_poll_time = current_time
    end
    
    -- Persist preferences if needed
    persist_preferences()
    
    -- Wait for next tick
    yield()
end