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
```

### Catalog-free contract

The controller is catalog-free: it has no `refresh_catalog`, `recipe_cost_vector`, `my_revision`, or `catalog_provider`, and carries no `working` recipe table. Each `printers_request` supplies a catalog-derived `cost_vector` (packed by the console), which the controller structurally validates (`valid_cost_vector`) *before* it touches the reservation ledger. `PrinterCatalog.lua` is an external `require`-able module (not embedded in the controller). `tools/generate_printer_catalog.py` regenerates `PrinterCatalog.lua` and `tests/printer_recipe_test.lua` from `modconfig.xml`.

The console owns the recipe knowledge: it packs a **per-single-item** `cost_vector` (reagent → grams for ONE item, zeros stripped) plus an `item` name and a `count`, and the controller does the aggregation (`per-item × count` into one storage request, one per reached task). New recipes are a redeploy of ONLY `PrinterCatalog.lua`; the controller and consoles need no restart to pick them up.

### Guarded I/O boundary (exception to the no-`pcall` convention)

The old "no `pcall` in the main path" convention is **overridden for the external-I/O boundary** by the adopted crash model ("guard I/O + per-task isolation + pre-send flush"). Every call to an external device in the controller is captured so a hostile payload or a missing/declining device can never halt or corrupt the chip:

* every RPC handler is wrapped in `guarded()` — a thrown handler is logged and returns a controlled `handler_error`;
* `transition()` **journals + checkpoints first, then** the guarded `ic.net.publish` — a send failure is logged and the transition is durable;
* `service_tasks()` serves each task inside a `pcall` (per-task isolation): one bad task is parked `FAILED`, logged, and cannot skip the end-of-tick `checkpoint()` or abort the rest of the queue;
* the whole tick loop is guarded as a last line of defense;
* a reached task requests the aggregated quantity from the storage line once (`request_storage_reservation`), guarded and **journaled before the send** so a halt recovers it without re-aggregating;
* a structurally invalid recipe is **logged** (`add_error`) and the controller **continues** serving the rest of the queue. The in-memory error log is capped (`ERRORS_MAX`) so a hostile caller cannot grow it unbounded.

Consoles never crash: they guard their own RPC calls and surface the controller's error code to the operator.
