# Advanced Silo Storage Controller Plan

## Purpose

Build one StationeersLua controller chip that discovers, validates, recovers, and operates an SDB silo storage system. Other Lua chips use a versioned network API to request resources and read controller state. A console chip may later use the same API for display and configuration.

This document records the implementation plan and its current state. `StorageController.lua` and the manual request client now exist in this repository.

## Current State

### Repository

- `StorageController.lua` is a single controller script. It implements topology enumeration, safe initialization, sorter-memory recovery, a startup inventory baseline, input and fail-valve servicing, ledger reservations, persistence, state publications, and the version-1 request/status/cancel/state/config RPC surface.
- `StorageControllerRequestTest.lua` is the sole test client. It uses two named button/dial pairs to request iron and silicon ingots through the controller API.
- Physical output fulfillment is implemented as a serialized controller task. It dispenses one source stack at a time, accounts at the closed output-input valve, splits and releases exact requested portions through output 1, and sends excess material through output 2 to normal input accounting. Recovery drains and decoded post-ready silo reconciliation remain unimplemented because Stationpedia does not expose the SDB internal-memory encoding.
- The storage topology is currently empty and not in use. No fixture, automated Lua harness, or further test script is planned at this stage.

### Verified Stationeers capabilities

- `StructureLogicSorter` (`873418029`) has 32 writable 64-bit memory rows, modes All/Any/None, and Import, reject Export, and matching Export 2 slots.
- A prefab-equality sorter row is encoded as opcode `FilterPrefabHashEquals` in bits 0-7 and the signed 32-bit prefab hash in bits 8-39. Unused rows must be zero.
- `StructureStacker` (`-2020231820`) and `StructureStackerReverse` (`1585641623`) expose Automatic/Logic mode, `Setting`, one-shot `Output`, and three readable slots.
- `StructureSDBSilo` (`1155865682`) holds up to 600 stacks. It exposes `Quantity`, `StackSize`, `Dispense`, `DispenseSlot`, two transfer slots, and read-only internal memory reported as 4800 bytes by Stationpedia. `StackSize` reports the silo capacity of 600 rather than an item's physical stack size. Each occupied memory word stores an 8-bit opcode, a 13-bit stack quantity at bits 8-20, and an unsigned prefab hash at bits 21-52. A current game bug reports ingot quantity as 1, which the controller temporarily overrides to 500.
- Left and right chute digital valves expose `On`, `Open`, `Setting`, `Quantity`, and one transport slot. They can close after a configured number of items.
- Left and right chute digital flip-flop splitters expose `On`, `Mode`, `Setting`, `SettingOutput`, `Quantity`, and one transport slot.
- StationeersLua supports device enumeration, reference-ID reads/writes, slot reads, external device memory reads/writes, persistence, cooperative `yield()`, RPC, and pub/sub on the same data network.
- The in-game MCP server was available while planning, but no storage data network was visible from the current PAN-only editor context. Device-specific transfer sequences therefore still require calibration against the built storage line.

## Confirmed Decisions

- Group labels are exact four-digit, two-byte hexadecimal display names: `0x0000`, `0x0001`, ..., `0xFFFF`.
- The sorter, group stacker, and silo in a group have the same exact display name. Grouping compares the display name; comparing `name_hash` instead would also work, but both checks are unnecessary.
- Group IDs start at `0x0000`, are contiguous, and have no gaps or duplicates.
- An unknown input resource automatically claims the lowest-ID empty group.
- A resource uses at most one silo in the first version.
- Output requests are asynchronous. Acceptance performs an immediate check against the controller's recovered in-memory ledger, including known contents in group stackers.
- An accepted output request reserves its full quantity before it is queued. Concurrent requests cannot spend the same stock.
- A request that cannot be fully reserved is rejected before any item is dispensed. Normal operation must not intentionally produce a partial delivery.
- If physical inventory changes unexpectedly or an actuator fails after dispensing starts, rollback is impossible. The request becomes `faulted`, all flow is stopped, and reconciliation is required; it must not be reported as a clean atomic rejection.
- Every group stacker uses `Setting = 500` as a ceiling above the maximum stack size of supported resources. Each item therefore enters the silo as a full stack at that item's own `MaxQuantity`, which may be much lower than 500. A group stacker may still hold one partial stack waiting to reach the resource-specific maximum, and that quantity is part of available inventory.
- A request may need to export the partial stack held by a group stacker. If doing so empties the group, clear the sorter assignment and send any unrequested remainder through the output return path so it is treated as new input and assigned normally.
- A one-time silo inventory scan cross-checks sorter assignments after the controller is already `ready`. A mismatch drains the affected silo and stacker to the shared output return path, routes the material back to input, and leaves the group unassigned after it is confirmed empty.
- Runtime silo contents can change only through controller-owned stackers, so one post-ready validation scan plus valve-boundary accounting is sufficient.

## Physical Topology

### Input and rejection path

```text
Storage.InputValve
  -> group 0 sorter reject
  -> group 1 sorter reject
  -> ...
  -> final sorter reject
  -> Storage.FailValve
  -> Storage.FailSplitter
      output 2 -> input chute before Storage.InputValve
      output 1 -> external dump location
```

Each matching sorter output has this branch:

```text
group sorter match -> same-group stacker -> same-group SDB silo
```

The controller routes a terminal reject back to input only after it has confirmed an existing matching group or successfully assigned an empty group. Otherwise it selects the dump output. The dump destination itself is out of scope.

### Shared output path

```text
all silo outputs
  -> Storage.OutputInValve
  -> Storage.OutputStacker
  -> Storage.OutputOutValve
  -> Storage.OutputSplitter
      output 1 -> shared request collection chute
      output 2 -> input chute before Storage.InputValve
```

Only one silo may dispense at a time. The two output valves isolate one transported stack at each side of the exact-quantity stacker. Both digital splitter orientations use output 2 as the top/orthogonal return path and output 1 as the straight/perpendicular non-return path, so wiring orientation does not require calibration.

Every valve is configured to close after one item. A closed valve holding an item is the controller's reliable observation point: the controller inspects that valve slot, prepares the downstream route, verifies the next controlled slot is free where required, and opens the valve for exactly that item. Normal flow logic must not depend on observing transient sorter, stacker, silo, or splitter slots on the precise tick an item passes through them.

### Reserved shared device names

- `Storage.Controller`: controller chip housing; RPC target name.
- `Storage.InputValve`: valve before the first sorter.
- `Storage.FailValve`: valve after the last sorter's reject output.
- `Storage.FailSplitter`: digital splitter selecting retry or dump.
- `Storage.OutputInValve`: valve between merged silo outputs and the output stacker.
- `Storage.OutputStacker`: the one additional exact-quantity stacker.
- `Storage.OutputOutValve`: valve after the output stacker.
- `Storage.OutputSplitter`: digital splitter selecting request output or return to input.

Orientation variants of stackers, valves, and digital splitters are permitted if they expose the required logic and slot interfaces. Splitter routing is fixed by port number: output 2 is always return-to-input and output 1 is always request-output or dump. Only the logic value that selects output 1 versus output 2 needs to be verified once against Stationpedia/device behavior; physical left/right orientation is irrelevant.

## Core Invariants

- Exactly one logic sorter, one group stacker, and one SDB silo exist for every group ID.
- Exactly one additional stacker exists and is named `Storage.OutputStacker`.
- No other logic sorters, stackers, or SDB silos exist on the dedicated storage data/power grid.
- Every group label matches `^0x[0-9A-Fa-f]{4}$`; canonicalize to uppercase for diagnostics but require the physical label to be unambiguous.
- Parsed group IDs are exactly `0..group_count-1`.
- Device grouping compares exact display labels. `name_hash` does not need a second comparison.
- A group is either unassigned, assigned to one prefab hash, reconciling, draining, or faulted.
- A prefab hash is assigned to at most one group in version 1.
- Sorter memory is authoritative for recovered resource assignment. Controller persistence may journal quantities and requests but never silently overrides a valid sorter assignment.
- An unassigned sorter has all memory rows cleared. An assigned sorter contains exactly one prefab-equality row at address 0 and zero in every other row.
- A group may be cleared only when its silo reports zero occupied slots, its group stacker is empty, no output request references the group, and no controller-commanded dispense is in progress. Transient sorter slots are not part of this decision.
- All flow valves default closed during discovery, recovery, faults, and script shutdown/restart initialization.
- Input handling and output handling are physically separated by the silos and do not need a shared movement lock.
- Each controlled valve path has a local busy state while the controller checks the next required slot, selects a splitter route, releases one item, waits for automatic closure, and detects a stuck item. Only the shared silo output line requires serialization between output requests.
- Once an item is sent through either splitter's output-2 return path it is deliberately forgotten. It creates no retained movement transaction or lock and will be observed and counted as a new item when it reaches `Storage.InputValve`.
- Ledger values never become negative. Available stock is `confirmed_quantity - reserved_quantity`.
- Store `max_stack_quantity` per assigned resource/group. Derive it from a held input item's readable `MaxQuantity`, a pending group-stacker item, or a full stored stack, and cross-check later observations against it.

## Controller State Model

### Global phases

1. `booting`: close flow devices and initialize API handlers in not-ready mode.
2. `discovering`: enumerate devices and build group candidates.
3. `invalid_topology`: publish validation errors and perform no movement.
4. `recovering`: decode sorter memory and reconstruct assignments.
5. `ready`: accept input and output work; run the optional one-time validation scan only when no higher-priority work exists.
6. `faulted`: close all valves, stop dispensing, preserve diagnostics and the request/output journal.

The API may become reachable at `booting`, but mutation requests return `not_ready` until sorter recovery and the cheap inventory baseline are complete. Reconciliation is validation for an unlikely inconsistent state, not a readiness gate. It starts only after entering `ready` and never runs while another task is queued.

### Group state

Each group record contains:

- `id`, canonical label, and sorter/stacker/silo reference IDs.
- `assignment_prefab_hash` and assignment source (`sorter_memory` or `new_input`).
- `confirmed_quantity`, `reserved_quantity`, and optional per-stack scan summary.
- Last observed input/fail/output valve contents and device counters for diagnostics.
- Reconciliation cursor and flags for `scan_complete`, `mismatch`, `draining`, and `fault`.
- Active request ID, if any.

### Request state

`accepted -> queued -> active -> completed`

Terminal alternatives are `rejected`, `cancelled` (only before `active`), and `faulted`. Every transition records a monotonic sequence number and controller time for diagnostics. Completed and terminal requests remain queryable for a bounded retention period and are persisted across reloads.

## Startup and Recovery

### Safe initialization

- Register read-only RPC handlers first so clients can see `booting` and startup errors.
- Discover all visible devices by prefab and exact display name.
- Resolve allowed orientation prefab hashes from Stationpedia-tested constants.
- Close every managed valve, power required devices on, and set splitters to output 1 as the safe non-return route.
- Do not open any path until topology validation and sorter recovery succeed.

### Topology validation

- Enumerate all visible devices once and bucket managed devices by exact display name and prefab type. This is the primary validation because stopping at the first missing sequential group would fail to detect later malformed, orphaned, or extra devices.
- Starting at `0x0000`, consume exactly one sorter, one group stacker, and one silo from each contiguous group. Stop when the next complete group is absent.
- After the contiguous sequence is built, reject every remaining hex-labelled or managed sorter/stacker/silo as malformed, duplicated, orphaned, gapped, or extra. Exempt only the single reserved output stacker.
- Require exactly one of every reserved shared device and verify its prefab belongs to the allowed type set.
- Report all discovered errors in one diagnostic result rather than stopping at the first error.

Repeated “find group N until missing” calls are not more reliable and may perform more network scans. A single enumeration plus sequential validation preserves the fixed-ID behavior while still proving that no devices exist after a gap.

### Mandatory device configuration

Write and read back every required setting because save/load may restore incorrect manual state:

- Group sorters: `On = 1`, unlocked/locked according to the chosen maintenance policy, `Mode = Any`, and validated memory program.
- Group stackers: `On = 1`, `Mode = Automatic`, `Setting = 500`. This is mandatory as a high target: the stacker emits a stack when it reaches the resource's own lower `MaxQuantity`, so only resource-specific full stacks enter the silo. A smaller pending stack remains in the stacker and must be included in inventory.
- SDB silos: `On = 1`; set required mode/open/activate defaults only after an in-game probe establishes their exact idle semantics.
- Output stacker: `On = 1`, `Mode = Logic`, idle `Output = -1`, and a safe default `Setting`.
- Chute valves: `On = 1`, automatic-close threshold `Setting = 1`, and `Open = 0` at rest.
- Digital splitters: `On = 1`, fixed ratio/settings, and output 1 selected by default. Output 2 is the fixed return-to-input route for both orientations.

Unsupported writes, failed read-backs, or a device `Error` value put the controller in `invalid_topology` or `faulted` before movement.

### Sorter-memory recovery

- Read all 32 sorter memory rows.
- All-zero memory means unassigned.
- A valid assignment has only row 0 populated with `FilterPrefabHashEquals`; decode bits 8-39 as a signed 32-bit prefab hash.
- Reject malformed opcodes, zero/invalid prefab hashes, duplicate prefab assignments, unexpected nonzero rows, and programs that cannot be round-trip encoded.
- Preserve valid assignments and rebuild the prefab-to-group index from sorter memory.
- Do not use persisted assignment data to repair a disagreement automatically.

### Resumable inventory reconciliation

- Before `ready`, obtain a cheap quantity baseline for each assigned group: read the silo's occupied-stack count from `Quantity`, immediately decode memory address 0 when the silo is nonempty, verify its signed prefab hash against the sorter assignment, and multiply the decoded stack quantity by the occupied-stack count. Log and replace a decoded quantity of 1 with 500 as a temporary workaround for the ingot-memory bug.
- Treat an empty silo as zero without reading an internal stack. If no stack size was learned from the group stacker, retry the single address-0 sample when a request arrives; return `inventory_unknown` without blocking when the silo is still empty or the sample is unavailable.
- After the controller enters `ready`, scan the occupied silo memory incrementally. Check at most `MAX_SILO_MEMORY_READS_PER_TICK` stacks per idle tick, defaulting to one, and stop at the occupied-stack count captured for the recovery baseline.
- Run a scan step only when the recovery, output, and fixed per-tick valve services have no pending work. Store the cursor and resume without restarting already verified addresses.
- Compare every nonempty stored stack with the recovered sorter assignment and verify its quantity equals the group's resource-specific `max_stack_quantity`. Include the group stacker's current partial item separately; do not rely on transient sorter or silo transfer slots.
- If an assigned group contains another prefab, or an unassigned group is not empty, mark it `mismatch` and enqueue a priority-1 recovery drain.
- A recovery drain serializes the shared output line, exports the group stacker's pending item as well as all silo stacks, clears the sorter assignment once the group is empty, and sends everything through output 2 of `Storage.OutputSplitter`. Returned items are forgotten and later re-enter through the normal input check.
- If the silo memory layout cannot be reliably decoded, expose `unsupported_silo_scan` for that optional validation. Keep normal operation limited to groups whose cheap full-stack baseline is valid rather than claiming reconciliation succeeded from transient device slots.

## Scheduler and Task Queue

Use one cooperative scheduler with FIFO order inside each priority. Each task implements a bounded `step()` and yields after one device action or a small scan batch.

1. Recovery: startup decode, detected mismatch drains, and output fault reconciliation.
2. Resource output: fulfill one already-reserved request through the shared silo output line.
3. Silo stack scan: post-ready, one-time, cursor-based validation work.

Additional scheduling rules:

- Service `Storage.InputValve` and `Storage.FailValve` once at the start of every tick before the task queue. This is fixed lightweight control logic, not a queued resource-input transaction.
- Each valve service is idempotent while its valve remains occupied: inspect the held item, prepare assignment/route state, verify the required next slot is free, and open once. Track the valve's local release state until it auto-closes and becomes empty.
- Priority-1 recovery blocks only the shared output hardware or affected group it uses. Ordinary input remains independent unless recovery explicitly changes sorter assignments.
- Slot scanning is interruptible between individual addresses and never changes an actuator.
- Apply timeouts to every expected slot, counter, and valve transition. Timeout closes all flow and records the exact device and expected condition.
- Run no more than the configured number of scan checks per tick and only when no queued tasks remain. Expose scan progress; indefinite delay under real traffic is acceptable.

## Resource Input Workflow

- At the start of every tick, inspect the item held by the closed `Storage.InputValve`.
- If its prefab already has a group, verify or learn the held item's `MaxQuantity`, add its current quantity to the in-memory ledger once, and open the valve for exactly one item.
- Otherwise select the lowest-ID group satisfying the empty-group invariant, read the held item's `MaxQuantity`, encode and write its sorter assignment, read it back, store `max_stack_quantity`, update the index, add the held quantity to the ledger, and open the valve. Assignment may span ticks; the valve safely retains the item, so no separate input task is required unless measurements show sorter programming exceeds the tick budget.
- If no group is available, mark the held item as uncounted and open it toward the sorter cascade. It will eventually be handled at `Storage.FailValve` and dumped.
- At the start of every tick, also inspect `Storage.FailValve`. Select output 2 and release the item back to input only if a matching group now exists or an empty group can first be assigned. Select output 1 and release it to dump otherwise.
- Before retrying an item that was already counted at `Storage.InputValve`, remove that prior count so its next input-valve observation adds it exactly once. Items that never had a silo available were never counted and go to dump without changing stored inventory.
- Do not wait for or poll transient sorter, stacker, silo, or splitter slots to confirm ordinary input. The two one-item valves are the authoritative observation and accounting boundaries.
- When output processing empties a group's silo and exports its pending stacker contents, clear that group's sorter assignment. Any unrequested remainder sent to return is forgotten and may claim a group normally at the input valve.

## Resource Output Workflow

### Acceptance and reservation

- Validate request schema, positive integral quantity, supported prefab hash, and idempotency key.
- Find the single assigned group for the prefab. Multi-silo aggregation is explicitly unsupported in version 1.
- Check the in-memory ledger, including known group stacker contents, without starting a new physical scan.
- If one group cannot satisfy the full quantity, return `insufficient_stock` and move no item.
- Otherwise atomically increment `reserved_quantity`, persist the request journal, enqueue it, and return its request ID.

### Physical fulfillment

- Acquire the shared silo-output lock and revalidate the reservation against the ledger.
- Calculate `source_stack_count = ceil(requested_quantity / max_stack_quantity)`. Dispense those source stacks one at a time through the cooperative output state machine, checking the silo's current `Quantity` before each command. This keeps the controller responsive to other per-tick services and limits excess material to less than one source stack.
- Dispense enough resource-specific full stacks from the silo to cover each output portion. If the silo alone cannot cover the request, command the group's input stacker, whose setting remains 500, to export its pending resource into the silo, then dispense it as part of the same serialized request.
- If exporting the group stacker and dispensing the silo empties the group, clear its sorter assignment before returned remainders can reach input. This lets the returned resource claim a free group through normal input assignment.
- Select the required silo stack(s) using the verified `DispenseSlot`/`Dispense` sequence.
- Let each stack wait at closed `Storage.OutputInValve`. Inspect it there, verify `Storage.OutputStacker` can accept it, subtract the complete admitted stack from `confirmed_quantity`, persist the output checkpoint, and open the valve for exactly one item.
- Let `Storage.OutputStacker` combine or split material in logic mode. Each requested output portion waits at closed `Storage.OutputOutValve`; inspect its quantity, select output 1, verify the request path is free, and release it. After all requested portions are delivered, configure the stacker as needed to emit any unrequested remainder, select output 2, and return that remainder to input.
- Items sent to output 2 are forgotten immediately. They are added to inventory again only when `Storage.InputValve` observes them, preventing a returned remainder from being counted twice.
- Confirm both output valves auto-close and become empty, the output stacker reaches its expected empty state, and relevant counters changed by expected amounts before completing the request.
- Release the reservation using a journaled completion transition that is safe across reloads; source-stack quantities were already removed at `Storage.OutputInValve`.
- A destination ID is retained in request state and completion events but does not control a physical route in version 1.

The final ledger transition must not subtract the requested quantity a second time: complete source stacks were already removed when admitted through `Storage.OutputInValve`, and returned remainders are restored later at `Storage.InputValve`. Completion releases the reservation and records `delivered_quantity` only.

The implementation must first verify output ordering, how `Output = -1` is re-armed, how changing `Setting` between full and final partial portions affects buffered resources, and which logic value selects splitter output 2. Splitter port direction itself is fixed and does not require calibration. Until this probe passes, output remains disabled with an explicit capability error.

## Inter-Chip Lua API

Use StationeersLua RPC for commands and point queries, and retained pub/sub for state changes. Target the controller by housing name `Storage.Controller`. All payloads and responses contain `api_version = 1`.

### `storage.request`

Request payload:

```lua
{
    api_version = 1,
    client_request_id = "console-unique-id",
    prefab_hash = -654790771,
    quantity = 100,
    destination_id = "main-console"
}
```

Immediate accepted response:

```lua
{
    ok = true,
    request_id = "controller-generated-id",
    state = "queued",
    reserved_quantity = 100
}
```

Rejected response uses `ok = false` and a stable code: `not_ready`, `invalid_request`, `unknown_resource`, `insufficient_stock`, `multi_silo_required`, `queue_full`, or `controller_faulted`. Repeating the same `client_request_id` from the same peer returns the original request instead of reserving twice.

### `storage.request_status`

Input is `{ api_version = 1, request_id = "..." }`. Return the request state, prefab hash, requested/reserved/delivered quantities, destination ID, timestamps/sequence, and any error code. Do not expose a request to an unrelated peer unless a future access policy enables it.

### `storage.cancel`

Cancel and release the reservation only while the request is `accepted` or `queued`. Active physical work returns `already_active`.

### `storage.get_state`

Accept optional pagination/filter fields. Return:

- Controller phase, readiness, fault, queue depths, active task, and scan progress.
- Aggregate free/assigned/faulted group counts.
- Resource totals: confirmed, reserved, and available quantities.
- Per-group assignment, quantity, state, and diagnostic summary when requested.
- API and controller schema versions.

Keep responses comfortably below the 128 KB network payload limit; paginate group/request details.

### `storage.get_config` and `storage.set_config`

Version 1 should expose read-only effective hardware mappings and operational limits. Mutating configuration is optional until the console requirements are known. Any future write API must validate the complete proposed configuration, persist it atomically, and refuse changes while movement is active.

### Pub/sub topics

- `storage/v1/state`: retained controller summary with a short TTL.
- `storage/v1/inventory`: retained aggregate inventory revision and totals.
- `storage/v1/request/<request_id>`: request transitions; non-retained or bounded TTL.
- `storage/v1/fault`: retained current fault, cleared by publishing `nil` after verified recovery.

RPC responses are authoritative; pub/sub is notification and cache-refresh signaling. Include an incrementing `state_revision` so clients can detect missed events.

## Persistence and Reload Safety

- Persist API schema version, request journal, reservations, quantity ledger, inventory revision, verified device-control values, and the last safe output checkpoint using `ic.persist` JSON.
- Persist before opening a valve or issuing a dispense action, and again after the observed result. Never persist on every idle tick.
- On reload, close all paths first and compare the journal checkpoint with valve-held items and device counters before resuming or failing an output request.
- Recover assignments from sorter memory even when persisted state disagrees.
- Keep completed request history bounded by count and age to remain within persistence limits.
- If persisted JSON is corrupt or a schema migration is unsupported, retain sorter assignments, block output, rebuild inventory through reconciliation, and report the persistence error.

## Diagnostics and Fault Handling

- Use stable error codes plus human-readable context containing group ID, device name/reference ID, expected value, and observed value.
- Aggregate startup topology errors.
- Publish phase and fault changes and write concise debugger logs; avoid per-tick logging.
- On any unsafe ambiguity, close all managed valves, set splitters to output 1, stop silo dispense commands, and preserve the active output journal.
- Distinguish `invalid_topology`, `capability_not_calibrated`, `inventory_mismatch`, `movement_timeout`, `device_error`, `persistence_error`, and `ledger_invariant` faults.
- Provide a read-only diagnostic snapshot through `storage.get_state` even while faulted.
- Do not implement a remote “clear fault” that merely erases state. Recovery must rerun the failed validation or reconciliation first.

## Required Implementation Probes

Run these against a small isolated test line before enabling normal operation:

- Verify the documented SDB silo memory decoder against empty, one-stack, mixed-stack, and 600-slot boundary cases.
- Verify that silo `Quantity` is occupied-stack count and that reading any occupied internal stack yields the resource's own `MaxQuantity` after the group stacker has normalized input. Test resources with several different maximum stack sizes and verify `slot_count * sampled_stack_quantity` against an exact scan.
- Verify `Dispense`, `DispenseSlot`, `Open`, `Activate`, and mode idle/one-shot behavior.
- Verify stacker Automatic mode with `Setting = 500` for resources whose `MaxQuantity` values are lower than 500; each emitted silo stack must equal the item's maximum rather than 500.
- Verify output stacker Logic mode, `Setting`, `Output` re-arm sequence, split ordering, and behavior when a request is below, equal to, and several times the resource's `MaxQuantity`. Confirm `Setting = 500` emits resource-limited full stacks and changing it for the final remainder emits the correct smaller last stack.
- Verify valve `Setting = 1`, one-item auto-close timing, persistent held-item inspection, local release state, and stuck-item detection.
- Verify that output 2 is the top/orthogonal port for both digital splitter orientations and determine only the logic value that selects output 1 versus output 2.
- Verify sorter instruction packing by round-tripping positive and negative prefab hashes and physically sorting test items.
- Establish which counters count stacks versus individual units and when they update.
- Measure conservative tick-based timeouts for every movement stage.

Record calibrated values as named constants near the top of the script. A failed probe must disable only the dependent capability when safe; output calibration failures disable output, while topology or valve failures disable all movement.

## Verification Strategy

The only planned test is `StorageControllerRequestTest.lua`. It requires one Lua chip on the controller's data network, with the following device labels:

- `Storage.Test.IronButton` and `Storage.Test.IronDial`
- `Storage.Test.SiliconButton` and `Storage.Test.SiliconDial`

Each rising button press submits `storage.request` to `Storage.Controller` for the corresponding ingot. The requested quantity is the nearest integer represented by its dial's `Setting`; zero and negative quantities are ignored. The client prints the accepted request ID/state or the stable rejection code returned by the controller.

The silo system is empty and currently unused. Until output hardware calibration is recorded, each valid press is expected to receive `capability_not_calibrated`; after calibration and stocking, it should receive `unknown_resource`, `insufficient_stock`, or a queued request according to controller state. No automated tests, fixture topology, or additional manual test scripts will be added.

## Implementation Steps

- [x] Create `StorageController.lua` with constants, enum aliases, safe device access wrappers, phase/error reporting, single-pass discovery, mandatory device configuration, and sorter-memory assignment recovery.
- [x] Implement input/fail-valve servicing, lowest-free assignment, in-memory ledger accounting, versioned persistence, request reservation, and the read-only RPC surface.
- [x] Add `StorageControllerRequestTest.lua` with iron and silicon button/dial controls as the sole planned test client.
- [ ] Run and document the required silo, per-resource maximum-stack, stacker, valve, splitter-control, and counter probes; verify fixed output-2 routing and confirm the documented output control sequence in-game.
- [x] Implement serialized output checkpoints at the closed output-input and output valves, with exact-quantity validation, valve timeouts, journal persistence, and fault-safe closure.
- [x] Implement the output scheduler plus post-ready bounded raw-memory scan; scanning runs only when output work is idle, checks at most the configured count, and resumes at its prior cursor.
- [ ] Implement incremental post-ready reconciliation and mismatch drain/return; verify every scanned stack matches assignment and quantity or the group is emptied and reassigned.
- [ ] Implement serialized physical output with resource-specific full portions and a smaller final portion, pending group-stacker export, assignment clearing, and output-2 remainder return; verify exact quantities across stack boundaries and all valve safe-state postconditions.
- [ ] Register RPC methods and pub/sub events; verify API version errors, pagination, state revisions, destination-ID round-trip, ownership checks, and payload bounds.
- [ ] Add concise operational logging and fault snapshots; verify every injected device error identifies the device, closes flow, and remains queryable.
- [ ] Add a minimal console/API example only after the controller API is stable; verify it can list inventory, submit a request, and follow request transitions without direct device access.

## Further Possible Improvements

### Strong candidates after version 1

- Support one resource across multiple silos with deterministic fill and drain order, per-group reservations, and aggregate fulfillment.
- Add inventory high/low watermarks and console-configurable keep-stock policies.
- Add a maintenance mode that pauses admission, drains in-flight items, and guarantees quiescence before hardware work.
- Add operator commands for rescan and verified fault recovery, guarded by phase and empty-path checks.
- Add request priorities below physical recovery/input safety priorities, with per-client fairness and bounded queue quotas.
- Add destination routing once physical destination selectors exist; retain the version-1 `destination_id` field for compatibility.
- Add a ScriptedScreens console using the same RPC/pub-sub API, with inventory, queue, reconciliation progress, and fault views.

### Reliability ideas added during planning

- Use client-provided idempotency keys to prevent duplicate deliveries after RPC retries.
- Journal intent before movement and observation after movement to make save/load behavior diagnosable.
- Expose monotonic inventory/state revisions so consoles can detect stale retained messages.
- Track expected versus observed device counters to catch uncommanded manual interaction.
- Optionally lock managed device controls after initialization and provide an explicit maintenance unlock procedure.
- Add a periodic lightweight invariant audit of labels, device presence, valve rest state, and ledger arithmetic without rescanning silo contents.
- Add queue backpressure and per-peer request limits to prevent one console or faulty chip from exhausting memory.
- Persist a compact recent event ring for post-fault diagnosis, bounded to avoid exceeding `ic.persist` limits.
- Add an offline simulation adapter for pure state-machine tests so queue, recovery, and reload edge cases can be exercised without moving real items.

### Deferred deliberately

- Multiple silos per resource.
- Multiple simultaneous output requests or destination-specific physical routing.
- Continuous full silo rescans during normal operation.
- Automatic trust of persisted assignments over sorter memory.
- Remote fault clearing without physical verification.
- Management of the external dump destination.
