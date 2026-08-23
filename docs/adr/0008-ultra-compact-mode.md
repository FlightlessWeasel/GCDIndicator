# 0008. Ultra-Compact Mode: machine-only minimum-footprint layout

Date: 2026-08-23
Status: Accepted

Full detail: [`docs/ultra-compact-mode.md`](../ultra-compact-mode.md)

## Context

Compact Mode already shrinks the HUD for a human (icon-less, flow-packed
spell/item/buff rows), but the companion script never needs that shape to be
legible — it only samples specific pixel coordinates. The user wanted a
smaller on-screen footprint than Compact Mode allows while the companion
script drives play, with human readability explicitly not a design goal for
that mode.

## Decision

Add a third mode, `configs.ultraCompactMode`, orthogonal to
`configs.compactMode` rather than a variant of it - both stay independently
toggleable (`/gcdopt compact`, `/gcdopt ultracompact`, matching Settings-tab
checkboxes). Ultra-Compact always implies the icon-less/flow-packed visual
style Compact Mode already provides (`configs.compactMode or
configs.ultraCompactMode` at every layout call site), and additionally
shrinks box size via new tunable fields (`ultraStatusSize`, `ultraBarSize`,
`ultraPad`, `ultraSpacing`, `ultraCompactGap`, `ultraCompactRowMaxWidth`) -
shipped as unvalidated starting points, since no live WoW client exists in
this dev environment to confirm the smallest size that doesn't blend/
antialias at a given UI Scale.

Scope is deliberately narrower than "shrink everything": only the status row
and spell/item/buff bars shrink. Resource bars stay on the base
`barHeight`/`bgPadding` unconditionally - a new helper,
`gcdi_effective_bar_geometry()`, returns the ultra-aware size/pad/spacing
only for the call sites that should shrink; resource-bar creation code never
calls it. `reposition_all`'s previously-shared `barSize`/`pad` locals (used
for both resource bars and spell bars) were split into resource-only and
spell-effective variants for the same reason - see the linked doc for why
that split was necessary, not optional.

The status row (`gcdCombatContainer` and its children) resizes in place
(`resize_status_row()`) rather than being destroyed and recreated on toggle,
unlike spell/item/buff bars (which already had a rebuild path from Compact
Mode and keep using it). The native dispel overlay
(`gcdi_setup_dispel_overlay`, ADR 0003) anchors itself to the exact
`main_frame.dispelbar` frame object it saw at bind time and never
re-anchors - destroying and recreating that frame would silently orphan the
overlay, since there is no rebind/teardown path for it. Resizing the same
frame object in place keeps its `SetAllPoints(sourceBar)` anchor valid
across a mode toggle.

## Consequences

- Toggling Ultra-Compact live-resizes the whole HUD (status row + spell/
  item/buff bars) without a `/reload`, at the cost of `resize_status_row()`
  being new, less-tested code with no equivalent precedent elsewhere in the
  codebase - every other "rebuild on mode change" path destroys and
  recreates frames instead of resizing them in place.
- The calibration marker's fourth swatch gained a third color
  (`GCDI.CALIBRATION_MODE_COLORS.ultra = {1,1,0}`, saturated yellow, checked
  against the existing red/green/blue/white/gray swatches under the
  companion script's per-channel tolerance match) - swatch count/size/offset
  are unchanged, only the color set it picks from grew from 2 to 3.
- Companion-script changes are proportionally larger than a typical
  layout-constant tweak: `PixelMonitor.ahk`'s box-size-derived constants
  (previously one-shot values computed at file load) had to become a
  callable `RecalculateAddonLayoutConstants()`, because Compact Mode never
  changed box size before - only position - so nothing in that file
  previously needed to recompute sizes at runtime.
- No live WoW client or AHK interpreter in this dev environment for either
  side - shipped starting geometry constants and the whole companion-script
  change are static-review-only until the user runs the in-game/Launcher
  verification pass described in the linked doc.

## Alternatives considered

- **Replace Compact Mode instead of adding a third mode.** Rejected per
  explicit user requirement - existing Compact Mode users would have their
  layout silently change size out from under them.
- **Destroy and recreate the status row on toggle**, mirroring
  `rebuild_spell_bars()`/`rebuild_buff_bars()`. Rejected once the dispel
  overlay's bind-time-only anchor was found - would silently orphan the
  purple/grey dispel indicator on every Ultra-Compact toggle. In-place
  resize avoids the problem entirely by never destroying the frame the
  overlay is anchored to.
- **Require a `/reload` for the status row instead of a live rebuild.**
  Considered as the lower-risk first cut, given no live client to test a
  dynamic rebuild against - the user explicitly chose the live-resize
  approach instead once the dispel-overlay-safe in-place-resize alternative
  was identified.
