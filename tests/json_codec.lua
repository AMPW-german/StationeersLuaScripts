
-- tests/json_codec.lua : minimal, dependency-free JSON codec for Lua 5.1.
-- Supports scalars (nil/bool/number/string) and tables as objects or arrays.
-- Used only as a test stand-in for the game-provided util.json; the controller
-- itself calls util.json.{encode,decode} (real in game).
local M = {}

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        if k < 1 or k ~= math.floor(k) then return false end
        n = n + 1
    end
    return n == #t and n > 0
end

local function escape(s)
    s = s:gsub('[%z\\\133-255\128-\177]', function(c)
        return string.format("\\u%04x", string.byte(c))
    end)
    s = (s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t'))
    return s
end

function M.encode(t, indent)
    indent = indent or ''
    local inner = indent .. '  '
    local et = type(t)
    if t == nil then return 'null' end
    if et == 'boolean' then return t and 'true' or 'false' end
    if et == 'number' then return tostring(t) end
    if et == 'string' then return '"' .. escape(t) .. '"' end
    if et == 'table' then
        local parts = {}
        if is_array(t) then
            for i = 1, #t do
                table.insert(parts, M.encode(t[i], inner))
            end
            return '[ ' .. table.concat(parts, ', ') .. ' ]'
        else
            for k, v in pairs(t) do
                if v ~= nil then
                    table.insert(parts, '"' .. escape(k) .. '": ' .. M.encode(v, inner))
                end
            end
            return '{ ' .. table.concat(parts, ', ') .. ' }'
        end
    end
    return 'null'
end

-- ---- recursive-descent decoder ----
local s, pos
local parse_value, parse_object, parse_array, parse_string, parse_number  -- forward decls
local function peek() return s:sub(pos, pos) end

local function skip_ws()
    while true do
        local c = s:sub(pos, pos)
        if c:match("[%s]") then pos = pos + 1
        else break end
    end
end

function parse_value()
    skip_ws()
    local c = peek()
    if c == '{' then return parse_object() end
    if c == '[' then return parse_array() end
    if c == '"' then return parse_string() end
    if c:match("[%d%-]") then return parse_number() end
    if s:sub(pos, pos+3) == 'true' then pos = pos + 4; return true end
    if s:sub(pos, pos+4) == 'false' then pos = pos + 5; return false end
    if s:sub(pos, pos+4) == 'null' then pos = pos + 4; return nil end
    error('bad json at pos ' .. pos)
end

function parse_object()
    local t = {}
    pos = pos + 1  -- {
    skip_ws()
    if peek() == '}' then pos = pos + 1; return t end
    while true do
        skip_ws()
        if peek() ~= '"' then error('expected key string at ' .. pos) end
        local k = parse_string()
        skip_ws()
        if peek() ~= ':' then error('expected colon at ' .. pos) end
        pos = pos + 1
        local v = parse_value()
        t[k] = v
        skip_ws()
        local c = peek()
        if c == '}' then pos = pos + 1; break end
        if c ~= ',' then error('expected comma or } at ' .. pos) end
        pos = pos + 1
    end
    return t
end

function parse_array()
    local t = {}
    pos = pos + 1  -- [
    skip_ws()
    if peek() == ']' then pos = pos + 1; return t end
    local i = 0
    while true do
        local v = parse_value()
        i = i + 1
        t[i] = v
        skip_ws()
        local c = peek()
        if c == ']' then pos = pos + 1; break end
        if c ~= ',' then error('expected comma or ] at ' .. pos) end
        pos = pos + 1
    end
    return t
end

function parse_string()
    pos = pos + 1  -- "
    local buf = {}
    while true do
        local c = s:sub(pos, pos)
        if c == '"' then pos = pos + 1; break end
        if c == '\\' then
            local n = s:sub(pos+1, pos+1)
            if n == 'n' then table.insert(buf, '\n')
            elseif n == 't' then table.insert(buf, '\t')
            elseif n == 'r' then table.insert(buf, '\r')
            elseif n == '\\' then table.insert(buf, '\\')
            elseif n == '"' then table.insert(buf, '"')
            elseif n == 'u' then
                local hex = s:sub(pos+2, pos+5)
                table.insert(buf, string.char(tonumber(hex, 16)))
                pos = pos + 6
            else
                table.insert(buf, n)
            end
            pos = pos + 2
        else
            table.insert(buf, c)
            pos = pos + 1
        end
        if pos > #s then break end
    end
    return table.concat(buf)
end

function parse_number()
    local num = s:sub(pos):match('^[-%d%.eE+]+')
    pos = pos + #num
    return tonumber(num)
end

function M.decode(str)
    s = str
    pos = 1
    local v = parse_value()
    return v
end

return M
