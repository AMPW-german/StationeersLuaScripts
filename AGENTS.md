# AGENTS.md

## Verification

Requires a Lua 5.1 interpreter (`lua` on PATH). Run from the repository root:

```
lua tests\test_storage_controller_drain.lua
```

Exits 0 when all mocked regression tests pass. `lua -e "assert(loadfile('StorageController.lua'))"` checks syntax only.

## Printer suite

The catalog-free suites load `PrinterController`/`PrinterControlConsole` by splicing out the main loop and run under a mocked `ic`/`ss`/`yield` harness (no `ic.*` inside the *controller body*; Lua 5.1, no `bit`/`jit.vesper` required):

```
lua tests\test_printer_controller.lua        -- catalog-free surface; each request carries a validated cost_vector
lua tests\test_printer_persistence.lua        -- journal + durable snapshot survive a restart (no re-reserve)
lua tests\printer_recipe_test.lua            -- PrinterCatalog internal checks (588 recipes, 7 families)
lua tests\test_printer_console.lua           -- console talks ONLY to Printer.Controller RPC, never storage
lua tests\test_storage_controller_drain.lua  -- storage drain / routing
lua tests\test_reagent_name_hash.lua         -- DISCOVERY: name->prefab_hash bridge (run in-engine; offline = structural only)
lua tests\test_reagent_name_hash_demo.lua    -- offline mock proof of the discovery logic (no engine)
```

### Catalog-free contract

The controller is catalog-free: it has no `refresh_catalog`, `recipe_cost_vector`, `my_revision`, or `catalog_provider`, and carries no `working` recipe table. Each `printers_request` supplies a catalog-derived `cost_vector` (packed by the console), which the controller structurally validates (`valid_cost_vector`) *before* it touches the reservation ledger. `PrinterCatalog.lua` is an external `require`-able module (not embedded in the controller). `tools/generate_printer_catalog.py` regenerates `PrinterCatalog.lua` and `tests/printer_recipe_test.lua` from `modconfig.xml`.

The console owns the recipe knowledge: it packs a **per-single-item, hash-keyed** `cost_vector` (`prefab_hash → grams` for ONE item, zeros stripped) plus an `item`/`recipe` name label and a `count`, and the controller does the aggregation (`per-item × count`, one `storage.request` **per reagent hash**, one task at a time). **Internally the chips speak prefab HASHES, not reagent names.**

**The catalog reagent KEYS are english/display names, NOT prefab names** — `hash("Iron")` is *not* storage's `prefab_hash` of `"ItemIronIngot"` (proven by `tests/test_reagent_name_hash.lua`: 17 ingot reagents carry a known prefab name; the other 29 food/liquid/gas/dye reagents carry none in the catalog at all). So the catalog supplies reagent *names only* (by design it never stores hashes, and the hash algorithm is never guessed), and the console resolves a name to a `prefab_hash` in **two steps**:

1. **name → prefab/ITEM name** via the hand-maintained `ReagentItemMap.lua` bridge (`resolve_item_name`, reading `state.reagent_item_map`): a **verified** entry supplies its `item` prefab name; a **missing or unverified** entry falls back to the **raw catalog name** and logs one `reagent_unverified`/`reagent_no_mapping` warning (so nothing guesses silently and filling the map fixes the hash *without a restart*). The 17 ingots are pre-verified (taken from `PrinterCatalog.ingots[].item`); the 29 non-ingots ship as `item == key`, `verified = false` stubs the operator fills in.
2. **prefab name → hash** via the engine's `Animator.StringToHash`/IC10 `HASH()` (`resolve_prefab_hash`, pcall-guarded — a name it cannot hash logs and refuses the submit rather than emitting a half-resolved vector or crashing).

A parallel `reagent_labels` table (`hash → display name`) carries the human name *for UI/logs only*, produced by one centralized `display_name` converter (mirroring the storage console's `item_name`; for now it only strips the leading `Item` token, e.g. `ItemCopperIngot → CopperIngot`) — names never become a controller/storage key. `ReagentItemMap.lua` is a passive, hand-editable companion to the generated catalog (the basic ingots/ressources rarely change, so it does not churn with each regeneration). The controller's `valid_cost_vector` accepts **both** name- and hash-keyed vectors, and 1 gram == 1 item, so a reagent's `storage.request` quantity is `ceil(aggregate_grams)`. New recipes are a redeploy of ONLY `PrinterCatalog.lua`; a corrected reagent hash is a redeploy of ONLY `ReagentItemMap.lua` — the controller and consoles need no restart.

### Guarded I/O boundary (exception to the no-`pcall` convention)

The old "no `pcall` in the main path" convention is **overridden for the external-I/O boundary** by the adopted crash model ("guard I/O + per-task isolation + pre-send flush"). Every call to an external device in the controller is captured so a hostile payload or a missing/declining device can never halt or corrupt the chip:

* every RPC handler is wrapped in `guarded()` — a thrown handler is logged and returns a controlled `handler_error`;
* `transition()` **journals + checkpoints first, then** the guarded `ic.net.publish` — a send failure is logged and the transition is durable;
* `service_tasks()` serves each task inside a `pcall` (per-task isolation): one bad task is parked `FAILED`, logged, and cannot skip the end-of-tick `checkpoint()` or abort the rest of the queue;
* the whole tick loop is guarded as a last line of defense;
* a reached task requests the aggregated quantity from the storage line once (`request_storage_reservation`), guarded and **journaled before the send** so a halt recovers it without re-aggregating;
* a structurally invalid recipe is **logged** (`add_error`) and the controller **continues** serving the rest of the queue. The in-memory error log is capped (`ERRORS_MAX`) so a hostile caller cannot grow it unbounded.

Consoles never crash: they guard their own RPC calls and surface the controller's error code to the operator.
