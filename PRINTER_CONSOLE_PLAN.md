# Printer Console Plan (paged UI redesign + controller completion)

## Purpose
Rebuild `PrinterControlConsole.lua` as a multi-page ScriptedScreens UI (main /
per-printer / recipe-list / task-queue pages), fix the backend defects it
depends on, and FINISH the printer controller: its actuation path is currently
mock scaffolding behind a never-enabled commission gate, so tasks complete via
simulated transitions without driving a real printer. Assumes ONE physical
printer per family (family == printer). RPC isolation is kept: the console
talks only `printers.*` to `LuaC.Printer.Controller`; storage inventory reaches
the console ONLY as relayed by the printer controller. The system is local-only
and unused — breaking API changes are allowed and legacy aliases/compat paths
get REMOVED, not shimmed (API_VERSION bumps to 2).

## Defects to fix (verified)
- `PrinterControlConsole.lua` uses `type = "text"` elements (not a documented ss
  type; should be `"label"`), never calls `s:commit()`, renders the task list
  once with `tasks[1] or {}` (an empty task is non-terminal, so a ghost CANCEL
  button appears), and reads fields the controller never emits (`task.recipe`,
  `task.total_quantity`, `task.print_progress`, state `"PRINTING"` vs the real
  lowercase states + `item`/`count`). All rect math is absolute px — the request
  bar overlaps other elements on the real screen size.
- `PrinterController.lua`: `printers_request` reads `payload.family_id or 1` and
  never looks at `family_name`; `FAMILY_ID` (name->id map, ~line 212) is defined
  but unused. **Every request currently routes to autolathe (family 1).**
- `tools/generate_printer_catalog.py`: `Time`/`Energy` are children of
  `<Recipe>`, but `parse_recipe_data` reads `node.find("Time")` at `<RecipeData>`
  level — all 588 recipes emit `time = nil, energy = nil`.
- The `ingots` support family renders as a 7th printer button; it is not a
  printable family and must be excluded from all printer pickers/filters.
- Actuation: `start_print` returns `not_commissioned` (`native_enabled` and
  `native_commissioned` are both false and nothing enables them). The
  `program_for_recipe`/`make_packed_word` memory-word layout is invented,
  mock-validated scaffolding — printers are driven by LogicType writes, not a
  memory program. See "Native actuation".
- Boot: the controller leaves all controlled devices (printers, feed sorters)
  in whatever state they were left — it must park them into a known state on
  start, the way StorageController does.
- `printers_cancel` returns `already_active` for active tasks; requirement is
  to allow it (see "Cancel + ejection").

## API v2 (breaking — no legacy compatibility)

Removed:
- `printers.request_status` endpoint entirely (overlay uses get_state tasks).
- `task_id_filter` param on `printers.get_state`.
- Request-payload legacy aliases: `recipe`, `quantity`, `printer_ref`. Canonical
  fields: `client_request_id`, `family_name`, `item`, `cost_vector`,
  `reagent_labels`, `count`, `destination_id`, `api_version`.
- `tier` everywhere: not sent (all printers fully upgraded), not stored on the
  task, `PARAM_TIER` and the whole memory-program scaffolding deleted.

`printers.get_state` response gains:
- `printers` — one record per family: `{family_id, family_name, prefab_hash,
  ref_id, status, active_task_id}`; `status` is controller-computed (single
  source of truth) ∈ `idle | printing | waiting_resources | ejecting | absent`.
- `time_multiplier` — the PRINT_TIME_MULTIPLIER user config.
- `recent_errors` — tail of the controller error log (code + tick, ~last 3),
  for the on-screen error line.
- `tasks` records (final schema, no aliases): `task_id`, `family_name`,
  `family_id`, `item` (prefab name), `count`, `done_count`, `state`,
  `cost_vector`, `reagent_labels`, `resources_state` ∈ `pending | delivered |
  failed`, `created_tick`, `updated_tick`, `error_code`, `printer_ref`.

New RPC `printers.get_inventory {}` → `{api_version, ok, revision, inventory}`:
- The controller forwards one `storage.get_state {include_groups=true}` through
  the guarded `safe_request`, compacts groups to `{prefab_hash -> {quantity,
  available}}`, caches it, and re-queries storage AT MOST every 2 s (returns
  the cached copy inside the window). No background polling.
- The console calls it ONLY when the recipe page is open (on entry + refresh
  while open); the default/main view never requests it.
- On `ok=false`/unreachable storage: max-buildable renders "--", reagents
  uncolored; recipes remain submittable.

`printers.request`: controller resolves `family_id or
FAMILY_ID[payload.family_name] or 1` (the routing fix). `printers.cancel`: now
accepts `queued`, `paused`, AND `active`.

## Native actuation (finishing the controller)
Replace the invented memory-program with real LogicType drives (all confirmed
to exist in vanilla `LogicType`; exact per-printer semantics verified in-game
FIRST — a probe checklist writes/reads one printer before the driver ships):
- Select recipe: `write_id(printer, RecipeHash, hash(item_prefab_name))`.
- Run: `write_id(printer, Activate, 1)`; stop: `Activate = 0`.
- Progress: `CompletionRatio` (current item 0..1); `ExportCount` /
  `ExportQuantity`/`ExportSlotHash` for items completed → real `done_count`;
  `ImportQuantity`/`ImportSlotOccupant`/`ImportSlotHash` for feed state;
  `Idle`, `Error` for printer status.
- Task lifecycle becomes: QUEUED → request storage (existing aggregate path) →
  ACTIVE while reagent delivery/producing runs → COMPLETED when done_count ==
  count and output collected. `awaiting_output`/`output_done` remain as the
  output-collection tail.
- Waiting-for-resources = a reached task whose storage request is still in
  flight or failed → `waiting_resources` printer status (today storage failures
  are only logged; surface `resources_state` on the task).
- `PRINT_TIME_MULTIPLIER` user config feeds the console's ETA math.

## Boot known-state
New `initialize_devices()` after discovery, mirroring StorageController's boot:
clear feed-sorter program memory (`ClearMemory` LogicType and/or `SI.None`
words), park feed paths/valves to their idle routing, set `Activate = 0` on
every printer that has no durable in-flight task in the journal (durable tasks
resume from the journal, not from device state), and eject-pend any residue a
recovered cancellation left behind. No controlled device is left in an
arbitrary inherited state.

## Cancel + ejection
- Cancelling (queued or ACTIVE): transition `CANCELLED`, release the
  undelivered reservation remainder (`release_batch` must accept partial
  release — `cannot_release_in_flight` currently blocks once delivered), and
  record the residue per reagent (delivered/in-flight but unconsumed) on the
  task + journal — durable, survives restart.
- Ejection triggers only when a family's queue holds no `queued`/`active`/
  `awaiting_*` task and residue exists — the printer must finish its work
  first, because its single output ejects EVERYTHING in stack order (full
  stacks of an item first, partial stack last) and ejecting mid-task would dump
  live ingredients.
- Two residue paths, both returning to storage:
  a) In-flight deliveries landing at the INPUT sorter after a cancel are
     bounced straight back to the storage line there — they never reach the
     printer.
  b) Residue inside the printer is pushed out with the printer's native eject
     (full stacks per item first, partial last); while the family is in
     `ejecting`, the OUTPUT sorter routes everything back to the storage input
     (products and reagents alike — the printer is only emptied when idle, so
     nothing in flight is a product that matters).
- The eject mechanism is `LogicType.Open`: opening the printer ejects its
  reagent contents in stack order. While ejecting the printer cannot print —
  which is exactly why ejection waits for the queue to drain, and why queued
  tasks for that family do not start until the eject completes (Open closed).
  End condition: drive `Open = 1`, monitor the import/export slot reads until
  empty (bounded by a timeout), then `Open = 0`. Sorter routing for the return
  path is verified in-game.

## Generator changes (tools/generate_printer_catalog.py)
- Read `Time`/`Energy` inside `<Recipe>` (`recipe_el.find`), keeping the
  RecipeData-level `node.find` as fallback for mods that nest differently.
- Emit `mods = { workshop_id -> display_name }` read from each mod dir's
  `About/About.xml` `<Name>` (fall back to the raw id when absent) so the source
  filter shows real names. Add `mods` to the revision payload.
- Regenerate `PrinterCatalog.lua` + `tests/printer_recipe_test.lua`; add a
  template assertion that at least one known recipe carries a numeric `time`.
  Energy stays captured/emitted (schema consistency) but is NEVER displayed —
  the printers' energy use is not meaningful.

## UI design (adaptive — every rect computed from `s:size()`, no fixed px widths)

Element palette: `panel`, `label`, `button`, `icon` (`icon_type="prefab"` —
`task.item` is already a prefab name; printer tiles use the `prefab_hash` from
the get_state summary), `progress` (native fill, `direction`), `textinput`,
`select`, `checkbox`, `border`. `ss.ui.grid` for the tile grid. `s:commit()`
after every rebuild. Render on state revision change; between rebuilds update
progress `value`s via element handles (`surface:get(id):set_props`) so scroll
position and open overlays don't jump. `type="text"` is gone everywhere.

Colors (colors only, no status letters):
- absent printer `#3A3A46` (greyed icon) · idle `#475569` (slate)
- printing `#22C55E` (green = healthy work) · waiting resources `#EAB308` (amber)
- ejecting `#38BDF6` (cyan) · fault `#EF4444` (red = real faults only)
- task bars: queued bg `#1E3A5F` (blue); progress fill `#22C55E` left→right.

Navigation: `state.page` + `state.nav` back-stack; every sub-page gets a back
button top-left returning to the previous page. Persist page, filters,
selected recipe/qty in `ic.persist` prefs (existing mechanism).

### Page 1 — Main
- Header: status pill (READY/PAUSED/OFFLINE/CONNECTING) + last error line
  (from `recent_errors`; request failures appear here, not only `print`).
- 3×2 tile grid (ss.ui.grid): icon + family name per printer; tile bg = status
  color; click → printer page for that family.
- [ALL RECIPES] button → recipe page with no printer filter.
- Bottom print-queue bar: "PRINT QUEUE (n)" label is a button → task page.
  Rows: active tasks first (all printers), then queued in `task_order`. Each
  panel ~28-36 px: icon, item name, done/total. Item names are GUARANTEED
  readable up to 16 chars (panel width + font sized so 16 chars fit cleanly;
  longer names truncated ~20 chars, best effort). Queued = blue bg; active =
  green `progress` fill by `done_count/count`.

### Page 2 — Printer page (one per family)
- Back button; family icon + name + status in header.
- Task bar (this family's tasks only) → click leads to task page with this
  family selected as filter.
- Recipe list pre-filtered to this family; printer filter control hidden.

### Page 3 — Recipe list page
- Back button; filter row: printer-family `select` (six families; hidden when
  arriving from a printer page), name `textinput` (case-insensitive substring
  over display name AND prefab name — no patterns/regex), source `select`
  (vanilla + each mod display name from `mods`), "buildable only" `checkbox`,
  sort `select` (name asc / max-buildable desc).
- Paginated rows (~30-50/page, like the storage console): icon | name | source
  | max-buildable = min over reagents of floor(available / per-item grams),
  red when 0 | reagent list (>0 only; red = insufficient, yellow = limiting
  when nothing is red).
- Click selects (highlight border) → bottom request bar: icon + name, qty
  `textinput`, two stepper rows (−1/−5/−10/−25/−50/−100 and
  +1/+5/+10/+25/+50/+100 + MIN/MAX), estimated print time
  `catalog.time × count × time_multiplier`, [CREATE TASK] → `printers.request`.

### Page 4 — Task queue page
- Back button; one row per family, panels ordered by rank = position among the
  family's non-terminal tasks in `task_order` (terminal states filtered out;
  history up to 128 is mixed into task_order).
- Click a panel → overlay (high `z_index` dim panel + centered card): icon,
  item name, state, done/total + `progress`, reagents (from task's
  `reagent_labels` + cost_vector × count; delivered/planned where known), est.
  remaining = `time × (count − done) × multiplier` for active or "rank N" for
  queued, [CANCEL] (queued/paused/active) + [CLOSE]. No cancel buttons on the
  small bars themselves.

## File-by-file changes
- `tools/generate_printer_catalog.py` — Time/Energy inside `<Recipe>` +
  fallback; `mods` map; revision payload updated; test-template time assertion.
- `PrinterCatalog.lua`, `tests/printer_recipe_test.lua` — regenerated outputs.
- `PrinterController.lua` — `FAMILY_ID[payload.family_name]` routing; API v2
  cleanup (request_status/task_id_filter/legacy aliases/tier removed); task
  record schema finalized; get_state additions; `printers.get_inventory` relay
  (guarded, cached, ≥2 s rate limit); `PRINT_TIME_MULTIPLIER` config;
  `initialize_devices()` boot sanitize; real actuation (RecipeHash/Activate/
  CompletionRatio/Export*/Import* drives replacing program_for_recipe);
  cancel-active + partial release + residue ledger + ejection orchestration.
- `PrinterControlConsole.lua` — rewrite UI into the four pages; keep
  safe_rpc_call/prefs/uuid/reagent-resolution machinery; align to API v2 task
  schema; label elements; commit; revision-driven render + handle updates;
  `printers.get_inventory` on recipe page only.
- `tests/test_printer_console.lua` — mocks gain `printers.get_inventory` and
  API v2 get_state; assert the trimmed payload (no legacy aliases/tier);
  keep the printers.*-only isolation assertions.
- `tests/test_printer_controller.lua` — cover family_name routing, stored
  reagent_labels/done_count/resources_state, get_state additions,
  get_inventory relay + rate limit (mock `storage.get_state`), cancel-active +
  residue, ejection trigger after queue drains, boot sanitize calls.
- `tests/test_printer_persistence.lua` — schema v2 snapshot + residue ledger
  survives restart.

## Edge cases
- Offline/not-ready controller → OFFLINE pill, controls disabled, retained data.
- Storage unreachable → inventory `ok=false` → "--" buildable, uncolored
  reagents; recipes still submittable.
- Catalog absent/declining → `no_config` refusal (existing path preserved).
- `valid = false` recipes shown dimmed, not selectable.
- Cancel on terminal-state task → hidden button (state check on CANCEL render).
- Queue full (64) / invalid cost vector → controller error code on error line.
- Chip restart mid-eject → residue ledger is journaled; ejection resumes or
  re-derives on boot.

## Verification
- `lua tests\test_printer_console.lua`
- `lua tests\test_printer_controller.lua`
- `lua tests\test_printer_persistence.lua`
- `lua tests\printer_recipe_test.lua`
- `lua tests\test_storage_controller_drain.lua` (regression — isolation kept)
- `lua -e "assert(loadfile('PrinterControlConsole.lua'))"` + same for controller
- `python tools\generate_printer_catalog.py --game-root <game> --mod-config <xml> --check`
- In-game probe BEFORE the actuation code: write `RecipeHash`, `Activate`,
  read `CompletionRatio`/`ExportCount`/`Import*`/`Export*`/`Idle`/`Error` on one
  real printer per family; confirm `Open` ejects in stack order (full stacks
  first, partial last) and how "eject finished" is observable.
- In-game: four pages navigate, tile colors follow printer status, queue bar +
  task page populate, 16-char names render clean, paginated/filtered recipe
  list, max-buildable colors, request submits to the right family, cancel
  (queued + active) works, residue ejects after queue drains, boot parks all
  controlled devices.

## Implementation steps
- [ ] Generator: Time/Energy inside `<Recipe>` (+fallback), `mods` map, test
      template assertion; regenerate catalog + recipe test; `--check` clean.
- [ ] Controller: API v2 cleanup — remove request_status, task_id_filter,
      legacy aliases, tier, and the memory-program scaffolding.
- [ ] Controller: `FAMILY_ID[payload.family_name]` routing + test.
- [ ] Controller: task schema (reagent_labels/done_count/resources_state);
      get_state += printers/inventory-free summary, time_multiplier,
      recent_errors; `printers.get_inventory` relay with ≥2 s cache.
- [ ] Controller: `PRINT_TIME_MULTIPLIER` config.
- [ ] Controller: `initialize_devices()` boot known-state.
- [ ] In-game actuation probe → real LogicType drive (RecipeHash/Activate/
      CompletionRatio/counting; Open = eject) replacing the mock gate.
- [ ] Controller: cancel-active + partial release_batch + residue ledger +
      ejection orchestration (input-sorter bounce + Open eject → output
      sorter → storage; queued tasks wait for Open to close).
- [ ] Console: page/nav skeleton + status header + error line; commit on
      rebuild; revision-driven rendering + handle updates.
- [ ] Console: task bar component (shared; progress element; rank ordering;
      terminal filtering; 16-char name budget).
- [ ] Console: main page (3×2 status tiles, ALL RECIPES, queue bar).
- [ ] Console: recipe list component (filters, pagination, buildable math,
      reagent colors) + request bar.
- [ ] Console: printer page + task queue page + task-detail overlay (cancel).
- [ ] Update test suites + mocks; run the full lua test set above.
- [ ] In-game verification pass (checklist above).

## Out of scope / risks
- Per-printer LogicType semantics must be probed on real hardware before the
  driver is written — highest-risk item. (Eject is confirmed: `Open`.)
- Ejection blocks printing while open — new tasks submitted during `ejecting`
  queue behind it until `Open` closes; acceptable per the empty-queue rule.
- Multiple printers per family — rejected; family == printer.
- scrollview (no scroll-offset API) rejected in favor of pagination.
- Stack-size "STACK" button — dropped (no data source, low value).
- Estimated energy — dropped (not meaningful on this hardware).
- `min_tier` — dropped entirely (all printers fully upgraded); catalog data
  remains for information only.
