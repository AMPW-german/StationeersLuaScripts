local LT = ic.enums.LogicType

-- ================== User config ==================
-- Interconnect naming: ic.net targets resolve a HOUSING's labeller name, and
-- housings cross Logic Filter Bridges only when their display name contains
-- NET_TAG (max 6 ASCII chars -- the bridge's packed Setting budget). Label the
-- storage controller's housing LuaC.Storage.Controller and every Logic Filter
-- Bridge LuaBridge; setup_bridges() programs each bridge at boot.
local NET_TAG = "LuaC."
local CONTROLLER_NAME = "LuaC.Storage.Controller"
local BRIDGE_NAME = "LuaBridge"
local BRIDGE_PREFAB_HASH = 1273838679 -- StructureLogicFilterBridge
local BRIDGE_NAME_MODE = 2            -- mode 2: display name contains packed Setting

local API_VERSION = 1

local function safe_call(fn, ...)
    local result = { pcall(fn, ...) }
    if not result[1] then
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
                print("StorageRequestTest: bridge " .. tostring(ref_id) .. " config write failed")
            end
        end
    end
end

setup_bridges()

local requests = {
    {
        resource = "iron",
        prefab_hash = hash("ItemIronIngot"),
        button_name = "Storage.Test.IronButton",
        dial_name = "Storage.Test.IronDial",
    },
    {
        resource = "copper",
        prefab_hash = hash("ItemCopperIngot"),
        button_name = "Storage.Test.CopperButton",
        dial_name = "Storage.Test.CopperDial",
    },
}

local request_sequence = 0

local function request_resource(control, quantity)
    request_sequence = request_sequence + 1
    local client_request_id = string.format("%s-%d-%d", control.resource, math.floor(os.clock() * 1000), request_sequence)
    ic.net.request(CONTROLLER_NAME, "storage.request", {
        api_version = API_VERSION,
        client_request_id = client_request_id,
        prefab_hash = control.prefab_hash,
        quantity = quantity,
        destination_id = "Storage.TestConsole",
    }, function(ok, response, err)
        if not ok then
            print(control.resource .. " request failed: " .. tostring(err))
        elseif response.ok then
            print(control.resource .. " request " .. response.request_id .. " " .. response.state)
        else
            print(control.resource .. " request rejected: " .. tostring(response.code))
        end
    end, 5)
end

for _, control in ipairs(requests) do
    control.button = ic.find(control.button_name)
    control.dial = ic.find(control.dial_name)
    if control.button == nil or control.dial == nil then
        error("missing test control for " .. control.resource)
    end
    control.was_pressed = ic.read_id(control.button, LT.Activate) ~= 0
end

while true do
    for _, control in ipairs(requests) do
        local pressed = ic.read_id(control.button, LT.Activate) ~= 0
        if pressed and not control.was_pressed then
            local quantity = math.floor(ic.read_id(control.dial, LT.Setting) + 0.5)
            request_resource(control, quantity)
        end
        control.was_pressed = pressed
    end
    yield()
end