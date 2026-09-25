local LT = ic.enums.LogicType

local API_VERSION = 1
local CONTROLLER_NAME = "Storage.Controller"

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