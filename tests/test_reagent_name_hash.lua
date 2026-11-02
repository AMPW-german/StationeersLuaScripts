-- tests/test_reagent_name_hash.lua
-- Lua 5.1. NOT part of the printer regression suites -- it is a DISCOVERY/PROOF
-- harness for the name -> prefab_hash conversion the console performs at pack
-- time (resolve_prefab_hash: prefab_hash = hash(prefab_name)).
--
-- The finding it locks: the catalog stores reagent KEYS that are internal /
-- display names, NOT prefab names. `hash("Iron")` is therefore NOT storage's
-- `prefab_hash`; the prefab name must be resolved first. The catalog carries the
-- correct prefab name for INGOT reagents in its `ingots` table
-- (Iron -> "ItemIronIngot", Copper -> "ItemCopperIngot", ...), but most other
-- reagents (food, liquids, gases) have NO bridge in the catalog at all.
--
-- What this script does, for every reagent in the universe:
--   1. picks the best prefab-name CANDIDATE (ingots[].item wins; else the raw
--      key, then common forms "Item"+k, k+"Ingot", "Item"+k+"Ingot");
--   2. in-engine (hash + prefab_name present) VERIFIES each candidate by
--      round-trip -- prefab_name(hash(candidate)) == candidate -- and prints a
--      per-reagent verdict (resolved / unresolved + which source/form);
--   3. offline (Lua 5.1 sandbox, engine globals absent) runs only the structural
--      part and clearly flags the verdicts as "run in-game to resolve".
--
-- Usage:
--   in-engine (a chip/console):   require("tests/test_reagent_name_hash")
--   offline / CI sanity:          lua tests/test_reagent_name_hash.lua
--
-- Exit status (offline run): 0 when the structural invariants hold; the
-- unresolved in-game count is a WARNING, not a hard failure (non-ingot reagents
-- legitimately lack a catalog bridge and are the discovery's real output).

-- ============================ Load the catalog ============================
-- In-engine it is require-able; offline load it as a chunk from the repo root
-- (the suites are always invoked from the repository root).
local Catalog
local loaded, lerr = pcall(require, "PrinterCatalog")
if loaded and type(Catalog) == "table" then
    -- require() present and succeeded.
else
    local chunk
    chunk, lerr = loadfile("PrinterCatalog.lua")
    if not chunk then
        chunk, lerr = loadfile("tests/PrinterCatalog.lua") -- CWD = tests/ fallback
    end
    if not chunk then
        print("FATAL: cannot load PrinterCatalog (" .. tostring(lerr) ..
            "); run from the repository root, not tests/.")
        os.exit(2)
    end
    Catalog = assert(chunk())
end

-- Also load the manual name->item bridge (the single fillable place that maps a
-- reagent name to the prefab/ITEM name hash() expects). Absent in a fresh repo:
-- best-effort, degrades to "no map" (the test then falls back to the catalog
-- ingots bridge, then raw key -- current behaviour). Loaded the same guarded way
-- the console's loader is, so the test mirrors the console exactly.
local map_loaded = false
local map_reagents = {}
do
    local ok_rim, rim = pcall(require, "ReagentItemMap")
    if ok_rim and type(rim) == "table" and type(rim.reagents) == "table" then
        map_reagents, map_loaded = rim.reagents, true
    else
        local chunk, lerr = loadfile("ReagentItemMap.lua")
        if not chunk then
            chunk, lerr = loadfile("tests/ReagentItemMap.lua") -- CWD = tests/ fallback
        end
        if chunk then
            local ok_call, tbl = pcall(chunk)
            if ok_call and type(tbl) == "table" and type(tbl.reagents) == "table" then
                map_reagents, map_loaded = tbl.reagents, true
            end
        end
    end
end

-- ============================ Test harness ============================
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

-- ============================ Engine availability ============================
-- In the game these are top-level functions; in the Lua 5.1 sandbox they are
-- nil. Guard every engine call in pcall so the script never errors on a chip
-- that lacks one (mirrors the console's guarded resolve_prefab_hash).
local ENGINE_OK = (type(hash) == "function") and (type(prefab_name) == "function")
local safe_hash, safe_prefab_name
if ENGINE_OK then
    safe_hash = function(s)
        local okc, h = pcall(hash, s)
        if not okc or type(h) ~= "number" then
            return nil
        end
        return h
    end
    safe_prefab_name = function(h)
        local okc, n = pcall(prefab_name, h)
        if not okc then
            return nil
        end
        return n -- may be nil/absent
    end
else
    safe_hash = function() return nil end
    safe_prefab_name = function() return nil end
end

-- A guarded round-trip: candidate c "verifies" iff prefab_name(hash(c)) == c.
local function round_trips(c)
    local h = safe_hash(c)
    if not h then
        return false, nil
    end
    return safe_prefab_name(h) == c, h
end

-- ============================ Enumerate the reagent universe ============================
-- The universe is the union of:
--   * catalog.reagents keys (key -> {name=<display>, unit=...}) -- ALL materials
--   * catalog.ingots  keys (key -> {item=<prefab name>, amount}) -- ingot bridge
--   * any reagent key seen in a family recipe's `reagents` map (defensive)
local catalog_reagents  = Catalog.reagents  or {}
local catalog_ingots    = Catalog.ingots    or {}

local present = {}         -- key -> true, the full universe
for k in pairs(catalog_reagents) do
    present[k] = true
end
for k in pairs(catalog_ingots) do
    present[k] = true
end
local families = Catalog.families
if type(families) == "table" then
    for _, fam in pairs(families) do
        if type(fam) == "table" then
            for _, recipe in pairs(fam) do
                if type(recipe) == "table" and type(recipe.reagents) == "table" then
                    for rk in pairs(recipe.reagents) do
                        present[rk] = true
                    end
                end
            end
        end
    end
end
local reagent_keys = {}
for k in pairs(present) do
    reagent_keys[#reagent_keys + 1] = k
end
table.sort(reagent_keys) -- deterministic, alphabetical

-- Display-name lookup: catalog.reagents[k].name (the human label), else the key.
local function display_for(k)
    local r = catalog_reagents[k]
    if type(r) == "table" and type(r.name) == "string" then
        return r.name
    end
    return k
end

-- Best prefab-name candidate order for a reagent key, mirroring the console's
-- resolve_item_name (map VERIFIED item, else raw key) with discovery forms after:
--   map:verified   -- the map's filled-in prefab name, confirmed (highest trust);
--   catalog:ingots -- the catalog's ingot bridge (same as a verified map entry);
--   raw_key        -- the raw catalog name == the console's FALLBACK when the
--                     map is missing/UNVERIFIED (the current pre-bridge behaviour);
--   forms          -- "Item"+k, k+"Ingot", "Item"+k+"Ingot" -- discovery
--                     suggestions for a reagent still awaiting a map entry.
-- Deduplicated, first that round-trips wins.
local function candidates_for(k)
    local seen = {}
    local out = {}
    local function add(name, source)
        if name and not seen[name] then
            seen[name] = true
            out[#out + 1] = { name = name, source = source }
        end
    end
    local mentry = map_reagents[k]
    if type(mentry) == "table" and type(mentry.item) == "string" and mentry.verified ~= false then
        add(mentry.item, "map:verified")
    end
    local ing = catalog_ingots[k]
    if type(ing) == "table" and type(ing.item) == "string" then
        add(ing.item, "catalog:ingots")
    end
    if type(k) == "string" then
        add(k, "raw_key")
        add("Item" .. k, "form:Item+k")
        add(k .. "Ingot", "form:k+Ingot")
        add("Item" .. k .. "Ingot", "form:Item+k+Ingot")
    end
    return out
end

-- ============================ Structural invariants (always run) ============================
ok(type(Catalog) == "table", "catalog loaded as a table")
ok(type(catalog_reagents) == "table" and next(catalog_reagents) ~= nil,
    "catalog.reagents is a populated table")
ok(type(catalog_ingots) == "table" and next(catalog_ingots) ~= nil,
    "catalog.ingots is a populated table (the ingot prefab-name bridge)")
ok(#reagent_keys > 0, "the reagent universe was enumerated (n=" .. #reagent_keys .. ")")

-- Every ingot bridge must give a prefab-name-looking item ("Item" prefix).
local ingot_bridge_ok = 0
local ingot_bridge_bad = 0
for k, ing in pairs(catalog_ingots) do
    local item = type(ing) == "table" and ing.item or nil
    if type(item) == "string" and item:sub(1, 4) == "Item" then
        ingot_bridge_ok = ingot_bridge_ok + 1
    else
        ingot_bridge_bad = ingot_bridge_bad + 1
    end
end
ok(ingot_bridge_bad == 0,
    "every ingot bridge has an 'Item*' prefab name (" .. ingot_bridge_ok .. " ok, " ..
    ingot_bridge_bad .. " bad)")

-- `catalog_ingots` is a NAME-KEYED hash table, so Lua's length operator `#`
-- is undefined on it -- count it with pairs (the total number of ingot reagents).
local n_catalog_ingots = 0
for _ in pairs(catalog_ingots) do
    n_catalog_ingots = n_catalog_ingots + 1
end

-- Prove the user's point structurally: for an ingot reAGENT whose catalog KEY is
-- NOT already a prefab name, the raw key and the bridged prefab name differ.
-- (Offline-safe: pure string comparison, no engine call.)
local proven = 0
if catalog_ingots.Iron and type(catalog_ingots.Iron.item) == "string" then
    if catalog_ingots.Iron.item ~= "Iron" then
        proven = proven + 1
    end
end
ok(proven >= 1,
    "proven: an ingot reagent key ('Iron') is NOT its own prefab name (" ..
    tostring(catalog_ingots.Iron and catalog_ingots.Iron.item) .. ")")

-- ============================ Map structural invariants ============================
-- If ReagentItemMap is loaded, check its shape: every VERIFIED entry names an
-- 'Item*' prefab, the map covers the catalog's ingot reagents, and UNVERIFIED
-- stubs carry item==key (a placeholder, not yet filled).
if map_loaded then
    local n_map, n_verified, n_stub = 0, 0, 0
    local bad_verified, bad_stub = 0, 0
    for k, e in pairs(map_reagents) do
        n_map = n_map + 1
        local is_table = type(e) == "table"
        local item = is_table and e.item or nil
        if is_table and e.verified then
            n_verified = n_verified + 1
            if type(item) ~= "string" or item:sub(1, 4) ~= "Item" then
                bad_verified = bad_verified + 1
            end
        elseif is_table then
            n_stub = n_stub + 1
            if item ~= k then
                bad_stub = bad_stub + 1
            end
        end
    end
    -- coverage: every catalog ingot reagent must have a map entry.
    local ingot_unmapped = 0
    for k, ing in pairs(catalog_ingots) do
        if map_reagents[k] == nil then
            ingot_unmapped = ingot_unmapped + 1
        end
    end
    ok(n_verified == n_catalog_ingots,
        "the map's VERIFIED entries cover all " .. n_catalog_ingots ..
        " catalog ingots (got " .. n_verified .. ")")
    ok(bad_verified == 0,
        "every verified map entry names an 'Item*' prefab (" .. bad_verified .. " bad)")
    ok(bad_stub == 0,
        "every unverified stub keeps item==key as a placeholder (" .. bad_stub .. " altered)")
    ok(ingot_unmapped == 0,
        "every catalog ingot reagent has a map entry (" .. ingot_unmapped .. " missing)")
    print(string.format("--- ReagentItemMap structural check: %d entries, %d verified, %d stubs ---",
        n_map, n_verified, n_stub))
end

-- ============================ Per-reagent verdict ============================
print(string.format(
    "\n--- %d reagent(s) in the universe; ENGINE %s ---",
    #reagent_keys,
    ENGINE_OK and "AVAILABLE (hash + prefab_name bound)" or "NOT available (offline; verdicts pending in-game run)"))

local resolved, unresolved, via_map, via_catalog, via_form, via_hash_key = 0, 0, 0, 0, 0, 0
local verdicts = {}
for _, k in ipairs(reagent_keys) do
    local cands = candidates_for(k)
    local picked, source, h
    for _, cand in ipairs(cands) do
        local rt, h2 = round_trips(cand.name)
        if rt then
            picked, source, h = cand.name, cand.source, h2
            break
        end
    end
    local verdict
    if picked then
        verdict = "resolved"
        resolved = resolved + 1
        if source == "map:verified" then
            via_map = via_map + 1
        elseif source == "catalog:ingots" then
            via_catalog = via_catalog + 1
        elseif string.sub(source or "", 1, 4) == "form" then
            via_form = via_form + 1
        end
        if source == "raw_key" and type(k) == "string" then
            via_hash_key = via_hash_key + 1
        end
    else
        verdict = "unresolved"
        unresolved = unresolved + 1
    end
    local mentry = map_reagents[k]
    local map_state
    if type(mentry) == "table" then
        map_state = (mentry.verified and "verified") or "stub(unverified)"
    else
        map_state = "absent"
    end
    verdicts[#verdicts + 1] = {
        key = k, display = display_for(k),
        unit = type(catalog_reagents[k]) == "table" and catalog_reagents[k].unit or "?",
        ingot = (catalog_ingots[k] ~= nil),
        verdict = verdict, source = source or "-",
        prefab = picked or "-",
        hash = h or "-",
        map = map_state,
        map_item = type(mentry) == "table" and mentry.item or nil,
    }
end

-- Deterministic, alphabetical dump.
print(string.rep("=", 118))
print(string.format("%-16s %-20s %-4s %-7s %-10s %-9s %-18s %s",
    "reagentKey", "display", "unit", "ingot", "verdict", "map", "prefabName(candidate)", "hash"))
for _, v in ipairs(verdicts) do
    local h = v.hash
    local hs
    if type(h) == "number" then
        hs = h
    else
        hs = tostring(h)
    end
    print(string.format("%-16s %-20s %-4s %-7s %-10s %-9s %-18s %s",
        v.key,
        string.sub(tostring(v.display), 1, 20),
        tostring(v.unit) or "?",
        v.ingot and "yes" or "no",
        v.verdict,
        tostring(v.map),
        string.sub(tostring(v.prefab), 1, 18),
        hs))
end
print(string.rep("=", 118))
print(string.format(
    "RESOLVED %d / %d (map:verified %d, catalog ingot bridge %d, raw key %d, form %d)   UNRESOLVED %d",
    resolved, #reagent_keys, via_map, via_catalog, via_hash_key, via_form, unresolved))
if map_loaded then
    local n_map = 0
    for _ in pairs(map_reagents) do
        n_map = n_map + 1
    end
    print(string.format("ReagentItemMap loaded: %d entry(ies) -- fill the 'stub(unverified)' rows' `item` + set verified=true.",
        n_map))
else
    print("ReagentItemMap NOT loaded -- resolution used the catalog ingot bridge / raw key only.")
end

-- ============================ Engine-specific assertions ============================
if ENGINE_OK then
    -- In-game, EVERY ingot reagent must resolve through a bridge (the map's
    -- verified entry, else the catalog ingots bridge) -- NOT its raw key.
    local ingot_resolved_ok = 0
    local ingot_via_bridge = 0
    local ingot_via_rawkey = 0
    local ingot_resolved_bad = 0
    for _, v in ipairs(verdicts) do
        if v.ingot then
            if v.verdict == "resolved" then
                ingot_resolved_ok = ingot_resolved_ok + 1
                if v.source == "map:verified" or v.source == "catalog:ingots" then
                    ingot_via_bridge = ingot_via_bridge + 1
                else
                    ingot_via_rawkey = ingot_via_rawkey + 1
                end
            else
                ingot_resolved_bad = ingot_resolved_bad + 1
            end
        end
    end
    ok(ingot_resolved_ok == n_catalog_ingots and ingot_resolved_bad == 0,
        "every ingot reagent resolves to a verified prefab_hash via its catalog/map bridge")
    ok(ingot_via_rawkey == 0,
        "no ingot reagent resolved via its raw key -- the bridge wins (" ..
        ingot_via_rawkey .. " raw-key, " .. ingot_via_bridge .. " via bridge)")

    -- The core proof: the raw catalog KEY does NOT itself hash to the prefab --
    -- the bridged prefab name does, and they differ. (Iron: key vs ItemIronIngot.)
    if catalog_ingots.Iron then
        local key_rt, key_h = round_trips("Iron")
        local br_h = safe_hash(catalog_ingots.Iron.item)
        ok((key_h == nil or key_h ~= br_h) and br_h ~= nil,
            "hash('Iron') (catalog key) is NOT storage's prefab_hash of 'ItemIronIngot'")
    end
else
    -- Offline: the engine-dependent verdicts cannot be asserted; report the
    -- pending count so the operator knows what awaits an in-game run.
    print("--- offline: " .. #reagent_keys ..
        " verdict(s) pending an in-game run; structural checks passed ---")
    print("--- to resolve names -> prefab_hash, run this script in-engine where hash()/prefab_name() are bound ---")
end

-- ============================ Exit / result ============================
-- Standalone offline run: a structural invariant failure is a hard error (exit 1).
-- Never exit in-engine -- a chip that require()s this consumes the returned table;
-- failing here would kill the chip. In the clean offline case the final return is
-- the main chunk's last statement, so the process exits 0 naturally.
if not ENGINE_OK and fail > 0 then
    os.exit(1)
end

-- ============================ Machine-readable result ============================
-- Returned so a chip can consume the discovery table directly.
return {
    engine = ENGINE_OK,
    catalog_revision = Catalog.revision,
    reagents = verdicts,
    summary = {
        total = #reagent_keys,
        resolved = resolved,
        unresolved = unresolved,
        via_map_verified = via_map,
        via_catalog_bridge = via_catalog,
        via_raw_key = via_hash_key,
        via_form = via_form,
        map_loaded = map_loaded,
    },
}
