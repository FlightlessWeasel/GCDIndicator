> **Removed (2026-08-18):** the experimental native `AuraContainer`/
> `AddAuraSlot` stack-binding A/B toggle (`useNativeStackBinding`) was pulled
> out — confirmed not working on the 12.1 test client (`SetApplicationBar`
> never painted a fill), parked, then deleted along with `GCDIndicator.xml`,
> its Settings checkbox, and its slash command.

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

- **Options UI**: Settings tab → "Layout & Export" section → "Compact layout
  (flow spells/items and buffs left-to-right)" checkbox.
- **Slash command**: `/gcdopt compact`
- Or set `GCDI.configs.compactMode = true` at `GCDIndicator.lua:18` (session-only;
  won't survive reload unless `settings.compactMode` is also set — see above).

Default was `false` (classic 3-column layout with icons) until the Batch 4
default-flip below changed it to `true`. Which layout counts as "unchanged
behavior" for a fresh install has therefore flipped too — see that entry.
The Settings tab is now a `ScrollFrame` (it wasn't before — content used to
silently clip past the bottom edge once enough sections existed); its
checkbox states also now re-sync on tab switch/refresh (see the native stack
binding section above), so flipping this config via slash command while the
panel is open no longer requires reopening it.

Because box layout (icon present/absent) is baked in at spell/item/buff
*creation* time, not just position, toggling calls a full rebuild
(`rebuild_spell_bars()` + `rebuild_buff_bars()`), not just `reposition_all()`.

## Files touched

- **`GCDIndicator.lua`**:
  - Line ~18: `compactMode = false,` originally added to the `GCDI.configs`
    table (global toggle, not per-profile — matches `useNativeStackBinding`'s
    precedent). Default flipped to `true` in Batch 4 — see that entry below.
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
  - Checkbox + label + help text in the "Layout & Export" section, bound to
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
4. Remove `compactMode = true,` (originally `false`, flipped in Batch 4 — see
   that entry) from `GCDI.configs`.
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

---

# Change Tracker — Compact Mode Default Flip (Batch 4)

## What changed

`GCDI.configs.compactMode` at `GCDIndicator.lua:18` changed from `false` to
`true`. This is a plain default-value change, not a new toggle or feature —
the compact-mode feature itself (see the "Change Tracker — Compact Mode
Layout" entry above) is unchanged and remains fully toggleable via the
Settings tab checkbox, `/gcdopt compact`, or `GCDI.configs.compactMode`
directly.

## Why

All 11 shipped companion-script spec profiles already default their own
compact-mode setting to `true` (confirmed separately from this addon repo).
A fresh addon install previously defaulted to `compactMode = false`, which
mismatched every one of those profiles' assumption out of the box — the
addon side was the drift, not the companion scripts, so the addon default was
brought in line with what the companion scripts already assume.

## Files touched

- **`GCDIndicator.lua:18`** — `compactMode = false,` → `compactMode = true,`
  in the `GCDI.configs` table.
