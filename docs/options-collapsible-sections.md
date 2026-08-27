# Options UI: Collapsible Sections

Covers the planned collapse/expand extension to `add_section_header` in
`Libs/LibGCDI-Options/LibGCDI-Options.lua`. See
[ADR 0009](adr/0009-options-ui-native-collapsible-sections.md) for the
decision to build this natively instead of adopting AceGUI-3.0 or
Blizzard's native Settings API. Read this before implementing collapse
behavior or extending it to another tab.

## Why native instead of a UI library

Researched AceGUI-3.0 (the leading community-standard WoW addon UI
library) and Blizzard's native Settings API as candidates. Both were
rejected — full reasoning in ADR 0009. Short version: AceGUI's auto-layout
containers don't accommodate the existing hand-built drag-to-reorder
gesture in Spells/Items/Buffs (`docs/options-drag-reorder.md`), and the
native Settings API's collapse mechanic is nav-tree-level, not an
in-canvas per-section toggle. A small, self-contained extension to the
helper this file already owns end-to-end covers the actual ask with the
least risk.

## `add_section_header` API contract change

Current signature: `add_section_header(frame, yOffset, title, desc, width, showSep)`.

Add two optional trailing parameters (or fold into an options table if
that reads cleaner against the file's existing calling convention):

```lua
add_section_header(frame, yOffset, title, desc, width, showSep, collapsible, sectionKey)
```

- `collapsible` (boolean) — when true, the title renders with a "+"/"-"
  text-glyph prefix and the header becomes clickable. Plain text instead of
  a hand-drawn shape (contrast the drag-handle grip's 3-bar texture in
  `docs/options-drag-reorder.md`): faking a chevron by rotating a texture
  (`Texture:SetRotation`) carries real anchor-point/scaling edge cases per
  Blizzard's own API docs, not worth the risk for a cosmetic marker with no
  live client to verify it against.
- `sectionKey` (string) — a stable identifier for the section (e.g.
  `"frame_position"`, `"layout_export"`), used as the key into persisted
  collapse state. Must be unique within a tab; does not need to be
  globally unique.

On click, the header toggles
`settings.optionsUiCollapsedSections[sectionKey]` and calls
`GCDI.refresh_options_frame()`, which dispatches to whichever
`refresh_*_tab` function owns the currently-shown tab (`refresh_settings_tab`,
`refresh_developer_tab`, etc.) — no new reflow mechanism, since every tab
already recomputes `yOffset` top-to-bottom on refresh.

## `settings.optionsUiCollapsedSections` shape

New sub-table, persisted the same way as `settings.compactMode`/
`settings.debugMode` — a flat field on `GCDI.settings`, which is a direct
reference to the `GCDIndicator_Settings` SavedVariablesPerCharacter table,
so writes persist with no extra plumbing. **Not** wired into
`LibGCDI-Profiles`' `SaveProfile`/`LoadProfile` (those use an explicit
per-field whitelist, not a generic table dump) — deliberately, since this is
an addon-UI preference, not rotation/spec data, and switching profiles
shouldn't fold/unfold Options panel sections out from under the user.

```lua
settings.optionsUiCollapsedSections = {
	frame_position = false,
	layout_export = true,
	-- ...one boolean per collapsible sectionKey, true = collapsed
}
```

Missing keys default to expanded (falsy = not collapsed), so adding a new
collapsible section never requires a migration step.

## Persistence / reflow behavior

When `build_button_section` walks a tab's `defs` list, each collapsible
section's rows are skipped entirely (not created, `yOffset` doesn't advance
past them) when `settings.optionsUiCollapsedSections[sectionKey]` is true —
the check lives once in that loop via each header def's `collapsible`/
`sectionKey` fields, not per-widget at every call site.

**Prerequisite that turned out not to already hold:** the doc originally
assumed "every tab already recomputes `yOffset` top-to-bottom on refresh."
True for GCD/Resources/Spells/Items/Buffs/Profiles, but Settings and
Developer — the two tabs this feature targets first — were built **once**
inside `create_options_frame` via raw `CreateFrame` calls, with
`refresh_settings_tab`/`refresh_developer_tab` only re-syncing checkbox
`:SetChecked()` state, not rebuilding. A collapse toggle needs the section's
rows to actually appear/disappear, which that model can't do. Fixed by
converting both tabs to the same pooled rebuild-per-refresh model every
other tab uses: `create_settings_button` and `build_button_section`'s
checkbox path now call `acquire_frame`/`acquire_fontstring` instead of raw
`CreateFrame`, `SETTINGS_SECTION_DEFS`/`DEVELOPER_SECTION_DEFS` construction
and the `build_button_section` call moved inside
`refresh_settings_tab`/`refresh_developer_tab`, and each wraps with
`reset_track_list(settingsTabElements)`/`reset_track_list(developerTabElements)`
first. This also made the old checkbox-resync workaround (and its
`optionsFrame.compactModeCheckbox`-style stale-reference risk) unnecessary,
since a fresh rebuild always reads current `configs.*` — deleted rather than
kept alongside the new mechanism.

## Tab migration order

1. **Settings tab — pilot.** No drag coupling, `refresh_settings_tab`
   already exists, two natural section groups (frame-position/minimap/
   preview vs. layout/export).
2. **Developer tab — second.** Same shape as Settings, four separable
   sections (Debug, Diagnostics, Actions, Companion Script).
3. **Spells/Items/Buffs disabled-entries sections — last, and only if 1-2
   land cleanly.** Collapse scoped to the disabled-entries sub-section
   only (already visually distinct via `add_disabled_section_separator`)
   — the draggable row list itself stays non-collapsible. Collapsing
   mid-drag against the `slotYs` Y-coordinate model used by
   `add_row_drag_handle` is exactly the kind of interaction that can't be
   safely validated without a live client, so it's out of scope.
4. **GCD/Resources/Profiles tabs — out of scope** unless specifically
   requested; not flagged as needing grouping, and Profiles has its own
   distinct UI shape.

## Other low-risk native polish noted alongside this feature

- Defensive `InCombatLockdown()` guard on `create_options_frame` (the
  single open/reopen entry point), consistent with existing guidance
  elsewhere in the codebase for other frame-creation paths (e.g.
  `AuraContainer`/CDM handling). Scoped to that entry point rather than
  every tab refresh, since a collapse toggle or checkbox click only
  reaches `refresh_*_tab` while the panel is already open.
- Consistent hover/pressed styling across Settings/Developer buttons
  falls out for free from `build_button_section`'s data-table shape.

## Known gaps (flagged, not fixed here)

- **No live in-game verification.** No WoW client is available in this
  dev environment. Verifiable here only via `check.js`/`scope.js` static
  checks and a manual paper-trace of the `yOffset` reflow arithmetic
  (collapsing section N must shift every later section up by exactly the
  height its rows would have occupied). Collapse/expand click feel and
  persisted-state-across-reload need real in-game testing before this is
  considered done.
- **Implemented for Settings and Developer tabs** (step 1-2 of the tab
  migration order above); Spells/Items/Buffs disabled-entries collapse is
  not.
