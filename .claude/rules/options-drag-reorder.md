# Options UI: Drag-to-Reorder Rows

Covers the drag-and-drop reordering added to the Spells/Items/Buffs tabs in
`Libs/LibGCDI-Options/LibGCDI-Options.lua`, replacing the old per-row
Up/Down/Bottom button triplet with a drag handle plus Top/Bottom quick-jump
icon buttons (not the original text-label buttons - see "Grip icon and
Top/Bottom arrow buttons" below; there are no longer per-row Up/Down actions).
Read this before touching row layout in those three tabs or before extending
drag-and-drop to another tab (e.g. Resources).

## Why

The old pattern called `GCDI.refresh_options_frame()` (a full teardown/rebuild
of the tab's widget tree, via the `acquire_*`/pooling layer — see
`OPTIMIZATION-NOTES.md`) on every single Up/Down click, so reordering an entry
N slots meant N full rebuilds. Drag-and-drop needed a mechanism that updates
the screen live without tearing down the row currently being dragged out from
under the gesture.

## What: `add_row_drag_handle` (top of the file, "REORDERABLE ROWS" section)

One shared implementation used by all three tabs' row-creation loops. Per row:

```lua
local gripBtn = add_row_drag_handle(row, spellRows, orderedSpells, i, slotYs, GCDI.commit_spell_order, refresh_spells_tab)
```

- `rows`/`ids` are the tab's own per-refresh arrays (`spellRows`/`orderedSpells`,
  etc.) — passed by reference and mutated in place as the dragged row passes
  its siblings, so at all times `rows[k]`/`ids[k]` reflect "what the order
  would be if dropped right now."
- `slotYs[k]` is captured once per row, from the literal `yOffset` value used
  for that row's `SetPoint("TOPLEFT", 10, yOffset)` at layout time — not
  derived from a fixed row height. The disabled-section separator
  (`add_disabled_section_separator`) inserts a non-uniform gap partway down
  the list, so slot positions aren't evenly spaced; snapping to the nearest
  *captured* Y (`nearest_slot_index`, an O(n) scan) is correct regardless of
  that gap, whereas `topY - (i-1) * rowHeight` arithmetic would not be.
- The dragged row's frame itself is never in `rows[]` positionally during the
  drag — it always occupies `rows[currentIndex]` (an invariant maintained by
  the swap loops in `OnUpdate`), while visually it free-follows the cursor;
  only its *displaced neighbors* get `SetPoint`-snapped to fixed slots as the
  swap happens.
- **On drop**: `commitFn(ids)` (`GCDI.commit_spell_order`/`commit_item_order`/
  `commit_buff_order`, thin wrappers in `GCDIndicator.lua` over
  `CatalogManager:CommitOrder`) persists the whole final order in one write —
  not N `MoveInOrder` calls. Then `onDropRefresh()` (the tab's own
  `refresh_*_tab`) runs once, to resync everything the live drag doesn't touch
  (disabled-section placement if enabled state changed elsewhere, row
  backing data, etc).

## Grip icon and Top/Bottom arrow buttons

The drag handle renders as a 3-horizontal-bar "hamburger" icon rather than a
bordered button with "|||" text: `add_row_drag_handle` now calls
`acquire_frame("Button", row)` (no template - a plain, borderless button) and
draws 3 thin `grip:CreateTexture(nil, "ARTWORK")` bars via `SetColorTexture`,
cached on `grip.__gripBars` so they're created once per pooled button instance
and just repositioned on every reuse rather than round-tripping through
`acquire_texture`/the tab's track list. There's no known stable Blizzard
hamburger/grip-icon atlas to depend on, so this is drawn by hand rather than
sourced from a template. Hover feedback is a brightness change
(`SetColorTexture(1,1,1,1)` vs `(0.82,0.82,0.82,1)`) on `OnEnter`/`OnLeave`,
same handlers that show/hide the "Drag to reorder" tooltip.

`Top`/`Bot` are now `UIPanelScrollUpButtonTemplate`/`UIPanelScrollDownButtonTemplate`
buttons (18x16, verified via the `tekkub/wow-ui-source` FrameXML mirror -
`SharedXML/SharedUIPanelTemplates.xml` - not recalled from training data) with
their `OnClick` fully replaced via `SetScript` to call
`GCDI.move_*_to_top`/`GCDI.move_*_to_bottom` + `GCDI.refresh_options_frame()`,
same as the old text-button pattern. Overwriting `OnClick` this way discards
whatever default scroll-button behavior the template ships with, which is
fine here since these buttons are never parented to an actual scrollbar.
`GCDI.move_spell_to_top`/`move_item_to_top`/`move_buff_to_top` wrap
`CatalogManager:MoveToTop` (`Libs/LibGCDI-Catalog/LibGCDI-Catalog.lua`, added
alongside `MoveToBottom`, same shape, test-covered in `catalog_spec.lua`'s
"MoveToTop" and "reorder side effects" blocks).

Row order left-to-right is grip -> Top -> Bottom, each anchored 2px off the
previous one's `RIGHT`. Total footprint from the `drag` column's `x` is
20 (grip) + 2 + 18 (top) + 2 + 18 (bottom) = 60px, up from the old 46px
(grip 20 + 2 + "Bot" 24) - each tab's `drag` column has enough room before
either the next column (Items' `gcd` at x=420 vs. Items' drag+60=406) or the
tab's `ScrollFrame` clip edge (viewport is the 670px-wide options frame minus
its 10/-30 margins = 630px; Spells' drag+60=609, Buffs' drag+60=516 both clear
it) - confirmed by reading the actual column-table x values and scroll frame
`SetPoint`s in this file, not assumed. If a future column is added after
`drag` in any tab, or the options frame is resized, re-check this budget.

## `CatalogManager:CommitOrder` (`Libs/LibGCDI-Catalog/LibGCDI-Catalog.lua`)

Added alongside the existing `MoveInOrder`/`MoveToBottom`, which now both
delegate to it too (removing what used to be a second copy of the
save+auto_save+onReorder sequence, and the leftover debug `print()`s that used
to run on every reorder click). Takes a full ordered id list and does
save + `GCDI.auto_save_to_profile()` + `onReorder()` once. Test-covered in
`tests/spec/catalog_spec.lua` ("CommitOrder" and "reorder side effects"
`describe` blocks) — this is the one piece of this feature that runs under
the real Lua 5.1 test harness; the drag gesture itself (frame/cursor-driven)
is not testable there, see `.claude/rules/test-harness.md`.

## Verified WoW API assumptions (12.x, not recalled from training data)

- `GetCursorPosition()` returns screen-space coordinates independent of any
  frame's scale; divide by the target frame's `GetEffectiveScale()` to get its
  local coordinate space. Source: `warcraft.wiki.gg/wiki/API_GetCursorPosition`.
- `GetMouseFocus()` was removed in patch 11.0.0 — do not use it or
  `IsMouseOver()`-based hit-testing for sibling detection during a drag, since
  `ScrollFrame` clip/hit-test interaction with a mid-drag child is not
  documented. This is why the gesture uses pure Y-coordinate comparison
  against `slotYs` instead of any mouse-focus/hit-test API.
- `RegisterForDrag("LeftButton")` **and** `EnableMouse(true)` are both
  required for `OnDragStart`/`OnDragStop` to fire — neither implies the other.
- `SetMovable(true)` is only tied to the `StartMoving()`/`StopMovingOrSizing()`
  built-in path; this implementation never calls `StartMoving()` (it re-anchors
  manually via `SetPoint` in `OnUpdate`), so rows are not `SetMovable`.
- `HasScript("OnDragStart"/"OnDragStop")` is `true` on plain `Frame`/`Button`
  widgets without ever calling `RegisterForDrag` first — so the existing
  `POOL_SCRIPTS` cleanup in `release_widget` (which already lists both script
  names) correctly clears them on every pooled-widget release; no pooling
  changes were needed for this feature.

## Known gaps (flagged, not fixed here)

- **No live in-game verification.** No WoW client is available in this dev
  environment (see `CLAUDE.md`'s "Critical constraints"). Verified here via
  `check.js`/`scope.js` static syntax/scope checks only. Cursor/scale math,
  drag feel, and scroll-frame interaction while dragging need real in-game
  testing (out of combat first) before this is considered done.
- **No auto-scroll while dragging** near the scroll-frame edge — deferred.
  Dragging an item far past the visible list requires scrolling manually
  first, or using the "Bot" button.
- **Resources tab is untouched** — no drag-and-drop there, and resource
  bar order is still the hardcoded `GCDI_RESOURCE_ORDER` in
  `GCDIndicator.lua`. Explicitly declined when this feature was scoped: making
  it configurable would add new persisted state and risks desyncing the
  companion script's pixel reads (see `CLAUDE.md`'s companion-project
  section) — would need its own `CatalogManager` instance and a separate,
  deliberate decision to do so.
