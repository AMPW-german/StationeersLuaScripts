# AGENTS.md

## Verification

Requires a Lua 5.1 interpreter (`lua` on PATH). Run from the repository root:

```
lua tests\test_storage_controller_drain.lua
```

Exits 0 when all mocked regression tests pass. `lua -e "assert(loadfile('StorageController.lua'))"` checks syntax only.

## Printer suite

The catalog-free suites load `PrinterController`/`PrinterControlConsole` by splicing out the main loop and run under a mocked `ic`/`ss`/`yield` harness (no `ic.*` inside the controller, no `pcall` in the main path — Lua 5.1, no `bit`/`jit.vesper` required):

```
lua tests\test_printer_controller.lua        -- catalog-free surface; each request carries a validated cost_vector
lua tests\test_printer_persistence.lua        -- journal + durable snapshot survive a restart (no re-reserve)
lua tests\printer_recipe_test.lua            -- PrinterCatalog internal checks (588 recipes, 7 families)
lua tests\test_printer_console.lua           -- console talks ONLY to Printer.Controller RPC, never storage
lua tests\test_storage_controller_drain.lua  -- storage drain / routing
```

The controller is catalog-free: it has no `refresh_catalog`, `recipe_cost_vector`, `my_revision`, or `catalog_provider`, and carries no `working` recipe table. Each `printers_request` supplies a catalog-derived `cost_vector` (packed by the console), which the controller structurally validates (`valid_cost_vector`) before it touches the reservation ledger. `PrinterCatalog.lua` is an external `require`-able module (not embedded in the controller). `tools/generate_printer_catalog.py` regenerates `PrinterCatalog.lua` and `tests/printer_recipe_test.lua` from `modconfig.xml`.
