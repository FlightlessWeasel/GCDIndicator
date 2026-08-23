# Ultra-Compact Mode: machine-only minimum-footprint layout

Covers `configs.ultraCompactMode`, its geometry fields
(`ultraStatusSize`/`ultraBarSize`/`ultraPad`/`ultraSpacing`/
`ultraCompactGap`/`ultraCompactRowMaxWidth`), `GCDI.effective_bar_geometry()`/
`GCDI.effective_status_geometry()`, and `GCDI.resize_status_row()`. Read this
before touching status-row/spell/item/buff sizing or the calibration
marker's mode swatch.

## Why

Compact Mode already shrinks the HUD for a human (icon-less, flow-packed
rows), but the companion script never needs the result to be legible - it
only samples fixed pixel coordinates. Ultra-Compact Mode is a third,
independent toggle that shrinks the HUD further, purely to reduce the
screen area the companion script has to capture. It is explicitly not
designed to be readable at a glance.

## What: config shape

`GCDI.configs` (`GCDIndicator.lua`, top of file) gained:

```lua
ultraCompactMode = false,
ultraStatusSize = 3,
ultraBarSize = 3,
ultraPad = 0,
ultraSpacing = 0,
ultraCompactGap = 1,
ultraCompactRowMaxWidth = 200,
```

`ultraCompactMode` persists per-character the same way `compactMode` does
(`settings.ultraCompactMode`, bootstrapped in `init()`, written by both the
`/gcdopt ultracompact` slash command and the Settings-tab checkbox). The
size/pad/spacing/gap/row-width fields are **unvalidated starting points** -
no live WoW client exists in this dev environment to confirm the smallest
box size that doesn't blend/antialias at a given WoW UI Scale. Tune them
after in-game testing (see "Known gaps" below), then update this doc and
`AHK/CLAUDE.md`'s pixel-protocol table with the real numbers.

## What: scope - status row + spell/item/buff bars only, never resource bars

Ultra-Compact Mode shrinks:
- The status indicator row (GCD/Combat/Aggro/Channeling/Dispel/AOE/MobCount/
  stance).
- Spell/item bars and buff/DoT bars.

It never shrinks resource bars (health/rage/energy/combo points/class
resources) - they always stay at the base `configs.barHeight`/`bgPadding`
size, in whichever of Normal/Compact they'd otherwise render at.

This mattered for implementation, not just intent: `configs.barHeight`/
`bgPadding` were already shared between resource bars and spell/item/buff
bars before this feature existed (both read the same fields). Making
Ultra-Compact shrink "barHeight" directly would have shrunk resource bars
too. The fix is `GCDI.effective_bar_geometry()` (near `create_bar_container`
in `GCDIndicator.lua`):

```lua
function GCDI.effective_bar_geometry()
	if configs.ultraCompactMode then
		return configs.ultraBarSize, configs.ultraPad, configs.ultraSpacing
	end
	return configs.barHeight, configs.bgPadding, configs.barSpacing
end
```

Attached directly to the `GCDI` table (`function GCDI.foo()`) rather than a
top-level `local function` - see "Known gaps" below for why that choice is
load-bearing here, not stylistic.

and its status-row sibling, `GCDI.effective_status_geometry()` (same
shape, `configs.size`/`ultraStatusSize` instead of `barHeight`/`ultraBarSize`).
Both are called **only** by `create_spell_bar`/`create_item_bar`/
`create_buff_bar`, the status-row creation code, and `reposition_all`'s
spell/status layout math. Resource-bar creation code (`create_resource_bar`
and `reposition_all`'s resource-bar block) reads `configs.barHeight`/
`bgPadding` directly and never calls either helper - this is the entire
mechanism that keeps resource bars unaffected.

`reposition_all` (`GCDIndicator.lua`) used to compute one shared
`barSize`/`pad` pair used by both resource bars and spell bars. It now
computes two independent pairs:

```lua
local resourceBarSize, resourcePad = configs.barHeight, configs.bgPadding
local spellBarSize, spellPad = GCDI.effective_bar_geometry()
local statusSize, statusPad = GCDI.effective_status_geometry()
```

`resourceBarHeight`/`resourceBarWidth` derive from the resource pair;
`spellBarHeight`/`columnWidth`/`gcdContainerHeight` derive from the
spell/status pair. The compact-mode row-wrap branch condition became
`if configs.compactMode or configs.ultraCompactMode then` (Ultra-Compact
always implies the flow-packed layout Compact Mode already provides), with
`compactGap`/`compactRowMaxWidth` reading `ultraCompactGap`/
`ultraCompactRowMaxWidth` instead of the fixed `2`/`200` when Ultra-Compact
is on.

## How: status row resizes in place, not destroy-and-recreate

Spell/item/buff bars already had a rebuild path (`rebuild_spell_bars()`/
`rebuild_buff_bars()`, built for Compact Mode's icon-square-present/absent
structural change) - the `ultracompact` slash command and Settings checkbox
reuse it. The status row (`gcdCombatContainer` and its children -
`stanceIndicator`, `gcdbar`, `combatbar`, `aggrobar`, `castingbar`,
`mobcountbar`, `dispelbar`, and 6 separators) had no equivalent, because
nothing had ever needed to resize it before: Compact Mode never touched
`configs.size`.

**Why not just destroy and recreate it, the same way spell bars do:** the
native dispel overlay (`gcdi_setup_dispel_overlay`, see
`docs/dispel-indicator.md` and ADR 0003) binds a single `AddAuraSlot` button
via `initializeFrame`'s closure, which captures `main_frame.dispelbar` as a
local (`sourceBar`) **at bind time** and calls
`button:SetAllPoints(sourceBar)` once. `dispelOverlayBound` then latches
true and `gcdi_setup_dispel_overlay` never runs its binding logic again -
there is no rebind/teardown path (deliberately removed when the feature
became permanent, see `docs/dispel-indicator.md`'s "What changed when this
became permanent"). Destroying `gcdCombatContainer` and creating a new one
would leave the overlay's `sourceBar` upvalue pointing at an orphaned,
hidden frame - the purple/grey dispel indicator would silently break on
every Ultra-Compact toggle, with no error.

The fix: `GCDI.resize_status_row()` (`GCDIndicator.lua`, right before
`rebuild_spell_bars`) mutates the **same** frame objects' `SetSize`/
`SetPoint` rather than destroying and recreating them:

```lua
function GCDI.resize_status_row()
	local container = main_frame.gcdcontainer
	if not container then return end

	local statusSize, statusPad = GCDI.effective_status_geometry()
	-- ... SetSize on container, stanceIndicator, gcdWhiteBg, gcdClip,
	-- gcdbar, every gcdRowSeps[] separator, and each of combatbar/
	-- aggrobar/castingbar/mobcountbar/dispelbar.
end
```

Since `main_frame.dispelbar` (and every other status-row frame) is never
destroyed, `SetAllPoints(sourceBar)` keeps tracking its live, resized
geometry automatically - WoW recomputes anchored positions/sizes from the
anchor's *current* state, not a snapshot. No re-anchoring code is needed on
the overlay side at all.

This required stashing two references on `main_frame` that the original
one-shot creation code didn't keep: `main_frame.gcdWhiteBg` (the GCD bar's
white background texture) and `main_frame.gcdRowSeps` (all 6 row
separators - previously only the *last* one, `gcdRowSep6`, was kept, since
nothing needed to resize the others before). `GCDI.resize_status_row()` also
retrieves the GCD clip frame via `main_frame.gcdbar:GetParent()` rather than
stashing a third new field, since it's already reachable that way.

Called from the `ultracompact` slash command and the Settings-tab checkbox,
alongside `rebuild_spell_bars()`/`rebuild_buff_bars()`:

```lua
rebuild_spell_bars()  -- also rebuilds item bars
rebuild_buff_bars()
GCDI.resize_status_row()
```

Order doesn't matter for correctness - `rebuild_buff_bars()`'s trailing
`reposition_all()` already computes correct new Y-offsets from
`GCDI.effective_status_geometry()` regardless of whether
`GCDI.resize_status_row()` has physically resized the container frame yet;
`GCDI.resize_status_row()` only changes frame *sizes*, and every status-row
frame's on-screen *position* comes from `SetPoint` chains relative to
`main_frame.anchor`/each other, unaffected by its own size.

## Calibration marker: third mode color, same swatch count/size/offset, own frame level

**Post-launch fix, not part of the original decision above:** the marker's
background/swatches were parented directly to `main_frame`, which put them
at the same effective z-order as `main_frame`'s own direct children -
losing to any real bar *container* (a child `Frame`, one `FrameLevel` above
`main_frame` by default) that happened to overlap the marker's fixed
x-offset. This was invisible in the common case (status row tops out at
~86px, well short of `CALIBRATION_OFFSET_X = 140`) but broke silently
whenever the resource bar row (200px wide, never shrunk by Ultra-Compact)
took row 0's place - e.g. with "Show GCD Row" off. Fixed by giving the
marker's background/swatches their own child frame at
`main_frame:GetFrameLevel() + 50`, so the marker always wins regardless of
what real content overlaps it. See `MISTAKES.md` for the full incident.



`GCDI.CALIBRATION_MODE_COLORS` (`GCDIndicator.lua`, "CALIBRATION MODE"
section) gained `.ultra = {1, 1, 0}` (saturated yellow) alongside the
existing `.compact`/`.normal`. The mode-swatch color selection became a
3-way:

```lua
local modeColor = configs.ultraCompactMode and GCDI.CALIBRATION_MODE_COLORS.ultra
	or configs.compactMode and GCDI.CALIBRATION_MODE_COLORS.compact
	or GCDI.CALIBRATION_MODE_COLORS.normal
```

Swatch count, size, and offset (`CALIBRATION_OFFSET_X`, `CALIBRATION_BORDER`)
are unchanged - the creation loop already sizes the marker off
`#GCDI.CALIBRATION_COLORS + 1`, so this was purely a new entry in the color
table plus a 3-way branch, not a marker-shape change. Yellow was checked
against the existing red/green/blue/white/gray swatches under the companion
script's per-channel `tolerance=40` match (`IsColorMatch` in
`FastPixelReader.ahk`) - every channel differs by enough from every existing
color to avoid a false match.

Companion-script side (not this addon's concern, documented here for the
cross-reference): `PositionCalibration.ahk`'s `TryMeasureMarkerAt` does the
matching 3-way match and returns both `compactMode`/`ultraCompactMode`
booleans; `PixelMonitor.ahk`'s per-mode geometry (previously one-shot values
computed at file load, since Compact Mode never changed box *size* before -
only position) became a callable `RecalculateAddonLayoutConstants()`,
invoked once at load and again from the new `Ctrl+Alt+U` toggle
(`lib/UltraCompactModeToggle.ahk`), before `CalculateBarLayout()`/
`GenerateCheckPixels()` run. See `AHK/CLAUDE.md`'s pixel-protocol table for
the full constant mapping.

## Known gaps (flagged, not fixed here)

- **No live in-game verification of any of this.** No WoW client or AHK
  interpreter exists in this dev environment - everything above is
  static-review-only (`check.js`/`scope.js` on the addon side; reading, plus
  a brace/paren balance check, on the AHK side - no real AHK parser
  available). Verify in-game before relying on any of it:
  - `/gcdopt calibrate`, then toggle `/gcdopt compact` and
    `/gcdopt ultracompact` independently - confirm the marker's 4th swatch
    changes to the right color each time, and the first 3 swatches don't
    move.
  - Toggle `/gcdopt ultracompact` with the options panel open and closed -
    confirm the status row visually shrinks/grows without a `/reload`, the
    dispel indicator still tracks correctly (cast something dispellable on
    yourself, confirm it still goes purple, in and out of Ultra-Compact),
    and no Lua errors appear.
  - In the companion script: `Launcher.ahk` → run one spec with
    Ultra-Compact checked, "Detect Position", then the `Ctrl+Alt+B`/
    `Ctrl+Alt+L` debug overlays to confirm predicted pixel positions land on
    the real (now smaller) status/spell/buff boxes, and that resource bars
    did **not** shrink.
- **`ultraStatusSize`/`ultraBarSize`/`ultraPad`/`ultraCompactGap` are
  unvalidated starting points**, not measured minimums. Tune them after the
  in-game pass above, then update this doc and `AHK/CLAUDE.md`'s table with
  the real numbers - don't leave the "unvalidated" framing in place once real
  numbers exist. `ultraCompactRowMaxWidth` is the exception - it's pinned to
  200 by design (matches the resource bar's fixed width, which is already
  the companion script's capture-width floor whenever a resource bar is
  shown; wrapping narrower only adds rows/height for no capture-area
  savings), not a guess to be tuned down.
- **`resize_status_row()` is new territory** - every other "layout mode
  changed, need to re-lay-out existing frames" path in this codebase
  destroys and recreates (`rebuild_spell_bars`/`rebuild_buff_bars`). This is
  the first in-place resize, chosen specifically to avoid orphaning the
  dispel overlay's bind-time anchor (see "How" above) - if a future change
  needs to resize a *different* set of frames that also has an
  engine-owned/bind-time-anchored dependent, the same reasoning applies:
  prefer resizing the existing frame object over destroying and recreating
  it.
