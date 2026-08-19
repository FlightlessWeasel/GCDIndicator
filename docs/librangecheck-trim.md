# LibGCDI-RangeCheck: trimmed first-party fork of LibRangeCheck-3.0

## What

`Libs/LibGCDI-RangeCheck/LibGCDI-RangeCheck.lua` replaces the third-party
`Libs/LibRangeCheck-3.0/LibRangeCheck-3.0.lua` (upstream MIT, mitch0/WoWUIDev
Community, rev 34). It is a first-party fork, not a vendored dependency —
normal editing rules apply, unlike the remaining third-party libs listed in
`CLAUDE.md`.

## Why

GCDIndicator only ever called 3 of the upstream lib's 75 functions
(`LibGCDI-Range.lua`'s `get_range_check()`/`TryRangeWithLibRangeCheck`/
`IsUnitInRangeYardsLRC`): `lib:init()`, `lib:GetRange(unit, checkVisible,
noItems, maxCacheAge)`, and `lib:GetSmartMaxChecker(range, inCombat)`. The
other 40 functions (~600 of the file's ~5000 lines) were dead weight:

- The entire official `--@do-not-package@` debug/measurement block
  (`checkAllCheckers`, `checkAllItems`, `checkAllSpells`, `checkItems`,
  `checkItemsAtRange`, `checkSpells`, `cacheAllItems`, `speedTest`,
  `startMeasurement`, `stopMeasurement`, `updateMeasurements`,
  `logMeasurementChange`, `dumpCheckerList`, `pairsByKeys`) — upstream's own
  packager already strips this from released addons; GCDIndicator doesn't
  use that packager, so it was shipping in-game unused.
- The entire `Get*Checker` accessor family (`GetFriendChecker[s]`,
  `GetHarmChecker[s]`, `GetMiscChecker[s]`, `*MaxChecker`, `*MinChecker`,
  `*NoItems` variants, plus `GetSmartChecker`/`GetSmartMinChecker`) and their
  private helpers `getChecker`/`getMinChecker`/`rcIterator` — GCDIndicator
  only ever calls `GetSmartMaxChecker`.
- `lib:UNIT_AURA` / `lib:scheduleAuraCheck` — dead code even upstream:
  `UNIT_AURA` is never `RegisterEvent`'d anywhere in the file, so the handler
  can't fire.
- `lib:findSpellIndex`, `lib:getRangeAsString` — unused public debug/display
  helpers.
- `minItemChecker` — zero callers anywhere in the file.
- `resetRangeCache` — only caller was `speedTest`, removed with it.
- The `checker(unit) end` doc-only stub, `lib.CHECKERS_CHANGED`/
  `lib.MeleeRange` exports, the `lib.getRange` back-compat alias, and the
  `RegisterCallback`/`CallbackHandler-1.0` shim (nothing in GCDIndicator
  registers a callback; the internal `self.callbacks:Fire(...)` call this
  shim would have enabled is already guarded by `if changed and
  self.callbacks then`, so removing the shim just means that guard never
  passes — safe no-op, not a behavior change).

All of the above was verified via `codebase-memory` graph tracing
(`trace_path` outbound from `lib:init`/`lib:GetRange`/`lib:GetSmartMaxChecker`
to build the real transitive closure) cross-checked against `grep`, since the
graph can't see WoW's dynamic `self[event](...)` event dispatch or Lua
`self[method]` duck-typed calls — those were confirmed by hand from
`lib:activate`'s `RegisterEvent`/`RegisterUnitEvent` calls and `lib:OnEvent`.

**Not touched:** all class/spec spell-ID range data tables, `createCheckerList`
and its full call chain (`lib:init`'s bootstrap), the friend/harm/misc/res/pet
checker-list machinery, item-range request/caching (`initItemRequests`/
`processItemRequests`), and the real event/OnUpdate lifecycle
(`lib:activate`/`scheduleInit`/`OnEvent` + the 6 events that really are
registered: `CHARACTER_POINTS_CHANGED`, `SPELLS_CHANGED`,
`LEARNED_SPELL_IN_TAB`, `PLAYER_TALENT_UPDATE`, `CVAR_UPDATE`,
`UNIT_INVENTORY_CHANGED`). These are all still needed and were kept verbatim.

## API contract

Unchanged for the 3 methods GCDIndicator uses — `LibStub("LibGCDI-RangeCheck")`
in place of `LibStub("LibRangeCheck-3.0")`, same method signatures:

```lua
local rc = LibStub("LibGCDI-RangeCheck", true)
rc:init()
local minRange, maxRange = rc:GetRange(unit, checkVisible, noItems, maxCacheAge)
local checker = rc:GetSmartMaxChecker(range, inCombat)
```

`LibGCDI-Range.lua`'s `get_range_check()` is the only call site and was
updated to the new library name; nothing else in the repo references
`LibRangeCheck-3.0` by name. The persisted setting key
`settings.gcdSettings.useLibRangeCheck` and the function name
`lib:TryRangeWithLibRangeCheck` in `LibGCDI-Range.lua` were deliberately
**not** renamed — they're a per-profile SavedVariables key
(`LibGCDI-Profiles`-persisted) and renaming would silently reset existing
users' toggle state for no functional benefit.

## Re-diffing against upstream

If a future GCDIndicator feature needs one of the removed accessors (e.g.
`GetFriendMinChecker` for an out-of-melee-range check), the original is
recoverable from git history: `git log --diff-filter=D -- Libs/LibRangeCheck-3.0`
finds the commit that deleted it, and `git show <that commit>^:Libs/LibRangeCheck-3.0/LibRangeCheck-3.0.lua`
recovers the full pre-trim file — or diff against upstream directly from the
CurseForge page linked in the fork's header comment.
