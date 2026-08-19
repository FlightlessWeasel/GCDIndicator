# GCDIndicator optimization pass — session notes

**Date:** 2026-08-11
**Branch:** `12.1-optimized` (branched off `12.1-Start`)
**HEAD:** `c8564ce` — "Cut per-frame work: phase the update ticker, cache range lookups"
**Uncommitted:** `Libs/LibGCDI-Options/LibGCDI-Options.lua` (widget pooling — see "Where I stopped")

> ⚠️ **Nothing here has been tested in-game.** No WoW client and no Lua interpreter were
> available. Verification was limited to (a) `luaparse` syntax checks and (b) differential
> scope analysis — parsing git-HEAD and working-tree versions and diffing the set of
> unresolved globals to prove no new globals appeared and none were dropped. That catches
> typos and missing locals. It does **not** catch runtime/API/visual regressions.

---

## Branch layout

| Branch | Contents |
|---|---|
| `12.1-Start` | Pre-optimization snapshot. Range check via LibRangeCheck-3.0, absorb/prediction bars. Pushed to origin. |
| `12.1-optimized` | All optimization work. **Not pushed.** |

---

## Committed in `c8564ce`

### 1. Ticker restructure (the big one)

Old: `C_Timer.NewTicker(0.015, ...)` ran *everything* every tick. At 60fps that's every
single frame, and it did range checks, icon updates, mob counts and dispel scans in that
window.

New: one 20 Hz ticker with phased work, in `GCDIndicator.lua`:

```lua
local TICK_INTERVAL = 0.05
local tickCount = 0
C_Timer.NewTicker(TICK_INTERVAL, function()
	tickCount = tickCount + 1
	-- 20 Hz
	animate_item_bars()
	update_charge_indicators_tick()
	-- 10 Hz
	if tickCount % 2 == 0 then update_range_indicators(); update_stagger_bar() end
	-- 5 Hz
	if tickCount % 4 == 0 then pcall(update_mob_count_indicator); update_spell_icons() end
	-- 2 Hz safety polls (event-driven paths are primary)
	if tickCount % 10 == 0 then
		update_gcd(); update_all_buff_bars(); update_item_charge_indicators()
		pcall(update_dispel_indicator)
	end
	-- 0.2 Hz
	if tickCount % 100 == 0 then detect_native_range_for_spells(); tickCount = 0 end
end)
```

**If something feels laggy in game, this is the first thing to retune** — bump a divisor
down rather than lowering `TICK_INTERVAL`.

### 2. Dead library deletion (~1180 lines)

`git rm -r`'d, all four were fully reimplemented inline in `GCDIndicator.lua`:

- `Libs/LibGCDI-Resources/` — was `LibStub`'d but never called
- `Libs/LibGCDI-Bars/` — same
- `Libs/LibGCDI-Scanner/` — same
- `Libs/LibGCDI-Detector/` — wasn't even in the `.toc`

`GCDIndicator.toc` had 3 load lines removed. Library refs in `GCDIndicator.lua` reduced to
`LibProfiles` and `LibRange`.

**`RESOURCE_COLORS`:** two copies existed and had drifted. Kept the fuller 21-entry table
already at `GCDIndicator.lua:99`; the stale 20-entry copy (missing `stagger`) went away with
`LibGCDI-Resources.lua`. No move needed.

### 3. `LibGCDI-Range` — hottest path (MINOR bumped 4 → 5)

- Lazy `LibRangeCheck-3.0` resolution via `get_range_check()` (resolved once, cached).
- `spellHasRangeCache` / `spellMaxRangeCache` — `GetSpellInfo().maxRange` was being called
  per spell per tick. New `lib:InvalidateSpellRangeCache()` clears both.
- Dirty-checking: `set_range_shown()` / `set_range_color()` compare against
  `spellData.rangeShownState` / `spellData.rangeColorState` and early-return, so no
  redundant `Show`/`Hide`/`SetColorTexture` calls.
- `lib:ResetIndicatorState()` clears both per-spell caches (used by the preview path, below).
- `UpdateRangeIndicators` hoists `getSettings()`, `useLRC`, `InCombatLockdown()` and
  `UnitExists("target")` above the loop.

### 4. `GCDIndicator.lua` — allocation & complexity

- **Charge spell list cached.** `chargeSpellIDList` + `chargeSpellIDListDirty`, rebuilt lazily
  by `gcdi_charge_spell_id_list()`. Was allocating a fresh table + sorting every tick.
  Invalidated at the end of `create_spell_bar` and in `clear_spell_bars`.
- **Action slot map.** Replaced an O(180 × N) rescan with an O(180 + N) map:
  `actionSlotBySpell` + `actionSlotMapDirty`, `gcdi_rebuild_action_slot_map()` (one pass over
  slots 1..180, indexing base *and* override IDs), `GCDI.get_action_slot_for_spell(spellID)`.
- **Stagger spec cached** — `staggerIsBrewmaster`, `gcdi_refresh_stagger_spec()`,
  `resourceBars.stagger.staggerParked`.
- **Closures hoisted to file scope** (were being re-created per call): `gcdi_read_applications`,
  `apps_from_aura`, `aggro_safe_bool`, `aggro_safe_tonumber`. (The classic dispel-scan closures
  that used to be listed here — `gcdi_scan_dispellable_by_index`, `gcdi_dispel_scan_hit`,
  `gcdi_dispel_aura_visitor`, `gcdi_scan_dispellable_foreach` — no longer exist; the dispel
  indicator moved to a native engine-owned overlay with no per-tick Lua scan at all. See
  `docs/dispel-indicator.md`.)
- **Disabled resources skipped** — `RESOURCE_UPDATERS` is now an array of `{key, fn}` pairs;
  `update_all_resources` consults `gcdi_is_resource_enabled` (also exported as
  `GCDI.is_resource_enabled`) instead of running every updater unconditionally.
- **`data.lastSeparatorMax` guards** — early return in `update_charge_bar`,
  `update_combo_points_bar`, `update_runes_bar` when separator count is unchanged.
- **`scan_action_bars`** no longer calls `rebuild_item_bars()` (already done inside
  `rebuild_spell_bars`).

### 5. New event-driven invalidation (`on_event`)

| Event | Action |
|---|---|
| `ACTIONBAR_SLOT_CHANGED`, `UPDATE_MACROS` | invalidate slot map |
| `UPDATE_SHAPESHIFT_FORM`, `UPDATE_BONUS_ACTIONBAR` | invalidate slot map |
| `SPELLS_CHANGED` | invalidate slot map + `LibRange:InvalidateSpellRangeCache()` |
| `PLAYER_SPECIALIZATION_CHANGED` | both of the above + `gcdi_refresh_stagger_spec()` |

`schedule_update_all_buff_bars_after_aura` now also calls `update_spell_icons()`.

### 6. ⚠️ Preview-mode interaction — do not remove

Dirty-checking broke preview mode, because preview writes textures **directly**, bypassing
the caches. Leaving preview would strand preview colors on screen. The fix is an explicit
invalidation block on the preview-off path:

```lua
LibRange:ResetIndicatorState()
for _, data in pairs(trackedBuffs) do data.active = nil; data.durationArmedFor = nil end
if resourceBars.stagger then resourceBars.stagger.staggerParked = nil end
main_frame.mobCountState = nil
main_frame.dispelState = nil
gcdi_invalidate_charge_spell_list()
```

**Any new dirty-check must add its reset here.**

---

## Uncommitted: options UI widget pooling

`Libs/LibGCDI-Options/LibGCDI-Options.lua` — **written, syntax-checked, not committed.**

**The bug it fixes:** WoW never garbage-collects Frames/FontStrings/Textures. `SetParent(nil)`
only orphans them. Every tab refresh built a fresh widget tree and dropped the old one, so
each refresh permanently leaked a tree — and refresh runs on tab switch, on rescan, on profile
load, and after most checkbox clicks.

**Design:** pool keyed by `(kind, template)`. Position-independent, because every call site
fully reconfigures what it gets (size, anchor, text, scripts).

Infrastructure at `LibGCDI-Options.lua:49-173`:

| Symbol | Line | Role |
|---|---|---|
| `pooledHost` | 49 | hidden parent for released widgets |
| `POOL_SCRIPTS` | 56 | 18 script handlers cleared on release |
| `activeTrackList` | 65 | auto-registers acquires to the current tab's list |
| `pool_take(key)` | 67 | |
| `pool_register(w)` | 77 | |
| `acquire_frame(kind, parent, template)` | 84 | key `"F\t"..kind.."\t"..template` |
| `acquire_fontstring(parent, layer, template)` | 99 | key `"S\t"..layer.."\t"..template` |
| `acquire_texture(parent, layer)` | 117 | key `"T\t"..layer` |
| `release_widget(w)` | 135 | non-pooled widgets fall back to `Hide` + `SetParent(nil)` |
| `reset_track_list(list)` | 166 | release all → wipe → set as active |

All 6 refresh functions now open with `reset_track_list(...)`:
lines **280** (gcd), **772** (resources), **919** (spells), **1368** (items), **1605** (buffs),
**2461** (profiles). `track()` is now a pass-through no-op kept for call-site readability.

**⚠️ Double-free guard:** `spellRows` / `itemRows` / `buffRows` are only `wipe()`d, never
released. The tab element list is the sole owner of those trees. Releasing both would return
the same widget to the pool twice and hand it to two call sites.

**One special case** (formerly line 1883) — the only named `CreateFrame` in the file, so it
can't be pooled by the generic path:

```lua
local thresholdName = "GCDI_BuffThreshold_" .. buffKey
local thresholdDropdown = _G[thresholdName]
if thresholdDropdown then
	thresholdDropdown:SetParent(row); thresholdDropdown:ClearAllPoints(); thresholdDropdown:Show()
else
	thresholdDropdown = CreateFrame("Frame", thresholdName, row, "UIDropDownMenuTemplate")
end
pool_register(thresholdDropdown)
```

### Verification already done on this file

- `luaparse` syntax: **OK**
- Scope diff vs HEAD: **no new unresolved globals, none dropped**
- Paren-balance sweep over all 136 `acquire_*` call sites: **no malformed conversions**
- All 49 `CreateFrame` sites accounted for (48 auto-converted + the named dropdown above)

---

## State-reset hardening — done

Added the resets identified below to `acquire_frame` / `acquire_fontstring` / `acquire_texture`
(`LibGCDI-Options.lua:84-150`):

1. **`Button:SetEnabled`** — highest risk, likely a real visible bug. The up/down/bottom
   reorder buttons call `SetEnabled(false)`. `rescanSpellsBtn` (and peers) never call
   `SetEnabled` at all. If a rescan button draws a previously-disabled button out of the
   pool, it renders greyed out and dead. → `acquire_frame` now calls `SetEnabled(true)`
   when the widget supports it.
2. **`Button` font objects** — the reorder buttons call `SetNormalFontObject` /
   `SetHighlightFontObject` with small fonts, which persist. A reused button elsewhere would
   render with the wrong font. → reset to `GameFontNormal` / `GameFontHighlight`
   (the `UIPanelButtonTemplate` defaults), guarded by `_G.GameFontNormal`/`_G.GameFontHighlight`
   existing.
3. **`Texture:SetTexCoord` / `SetVertexColor` / `SetAlpha`** — a cropped spell icon reused as
   a plain color swatch stays cropped, since `SetColorTexture` doesn't clear TexCoord.
   → `acquire_texture` now resets `SetTexCoord(0,1,0,1)`, `SetVertexColor(1,1,1,1)`,
   `SetAlpha(1)`.
4. **`FontString` text color / justify / width** — `SetTextColor(0.7,0.7,0.7)` on a section
   description persists onto a reused fontstring whose call site doesn't set a color.
   → `acquire_fontstring` now resets via `fs:SetTextColor(fs:GetFontObject():GetTextColor())`
   (guarded on `GetFontObject()` returning non-nil), plus `SetJustifyH("LEFT")`,
   `SetWidth(0)` (0 = auto-size), `SetAlpha(1)`.
5. **`Frame` alpha** — reset to 1 in `acquire_frame`.
6. **`EditBox` text** — cleared in `acquire_frame` when `kind == "EditBox"`.

Verified: `luaparse` syntax OK, scope diff vs `HEAD` clean (no new/dropped unresolved globals —
`_G.GameFontNormal`/`_G.GameFontHighlight` used explicitly, matching the file's existing
`_G.GCDI` convention, so they don't register as bare globals).

**Still not tested in-game — this is now the top priority.** Priority order:
- Open options, switch every tab several times, rescan, load a profile — watch for
  greyed-out buttons, wrong fonts, cropped textures, stuck grey text.
- Toggle preview mode on and off; confirm nothing stays preview-colored.
- Swap spec (stagger + range caches), change action bars, shapeshift.
- Watch general responsiveness against the old 0.015s ticker.

---

## Tooling built this session (recreate if needed)

Lives in bash `/tmp/luacheck/` = `C:\Users\jason\AppData\Local\Temp\luacheck\`.
Nothing is in the repo.

| File | Purpose |
|---|---|
| `check.js` | `luaparse` syntax check, `node check.js <files...>` |
| `scope.js` | AST scope walker printing unresolved globals |
| `convert.js` | the mechanical `CreateFrame` → `acquire_*` transformer (hardcoded ranges `[[224,1963],[2443,2656]]`) |

Baselines of the HEAD versions were kept in `/tmp/base/`.

**Two gotchas:** there is no `lua`/`luac` on this machine — hence the JS/`luaparse` approach.
And the Write tool's `/tmp` is *not* bash's `/tmp`, so write these scripts with a bash
heredoc, not with Write.
