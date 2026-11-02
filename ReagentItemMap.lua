--@module ReagentItemMap
--@version 1
--@revision manual-2 -- HAND-MAINTAINED (not generated).
-- NOTE: --@module (two dashes) is the require() registration tag scanned by
-- the engine; ---@module (three dashes) does NOT register as a library chip.
-- The single, fillable bridge that translates a recipe reagent NAME into the
-- prefab (ITEM) NAME the engine's hash() / storage's prefab_hash expect.
--
-- WHY THIS EXISTS
--   PrinterCatalog.lua (a GENERATED, DO-NOT-EDIT catalog) keys reagent amounts by
--   the in-game / ENGLISH name -- "Iron", "Copper", "Gold", "Blue Coloring", ...
--   But the controller/storage speak prefab HASHES, and hash() takes a PREFAB
--   name (hash("ItemIronIngot"), NOT hash("Iron")). tests/test_reagent_name_hash.
--   lua proves this: the catalog reagent keys are display names, NOT prefab names;
--   17 ingots have a known prefab name (PrinterCatalog.ingots[].item) and the
--   other 29 (food/liquids/gases, dyes) have none in the catalog at all.
--
-- SEMANTICS -- a recipe reagent R is hashed as `item`, where:
--   VERIFIED entry   -> hash(entry.item)            (the correct prefab name)
--   missing / unverified -> hash(R)  + ONE warning   (the current, pre-bridge
--                      behaviour; fill `item` + set verified=true to correct it)
--   nothing guesses silently, and filling the map fixes the hash input WITHOUT a
--   restart (the console reads this table live on every submit).
--
-- FORM
--   ["<reagent name>"] = {
--       item     = "<prefab name to hash>",   -- the input to hash()
--       verified = true | false,              -- true = confirmed in-engine
--       display  = "<human label>",           -- UI/log only (never a key)
--       unit     = "g" | "ml" | "",
--   }
--
-- STATUS
--   * 17 INGOTS are VERIFIED -- taken straight from PrinterCatalog.ingots[].item.
--     The basic ingots and ressources almost never change, so this table is
--     stable: it does not churn with each catalog regeneration.
--   * 29 NON-INGOTS are identity STUBS (item == name, verified = false): a
--     visible placeholder for you to fill with the correct prefab name, confirmed
--     in-engine via tests/test_reagent_name_hash.lua. Until then they hash their
--     own raw name (the status quo), so nothing regresses -- you just correct
--     them one at a time.
--
-- The 3 deployable chips don't change: the controller is catalog-free and never
-- reads this; the console loads it via require("ReagentItemMap") at startup
-- (a missing/declining module degrades to "hash every raw name").
local ReagentItemMap = {
  api_version = 1,
  reagents = {
    -- ================= VERIFIED ingot bridges (PrinterCatalog.ingots[].item) =
    -- These 17 are authoritative: the catalog already knows their prefab name.
    ["Astroloy"]  = { item = "ItemAstroloyIngot",  verified = true,  display = "Astroloy",      unit = "g" },
    ["Constantan"]= { item = "ItemConstantanIngot", verified = true,  display = "Constantan",    unit = "g" },
    ["Copper"]    = { item = "ItemCopperIngot",     verified = true,  display = "Copper",        unit = "g" },
    ["Electrum"]  = { item = "ItemElectrumIngot",   verified = true,  display = "Electrum",      unit = "g" },
    ["Gold"]      = { item = "ItemGoldIngot",       verified = true,  display = "Gold",          unit = "g" },
    ["Hastelloy"] = { item = "ItemHastelloyIngot",  verified = true,  display = "Hastelloy",     unit = "g" },
    ["Inconel"]   = { item = "ItemInconelIngot",    verified = true,  display = "Inconel",       unit = "g" },
    ["Invar"]     = { item = "ItemInvarIngot",      verified = true,  display = "Invar",         unit = "g" },
    ["Iron"]      = { item = "ItemIronIngot",       verified = true,  display = "Iron",          unit = "g" },
    ["Lead"]      = { item = "ItemLeadIngot",       verified = true,  display = "Lead",          unit = "g" },
    ["Nickel"]    = { item = "ItemNickelIngot",     verified = true,  display = "Nickel",        unit = "g" },
    ["Silicon"]   = { item = "ItemSiliconIngot",    verified = true,  display = "Silicon",       unit = "g" },
    ["Silver"]    = { item = "ItemSilverIngot",     verified = true,  display = "Silver",        unit = "g" },
    ["Solder"]    = { item = "ItemSolderIngot",     verified = true,  display = "Solder",        unit = "g" },
    ["Steel"]     = { item = "ItemSteelIngot",      verified = true,  display = "Steel",         unit = "g" },
    ["Stellite"]  = { item = "ItemStelliteIngot",   verified = true,  display = "Stellite",      unit = "g" },
    ["Waspaloy"]  = { item = "ItemWaspaloyIngot",   verified = true,  display = "Waspaloy",      unit = "g" },

    -- ================= UNVERIFIED non-ingot stubs (FILL IN the prefab name) ====
    -- `item` currently == the raw name (a placeholder, verified=false) so the
    -- chip keeps the old behaviour. Find the real prefab name with
    -- tests/test_reagent_name_hash.lua (run it in-engine), set `item` to it, and
    -- flip `verified = true`. The stub list is the full non-ingot universe.
    ["Alcohol"]       = { item = "Alcohol",     verified = false, display = "Alcohol",       unit = "ml" }, -- TODO
    ["Biomass"]       = { item = "Biomass",     verified = false, display = "Biomass",       unit = ""  }, -- TODO
    ["Carbon"]        = { item = "Carbon",      verified = false, display = "Carbon",        unit = "g" }, -- TODO
    ["Cheese"]        = { item = "Cheese",      verified = false, display = "Cheese",        unit = "g" }, -- TODO
    ["Cobalt"]        = { item = "Cobalt",      verified = false, display = "Cobalt",        unit = "g" }, -- TODO
    ["Cocoa"]         = { item = "Cocoa",       verified = false, display = "Cocoa",         unit = "g" }, -- TODO
    ["ColorBlue"]     = { item = "ColorBlue",   verified = false, display = "Blue Coloring",   unit = "g" }, -- TODO
    ["ColorGreen"]    = { item = "ColorGreen",  verified = false, display = "Green Coloring",  unit = "g" }, -- TODO
    ["ColorOrange"]   = { item = "ColorOrange", verified = false, display = "Orange Coloring", unit = "g" }, -- TODO
    ["ColorRed"]      = { item = "ColorRed",    verified = false, display = "Red Coloring",    unit = "g" }, -- TODO
    ["ColorYellow"]   = { item = "ColorYellow", verified = false, display = "Yellow Coloring", unit = "g" }, -- TODO
    ["Corn"]          = { item = "Corn",        verified = false, display = "Corn",          unit = ""  }, -- TODO
    ["Egg"]           = { item = "Egg",         verified = false, display = "Egg",           unit = ""  }, -- TODO
    ["Fenoxitone"]    = { item = "Fenoxitone",  verified = false, display = "Fenoxitone",    unit = "g" }, -- TODO
    ["Flour"]         = { item = "Flour",       verified = false, display = "Flour",         unit = "g" }, -- TODO
    ["Hydrocarbon"]   = { item = "Hydrocarbon", verified = false, display = "Hydrocarbon",   unit = "g" }, -- TODO
    ["Milk"]          = { item = "Milk",        verified = false, display = "Milk",          unit = "ml" }, -- TODO
    ["Mushroom"]      = { item = "Mushroom",    verified = false, display = "Mushroom",      unit = "g" }, -- TODO
    ["Oil"]           = { item = "Oil",         verified = false, display = "Oil",           unit = "ml" }, -- TODO
    ["Plastic"]       = { item = "Plastic",     verified = false, display = "Plastic",       unit = "g" }, -- TODO
    ["Potato"]        = { item = "Potato",      verified = false, display = "Potato",        unit = ""  }, -- TODO
    ["Pumpkin"]       = { item = "Pumpkin",     verified = false, display = "Pumpkin",       unit = ""  }, -- TODO
    ["Rice"]          = { item = "Rice",        verified = false, display = "Rice",          unit = "g" }, -- TODO
    ["SalicylicAcid"] = { item = "SalicylicAcid", verified = false, display = "Salicylic Acid", unit = "g" }, -- TODO
    ["Soy"]           = { item = "Soy",         verified = false, display = "Soy",           unit = ""  }, -- TODO
    ["Sugar"]         = { item = "Sugar",       verified = false, display = "Sugar",         unit = "g" }, -- TODO
    ["Tomato"]        = { item = "Tomato",      verified = false, display = "Tomato",        unit = ""  }, -- TODO
    ["Uranium"]       = { item = "Uranium",     verified = false, display = "Uranium",       unit = "g" }, -- TODO
    ["Wheat"]         = { item = "Wheat",       verified = false, display = "Wheat",         unit = ""  }, -- TODO
  },
}

return ReagentItemMap
