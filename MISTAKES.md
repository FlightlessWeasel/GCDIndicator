# Mistakes

## Copilot review merge gate (2026-08-15)
Draft-state merge gate failed: GitHub Free plan has no branch protection, and
Actions `GITHUB_TOKEN` can't call the draft-state GraphQL mutation ("Resource
not accessible by integration"). **Fix:** verify plan tier + token perms
before building merge gates; use required status checks or a scoped
credential instead.

## Dispel indicator silently disabled on every client (found 2026-08-16)
`player_has_dispellable_debuff_on_self` (deleted, see `docs/dispel-indicator.md`)
gated on a build-number check (`>= 120100`) meant to proxy "auras might be
secret," but that's true on every current client — so it always returned
false/no-dispel with no error, silently broken for unknown sessions.
**Root cause:** version-number gate used as a proxy for a runtime condition
that never re-evaluates once the version threshold passes. **Fix:** gate on
live capability/state checks (`pcall` the real call, or an explicit secrecy
API) instead of version gates, unless the failure mode is a hard API
removal. Now moot: detection moved to native `AuraContainer`/`AddAuraSlot`
overlay, which doesn't gate on secrecy at all.

## PLAYER_ENTERING_WORLD CDM rescan tainted Blizzard's CooldownViewer (2026-08-21)
Added a synchronous `scan_cdm_buff_frames()` call to the `PLAYER_ENTERING_WORLD`
handler to fix a stale `cdmBuffFrames` cache after zone transitions (CDM's
`itemFramePool` reassigns frame objects across cooldownIDs - see `CLAUDE.md`).
Caused `"attempt to perform boolean test on ... secret boolean value, while
execution tainted by 'GCDIndicator'"` errors inside Blizzard's own
`CooldownViewerItemData.lua`/`CooldownViewer.lua` (`RefreshTotemData`,
`CheckAuraAddedAlertTriggers`) when exiting a dungeon mid-combat - exactly
when Blizzard's own CDM visibility/layout refresh (`OnShow`/`RefreshLayout`)
also runs off the same zone transition. **Root cause:** reading deep into
CDM internals (`itemFramePool`, frame fields) synchronously in the same tick
as Blizzard's own CDM refresh, not deferred like this codebase's established
`UNIT_AURA` pattern (`RegisterUnitEvent` + `C_Timer.After(0, ...)`). **Fix:**
removed the rescan entirely rather than deferring it - it didn't even solve
the original bug (only captures *currently active* frames, so a not-yet-cast
buff was never fixed by it) and was superseded by an on-demand self-heal
inside `update_buff_bar` (`gcdi_cdm_find_active_frame`), which only ever runs
from already-deferred call sites and fixed the bug on its own. Lesson: any
new code that reads `C_CooldownViewer`/CDM frame-pool internals must be
audited for which event/call-chain it runs in, not just wrapped in a pcall -
taint isn't caught by pcall.

Calibration-mode marker (`GCDI.toggle_calibration_mode`) parented its
background/swatch textures directly to `main_frame`, and the header comment
claimed the marker's fixed x-offset (`CALIBRATION_OFFSET_X = 140`) would
"never overlap real indicators." That only held for the ~86px-wide status
row. With "Show GCD Row" off, the resource bar (a real child `Frame`, 204px
wide, created at `main_frame:GetFrameLevel() + 1` by CreateFrame's default)
takes row 0's place and spatially overlaps the marker's x-range - and since
frame level beats draw layer across *different* frames, the resource bar's
background silently painted over the marker regardless of texture creation
order or `BACKGROUND`/`ARTWORK` layer choice, breaking companion-script
detection with no error. **Fix:** parent the marker's background/swatches to
a dedicated child frame set to `main_frame:GetFrameLevel() + 50`, so it wins
against any real content regardless of what occupies that row. Lesson: for
overlay/marker UI meant to always be visible on top, don't rely on draw
layer alone when siblings can be full child frames - frame level order
trumps draw layer between different frames.
