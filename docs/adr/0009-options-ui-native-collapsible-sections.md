# 0009. Options UI: native collapsible sections instead of adopting AceGUI

Date: 2026-08-24
Status: Accepted

Full detail: [`docs/options-collapsible-sections.md`](../options-collapsible-sections.md)

## Context

The Options panel (`Libs/LibGCDI-Options/LibGCDI-Options.lua`) is built
entirely from native/raw WoW `CreateFrame` calls, with a hand-rolled tab
bar and no collapse/expand behavior anywhere — every section under
`add_section_header` is always fully expanded. The user asked for the
panel to feel more polished, specifically calling out collapsible/
expandable sections, and asked that the most common UI library used by
WoW addons be researched as a candidate for the upgrade.

The addon has zero Ace3-family dependencies today, though `LibStub` and
`CallbackHandler-1.0` (both AceGUI-3.0 prerequisites) are already
vendored in `Libs/`. The Spells/Items/Buffs tabs have a hand-built
drag-to-reorder gesture (`add_row_drag_handle`, ADR 0006) built on manual
`SetPoint` re-anchoring against captured `slotYs`, deliberately avoiding
`StartMoving()`/mouse-focus hit-testing since `GetMouseFocus()` was
removed in patch 11.0.0 and `ScrollFrame` hit-testing during a drag is
unreliable. No live WoW client is available in this dev environment for
either researching or verifying a UI-library migration.

## Decision

Extend the existing native `add_section_header` helper with a manual
chevron-toggle + `:SetShown()`/reflow mechanism, rather than vendoring
AceGUI-3.0 or migrating to Blizzard's native Settings API
(`Settings.RegisterCanvasLayoutCategory`/subcategories). No new
dependency is added. Collapse state persists per section key in
`settings.optionsUiCollapsedSections`; toggling re-runs the owning tab's
existing `refresh_*_tab` function, since every tab already recomputes
`yOffset` top-to-bottom on refresh — no new reflow mechanism is needed.

Migration is scoped to the Settings and Developer tabs first (button/
checkbox-only, no drag coupling), then optionally the disabled-entries
sub-section of Spells/Items/Buffs. The draggable row list itself stays
non-collapsible in this iteration.

## Consequences

- No new vendored dependency, no change to `.toc` load order, no change
  to the addon's `/gcdopt` entry point or discoverability model.
- The existing drag-to-reorder gesture in Spells/Items/Buffs is
  completely unaffected — it was the single biggest risk item identified
  for an AceGUI migration, and this decision avoids that risk entirely by
  not touching the layout engine those tabs depend on.
- Collapse/expand is in-canvas (within a single tab's own frame), not
  nav-tree-level — matches the actual ask (e.g. collapsing "Layout &
  Export" while "Frame Position" stays open in the same Settings tab).
- Native Settings API's automatic look-and-feel (consistent native
  styling, Options > AddOns list integration) is left on the table —
  explicitly not pursued, see alternatives below.
- No live WoW client for verification — collapse/expand click feel,
  reflow correctness, and persisted-state-across-reload all need real
  in-game confirmation before this is considered done, same standing
  limitation as ADR 0006.

## Alternatives considered

- **AceGUI-3.0** (New BSD license, standalone-usable without
  `AceAddon-3.0`). Researched as the current community-standard choice
  for polished WoW addon UIs, with native `TreeGroup`/manual-toggle
  support for collapsible sections. Rejected because its auto-layout
  containers (Flow/List) don't accommodate the existing drag-to-reorder
  gesture — migrating would mean simultaneously learning a new library's
  frame lifecycle and reimplementing an already-fragile gesture, with no
  live client available to validate either. Its main structural win
  (Vertical Layout auto-stacking, eliminating manual `yOffset` math) only
  helps the Settings/Developer tabs, which don't need a new dependency to
  get the same benefit from a data-table-driven native helper.
- **Blizzard's native Settings API**
  (`Settings.RegisterCanvasLayoutCategory`/`RegisterAddOnCategory` +
  subcategories, redone in patch 10.0.0, further changes in 11.0.2).
  Zero new dependency, and subcategories do render as collapsible nav
  entries. Rejected as the primary vehicle because that collapse is
  nav-tree-level (a whole subcategory's contents hide/show, rendered in
  Blizzard's own Options > AddOns chrome) rather than an in-canvas toggle
  of a section within a single tab — doesn't solve the actual ask.
  Adopting it would also change the addon's entry-point/discoverability
  model beyond what `README.md` currently promises or the user requested.
