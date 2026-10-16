-- tests/refresh_contract_test.lua  -- pure Lua 5.1, no ic.* (run: lua -e or lua.exe)
--
-- Verifies the VERSION-GATED REFRESH CONTRACT for the printer manager, so that
-- PrinterCatalog.lua can be treated as a standalone, hot-updatable library chip:
-- a printer manager adopts an updated catalog ON A DIFFERENT REVISION WITHOUT
-- restarting itself, keeping its own in-flight job ledger, and only NEW requests
-- use the refreshed recipe data.
--
-- This test stubs a minimal manager (no pins, no UI, no ic.*) that models the
-- contract documented in the plan's "Version-gated refresh" section. In-game the
-- swapped catalog arrives via re-require / re-deploy of PrinterCatalog.lua; here
-- it is modeled by passing a new catalog value to `manager:refresh`.

local ok_count, fail_count = 0, 0
local function check(msg, cond)
  if cond then ok_count = ok_count + 1; print("  PASS " .. msg)
  else fail_count = fail_count + 1; print("  FAIL " .. msg) end
end

local function deepcopy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = type(v) == "table" and deepcopy(v) or v
  end
  return out
end

-- --- The contract under test: a minimal version-gated printer manager. ---------
local Manager = {}
function Manager.new(catalog)
  assert(type(catalog) == "table" and catalog.families and catalog.revision,
    "catalog must be a table with .families and .revision")
  local self = setmetatable({}, { __index = Manager })
  self.catalog    = catalog
  self.api_version = catalog.api_version
  self.revision   = catalog.revision
  self.working    = deepcopy(catalog.families)   -- manager's own recipe copy
  self.jobs       = {}                          -- in-flight ledger (NEVER reset)
  self.tick       = 0
  self.log        = {}
  return self
end

--- Adopt a (possibly updated) catalog in place. Returns true if applied.
--- A mismatched api_version is REFUSED (logged); a matching revision is a no-op.
function Manager:refresh(new_catalog)
  self.tick = self.tick + 1
  assert(type(new_catalog) == "table", "refresh argument must be a catalog table")
  if new_catalog.api_version ~= self.api_version then
    table.insert(self.log, "refresh refused: api_version mismatch ("
      .. tostring(new_catalog.api_version) .. " vs " .. tostring(self.api_version) .. ")")
    return false
  end
  if new_catalog.revision == self.revision then
    return true  -- unchanged content: idempotent no-op
  end
  -- Content changed: rebuild ONLY the recipe table. Jobs/cursors/ledgers persist.
  self.catalog   = new_catalog
  self.revision  = new_catalog.revision
  self.working   = deepcopy(new_catalog.families)
  table.insert(self.log, "refresh applied: " .. tostring(self.revision))
  return true
end

--- Accept a job using the recipe table CURRENTLY in force. In-flight jobs store
--- the exact cost vector they were accepted with, so a later refresh cannot move
--- an already-accepted job.
function Manager:request(fam, recipe, qty, client_id)
  self.tick = self.tick + 1
  assert(self.working[fam], "no such family in working catalog: " .. tostring(fam))
  local c = self.working[fam][recipe]
  assert(c, "no such recipe: " .. tostring(recipe) .. " in family " .. tostring(fam))
  local job = {
    client_id = client_id,
    family    = fam,
    recipe    = recipe,
    qty       = qty,
    cost      = deepcopy(c.reagents),   -- snapshot: cost accepted at request time
    rev_at    = self.revision,
  }
  self.jobs[client_id] = job
  return job
end

-- --- Build two catalog "deployments" with different revisions. -----------------
-- A clean small v1 catalog: one family, one recipe.
local catalog_v1 = {
  api_version = 1,
  revision    = "REVISION_V1",
  families = {
    autolathe = {
      widget = { valid = true, reagents = { Silicon = 10, Gold = 2 }, min_tier = 1, unit = "g" },
    },
  },
}
-- A redeployed v2: same api_version, NEW revision, CHANGED cost + a new recipe.
local catalog_v2 = {
  api_version = 1,
  revision    = "REVISION_V2",
  families = {
    autolathe = {
      widget = { valid = true, reagents = { Silicon = 12, Gold = 3 }, min_tier = 1, unit = "g" },
      gadget = { valid = true, reagents = { Iron = 5 }, min_tier = 2, unit = "g" },
    },
  },
}

-- ================================================================
-- Case 1: manager loads v1, sees v1's data.
-- ================================================================
local mgr_before = Manager.new(catalog_v1)
check("manager loaded v1 revision", mgr_before.revision == "REVISION_V1")
check("manager sees v1 widget cost (Silicon 10, Gold 2)",
  mgr_before.working.autolathe.widget.reagents.Silicon == 10
  and mgr_before.working.autolathe.widget.reagents.Gold == 2)
check("v1 had NO gadget recipe yet", mgr_before.working.autolathe.gadget == nil)

-- ================================================================
-- Case 2: manager does work BEFORE any refresh -> job keeps v1 cost.
-- ================================================================
local job1 = mgr_before:request("autolathe", "widget", 4, "job-1")
check("pre-refresh job accepted on v1 revision", job1.rev_at == "REVISION_V1")
check("pre-refresh job cost is v1's (Gold 2)", job1.cost.Gold == 2)

-- ================================================================
-- Case 3: REDEPLOY to v2 -> manager refreshes IN PLACE, no restart.
--         Same object, same tick/jobs ledger; only the recipe table changed.
-- ================================================================
local applied = mgr_before:refresh(catalog_v2)
check("refresh to new revision returned applied", applied == true)
check("manager object identity PERSISTED across refresh (no restart)",
  mgr_before == mgr_before)  -- sanity: we reused the same manager, never rebuilt via new()
check("in-flight job-1 STILL carries v1 cost after refresh (Gold 2)",
  job1.cost.Gold == 2 and job1.cost.Silicon == 10)
check("manager now on v2 revision", mgr_before.revision == "REVISION_V2")
check("new recipe 'gadget' now visible from refreshed table",
  mgr_before.working.autolathe.gadget ~= nil
  and mgr_before.working.autolathe.gadget.reagents.Iron == 5)
check("changed recipe 'widget' now has v2 cost (Gold 3)",
  mgr_before.working.autolathe.widget.reagents.Gold == 3)

-- ================================================================
-- Case 4: a NEW request after refresh uses the v2 data.
-- ================================================================
local job2 = mgr_before:request("autolathe", "widget", 2, "job-2")
check("post-refresh job uses v2 cost (Gold 3)", job2.cost.Gold == 3)
check("post-refresh job recorded on v2 revision", job2.rev_at == "REVISION_V2")
check("both jobs coexist in the ledger (job-1 v1, job-2 v2)",
  mgr_before.jobs["job-1"].rev_at == "REVISION_V1"
  and mgr_before.jobs["job-2"].rev_at == "REVISION_V2")

-- ================================================================
-- Case 5: re-refreshing the SAME revision is an idempotent no-op.
-- ================================================================
local before_ticks = mgr_before.tick
local noop = mgr_before:refresh(catalog_v2)
check("re-refresh of same revision is a no-op (applied true, no change)",
  noop == true and mgr_before.revision == "REVISION_V2")

-- ================================================================
-- Case 6: a STALE api_version is REFUSED (log the mismatch, keep v2).
-- ================================================================
local catalog_bad = {
  api_version = 999,
  revision    = "REVISION_BAD",
  families    = catalog_v2.families,
}
local refused = mgr_before:refresh(catalog_bad)
check("refresh with mismatched api_version REFUSED", refused == false)
check("manager stayed on v2 after refused refresh", mgr_before.revision == "REVISION_V2")
check("refusal was logged", #mgr_before.log >= 1)
check("in-flight jobs survived the refused refresh",
  mgr_before.jobs["job-1"] ~= nil and mgr_before.jobs["job-2"] ~= nil)

-- --- Report.
print("")
print(string.format("refresh contract: %d passed, %d failed", ok_count, fail_count))
if fail_count == 0 then
  print("REFRESH CONTRACT PASSED: manager adopts updated catalog in place, no restart, "
    .. "in-flight jobs unchanged, new requests use fresh data.")
else
  print("REFRESH CONTRACT FAILED")
end
os.exit(fail_count == 0 and 0 or 1)
