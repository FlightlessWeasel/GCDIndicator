# Change Tracker — Experimental Native Stack Binding

## Status (2026-08-11 in-game testing): NOT WORKING — parked

Tested live on the user's 12.1 client. Findings, in order:
- Container creation, `AddAuraSlot` registration, and `initializeFrame` all fire
  correctly and match ArcUI's reference implementation exactly (verified by
  diffing every step against ArcUI's source, including call order for
  `SetApplicationBar` vs styling, `UpdateAllAuras()` for already-active buffs,
  button anchoring/strata, and orientation/reverse-fill copying).
- No Lua errors anywhere in the chain.
- Reads off the engine-bound `ArcBar` widget after binding (`GetSize`,
  `IsShown`, `GetMinMaxValues`) come back as secret/opaque values that poison
  any debug string built from them into `<SECRET>` — expected per the 12.1
  secret-value system, but it means we cannot introspect the bound widget's
  actual state from Lua at all.
- End result: the bar never shows a fill, confirmed at multiple stack counts
  (not just "too thin to see at 1 stack" — tested up to several stacks,
  completely blank every time).
- Conclusion: `SetApplicationBar`'s C-side fill-painting does not appear to be
  functional on this client/build, despite the API surface (`AddAuraSlot`,
  `SetApplicationBar`, etc.) existing and accepting calls without error.
  ArcUI's own source gates this feature behind specific PTR build numbers and
  repeatedly flags this exact API as inconsistent across 12.1 builds — this is
  consistent with that.

**Do not sink more time into this without a way to inspect the live client
directly** (no WoW client/Lua interpreter available in this dev environment).
If revisiting in a future session/patch, the fastest sanity check is whether
`SetDurationBar` (the duration-bar equivalent, not touched by this feature)
renders correctly on a test bar first — if that also doesn't paint, the whole
native-binding approach is off the table on this build regardless of what we
change here.

`configs.useNativeStackBinding` defaults to `false`; the classic
`C_UnitAuras`-based path (fixed earlier this session — spell-ID fallback +
CDM frame-pool staleness fix) is what's actually in use and confirmed working.


Tracks an experimental, toggleable feature so it can be fully undone in a future
session without needing to untangle it from unrelated work. Written 2026-08-11.

## What this is

An alternate (not a replacement) method of tracking buff stack counts, based on
how ArcUI does it: instead of polling `C_UnitAuras.GetPlayerAuraBySpellID` /
`GetUnitAuraBySpellID` and writing the result into our own StatusBar
(`gcdi_get_buff_stack_applications` + `gcdi_set_stack_bar_value`), it creates a
native `AuraContainer` frame (12.1+ engine type) and uses `AddAuraSlot` +
`SetApplicationBar` so the C-side engine drives the bar fill directly. This
sidesteps secret-value handling for stacks entirely, at the cost of being a much
newer, less-tested API surface (per ArcUI's own comments, some of this is
PTR-build-number sensitive).

**The old method is untouched and still the default.** This is purely an A/B
option for testing.

## How to toggle

- **Options UI**: Settings tab → "Experimental" section → "Use native engine
  stack binding (A/B test)" checkbox.
- **Slash command**: `/gcdopt nativestacks`
- Or set `GCDI.configs.useNativeStackBinding = true` at `GCDIndicator.lua:17`.

Default is `false` (classic/current method, unchanged behavior). Note: the
Settings tab is built once when the options frame is created and isn't rebuilt
on tab switch (matches the rest of that tab, e.g. the LibRangeCheck checkbox),
so if you flip the config via slash command while the panel is already open,
the checkbox won't visually update until you reopen the options window.

## Files touched

- **`GCDIndicator.xml`** (new file) — defines `GCDINativeStackButtonTemplate`, a
  virtual Button with a `StatusBar` (`parentKey="ArcBar"`) for the engine to own
  and drive via `SetApplicationBar`. Native AuraButtons get created from this
  template when `AddAuraSlot` fires.
- **`GCDIndicator.toc`** — added one line, `GCDIndicator.xml`, right before
  `GCDIndicator.lua` under the "Core addon" section, so the template loads
  before the Lua that references it.
- **`Libs/LibGCDI-Options/LibGCDI-Options.lua`** — added an "Experimental"
  section to the Settings tab (~after the Preview Mode section) with a
  checkbox bound to `configs.useNativeStackBinding`, calling
  `GCDI.rebuild_buff_bars()` on click.
- **`GCDIndicator.lua`**:
  - Line ~17: `useNativeStackBinding = false,` added to the `GCDI.configs` table
    (global toggle, not per-profile — matches `debugMode`'s precedent).
  - `-- EXPERIMENTAL: native AuraContainer/AddAuraSlot stack binding` block
    (~line 1489–1566, immediately before `create_buff_bar`): new functions
    `gcdi_ensure_native_stack_container(unit)`,
    `gcdi_setup_native_stack_slot(buffKey, data, catalogEntry)`,
    `gcdi_setup_all_native_stack_slots()`, and module-local
    `nativeStackContainers = {}`.
  - `rebuild_buff_bars` — one added call, `gcdi_setup_all_native_stack_slots()`,
    right after the bar-creation loop and before `update_all_buff_bars()`.
  - `update_buff_bar` — the stack-write block gained a
    `not data.nativeStackActive` guard so the classic write doesn't fight the
    engine-owned bar once a slot has bound successfully:
    ```lua
    if data.stackBar and GCDI.should_show_buff_stacks(buffID) and not data.nativeStackActive then
    ```
  - `SlashCmdList["GCDOPT"]` — new `elseif msg == "nativestacks" then` branch
    (~line 4210) that flips the config and calls `rebuild_buff_bars()`.

## How to fully revert

1. Delete the `-- EXPERIMENTAL: native AuraContainer/AddAuraSlot stack binding`
   block from `GCDIndicator.lua` (the four items listed above under that
   heading).
2. Remove the `gcdi_setup_all_native_stack_slots()` call from `rebuild_buff_bars`.
3. Remove the `and not data.nativeStackActive` clause from the stack-write
   condition in `update_buff_bar` (restores the original unconditional write).
4. Remove the `nativestacks` branch from `SlashCmdList["GCDOPT"]`.
5. Remove `useNativeStackBinding = false,` from `GCDI.configs`.
6. Delete `GCDIndicator.xml`.
7. Remove the `GCDIndicator.xml` line from `GCDIndicator.toc`.
8. Remove the "Experimental" section (checkbox + title + label + help text)
   from the Settings tab in `Libs/LibGCDI-Options/LibGCDI-Options.lua`.

## Known limitations / risks

- **Untested in-game.** No WoW client is available in this dev environment;
  verification here has been limited to `luaparse` syntax checks and AST-based
  scope diffing. Try this out of combat first.
- **Dangling slots on rebuild.** `clear_buff_bars()` calls `wipe(trackedBuffs)`,
  which discards each buff's `nativeStackActive` flag and bar reference, but
  does *not* tear down the native `AddAuraSlot` bindings already registered on
  `nativeStackContainers[unit]`. Toggling the option or rebuilding bars
  repeatedly will accumulate orphaned native slots for the session's lifetime
  (cleared on reload/relog). Not addressed yet — flagged here for later
  cleanup, per your "come back and clean this up later" note.
- **Combat-lockdown gated.** `gcdi_ensure_native_stack_container` refuses to
  create the container while `InCombatLockdown()` is true, since frame
  creation must happen in a clean (non-tainted) call path. If you toggle this
  on mid-combat, native slots simply won't bind until the next out-of-combat
  rebuild.
- **API maturity.** `AddAuraSlot`/`SetApplicationBar` are 12.1+ engine
  additions. A pre-existing code comment (predating this change, near the
  classic stack-lookup function) noted this approach was considered and
  rejected once before, reasoning that `AuraContainer`/`ApplicationBar` "cannot
  be used from tainted code." That's still true — this implementation only
  ever creates/wires the container from clean contexts (bar rebuild), never
  from inside `UNIT_AURA` — but confirm this holds if you find taint errors in
  combat logs.
- `CustomAuraContainerTemplate` (referenced in the `CreateFrame("AuraContainer",
  ...)` call) is a genuine Blizzard stock template, not something specific to
  ArcUI — confirmed used by other addons (e.g. Plater) and documented on
  Warcraft Wiki. Note per that same research: Blizzard is reworking
  `AuraContainer` in 12.1.0 toward a "ManagedAuraContainer" model on later PTR
  builds, so this API surface may shift again before 12.1 ships live.
