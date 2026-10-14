# AGENTS.md

## Verification

Requires a Lua 5.1 interpreter (`lua` on PATH). Run from the repository root:

```
lua tests\test_storage_controller_drain.lua
```

Exits 0 when all mocked regression tests pass. `lua -e "assert(loadfile('StorageController.lua'))"` checks syntax only.
