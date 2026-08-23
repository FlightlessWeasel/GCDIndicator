# 0006. Drag-to-reorder rows in the Options UI

Date: 2026-08-15
Status: Accepted

Full detail: [`docs/options-drag-reorder.md`](../options-drag-reorder.md)

## Context

The Spells/Items/Buffs tabs originally reordered rows via a per-row
Up/Down/Bottom button triplet, each click calling
`GCDI.refresh_options_frame()` — a full teardown/rebuild of the tab's widget
tree. Reordering an entry N slots meant N full rebuilds, and the mechanism
had no way to update the screen live without tearing down the row currently
being dragged out from under a gesture, which any drag-and-drop replacement
would need.

## Decision

One shared implementation, `add_row_drag_handle`, used by all three tabs'
row-creation loops. Rows/ids arrays are passed by reference and mutated live
as the dragged row passes siblings; each row's fixed Y-slot is captured from
its actual layout-time `SetPoint` offset (not derived from a uniform row
height, since the disabled-section separator creates a non-uniform gap) and
snapped to via nearest-slot lookup. On drop, the whole final order is
persisted in one write (`CatalogManager:CommitOrder`, new — supersedes
repeated `MoveInOrder` calls with their own duplicated save+auto-save+
`onReorder` sequence), then the tab refreshes once. Per-row Up/Down buttons
were removed entirely in favor of a drag handle plus Top/Bottom quick-jump
buttons.

## Consequences

- Reordering is O(1) full-tree rebuilds regardless of how far a row moves,
  down from O(N).
- `CommitOrder` is the one piece of this feature that's unit-testable under
  the real Lua 5.1 harness (ADR 0007) — the drag gesture itself
  (frame/cursor-driven) is not.
- No `GetMouseFocus()`/hit-test API is used for sibling detection (removed
  in patch 11.0.0, and `ScrollFrame` clip/hit-test interaction with a
  mid-drag child is undocumented) — pure Y-coordinate comparison against
  captured slot positions instead. This constrains how any future drag
  gesture in this codebase should be built.
- Resources tab was explicitly left out of scope — deferred as its own
  future decision, not an oversight (see the linked doc's "Known gaps").

## Alternatives considered

- **Keep per-row buttons, just remove the full rebuild per click.** Would
  need incremental in-place reordering logic without solving the actual
  UX goal (live drag feedback); rejected in favor of building the real
  drag gesture once.
- **Use `SetMovable(true)` + `StartMoving()`/`StopMovingOrSizing()`** for
  the drag itself. Rejected — rows re-anchor manually via `SetPoint` in
  `OnUpdate` instead, since the built-in movable-frame path doesn't fit
  "snap to nearest slot among siblings" behavior.
