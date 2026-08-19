# Lua Test Harness

This document explains the `tests/` directory: what it is, why it's built the
way it is, what it covers, and how to extend it.

## Why not busted (like a "normal" WoW addon test setup)

The reference point for this setup is [BetterBags](https://github.com/Cidan/BetterBags),
which runs real `busted` tests against Lua 5.1 with WoW API mocks built from
Blizzard's vendored UI source. That requires a Lua 5.1 interpreter, LuaRocks,
and a C compiler (busted depends on `luafilesystem`, which is a compiled C
extension).

This dev machine has no C compiler and no admin rights for a system-wide
toolchain install (`choco`/`winget` both fail without elevation for anything
that needs one). Attempting `luarocks install luacheck` here fails at
`luafilesystem`'s build step with `'gcc' is not recognized...` — confirmed
directly, not assumed. So: no busted, no luacheck.

## What's actually running

- **Interpreter**: LuaJIT 2.1, installed via `winget install DEVCOM.LuaJIT`
  (no compiler needed, single MSI) into
  `C:\Users\jason\AppData\Local\Programs\LuaJIT\bin\luajit.exe`, copied to
  `~/bin/luajit.exe` (already on `PATH`) alongside its `lua51.dll` dependency.
  LuaJIT's `_VERSION` reports `"Lua 5.1"` and its semantics match stock Lua
  5.1 for everything these tests exercise — this is the same exception
  BetterBags' own `CLAUDE.md` carves out ("a 5.1-compatible LuaJIT 2.x, whose
  `_VERSION` is `"Lua 5.1"`").
- **Test framework**: `tests/framework.lua`, a ~90-line hand-rolled
  `describe`/`it`/`assertEqual`/`assertTrue`/`assertFalse`/`assertNil`/
  `assertDeepEqual` implementation. No dependencies — pcall-based, prints
  PASS/FAIL per test, tracks pass/fail counts.
- **Entry point**: `tests/runner.lua`. Asserts `_VERSION == "Lua 5.1"` before
  doing anything else (hard-fails on the wrong runtime, mirroring BetterBags'
  `spec/setup.lua` guard). Loads `tests/mocks/wow_api.lua` and
  `Libs/LibStub/LibStub.lua`, then `dofile`s each spec listed in its
  `SPEC_FILES` manifest. **Spec discovery is a static list, not a directory
  scan** — stock Lua 5.1 has no filesystem listing API (that's normally
  `lfs`, the same compiled extension we can't build), so new spec files must
  be added to `SPEC_FILES` by hand.
- **Mocks**: `tests/mocks/wow_api.lua`. Loaded *before* any addon/Lib file,
  because several of them cache WoW globals into upvalues at chunk-load time
  (e.g. `LibGCDI-Range.lua`'s `local UnitExists = UnitExists`) — a global that
  doesn't exist yet when the chunk loads never gets picked up later, so
  load order here is load-bearing, not cosmetic.

Run from the repo root:

```
luajit tests/runner.lua
```

Exits non-zero if any test fails.

## What's covered

Only the first-party `Libs/*` modules whose logic is pure table manipulation
with no frame/widget dependency:

- `LibGCDI-Catalog` (`tests/spec/catalog_spec.lua`) — `GetAllOrdered`,
  `GetEnabledOrdered`, `MoveInOrder`, `MoveToBottom`.
- `LibGCDI-Profiles` (`tests/spec/profiles_spec.lua`) — `deepcopy` (including
  the cycle-safety and frame/function-skipping behavior), the compact
  serialize/deserialize round-trip, and `SaveProfile`/`LoadProfile`/
  `DeleteProfile`/`GetProfileNames`/`ExportSettings`/`ImportSettings`.
- `LibGCDI-Range` (`tests/spec/range_spec.lua`) — only the settings-table
  logic (`GetRangeFallbackYards`, `IsSpellSelfCast`, `HasRangeOverride`,
  `HasNativeRangeSetting`). `UpdateRangeIndicators`, `DetectNativeRangeForSpells`,
  and `AutoDetectSelfCast` touch live WoW state (`UnitExists`, `C_Spell`,
  `IsActionInRange`, frame `Show`/`Hide`) and are **not** covered.

## What's not covered, and why

`GCDIndicator.lua` (~4500 lines) and `LibGCDI-Options.lua` (~3100 lines) are
not touched by this harness. Both are built almost entirely around
`CreateFrame`, the update ticker, and Blizzard event/API calls
(`C_CooldownViewer`, `C_Spell`, `UNIT_AURA`, native `AuraContainer` bindings).
Mocking that surface faithfully — especially the CDM frame-pool reuse
semantics and Secret Value behavior documented in `CLAUDE.md`'s "Critical
constraints" — is a much larger undertaking than the four `Libs/*` modules
above, and doing it badly (an inaccurate mock that addon code gets bent to
satisfy) would actively work against the "mocks are the contract" rule in
`CLAUDE.md`. These files are still checked only via `check.js`/`scope.js` plus
manual reasoning and user in-game testing.

## Extending this

1. New pure-logic function in an already-mocked `Libs/*` file: add an `it()`
   to the existing spec file, following the pattern of writing the test
   first, confirming it fails, then implementing (per `CLAUDE.md`'s
   "Test-first" directive).
2. New spec file: add it to `tests/runner.lua`'s `SPEC_FILES` list.
3. Need a WoW API this doesn't stub yet: verify the API's real signature and
   return semantics first (via the `wow-addon-architect` agent or
   `warcraft.wiki.gg` — never guess), then add it to
   `tests/mocks/wow_api.lua` with a comment noting what was verified.
4. Considering coverage for `GCDIndicator.lua`/`LibGCDI-Options.lua`: this is
   a real scope increase (frame mocking, CDM pool semantics, Secret Value
   handling) — flag it to the user and plan the mock surface deliberately
   rather than bolting on ad hoc stubs.
