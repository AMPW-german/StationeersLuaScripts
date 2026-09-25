# Storage Console Plan (control screen chip)

## Purpose
A standalone Lua chip on a ScriptedScreens 3x3 console that operates the storage system only through the controller's standard RPC API (storage.get_state, storage.request, storage.request_status, storage.cancel) — no direct device access, no controller changes. Uses item thumbnails (prefab icons), resource/browse views, and an expandable request panel.

## Networking contract
- Target: Storage.Controller (constant). Console identification: destination_id = "Storage.Console" (informational).
- get_state { include_groups = true } → phase, fault, queue depth, active request id, per-silo {id, label, prefab_hash, state, confirmed_quantity, reserved_quantity, available_quantity, silo_stack_count, ...}.
- storage.request {client_request_id, prefab_hash, quantity, destination_id} → request id / stable rejection code. client_request_id = console-<os.clock()*1000>-<seq> (idempotent).
- storage.request_status {request_id} and storage.cancel {request_id} for tracking/cancelling.
- Names via global prefab_name(prefab_hash); icons via icon_type = "prefab", name = prefab_hash (numeric hash accepted).

## UI layout (adaptive to ui:size())

Surface ss.ui.surface("main") / ss.ui.activate("main"); everything sized from ui:size().

1. Header bar — title, controller status pill (READY/DISCOVERING/FAULT/OFFLINE), group count, queue depth, active-request id, sort toggle [BY RESOURCE] / [BY SILO], pagination [<] PAGE x/y [>], and request-panel toggle [REQUEST].
2. Silo grid (full area below header) — auto-fit cards: cols = ⌊(W−pad·2+gap)/(cellW+gap)⌋, rows = ⌊(H−header−pad·2+gap)/(cellH+gap)⌋ (cell defaults ~150×120 px, tuneable constants). Each card (one per silo):
  - Background: a progress element spanning the card with value = clamp(silo_stack_count / 600, 0, 1) — the silo fill bar — neutral accent fill (dark track), per your choice.
  - Item icon (type=icon, prefab hash) top-left; silo id (e.g. 0x0003) top-right.
  - Item name below icon; item quantity (confirmed units, e.g. 1,250; shows -R indicator when reserved > 0), beneath name.
  - Unassigned silos: placeholder icon, -- name/qty, fill 0. Tapping a card selects that silo/resource (highlight border).
3. Sort modes — one row per silo in both modes, only the key differs: by silo = ascending group.id; by resource = prefab_name asc, then silo id. Sort applies before pagination slicing; only the current page (cols×rows cards) is rendered.

### Expandable request panel
- Closed by default: only the header [REQUEST] button exists — takes almost no space from the grid.
- Open: bottom sheet (~45% height) overlays the grid with a dark panel (higher z_index) so the layout doesn't shift. Contents:
- Selected resource name + available quantity (row tap loads it), or a select dropdown of assigned resources sorted by name.
- Quantity entry: numeric textinput + steppers −1000/−100/−10/+10/+100/+1000 + MAX; integer-clamped to 1..available.
- [REQUEST] button with inline response (request id or rejection code).
- Tracked requests list (last ~6): resource, quantity, state, [CANCEL] for queued requests.
- [CLOSE] collapses back to header-only.

## Data flow
- Poll get_state ~every 1 s via a safe ic.net.request wrapper; rebuild only when state_revision/inventory_revision changes, otherwise just the status pill.
- Submit → add to tracked list → re-fetch state to refresh reservations. Tracked queued/active requests polled each refresh via storage.request_status; cancel allowed while queued.
- Persist prefs in ic.persist: sort mode, current page, panel open state.
- New silos appear automatically from the polled catalog (scalability).

## Edge cases
- RPC timeout/network down → OFFLINE pill, controls disabled, last data retained.
- Controller not ready/faulted → show phase, disable request/cancel.
- Unassigned silo tapped → no request possible, message shown.
- Fill ratio source: silo_stack_count / 600 (SDB capacity), capped 0..1, 0 when unknown.

## Deliverables
- STORAGE_CONSOLE_PLAN.md — this plan.
- StorageControlConsole.lua — the console script.

## Implementation steps
1. Scaffold StorageControlConsole.lua: constants, ss.ui surface/activate, safe RPC wrapper, main loop.
2. State fetch + catalog normalization (sort + paginate view model).
3. Header + grid rendering (progress-bg cards with icon/id/name/qty) + sort/pagination controls.
4. Expandable request sheet + quantity controls + submit.
5. Tracked-request list with status polling + cancel.
6. Persistence, offline/fault handling, only-on-change re-render.
7. In-game verification checklist (22 silos render, icons/quantities correct, both sorts, pagination, progress bars, request/cancel flow against controller logs, offline/fault states).