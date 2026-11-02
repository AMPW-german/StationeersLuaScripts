# Checkpoint — Printer automation: catalog-free controller, persistence done, tests realigning

**Saved:** 2026-10-19 · **Repo:** `D:\StationeersLua` · **Branch:** `main`
**Supersedes:** the 2026-10-16 catalog-embedded checkpoint. That checkpoint assumed
`PrinterController.lua` carried recipe data (`refresh_catalog`, `catalog_provider`,
`my_api_version`, `my_revision`, `recipe_cost_vector`, the `__PRINTER_CATALOG__`
bundle sentinel). **All of that is GONE.** The controller is now CATALOG-FREE.

---

## 0. CATALOG-FREE REFACTOR (the big change)

`PrinterController.lua` no longer knows any recipe data. Model (header L1-24): the
controller only **ROUTES, RESERVES, ACTUATES**. The PrinterCatalog is a passive
BUILD-TIME library chip; a console UI chip on the same data network `require`s the
catalog, builds the recipe menu, and packs each request as a fully-specified,
self-contained payload (`family_name`/`family_id`, `item`, `count`, `cost_vector`,
`tier`). The controller trusts that catalog-derived `cost_vector` but still
validates its SHAPE.

Symbol scan of `PrinterController.lua` (verified 2026-10-19):
- ABSENT: `refresh_catalog`, `catalog_provider`, `my_api_version`, `my_revision`,
  `recipe_cost_vector`, `__PRINTER_CATALOG__`, `get_catalog` (the old
  `require("PrinterCatalog")` dev fallback).
- PRESENT: `valid_cost_vector` (L170), `durable_snapshot` (L300),
  `register_api` (L724), `restore_state` (L370), `checkpoint` (L316),
  `journal_append` (L335), `dispatch_reserved` (L221), `delivery_ack`,
  `require(` (engine libs / net registration only, NOT the catalog),
  `schema_version`, `CONTROLLER_SCHEMA_VERSION = 1` (L31).

Boot/contract flow changes:
- **Boot (`initialize`, L800-808):** `register_api()` → `restore_state()` →
  `set_phase_or_fallback()` → `discover_printers()`. **No `refresh_catalog`.**
  The 2026-10-16 note that `restore_state` must precede `refresh_catalog` to avoid a
  nil `my_revision` is MOOT — there is no refresh step and no `my_revision`.
- **Cost validation:** `valid_cost_vector(raw)` returns `(cleaned_copy, nil, total)`
  on success, `(nil, reason, 0)` on failure, rejecting non-table / non-string key /
  non-number amount / NaN / negative. Called in `printers_request` at L591. It
  replaces the removed `recipe_cost_vector`.
- **Reservation ledger keys:** `reserve_batch` copies `recipe_cost` into the
  `reserved_ledger` record; `dispatch_reserved` / `delivery_ack` drive the additive
  storage handoff.
- **Native print:** still commission-gated (`check_commission` L468 =
  `native_enabled == true and native_commissioned == true`); OFF by default.
- **`make_packed_word` (L472)** is the FIX-verified form: `pos = 8` then
  `pos = pos + 32` per 32-bit param (old `#param * 32 == 0` byte-offset bug resolved).

---

## 1. What's green right now (live re-run, 2026-10-19, `lua.exe` 5.1)

| # | Suite | Command | Result |
|---|-------|---------|--------|
| 1 | controller  | `lua tests/test_printer_controller.lua`     | **FAIL** — L287 calls `refresh_catalog` (nil) |
| 2 | persistence | `lua tests/test_printer_persistence.lua`    | **FAIL** — L286 calls `refresh_catalog` (nil) |
| 3 | refresh contract | `lua tests/refresh_contract_test.lua`    | **19/19 PASS** (standalone manager stub) |
| 4 | recipe catalog | `lua tests/printer_recipe_test.lua`       | **PASS — 7 families, 588 recipes, 0 invalid** |
| 5 | console     | `lua tests/test_printer_console.lua`       | **29/29 PASS** |
| 6 | storage (ref) | `lua tests/test_storage_controller_drain.lua`| **20/20 PASS** (`0/20 tests failed`) |

**4 of 6 green; 2 red.** The two red suites are exactly the two that import/drive the
controller and carry a leftover `refresh_catalog()` call. They must be realigned to
the catalog-free API (see §7). Everything else is green.

All green suites run under the mocked `ic`/`ss`/`yield` harness — no `ic.*` inside
tests, no `pcall` in the main path, Lua 5.1 only. Interpreter / compiler:
`D:/programms/Lua/5.1/lua.exe` and `luac.exe`.

> **The two FAILing suites are stale on purpose.** Their `new_module()` (controller
> test L~287, persistence test L~286) still calls `m.refresh_catalog()`, which the
> catalog-free controller no longer exposes. Fail mode: `attempt to call field
> 'refresh_catalog' (a nil value)` → traceback at `new_module` → main chunk. This is a
> test-authoring gap, NOT a controller regression.

> **README.md / AGENTS.md suite counts:** README still says "4 of 4"; AGENTS.md lists
> 6. Treat the real matrix as the 6 above until README is updated.


---

## 2. PLAN ITEM 8 — Persistence across restart: **DONE** (and catalog-free)

Design (locked with user): `ic.persist` + `util.json` (test stand-in:
`tests/json_codec.lua`) + **journaling** (execution can stop every tick; must be
recoverable). Mirrors `StorageController.lua`. **Do NOT use any other storage
solution — `ic.persist` is mandatory; journaling is mandatory.**

### 2.1 Implementation in `PrinterController.lua` (verified 2026-10-19)
- **Boot sequence (`initialize`, L800-808, order matters):**
  `register_api()` → `restore_state()` → `set_phase_or_fallback()` →
  `discover_printers()`. **No `refresh_catalog` step, no `my_revision`.**
  - `register_api()` MUST run first: an early journal entry that fires its
    `safe_call(ic.net.register)` would nil-crash at `ic.net.register` if
    `register_api` hadn't run yet.
  - `restore_state()` runs before the phase/discovery so a recovered ledger exists
    when the tick loop decides `ready`.
- **Journal entry types (`journal_append`, L335):**
  - `"transition"` — inside `transition()` (L540).
  - `"task_created"` — inside `printers_request` (L626).
  - `"checkpoint"` — inside `journal_append` ITSELF, a NON-RECURSIVE recovery-point
    marker: it bumps `journal_seq` and appends `{seq, op="checkpoint", task_id,
    tick, updated_tick, journal_seq=capture_seq}` DIRECTLY (NOT re-entrantly —
    that would infinite-loop), truncates to `JOURNAL_MAX`, then calls
    `checkpoint()`.
- **Checkpointing (durable flush, `checkpoint` L316):** if no persist backend,
  returns true (in-memory journal already advanced). Otherwise
  `util.json.encode(durable_snapshot())` →
  `ic.persist.set(PERSISTENCE_KEY, encoded)`. Wired after `transition()`,
  `printers_request` (via `journal_append`), `printers_cancel` (L675), and at the
  end of `service_tasks()` (L797).
- **First-boot handling (`restore_state` L370):** returns
  `false, "no_persistence_backend"` if `has_persist()` is false, and
  `false, "no_state"` SILENTLY (no `add_error`) when nothing was ever persisted.
  Only a JSON-decode failure OR a `controller_schema_version` mismatch throws
  `add_error("persistence_decode_error"/"persistence_schema_mismatch", ...)`
  (L382 / L386).
- **Constants:** `CONTROLLER_SCHEMA_VERSION = 1` (L31), `JOURNAL_MAX = 128` (L39),
  `MAX_QUEUE_LENGTH = 64` (L32), `MAX_TASK_HISTORY = 128` (L33, drives
  `trim_history` L736), `PERSISTENCE_KEY = "printer_controller_state"` (L41).

### 2.2 `durable_snapshot()` shape (ACTUAL, L300-314 — corrected vs catalog-era)
The catalog-era checkpoint listed wrong keys (`reserved_ledger`, `api_version`,
`revision`, `request_count`, `saved_at`). The REAL current keys are:
```
controller_schema_version = CONTROLLER_SCHEMA_VERSION
sequence = state.sequence
journal_seq = state.journal_seq
task_order   = deep_copy(state.task_order)
tasks        = deep_copy(state.tasks)
reservation_ledger = deep_copy(state.reserved_ledger)   -- key is "reservation_ledger"
reserved    = deep_copy(state.reserved)
idempotency = deep_copy(state.idempotency)
active_task_by_printer = deep_copy(state.active_task_by_printer)
journal     = deep_copy(state.journal)
saved_tick = state.tick
```
NOTE for the persistence test: the snapshot has NO `api_version`, NO `revision`,
NO `request_count`, NO `saved_at`. It DOES have `active_task_by_printer`, `journal`,
`saved_tick`, and the ledger key is `reservation_ledger` (NOT `reserved_ledger`).
`restore_state` mirrors this on the way back in (L393-428).

### 2.3 `safe_call` contract — CRITICAL (already-fixed)
`safe_call` returns a SINGLE value (`result[2]`), not a 2-value `(ok, val)`.
Destructuring `local ok, val = safe_call(...)` is WRONG — `ok` gets the result and
`val` is always nil. Correct usage:
```lua
local value = safe_call(fn, arg)
if type(value) ~= "table" then return false, value end
```
Applied at `checkpoint`/`durable_sync` (L322-327), `journal_append`, `restore_state`
(L374/380 — `ic.persist.get` and `util.json.decode`), and the `ic.net.register`
registration in `register_api`. `restore_state`'s JSON-decode path uses
`safe_call` + `type` checks, NOT raw `pcall` in the test main path.

### 2.4 Cost vector = `valid_cost_vector` (L170-187)
Replaces the removed `recipe_cost_vector`. The controller TRUSTS the console's
catalog-derived `cost_vector` but validates SHAPE: input must be a `table` of
`name(string) -> amount(number)`; rejects NaN (`amount ~= amount`), negative,
non-string key, non-number amount; zero-amounts are stripped; returns
`(cleaned_copy, nil, total)`. Failure returns `(nil, "invalid_cost_amount" |
"invalid_cost_vector", 0)`. `printers_request` (L591) calls it; on failure returns
`response_error("invalid_cost_vector")`. The reservation then stores
`cost_vector = deep_copy(cost)`, `cost_total = total` on the task.

## 3. PLAN ITEM 130 — `PrinterController.bundle.lua` builder: **SUPERSEDED by the catalog-free refactor**

The 2026-10-16 plan was to embed the recipe catalog into a deployable
`PrinterController.bundle.lua` by string-replacing a single `__PRINTER_CATALOG__`
sentinel in `PrinterController.lua` with `local Catalog = {...}`. **That whole
approach is DEAD** because the controller is now catalog-free (§0):
- NO `__PRINTER_CATALOG__` sentinel exists anywhere in `PrinterController.lua`.
- NO `get_catalog()`, `catalog_provider`, `_CATALOG_EMBED`, or
  `require("PrinterCatalog")` dev fallback.
- `tools/generate_printer_catalog.py` (git: `M`) still builds `PrinterCatalog.lua`
  and regenerates the `-- DO NOT EDIT` `tests/printer_recipe_test.lua` (588 recipes
  / 7 families, PASS), but it now has NO controller to bundle — any
  `--controller`/`build_bundle` path in it is obsolete.

**Open question to resolve before more work:** with the controller catalog-free
and recipe data living entirely in `PrinterCatalog.lua`, is
`PrinterController.bundle.lua` still wanted? Likely the deployable is now just the
three chips `PrinterController.lua` + `PrinterCatalog.lua`
+ `PrinterControlConsole.lua`, and the bundle step is DROPPED. `build_bundle`
(L900-923) / `_catalog_literal_only` (L878) can be removed from the generator.
Decide with the user before spending effort.

---

## 4. Locked decisions (post-refactor — don't re-litigate)
- **Catalog-free controller:** `PrinterController.lua` carries ZERO recipe data.
  It routes by `family_name`/`family_id`, structurally validates a console-supplied
  `cost_vector` via `valid_cost_vector`, reserves, and (commission-gated) acts out
  the single-item print. Recipe updates = redeploy `PrinterCatalog.lua` only; the
  controller and consoles do NOT restart to pick up recipe changes.
- **Artifacts:** `PrinterController.lua` (catalog-free IC logic chip),
  `PrinterCatalog.lua` (passive BUILD-TIME library chip, hot-reloaded by the
  console via `require("PrinterCatalog", true)`), `PrinterControlConsole.lua`
  (ScriptedScreens UI — UI-only, talks to `Printer.Controller` via `ss:RPC()`
  only, NEVER imports `PrinterController`/`PrinterCatalog`, never touches pins;
  `ss:RPC` mock returns `false, "unavailable"` in tests), `StorageController.lua`
  (ref), `StorageControlConsole.lua` (untouched), `tools/generate_printer_catalog.py`
  (build tool). `PrinterController.bundle.lua` — does NOT exist and is in question
  (§3).
- **Lua library is hot-reload-locked-out** (flash = restart); the catalog chip
  hot-reloads via `require("PrinterCatalog", true)` in the console — accepted.
- **Actuation (physical single-item print)** is commission-gated behind
  `check_commission()` (`native_enabled` AND `native_commissioned`), default OFF;
  validated with mocks, enabled only after commissioning passes.
- **Reservation→storage wiring is NOT done** — `dispatch_reserved` / `delivery_ack`
  are the prepared handoff; wiring to `StorageController` is a later phase.
- **Per-item cost vector:** e.g. `Iron=2` per item; the reservation carries the
  TOTAL (`per * count`).
- **`printers_request(payload, owner)`**: idempotency key = `owner .. ":" ..
  payload.client_request_id`; payload needs `family_id`/`family_name`, `item`,
  `count` (integer >0), `cost_vector`, optional `tier`.
- **`printers_cancel(payload, sender)`** requires `payload = {api_version,
  task_id, owner}`; routes through `lookup_task(payload.task_id, sender)`.
- **`printers_get_state`** unpacks `lookup_task(task, err)` carefully; a
  `task_id_filter` branch (L686) returns `{tasks={task}, task_count=1}` to avoid
  mis-unpacking.
- **Splicing idiom (persistence test):** drop the leading journal entry with
  `entry_index - 1`.
- **Export access pattern (tests):** route through
  `chunk_run.state.printer_by_name` (not the module return).
- **`safe_call`** returns a single value — never destructure it into 2 locals.
- **`make_packed_word`** runs `pos = 8` then `pos = pos + 32` per 32-bit param
  (the L557-580 `#param*32==0` bug class is fixed).

---

## 5. Commands (from `D:\StationeersLua`, Lua 5.1 on PATH)

```bash
# syntax (compile-only) checks
D:/programms/Lua/5.1/luac.exe -p PrinterController.lua
D:/programms/Lua/5.1/luac.exe -p tests/test_printer_controller.lua
D:/programms/Lua/5.1/luac.exe -p tests/test_printer_persistence.lua

# full 6-suite matrix
for t in test_printer_controller test_printer_persistence \
         refresh_contract_test printer_recipe_test test_printer_console \
         test_storage_controller_drain; do
  echo -n "$t: "; D:/programms/Lua/5.1/lua.exe tests/$t.lua 2>&1 \
    | grep -E "PASS|FAIL|passed|failed|families|recipes" | tail -1
done

# regenerate the catalog + the generated recipe test (no bundling)
python tools/generate_printer_catalog.py \
  --game-root "D:/SteamLibrary/steamapps/common/Stationeers" \
  --mod-config "C:/Users/AMPW/Documents/My Games/Stationeers/modconfig.xml" \
  [--out-dir .] [--check] [--test-out tests/printer_recipe_test.lua]
```

**Tooling gotchas (this session):**
- `run_commands` ONLY accepts the array form `run_commands(commands=[...])` under
  the key `commands`; the older `arguments=` string form returns `✖ Invalid input`
  every time. (A recurring self-inflicted failure — use `commands`.)
- The tool bridge / shell flaked intermittently; retries with the right key
  succeeded. If a call returns `✖ Invalid input`, check the param key first.
- `read_files` on freshly-written dump files sometimes returns a stale
  cache ("[outdated - see the latest file content]"); use a FRESH dump filename.
- **Terminal caveat:** piping through `tail -1`/`grep` only shows the LAST line;
  for full counts read the full stdout.

---

## 6. Untracked / modified files (git status at checkpoint, 2026-10-19)

Tracked / modified:
- `M AGENTS.md` — printer-suite section + 6-suite list.
- `M tools/generate_printer_catalog.py` — catalog generator (still emits
  `PrinterCatalog.lua` + the generated recipe test; bundle path now obsolete §3).
- `M tools/__pycache__/generate_printer_catalog.cpython-314.pyc` — regenerated.
- `?? CHECKPOINT-persistence-and-bundle.md` — this file.
- `?? PrinterController.lua` — **catalog-free controller (THE refactor of §0); 829
  lines.**
- `?? PrinterControlConsole.lua` — ScriptedScreens console; 29/29
  `test_printer_console.lua`.
- `?? tests/json_codec.lua` — util.json test stand-in.
- `?? tests/test_printer_controller.lua` — **STALE: FAILs at L287 (`refresh_catalog`).**
- `?? tests/test_printer_persistence.lua` — **STALE: FAILs at L286 (`refresh_catalog`).**
- `?? tests/printer_recipe_test.lua` — GENERATED (`-- DO NOT EDIT`); standalone
  588 recipes / 7 families PASS.
- `?? tests/refresh_contract_test.lua` — standalone manager stub, 19/19 PASS.
- `?? tests/test_printer_console.lua` — 29/29, path-robust.
- `?? tests/test_storage_controller_drain.lua` — reference, 20/20 PASS.
- `?? PrinterCatalog.lua` — generated passive catalog (588 recipes / 7 families).
- `?? storage_controller_*` + `storage_*.lua` (13 lines) — StorageController
  reference artifacts.
- `?? tools/_probe3.py`, `?? tools/_verify_sentinel.py` — scratch probes.

Untracked SCRATCH (safe to delete; ~35 `_`-prefixed files):
- Root: `_c_bare.lua`, `_c_bund.lua`, `_c_call.lua`, `_c_paren.lua`, `_c_x.lua`,
  `_probe.lua`, `_probe_forms.lua`, `_t_dev.lua`, `_cleanup.py`, `_runone.py`,
  `_runctl.py`, `_cmk.py`, `_go1.py`, `_write_ckpt.py`, `_marks.py`,
  `_ctl_probe.txt`, `_ck_mid.txt`, `_ck_160.txt`, the `_d_*.txt` / `_dp_*.txt`
  dumps, `_dump*.py`, `_gen.py`, `_grep_tmp.py`, `_inspect_tmp.py`,
  `_inspect2_tmp.py`, `_dumpout.txt`.
- `tools/`: `_probe3.py`, `_verify_sentinel.py`.

> **DO NOT delete** `scratch.ic10` / `sratch2.ic10` (or any tracked `.ic10`)
> — they are the game save/level fixtures. Only `_`-prefixed untracked scratch is
> safe. A `_cleanup.py` writer exists to delete exactly that set while protecting
> the `.ic10` fixtures; it has NOT yet been executed.

`PrinterController.bundle.lua` — **does NOT exist** (item 130 now in question; §3).

---

## 7. Immediate next action
1. **Realign `tests/test_printer_controller.lua`:** drop the `refresh_catalog`
   call (L~287) and any `my_api_version`/`my_revision`/`catalog_provider` usage;
   replace the removed `recipe_cost_vector` tests with `valid_cost_vector`-based
   cost checks; remove obsolete catalog-refresh / version / revision tests;
   re-point `new_module` at the catalog-free `initialize`
   (`register_api → restore_state → set_phase_or_fallback → discover_printers`).
2. **Realign `tests/test_printer_persistence.lua`:** drop `refresh_catalog`
   (L~286); align snapshot assertions to the ACTUAL `durable_snapshot` shape
   (§2.2 — `reservation_ledger`, `active_task_by_printer`, `journal`,
   `saved_tick`; no `api_version`/`revision`/`request_count`/`saved_at`); strip
   `my_*` fields.
3. **`tests/printer_recipe_test.lua`:** standalone PASS; it is GENERATED — do not
   hand-edit, keep it regenerable from `tools/generate_printer_catalog.py`.
4. **Decision on `tests/refresh_contract_test.lua`:** it models a version-gated
   catalog-refresh contract the catalog-free controller no longer has — decide
   whether to delete it or keep as regression doc for the `revision`-bump
   semantics that now live in `PrinterCatalog.lua` hot-reload.
5. **§3:** resolve with the user whether `PrinterController.bundle.lua` is still
   wanted now the controller is catalog-free; if not, drop `build_bundle` /
   `_catalog_literal_only` from the generator.
6. **Delete the untracked scratch** (run `_cleanup.py`; verify `.ic10` survive).
7. **`luac -p` every changed `.lua`; re-run all 6 suites; target 6/6 green.**
8. **Update `README.md`** to the 6-suite matrix (currently "4 of 4").
9. **`git add` + commit** the catalog-free controller, the realigned tests, this
   checkpoint, and the scratch cleanup.

Session transcript for deep recovery:
`session_search(query='persistence bundle sentinel', session_id='20261015_203331_70cec3')`.
