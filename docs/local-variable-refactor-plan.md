# Local-variable refactor plan

**Status**: steps 1-3 below landed together in the collapsible-sections
commit (see `docs/options-collapsible-sections.md`), verified via
`check.js`/`scope.js` + the manual `SetPoint`-sequence trace described
under Verification. No live-client confirmation yet. Step 4 (GCDI-table
namespacing sweep) was added during that same pass, beyond this plan's
original scope — see its own section below.

Preventive maintenance, not a live bug: Lua enforces a hard compile-time
limit of 200 locals in scope within a single function. Both large files in
this repo compile clean today (`luajit -e "loadfile(...)"`), but several
functions are structurally close to the limit and keep growing by 2-4
locals every time a feature is added the same copy-paste way — most
notably `create_options_frame` (LibGCDI-Options.lua) and `reposition_all`
(GCDIndicator.lua).

**Constraint**: zero behavioral/visual change. `reposition_all` drives
on-screen bar positions the sibling AHK repo (`../AHK`) reads via
pixel-sampling — any extraction there must be a pure move-the-code
operation, verified by literal before/after diff of the generated
`SetPoint` math. `create_options_frame` carries no such risk (AHK never
reads the Options panel).

## Sequencing

Safest/most isolated first:

1. `init()` resource-bar block (GCDIndicator.lua:3764-3784) — smallest,
   calibrates the workflow.
2. `create_options_frame` (LibGCDI-Options.lua:2901-3266) — no AHK risk,
   most locals to reclaim (~32 → ~6), safe to be aggressive.
3. `reposition_all` (GCDIndicator.lua:2236-2466) — last, only real
   AHK-desync risk, needs the strictest verification.

## 1. `init()` (GCDIndicator.lua:3764-3784)

Add module-level `RESOURCE_NAMES` (ordered list matching existing
`RESOURCE_COLORS` keys), replace the 15 flat
`resourceBars.X = create_resource_bar(...)` lines with:

```lua
for _, name in ipairs(RESOURCE_NAMES) do
	resourceBars[name] = create_resource_bar(name, RESOURCE_COLORS[name])
end
setup_health_heal_absorb_bar(resourceBars.health)
```

Mirrors the `events`-table loop (3822-3844) and `resources`-table loop
(3809-3817) `init()` already uses elsewhere in its own body. ~19 flat
locals → ~1.

## 2. `create_options_frame` (LibGCDI-Options.lua:2901-3266)

- New top-level helper `build_button_section(parent, yOffset, defs)` where
  `defs` is an ordered list of `{kind="button"|"checkbox"|"header", ...}`
  entries:
  - button: `width, text, tooltipTitle, tooltipLines, onClick, sameLine, resultKey`
  - checkbox: `checked, label, help, onClick, resultKey`
  - header: `title, desc, width, showSep`

  Returns final `yOffset` and a `{[resultKey]=widget}` table. Replaces the
  ~32 flat locals in the Settings-tab (2978-3096) and Developer-tab
  (3140-3241) sections with two module-level data tables
  (`SETTINGS_SECTION_DEFS`, `DEVELOPER_SECTION_DEFS`) built from the exact
  current literal content (same headers/tooltips/`onClick` closures —
  closures keep capturing `optionsFrame`/`configs`/`settings` as upvalues
  unchanged).

  The `exportBarsBtn`/`exportAhkBtn` same-line-anchor pair stays as an
  explicit special case after the loop rather than forcing a generic
  "anchor to sibling" field into the def shape for one pair.

- Keep an `optionsFrame[resultKey] = widget` compatibility assignment
  inside the loop so any other code reading e.g.
  `optionsFrame.compactModeCheckbox` directly keeps working without a
  wider search-and-replace.
- Hoist `create_tab_scroll_frame` from a closure captured over
  `optionsFrame` to a plain top-level function taking `optionsFrame` as an
  explicit parameter.
- Leave `TAB_SCROLL_DEFS`'s existing loop (2942-2953) as-is — already
  correct. Leave `profilesFrame`/`closeBtn` (3250-3262, 3 locals) inline,
  not worth extracting.
- Relocate existing block comments (2922-2923, 3105-3108, 3120-3125,
  3135-3139) to their new homes, re-evaluating each against the
  no-comments-unless-justified rule rather than reflexively carrying all
  forward.

## 3. `reposition_all` (GCDIndicator.lua:2236-2466)

Most conservative treatment of the three:

- Extract `layout_three_columns(entries, startY, col2X, col3X, spellBarHeight, spacing)`
  → `(col1Y, col2Y, col3Y, columnsUsed)`, used once for the non-compact
  spell/item block (2381-2405) and once for the non-compact buff block
  (2409-2435) — currently near-identical duplicated math.
- Optionally extract the duplicated `maxWidth` calc (2439-2447 /
  2449-2457) into `column_max_width(...)` for symmetry, since it consumes
  values `layout_three_columns` already computed.
- Do **not** touch the compact-mode flow-packing block (2344-2380,
  already correctly shares `allEntries`) or the GCD-row/resource-bar
  visibility block (2252-2320, small and not worth reducing to a
  table-loop without losing per-bar readability) — wrap the latter in
  `do...end` if desired, no function extraction.
- Verification for this function specifically requires a manual trace:
  capture the exact sequence + numeric arguments of every `SetPoint` call
  for a fixed synthetic input (e.g. 7 spells + 3 items + 4 buffs) before
  and after, confirm byte-identical — `check.js`/`scope.js` passing is
  necessary but not sufficient here given the AHK pixel-read dependency.

## 4. GCDI-table namespacing sweep (GCDIndicator.lua, whole file)

Beyond the three functions above, every remaining top-level
`local function foo() ... end` that GCDIndicator.lua also exposed for
cross-file use via a separate `GCDI.foo = foo` line (`should_track_spell_icon`,
`is_spell_off_gcd`, `is_item_off_gcd`, `rebuild_spell_bars`/
`rebuild_item_bars`/`rebuild_buff_bars`, `scan_cdm_buff_frames`,
`export_bar_positions`, `export_companion_config`, `scan_action_bars`,
and the various `print_*`/`test_*`/`import_*` debug commands, among
others) was collapsed to a single `function GCDI.foo()` declaration,
dropping the separate assignment line and the forward-declared
chunk-level local it required. This is the same pattern
`GCDI.effective_bar_geometry`'s comment already documented as this
file's convention before this refactor — applying it to the remaining
holdouts frees main-chunk locals the same way step 1-3's extractions
free per-function locals, just at chunk scope instead of function scope.

`reposition_all`/`rebuild_spell_bars`/`rebuild_item_bars`/
`rebuild_buff_bars` were previously the sole exception, kept as
forward-declared locals under a comment calling them out as "genuinely
hot per-tick functions." They aren't: every call site is a discrete
UI/profile event (profile load, drag-reorder callback, settings toggle,
preview-mode exit) — none of them fire from a `ticker`/`OnUpdate` per
displayed frame. That comment was already stale, so this sweep folds
those four in too instead of carving out an exception the codebase
doesn't actually need.

## Verification (all four)

- `check.js` (syntax) + `scope.js` (unresolved-globals diff must be
  unchanged) after every extraction.
- Manual before/after local-count tally per function to confirm the
  metric actually moved.
- Manual `CreateFrame`/`SetPoint`/`SetText`/`SetScript` call-sequence diff
  for `create_options_frame` and the `reposition_all` trace above.
- No unit-test coverage exists for either file (out of scope to add
  here).
- In-game confirmation (`/gcdopt`, all Settings/Developer buttons still
  work, bar layout pixel-identical in compact and non-compact mode)
  remains required before calling this done — don't claim coverage that
  doesn't exist.
