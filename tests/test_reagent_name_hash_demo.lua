-- tests/test_reagent_name_hash_demo.lua
-- Lua 5.1 -- no `bit`, no `jit.vesper`.
--
-- Offline DEMO for tests/test_reagent_name_hash.lua. It exists so the
-- name->prefab_hash discovery/proof logic can be EXERCISED without the game
-- engine, by injecting a FAITHFULLY-LABELED MOCK (explicitly NOT the engine):
--
--   * hash(s)        = a deterministic polynomial integer function of the string
--                     s. This mirrors the essential property of the engine's
--                     hash(): prefab_hash is a pure function of the name.
--   * prefab_name(h) = a reverse map seeded ONLY with the catalog's OWN ingot
--                     prefab names (ItemIronIngot, ItemCopperIngot, ...). Any
--                     hash not in that map is "unknown" (returns nil), exactly as
--                     the engine only knows real prefabs.
--
-- With that mock the result is honest and instructive:
--   * every one of the 17 INGOT reagents RESOLVES through its catalog bridge
--     (`ingots[].item`), and
--   * every NON-ingot reagent (food/liquid/gas, 29 of them) stays UNRESOLVED --
--     the catalog carries NO prefab-name bridge for them, which is precisely the
--     discovery this tool makes.
--
-- It is NOT a substitute for an in-engine run. Run the real discovery in-game,
-- where the genuine hash()/prefab_name() produce storage's actual prefab_hash;
-- this demo only proves the logic is wired correctly.
--
-- Run (from the repository root):
--   lua tests/test_reagent_name_hash_demo.lua

-- ============================ Load the catalog (offline) ============================
local Catalog
local chunk0, err0 = loadfile("PrinterCatalog.lua")
if not chunk0 then
    chunk0, err0 = loadfile("tests/PrinterCatalog.lua")
end
if not chunk0 then
    print("FATAL: cannot load PrinterCatalog (" .. tostring(err0) ..
        "); run this from the repository root, not tests/.")
    os.exit(2)
end
Catalog = assert(chunk0())

-- Load the manual name->item bridge too (best-effort); the mock "knows" only
-- the prefab names the map marks VERIFIED -- the honest, map-driven view.
local item_map = {}
local ok_im, im = pcall(require, "ReagentItemMap")
if ok_im and type(im) == "table" and type(im.reagents) == "table" then
    item_map = im.reagents
else
    local chunk_im = loadfile("ReagentItemMap.lua")
    if chunk_im then
        local okc, tbl = pcall(chunk_im)
        if okc and type(tbl) == "table" then
            item_map = tbl.reagents or {}
        end
    end
end

-- ============================ Faithful MOCK engine ============================
-- Deterministic polynomial string -> integer hash, pure Lua 5.1 (no bit ops).
-- A prime modulus keeps the running value finite for Lua's double numbers.
local HASH_PRIME = 4294967291 -- 2^32 - 15, a prime, bounds the accumulator
local function mock_hash(s)
    local h = 2166136261 -- FNV-1a 32-bit offset basis
    for i = 1, #s do
        h = (h * 16777619 + string.byte(s, i)) % HASH_PRIME
    end
    return h
end

-- Reverse map, seeded ONLY with the name->item bridge's VERIFIED prefab names
-- (equivalently the catalog ingot prefab names). Any unverified/unknown hash is
-- "not a known prefab" -- exactly the signal the discovery produces.
local prefab_lookup = {}
local collisions = 0
do
    local seeded_from = "catalog.ingots"
    local n_verified = 0
    for k, e in pairs(item_map) do
        if type(e) == "table" and e.verified and type(e.item) == "string" then
            local h = mock_hash(e.item)
            if prefab_lookup[h] ~= nil and prefab_lookup[h] ~= e.item then
                collisions = collisions + 1
            end
            prefab_lookup[h] = e.item
            n_verified = n_verified + 1
        end
    end
    seeded_from = "ReagentItemMap verified entries (" .. n_verified .. ")"
    -- If the map isn't present, fall back to seeding from the catalog ingots so
    -- the demo still exercises the bridge.
    if n_verified == 0 then
        for _, ing in pairs(Catalog.ingots or {}) do
            local item = type(ing) == "table" and ing.item or nil
            if type(item) == "string" then
                local h = mock_hash(item)
                if prefab_lookup[h] ~= nil and prefab_lookup[h] ~= item then
                    collisions = collisions + 1
                end
                prefab_lookup[h] = item
            end
        end
        seeded_from = "catalog.ingots (ReagentItemMap absent)"
    end
    print("--- demo mock prefab_name seeded from " .. seeded_from .. " ---")
end
local function mock_prefab_name(h)
    return prefab_lookup[h] -- nil for anything not a known/verified prefab
end

-- Inject the mock as the engine globals the discovery module probes.
_G.hash = mock_hash
_G.prefab_name = mock_prefab_name

-- ============================ Run the real discovery module ============================
-- The main module probes `type(hash)`/`type(prefab_name)` at load time, so with
-- the mock in place its ENGINE_OK flag is true and the engine path runs.
local main, merr = loadfile("tests/test_reagent_name_hash.lua")
if not main then
    main, merr = loadfile("test_reagent_name_hash.lua")
end
if not main then
    print("FATAL: cannot load tests/test_reagent_name_hash.lua (" ..
        tostring(merr) .. ")")
    os.exit(2)
end
local result = assert(main())

-- ============================ Verify the demo produced the expected shape ============================
local pass, fail = 0, 0
local function ok(cond, msg)
    if cond then
        pass = pass + 1
        print("PASS " .. msg)
    else
        fail = fail + 1
        print("FAIL " .. msg)
    end
end

ok(type(result) == "table", "the discovery module returned a result table")
ok(result.engine == true, "the module detected the (mock) engine as available")
ok(collisions == 0, "the mock prefab_name map has no hash collisions among ingots")

-- Every ingot reagent must resolve through its bridge (map-verified entry).
local summary = result.summary or {}
local n_ingots = 0
for _ in pairs(Catalog.ingots or {}) do
    n_ingots = n_ingots + 1
end
ok(summary.resolved == n_ingots,
    "all " .. n_ingots .. " ingot reagents resolved (summary.resolved = " ..
    tostring(summary.resolved) .. ", via map-verified = " ..
    tostring(summary.via_map_verified or 0) .. ")")
ok((summary.via_map_verified or 0) == n_ingots,
    "every resolution used the map's verified bridge (via_map_verified = " ..
    tostring(summary.via_map_verified or 0) .. ")")

-- Spot-check the flagship reagent the user raised: Iron.
local found_iron
for _, v in ipairs(result.reagents or {}) do
    if v.key == "Iron" then
        found_iron = v
    end
end
ok(found_iron ~= nil, "Iron is in the verdict set")
ok(found_iron and found_iron.verdict == "resolved", "Iron resolves (not unresolved)")
ok(found_iron and found_iron.prefab == Catalog.ingots.Iron.item,
    "Iron resolved to its bridged prefab name (ItemIronIngot)")
ok(found_iron and found_iron.source == "map:verified",
    "Iron resolved through the VERIFIED map entry, not its raw key")

-- The core proof: hash("Iron") (the raw catalog KEY) is NOT the prefab_hash of
-- the ingot. Different strings -> different hashes under the pure function.
ok(mock_hash("Iron") ~= mock_hash(Catalog.ingots.Iron.item),
    "hash('Iron') (key) ~= hash('ItemIronIngot') (prefab) -- the user's point")
ok(mock_prefab_name(mock_hash("Iron")) == nil,
    "prefab_name(hash('Iron')) is nil -- the key is not itself a prefab")

-- Non-ingot reagents stay unresolved (the honest catalog gap).
local unresolved_ingots = 0
for _, v in ipairs(result.reagents or {}) do
    if type(Catalog.ingots[v.key]) == "table" and v.verdict ~= "resolved" then
        unresolved_ingots = unresolved_ingots + 1
    end
end
ok(unresolved_ingots == 0,
    "no ingot reagent went unresolved (gap-free bridge)")
ok(summary.unresolved > 0,
    "some non-ingot reagents stay unresolved, as expected " ..
        "(summary.unresolved = " .. tostring(summary.unresolved) ..
        " -- not yet in the map, the discovery's real output)")

print(string.format(
    "\n=== reagent name->hash DEMO: %d passed, %d failed ===",
    pass, fail))
if fail == 0 then
    print("mock engine: " ..
        tostring(summary.resolved) .. " reagent(s) resolved via the verified map, " ..
        tostring(summary.unresolved) .. " unresolved (non-ingots) -- run in-game " ..
        "for the real prefab_hash values")
    os.exit(0)
else
    print(string.format("%d check(s) failed", fail))
    os.exit(1)
end
