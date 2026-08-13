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

---

# Change Tracker — Compact Mode Layout

## Status (2026-08-12): toggleable, not yet tested in-game

Tracks a toggleable feature so it can be fully undone in a future session
without needing to untangle it from unrelated work. Written 2026-08-12.

## What this is

An alternate layout for spells, items, and buffs. Instead of stacking entries
into 3 fixed vertical columns (spells+items in their own block, buffs in a
separate block below), compact mode treats spells, items, AND buffs as one
continuous left-to-right flow — buffs do not start a new section, they just
keep flowing right after the last spell/item box. A row wraps once it would
exceed 200px (the same width as the resource bars, so the HUD doesn't get
wider — only shorter), with a fixed 2px gap between every adjacent box.
Compact mode also drops the icon square from every spell/item/buff box
entirely (not just hidden — the box shrinks by that width too), so only the
cooldown-clip/active-indicator square and its extras (range, charges, stacks,
etc.) remain. `configs.size`/`.barHeight`/`.bgPadding` themselves are
unchanged — no icon means less width per box, not smaller icons. The GCD row
and resource bars are untouched.

**The old 3-column layout (with icons) is untouched and still the default.**
This is purely an alternate arrangement, off by default.

Persists per-character via `GCDIndicator_Settings` (`settings.compactMode`,
SavedVariablesPerCharacter) — survives `/reload` and logout, shared across
all profiles/specs on that character (not per-profile, not account-wide).

## How to toggle

- **Options UI**: Settings tab → "Experimental" section → "Compact layout
  (flow spells/items and buffs left-to-right)" checkbox.
- **Slash command**: `/gcdopt compact`
- Or set `GCDI.configs.compactMode = true` at `GCDIndicator.lua:18` (session-only;
  won't survive reload unless `settings.compactMode` is also set — see above).

Default is `false` (classic 3-column layout with icons, unchanged behavior).
Note: the Settings tab is built once when the options frame is created and
isn't rebuilt on tab switch, so if you flip the config via slash command
while the panel is already open, the checkbox won't visually update until you
reopen the options window. The Settings tab is now a `ScrollFrame` (it wasn't
before — content used to silently clip past the bottom edge once enough
sections existed).

Because box layout (icon present/absent) is baked in at spell/item/buff
*creation* time, not just position, toggling calls a full rebuild
(`rebuild_spell_bars()` + `rebuild_buff_bars()`), not just `reposition_all()`.

## Files touched

- **`GCDIndicator.lua`**:
  - Line ~18: `compactMode = false,` added to the `GCDI.configs` table
    (global toggle, not per-profile — matches `useNativeStackBinding`'s
    precedent).
  - `init()` (~line 3696): bootstraps `configs.compactMode` from
    `settings.compactMode` on load/profile-init (persistence).
  - `reposition_all()` (~line 2495-2745): the spells+items+buffs positioning
    is wrapped in `if configs.compactMode then <single merged shelf-packing pass> else <original 3-column code, unchanged> end`.
    The compact branch builds one combined list (spells+items, then buffs, in
    existing order) and packs it in a single continuous pass — no separate
    buff section/Y restart.
  - `create_spell_bar` (~line 817), `create_item_bar` (~line 1094),
    `create_buff_bar` (~line 1643): each reads `configs.compactMode` and, if
    true, hides the icon texture and excludes its width from the container
    (the cooldown-clip/active-indicator square anchors directly at `pad`
    instead of after the icon). The icon texture object is still created
    either way (icon-change detection in `create_spell_bar` reads/writes it
    regardless of mode).
  - `SlashCmdList["GCDOPT"]` — `elseif msg == "compact" then` branch
    (~line 4362): flips the config, persists it to `settings.compactMode`,
    and calls `rebuild_spell_bars()` + `rebuild_buff_bars()`.
- **`Libs/LibGCDI-Options/LibGCDI-Options.lua`**:
  - Settings tab (~line 2818) converted to a `ScrollFrame` (was a plain fixed
    `Frame` before — content past the bottom edge was silently clipped, not
    scrollable). `optionsFrame.settingsScrollFrame` is the new shown/hidden
    handle; `optionsFrame.settingsFrame` is now the scroll child that all
    Settings-tab widgets are still parented to (unchanged from their
    perspective). `switch_tab()` updated to show/hide the scroll frame.
  - Checkbox + label + help text in the "Experimental" section, bound to
    `configs.compactMode`, persists to `settings.compactMode`, calls
    `GCDI.rebuild_spell_bars()` + `GCDI.rebuild_buff_bars()` on click.
- **`../AHK/GuardianDruid_Apexless.ahk`** — `CompactMode` global +
  `Ctrl+Alt+M` hotkey (not `Ctrl+Alt+C` — that combo is already used by
  `lib/PixelMonitor.ahk`'s CheckPixel debug UI).
- **`../AHK/lib/PixelMonitor.ahk`** — mirrors both the merge and the icon
  removal:
  - `CalculateBuffBaseY()`'s compact branch now builds one combined list from
    `SpellList` + `BuffList` and packs it in a single `PackCompactRow` call
    (via a `CalculateCompactEntryWidth` dispatcher), then splits the result
    back into `CompactSpellPositions`/`CompactBuffPositions` caches — mirrors
    the addon's single merged pass exactly.
  - `CalculateCompactSpellWidth`/`CalculateCompactBuffWidth` no longer add
    the icon square's width (`barSize` alone instead of `barSize*2+2`).
  - `GetBoxXOffset`/`GetBuffBoxXOffset`/`GetPandemicXOffset` (the compact-mode
    box-position helpers) now anchor off `SpellIconX`/`BuffIconX` (the icon's
    old position formula) instead of `SpellBoxStartX`/`BuffActiveX` — since
    the icon square is gone, the first indicator box takes its old slot.
  - `ShowPixelMarkers()`'s green fixed-column corner-boundary grid (`Ctrl+Alt+L`
    debug overlay) is skipped entirely in compact mode — it assumed the old
    3-column layout and would otherwise be actively misleading. The per-box
    dot markers themselves are unaffected (already read from `CheckPixels`,
    which is fully compact-mode-aware).
  - The other 5 rotation scripts that `#Include` `PixelMonitor.ahk` never
    flip `CompactMode`, so they're unaffected.

## How to fully revert

1. Remove the `compact` branch from `SlashCmdList["GCDOPT"]` in
   `GCDIndicator.lua`, and the `configs.compactMode` bootstrap line in
   `init()`.
2. In `reposition_all()`, remove the `if configs.compactMode then ... else`
   wrapper, keeping only the original (`else`) 3-column code.
3. In `create_spell_bar`/`create_item_bar`/`create_buff_bar`, remove the
   `compact`/icon-hiding branches, restoring the icon square unconditionally.
4. Remove `compactMode = false,` from `GCDI.configs`.
5. Remove the "Compact Mode" checkbox/label/help-text block from the Settings
   tab in `Libs/LibGCDI-Options/LibGCDI-Options.lua`. Reverting the Settings
   tab's ScrollFrame conversion is optional (it's a strict improvement even
   without compact mode) but if desired, restore it to a plain `Frame` and
   revert `switch_tab()`'s `settingsScrollFrame` reference back to
   `settingsFrame`.
6. On the AHK side: remove the `CompactMode` global and `Ctrl+Alt+M` hotkey
   from `GuardianDruid_Apexless.ahk`, and remove all `CompactMode`-related
   additions from `lib/PixelMonitor.ahk` (`CalculateCompactEntryWidth`,
   `CalculateCompactSpellWidth`, `CalculateCompactBuffWidth`,
   `PackCompactRow`, the `_Offset` box-position helpers, the `CompactMode`
   branches inside `GenerateCheckPixels()`/`CalculateBuffBaseY()`/
   `ShowPixelMarkers()`).

## Known limitations / risks

- **Untested in-game.** No WoW client is available in this dev environment;
  verification here has been limited to `luaparse` syntax checks and AST-based
  scope diffing, plus a manual hand-trace of the packing algorithm. Try this
  out of combat first.
- **AHK sync is manual and required.** Turning compact mode on in the addon
  without also turning it on in the AHK script (or vice versa) silently
  desyncs every pixel read for spells/items/buffs (wrong `CanCast`/stack
  reads, not a crash) — same consequence any layout change has per this
  repo's `CLAUDE.md`.
- **`trackIcon`/duration-bar mapping is inferred, not confirmed.** Initial
  planning flagged `trackIcon` (`should_track_spell_icon()` in
  `GCDIndicator.lua`, opt-in per spell) and buff duration bars
  (`showDurationBar`) as having no AHK equivalent. While implementing the
  compact-mode width formulas, the box ordering in `GenerateCheckPixels()`
  turned out to line up exactly: AHK's `hasProc` flag sits in the same slot
  right after range/charges that Lua's icon-change indicator occupies, and
  AHK's `hasPandemic` flag sits in the same slot right after stacks that
  Lua's duration-bar indicator occupies. `CalculateCompactSpellWidth`/
  `CalculateCompactBuffWidth` in `lib/PixelMonitor.ahk` treat them as
  equivalent on that basis. This is a structural inference (matching slot
  order + matching visual purpose - a color-flash indicator), not something
  confirmed by testing (no live client). If a tracked spell/buff's box
  positions look off in compact mode, check whether it has `trackIcon`/
  `showDurationBar` enabled on the addon side and `hasProc`/`hasPandemic` set
  to match on the AHK `SpellList`/`BuffList` entry - if the mapping is wrong,
  every box after it in that row will be misaligned.
